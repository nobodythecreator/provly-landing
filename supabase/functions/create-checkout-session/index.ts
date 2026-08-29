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
//   5. One returned Checkout session per org (v20.0.9r1, superseded by r9).
//      The org row records the current session (stripe_checkout_session_id,
//      an observability hint); a new request expires every open session it
//      can see and mints its own — reuse across leases no longer exists.
//      Steps 4–5 run under an
//      atomic compare-and-set lock on the org row (checkout_lock_at, 30s
//      stale expiry) so two simultaneous requests cannot both pass the
//      checks and each mint a payable session. v20.0.9r3 (Greptile): the
//      lease is FENCED — the write that records a new session is conditioned
//      on still holding the lease, and a request that lost it (a Stripe
//      call outlived the 30s) expires the session it made and answers 409.
//      The remembered session id is read atomically WITH the acquire, so a
//      request cannot act on a value that predates another request's
//      commit. Correctness no longer depends on how long Stripe takes.
//      v20.0.9r4 (Greptile): EVERY write under the lease is fenced, not just
//      the session record — the customer link (a lease-loser overwriting it
//      would strand the accepted session's subscription on a customer the
//      org no longer claims, and the webhook would refuse it as a conflict)
//      and the subscription-id backfill. A fenced write that lands zero rows
//      means the lease is gone: undo what Stripe was just asked to make and
//      answer 409.
//      v20.0.9r5 (Greptile): the invariant is re-established by EVERY holder
//      from Stripe's own truth — at acquire it lists the customer's open
//      Checkout sessions and expires them (r9: all of them). The DB column
//      is a hint, not the source of truth,
//      so an orphan left by a failed compensation (Stripe refused the
//      expiry) is swept by the next request. Compensation itself retries,
//      and a request that could not compensate never returns the orphan's
//      URL — the session is unreachable until swept.
//      v20.0.9r9 (Greptile): cross-lease session REUSE is REMOVED. Both
//      round-9 races existed only because one lease could return a session a
//      different lease created. Rule now: a request only ever returns a URL
//      it minted under its own lease. Every holder expires all open sessions
//      it can see (after the r8 newer-token guard) and creates its own; a
//      stale creator's compensation therefore only ever targets its own,
//      never-returned session. The newest request wins; an older tab's link
//      dying is the correct reading of the owner's latest intent.
//      v20.0.9r8 (Greptile): every session we create is stamped with the
//      creating lease's token (metadata.lock_token). The sweep refuses to
//      touch anything when it sees a session stamped with a NEWER token —
//      that session belongs to a holder who took the lease from us, and its
//      URL may already be in the owner's hands. We answer 409 before any
//      mutation. Ordering is exact: a newer holder can only acquire after
//      our lease went stale (≥30s later), far beyond any clock skew.
//      v20.0.9r6 (Greptile): the sweep runs BEFORE the live-subscription
//      branch. An org with a live subscription (e.g. one that started a
//      checkout on trial, then subscribed through the portal) gets every
//      open session expired before the portal URL is returned — a stale
//      checkout link can no longer buy a second subscription.
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

// v20.0.9r5 (Greptile) — compensation is not best-effort. Expire a Checkout
// session with retries; a session that is already not open counts as done.
// Returns false only when Stripe would not take the expiry after three tries.
async function expireSession(id: string): Promise<boolean> {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await stripe.checkout.sessions.expire(id);
      return true;
    } catch (err) {
      const e = err as Stripe.errors.StripeError;
      if (e?.code === "resource_missing") return true;
      if (/not open|already expired|cannot be expired|status/i.test(e?.message ?? "")) return true;
      if (attempt < 2) await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
    }
  }
  return false;
}

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
      .select("id, legal_name, email, stripe_customer_id, stripe_subscription_id")
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
      .select("id, stripe_customer_id, stripe_subscription_id");
    if (lockErr) throw lockErr;
    if (!locked || locked.length === 0) {
      return json({ error: "A checkout is already being prepared for your organization — try again in a moment" }, 409);
    }

    try {
      // ── Stripe customer (create once, persist before anything else) ────
      // v20.0.9r4 — the customer id is read from the ACQUIRE, not the pre-lock
      // org fetch, for the same reason as the session id.
      let customerId = (locked[0].stripe_customer_id as string | null) ?? null;
      if (!customerId) {
        const customer = await stripe.customers.create({
          name: org.legal_name ?? undefined,
          email: org.email ?? undefined,
          metadata: { org_id: org.id },
        });
        // v20.0.9r4 — FENCED link: only under our lease and only into an
        // empty slot. Zero rows = a newer holder already linked a customer
        // (and may have an accepted session on it); ours must not replace
        // theirs. Delete the customer we made so Stripe holds no orphan.
        const { data: linked, error: linkErr } = await supabaseAdmin
          .from("organizations")
          .update({ stripe_customer_id: customer.id })
          .eq("id", org.id)
          .eq("checkout_lock_at", lockToken)
          .is("stripe_customer_id", null)
          .select("id");
        if (linkErr) {
          await stripe.customers.del(customer.id).catch(() => {});
          throw linkErr;
        }
        if (!linked || linked.length === 0) {
          await stripe.customers.del(customer.id).catch(() => {});
          return json({ error: "Checkout took too long to prepare — please try again" }, 409);
        }
        customerId = customer.id;
      }

      const origin = req.headers.get("origin") ?? "https://getprovly.com";

      // ── Open Checkout sessions: sweep, never reuse (r1, r5, r6, r8, r9) ─
      // Stripe is asked directly which Checkout sessions are OPEN for this
      // customer. r9: none survive — this request will mint its own session
      // under its own lease or hand out nothing. Before any mutation, the r8
      // guard: a session stamped by a LATER lease means a newer holder took
      // over and its URL may be in the owner's hands — 409, touch nothing.
      // Older-stamped and unstamped sessions were never returned by a live
      // request (their creators are gone or will 409 on their own fenced
      // commit) and are expired here. If an expiry is refused we do not
      // proceed to hand out anything payable: 409, the next request sweeps.
      const openSessions = await stripe.checkout.sessions.list({
        customer: customerId,
        status: "open",
        limit: 20,
      });
      for (const sess of openSessions.data) {
        const sessToken = sess.metadata?.lock_token ?? "";
        if (sessToken > lockToken) {
          return json({ error: "Checkout took too long to prepare — please try again" }, 409);
        }
      }
      for (const sess of openSessions.data) {
        if (!(await expireSession(sess.id))) {
          console.error("could not expire stray checkout session", sess.id, "for org", org.id);
          return json({ error: "Checkout could not be prepared — please try again" }, 409);
        }
      }

      // ── 4. Duplicate-subscription guard (Stripe is the source of truth) ─
      const existing = await stripe.subscriptions.list({ customer: customerId, status: "all", limit: 20 });
      const live = existing.data.find((sub) => LIVE_STATUSES.has(sub.status));
      if (live) {
        // Identifier backfill only (the org row may predate parity — e.g. a
        // portal-originated subscription). Status and tier stay the webhook's.
        // v20.0.9r4 — fenced on the lease and on the slot being empty; a zero-
        // row result is fine here (a newer holder or the webhook filled it),
        // and the portal URL below creates nothing payable either way.
        if (!locked[0].stripe_subscription_id) {
          const { error: bfErr } = await supabaseAdmin
            .from("organizations")
            .update({ stripe_subscription_id: live.id })
            .eq("id", org.id)
            .eq("checkout_lock_at", lockToken)
            .is("stripe_subscription_id", null);
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

      // ── Checkout ───────────────────────────────────────────────────────
      // Return URLs are honored only on the requesting origin; anything else
      // falls back to the default so this cannot become an open redirect.
      const sameOrigin = (u: unknown): u is string => typeof u === "string" && u.startsWith(`${origin}/`);
      // v20.0.9r8 — lock_token stamps the creating lease so a later sweep can
      // tell a newer holder's session from a stray (see header).
      const metadata = { org_id: org.id, tier, client_census: String(census), lock_token: lockToken };
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

      // v20.0.9r3 — FENCED commit. Recording the session is conditioned on
      // checkout_lock_at still being OUR token. If the lease was taken over
      // while Stripe was slow, this updates zero rows: the session we just
      // made must not be handed out — expire it and tell the caller to retry.
      // The session is recorded BEFORE its URL is returned, so the next
      // holder sees it at acquire time.
      const { data: fenced, error: rememberErr } = await supabaseAdmin
        .from("organizations")
        .update({ stripe_checkout_session_id: session.id })
        .eq("id", org.id)
        .eq("checkout_lock_at", lockToken)
        .select("id");
      if (rememberErr) {
        if (!(await expireSession(session.id))) console.error("ORPHAN checkout session (record failed, expiry refused)", session.id, "org", org.id);
        throw rememberErr;
      }
      if (!fenced || fenced.length === 0) {
        // v20.0.9r5 — the URL below is never returned on this path, so even
        // if Stripe refuses the expiry the session is unreachable; the next
        // holder's sweep expires it.
        if (!(await expireSession(session.id))) console.error("ORPHAN checkout session (lease lost, expiry refused)", session.id, "org", org.id);
        return json({ error: "Checkout took too long to prepare — please try again" }, 409);
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
