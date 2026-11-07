-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.42_encrypted_ssn.sql
-- Encrypted Social Security numbers (PBA SSN design, decisions 1–4)
--
--   Storage   The full number lives only in Supabase Vault (encrypted with a key kept outside the
--             database). person_ssn holds the Vault reference and the last four digits; clients can't
--             read the reference column at all.
--   Entry     The Person's PBA Manager, and the roles allowed to see SSNs, can enter or replace a number
--             (checked for impossible numbers). Entering never shows it back.
--   Reveal    Only the roles allowed to see SSNs (Owner and Compliance Director by default) — with a
--             fresh authenticator code (within 5 minutes), a written reason, and at most 10 reveals an
--             hour. Every reveal, and every refused or blocked attempt, is written to the access log
--             FIRST; the number is returned only after its log row is written.
--   Log       ssn_access_log is append-only: no update or delete, by anyone, ever. It never holds the
--             number. Readable by the roles allowed to see SSNs.
--   Roles     ssn_viewer_roles: who may see full SSNs, per organization. Only the Owner changes it (with
--             a fresh code); the Owner is always included; every change is logged. Those roles also
--             require two-factor sign-in (v20.0.38).
--   Deletion  _ssn_purge_due() deletes the number 90 days after the Person's PBA ends (daily, when
--             pg_cron is enabled); the last four stay. A viewer can delete one sooner, with a reason.
--
-- r1 (Greptile round 1, before this file ran): deleting requires the actor to be active staff of the
--   Person's organization (as entering and viewing already did); every public SSN function first checks
--   the caller can see that Person (can_see_person), so a hidden Person's last four never leak; views are
--   serialized per person viewing, so parallel requests can't get past the 10-an-hour limit; refused
--   deletions and refused role changes are logged like refused views.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction: preflight → changes → rolled-back self-test on a
-- synthetic Person → COMMIT → verification table.
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $pre$
BEGIN
  IF to_regclass('vault.secrets') IS NULL OR to_regprocedure('vault.create_secret(text, text, text, uuid)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.42 preflight: Supabase Vault is not available in this project (Database → Extensions → supabase_vault)';
  END IF;
  IF to_regclass('public.organizations') IS NULL THEN
    RAISE EXCEPTION 'v20.0.42 preflight: public.organizations not found';
  END IF;
  IF to_regprocedure('public.can_see_person(uuid)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.42 preflight: public.can_see_person(uuid) not found (Person visibility rules)';
  END IF;
  IF to_regprocedure('public._mfa_satisfied()') IS NULL THEN
    RAISE EXCEPTION 'v20.0.42 preflight: v20.0.38 (two-factor) has not run';
  END IF;
  IF to_regclass('public.person_ssn') IS NOT NULL THEN
    RAISE EXCEPTION 'v20.0.42 preflight: this migration has already run';
  END IF;
END
$pre$;

-- ── 1. Who may see full SSNs ─────────────────────────────────────────────────────────
CREATE TABLE public.ssn_viewer_roles (
  org_id    uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  role      text NOT NULL CHECK (role ~ '^[a-z_]{2,40}$'),
  added_by  uuid,
  added_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, role)
);
INSERT INTO public.ssn_viewer_roles (org_id, role)
SELECT o.id, r FROM public.organizations o CROSS JOIN unnest(ARRAY['owner', 'compliance_director']) r;

CREATE FUNCTION public.trg_ssn_viewer_roles_seed()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO ssn_viewer_roles (org_id, role) VALUES (NEW.id, 'owner'), (NEW.id, 'compliance_director')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER ssn_viewer_roles_seed AFTER INSERT ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_ssn_viewer_roles_seed();

-- ── 2. The number (in Vault) and its last four ───────────────────────────────────────
CREATE TABLE public.person_ssn (
  person_id       uuid PRIMARY KEY,
  org_id          uuid NOT NULL,
  secret_id       uuid,                  -- the Vault secret; NULL once the number is deleted
  last4           text NOT NULL CHECK (last4 ~ '^[0-9]{4}$'),
  entered_by      uuid,
  entered_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  deleted_reason  text,
  CONSTRAINT person_ssn_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id) ON DELETE CASCADE
);

-- ── 3. The access log: append-only, never the number ─────────────────────────────────
CREATE TABLE public.ssn_access_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL,
  person_id       uuid,
  actor_staff_id  uuid,
  actor_role      text,
  action          text NOT NULL CHECK (action IN ('enter', 'replace', 'reveal', 'denied', 'blocked', 'delete', 'purge', 'roles_changed')),
  ok              boolean NOT NULL,
  reason          text,
  detail          text,
  at              timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ssn_access_log_org_at ON public.ssn_access_log (org_id, at);
CREATE INDEX ssn_access_log_actor_at ON public.ssn_access_log (actor_staff_id, at);

CREATE FUNCTION public.trg_ssn_access_log_append_only()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'The SSN access log can''t be changed or deleted';
END;
$$;
CREATE TRIGGER ssn_access_log_append_only BEFORE UPDATE OR DELETE ON public.ssn_access_log
  FOR EACH ROW EXECUTE FUNCTION public.trg_ssn_access_log_append_only();
CREATE TRIGGER ssn_access_log_no_truncate BEFORE TRUNCATE ON public.ssn_access_log
  FOR EACH STATEMENT EXECUTE FUNCTION public.trg_ssn_access_log_append_only();

-- ── 4. Helpers ──────────────────────────────────────────────────────────────────────
CREATE FUNCTION public._ssn_is_viewer(p_org uuid, p_role text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT p_role IS NOT NULL AND EXISTS (SELECT 1 FROM ssn_viewer_roles v WHERE v.org_id = p_org AND v.role = p_role)
$$;

-- A verified session whose authenticator code was entered within the last 5 minutes (the "amr" claim
-- Supabase puts in the signed token records when each method was used).
CREATE FUNCTION public._ssn_fresh_code()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(auth.jwt() -> 'amr') = 'array' THEN auth.jwt() -> 'amr' ELSE '[]'::jsonb END) m
                  WHERE m ->> 'method' = 'totp'
                    AND (m ->> 'timestamp') ~ '^[0-9]+$'
                    AND (m ->> 'timestamp')::bigint >= extract(epoch FROM clock_timestamp())::bigint - 300)
$$;

CREATE FUNCTION public._ssn_log(p_org uuid, p_person uuid, p_actor uuid, p_role text, p_action text, p_ok boolean, p_reason text, p_detail text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  INSERT INTO ssn_access_log (org_id, person_id, actor_staff_id, actor_role, action, ok, reason, detail)
  VALUES (p_org, p_person, p_actor, p_role, p_action, p_ok, nullif(btrim(coalesce(p_reason, '')), ''), p_detail)
$$;

-- Nine digits that SSA could have issued: no 000, 666 or 900-999 area; no 00 group; no 0000 serial.
CREATE FUNCTION public._ssn_valid(p_digits text)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_digits ~ '^[0-9]{9}$'
     AND substr(p_digits, 1, 3) NOT IN ('000', '666') AND substr(p_digits, 1, 1) <> '9'
     AND substr(p_digits, 4, 2) <> '00' AND substr(p_digits, 6, 4) <> '0000'
$$;

-- ── 5. Enter / replace ──────────────────────────────────────────────────────────────
CREATE FUNCTION public._ssn_set(p_person uuid, p_ssn text, p_actor uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org    uuid;
  v_digits text := regexp_replace(coalesce(p_ssn, ''), '[^0-9]', '', 'g');
  v_row    person_ssn;
  v_has    boolean;
  v_secret uuid;
  a        record;
  v_may    boolean;
BEGIN
  SELECT org_id INTO v_org FROM persons WHERE id = p_person;
  IF v_org IS NULL OR p_actor IS NULL
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = v_org AND s.is_active) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Not permitted');
  END IF;
  v_may := public._ssn_is_viewer(v_org, p_role);
  IF NOT v_may AND to_regprocedure('public._pba_access(uuid, uuid, text)') IS NOT NULL THEN
    SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_role);
    v_may := coalesce(a.o_write, false);                       -- the Person's PBA Manager
  END IF;
  IF NOT v_may THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'denied', false, NULL, 'enter: role not permitted');
    RETURN jsonb_build_object('ok', false, 'error', 'Only this Person''s PBA Manager, or a role allowed to see SSNs, can enter it');
  END IF;
  IF NOT public._ssn_valid(v_digits) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'That isn''t a valid Social Security number — check the digits');
  END IF;

  SELECT * INTO v_row FROM person_ssn WHERE person_id = p_person FOR UPDATE;
  v_has := FOUND;
  IF v_has AND v_row.secret_id IS NOT NULL THEN
    PERFORM vault.update_secret(v_row.secret_id, v_digits);
    UPDATE person_ssn SET last4 = right(v_digits, 4), entered_by = p_actor, updated_at = now(),
                          deleted_at = NULL, deleted_reason = NULL
     WHERE person_id = p_person;
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'replace', true, NULL, NULL);
  ELSE
    v_secret := vault.create_secret(v_digits, 'provly-ssn-' || p_person::text || '-' || gen_random_uuid()::text, 'Provly: Social Security number');
    IF v_has THEN
      UPDATE person_ssn SET secret_id = v_secret, last4 = right(v_digits, 4), entered_by = p_actor, updated_at = now(),
                            deleted_at = NULL, deleted_reason = NULL
       WHERE person_id = p_person;
    ELSE
      INSERT INTO person_ssn (person_id, org_id, secret_id, last4, entered_by)
      VALUES (p_person, v_org, v_secret, right(v_digits, 4), p_actor);
    END IF;
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'enter', true, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('ok', true, 'last4', right(v_digits, 4));
END;
$$;

-- ── 6. Reveal ───────────────────────────────────────────────────────────────────────
CREATE FUNCTION public._ssn_reveal(p_person uuid, p_reason text, p_actor uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org    uuid;
  v_row    person_ssn;
  v_n      integer;
  v_digits text;
BEGIN
  SELECT org_id INTO v_org FROM persons WHERE id = p_person;
  IF v_org IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Not permitted'); END IF;
  -- every refusal is logged and returned (never raised), so the log row is kept
  IF p_actor IS NULL OR NOT public._ssn_is_viewer(v_org, p_role)
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = v_org AND s.is_active) THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'denied', false, p_reason, 'reveal: role not permitted');
    RETURN jsonb_build_object('ok', false, 'error', 'Your role can''t see full Social Security numbers');
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'denied', false, p_reason, 'reveal: no reason');
    RETURN jsonb_build_object('ok', false, 'error', 'Give a reason for viewing the number');
  END IF;
  IF NOT public._ssn_fresh_code() THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'denied', false, p_reason, 'reveal: no fresh authenticator code');
    RETURN jsonb_build_object('ok', false, 'needs_code', true, 'error', 'Enter a fresh code from your authenticator app');
  END IF;
  -- r1 — one view at a time per person viewing, held until this transaction ends (through the log write),
  -- so parallel requests can't all count the same nine
  PERFORM pg_advisory_xact_lock(hashtext('provly-ssn-reveal'), hashtext(p_actor::text));
  SELECT count(*) INTO v_n FROM ssn_access_log
   WHERE actor_staff_id = p_actor AND action = 'reveal' AND ok AND at > clock_timestamp() - interval '1 hour';
  IF v_n >= 10 THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'blocked', false, p_reason, 'reveal: more than 10 in an hour');
    RETURN jsonb_build_object('ok', false, 'error', 'Too many numbers viewed in the last hour — this has been recorded for the Owner');
  END IF;
  SELECT * INTO v_row FROM person_ssn WHERE person_id = p_person;
  IF NOT FOUND OR v_row.secret_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No Social Security number is on file');
  END IF;
  PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'reveal', true, p_reason, NULL);   -- the log comes first
  SELECT decrypted_secret INTO v_digits FROM vault.decrypted_secrets WHERE id = v_row.secret_id;
  IF v_digits IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'The number couldn''t be read'); END IF;
  RETURN jsonb_build_object('ok', true, 'ssn', substr(v_digits, 1, 3) || '-' || substr(v_digits, 4, 2) || '-' || substr(v_digits, 6, 4));
END;
$$;

-- ── 7. Delete (a viewer, with a fresh code and a reason) and the 90-day purge ─────────
CREATE FUNCTION public._ssn_delete(p_person uuid, p_reason text, p_actor uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org uuid;
  v_row person_ssn;
BEGIN
  SELECT org_id INTO v_org FROM persons WHERE id = p_person;
  IF v_org IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Not permitted'); END IF;
  -- r1 — the actor must be active staff of this Person's organization, as for entering and viewing
  IF p_actor IS NULL OR NOT public._ssn_is_viewer(v_org, p_role)
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = v_org AND s.is_active) THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'denied', false, p_reason, 'delete: role not permitted');
    RETURN jsonb_build_object('ok', false, 'error', 'Your role can''t delete Social Security numbers');
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'denied', false, p_reason, 'delete: no reason');
    RETURN jsonb_build_object('ok', false, 'error', 'Give a reason for deleting the number');
  END IF;
  IF NOT public._ssn_fresh_code() THEN
    PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'denied', false, p_reason, 'delete: no fresh authenticator code');
    RETURN jsonb_build_object('ok', false, 'needs_code', true, 'error', 'Enter a fresh code from your authenticator app');
  END IF;
  SELECT * INTO v_row FROM person_ssn WHERE person_id = p_person FOR UPDATE;
  IF NOT FOUND OR v_row.secret_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'No Social Security number is on file'); END IF;
  DELETE FROM vault.secrets WHERE id = v_row.secret_id;
  UPDATE person_ssn SET secret_id = NULL, deleted_at = now(), deleted_reason = btrim(p_reason), updated_at = now() WHERE person_id = p_person;
  PERFORM public._ssn_log(v_org, p_person, p_actor, p_role, 'delete', true, p_reason, NULL);
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- 90 days after a Person's PBA ends, their number is deleted (the last four stay). Returns how many.
CREATE FUNCTION public._ssn_purge_due()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  r   record;
  v_n integer := 0;
BEGIN
  FOR r IN
    SELECT s.person_id, s.org_id, s.secret_id, e.ended_on
      FROM person_ssn s JOIN pba_enrollments e ON e.person_id = s.person_id
     WHERE s.secret_id IS NOT NULL AND e.ended_on IS NOT NULL AND e.ended_on + 90 <= current_date
     FOR UPDATE OF s
  LOOP
    DELETE FROM vault.secrets WHERE id = r.secret_id;
    UPDATE person_ssn SET secret_id = NULL, deleted_at = now(), deleted_reason = '90 days after PBA ended ' || r.ended_on::text, updated_at = now()
     WHERE person_id = r.person_id;
    PERFORM public._ssn_log(r.org_id, r.person_id, NULL, NULL, 'purge', true, NULL, 'PBA ended ' || r.ended_on::text);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;

-- ── 8. Who may see SSNs — changed only by the Owner, with a fresh code ─────────────────
CREATE FUNCTION public._ssn_set_viewer_roles(p_roles text[], p_actor uuid, p_role text, p_org uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_old text;
  v_new text[];
BEGIN
  IF p_org IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Not permitted'); END IF;
  IF p_actor IS NULL OR p_role IS DISTINCT FROM 'owner'
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = p_org AND s.is_active) THEN
    PERFORM public._ssn_log(p_org, NULL, p_actor, p_role, 'denied', false, NULL, 'roles: not the Owner');
    RETURN jsonb_build_object('ok', false, 'error', 'Only the Owner can change who sees Social Security numbers');
  END IF;
  IF NOT public._ssn_fresh_code() THEN
    PERFORM public._ssn_log(p_org, NULL, p_actor, p_role, 'denied', false, NULL, 'roles: no fresh authenticator code');
    RETURN jsonb_build_object('ok', false, 'needs_code', true, 'error', 'Enter a fresh code from your authenticator app');
  END IF;
  SELECT array_agg(DISTINCT r ORDER BY r) INTO v_new FROM unnest(coalesce(p_roles, ARRAY[]::text[])) r WHERE r ~ '^[a-z_]{2,40}$';
  IF v_new IS NULL OR NOT ('owner' = ANY (v_new)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'The Owner always keeps access');
  END IF;
  SELECT string_agg(role, ', ' ORDER BY role) INTO v_old FROM ssn_viewer_roles WHERE org_id = p_org;
  DELETE FROM ssn_viewer_roles WHERE org_id = p_org AND NOT (role = ANY (v_new));
  INSERT INTO ssn_viewer_roles (org_id, role, added_by) SELECT p_org, r, p_actor FROM unnest(v_new) r ON CONFLICT DO NOTHING;
  PERFORM public._ssn_log(p_org, NULL, p_actor, p_role, 'roles_changed', true, NULL, coalesce(v_old, '') || ' → ' || array_to_string(v_new, ', '));
  RETURN jsonb_build_object('ok', true, 'roles', to_jsonb(v_new));
END;
$$;

-- Roles allowed to see SSNs also need two-factor sign-in (v20.0.38 rule, widened)
CREATE OR REPLACE FUNCTION public._mfa_required_for(p_user uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT EXISTS (SELECT 1 FROM org_members m
                  WHERE m.user_id = p_user
                    AND (m.role::text = ANY (public._mfa_roles())
                         OR EXISTS (SELECT 1 FROM ssn_viewer_roles v WHERE v.org_id = m.org_id AND v.role = m.role::text)))
$$;

-- ── 9. Public functions (identity from the access helpers, so two-factor applies) ──────
-- r1 — every public SSN function first checks the caller can see this Person (the same rule as reading
-- the Person); a hidden or another organization's Person gets "not permitted", logged for that Person.
CREATE FUNCTION public._ssn_hidden(p_person uuid, p_what text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org uuid;
BEGIN
  IF public.can_see_person(p_person) THEN RETURN NULL; END IF;
  SELECT org_id INTO v_org FROM persons WHERE id = p_person;
  IF v_org IS NOT NULL AND p_what IS NOT NULL THEN
    PERFORM public._ssn_log(v_org, p_person, public.my_staff_id(), public.member_role()::text, 'denied', false, NULL, p_what || ': Person not visible');
  END IF;
  RETURN jsonb_build_object('ok', false, 'error', 'Not permitted');
END;
$$;
CREATE FUNCTION public.ssn_set(p_person uuid, p_ssn text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(public._ssn_hidden(p_person, 'enter'), public._ssn_set(p_person, p_ssn, public.my_staff_id(), public.member_role()::text))
$$;
CREATE FUNCTION public.ssn_reveal(p_person uuid, p_reason text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(public._ssn_hidden(p_person, 'reveal'), public._ssn_reveal(p_person, p_reason, public.my_staff_id(), public.member_role()::text))
$$;
CREATE FUNCTION public.ssn_delete(p_person uuid, p_reason text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(public._ssn_hidden(p_person, 'delete'), public._ssn_delete(p_person, p_reason, public.my_staff_id(), public.member_role()::text))
$$;
CREATE FUNCTION public.ssn_viewer_roles_set(p_roles text[]) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._ssn_set_viewer_roles(p_roles, public.my_staff_id(), public.member_role()::text, public.org_id()) $$;

-- What the signed-in user may do with this Person's number (never the number itself)
CREATE FUNCTION public.ssn_status(p_person uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org   uuid := public.org_id();
  v_role  text := public.member_role()::text;
  v_staff uuid := public.my_staff_id();
  v_row   person_ssn;
  v_has   boolean;
  a       record;
  v_write boolean := false;
BEGIN
  -- r1 — only for a Person this caller can see
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM persons p WHERE p.id = p_person AND p.org_id = v_org)
     OR NOT public.can_see_person(p_person) THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO v_row FROM person_ssn WHERE person_id = p_person;
  v_has := FOUND;                                   -- before the access check below changes FOUND
  IF to_regprocedure('public._pba_access(uuid, uuid, text)') IS NOT NULL AND v_staff IS NOT NULL THEN
    SELECT * INTO a FROM public._pba_access(p_person, v_staff, v_role);
    v_write := coalesce(a.o_write, false);
  END IF;
  RETURN jsonb_build_object('ok', true,
    'on_file', v_has AND v_row.secret_id IS NOT NULL,
    'last4', CASE WHEN v_has THEN v_row.last4 END,
    'deleted_at', CASE WHEN v_has THEN v_row.deleted_at END,
    'can_enter', public._ssn_is_viewer(v_org, v_role) OR v_write,
    'can_reveal', public._ssn_is_viewer(v_org, v_role),
    'is_owner', v_role = 'owner');
END;
$$;

-- ── 10. Access (RLS) and grants ─────────────────────────────────────────────────────
DO $rls$
BEGIN
  ALTER TABLE public.person_ssn ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ssn_access_log ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ssn_viewer_roles ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON public.person_ssn, public.ssn_access_log, public.ssn_viewer_roles FROM PUBLIC, anon, authenticated;
  -- the last four and dates — never the Vault reference
  GRANT SELECT (person_id, org_id, last4, entered_at, updated_at, deleted_at) ON public.person_ssn TO authenticated;
  GRANT SELECT ON public.ssn_access_log, public.ssn_viewer_roles TO authenticated;
  CREATE POLICY person_ssn_read ON public.person_ssn FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id()) AND EXISTS (SELECT 1 FROM public.persons p WHERE p.id = person_ssn.person_id));
  CREATE POLICY ssn_access_log_read ON public.ssn_access_log FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id()) AND public._ssn_is_viewer(org_id, (SELECT public.member_role())::text));
  CREATE POLICY ssn_viewer_roles_read ON public.ssn_viewer_roles FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL);
END
$rls$;

DO $fn$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('trg_ssn_viewer_roles_seed', 'trg_ssn_access_log_append_only', '_ssn_is_viewer', '_ssn_fresh_code', '_ssn_log',
                         '_ssn_valid', '_ssn_set', '_ssn_reveal', '_ssn_delete', '_ssn_purge_due', '_ssn_set_viewer_roles', '_mfa_required_for',
                         'ssn_set', 'ssn_reveal', 'ssn_delete', 'ssn_viewer_roles_set', 'ssn_status', '_ssn_hidden')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    -- _ssn_is_viewer is used by the access-log policy, which runs as the signed-in user (it reveals nothing)
    IF f.proname IN ('ssn_set', 'ssn_reveal', 'ssn_delete', 'ssn_viewer_roles_set', 'ssn_status', '_ssn_is_viewer') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
  END LOOP;
END
$fn$;

-- Daily purge, when pg_cron is enabled (Database → Extensions). If it isn't, the verification says so.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('provly-ssn-purge', '17 9 * * *', 'SELECT public._ssn_purge_due()');
  END IF;
END
$cron$;

NOTIFY pgrst, 'reload schema';

-- ── 11. Self-test — a synthetic Person, rolled back ─────────────────────────────────
CREATE OR REPLACE FUNCTION pg_temp.v20042_test_insert(p_table text, p_given jsonb)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_rel  regclass := ('public.' || p_table)::regclass;
  v_cols text := '';
  v_vals text := '';
  k      text;
  v_typ  text;
  c      record;
  v_id   uuid;
BEGIN
  FOR k IN SELECT jsonb_object_keys(p_given) LOOP
    SELECT format_type(a.atttypid, a.atttypmod) INTO v_typ
      FROM pg_attribute a WHERE a.attrelid = v_rel AND a.attname = k AND NOT a.attisdropped;
    v_cols := v_cols || ', ' || quote_ident(k);
    v_vals := v_vals || ', ' || CASE WHEN jsonb_typeof(p_given->k) = 'null' THEN 'NULL'
                                     ELSE quote_literal(p_given->>k) END || '::' || v_typ;
  END LOOP;
  FOR c IN
    SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ, t.typtype, t.typcategory, a.atttypid
      FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
     WHERE a.attrelid = v_rel AND a.attnum > 0 AND NOT a.attisdropped AND a.attnotnull
       AND NOT a.atthasdef AND a.attidentity = '' AND a.attgenerated = ''
       AND NOT (p_given ? a.attname::text)
  LOOP
    v_cols := v_cols || ', ' || quote_ident(c.attname);
    v_vals := v_vals || ', ' || CASE
      WHEN c.typtype = 'e' THEN format('(SELECT e.enumlabel FROM pg_enum e WHERE e.enumtypid = %s ORDER BY e.enumsortorder LIMIT 1)::%s', c.atttypid, c.typ)
      WHEN c.typ = 'date' THEN '''1990-01-01''::date'
      WHEN c.typ LIKE 'timestamp%' THEN 'now()'
      WHEN c.typ LIKE 'time%' THEN '''00:00''::time'
      WHEN c.typ = 'boolean' THEN 'false'
      WHEN c.typcategory = 'N' THEN '0'
      WHEN c.typ IN ('jsonb', 'json') THEN '''{}''::' || c.typ
      WHEN c.typ = 'uuid' THEN 'gen_random_uuid()'
      WHEN c.typcategory = 'A' THEN '''{}''::' || c.typ
      ELSE quote_literal('v20.0.42 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $test$
DECLARE
  v_org    uuid;
  v_owner  uuid;
  v_ouser  uuid;
  v_person uuid;
  r        jsonb;
  i        integer;
  v_secret uuid;
  v_now    bigint := extract(epoch FROM clock_timestamp())::bigint;
BEGIN
  SELECT m.org_id, s.id, m.user_id INTO v_org, v_owner, v_ouser
    FROM org_members m JOIN staff s ON s.user_id = m.user_id AND s.org_id = m.org_id AND s.is_active
   WHERE m.role::text = 'owner' ORDER BY s.id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'SELFTEST FAIL 0: no active owner to test with'; END IF;

  BEGIN
    v_person := pg_temp.v20042_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20042', 'last_name', 'Selftest',
                                                                            'identification_number', '099999942', 'is_active', true));
    -- a verified session with a fresh code
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ouser, 'role', 'authenticated', 'aal', 'aal2', 'org_id', v_org,
      'app_metadata', json_build_object('org_id', v_org), 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', v_now)))::text, true);

    -- 1. impossible numbers are refused; a valid one is stored in Vault with only the last four outside it
    r := public._ssn_set(v_person, '000-12-3456', v_owner, 'owner');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 1: an impossible number (area 000) was accepted'; END IF;
    r := public._ssn_set(v_person, '987-65-4321', v_owner, 'owner');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 1b: an impossible number (area 9xx) was accepted'; END IF;
    r := public._ssn_set(v_person, '123-45-6788', v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean OR r ->> 'last4' <> '6788' THEN RAISE EXCEPTION 'SELFTEST FAIL 1c: a valid number was refused: %', r; END IF;
    SELECT secret_id INTO v_secret FROM person_ssn WHERE person_id = v_person;
    IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE id = v_secret AND decrypted_secret = '123456788') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 1d: the number is not in Vault';
    END IF;
    IF EXISTS (SELECT 1 FROM ssn_access_log WHERE person_id = v_person AND (coalesce(reason, '') || coalesce(detail, '')) LIKE '%123%45%6788%') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 1e: the number reached the access log';
    END IF;

    -- 2. a viewer with a fresh code and a reason sees it — and the reveal is logged
    r := public._ssn_reveal(v_person, 'self-test', v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean OR r ->> 'ssn' <> '123-45-6788' THEN RAISE EXCEPTION 'SELFTEST FAIL 2: reveal failed: %', r; END IF;
    IF NOT EXISTS (SELECT 1 FROM ssn_access_log WHERE person_id = v_person AND action = 'reveal' AND ok) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 2b: the reveal was not logged';
    END IF;

    -- 3. refused: no reason; a role that can't see SSNs; a stale code — each logged
    r := public._ssn_reveal(v_person, '', v_owner, 'owner');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 3: revealed without a reason'; END IF;
    r := public._ssn_reveal(v_person, 'self-test', v_owner, 'dsp');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 3b: revealed to a role that can''t see SSNs'; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ouser, 'role', 'authenticated', 'aal', 'aal2', 'org_id', v_org,
      'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', v_now - 3600)))::text, true);
    r := public._ssn_reveal(v_person, 'self-test', v_owner, 'owner');
    IF (r ->> 'ok')::boolean OR NOT coalesce((r ->> 'needs_code')::boolean, false) THEN RAISE EXCEPTION 'SELFTEST FAIL 3c: revealed with an hour-old code'; END IF;
    IF (SELECT count(*) FROM ssn_access_log WHERE person_id = v_person AND action = 'denied') < 3 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3d: refused attempts were not all logged';
    END IF;

    -- 4. replacing updates Vault; more than 10 reveals an hour is blocked (and logged)
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ouser, 'role', 'authenticated', 'aal', 'aal2', 'org_id', v_org,
      'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', v_now)))::text, true);
    r := public._ssn_set(v_person, '123-45-6799', v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 4: replace failed'; END IF;
    FOR i IN 1..9 LOOP
      r := public._ssn_reveal(v_person, 'self-test', v_owner, 'owner');
      IF NOT (r ->> 'ok')::boolean OR r ->> 'ssn' <> '123-45-6799' THEN RAISE EXCEPTION 'SELFTEST FAIL 4b: reveal % failed: %', i, r; END IF;
    END LOOP;
    r := public._ssn_reveal(v_person, 'self-test', v_owner, 'owner');
    IF (r ->> 'ok')::boolean OR NOT EXISTS (SELECT 1 FROM ssn_access_log WHERE person_id = v_person AND action = 'blocked') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4c: the 11th reveal in an hour was not blocked and logged';
    END IF;

    -- 5. the log can't be changed or deleted
    BEGIN
      UPDATE ssn_access_log SET reason = 'changed' WHERE person_id = v_person;
      RAISE EXCEPTION 'SELFTEST FAIL 5: the access log was changed';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      DELETE FROM ssn_access_log WHERE person_id = v_person;
      RAISE EXCEPTION 'SELFTEST FAIL 5b: the access log was deleted from';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 6a. deleting: someone not on this organization's staff can't, even with the Owner role; a
    --     refused deletion (no reason) is logged
    r := public._ssn_delete(v_person, 'self-test', gen_random_uuid(), 'owner');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 6a: someone outside the organization deleted a number'; END IF;
    r := public._ssn_delete(v_person, '', v_owner, 'owner');
    IF (r ->> 'ok')::boolean OR NOT EXISTS (SELECT 1 FROM ssn_access_log WHERE person_id = v_person AND action = 'denied' AND detail = 'delete: no reason') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6b: a refused deletion was not logged';
    END IF;

    -- 6. deleting with a reason removes it from Vault; the last four stay
    SELECT secret_id INTO v_secret FROM person_ssn WHERE person_id = v_person;
    r := public._ssn_delete(v_person, 'self-test', v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean OR EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret)
       OR NOT EXISTS (SELECT 1 FROM person_ssn WHERE person_id = v_person AND secret_id IS NULL AND last4 = '6799') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6: delete did not remove the number from Vault (or lost the last four)';
    END IF;

    -- 7. 90 days after PBA ends, the number is purged
    r := public._ssn_set(v_person, '123-45-6711', v_owner, 'owner');
    INSERT INTO pba_enrollments (org_id, person_id, fiduciary_type, started_on, ended_on)
    VALUES (v_org, v_person, 'ssa_payee', current_date - 400, current_date - 91);
    IF public._ssn_purge_due() < 1 OR EXISTS (SELECT 1 FROM person_ssn WHERE person_id = v_person AND secret_id IS NOT NULL) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 7: the number outlived its 90 days';
    END IF;

    -- 8. only the Owner, with a fresh code, changes who may see SSNs, and the Owner always stays
    r := public._ssn_set_viewer_roles(ARRAY['compliance_director'], v_owner, 'owner', v_org);
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 8: the Owner was removed from SSN access'; END IF;
    r := public._ssn_set_viewer_roles(ARRAY['owner', 'compliance_director', 'admin'], v_owner, 'compliance_director', v_org);
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 8b: someone other than the Owner changed SSN access'; END IF;
    r := public._ssn_set_viewer_roles(ARRAY['owner', 'compliance_director', 'admin'], v_owner, 'owner', v_org);
    IF NOT (r ->> 'ok')::boolean OR NOT EXISTS (SELECT 1 FROM ssn_viewer_roles WHERE org_id = v_org AND role = 'admin') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 8c: the Owner could not add a role';
    END IF;

    -- 9. without a signed-in session nothing is revealed
    PERFORM set_config('request.jwt.claims', '{}', true);
    r := public.ssn_reveal(v_person, 'self-test');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 9: revealed without a session'; END IF;

    RAISE EXCEPTION 'SELFTEST_ROLLBACK' USING ERRCODE = 'PRVOK';
  EXCEPTION WHEN SQLSTATE 'PRVOK' THEN
    NULL;  -- every self-test write above, including the Vault secrets, is rolled back here
  END;
END
$test$;

SELECT set_config('request.jwt.claims', '{}', true);

COMMIT;

-- ── Verification table (paste this result into the PR and the chat) ─────────────────
SELECT n, check_name, got, want,
       CASE WHEN want = '(information)' THEN 'ℹ️' WHEN got = want THEN '✅' ELSE '❌' END AS ok FROM (
  SELECT 1 n, 'SSN tables with RLS' check_name,
    (SELECT count(*) FROM pg_class WHERE relname IN ('person_ssn', 'ssn_access_log', 'ssn_viewer_roles') AND relrowsecurity)::text got, '3' want
  UNION ALL SELECT 2, 'Clients cannot read the Vault reference',
    has_column_privilege('authenticated', 'public.person_ssn', 'secret_id', 'SELECT')::text, 'false'
  UNION ALL SELECT 3, 'Clients cannot write SSN tables directly',
    (has_table_privilege('authenticated', 'public.person_ssn', 'INSERT') OR has_table_privilege('authenticated', 'public.person_ssn', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.ssn_access_log', 'INSERT') OR has_table_privilege('authenticated', 'public.ssn_viewer_roles', 'INSERT'))::text, 'false'
  UNION ALL SELECT 4, 'Access log is append-only (update/delete/truncate refused)',
    (SELECT count(*) FROM pg_trigger WHERE tgname IN ('ssn_access_log_append_only', 'ssn_access_log_no_truncate') AND NOT tgisinternal)::text, '2'
  UNION ALL SELECT 5, 'Public SSN functions for signed-in users (not anon)',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('ssn_set', 'ssn_reveal', 'ssn_delete', 'ssn_viewer_roles_set', 'ssn_status')
       AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE'))::text, '5'
  UNION ALL SELECT 6, 'Internal SSN functions callable by clients',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('_ssn_fresh_code', '_ssn_log', '_ssn_valid', '_ssn_set', '_ssn_reveal',
                                                    '_ssn_delete', '_ssn_purge_due', '_ssn_set_viewer_roles', '_ssn_hidden')
       AND (has_function_privilege('authenticated', oid, 'EXECUTE') OR has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  UNION ALL SELECT 7, 'Roles allowed to see SSNs (Hope Haven)',
    (SELECT string_agg(role, ', ' ORDER BY role) FROM ssn_viewer_roles WHERE org_id = '00000000-0000-0000-0000-000000000001'), 'compliance_director, owner'
  UNION ALL SELECT 8, 'Those roles require two-factor sign-in',
    (position('ssn_viewer_roles' IN pg_get_functiondef('public._mfa_required_for(uuid)'::regprocedure)) > 0)::text, 'true'
  UNION ALL SELECT 9, 'Self-test leftovers (synthetic Person / numbers in Vault)',
    ((SELECT count(*) FROM persons WHERE identification_number = '099999942')::text || '/' ||
     (SELECT count(*) FROM vault.secrets WHERE description = 'Provly: Social Security number')::text), '0/0'
  UNION ALL SELECT 11, 'Views serialized per person viewing (hourly limit holds)',
    (position('pg_advisory_xact_lock' IN pg_get_functiondef('public._ssn_reveal(uuid, text, uuid, text)'::regprocedure)) > 0)::text, 'true'
  UNION ALL SELECT 12, 'Public SSN functions check Person visibility',
    ((SELECT count(*) FROM pg_proc WHERE proname IN ('ssn_set', 'ssn_reveal', 'ssn_delete') AND position('_ssn_hidden' IN pg_get_functiondef(oid)) > 0)
     + (SELECT count(*) FROM pg_proc WHERE proname = 'ssn_status' AND position('can_see_person' IN pg_get_functiondef(oid)) > 0))::text, '4'
  UNION ALL SELECT 10, 'Daily 90-day purge scheduled (needs pg_cron enabled)',
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN 'scheduled' ELSE 'pg_cron not enabled' END), '(information)'
) t
ORDER BY n;
