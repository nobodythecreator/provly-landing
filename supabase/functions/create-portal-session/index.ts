// v20.0.38 — CREATE PORTAL SESSION, BOUND TO THE CALLER
//
// Before v20.0.38 this function checked nobody: any request carrying the app's public key could ask
// for a Stripe Billing Portal session for any organization id it knew — where the subscription can be
// cancelled and payment details changed. It now follows the same rules as create-checkout-session:
//   1. Caller identity — a signed-in user's token, verified with the auth server.
//   2. Membership — the user must hold the OWNER row in org_members for exactly this orgId (fail closed).
//   3. Two-factor — the owner's session must be verified with an authenticator code (_shared/mfa.ts).
//   4. Return address — only an allowlisted origin (ALLOWED_ORIGINS, as in checkout); anything else
//      returns to the canonical app address.

import Stripe from "https://esm.sh/stripe@17.7.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/stripe.ts";
import { twoFactorOk, TWO_FACTOR_REFUSAL } from "../_shared/mfa.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2026-04-22.dahlia",
  httpClient: Stripe.createFetchHttpClient(),
});

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const ALLOWED_ORIGINS = new Set(
  (Deno.env.get("ALLOWED_ORIGINS") ?? "https://getprovly.com,https://www.getprovly.com")
    .split(",").map((o) => o.trim()).filter(Boolean),
);
const DEFAULT_ORIGIN = [...ALLOWED_ORIGINS][0] ?? "https://getprovly.com";
const safeReturnUrl = (u: unknown): string => {
  try {
    const url = new URL(String(u));
    return ALLOWED_ORIGINS.has(url.origin) ? url.toString() : `${DEFAULT_ORIGIN}/app`;
  } catch (_) {
    return `${DEFAULT_ORIGIN}/app`;
  }
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  try {
    // 1. who is calling
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "Not signed in" }, 401);
    const { data: { user }, error: userErr } = await supabaseAdmin.auth.getUser(token);
    if (userErr || !user) return json({ error: "Not signed in" }, 401);

    const { orgId, returnUrl } = await req.json();
    if (!orgId) return json({ error: "orgId is required" }, 400);

    // 2. the owner of exactly this organization — fail closed
    const { data: member, error: memberErr } = await supabaseAdmin
      .from("org_members").select("role").eq("org_id", orgId).eq("user_id", user.id).maybeSingle();
    if (memberErr) throw memberErr;
    if (!member) return json({ error: "You can only manage billing for your own organization" }, 403);
    if (member.role !== "owner") return json({ error: "Only the account owner can manage billing" }, 403);

    // 3. two-factor
    if (!(await twoFactorOk(token))) return json({ error: TWO_FACTOR_REFUSAL, code: "mfa_required" }, 403);

    const { data: org, error: orgErr } = await supabaseAdmin
      .from("organizations")
      .select("stripe_customer_id")
      .eq("id", orgId)
      .maybeSingle();

    if (orgErr || !org) return json({ error: "Organization not found" }, 404);
    if (!org.stripe_customer_id) {
      return json({ error: "No Stripe customer for this organization yet" }, 400);
    }

    // 4. an allowlisted return address only
    const session = await stripe.billingPortal.sessions.create({
      customer: org.stripe_customer_id as string,
      return_url: safeReturnUrl(returnUrl ?? `${DEFAULT_ORIGIN}/app`),
    });

    return json({ url: session.url });
  } catch (err) {
    console.error("create-portal-session error:", err);
    return json({ error: (err as Error).message ?? "Internal error" }, 500);
  }
});
