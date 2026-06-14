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

function readSubscription(sub: Stripe.Subscription) {
  const priceId = sub.items?.data?.[0]?.price?.id ?? null;
  return {
    orgId: (sub.metadata?.org_id as string) || null,
    customerId: typeof sub.customer === "string" ? sub.customer : sub.customer?.id ?? null,
    subscriptionId: sub.id,
    status: mapStripeStatus(sub.status),
    tier: priceId ? PRICE_TO_TIER[priceId] ?? null : null,
  };
}

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

  const { data: seen } = await supabaseAdmin
    .from("subscription_events")
    .select("id")
    .eq("stripe_event_id", event.id)
    .maybeSingle();
  if (seen) return new Response(JSON.stringify({ received: true, duplicate: true }), { status: 200 });

  let orgId: string | null = null;
  let customerId: string | null = null;
  let subscriptionId: string | null = null;
  let note: string | null = null;

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        orgId = (session.metadata?.org_id as string) || null;
        customerId = typeof session.customer === "string" ? session.customer : null;
        subscriptionId = typeof session.subscription === "string" ? session.subscription : null;

        if (subscriptionId) {
          const sub = await stripe.subscriptions.retrieve(subscriptionId);
          const r = readSubscription(sub);
          orgId = orgId || r.orgId;
          customerId = customerId || r.customerId;
          await applyToOrg(orgId, customerId, r.subscriptionId, r.status, r.tier);
          note = `checkout completed -> ${r.status}/${r.tier ?? "?"}`;
        }
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const r = readSubscription(sub);
        orgId = r.orgId;
        customerId = r.customerId;
        subscriptionId = r.subscriptionId;
        await applyToOrg(orgId, customerId, subscriptionId, r.status, r.tier);
        note = `${event.type} -> ${r.status}/${r.tier ?? "?"}`;
        break;
      }

      default:
        note = `unhandled event type: ${event.type}`;
    }
  } catch (err) {
    note = `ERROR: ${(err as Error).message}`;
    console.error("Webhook processing error:", err);
    await logEvent(event, orgId, customerId, subscriptionId, note);
    return new Response(JSON.stringify({ error: note }), { status: 500 });
  }

  await logEvent(event, orgId, customerId, subscriptionId, note);
  return new Response(JSON.stringify({ received: true }), { status: 200 });
});

async function applyToOrg(
  orgId: string | null,
  customerId: string | null,
  subscriptionId: string | null,
  status: string,
  tier: string | null,
) {
  const patch: Record<string, unknown> = {
    subscription_status: status,
    stripe_subscription_id: subscriptionId,
  };
  if (customerId) patch.stripe_customer_id = customerId;
  if (tier) patch.subscription_tier = tier;

  let q = supabaseAdmin.from("organizations").update(patch);
  if (orgId) {
    q = q.eq("id", orgId);
  } else if (customerId) {
    q = q.eq("stripe_customer_id", customerId);
  } else {
    throw new Error("Cannot resolve org: no org_id metadata and no customer id");
  }
  const { error } = await q;
  if (error) throw error;
}

async function logEvent(
  event: Stripe.Event,
  orgId: string | null,
  customerId: string | null,
  subscriptionId: string | null,
  note: string | null,
) {
  const { error } = await supabaseAdmin.from("subscription_events").insert({
    org_id: orgId,
    stripe_event_id: event.id,
    event_type: event.type,
    stripe_customer_id: customerId,
    stripe_subscription_id: subscriptionId,
    payload: event as unknown,
    note,
  });
  if (error) console.error("Failed to log subscription_event:", error.message);
}
