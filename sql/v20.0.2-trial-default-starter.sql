-- ============================================================================
-- Provly v20.0.2 — new-org trial defaults to Starter ($99), not Growth
-- Run in the Supabase SQL editor for project zsrnqbmzgypldraifjho.
--
-- Two sources were defining the signup tier:
--   (a) organizations.subscription_tier column DEFAULT ('growth')
--   (b) signup_create_organization() hardcoding 'growth' in its INSERT —
--       which bypasses (a) entirely.
-- This migration leaves exactly ONE source of truth: the column defaults.
-- ============================================================================

-- (1) Column defaults govern the signup tier/status.
--     (Tier ALTER already applied 2026-08-02; idempotent — safe to re-run.)
ALTER TABLE organizations ALTER COLUMN subscription_tier   SET DEFAULT 'starter';
ALTER TABLE organizations ALTER COLUMN subscription_status SET DEFAULT 'trial';

-- (2) Signup function: stop hardcoding subscription_tier / subscription_status
--     (column defaults apply); max_clients 50 → 10 to match Starter's cap.
--     Everything else is byte-identical to the previous definition.
CREATE OR REPLACE FUNCTION public.signup_create_organization(p_legal_name text, p_address text, p_phone text, p_email text, p_contract_number text, p_first_name text, p_last_name text, p_user_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_org_id  uuid;
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
END;
$function$;

-- ============================================================================
-- Verify after running:
--   (a) SELECT column_name, column_default FROM information_schema.columns
--       WHERE table_name='organizations'
--       AND column_name IN ('subscription_tier','subscription_status');
--       -- expect 'starter' / 'trial'
--   (b) SELECT prosrc FROM pg_proc WHERE proname='signup_create_organization';
--       -- expect NO 'growth' anywhere in the body
--   (c) Empirical: fresh incognito signup shows "Starter · $99/mo · Trial",
--       usage cap /10.
-- ============================================================================
