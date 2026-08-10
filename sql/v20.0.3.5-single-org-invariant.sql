-- ============================================================================
-- Provly v20.0.3.5 — single-organization invariant (Greptile round 9)
-- Run in the Supabase SQL editor for project zsrnqbmzgypldraifjho.
--
-- Finding (reproduced): concurrent acceptance of invitations to two DIFFERENT
-- organizations could attach one user to both tenants. Each accept_invite
-- transaction checked "does this user have a staff row?" BEFORE locking its
-- own (different) invite row — a check-then-act race: both checks pass while
-- zero staff rows exist, both commit, dual membership results.
--
-- Fix: a DATABASE INVARIANT, not request serialization. staff.user_id is now
-- UNIQUE (partial index — NULL user_ids, i.e. login-less staff records,
-- remain unrestricted and unlimited). Both membership-creating RPCs insert
-- the staff row first, so under any interleaving the losing transaction hits
-- the unique index and rolls back ENTIRELY (staff + org_members + JWT claim
-- update — all atomic). Exactly one organization wins; the loser receives
-- the same friendly error as the sequential case. The identical race in
-- signup_create_organization (signup-vs-accept, signup-vs-signup) is closed
-- by the same index; both functions gain a handler that maps the violation
-- to the friendly message (other unique violations re-raise untouched).
--
-- NOTE for Provly 2.0 (multi-org / portable record): this invariant encodes
-- the CURRENT product truth — one login, one organization. Multi-org
-- membership is a deliberate future design that will revisit this index
-- alongside claim-switching; do not silently drop it before then.
-- ============================================================================

-- (0) Pre-flight: existing duplicates would block the index. Expect 0 rows;
--     if any appear, STOP and report them before proceeding.
SELECT user_id, count(*) AS rows
FROM staff WHERE user_id IS NOT NULL
GROUP BY user_id HAVING count(*) > 1;

-- (1) The invariant.
CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_user_id_unique
  ON staff(user_id) WHERE user_id IS NOT NULL;

-- (2) accept_invite — identical to v20.0.3.4 plus the violation handler.
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
  v_constraint text;
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
EXCEPTION
  WHEN unique_violation THEN
    -- v20.0.3.5 — the single-org invariant (unique index on staff.user_id)
    -- resolves concurrent membership creation at commit: the losing
    -- transaction lands here and its inserts are all rolled back atomically.
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint = 'idx_staff_user_id_unique' THEN
      RAISE EXCEPTION 'User already linked to an organization'
        USING ERRCODE = '23505';
    END IF;
    RAISE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.accept_invite(uuid) TO authenticated;

-- (3) signup_create_organization — identical to v20.0.2 plus the handler.
CREATE OR REPLACE FUNCTION public.signup_create_organization(p_legal_name text, p_address text, p_phone text, p_email text, p_contract_number text, p_first_name text, p_last_name text, p_user_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_org_id  uuid;
  v_constraint text;
BEGIN
  v_user_id := COALESCE(auth.uid(), p_user_id);
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No user_id available (neither session nor parameter)'
      USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_user_id) THEN
    RAISE EXCEPTION 'User does not exist in auth.users'
      USING ERRCODE = '23503';
  END IF;
  IF EXISTS (SELECT 1 FROM staff WHERE user_id = v_user_id) THEN
    RAISE EXCEPTION 'User already linked to an organization'
      USING ERRCODE = '23505';
  END IF;
  -- (1) Create the org. 30-day trial timer starts NOW.
  --     v20.0.2: subscription_tier and subscription_status are intentionally
  --     NOT set here — the organizations column DEFAULTs ('starter'/'trial')
  --     are the single source of truth. max_clients matches Starter's cap.
  INSERT INTO organizations (
    name, legal_name, address, phone, email, contract_number,
    trial_ends_at, max_clients
  ) VALUES (
    p_legal_name, p_legal_name, p_address, p_phone, p_email, p_contract_number,
    NOW() + INTERVAL '30 days', 10
  )
  RETURNING id INTO v_org_id;
  -- (2) Operational staff record
  INSERT INTO staff (
    org_id, user_id, first_name, last_name, email,
    role, is_active, hire_date
  ) VALUES (
    v_org_id, v_user_id, p_first_name, p_last_name, p_email,
    'owner', true, CURRENT_DATE
  );
  -- (3) Membership record (org_members is the canonical membership table)
  INSERT INTO org_members (
    user_id, org_id, role, is_default_org
  ) VALUES (
    v_user_id, v_org_id, 'owner', true
  );
  -- (4) THE CRITICAL ONE: update app_metadata.org_id so the JWT carries
  --     the org_id claim. Without this, org_id() returns NULL and RLS
  --     denies the user access to their own org's data.
  --     Merge with any existing app_metadata to preserve provider info.
  UPDATE auth.users
  SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
    || jsonb_build_object('org_id', v_org_id::text)
  WHERE id = v_user_id;
  RETURN v_org_id;
EXCEPTION
  WHEN unique_violation THEN
    -- v20.0.3.5 — the single-org invariant (unique index on staff.user_id)
    -- resolves concurrent membership creation at commit: the losing
    -- transaction lands here and its inserts are all rolled back atomically.
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint = 'idx_staff_user_id_unique' THEN
      RAISE EXCEPTION 'User already linked to an organization'
        USING ERRCODE = '23505';
    END IF;
    RAISE;
END;
$function$;

-- ============================================================================
-- Verify after running:
--   SELECT indexname FROM pg_indexes
--   WHERE tablename = 'staff' AND indexname = 'idx_staff_user_id_unique';
--   -- 1 row
--   SELECT get_invite(gen_random_uuid());
--   -- {"valid": false, "reason": "not_found"}  (RPCs healthy)
--   SELECT prosrc LIKE '%idx_staff_user_id_unique%' AS handler_present
--   FROM pg_proc WHERE proname = 'accept_invite';
--   -- handler_present = true
-- ============================================================================
