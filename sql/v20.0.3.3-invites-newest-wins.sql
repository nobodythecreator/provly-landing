-- ============================================================================
-- Provly v20.0.3.3 — newest-pending-wins acceptance (Greptile round 6)
-- Run in the Supabase SQL editor for project zsrnqbmzgypldraifjho.
--
-- Findings addressed:
--  (A) A silently-failed post-delivery revocation (supabase-js resolves with
--      { error }, it does not throw) could leave a stale pending link valid;
--      if that stale link carried a HIGHER role (resend-as-downgrade), the
--      recipient could accept the obsolete higher role.
--  (B) Two overlapping sends could each revoke "everything but mine",
--      killing both delivered links.
--
-- Structural fix: acceptance itself enforces the ordering, inside the
-- database transaction. accept_invite rejects any token when a NEWER
-- pending invite exists for the same org+email — stale links die at the
-- door whether or not any revocation ever ran. The send function's
-- companion change revokes only STRICTLY OLDER pendings, so the newest
-- invite always survives concurrent sends.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.accept_invite(p_token uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id    uuid;
  v_inv        record;
  v_user_email text;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Must be authenticated to accept an invite'
      USING ERRCODE = '28000';
  END IF;
  IF EXISTS (SELECT 1 FROM staff WHERE user_id = v_user_id) THEN
    RAISE EXCEPTION 'User already linked to an organization'
      USING ERRCODE = '23505';
  END IF;

  SELECT * INTO v_inv FROM invites WHERE id = p_token FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invite not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_inv.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invite has been revoked';
  END IF;
  IF v_inv.accepted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invite already accepted';
  END IF;
  IF v_inv.expires_at < now() THEN
    RAISE EXCEPTION 'Invite has expired';
  END IF;

  -- v20.0.3.3 — NEWEST-PENDING-WINS (transactional, DB-side): if a newer
  -- pending invite exists for this org+email, this older token is dead
  -- regardless of whether the sender's post-delivery revocation succeeded.
  -- Acceptance correctness therefore never depends on edge-function cleanup
  -- — a stale higher-role link cannot confer its role, and revocation is
  -- demoted to pure hygiene.
  IF EXISTS (
    SELECT 1 FROM invites n
    WHERE n.org_id = v_inv.org_id
      AND lower(n.email) = lower(v_inv.email)
      AND n.accepted_at IS NULL
      AND n.revoked_at IS NULL
      AND n.created_at > v_inv.created_at
  ) THEN
    RAISE EXCEPTION 'A newer invitation supersedes this one — use the most recent invite email';
  END IF;

  -- The signer-up must BE the invited address — an invite is a relationship
  -- with a specific person, not a bearer pass.
  SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;
  IF lower(v_user_email) IS DISTINCT FROM lower(v_inv.email) THEN
    RAISE EXCEPTION 'Invite was issued to a different email address'
      USING ERRCODE = '28000';
  END IF;

  -- (a) Operational staff record — role comes from the invite.
  INSERT INTO staff (
    org_id, user_id, first_name, last_name, email,
    role, is_active, hire_date
  ) VALUES (
    v_inv.org_id, v_user_id,
    COALESCE(v_inv.first_name, ''), COALESCE(v_inv.last_name, ''), v_inv.email,
    v_inv.role, true, CURRENT_DATE
  );

  -- (b) Membership record.
  INSERT INTO org_members (user_id, org_id, role, is_default_org)
  VALUES (v_user_id, v_inv.org_id, v_inv.role, true);

  -- (c) THE CRITICAL ONE (same as signup_create_organization): JWT org_id
  --     claim, without which org_id() is NULL and RLS denies everything.
  UPDATE auth.users
  SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
    || jsonb_build_object('org_id', v_inv.org_id::text)
  WHERE id = v_user_id;

  -- (d) Consume the invite.
  UPDATE invites SET accepted_at = now() WHERE id = p_token;

  RETURN v_inv.org_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.accept_invite(uuid) TO authenticated;

-- ============================================================================
-- Verify after running:
--   SELECT get_invite(gen_random_uuid());
--   -- {"valid": false, "reason": "not_found"}  (RPCs healthy)
--   SELECT prosrc LIKE '%NEWEST-PENDING-WINS%' AS guard_present
--   FROM pg_proc WHERE proname = 'accept_invite';
--   -- guard_present = true
-- ============================================================================
