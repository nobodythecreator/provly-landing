-- ============================================================================
-- Provly v20.0.3.1 — invites hardening (Greptile security review)
-- Run in the Supabase SQL editor for project zsrnqbmzgypldraifjho.
--
-- Finding: the broad same-org UPDATE policy was a conditional privilege-
-- escalation path — with default table grants, ANY org member could retarget
-- a pending invite's email/role to an accomplice, who then accepts and
-- receives the altered role (including admin).
--
-- Fix: clients get NO direct table access to invites at all. Every
-- legitimate path already works without it:
--   * send-invite edge function  -> service role (bypasses grants/RLS)
--   * get_invite / accept_invite -> SECURITY DEFINER
-- A future pending-invites UI (revoke/resend list) will read via a
-- role-gated RPC or a deliberately narrow policy — never broad grants.
-- ============================================================================

DROP POLICY IF EXISTS invites_org_update ON invites;
DROP POLICY IF EXISTS invites_org_select ON invites;

REVOKE ALL ON TABLE invites FROM anon, authenticated;

-- RLS stays ENABLED as defense-in-depth: if a grant ever reappears, the
-- (now empty) policy set still denies by default.

-- NOTE on the expired-invite deadlock (Greptile finding 3): fixed in the
-- send-invite edge function, not here — a new invite now supersedes (revokes)
-- any prior pending invite for the same org+email before inserting, so the
-- partial unique index can no longer block re-invites after expiry. The
-- index itself is unchanged and still guards concurrent-send races.

-- ============================================================================
-- Verify after running:
--   SELECT grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_name = 'invites' AND grantee IN ('anon','authenticated');
--   -- expect: 0 rows
--   SELECT polname FROM pg_policy WHERE polrelid = 'invites'::regclass;
--   -- expect: 0 rows
--   SELECT get_invite(gen_random_uuid());
--   -- still returns {"valid": false, "reason": "not_found"} (RPCs unaffected)
-- ============================================================================
