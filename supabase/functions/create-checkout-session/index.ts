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
    const { orgId, priceId, successUrl, cancelUrl } = await req.json();

    if (!orgId || !priceId) {
      return json({ error: "orgId and priceId are required" }, 400);
    }

    const { data: org, error: orgErr } = await supabaseAdmin
      .from("organizations")
      .select("id, legal_name, email, stripe_customer_id")
      .eq("id", orgId)
      .maybeSingle();

    if (orgErr || !org) {
      return json({ error: "Organization not found" }, 404);
    }

    let customerId = org.stripe_customer_id as string | null;
    if (!customerId) {
      const customer = await stripe.customers.create({
        name: org.legal_name ?? undefined,
        email: org.email ?? undefined,
        metadata: { org_id: org.id },
      });
      customerId = customer.id;
      await supabaseAdmin
        .from("organizations")
        .update({ stripe_customer_id: customerId })
        .eq("id", org.id);
    }

    const origin = req.headers.get("origin") ?? "https://getprovly.com";

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      line_items: [{ price: priceId, quantity: 1 }],
      subscription_data: { metadata: { org_id: org.id } },
      metadata: { org_id: org.id },
      allow_promotion_codes: true,
      success_url:
        successUrl ?? `${origin}/app?checkout=success&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: cancelUrl ?? `${origin}/app?checkout=cancel`,
    });

    return json({ url: session.url });
  } catch (err) {
    console.error("create-checkout-session error:", err);
    return json({ error: (err as Error).message ?? "Internal error" }, 500);
  }
});
