-- ============================================================================
-- Provly v20.0.11 — Item 4 PR (a): identity + membership + reverse drift
-- Run in the Supabase SQL editor (production) BEFORE shipping the app file.
-- Additive and idempotent: safe to re-run. Design: docs/item4-rls-design.md
--
-- What this file does (and does NOT do):
--   D1  organizations.city/state/zip: DROP IF EXISTS (no-op on production —
--       the columns never existed there; converges fresh builds at 27 cols).
--   D2  organizations.max_clients DEFAULT 50 -> 10, existing rows realigned
--       to their tier, and a derive-only trigger so tier and cap can never
--       disagree again (10 / 50 / 250 / 500).
--   D3  VARCHAR(n) types: left as-is on purpose (see comment in provly_schema.sql).
--   R1  member_role() reads org_members by (auth.uid(), org_id()). org_members
--       is DERIVED from staff by trigger; authenticated cannot write it.
--   R2  access_tier(): manage / operate / deliver, mapped from the role labels
--       the app actually uses. Unmapped roles -> NULL (no tier). Nothing changes
--       for them in (a); PR (b) is where a NULL tier means no rows.
--   R4  can_see_person() helper (used by PR (b); defined here so (b) is policies only).
--   R6  set_staff_role / terminate_staff / reactivate_staff RPCs enforce the
--       ceiling rule; staff.role/is_active/user_id/termination_date are no
--       longer writable by the app (column privileges); organizations'
--       subscription/Stripe/max_clients columns likewise (service role only).
--   R7  accept_invite binds an EXISTING staff row when the invite carries
--       staff_id (Invite to app), otherwise creates one; the trigger makes the
--       org_members row. signup_create_organization likewise stops inserting
--       org_members directly. Nothing is ever bound by email match.
--   NO RLS policy is created or changed in this file (that is PR (b)/(c)).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- D1 — reverse drift: three base-schema columns production never had
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.organizations DROP COLUMN IF EXISTS city;
ALTER TABLE public.organizations DROP COLUMN IF EXISTS state;
ALTER TABLE public.organizations DROP COLUMN IF EXISTS zip;

-- ─────────────────────────────────────────────────────────────────────────────
-- D2 — max_clients: default 10, derived from tier, realigned
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.organizations ALTER COLUMN max_clients SET DEFAULT 10;

-- Tier -> cap. The app's TIER_META is presentation; this function is authoritative.
-- Accepts text so it works whatever the enum's labels are ('scale' vs the
-- base schema's 'professional' — the verification below prints the live labels).
CREATE OR REPLACE FUNCTION public.tier_cap(p_tier text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_tier, ''))
    WHEN 'starter'      THEN 10
    WHEN 'growth'       THEN 50
    WHEN 'scale'        THEN 250
    WHEN 'professional' THEN 250   -- base-schema label for the $599 tier
    WHEN 'enterprise'   THEN 500   -- v20.0.10b: 500, not 1,000
    ELSE 10                        -- unknown -> the conservative (Starter) cap
  END
$$;

CREATE OR REPLACE FUNCTION public.trg_org_derive_max_clients()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Derive-only: max_clients is always tier_cap(subscription_tier). Fires on
  -- INSERT and on UPDATE OF subscription_tier OR max_clients, so a manual write
  -- to max_clients is overwritten by the derivation rather than accepted.
  NEW.max_clients := public.tier_cap(NEW.subscription_tier::text);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS org_derive_max_clients ON public.organizations;
CREATE TRIGGER org_derive_max_clients
  BEFORE INSERT OR UPDATE OF subscription_tier, max_clients ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_org_derive_max_clients();

-- One-time realign (idempotent: only rows that disagree are touched; the
-- trigger above computes the value, the SET is just what fires it).
UPDATE public.organizations
SET max_clients = public.tier_cap(subscription_tier::text)
WHERE max_clients IS DISTINCT FROM public.tier_cap(subscription_tier::text);

COMMENT ON COLUMN public.organizations.max_clients IS
  'DERIVED from subscription_tier by trigger org_derive_max_clients (10/50/250/500). Not writable by the app; service role and the trigger only. v20.0.11.';

-- ─────────────────────────────────────────────────────────────────────────────
-- R1 / R2 / R4 — identity helpers
-- All STABLE SECURITY DEFINER with a pinned search_path; policies (PR b/c)
-- call them as (SELECT fn()) so Postgres evaluates once per statement.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.member_role()
RETURNS public.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT m.role
  FROM public.org_members m
  WHERE m.user_id = auth.uid()
    AND m.org_id  = public.org_id()
  LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.member_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.member_role() TO authenticated, service_role;

-- Role label -> access tier. The labels are exactly the ones the app offers
-- (STAFF_ROLES) plus supervisor/rn from ROLE_PERMISSIONS. Anything else
-- (billing, readonly, and any future enum value) maps to NULL = no tier.
CREATE OR REPLACE FUNCTION public.role_tier(p_role public.user_role)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_role::text
    WHEN 'owner'                THEN 'manage'
    WHEN 'admin'                THEN 'manage'
    WHEN 'compliance_director'  THEN 'manage'
    WHEN 'residential_director' THEN 'operate'
    WHEN 'day_program_director' THEN 'operate'
    WHEN 'house_manager'        THEN 'operate'
    WHEN 'supervisor'           THEN 'operate'
    WHEN 'rn'                   THEN 'operate'
    WHEN 'bcba'                 THEN 'operate'
    WHEN 'dsp'                  THEN 'deliver'
    WHEN 'hhs_operator'         THEN 'deliver'
    ELSE NULL
  END
$$;

CREATE OR REPLACE FUNCTION public.access_tier()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.role_tier(public.member_role())
$$;
REVOKE ALL ON FUNCTION public.access_tier() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.access_tier() TO authenticated, service_role;

-- Ceiling rank: owner 4, manage 3, operate 2, deliver 1, no tier 0.
CREATE OR REPLACE FUNCTION public.role_rank(p_role public.user_role)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_role::text = 'owner' THEN 4
    WHEN public.role_tier(p_role) = 'manage'  THEN 3
    WHEN public.role_tier(p_role) = 'operate' THEN 2
    WHEN public.role_tier(p_role) = 'deliver' THEN 1
    ELSE 0
  END
$$;

CREATE OR REPLACE FUNCTION public.my_staff_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id
  FROM public.staff s
  WHERE s.user_id = auth.uid()
    AND s.org_id  = public.org_id()
    AND s.is_active
  LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.my_staff_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_staff_id() TO authenticated, service_role;

-- R4: sight of a person. manage/operate see the org; deliver sees people they
-- hold an open person edge to, or who are placed at a site they hold an open
-- site edge to (host home). Used by PR (b) policies and the schedule->edge trigger.
CREATE OR REPLACE FUNCTION public.can_see_person(p_person_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE public.access_tier()
    WHEN 'manage'  THEN true
    WHEN 'operate' THEN true
    WHEN 'deliver' THEN EXISTS (
        SELECT 1 FROM public.staff_assignments sa
        WHERE sa.staff_id  = public.my_staff_id()
          AND sa.org_id    = public.org_id()
          AND sa.person_id = p_person_id
          AND (sa.end_date IS NULL OR sa.end_date >= CURRENT_DATE)
      ) OR EXISTS (
        SELECT 1
        FROM public.staff_assignments sa
        JOIN public.person_placements pp
          ON pp.site_id = sa.site_id AND pp.org_id = sa.org_id
        WHERE sa.staff_id  = public.my_staff_id()
          AND sa.org_id    = public.org_id()
          AND sa.site_id IS NOT NULL
          AND (sa.end_date IS NULL OR sa.end_date >= CURRENT_DATE)
          AND pp.person_id = p_person_id
          AND (pp.end_date IS NULL OR pp.end_date >= CURRENT_DATE)
      )
    ELSE false
  END
$$;
REVOKE ALL ON FUNCTION public.can_see_person(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_see_person(uuid) TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- R1 — org_members is derived from staff; last-owner guard; app cannot write it
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_staff_sync_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- A login that was unlinked (user_id changed away) loses the old membership.
  IF TG_OP = 'UPDATE' AND OLD.user_id IS NOT NULL
     AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN
    DELETE FROM public.org_members WHERE user_id = OLD.user_id AND org_id = OLD.org_id;
  END IF;

  IF NEW.user_id IS NULL THEN
    RETURN NEW;                     -- login-less staff record: no membership
  END IF;

  IF NEW.is_active AND NEW.termination_date IS NULL THEN
    INSERT INTO public.org_members (user_id, org_id, role, is_default_org)
    VALUES (NEW.user_id, NEW.org_id, NEW.role, true)
    ON CONFLICT (user_id, org_id) DO UPDATE SET role = EXCLUDED.role;
  ELSE
    DELETE FROM public.org_members WHERE user_id = NEW.user_id AND org_id = NEW.org_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS staff_sync_membership ON public.staff;
CREATE TRIGGER staff_sync_membership
  AFTER INSERT OR UPDATE OF user_id, role, is_active, termination_date, org_id ON public.staff
  FOR EACH ROW EXECUTE FUNCTION public.trg_staff_sync_membership();

-- Last-owner guard on the membership table itself, so every path (trigger,
-- RPC, service role, a human in the SQL editor) is covered.
CREATE OR REPLACE FUNCTION public.trg_org_members_last_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_losing boolean := false;
BEGIN
  -- Branch on TG_OP so NEW is never referenced in the DELETE path.
  IF TG_OP = 'DELETE' THEN
    v_losing := (OLD.role = 'owner');
  ELSIF OLD.role = 'owner' THEN
    v_losing := (NEW.role <> 'owner' OR NEW.org_id <> OLD.org_id OR NEW.user_id <> OLD.user_id);
  END IF;
  IF v_losing AND NOT EXISTS (
       SELECT 1 FROM public.org_members m
       WHERE m.org_id = OLD.org_id AND m.role = 'owner' AND m.id <> OLD.id
     ) THEN
    RAISE EXCEPTION 'An organization must keep at least one owner'
      USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS org_members_last_owner ON public.org_members;
CREATE TRIGGER org_members_last_owner
  BEFORE UPDATE OR DELETE ON public.org_members
  FOR EACH ROW EXECUTE FUNCTION public.trg_org_members_last_owner();

-- The app may read membership; only triggers/RPCs (SECURITY DEFINER, owned by
-- postgres) and the service role may write it.
REVOKE INSERT, UPDATE, DELETE ON public.org_members FROM authenticated;
GRANT  SELECT                 ON public.org_members TO   authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- R6 — column privileges: protected columns are RPC / service-role only
-- Postgres column privileges are additive, so the table-level UPDATE grant is
-- replaced by an explicit per-column grant that omits the protected set.
-- Re-runnable: it re-grants every current column except the protected ones,
-- so a column added later is covered by re-running this block.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.provly_regrant_column_updates(p_table text, p_protected text[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cols text;
BEGIN
  SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
  INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = p_table
    AND column_name <> ALL (p_protected);
  EXECUTE format('REVOKE UPDATE ON public.%I FROM authenticated', p_table);
  EXECUTE format('GRANT UPDATE (%s) ON public.%I TO authenticated', v_cols, p_table);
END;
$$;
REVOKE ALL ON FUNCTION public.provly_regrant_column_updates(text, text[]) FROM PUBLIC, anon, authenticated;

SELECT public.provly_regrant_column_updates('staff',
  ARRAY['role', 'is_active', 'user_id', 'termination_date']);

SELECT public.provly_regrant_column_updates('organizations',
  ARRAY['subscription_tier', 'subscription_status', 'trial_ends_at',
        'stripe_customer_id', 'stripe_subscription_id',
        'stripe_checkout_session_id', 'checkout_lock_at', 'max_clients']);

-- ─────────────────────────────────────────────────────────────────────────────
-- R6 — staff lifecycle RPCs with the ceiling rule
-- Caller must be owner or admin (compliance_director touches no staff records).
-- A caller may act on / grant only roles ranked strictly below their own;
-- owner may do anything, subject to the last-owner guard above.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assert_staff_ceiling(p_staff_id uuid, p_new_role public.user_role)
RETURNS public.staff
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller public.user_role := public.member_role();
  v_target public.staff;
BEGIN
  IF v_caller IS NULL OR v_caller::text NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Only owners and admins may change staff access'
      USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_target FROM public.staff
  WHERE id = p_staff_id AND org_id = public.org_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Staff record not found in your organization'
      USING ERRCODE = 'P0002';
  END IF;
  IF v_caller::text <> 'owner' THEN
    IF public.role_rank(v_target.role) >= public.role_rank(v_caller) THEN
      RAISE EXCEPTION 'You may only change staff whose role is below your own'
        USING ERRCODE = '42501';
    END IF;
    IF p_new_role IS NOT NULL AND public.role_rank(p_new_role) >= public.role_rank(v_caller) THEN
      RAISE EXCEPTION 'You may only grant roles below your own'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN v_target;
END;
$$;
REVOKE ALL ON FUNCTION public.assert_staff_ceiling(uuid, public.user_role) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_staff_role(p_staff_id uuid, p_role public.user_role)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target public.staff;
BEGIN
  IF public.role_tier(p_role) IS NULL THEN
    RAISE EXCEPTION 'Role % has no access tier and cannot be assigned', p_role
      USING ERRCODE = '22023';
  END IF;
  v_target := public.assert_staff_ceiling(p_staff_id, p_role);
  UPDATE public.staff SET role = p_role WHERE id = v_target.id;   -- trigger syncs org_members
END;
$$;
GRANT EXECUTE ON FUNCTION public.set_staff_role(uuid, public.user_role) TO authenticated;

CREATE OR REPLACE FUNCTION public.terminate_staff(p_staff_id uuid, p_termination_date date DEFAULT CURRENT_DATE)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target public.staff;
BEGIN
  v_target := public.assert_staff_ceiling(p_staff_id, NULL);
  UPDATE public.staff
  SET is_active = false, termination_date = COALESCE(p_termination_date, CURRENT_DATE)
  WHERE id = v_target.id;                                            -- trigger removes membership
END;
$$;
GRANT EXECUTE ON FUNCTION public.terminate_staff(uuid, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.reactivate_staff(p_staff_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target public.staff;
BEGIN
  v_target := public.assert_staff_ceiling(p_staff_id, NULL);
  UPDATE public.staff SET is_active = true, termination_date = NULL
  WHERE id = v_target.id;                                            -- trigger restores membership if linked
END;
$$;
GRANT EXECUTE ON FUNCTION public.reactivate_staff(uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- R7 — invites carry an optional staff_id (Invite to app for an existing record)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.invites
  ADD COLUMN IF NOT EXISTS staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.invites.staff_id IS
  'When set, acceptance links the new login to THIS staff record instead of creating one. v20.0.11.';

-- accept_invite — v20.0.3.5 body, minus the direct org_members insert (the
-- staff trigger creates it), plus the staff_id binding path.
CREATE OR REPLACE FUNCTION public.accept_invite(p_token uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id    uuid;
  v_inv        record;
  v_user_email text;
  v_constraint text;
  v_linked     integer;
BEGIN
  -- Checks and messages identical to v20.0.3.5 (the app matches on them).
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Must be authenticated to accept an invite'
      USING ERRCODE = '28000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.staff WHERE user_id = v_user_id) THEN
    RAISE EXCEPTION 'User already linked to an organization'
      USING ERRCODE = '23505';
  END IF;
  SELECT * INTO v_inv FROM public.invites WHERE id = p_token FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invite not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_inv.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invite has been revoked';
  END IF;
  IF v_inv.accepted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invite already accepted';
  END IF;
  -- v20.0.3.3/.4 — newest-pending-wins under the total order (created_at, id).
  IF EXISTS (
    SELECT 1 FROM public.invites n
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

  -- The signer-up must BE the invited address.
  SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;
  IF lower(v_user_email) IS DISTINCT FROM lower(v_inv.email) THEN
    RAISE EXCEPTION 'Invite was issued to a different email address'
      USING ERRCODE = '28000';
  END IF;

  IF v_inv.staff_id IS NOT NULL THEN
    -- (a') Bind the login to the EXISTING staff record. Role comes from the
    --      record as it stands now (an admin may have re-roled it since the
    --      invite was sent); the record must be unlinked and in this org.
    UPDATE public.staff
    SET user_id = v_user_id, is_active = true, termination_date = NULL
    WHERE id = v_inv.staff_id AND org_id = v_inv.org_id AND user_id IS NULL;
    GET DIAGNOSTICS v_linked = ROW_COUNT;
    IF v_linked <> 1 THEN
      RAISE EXCEPTION 'The staff record for this invite is missing or already has a login'
        USING ERRCODE = 'P0001';
    END IF;
  ELSE
    -- (a) New operational staff record — role comes from the invite.
    INSERT INTO public.staff (
      org_id, user_id, first_name, last_name, email,
      role, is_active, hire_date
    ) VALUES (
      v_inv.org_id, v_user_id,
      COALESCE(v_inv.first_name, ''), COALESCE(v_inv.last_name, ''), v_inv.email,
      v_inv.role, true, CURRENT_DATE
    );
  END IF;
  -- (b) Membership: created by trigger staff_sync_membership (v20.0.11).

  -- (c) JWT org_id claim — without it org_id() is NULL and RLS denies everything.
  UPDATE auth.users
  SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
    || jsonb_build_object('org_id', v_inv.org_id::text)
  WHERE id = v_user_id;

  -- (d) Consume the invite.
  UPDATE public.invites SET accepted_at = now() WHERE id = p_token;

  RETURN v_inv.org_id;
EXCEPTION
  WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint = 'idx_staff_user_id_unique' THEN
      RAISE EXCEPTION 'User already linked to an organization'
        USING ERRCODE = '23505';
    END IF;
    RAISE;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.accept_invite(uuid) TO authenticated;

-- signup_create_organization — v20.0.3.5 body minus the direct org_members
-- insert (the staff trigger creates the owner membership). max_clients is
-- left to the derive trigger.
CREATE OR REPLACE FUNCTION public.signup_create_organization(p_legal_name text, p_address text, p_phone text, p_email text, p_contract_number text, p_first_name text, p_last_name text, p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  IF EXISTS (SELECT 1 FROM public.staff WHERE user_id = v_user_id) THEN
    RAISE EXCEPTION 'User already linked to an organization'
      USING ERRCODE = '23505';
  END IF;
  -- (1) Create the org. 30-day trial timer starts NOW. Tier/status come from
  --     column defaults; max_clients is derived by trigger from the tier.
  INSERT INTO public.organizations (
    name, legal_name, address, phone, email, contract_number, trial_ends_at
  ) VALUES (
    p_legal_name, p_legal_name, p_address, p_phone, p_email, p_contract_number,
    NOW() + INTERVAL '30 days'
  )
  RETURNING id INTO v_org_id;
  -- (2) Operational staff record for the founder (owner). The staff trigger
  --     creates the org_members owner row.
  INSERT INTO public.staff (
    org_id, user_id, first_name, last_name, email,
    role, is_active, hire_date
  ) VALUES (
    v_org_id, v_user_id, p_first_name, p_last_name, p_email,
    'owner', true, CURRENT_DATE
  );
  -- (3) JWT org_id claim.
  UPDATE auth.users
  SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
    || jsonb_build_object('org_id', v_org_id::text)
  WHERE id = v_user_id;
  RETURN v_org_id;
EXCEPTION
  WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint = 'idx_staff_user_id_unique' THEN
      RAISE EXCEPTION 'User already linked to an organization'
        USING ERRCODE = '23505';
    END IF;
    RAISE;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification — ONE statement (the editor shows only the last result).
-- Every "want" is printed beside its value. Rows marked (info) are for reading,
-- not pass/fail: they tell you what to clean up before PR (b).
-- ─────────────────────────────────────────────────────────────────────────────
SELECT check_name, value, want FROM (
  SELECT 10 AS ord, 'D1 city/state/zip columns present' AS check_name,
         (SELECT count(*)::text FROM information_schema.columns
           WHERE table_name = 'organizations' AND column_name IN ('city','state','zip')) AS value,
         '0' AS want
  UNION ALL
  SELECT 20, 'D2 max_clients default',
         (SELECT column_default FROM information_schema.columns
           WHERE table_name = 'organizations' AND column_name = 'max_clients'),
         '10'
  UNION ALL
  SELECT 21, 'D2 orgs whose max_clients disagrees with tier',
         (SELECT count(*)::text FROM public.organizations
           WHERE max_clients IS DISTINCT FROM public.tier_cap(subscription_tier::text)),
         '0'
  UNION ALL
  SELECT 22, 'D2 (info) live subscription_tier enum labels',
         (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder)
           FROM pg_enum WHERE enumtypid = 'public.subscription_tier'::regtype),
         'includes the label the webhook writes for $599 (scale or professional)'
  UNION ALL
  SELECT 30, 'helpers present (member_role, access_tier, my_staff_id, can_see_person, role_tier, role_rank, tier_cap)',
         (SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public'
             AND p.proname IN ('member_role','access_tier','my_staff_id','can_see_person','role_tier','role_rank','tier_cap')),
         '7'
  UNION ALL
  SELECT 31, 'RPCs present (set_staff_role, terminate_staff, reactivate_staff, accept_invite, signup_create_organization)',
         (SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public'
             AND p.proname IN ('set_staff_role','terminate_staff','reactivate_staff','accept_invite','signup_create_organization')),
         '5'
  UNION ALL
  SELECT 40, 'triggers present (staff_sync_membership, org_members_last_owner, org_derive_max_clients)',
         (SELECT count(*)::text FROM pg_trigger
           WHERE tgname IN ('staff_sync_membership','org_members_last_owner','org_derive_max_clients') AND NOT tgisinternal),
         '3'
  UNION ALL
  SELECT 50, 'authenticated can UPDATE staff.role',
         has_column_privilege('authenticated', 'public.staff', 'role', 'UPDATE')::text, 'false'
  UNION ALL
  SELECT 51, 'authenticated can UPDATE staff.first_name',
         has_column_privilege('authenticated', 'public.staff', 'first_name', 'UPDATE')::text, 'true'
  UNION ALL
  SELECT 52, 'authenticated can UPDATE organizations.subscription_tier',
         has_column_privilege('authenticated', 'public.organizations', 'subscription_tier', 'UPDATE')::text, 'false'
  UNION ALL
  SELECT 53, 'authenticated can UPDATE organizations.legal_name',
         has_column_privilege('authenticated', 'public.organizations', 'legal_name', 'UPDATE')::text, 'true'
  UNION ALL
  SELECT 54, 'authenticated can INSERT org_members',
         has_table_privilege('authenticated', 'public.org_members', 'INSERT')::text, 'false'
  UNION ALL
  SELECT 60, 'invites.staff_id column',
         (SELECT count(*)::text FROM information_schema.columns
           WHERE table_name = 'invites' AND column_name = 'staff_id'), '1'
  UNION ALL
  SELECT 70, '(info) active staff with a role outside the tier map (re-role before PR b)',
         (SELECT coalesce(string_agg(s.first_name || ' ' || s.last_name || ' [' || s.role::text || ']', '; '), 'none')
           FROM public.staff s WHERE s.is_active AND public.role_tier(s.role) IS NULL),
         'none'
  UNION ALL
  SELECT 71, '(info) org_members rows with no linked active staff row (legacy owners; fine to keep)',
         (SELECT coalesce(string_agg(o.name || ' / ' || m.role::text, '; '), 'none')
           FROM public.org_members m
           JOIN public.organizations o ON o.id = m.org_id
           WHERE NOT EXISTS (SELECT 1 FROM public.staff s
                             WHERE s.user_id = m.user_id AND s.org_id = m.org_id AND s.is_active)),
         'read'
  UNION ALL
  SELECT 72, '(info) staff with a login vs without, per org',
         (SELECT coalesce(string_agg(o.name || ': ' || linked || ' linked / ' || unlinked || ' unlinked', '; '), 'none')
           FROM (SELECT org_id,
                        count(*) FILTER (WHERE user_id IS NOT NULL) AS linked,
                        count(*) FILTER (WHERE user_id IS NULL)     AS unlinked
                 FROM public.staff WHERE is_active GROUP BY org_id) t
           JOIN public.organizations o ON o.id = t.org_id),
         'read'
) v ORDER BY ord;
