-- ============================================================================
-- Provly v20.0.3 — email invites: table + pre-auth lookup + acceptance
-- Run in the Supabase SQL editor for project zsrnqbmzgypldraifjho
-- AFTER the org_members/staff role diagnostic has been reviewed.
--
-- The invite primitive of Phase 1.5: one mechanism that invites staff today,
-- HHS operators (Items 3-4, via `scope`) next, and care-circle members
-- (v20.5) after that. An invite establishes a RELATIONSHIP; access flows
-- from it. It never grants ownership.
-- ============================================================================

-- (1) The invites table. The row id IS the invite token (unguessable uuid).
CREATE TABLE IF NOT EXISTS invites (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email       text NOT NULL,
  first_name  text,
  last_name   text,
  role        user_role NOT NULL DEFAULT 'dsp'
              CHECK (role <> 'owner'),  -- enum-typed (per live-DB diagnostic): an
                                        -- invalid role fails at SEND time, not at
                                        -- acceptance; ownership is never invitable
  scope       jsonb NOT NULL DEFAULT '{}'::jsonb,  -- empty for staff; carries site/individual
                                                   -- scoping for HHS operators (Items 3-4) and
                                                   -- care-circle context (v20.5)
  invited_by  uuid,                                -- auth user id of the inviter
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL DEFAULT now() + interval '7 days',
  accepted_at timestamptz,
  revoked_at  timestamptz
);

CREATE INDEX IF NOT EXISTS idx_invites_org ON invites(org_id, created_at DESC);

-- One PENDING invite per (org, email) — re-inviting after expiry/revoke is fine.
CREATE UNIQUE INDEX IF NOT EXISTS idx_invites_pending_unique
  ON invites(org_id, lower(email))
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- RLS: org members manage their own org's invites (mirrors subscription_events
-- pattern). The send-invite edge function uses the service role (bypasses RLS);
-- anonymous token lookup goes through get_invite() below, never the table.
ALTER TABLE invites ENABLE ROW LEVEL SECURITY;

CREATE POLICY invites_org_select ON invites
  FOR SELECT USING (org_id = org_id());

CREATE POLICY invites_org_update ON invites
  FOR UPDATE USING (org_id = org_id()) WITH CHECK (org_id = org_id());

-- (2) Pre-auth lookup: "you've been invited to <org> as <role>".
--     SECURITY DEFINER + limited jsonb payload — reveals nothing beyond what
--     the invite email itself already says, and only to a token holder.
CREATE OR REPLACE FUNCTION public.get_invite(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v record;
BEGIN
  SELECT i.email, i.role, i.first_name, i.last_name,
         i.expires_at, i.accepted_at, i.revoked_at,
         COALESCE(NULLIF(o.display_name,''), NULLIF(o.legal_name,''), o.name) AS org_name
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
  IF v.expires_at < now() THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'expired');
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'org_name', v.org_name,
    'email', v.email,
    'role', v.role,
    'first_name', v.first_name,
    'last_name', v.last_name
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_invite(uuid) TO anon, authenticated;

-- (3) Acceptance: called AFTER auth signup/login by the invited user.
--     Mirrors signup_create_organization steps 2-4 (staff row, org_members
--     row, JWT org_id claim) but JOINS the inviting org instead of creating
--     one. Same SECURITY DEFINER discipline.
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
--   (a) SELECT count(*) FROM invites;                       -- 0 rows, no error
--   (b) SELECT get_invite(gen_random_uuid());               -- {"valid":false,"reason":"not_found"}
--   (c) Full loop: tested end-to-end via the send-invite edge function +
--       ?invite= signup path (Item 2 test plan).
-- ============================================================================
