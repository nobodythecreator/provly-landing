// v20.0.9 — STRIPE WEBHOOK, FULL SUBSCRIPTION PARITY
//
// Every path that changes a subscription (app checkout, customer portal,
// renewals, failed payments, cancellations, dashboard edits) is reduced to
// ONE operation: syncSubscription(subscriptionId). The handler does not
// trust the event payload's snapshot; it retrieves the subscription's
// CURRENT state from Stripe and writes that. Consequences, by construction:
//   - order-independent: Stripe does not guarantee delivery order; a
//     late-arriving older event re-applies the same current truth.
//   - path-independent: a portal-created subscription (no checkout session,
//     no org_id metadata) resolves through stripe_customer_id and provisions
//     exactly like a checkout one — and backfills stripe_subscription_id.
//   - retry-safe: an event that fails mid-processing is logged with an
//     ERROR note and answered 500; the retry is NOT treated as a duplicate
//     (the v19.8 seen-check swallowed retries of failed events forever).
//
// Organization resolution precedence: organizations.stripe_customer_id
// (our DB owns the link) → subscription.metadata.org_id → customer.metadata
// .org_id. A customer-id match that DISAGREES with metadata is a coherence
// conflict: logged, not written (hard enforcement is reserved for data
// coherence and the software's own money conduct).

import Stripe from "https://esm.sh/stripe@17.7.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PRICE_TO_TIER, mapStripeStatus } from "../_shared/stripe.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2026-04-22.dahlia",
  httpClient: Stripe.createFetchHttpClient(),
});

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

// Stripe statuses under which a subscription is the org's LIVE billing
// relationship. canceled / incomplete_expired are dead.
const LIVE_STATUSES = new Set<string>([
  "active", "trialing", "past_due", "unpaid", "paused",
]);
// NOT live: canceled, incomplete_expired — and incomplete (a checkout whose
// payment never completed). Treating incomplete as live would let an
// abandoned attempt block adoption of the real subscription that follows.

type OrgRow = {
  id: string;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  subscription_status: string | null;
  subscription_tier: string | null;
};

type SyncResult = {
  orgId: string | null;
  customerId: string | null;
  subscriptionId: string | null;
  note: string;
  // v20.0.9r1 (Greptile): a LIVE subscription that could not be attached to
  // an org is a provisioning failure, not a decision — answered 500 so Stripe
  // keeps retrying (up to 3 days) while the data is repaired. A dead
  // subscription that cannot resolve is acknowledged (nothing to provision).
  retry?: boolean;
};

const idOf = (ref: string | { id: string } | null | undefined): string | null =>
  typeof ref === "string" ? ref : ref?.id ?? null;

// ─────────────────────────────────────────────────────────────────────────
// Org resolution
// ─────────────────────────────────────────────────────────────────────────
async function resolveOrg(
  sub: Stripe.Subscription,
): Promise<{ org: OrgRow | null; conflict: string | null }> {
  const customerId = idOf(sub.customer as string | { id: string });
  const metaOrgId = (sub.metadata?.org_id as string | undefined) || null;
  const cols = "id, stripe_customer_id, stripe_subscription_id, subscription_status, subscription_tier";

  // 1. Our DB's link wins — the customer id was written by create-checkout-
  //    session before any subscription could exist for it.
  if (customerId) {
    const { data, error } = await supabaseAdmin
      .from("organizations").select(cols).eq("stripe_customer_id", customerId).maybeSingle();
    if (error) throw error;
    if (data) {
      if (metaOrgId && metaOrgId !== data.id) {
        return { org: null, conflict: `customer ${customerId} belongs to org ${data.id} but subscription metadata says ${metaOrgId}` };
      }
      return { org: data as OrgRow, conflict: null };
    }
  }

  // 2. Subscription metadata (checkout-originated subs carry org_id).
  // 3. Customer metadata (every customer our checkout creates carries org_id).
  let candidate = metaOrgId;
  if (!candidate && customerId) {
    const customer = await stripe.customers.retrieve(customerId);
    if (!("deleted" in customer && customer.deleted)) {
      candidate = ((customer as Stripe.Customer).metadata?.org_id as string | undefined) || null;
    }
  }
  if (!candidate) return { org: null, conflict: null };

  const { data, error } = await supabaseAdmin
    .from("organizations").select(cols).eq("id", candidate).maybeSingle();
  if (error) throw error;
  if (!data) return { org: null, conflict: null };
  const org = data as OrgRow;
  if (org.stripe_customer_id && customerId && org.stripe_customer_id !== customerId) {
    return { org: null, conflict: `org ${org.id} is linked to customer ${org.stripe_customer_id}, event customer is ${customerId}` };
  }
  return { org, conflict: null };
}

// ─────────────────────────────────────────────────────────────────────────
// Sync: retrieve current state → decide whether this subscription is the
// org's tracked one → write status / tier / ids.
// ─────────────────────────────────────────────────────────────────────────
async function syncSubscription(subscriptionId: string, origin: string): Promise<SyncResult> {
  const sub = await stripe.subscriptions.retrieve(subscriptionId);
  const customerId = idOf(sub.customer as string | { id: string });
  const base = { customerId, subscriptionId: sub.id };

  const { org, conflict } = await resolveOrg(sub);
  const retry = LIVE_STATUSES.has(sub.status); // v20.0.9r1 — live + unattached = retryable failure
  if (conflict) return { ...base, orgId: null, retry, note: `CONFLICT (not applied): ${conflict}` };
  if (!org) return { ...base, orgId: null, retry, note: `unresolved: no org for customer ${customerId ?? "?"} (${origin}, ${sub.status})` };

  // ONE tracked subscription per org. If the org already tracks a different
  // subscription, the event's subscription replaces it only if the tracked
  // one is no longer live — a canceled-then-replaced sequence lands correctly
  // regardless of which event arrives first, and a stale `deleted` for an old
  // subscription can never cancel a live replacement.
  if (org.stripe_subscription_id && org.stripe_subscription_id !== sub.id) {
    if (!LIVE_STATUSES.has(sub.status)) {
      return { ...base, orgId: org.id, note: `ignored: ${sub.id} is ${sub.status}; org tracks ${org.stripe_subscription_id}` };
    }
    let trackedLive = false;
    try {
      const tracked = await stripe.subscriptions.retrieve(org.stripe_subscription_id);
      trackedLive = LIVE_STATUSES.has(tracked.status);
    } catch (err) {
      // resource_missing → the tracked id no longer exists; adopt the live one.
      if ((err as Stripe.errors.StripeError)?.code !== "resource_missing") throw err;
    }
    if (trackedLive) {
      return { ...base, orgId: org.id, note: `ignored: org tracks live ${org.stripe_subscription_id}; ${sub.id} (${sub.status}) not adopted` };
    }
  }

  const priceId = sub.items?.data?.[0]?.price?.id ?? null;
  const tier = priceId ? PRICE_TO_TIER[priceId] ?? null : null;
  const status = mapStripeStatus(sub.status);

  const patch: Record<string, unknown> = {
    subscription_status: status,
    stripe_subscription_id: sub.id,
  };
  if (customerId) patch.stripe_customer_id = customerId;
  if (tier) patch.subscription_tier = tier;

  const { error } = await supabaseAdmin.from("organizations").update(patch).eq("id", org.id);
  if (error) throw error;

  const replaced = org.stripe_subscription_id && org.stripe_subscription_id !== sub.id
    ? ` (replaced ${org.stripe_subscription_id})` : "";
  const backfilled = !org.stripe_subscription_id ? " (backfilled subscription id)" : "";
  return {
    ...base, orgId: org.id,
    note: `${origin} -> ${status}/${tier ?? (priceId ? `unknown price ${priceId}` : "?")}${replaced}${backfilled}`,
  };
}

// Newer API versions carry the subscription reference under invoice.parent;
// older ones under invoice.subscription. Read both.
function subscriptionIdFromInvoice(inv: Stripe.Invoice): string | null {
  const legacy = idOf((inv as unknown as { subscription?: string | { id: string } | null }).subscription);
  if (legacy) return legacy;
  const parent = (inv as unknown as {
    parent?: { subscription_details?: { subscription?: string | { id: string } | null } | null } | null;
  }).parent;
  return idOf(parent?.subscription_details?.subscription);
}

// ─────────────────────────────────────────────────────────────────────────
// Event log — upsert on stripe_event_id so a retried event overwrites its
// own ERROR row instead of colliding with it.
// ─────────────────────────────────────────────────────────────────────────
async function logEvent(event: Stripe.Event, r: Partial<SyncResult> & { note: string }) {
  const { error } = await supabaseAdmin.from("subscription_events").upsert({
    org_id: r.orgId ?? null,
    stripe_event_id: event.id,
    event_type: event.type,
    stripe_customer_id: r.customerId ?? null,
    stripe_subscription_id: r.subscriptionId ?? null,
    payload: event as unknown,
    note: r.note,
  }, { onConflict: "stripe_event_id" });
  if (error) console.error("Failed to log subscription_event:", error.message);
}

// ─────────────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("Missing signature", { status: 400 });

  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, WEBHOOK_SECRET);
  } catch (err) {
    console.error("Signature verification failed:", (err as Error).message);
    return new Response(`Webhook Error: ${(err as Error).message}`, { status: 400 });
  }

  // Idempotency. Only an event whose processing REACHED A DECISION is
  // "seen". A failed one (ERROR:) must be reprocessed by Stripe's retry, and
  // a CONFLICT / unresolved one must be reprocessable after the data is
  // repaired (Stripe's dashboard "Resend" delivers the same event id). Two
  // concurrent deliveries of the same event can both pass this check; that
  // is benign because sync writes current state (idempotent) and the log
  // upserts.
  const { data: seen } = await supabaseAdmin
    .from("subscription_events")
    .select("id, note")
    .eq("stripe_event_id", event.id)
    .maybeSingle();
  const reprocessable = (note: string | null) => /^(ERROR:|CONFLICT|unresolved)/.test(note ?? "");
  if (seen && !reprocessable(seen.note)) {
    return new Response(JSON.stringify({ received: true, duplicate: true }), { status: 200 });
  }

  let result: Partial<SyncResult> & { note: string } = { note: "" };

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const subId = idOf(session.subscription as string | { id: string } | null);
        if (!subId) {
          result = {
            orgId: (session.metadata?.org_id as string) || null,
            customerId: idOf(session.customer as string | { id: string } | null),
            subscriptionId: null,
            note: `checkout completed without a subscription (mode=${session.mode})`,
          };
          break;
        }
        result = await syncSubscription(subId, "checkout.session.completed");
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        result = await syncSubscription(sub.id, event.type);
        break;
      }

      case "invoice.payment_failed":
      case "invoice.paid": {
        // Stripe has already moved the subscription (past_due / active) by
        // the time these fire; syncing the subscription writes that truth.
        const inv = event.data.object as Stripe.Invoice;
        const subId = subscriptionIdFromInvoice(inv);
        if (!subId) {
          result = {
            customerId: idOf(inv.customer as string | { id: string } | null),
            subscriptionId: null,
            note: `${event.type} without a subscription reference (invoice ${inv.id})`,
          };
          break;
        }
        result = await syncSubscription(subId, event.type);
        break;
      }

      default:
        result = { note: `unhandled event type: ${event.type}` };
    }
  } catch (err) {
    const note = `ERROR: ${(err as Error).message}`;
    console.error("Webhook processing error:", err);
    await logEvent(event, { ...result, note });
    return new Response(JSON.stringify({ error: note }), { status: 500 });
  }

  await logEvent(event, result);
  if (result.retry) {
    // v20.0.9r1 — provisioning did not happen for a live subscription: fail
    // loudly so Stripe retries; the seen-check above already treats this
    // row's note as reprocessable.
    return new Response(JSON.stringify({ error: result.note }), { status: 500 });
  }
  return new Response(JSON.stringify({ received: true }), { status: 200 });
});
