// v20.0.9 — CREATE CHECKOUT SESSION, HARDENED
//
// Money conduct is the software's own conduct, so this function enforces
// rather than advises:
//   1. Caller binding — the JWT's user must hold an org_members row for the
//      orgId being billed with role = owner. Keyed on user_id (immutable),
//      never email; no row = refused. (v20.0.9r1, Greptile: the email-keyed
//      staff lookup with a no-row-means-owner fallback failed OPEN for any
//      member whose auth email differed from their staff record.)
//   2. priceId whitelist — only prices in _shared PRICE_TO_TIER are sold.
//   3. Census metadata — the org's active client count and the tier rides on
//      the session AND the subscription (visible in the Stripe dashboard).
//   4. Duplicate-subscription guard — asks STRIPE (not our DB, which can be
//      stale after a portal-originated subscription) whether a live
//      subscription already exists for the customer. If so, no checkout is
//      created: the caller gets a Billing Portal URL deep-linked to the
//      plan change instead. A second checkout would otherwise create a
//      second, parallel subscription.
//   5. One open Checkout session per org (v20.0.9r1, Greptile). The org row
//      remembers its open session (stripe_checkout_session_id); a new request
//      reuses it when it is still open for the same price, expires it when
//      the price differs, and only then creates one. Steps 4–5 run under an
//      atomic compare-and-set lock on the org row (checkout_lock_at, 30s
//      stale expiry) so two simultaneous requests cannot both pass the
//      checks and each mint a payable session.
//
// Schema (sql/v20.0.9): organizations.checkout_lock_at timestamptz,
// organizations.stripe_checkout_session_id text.

import Stripe from "https://esm.sh/stripe@17.7.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, json, PRICE_TO_TIER } from "../_shared/stripe.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2026-04-22.dahlia",
  httpClient: Stripe.createFetchHttpClient(),
});

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const supabaseAdmin = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// Stripe statuses under which a subscription is live (a new checkout would
// create a parallel one). Mirrors stripe-webhook's LIVE_STATUSES.
const LIVE_STATUSES = new Set<string>([
  "active", "trialing", "past_due", "unpaid", "paused",
]);
// NOT live: canceled, incomplete_expired, incomplete — a new checkout is the
// right recovery for an incomplete one.

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  try {
    // ── 1. Caller identity ─────────────────────────────────────────────
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "Not signed in" }, 401);
    const { data: { user }, error: userErr } = await supabaseAdmin.auth.getUser(token);
    if (userErr || !user) return json({ error: "Not signed in" }, 401);

    const { orgId, priceId, successUrl, cancelUrl } = await req.json();
    if (!orgId || !priceId) {
      return json({ error: "orgId and priceId are required" }, 400);
    }

    // ── 2. priceId whitelist ───────────────────────────────────────────
    if (typeof priceId !== "string" || !Object.prototype.hasOwnProperty.call(PRICE_TO_TIER, priceId)) {
      return json({ error: "Unknown plan" }, 400);
    }
    const tier = PRICE_TO_TIER[priceId];

    // ── 1b. Membership + owner role — fail closed ──────────────────────
    // org_members is the identity-bound membership table: user_id from the
    // verified JWT, org_id = the org being billed. Anything other than an
    // owner row for exactly this pair is refused. No email, no fallback.
    const { data: member, error: memberErr } = await supabaseAdmin
      .from("org_members").select("role").eq("org_id", orgId).eq("user_id", user.id).maybeSingle();
    if (memberErr) throw memberErr;
    if (!member) return json({ error: "You can only manage billing for your own organization" }, 403);
    if (member.role !== "owner") return json({ error: "Only the account owner can change billing" }, 403);

    // ── Org + census ───────────────────────────────────────────────────
    const { data: org, error: orgErr } = await supabaseAdmin
      .from("organizations")
      .select("id, legal_name, email, stripe_customer_id, stripe_subscription_id, stripe_checkout_session_id")
      .eq("id", orgId)
      .maybeSingle();
    if (orgErr || !org) {
      return json({ error: "Organization not found" }, 404);
    }

    const { count: censusCount, error: censusErr } = await supabaseAdmin
      .from("persons")
      .select("id", { count: "exact", head: true })
      .eq("org_id", orgId)
      .eq("is_active", true);
    if (censusErr) throw censusErr;
    const census = censusCount ?? 0;

    // ── Org-scoped serialization (v20.0.9r1) ───────────────────────────
    // Atomic compare-and-set on organizations.checkout_lock_at: the UPDATE
    // only lands when the lock is free or stale (>30s — a crashed run). A
    // second simultaneous request sees zero rows and is told to retry; it
    // cannot reach the guard/session logic below concurrently.
    const lockToken = new Date().toISOString();
    // Second precision in the filter value (no "." in a PostgREST or() operand).
    const staleBefore = new Date(Date.now() - 30_000).toISOString().replace(/\.\d{3}Z$/, "Z");
    const { data: locked, error: lockErr } = await supabaseAdmin
      .from("organizations")
      .update({ checkout_lock_at: lockToken })
      .eq("id", org.id)
      .or(`checkout_lock_at.is.null,checkout_lock_at.lt.${staleBefore}`)
      .select("id");
    if (lockErr) throw lockErr;
    if (!locked || locked.length === 0) {
      return json({ error: "A checkout is already being prepared for your organization — try again in a moment" }, 409);
    }

    try {
      // ── Stripe customer (create once, persist before anything else) ────
      let customerId = org.stripe_customer_id as string | null;
      if (!customerId) {
        const customer = await stripe.customers.create({
          name: org.legal_name ?? undefined,
          email: org.email ?? undefined,
          metadata: { org_id: org.id },
        });
        customerId = customer.id;
        const { error: linkErr } = await supabaseAdmin
          .from("organizations")
          .update({ stripe_customer_id: customerId })
          .eq("id", org.id);
        if (linkErr) throw linkErr;
      }

      const origin = req.headers.get("origin") ?? "https://getprovly.com";

      // ── 4. Duplicate-subscription guard (Stripe is the source of truth) ─
      const existing = await stripe.subscriptions.list({ customer: customerId, status: "all", limit: 20 });
      const live = existing.data.find((s) => LIVE_STATUSES.has(s.status));
      if (live) {
        // Identifier backfill only (the org row may predate parity — e.g. a
        // portal-originated subscription). Status and tier stay the webhook's.
        if (!org.stripe_subscription_id) {
          const { error: bfErr } = await supabaseAdmin
            .from("organizations")
            .update({ stripe_subscription_id: live.id })
            .eq("id", org.id);
          if (bfErr) throw bfErr;
        }

        const returnUrl = `${origin}/app#/settings/subscription`;
        const item = live.items?.data?.[0];
        const samePlan = item?.price?.id === priceId;
        let url: string | null = null;

        // Deep-link the portal straight to the confirm step for the chosen
        // price. If the portal configuration rejects that flow (updates
        // disabled, price not in the portal catalog), fall back to the plain
        // portal — the customer still lands somewhere they can act.
        if (item && !samePlan) {
          try {
            const flow = await stripe.billingPortal.sessions.create({
              customer: customerId,
              return_url: returnUrl,
              flow_data: {
                type: "subscription_update_confirm",
                subscription_update_confirm: {
                  subscription: live.id,
                  items: [{ id: item.id, price: priceId, quantity: 1 }],
                },
              },
            });
            url = flow.url;
          } catch (err) {
            console.warn("portal deep-link unavailable, falling back:", (err as Error).message);
          }
        }
        if (!url) {
          const plain = await stripe.billingPortal.sessions.create({ customer: customerId, return_url: returnUrl });
          url = plain.url;
        }
        return json({ url, mode: "portal", subscriptionId: live.id, samePlan });
      }

      // ── One open Checkout session per org (v20.0.9r1) ──────────────────
      // Reuse the remembered session if Stripe says it is still open for the
      // SAME price; expire it if the price differs. After this block, no other
      // payable session for this org exists — the one created below is it.
      if (org.stripe_checkout_session_id) {
        try {
          const prior = await stripe.checkout.sessions.retrieve(org.stripe_checkout_session_id, {
            expand: ["line_items"],
          });
          if (prior.status === "open" && prior.url) {
            const priorPrice = prior.line_items?.data?.[0]?.price?.id ?? null;
            if (priorPrice === priceId) {
              return json({ url: prior.url, mode: "checkout", reused: true });
            }
            await stripe.checkout.sessions.expire(prior.id);
          }
        } catch (err) {
          // A session id Stripe no longer knows (or a transient retrieve
          // failure) must not brick checkout; the id is overwritten below.
          console.warn("prior checkout session lookup:", (err as Error).message);
        }
      }

      // ── Checkout ───────────────────────────────────────────────────────
      // Return URLs are honored only on the requesting origin; anything else
      // falls back to the default so this cannot become an open redirect.
      const sameOrigin = (u: unknown): u is string => typeof u === "string" && u.startsWith(`${origin}/`);
      const metadata = { org_id: org.id, tier, client_census: String(census) };
      const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        customer: customerId,
        line_items: [{ price: priceId, quantity: 1 }],
        subscription_data: { metadata },
        metadata,
        allow_promotion_codes: true,
        success_url: sameOrigin(successUrl)
          ? successUrl
          : `${origin}/app?checkout=success&session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: sameOrigin(cancelUrl) ? cancelUrl : `${origin}/app?checkout=cancel`,
      });

      // Remember the open session BEFORE returning the URL: the lock is still
      // held, so the next request sees it. If this write fails, the session
      // must not be handed out untracked.
      const { error: rememberErr } = await supabaseAdmin
        .from("organizations")
        .update({ stripe_checkout_session_id: session.id })
        .eq("id", org.id);
      if (rememberErr) {
        await stripe.checkout.sessions.expire(session.id).catch(() => {});
        throw rememberErr;
      }

      return json({ url: session.url, mode: "checkout" });
    } finally {
      // Release only OUR lock (compare-and-clear) — never a newer holder's.
      await supabaseAdmin
        .from("organizations")
        .update({ checkout_lock_at: null })
        .eq("id", org.id)
        .eq("checkout_lock_at", lockToken);
    }
  } catch (err) {
    console.error("create-checkout-session error:", err);
    return json({ error: (err as Error).message ?? "Internal error" }, 500);
  }
});
