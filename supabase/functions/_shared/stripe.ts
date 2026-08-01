// Shared CORS headers + small helpers for all Provly billing edge functions.
// The app calls these from the browser (provly.vercel.app / localhost), so we
// need permissive-but-explicit CORS. Stripe's webhook does NOT use CORS.

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Map a Stripe price id -> our subscription_tier enum value.
// Contains BOTH modes: price ids are globally unique across test/live, so
// coexistence is safe. Live entries serve production (v20.0 flip); test
// entries are kept so test mode keeps working for development.
export const PRICE_TO_TIER: Record<string, string> = {
  // live (v20.0)
  "price_1TygurK88nWsAJ4x2YH9wKjf": "starter", // $99/mo  (live)
  "price_1TygupK88nWsAJ4xMNSGxhXV": "growth",  // $299/mo (live)
  "price_1TyguqK88nWsAJ4xN85JsfDA": "scale",   // $599/mo (live)
  // test
  "price_1TZcoKGwLlvZ0hAZhJ42EdWc": "starter", // $99/mo  (test)
  "price_1TZcpaGwLlvZ0hAZ49guorUW": "growth",  // $299/mo (test)
  "price_1TZcqYGwLlvZ0hAZ4hb39WfW": "scale",   // $599/mo (test)
};

// Option B: collapse Stripe's richer subscription statuses down to our 4-value
// subscription_status enum (trial / active / past_due / canceled).
export function mapStripeStatus(stripeStatus: string): string {
  switch (stripeStatus) {
    case "trialing":
      return "trial";
    case "active":
      return "active";
    case "past_due":
    case "incomplete":
    case "incomplete_expired":
    case "unpaid":
      return "past_due";
    case "canceled":
    case "paused":
      return "canceled";
    default:
      return "past_due";
  }
}
