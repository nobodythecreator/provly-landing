// v20.0.38 — the two-factor rule, for edge functions that act with the service key.
//
// The service key skips the database's access rules, so a function that uses it must ask the same
// question every database request answers on its own: may this caller proceed? It asks with the
// CALLER's own token (sql/v20.0.38_two_factor.sql, mfa_ok()), so the answer comes from their signed
// session: true for roles that don't need two-factor, and for the Owner / Compliance Director only
// once their session has been verified with an authenticator code.
//
// Fails closed: any error — a network failure, or the v20.0.38 SQL not having been run — refuses.
import { createClient } from "npm:@supabase/supabase-js@2";

export async function twoFactorOk(jwt: string): Promise<boolean> {
  try {
    const asCaller = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const { data, error } = await asCaller.rpc("mfa_ok");
    return !error && data === true;
  } catch (_) {
    return false;
  }
}

export const TWO_FACTOR_REFUSAL =
  "Two-factor verification required — sign out and sign back in with your authenticator code.";
