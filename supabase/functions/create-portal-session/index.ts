import Stripe from "https://esm.sh/stripe@17.7.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/stripe.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2026-04-22.dahlia",
  httpClient: Stripe.createFetchHttpClient(),
});

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  try {
    const { orgId, returnUrl } = await req.json();
    if (!orgId) return json({ error: "orgId is required" }, 400);

    const { data: org, error: orgErr } = await supabaseAdmin
      .from("organizations")
      .select("stripe_customer_id")
      .eq("id", orgId)
      .maybeSingle();

    if (orgErr || !org) return json({ error: "Organization not found" }, 404);
    if (!org.stripe_customer_id) {
      return json({ error: "No Stripe customer for this organization yet" }, 400);
    }

    const origin = req.headers.get("origin") ?? "https://getprovly.com";
    const session = await stripe.billingPortal.sessions.create({
      customer: org.stripe_customer_id as string,
      return_url: returnUrl ?? `${origin}/app`,
    });

    return json({ url: session.url });
  } catch (err) {
    console.error("create-portal-session error:", err);
    return json({ error: (err as Error).message ?? "Internal error" }, 500);
  }
});
