-- ============================================================================
-- Provly v20.0.3.4 — deterministic invite ordering + pre-signup screening
-- Run in the Supabase SQL editor for project zsrnqbmzgypldraifjho.
--
-- Round-7 findings:
--  (A) get_invite did not know the superseded rule, so a stale link rendered
--      the join form and an auth ACCOUNT could be created before
--      accept_invite rejected the join. get_invite now screens superseded
--      links at lookup (reason: 'superseded'), and the app re-checks at the
--      submit instant — no account creation on a deterministically dead link.
--  (B) Timestamp ties (now() is transaction-frozen) made "newer" ambiguous,
--      leaving an obsolete higher-role invite acceptable. Ordering is now the
--      TOTAL order (created_at, id) in BOTH RPCs — ties are impossible.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_invite(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v record;
BEGIN
  SELECT i.id AS inv_id, i.org_id, i.created_at,
         i.email, i.role, i.first_name, i.last_name,
         i.expires_at, i.accepted_at, i.revoked_at,
         COALESCE(NULLIF(o.display_name,''), NULLIF(o.legal_name,''), NULLIF(o.name,'')) AS org_name
  INTO v
  FROM invites i JOIN organizations o ON o.id = i.org_id
  WHERE i.id = p_token;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'not_found');
  END IF;
  IF v.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'revoked');
  END IF;
  IF v.accepted_at IS NOT NULL THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'accepted');
  END IF;
  -- v20.0.3.4 — superseded screening BEFORE any account is created: a stale
  -- link is reported invalid at lookup, mirroring accept_invite's
  -- newest-pending-wins rule under the same deterministic total order
  -- (created_at, id) — timestamp ties cannot leave two "equally newest".
  -- Checked BEFORE expiry: when a link is both, "use the most recent invite
  -- email" is the actionable answer (a usable newer link exists), whereas
  -- "expired" sends the recipient back to their administrator for nothing.
  IF EXISTS (
    SELECT 1 FROM invites n
    WHERE n.org_id = v.org_id
      AND lower(n.email) = lower(v.email)
      AND n.accepted_at IS NULL
      AND n.revoked_at IS NULL
      AND (n.created_at > v.created_at
           OR (n.created_at = v.created_at AND n.id > v.inv_id))
  ) THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'superseded');
  END IF;
  IF v.expires_at < now() THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'expired');
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'org_name', COALESCE(v.org_name, 'your organization'),
    'email', v.email,
    'role', v.role,
    'first_name', v.first_name,
    'last_name', v.last_name,
    'expires_at', v.expires_at
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_invite(uuid) TO anon, authenticated;

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
  -- v20.0.3.3/.4 — NEWEST-PENDING-WINS (transactional, DB-side) under the
  -- deterministic total order (created_at, id) — equal timestamps cannot
  -- leave two "equally newest" invites (round-7 tie finding): if a newer
  -- pending invite exists for this org+email, this older token is dead
  -- regardless of whether the sender's post-delivery revocation succeeded.
  -- Acceptance correctness therefore never depends on edge-function cleanup
  -- — a stale higher-role link cannot confer its role, and revocation is
  -- demoted to pure hygiene. Checked BEFORE expiry, same order as
  -- get_invite, so lookup and acceptance always give the same answer.
  IF EXISTS (
    SELECT 1 FROM invites n
    WHERE n.org_id = v_inv.org_id
      AND lower(n.email) = lower(v_inv.email)
      AND n.accepted_at IS NULL
      AND n.revoked_at IS NULL
      AND (n.created_at > v_inv.created_at
           OR (n.created_at = v_inv.created_at AND n.id > v_inv.id))
  ) THEN
    RAISE EXCEPTION 'A newer invitation supersedes this one — use the most recent invite email';
  END IF;

  IF v_inv.expires_at < now() THEN
    RAISE EXCEPTION 'Invite has expired';
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
--   -- {"valid": false, "reason": "not_found"}
--   SELECT prosrc LIKE '%superseded%' AS get_guard FROM pg_proc WHERE proname='get_invite';
--   -- get_guard = true
--   SELECT prosrc LIKE '%n.id > v_inv.id%' AS tie_safe FROM pg_proc WHERE proname='accept_invite';
--   -- tie_safe = true
-- ============================================================================
