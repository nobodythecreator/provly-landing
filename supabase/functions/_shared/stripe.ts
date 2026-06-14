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
// TEST-MODE ids. When flipping to live, swap these for the live price_ ids
// (this is the only code change at go-live besides the keys).
export const PRICE_TO_TIER: Record<string, string> = {
  "price_1TZcoKGwLlvZ0hAZhJ42EdWc": "starter", // $99/mo
  "price_1TZcpaGwLlvZ0hAZ49guorUW": "growth",  // $299/mo
  "price_1TZcqYGwLlvZ0hAZ4hb39WfW": "scale",   // $599/mo
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
