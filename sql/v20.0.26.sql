-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.26 — authorizations become 1056 rows (docs/authorizations-design.md v1.0, Decisions A, D1)
--   Columns    person_service_authorizations gains approval_id (DSPD's Approval ID),
--              unit_kind (the 1056's Kind: D daily · Q quarter hour · S per session ·
--              M monthly; NULL = the code table's unit) and max_units_per_month (the
--              1056's Max Billable Units). authorized_units now means the 1056's
--              "Annual Units": the units for the row's own date range.
--              Existing rows: max_units_per_month is copied from authorized_units the
--              first time this file runs (those values were entered as monthly maxes);
--              authorized_units itself is left alone until the rows are re-entered
--              from the 1056s.
--   Counters   used units count in the row's Kind (falling back to the code table);
--              provly_auth_used_in_month(auth, month) is the "this month" counter, and
--              person_service_authorizations_v gains used_this_month (current month,
--              Mountain Time), unit_kind_effective and the three new columns.
--   Code table PBA → per session (the 1056 bills PBA as S).
--   D1         a front-line note whose date no authorization covers still saves when
--              the client has had that code before (a non-rejected row starting on or
--              before the note's date): the budget lapsed or the SC hasn't entered the
--              renewal yet. A code the client never had is still refused. Coverage now
--              means the same thing in the note rule and the payment file: a row that
--              isn't rejected and whose dates include the day (an 'expired' row covers
--              its own dates; v20.0.21 excluded it). notes_without_authorization(ids)
--              tells a manager which notes have no covering row; the answer is computed
--              on read, so it clears on its own once the rows are entered.
--   Duplicates the identical-row guard (v20.0.10) now compares the new fields too.
--   Audit      every authorization insert, edit and delete by a signed-in user is
--              written to audit_log (auth_added / auth_changed / auth_deleted); the
--              used-units recount is not an edit and isn't logged.
--   Payment    the e520 engine fills S lines: one unit per approved note (session),
--              capped by the month's max and remaining units like every other kind;
--              for an EVV code, the lesser of notes and EVV visits.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction: it
-- stops before changing anything if production is missing something it builds on,
-- and rolls back completely if any self-test check fails. The last statement is the
-- verification table — paste it into chat.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- a valid "nobody signed in" state for this transaction (the editor can hold the claims as an empty string)
SELECT set_config('request.jwt.claims', '{}', true);

-- ── 0. Preflight: what this file builds on must be live ─────────────────
DO $$
DECLARE
  v_missing text[] := '{}';
  v_typ     oid;
  x         text;
BEGIN
  FOREACH x IN ARRAY ARRAY[
    'public.access_tier()', 'public.org_id()', 'public.member_role()', 'public.can_see_person(uuid)',
    'public.e520_round_q(numeric)', 'public.e520_caller_org(uuid)',
    'public.e520_hap_billing_auth(uuid,uuid,uuid,date,date)',
    'public.e520_day_units(uuid,uuid,text,uuid,text,boolean,date)',
    'public.e520_fill_line(uuid,uuid,jsonb,integer)', 'public.e520_build(text,text,uuid)',
    'public.provly_auth_used_units(uuid,uuid,uuid,date,date,uuid)',
    'public.provly_recompute_auth_units(uuid,uuid,uuid,date)',
    'public.provly_recompute_monthly_auths(uuid,uuid)']
  LOOP
    IF to_regprocedure(x) IS NULL THEN v_missing := v_missing || ('function ' || x); END IF;
  END LOOP;
  FOREACH x IN ARRAY ARRAY[
    'person_service_authorizations.psa_used_units', 'person_service_authorizations.trg_psa_reject_identical',
    'person_service_authorizations.psa_billed_guard', 'service_notes.service_notes_deliver_auth',
    'service_notes.service_note_auth_update']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                    WHERE t.tgrelid = to_regclass('public.' || split_part(x, '.', 1))
                      AND t.tgname = split_part(x, '.', 2) AND NOT t.tgisinternal) THEN
      v_missing := v_missing || ('trigger ' || x);
    END IF;
  END LOOP;
  FOREACH x IN ARRAY ARRAY[
    'e520_lines.authorization_id', 'e520_lines.released_at', 'e520_line_notes.released',
    'service_notes.context_id', 'service_notes.transport', 'service_notes.duration_minutes',
    'person_absences.start_date', 'persons.discharge_date']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = split_part(x, '.', 1)
                      AND column_name = split_part(x, '.', 2)) THEN
      v_missing := v_missing || ('column ' || x);
    END IF;
  END LOOP;
  IF to_regclass('public.person_service_authorizations_v') IS NULL THEN
    v_missing := v_missing || 'view person_service_authorizations_v'::text;
  END IF;
  IF to_regclass('public.service_delivery_context_members') IS NULL THEN
    v_missing := v_missing || 'table service_delivery_context_members'::text;
  END IF;
  SELECT a.atttypid INTO v_typ FROM pg_attribute a
   WHERE a.attrelid = 'public.service_code_definitions'::regclass AND a.attname = 'billing_unit';
  FOREACH x IN ARRAY ARRAY['per_session', 'monthly'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_enum e WHERE e.enumtypid = v_typ AND e.enumlabel = x) THEN
      v_missing := v_missing || ('billing unit label ' || x);
    END IF;
  END LOOP;
  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'v20.0.26 stopped before changing anything — production is missing: %. Paste this message into chat.',
      array_to_string(v_missing, '; ');
  END IF;
END $$;

-- ── 1. The 1056 columns ───────────────────────────────────────────────────
DO $$
DECLARE
  v_first_run boolean;
BEGIN
  v_first_run := NOT EXISTS (SELECT 1 FROM information_schema.columns
                              WHERE table_schema = 'public' AND table_name = 'person_service_authorizations'
                                AND column_name = 'max_units_per_month');
  ALTER TABLE public.person_service_authorizations
    ADD COLUMN IF NOT EXISTS approval_id text,
    ADD COLUMN IF NOT EXISTS unit_kind text,
    ADD COLUMN IF NOT EXISTS max_units_per_month integer;
  -- the current rows were entered as monthly maxes: that value is the row's monthly max
  IF v_first_run THEN
    UPDATE public.person_service_authorizations SET max_units_per_month = authorized_units;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'psa_unit_kind_valid') THEN
    ALTER TABLE public.person_service_authorizations
      ADD CONSTRAINT psa_unit_kind_valid CHECK (unit_kind IS NULL OR unit_kind IN ('D', 'Q', 'S', 'M'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'psa_max_units_nonneg') THEN
    ALTER TABLE public.person_service_authorizations
      ADD CONSTRAINT psa_max_units_nonneg CHECK (max_units_per_month IS NULL OR max_units_per_month >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'psa_approval_id_not_blank') THEN
    ALTER TABLE public.person_service_authorizations
      ADD CONSTRAINT psa_approval_id_not_blank CHECK (approval_id IS NULL OR btrim(approval_id) <> '');
  END IF;
END $$;

COMMENT ON COLUMN public.person_service_authorizations.approval_id IS
  'v20.0.26: the 1056''s Approval ID — DSPD''s service/rate approval number, shared across clients (not a per-client id).';
COMMENT ON COLUMN public.person_service_authorizations.unit_kind IS
  'v20.0.26: the 1056''s Kind — D daily, Q quarter hour, S per session, M monthly. NULL = the code table''s billing unit.';
COMMENT ON COLUMN public.person_service_authorizations.max_units_per_month IS
  'v20.0.26: the 1056''s Max Billable Units — the cap per calendar month, in the row''s Kind.';
COMMENT ON COLUMN public.person_service_authorizations.authorized_units IS
  'v20.0.26: the 1056''s "Annual Units" — total units for this row''s own start–end dates (not a calendar or plan year), in the row''s Kind.';

-- ── 2. Code table: PBA is billed per session ─────────────────────────────
UPDATE public.service_code_definitions
   SET billing_unit = 'per_session'
 WHERE code = 'PBA' AND billing_unit::text IS DISTINCT FROM 'per_session';

-- ── 3. Kind: the row's own, else the code table's ────────────────────────
-- D daily · Q quarter hour · S per session (per_trip counts the same way) · M monthly · H hourly (code table only)
CREATE OR REPLACE FUNCTION public.provly_auth_kind(p_kind text, p_code_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT coalesce(p_kind,
           (SELECT CASE c.billing_unit::text
                     WHEN 'quarter_hour' THEN 'Q'
                     WHEN 'daily'        THEN 'D'
                     WHEN 'per_session'  THEN 'S'
                     WHEN 'per_trip'     THEN 'S'
                     WHEN 'monthly'      THEN 'M'
                     WHEN 'hourly'       THEN 'H'
                   END
              FROM service_code_definitions c WHERE c.id = p_code_id))
$$;

-- ── 4. Used units in the row's Kind ──────────────────────────────────────
-- HAP (and any monthly code) keeps v20.0.24a r6: months billed under this authorization,
-- now limited to the months inside the dates asked for (so the same function answers
-- "this month"); MTP keeps DSG ride days. Everything else counts by Kind:
--   Q each day's minutes to the nearest quarter hour · D days with a note · S notes ·
--   M months with a note · H each day's minutes to the nearest hour.
CREATE OR REPLACE FUNCTION public.provly_auth_used_units(p_org uuid, p_person uuid, p_code_id uuid, p_start date, p_end date, p_auth uuid, p_kind text)
RETURNS integer
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_code  text;
  v_unit  text;
  v_kind  text;
  v_lo    date := coalesce(p_start, '-infinity'::date);
  v_hi    date := coalesce(p_end, 'infinity'::date);
  v_units integer := 0;
BEGIN
  SELECT c.code, c.billing_unit::text INTO v_code, v_unit FROM service_code_definitions c WHERE c.id = p_code_id;
  IF v_code IS NULL OR p_person IS NULL THEN RETURN 0; END IF;
  v_kind := public.provly_auth_kind(p_kind, p_code_id);

  IF v_code = 'HAP' OR v_unit = 'monthly' THEN
    SELECT count(DISTINCT date_trunc('month', l.start_date))::integer INTO v_units
      FROM e520_lines l JOIN e520_batches b ON b.id = l.batch_id
     WHERE l.org_id = p_org AND l.person_id = p_person AND l.service_code = v_code
       AND l.authorization_id = p_auth
       AND l.action <> 'remove' AND l.released_at IS NULL AND b.status = 'uploaded'
       AND date_trunc('month', l.start_date) >= date_trunc('month', v_lo)
       AND date_trunc('month', l.start_date) <= v_hi;
  ELSIF v_code = 'MTP' THEN
    SELECT count(DISTINCT n.service_date)::integer INTO v_units
      FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
     WHERE n.org_id = p_org AND n.person_id = p_person AND c.code = 'DSG'
       AND n.status IN ('approved', 'billed') AND coalesce(n.transport, 'to_and_from') <> 'none'
       AND n.service_date BETWEEN v_lo AND v_hi;
  ELSIF v_kind = 'Q' THEN
    SELECT coalesce(sum(e520_round_q(d.m)), 0)::integer INTO v_units
      FROM (SELECT n.service_date, sum(coalesce(n.duration_minutes, 0)) AS m
              FROM service_notes n
             WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
               AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi
             GROUP BY n.service_date) d;
  ELSIF v_kind = 'H' THEN
    SELECT coalesce(sum(round(d.m / 60.0)), 0)::integer INTO v_units
      FROM (SELECT n.service_date, sum(coalesce(n.duration_minutes, 0)) AS m
              FROM service_notes n
             WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
               AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi
             GROUP BY n.service_date) d;
  ELSIF v_kind = 'D' THEN
    SELECT count(DISTINCT n.service_date)::integer INTO v_units
      FROM service_notes n
     WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
       AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi;
  ELSIF v_kind = 'M' THEN
    SELECT count(DISTINCT date_trunc('month', n.service_date))::integer INTO v_units
      FROM service_notes n
     WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
       AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi;
  ELSE
    -- S (per session): one per approved note
    SELECT count(*)::integer INTO v_units
      FROM service_notes n
     WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
       AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi;
  END IF;
  RETURN coalesce(v_units, 0);
END;
$$;

-- the v20.0.24a signature stays for any caller that doesn't pass a Kind: it reads the row's
CREATE OR REPLACE FUNCTION public.provly_auth_used_units(p_org uuid, p_person uuid, p_code_id uuid, p_start date, p_end date, p_auth uuid)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT public.provly_auth_used_units(p_org, p_person, p_code_id, p_start, p_end, p_auth,
           (SELECT a.unit_kind FROM person_service_authorizations a WHERE a.id = p_auth))
$$;

-- "this month": the units a row used inside one calendar month (its dates clipped to the
-- month); NULL when the row doesn't reach into that month; 0 for a rejected row.
-- SECURITY DEFINER so the read view can show it to every tier; a signed-in caller only
-- gets an answer for a row they can see.
CREATE OR REPLACE FUNCTION public.provly_auth_used_in_month(p_auth uuid, p_month date)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r     record;
  v_m0  date := date_trunc('month', p_month)::date;
  v_m1  date;
BEGIN
  v_m1 := (v_m0 + interval '1 month' - interval '1 day')::date;
  SELECT a.id, a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.status::text AS st, a.unit_kind
    INTO r
    FROM person_service_authorizations a WHERE a.id = p_auth;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF auth.uid() IS NOT NULL
     AND NOT (r.org_id = public.org_id() AND public.member_role() IS NOT NULL AND public.can_see_person(r.person_id)) THEN
    RETURN NULL;
  END IF;
  IF (r.start_date IS NOT NULL AND r.start_date > v_m1) OR (r.end_date IS NOT NULL AND r.end_date < v_m0) THEN
    RETURN NULL;
  END IF;
  IF r.st = 'rejected' THEN RETURN 0; END IF;
  RETURN public.provly_auth_used_units(r.org_id, r.person_id, r.service_code_id,
           greatest(coalesce(r.start_date, v_m0), v_m0), least(coalesce(r.end_date, v_m1), v_m1), r.id, r.unit_kind);
END;
$$;

-- ── 5. Recount paths pass the row's Kind ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.provly_recompute_auth_units(p_org uuid, p_person uuid, p_code_id uuid, p_day date)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_mtp uuid;
BEGIN
  IF p_person IS NULL OR p_code_id IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM service_code_definitions c WHERE c.id = p_code_id AND c.code = 'DSG') THEN
    SELECT id INTO v_mtp FROM service_code_definitions WHERE code = 'MTP';
  END IF;
  UPDATE person_service_authorizations a
     SET used_units = x.u
    FROM (SELECT a2.id, CASE WHEN a2.status::text = 'rejected' THEN 0
                 ELSE public.provly_auth_used_units(a2.org_id, a2.person_id, a2.service_code_id, a2.start_date, a2.end_date, a2.id, a2.unit_kind) END AS u
            FROM person_service_authorizations a2
           WHERE a2.org_id = p_org AND a2.person_id = p_person
             AND (a2.service_code_id = p_code_id OR a2.service_code_id = v_mtp)
             AND (a2.start_date IS NULL OR a2.start_date <= p_day)
             AND (a2.end_date IS NULL OR a2.end_date >= p_day)) x
   WHERE a.id = x.id AND a.used_units IS DISTINCT FROM x.u;
END;
$$;

CREATE OR REPLACE FUNCTION public.provly_recompute_monthly_auths(p_org uuid, p_person uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE person_service_authorizations a
     SET used_units = x.u
    FROM (SELECT a2.id, CASE WHEN a2.status::text = 'rejected' THEN 0
                 ELSE public.provly_auth_used_units(a2.org_id, a2.person_id, a2.service_code_id, a2.start_date, a2.end_date, a2.id, a2.unit_kind) END AS u
            FROM person_service_authorizations a2 JOIN service_code_definitions c ON c.id = a2.service_code_id
           WHERE a2.org_id = p_org AND a2.person_id = p_person
             AND (c.code = 'HAP' OR c.billing_unit::text = 'monthly')) x
   WHERE a.id = x.id AND a.used_units IS DISTINCT FROM x.u;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_psa_used_units()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- a rejected authorization uses nothing (read from NEW: in a BEFORE trigger the table still holds the old row)
  NEW.used_units := CASE WHEN NEW.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(NEW.org_id, NEW.person_id, NEW.service_code_id,
                                                            NEW.start_date, NEW.end_date, NEW.id, NEW.unit_kind) END;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS psa_used_units ON public.person_service_authorizations;
CREATE TRIGGER psa_used_units
  BEFORE INSERT OR UPDATE OF person_id, service_code_id, start_date, end_date, status, unit_kind
  ON public.person_service_authorizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_psa_used_units();

-- ── 6. Identical-row guard (v20.0.10) compares the 1056 fields too ────────
CREATE OR REPLACE FUNCTION public.psa_reject_identical()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- serialize on the material tuple: a concurrent identical write waits here, then sees the committed row
  PERFORM pg_advisory_xact_lock(hashtext(
    NEW.person_id::text || '|' || NEW.service_code_id::text || '|' ||
    NEW.start_date::text || '|' || coalesce(NEW.end_date::text, 'NULL') || '|' ||
    NEW.authorized_units::text || '|' || coalesce(NEW.rate_per_unit::text, 'NULL') || '|' ||
    coalesce(NEW.approval_id, 'NULL') || '|' || coalesce(NEW.unit_kind, 'NULL') || '|' ||
    coalesce(NEW.max_units_per_month::text, 'NULL')));

  IF EXISTS (
    SELECT 1 FROM public.person_service_authorizations p
     WHERE p.person_id = NEW.person_id
       AND p.service_code_id = NEW.service_code_id
       AND p.start_date = NEW.start_date
       AND p.end_date IS NOT DISTINCT FROM NEW.end_date
       AND p.authorized_units = NEW.authorized_units
       AND p.rate_per_unit IS NOT DISTINCT FROM NEW.rate_per_unit
       AND p.approval_id IS NOT DISTINCT FROM NEW.approval_id
       AND p.unit_kind IS NOT DISTINCT FROM NEW.unit_kind
       AND p.max_units_per_month IS NOT DISTINCT FROM NEW.max_units_per_month
       AND p.id <> NEW.id
  ) THEN
    RAISE unique_violation
      USING MESSAGE = 'duplicate key value violates unique constraint "uq_psa_identical"',
            DETAIL  = 'An authorization identical in every material field already exists for this client.';
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_psa_reject_identical ON public.person_service_authorizations;
CREATE TRIGGER trg_psa_reject_identical
  BEFORE INSERT OR UPDATE OF person_id, service_code_id, start_date, end_date, authorized_units, rate_per_unit,
                             approval_id, unit_kind, max_units_per_month
  ON public.person_service_authorizations
  FOR EACH ROW
  EXECUTE FUNCTION public.psa_reject_identical();

-- the two v20.0.10 partial indexes would refuse rows that differ only in a 1056 field;
-- one NULLS NOT DISTINCT index over every material field replaces them (Postgres 15+).
DROP INDEX IF EXISTS public.uq_psa_identical;
DROP INDEX IF EXISTS public.uq_psa_identical_nullrate;
DO $$
DECLARE
  dup_groups integer;
BEGIN
  SELECT count(*) INTO dup_groups FROM (
    SELECT 1 FROM public.person_service_authorizations
    GROUP BY person_id, service_code_id, start_date, end_date, authorized_units, rate_per_unit,
             approval_id, unit_kind, max_units_per_month
    HAVING count(*) > 1) d;
  IF current_setting('server_version_num')::integer < 150000 THEN
    RAISE NOTICE 'uq_psa_identical not created: Postgres is older than 15. The trg_psa_reject_identical trigger guards every write.';
  ELSIF dup_groups > 0 THEN
    RAISE NOTICE 'uq_psa_identical not created: % identical group(s) exist. The trigger guards new writes meanwhile.', dup_groups;
  ELSE
    EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS uq_psa_identical ON public.person_service_authorizations
               (person_id, service_code_id, start_date, end_date, authorized_units, rate_per_unit,
                approval_id, unit_kind, max_units_per_month) NULLS NOT DISTINCT';
  END IF;
END $$;

-- ── 7. D1: notes during a budget lapse ───────────────────────────────────
-- covered  a row that isn't rejected (or closed) and whose dates include the day,
--          or a group-service context that locks the code with the client an active member
-- lapse    no covering row, but the client has had the code: a row that isn't rejected
--          (or closed) starting on or before the day
-- none     the client has never had the code
CREATE OR REPLACE FUNCTION public.provly_note_auth_state(p_org uuid, p_person uuid, p_code_id uuid, p_date date, p_context uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM person_service_authorizations a
              WHERE a.org_id = p_org AND a.person_id = p_person AND a.service_code_id = p_code_id
                AND lower(a.status::text) NOT IN ('rejected', 'closed', 'terminated', 'denied', 'inactive', 'cancelled', 'canceled')
                AND (a.start_date IS NULL OR a.start_date <= p_date)
                AND (a.end_date IS NULL OR a.end_date >= p_date)) THEN
    RETURN 'covered';
  END IF;
  IF p_context IS NOT NULL AND EXISTS (
       SELECT 1 FROM service_delivery_contexts c
         JOIN service_delivery_context_members m ON m.context_id = c.id
        WHERE c.id = p_context AND c.org_id = p_org AND c.is_active = true
          AND c.service_code_id = p_code_id
          AND m.person_id = p_person AND m.is_active IS DISTINCT FROM false AND m.end_date IS NULL) THEN
    RETURN 'covered';
  END IF;
  IF EXISTS (SELECT 1 FROM person_service_authorizations a
              WHERE a.org_id = p_org AND a.person_id = p_person AND a.service_code_id = p_code_id
                AND lower(a.status::text) NOT IN ('rejected', 'closed', 'terminated', 'denied', 'inactive', 'cancelled', 'canceled')
                AND (a.start_date IS NULL OR a.start_date <= p_date)) THEN
    RETURN 'lapse';
  END IF;
  RETURN 'none';
END;
$$;

-- the v20.0.21 front-line rule, relaxed by D1: only "never had this code" is refused
CREATE OR REPLACE FUNCTION public.trg_service_notes_deliver_auth()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.access_tier() IS DISTINCT FROM 'deliver' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.person_id IS NOT DISTINCT FROM OLD.person_id
     AND NEW.service_code_id IS NOT DISTINCT FROM OLD.service_code_id
     AND NEW.service_date IS NOT DISTINCT FROM OLD.service_date
     AND NEW.context_id IS NOT DISTINCT FROM OLD.context_id THEN
    RETURN NEW;                                                  -- nothing the test depends on changed
  END IF;
  IF public.provly_note_auth_state(NEW.org_id, NEW.person_id, NEW.service_code_id, NEW.service_date, NEW.context_id) = 'none' THEN
    RAISE EXCEPTION 'This client has no authorization for this service. Ask your office.';
  END IF;
  RETURN NEW;                                                    -- covered, or a lapse (saved; managers see it flagged)
END;
$$;
DROP TRIGGER IF EXISTS service_notes_deliver_auth ON public.service_notes;
CREATE TRIGGER service_notes_deliver_auth
  BEFORE INSERT OR UPDATE ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_deliver_auth();

-- which of these notes have no covering authorization (lapse or none) — manage tier only;
-- a signed-in caller below manage gets nothing back; computed on read, so it clears itself
CREATE OR REPLACE FUNCTION public.notes_without_authorization(p_note_ids uuid[])
RETURNS TABLE (o_note_id uuid, o_state text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF public.access_tier() IS DISTINCT FROM 'manage' THEN RETURN; END IF;
    v_org := public.org_id();
    IF v_org IS NULL THEN RETURN; END IF;
  END IF;
  RETURN QUERY
  SELECT n.id, s.st
    FROM service_notes n
   CROSS JOIN LATERAL (SELECT public.provly_note_auth_state(n.org_id, n.person_id, n.service_code_id,
                                                            n.service_date, n.context_id) AS st) s
   WHERE n.id = ANY (coalesce(p_note_ids, '{}'::uuid[]))
     AND (v_org IS NULL OR n.org_id = v_org)
     AND s.st <> 'covered';
END;
$$;

-- ── 8. The read view gains the 1056 fields and the "this month" counter ──
-- same columns, order and guard as v20.0.12 (rate masked below manage); new columns appended
CREATE OR REPLACE VIEW public.person_service_authorizations_v
WITH (security_barrier = true, security_invoker = false) AS
SELECT a.id, a.org_id, a.person_id, a.service_code_id,
       a.authorized_units, a.used_units, a.start_date, a.end_date, a.status,
       a.upi_approved_at,
       CASE WHEN public.access_tier() = 'manage' THEN a.rate_per_unit ELSE NULL END AS rate_per_unit,
       a.notes, a.created_at, a.updated_at,
       a.approval_id, a.unit_kind, a.max_units_per_month,
       public.provly_auth_kind(a.unit_kind, a.service_code_id) AS unit_kind_effective,
       public.provly_auth_used_in_month(a.id, (now() AT TIME ZONE 'America/Denver')::date) AS used_this_month
FROM public.person_service_authorizations a
WHERE a.org_id = public.org_id()
  AND public.member_role() IS NOT NULL
  AND public.can_see_person(a.person_id);
COMMENT ON VIEW public.person_service_authorizations_v IS
  'v20.0.12 R3 + v20.0.26 — read view of person_service_authorizations; rate_per_unit masked below the manage tier; sight via can_see_person. v20.0.26 adds the 1056 fields (approval_id, unit_kind, max_units_per_month), unit_kind_effective (row Kind or the code table''s) and used_this_month (current month, Mountain Time).';

-- ── 9. Audit: every authorization change by a signed-in user ─────────────
CREATE OR REPLACE FUNCTION public.trg_psa_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;                 -- service role / SQL editor repairs
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (NEW.org_id, auth.uid(), 'auth_added', 'person_service_authorizations', NEW.id, NULL, to_jsonb(NEW));
  ELSIF TG_OP = 'UPDATE' THEN
    -- the used-units recount (and updated_at) is not an edit
    IF (to_jsonb(NEW) - ARRAY['used_units', 'updated_at']) = (to_jsonb(OLD) - ARRAY['used_units', 'updated_at']) THEN
      RETURN NULL;
    END IF;
    INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (NEW.org_id, auth.uid(), 'auth_changed', 'person_service_authorizations', NEW.id, to_jsonb(OLD), to_jsonb(NEW));
  ELSE
    INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (OLD.org_id, auth.uid(), 'auth_deleted', 'person_service_authorizations', OLD.id, to_jsonb(OLD), NULL);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS psa_audit ON public.person_service_authorizations;
CREATE TRIGGER psa_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.person_service_authorizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_psa_audit();

-- ── 10. Payment file: S (per session) lines ─────────────────────────────
-- one day's units for one person + code; v20.0.26: S = one unit per approved note that day
-- (for an EVV code, the lesser of notes and completed EVV visits); every note's share is 1
CREATE OR REPLACE FUNCTION public.e520_day_units(
  p_org uuid, p_person uuid, p_code text, p_code_id uuid, p_unit text, p_evv boolean, p_day date)
RETURNS TABLE (o_units integer, o_note_units integer, o_evv_units integer, o_notes jsonb, o_null_min boolean)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_ids   uuid[];
  v_mins  integer[];
  v_min   integer := 0;
  v_emin  integer := 0;
  v_ecnt  integer := 0;
  v_eany  boolean;
  v_cum   integer := 0;
  v_prev  integer;
  v_a     integer;
  v_left  integer;
  i       integer;
BEGIN
  o_notes := '[]'::jsonb; o_null_min := false; o_evv_units := NULL;

  IF p_code = 'MTP' THEN
    -- D6: one MTP day per approved DSG note day with a ride by our staff
    SELECT array_agg(n.id ORDER BY n.start_time NULLS LAST, n.id) INTO v_ids
      FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
     WHERE n.org_id = p_org AND n.person_id = p_person AND c.code = 'DSG'
       AND n.service_date = p_day AND n.status IN ('approved', 'billed')   -- r1: billed for DSG can still back a released MTP day
       AND coalesce(n.transport, 'to_and_from') <> 'none'
       AND NOT EXISTS (SELECT 1 FROM e520_line_notes x
                        WHERE x.note_id = n.id AND x.service_code = 'MTP' AND NOT x.released);
    IF v_ids IS NULL THEN o_units := 0; o_note_units := 0; RETURN NEXT; RETURN; END IF;
    o_units := 1; o_note_units := 1;
    FOR i IN 1 .. array_length(v_ids, 1) LOOP
      o_notes := o_notes || jsonb_build_array(jsonb_build_object('id', v_ids[i], 'u', CASE WHEN i = 1 THEN 1 ELSE 0 END));
    END LOOP;
    RETURN NEXT; RETURN;
  END IF;

  SELECT array_agg(n.id ORDER BY n.start_time NULLS LAST, n.id),
         array_agg(coalesce(n.duration_minutes, 0) ORDER BY n.start_time NULLS LAST, n.id),
         bool_or(n.duration_minutes IS NULL)
    INTO v_ids, v_mins, o_null_min
    FROM service_notes n
   WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
     AND n.service_date = p_day AND n.status IN ('approved', 'billed')      -- r1: eligibility is "no live unit for this code", not the status
     AND NOT EXISTS (SELECT 1 FROM e520_line_notes x
                      WHERE x.note_id = n.id AND x.service_code = p_code AND NOT x.released);
  o_null_min := coalesce(o_null_min, false);
  IF v_ids IS NULL THEN o_units := 0; o_note_units := 0; RETURN NEXT; RETURN; END IF;

  IF p_unit = 'Q' THEN
    SELECT coalesce(sum(m), 0) INTO v_min FROM unnest(v_mins) AS m;
    o_note_units := e520_round_q(v_min);
  ELSIF p_unit = 'S' THEN
    o_note_units := array_length(v_ids, 1);                     -- v20.0.26: a session per approved note
  ELSE
    o_note_units := 1;                                          -- D and M: a documented day
  END IF;

  IF p_evv THEN                                                  -- D4: note AND EVV visit, bill the lesser
    SELECT coalesce(sum(floor(extract(epoch FROM (e.clock_out_at - e.clock_in_at)) / 60)), 0)::integer,
           count(*)::integer,
           bool_or(true)
      INTO v_emin, v_ecnt, v_eany
      FROM evv_sessions e
     WHERE e.org_id = p_org AND e.person_id = p_person AND e.service_code_id = p_code_id
       AND e.clock_out_at IS NOT NULL AND e.clock_out_at > e.clock_in_at
       AND (e.clock_in_at AT TIME ZONE 'America/Denver')::date = p_day;
    o_evv_units := CASE WHEN p_unit = 'Q' THEN e520_round_q(v_emin)
                        WHEN p_unit = 'S' THEN coalesce(v_ecnt, 0)
                        WHEN coalesce(v_eany, false) THEN 1 ELSE 0 END;
    o_units := least(o_note_units, o_evv_units);
  ELSE
    o_units := o_note_units;
  END IF;

  -- each note's running-total share; the shares add up to the day's units
  v_left := o_units;
  FOR i IN 1 .. array_length(v_ids, 1) LOOP
    IF p_unit = 'Q' THEN
      v_prev := e520_round_q(v_cum);
      v_cum  := v_cum + v_mins[i];
      v_a    := e520_round_q(v_cum) - v_prev;
    ELSIF p_unit = 'S' THEN
      v_a := 1;
    ELSE
      v_a := CASE WHEN i = 1 THEN 1 ELSE 0 END;
    END IF;
    v_a := least(v_a, v_left);
    v_left := v_left - v_a;
    o_notes := o_notes || jsonb_build_array(jsonb_build_object('id', v_ids[i], 'u', v_a));
  END LOOP;
  RETURN NEXT;
END;
$$;

-- the line filler (v20.0.24a r7, unchanged) now accepts S lines
CREATE OR REPLACE FUNCTION public.e520_fill_line(p_batch uuid, p_org uuid, p_row jsonb, p_next_ln integer)
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  c_residential constant text[] := ARRAY['RHS', 'HHS', 'PPS'];
  v_ord      integer := (p_row->>'ord')::integer;
  v_ln       integer := (p_row->>'line_number')::integer;
  v_s        date    := (p_row->>'start')::date;
  v_e        date    := (p_row->>'end')::date;
  v_code     text    := p_row->>'code';
  v_unit     text    := p_row->>'unit';
  v_rate_txt text    := p_row->>'rate';
  v_next     integer := p_next_ln;
  v_flags    jsonb   := '[]'::jsonb;
  v_reason   text;
  v_person   uuid;
  v_nperson  integer;
  v_code_id  uuid;
  v_evv      boolean;
  v_need_place boolean := false;
  v_need_auth  boolean := false;
  v_auth_rate numeric;
  v_max      integer;
  v_rem      integer;
  v_prior_month integer := 0;
  v_prior_batch integer := 0;
  v_cap      integer;
  v_d        date;
  v_covered  boolean;
  v_absent   boolean;
  dr         record;
  v_days     jsonb := '[]'::jsonb;
  v_days2    jsonb := '[]'::jsonb;
  v_day      jsonb;
  v_note     jsonb;
  v_new_notes jsonb;
  v_evv_gap  text[] := '{}';
  v_absent_notes text[] := '{}';
  v_outside_notes text[] := '{}';
  v_outside  integer := 0;
  v_total_days integer := 0;
  v_undoc    integer := 0;
  v_null_min boolean := false;
  v_documented integer := 0;
  v_running  integer := 0;
  v_used     integer;
  v_left     integer;
  v_a        integer;
  v_seg_s    date;
  v_seg_e    date;
  v_seg_units integer;
  v_seg_days jsonb;
  v_kept     integer := 0;
  v_this_ln  integer;
  v_line_id  uuid;
  v_incare   integer;
  v_inplace  integer;
  v_first    date;
  v_hap_auth uuid;
BEGIN
  -- 1. who, what, which unit
  SELECT count(*), (array_agg(p.id))[1] INTO v_nperson, v_person
    FROM persons p
   WHERE p.org_id = p_org
     AND lpad(btrim(coalesce(p.identification_number, '')), 9, '0') = p_row->>'pid';
  IF v_nperson = 0 THEN
    v_reason := 'PID not found in Provly';
  ELSIF v_nperson > 1 THEN
    v_reason := 'More than one client in Provly has this PID'; v_person := NULL;
  END IF;
  IF v_reason IS NULL THEN
    SELECT c.id, coalesce(c.evv_required, false) INTO v_code_id, v_evv
      FROM service_code_definitions c WHERE upper(c.code) = v_code LIMIT 1;
    IF v_code_id IS NULL THEN v_reason := format('Service code %s isn''t set up in Provly', v_code); END IF;
  END IF;
  IF v_reason IS NULL AND v_unit NOT IN ('Q', 'D', 'M', 'S') THEN          -- v20.0.26: S (per session) lines fill
    v_reason := format('Unit type %s isn''t supported yet; fill this line by hand', v_unit);
  END IF;

  IF v_reason IS NOT NULL THEN
    INSERT INTO e520_lines (batch_id, org_id, ord, line_number, source_line_number, raw, person_id, service_code,
                            unit_type, start_date, end_date, source_start_date, source_end_date, units, action,
                            remove_reason, flags)
    VALUES (p_batch, p_org, v_ord * 100, v_ln, v_ln, p_row->'vals', v_person, v_code,
            v_unit, v_s, v_e, v_s, v_e, 0, 'remove', v_reason, v_flags);
    RETURN v_next;
  END IF;

  -- 2. which coverage applies (D1: with none on file, UPI's line is the authority)
  IF v_code = ANY (c_residential) THEN
    v_need_place := EXISTS (SELECT 1 FROM person_placements pl
                             WHERE pl.org_id = p_org AND pl.person_id = v_person
                               AND pl.start_date <= v_e AND (pl.end_date IS NULL OR pl.end_date >= v_s));
    IF NOT v_need_place THEN
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'no_placement',
                   'detail', 'No placement on file covers these dates'));
    END IF;
  END IF;
  -- r3: ANY authorization on file (whatever its status) means coverage is checked; only
  --     "none on file" falls back to UPI's line. A rejected one never covers a day.
  v_need_auth := EXISTS (SELECT 1 FROM person_service_authorizations a
                          WHERE a.org_id = p_org AND a.person_id = v_person AND a.service_code_id = v_code_id
                            AND (a.start_date IS NULL OR a.start_date <= v_e) AND (a.end_date IS NULL OR a.end_date >= v_s));
  IF NOT v_need_auth THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'no_authorization',
                 'detail', 'No Provly authorization covers these dates; UPI''s line is used as the authority'));
  ELSE
    IF NOT EXISTS (SELECT 1 FROM person_service_authorizations a
                    WHERE a.org_id = p_org AND a.person_id = v_person AND a.service_code_id = v_code_id
                      AND a.status::text <> 'rejected'
                      AND (a.start_date IS NULL OR a.start_date <= v_e) AND (a.end_date IS NULL OR a.end_date >= v_s)) THEN
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'rejected_authorization',
                   'detail', 'The only authorization on file for these dates is rejected, so no day is covered'));
    END IF;
    SELECT a.rate_per_unit INTO v_auth_rate
      FROM person_service_authorizations a
     WHERE a.org_id = p_org AND a.person_id = v_person AND a.service_code_id = v_code_id
       AND a.status::text <> 'rejected'
       AND (a.start_date IS NULL OR a.start_date <= v_e) AND (a.end_date IS NULL OR a.end_date >= v_s)
     ORDER BY a.start_date DESC NULLS LAST LIMIT 1;
    IF v_auth_rate IS NOT NULL AND v_rate_txt ~ '^[0-9]+(\.[0-9]+)?$'
       AND round(v_rate_txt::numeric, 2) <> round(v_auth_rate, 2) THEN
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'rate_mismatch',
                   'detail', format('UPI''s rate %s differs from Provly''s authorization rate %s; UPI''s rate is sent', v_rate_txt, round(v_auth_rate, 2))));
    END IF;
  END IF;

  -- 3. caps, shared by every live line for this client + code + month (this file, and uploaded files)
  SELECT coalesce(sum(l.units), 0),
         coalesce(sum(l.units) FILTER (WHERE l.batch_id = p_batch), 0)
    INTO v_prior_month, v_prior_batch
    FROM e520_lines l JOIN e520_batches b ON b.id = l.batch_id
   WHERE l.org_id = p_org AND l.person_id = v_person AND l.service_code = v_code
     AND l.action <> 'remove' AND l.released_at IS NULL
     AND date_trunc('month', l.start_date) = date_trunc('month', v_s)
     AND (l.batch_id = p_batch OR b.status = 'uploaded');
  IF coalesce(p_row->>'max', '') ~ '^[0-9]+$' THEN
    v_max := (p_row->>'max')::integer;
    v_cap := greatest(v_max - v_prior_month, 0);          -- the month's max, less what other lines already bill
  END IF;
  IF coalesce(p_row->>'remaining', '') ~ '^[0-9]+$' THEN
    v_rem := (p_row->>'remaining')::integer;             -- UPI's remaining, as of this download, less this file's other lines
    v_cap := CASE WHEN v_cap IS NULL THEN greatest(v_rem - v_prior_batch, 0)
                  ELSE least(v_cap, greatest(v_rem - v_prior_batch, 0)) END;
  END IF;
  IF v_unit = 'M' THEN v_cap := least(coalesce(v_cap, 1), greatest(1 - v_prior_month, 0)); END IF;

  -- 3b. v20.0.24a HAP (rent): the placement proves the month. One unit for a month with any
  --     day in care (placement on file, not after discharge); absences never reduce it.
  IF v_code = 'HAP' THEN
    SELECT count(*) INTO v_inplace
      FROM generate_series(v_s, v_e, interval '1 day') AS gs
     WHERE EXISTS (SELECT 1 FROM person_placements pl
                    WHERE pl.org_id = p_org AND pl.person_id = v_person
                      AND pl.start_date <= gs::date AND (pl.end_date IS NULL OR pl.end_date >= gs::date))
       AND NOT EXISTS (SELECT 1 FROM persons p
                        WHERE p.id = v_person AND p.discharge_date IS NOT NULL AND p.discharge_date < gs::date);
    SELECT count(*) INTO v_incare
      FROM generate_series(v_s, v_e, interval '1 day') AS gs
     WHERE EXISTS (SELECT 1 FROM person_placements pl
                    WHERE pl.org_id = p_org AND pl.person_id = v_person
                      AND pl.start_date <= gs::date AND (pl.end_date IS NULL OR pl.end_date >= gs::date))
       AND NOT EXISTS (SELECT 1 FROM persons p
                        WHERE p.id = v_person AND p.discharge_date IS NOT NULL AND p.discharge_date < gs::date)
       AND (NOT v_need_auth
            OR EXISTS (SELECT 1 FROM person_service_authorizations a
                        WHERE a.org_id = p_org AND a.person_id = v_person AND a.service_code_id = v_code_id
                          AND a.status::text <> 'rejected'
                          AND (a.start_date IS NULL OR a.start_date <= gs::date) AND (a.end_date IS NULL OR a.end_date >= gs::date)));
    v_total_days := v_e - v_s + 1;
    IF v_inplace = 0 THEN
      v_reason := 'Not in care on any of these dates (no placement, or after discharge)';
    ELSIF v_incare = 0 THEN
      v_reason := 'No authorization that isn''t rejected covers the days in care';
    ELSIF coalesce(v_cap, 1) <= 0 THEN
      v_reason := 'HAP is already billed for this month';
    END IF;
    IF v_reason IS NOT NULL THEN
      INSERT INTO e520_lines (batch_id, org_id, ord, line_number, source_line_number, raw, person_id, service_code,
                              unit_type, start_date, end_date, source_start_date, source_end_date, units, action,
                              remove_reason, flags)
      VALUES (p_batch, p_org, v_ord * 100, v_ln, v_ln, p_row->'vals', v_person, v_code,
              v_unit, v_s, v_e, v_s, v_e, 0, 'remove', v_reason, v_flags);
      RETURN v_next;
    END IF;
    -- r6: the authorization this month is billed under — the one covering the first day in care and
    --     authorized (later-starting, then later-ending, then id, when several cover it)
    IF v_need_auth THEN
      v_hap_auth := public.e520_hap_billing_auth(p_org, v_person, v_code_id, v_s, v_e);
    END IF;
    IF v_incare < v_total_days THEN
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'partial_month',
                   'detail', format('In care %s of %s days on this line; check whether HAP is prorated', v_incare, v_total_days)));
    END IF;
    INSERT INTO e520_lines (batch_id, org_id, ord, line_number, source_line_number, raw, person_id, service_code,
                            unit_type, start_date, end_date, source_start_date, source_end_date, units, action, flags,
                            authorization_id)
    VALUES (p_batch, p_org, v_ord * 100 + 1, v_ln, v_ln, p_row->'vals', v_person, v_code,
            v_unit, v_s, v_e, v_s, v_e, 1, 'fill', v_flags, v_hap_auth);
    RETURN v_next;
  END IF;

  -- 4. every day of the span: outside coverage or inside an absence is a break (D7)
  FOR v_d IN SELECT gs::date FROM generate_series(v_s, v_e, interval '1 day') AS gs LOOP
    v_total_days := v_total_days + 1;
    v_covered := (NOT v_need_place
                   OR EXISTS (SELECT 1 FROM person_placements pl
                               WHERE pl.org_id = p_org AND pl.person_id = v_person
                                 AND pl.start_date <= v_d AND (pl.end_date IS NULL OR pl.end_date >= v_d)))
             AND (NOT v_need_auth
                   OR EXISTS (SELECT 1 FROM person_service_authorizations a
                               WHERE a.org_id = p_org AND a.person_id = v_person AND a.service_code_id = v_code_id
                                 AND a.status::text <> 'rejected'
                                 AND (a.start_date IS NULL OR a.start_date <= v_d) AND (a.end_date IS NULL OR a.end_date >= v_d)));
    SELECT EXISTS (SELECT 1 FROM person_absences ab
                    WHERE ab.org_id = p_org AND ab.person_id = v_person
                      AND ab.start_date <= v_d AND (ab.end_date IS NULL OR ab.end_date >= v_d))
      INTO v_absent;
    IF NOT v_covered OR v_absent THEN
      IF EXISTS (SELECT 1 FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
                  WHERE n.org_id = p_org AND n.person_id = v_person AND n.service_date = v_d
                    AND n.status IN ('approved', 'billed')
                    AND c.code = CASE WHEN v_code = 'MTP' THEN 'DSG' ELSE v_code END) THEN
        IF v_absent THEN v_absent_notes := v_absent_notes || to_char(v_d, 'MM/DD');
        ELSE v_outside_notes := v_outside_notes || to_char(v_d, 'MM/DD'); END IF;
      END IF;
      IF NOT v_covered THEN v_outside := v_outside + 1; END IF;
      v_days := v_days || jsonb_build_array(jsonb_build_object('d', v_d, 'absent', true, 'u', 0, 'notes', '[]'::jsonb));
      CONTINUE;
    END IF;
    SELECT * INTO dr FROM public.e520_day_units(p_org, v_person, v_code, v_code_id, v_unit, v_evv, v_d);
    IF v_unit = 'Q' AND dr.o_null_min THEN v_null_min := true; END IF;
    IF v_evv AND dr.o_note_units > 0 AND dr.o_evv_units IS DISTINCT FROM dr.o_note_units THEN
      v_evv_gap := v_evv_gap || to_char(v_d, 'MM/DD');
    END IF;
    IF v_code = ANY (c_residential) AND v_unit = 'D' AND dr.o_note_units = 0 THEN
      v_undoc := v_undoc + 1;
    END IF;
    v_documented := v_documented + dr.o_units;
    v_days := v_days || jsonb_build_array(jsonb_build_object('d', v_d, 'absent', false, 'u', dr.o_units, 'notes', dr.o_notes));
  END LOOP;

  -- 5. apply the cap day by day; a day that bills anything reserves all its notes
  FOR v_day IN SELECT x FROM jsonb_array_elements(v_days) WITH ORDINALITY AS t(x, o) ORDER BY o LOOP
    v_used := (v_day->>'u')::integer;
    IF v_cap IS NOT NULL THEN v_used := least(v_used, greatest(v_cap - v_running, 0)); END IF;
    v_running := v_running + v_used;
    v_new_notes := '[]'::jsonb;
    IF v_used > 0 THEN
      v_left := v_used;
      FOR v_note IN SELECT y FROM jsonb_array_elements(v_day->'notes') WITH ORDINALITY AS t2(y, o2) ORDER BY o2 LOOP
        v_a := least((v_note->>'u')::integer, v_left);
        v_left := v_left - v_a;
        v_new_notes := v_new_notes || jsonb_build_array(jsonb_build_object('id', v_note->>'id', 'u', v_a));
      END LOOP;
    END IF;
    v_days2 := v_days2 || jsonb_build_array(jsonb_build_object(
                 'd', v_day->>'d', 'absent', (v_day->>'absent')::boolean, 'used', v_used, 'notes', v_new_notes));
  END LOOP;

  -- 6. flags the review screen shows
  IF coalesce(array_length(v_evv_gap, 1), 0) > 0 THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'evv_gap',
                 'detail', format('EVV and notes disagree on %s; the lower count is billed', array_to_string(v_evv_gap, ', '))));
  END IF;
  IF v_outside > 0 THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'outside_coverage',
                 'detail', format('%s day(s) fall outside the placement or authorization and are not billed%s', v_outside,
                                  CASE WHEN coalesce(array_length(v_outside_notes, 1), 0) > 0
                                       THEN '; approved notes on ' || array_to_string(v_outside_notes, ', ') ELSE '' END)));
  END IF;
  IF v_undoc > 0 THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'undocumented_days',
                 'detail', format('%s day(s) have neither an approved note nor a recorded absence', v_undoc)));
  END IF;
  IF coalesce(array_length(v_absent_notes, 1), 0) > 0 THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'note_in_absence',
                 'detail', format('Approved notes fall inside a recorded absence on %s; those days are not billed', array_to_string(v_absent_notes, ', '))));
  END IF;
  IF v_null_min THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'note_without_minutes',
                 'detail', 'An approved note has no times, so its minutes count as 0'));
  END IF;
  IF v_unit <> 'M' AND v_documented > v_running THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'capped',
                 'detail', format('%s more unit(s) documented than the monthly max or remaining units allow%s; ask the SC to raise it, then send a supplemental',
                                  v_documented - v_running,
                                  CASE WHEN v_prior_month > 0 THEN format(' (%s already on other lines this month)', v_prior_month) ELSE '' END)));
  END IF;

  -- 7. runs of consecutive days between breaks become the line and its split parts
  v_seg_s := NULL;
  FOR v_day IN
    SELECT x FROM jsonb_array_elements(v_days2 || jsonb_build_array(jsonb_build_object('absent', true, 'used', 0, 'notes', '[]'::jsonb)))
                  WITH ORDINALITY AS t(x, o) ORDER BY o
  LOOP
    IF (v_day->>'absent')::boolean THEN                          -- a break (or the end sentinel) closes a run
      IF v_seg_s IS NOT NULL THEN
        IF v_seg_units > 0 THEN
          v_kept := v_kept + 1;
          IF v_kept = 1 THEN v_this_ln := v_ln; ELSE v_this_ln := v_next; v_next := v_next + 1; END IF;
          INSERT INTO e520_lines (batch_id, org_id, ord, line_number, source_line_number, raw, person_id,
                                  service_code, unit_type, start_date, end_date, source_start_date,
                                  source_end_date, units, action, flags)
          VALUES (p_batch, p_org, v_ord * 100 + v_kept, v_this_ln, v_ln, p_row->'vals', v_person,
                  v_code, v_unit, v_seg_s, v_seg_e, v_s,
                  v_e, v_seg_units, CASE WHEN v_kept = 1 THEN 'fill' ELSE 'split' END,
                  CASE WHEN v_kept = 1 THEN v_flags ELSE '[]'::jsonb END)
          RETURNING id INTO v_line_id;
          INSERT INTO e520_line_notes (line_id, org_id, note_id, service_code, service_date, units)
          SELECT v_line_id, p_org, (n->>'id')::uuid, v_code, (dd->>'d')::date, (n->>'u')::integer
            FROM jsonb_array_elements(v_seg_days) AS dd, jsonb_array_elements(dd->'notes') AS n
           WHERE (dd->>'used')::integer > 0;
        END IF;
        v_seg_s := NULL;
      END IF;
    ELSE
      IF v_seg_s IS NULL THEN
        v_seg_s := (v_day->>'d')::date; v_seg_units := 0; v_seg_days := '[]'::jsonb;
      END IF;
      v_seg_e := (v_day->>'d')::date;
      v_seg_units := v_seg_units + (v_day->>'used')::integer;
      v_seg_days := v_seg_days || jsonb_build_array(v_day);
    END IF;
  END LOOP;

  IF v_kept = 0 THEN
    INSERT INTO e520_lines (batch_id, org_id, ord, line_number, source_line_number, raw, person_id, service_code,
                            unit_type, start_date, end_date, source_start_date, source_end_date, units, action,
                            remove_reason, flags)
    VALUES (p_batch, p_org, v_ord * 100, v_ln, v_ln, p_row->'vals', v_person, v_code,
            v_unit, v_s, v_e, v_s, v_e, 0, 'remove',
            CASE WHEN v_outside = v_total_days THEN 'No day on this line falls inside a placement or authorization'
                 WHEN v_documented > 0 THEN 'No units left under the monthly max or remaining units'
                 ELSE 'No approved documentation for these dates' END,
            v_flags);
  END IF;
  RETURN v_next;
END;
$$;

-- ── 11. Recount every authorization once (Kind, and PBA's new unit) ─────
UPDATE public.person_service_authorizations a
   SET used_units = CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id, a.unit_kind) END
 WHERE a.used_units IS DISTINCT FROM CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id, a.unit_kind) END;

-- ── 12. Privileges ───────────────────────────────────────────────────────
-- internal: not callable by clients
REVOKE ALL ON FUNCTION public.provly_auth_used_units(uuid, uuid, uuid, date, date, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provly_auth_used_units(uuid, uuid, uuid, date, date, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provly_recompute_auth_units(uuid, uuid, uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provly_recompute_monthly_auths(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_psa_used_units() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provly_note_auth_state(uuid, uuid, uuid, date, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_service_notes_deliver_auth() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_psa_audit() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_fill_line(uuid, uuid, jsonb, integer) FROM PUBLIC, anon, authenticated;
-- the read view calls these as the signed-in user, so they need EXECUTE; the RPC is manage-gated inside
REVOKE ALL ON FUNCTION public.provly_auth_kind(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provly_auth_kind(text, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.provly_auth_used_in_month(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provly_auth_used_in_month(uuid, date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.notes_without_authorization(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notes_without_authorization(uuid[]) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ── 13. Self-test: a synthetic client (inactive, PID 099999926, 2001 dates) run end to
--        end, then rolled back. If ANY check fails, or the test can't run, the whole
--        file is rolled back — nothing in it is applied — and the error lists each
--        failing check. Results go to a session temp table.
CREATE TEMP TABLE IF NOT EXISTS v20026_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20026_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20026_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.26 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res    jsonb := '[]'::jsonb;
  v_fail   text;
  v_org    uuid;
  v_staff  uuid;
  v_pba    uuid;
  v_sln    uuid;
  v_dsg    uuid;
  v_person uuid;
  v_a      uuid;
  v_n1     uuid;
  v_apr    uuid;
  v_batch  uuid;
  v_txt    text;
  v_msg    text;
  v_n      integer;
  v_u1     integer;
  v_u2     integer;
  r        record;
  v_step   text := 'setup';
  v_hdr    text := 'line_number,provider_approver_email,consumer_name,consumer_pid,service_code,rate,unit_type,service_start_date,service_end_date,units,remaining_units,sce,monthly_max_units';
  v_line   text := '1,selftest@example.com,Selftest V20026,099999926,PBA,18.59,S,01/01/2001,01/31/2001,0,100,Test Coordinator,100';
BEGIN
  -- start from a valid "nobody signed in" state (the editor can hold the claims as an empty string)
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s.org_id INTO v_org FROM staff s ORDER BY s.created_at NULLS LAST, s.id LIMIT 1;
  SELECT s.id INTO v_staff FROM staff s WHERE s.org_id = v_org ORDER BY s.id LIMIT 1;
  SELECT id INTO v_pba FROM service_code_definitions WHERE code = 'PBA' LIMIT 1;
  SELECT id INTO v_sln FROM service_code_definitions WHERE code = 'SLN' LIMIT 1;
  SELECT id INTO v_dsg FROM service_code_definitions WHERE code = 'DSG' LIMIT 1;

  BEGIN
    v_step := 'creating the test client';
    v_person := pg_temp.v20026_test_insert('persons', jsonb_build_object(
      'org_id', v_org, 'first_name', 'V20026', 'last_name', 'Selftest', 'identification_number', '099999926', 'is_active', false));

    -- T1: Kind falls back to the code table (PBA is now per session)
    v_step := 'T1 Kind';
    v_txt := coalesce(public.provly_auth_kind(NULL, v_pba), 'null') || ', ' || coalesce(public.provly_auth_kind('Q', v_pba), 'null')
             || ', ' || coalesce(public.provly_auth_kind(NULL, v_sln), 'null');
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'T1 Kind: PBA with none set, PBA set to Q, SLN with none set', v_txt, 'S, Q, Q'));

    -- a PBA 1056 row for Jan–Mar 2001 (no Kind set → S), 12 units for the period, 4 a month
    v_step := 'creating the PBA authorization and notes';
    v_a := pg_temp.v20026_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_pba, 'authorized_units', 12, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-03-31',
      'rate_per_unit', 18.59, 'status', 'approved', 'approval_id', 'SELFTEST-1', 'max_units_per_month', 4));
    v_n1 := pg_temp.v20026_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-05', 'start_time', '09:00', 'end_time', '09:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26 self-test', 'status', 'approved'));
    PERFORM pg_temp.v20026_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-05', 'start_time', '13:00', 'end_time', '13:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26 self-test', 'status', 'approved'));
    PERFORM pg_temp.v20026_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-20', 'start_time', '10:00', 'end_time', '10:45', 'duration_minutes', 45,
      'billable_units', 1, 'summary_note', 'v20.0.26 self-test', 'status', 'approved'));
    PERFORM pg_temp.v20026_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-02-02', 'start_time', '10:00', 'end_time', '10:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26 self-test', 'status', 'approved'));
    PERFORM pg_temp.v20026_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-21', 'start_time', '10:00', 'end_time', '10:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26 self-test', 'status', 'draft'));

    -- T2: per session = one unit per approved note (the draft doesn't count)
    v_step := 'T2 per-session count';
    SELECT used_units::text INTO v_txt FROM person_service_authorizations WHERE id = v_a;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'T2 per session: 4 approved notes (2 on one day) and a draft', v_txt, '4'));

    -- T3: changing the row's Kind recounts it (Q: 60 min → 4, 45 → 3, 30 → 2), and back
    v_step := 'T3 Kind change recount';
    UPDATE person_service_authorizations SET unit_kind = 'Q' WHERE id = v_a;
    SELECT used_units INTO v_u1 FROM person_service_authorizations WHERE id = v_a;
    UPDATE person_service_authorizations SET unit_kind = NULL WHERE id = v_a;
    SELECT used_units INTO v_u2 FROM person_service_authorizations WHERE id = v_a;
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'T3 the row''s Kind decides the count, and changing it recounts',
                       format('Q %s, back to S %s', v_u1, v_u2), 'Q 9, back to S 4'));

    -- T4: this month = the row's units inside one calendar month; NULL outside the row's dates
    v_step := 'T4 this month';
    v_txt := coalesce(public.provly_auth_used_in_month(v_a, DATE '2001-01-15')::text, 'null') || ', '
          || coalesce(public.provly_auth_used_in_month(v_a, DATE '2001-02-01')::text, 'null') || ', '
          || coalesce(public.provly_auth_used_in_month(v_a, DATE '2001-04-01')::text, 'null');
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'T4 this-month counter: January, February, April (outside the row)', v_txt, '3, 1, null'));

    -- T5: D1 coverage states
    v_step := 'T5 note coverage';
    PERFORM pg_temp.v20026_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_dsg, 'authorized_units', 60, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-03-31',
      'rate_per_unit', 127, 'status', 'rejected', 'max_units_per_month', 20));
    v_txt := public.provly_note_auth_state(v_org, v_person, v_pba, DATE '2001-01-10', NULL) || ', '
          || public.provly_note_auth_state(v_org, v_person, v_pba, DATE '2001-04-10', NULL) || ', '
          || public.provly_note_auth_state(v_org, v_person, v_pba, DATE '2000-12-10', NULL) || ', '
          || public.provly_note_auth_state(v_org, v_person, v_sln, DATE '2001-01-10', NULL) || ', '
          || public.provly_note_auth_state(v_org, v_person, v_dsg, DATE '2001-01-10', NULL);
    UPDATE person_service_authorizations SET status = 'expired' WHERE id = v_a;
    v_txt := v_txt || ', ' || public.provly_note_auth_state(v_org, v_person, v_pba, DATE '2001-01-10', NULL);
    UPDATE person_service_authorizations SET status = 'approved' WHERE id = v_a;
    v_res := v_res || jsonb_build_array(jsonb_build_array(5,
      'T5 coverage: inside the row, after it ends (lapse), before any row, a code never had, only a rejected row, an expired row inside its dates',
      v_txt, 'covered, lapse, none, none, none, covered'));

    -- T6: a note saved during the lapse is flagged, and the flag clears once the renewal is entered
    v_step := 'T6 lapse flag';
    v_apr := pg_temp.v20026_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-04-10', 'start_time', '10:00', 'end_time', '10:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26 self-test', 'status', 'approved'));
    SELECT count(*), string_agg(f.o_state || ':' || (f.o_note_id = v_apr)::text, ',')
      INTO v_n, v_txt FROM public.notes_without_authorization(ARRAY[v_n1, v_apr]) AS f;
    v_txt := format('before: %s %s', v_n, coalesce(v_txt, '-'));
    PERFORM pg_temp.v20026_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_pba, 'authorized_units', 12, 'used_units', 0, 'start_date', '2001-04-01', 'end_date', '2001-06-30',
      'rate_per_unit', 18.59, 'status', 'approved', 'approval_id', 'SELFTEST-1', 'unit_kind', 'S', 'max_units_per_month', 4));
    SELECT count(*) INTO v_n FROM public.notes_without_authorization(ARRAY[v_n1, v_apr]);
    v_txt := v_txt || format('; after: %s', v_n);
    v_res := v_res || jsonb_build_array(jsonb_build_array(6, 'T6 a lapse note is flagged; entering the renewal clears it', v_txt,
                       'before: 1 lapse:true; after: 0'));

    -- T7: the identical-row guard compares the 1056 fields
    v_step := 'T7 duplicate guard';
    v_msg := NULL;
    BEGIN
      PERFORM pg_temp.v20026_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
        'service_code_id', v_pba, 'authorized_units', 12, 'used_units', 0, 'start_date', '2001-04-01', 'end_date', '2001-06-30',
        'rate_per_unit', 18.59, 'status', 'approved', 'approval_id', 'SELFTEST-1', 'unit_kind', 'S', 'max_units_per_month', 4));
      v_msg := 'identical ALLOWED';
    EXCEPTION WHEN unique_violation THEN v_msg := 'identical refused';
    END;
    BEGIN
      PERFORM pg_temp.v20026_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
        'service_code_id', v_pba, 'authorized_units', 12, 'used_units', 0, 'start_date', '2001-04-01', 'end_date', '2001-06-30',
        'rate_per_unit', 18.59, 'status', 'approved', 'approval_id', 'SELFTEST-2', 'unit_kind', 'S', 'max_units_per_month', 4));
      v_msg := v_msg || '; other Approval ID allowed';
    EXCEPTION WHEN unique_violation THEN v_msg := v_msg || '; other Approval ID REFUSED';
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(7, 'T7 duplicates: an identical row, then one with another Approval ID', v_msg,
                       'identical refused; other Approval ID allowed'));

    -- T8: a signed-in edit is audited; the used-units recount is not
    v_step := 'T8 audit';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    UPDATE person_service_authorizations SET approval_id = 'SELFTEST-1B' WHERE id = v_a;
    UPDATE person_service_authorizations SET used_units = used_units + 0 WHERE id = v_a;
    PERFORM set_config('request.jwt.claims', '{}', true);
    SELECT count(*)::text INTO v_txt FROM audit_log WHERE record_id = v_a AND action = 'auth_changed';
    v_res := v_res || jsonb_build_array(jsonb_build_array(8, 'T8 audit rows: one edit by a signed-in user, then a recount', v_txt, '1'));

    -- T9: the payment-file day count for S, with and without EVV
    v_step := 'T9 engine day units';
    SELECT d.o_units, d.o_notes INTO r FROM public.e520_day_units(v_org, v_person, 'PBA', v_pba, 'S', false, DATE '2001-01-05') AS d;
    v_txt := format('%s units, shares %s', r.o_units, (SELECT string_agg(x->>'u', '+') FROM jsonb_array_elements(r.o_notes) AS x));
    PERFORM pg_temp.v20026_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_staff, 'person_id', v_person,
      'service_code_id', v_pba,
      'clock_in_at', (TIMESTAMP '2001-01-05 09:00' AT TIME ZONE 'America/Denver'),
      'clock_out_at', (TIMESTAMP '2001-01-05 09:30' AT TIME ZONE 'America/Denver')));
    SELECT d.o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'PBA', v_pba, 'S', true, DATE '2001-01-05') AS d;
    v_txt := v_txt || format('; with 1 EVV visit: %s', v_n);
    v_res := v_res || jsonb_build_array(jsonb_build_array(9, 'T9 engine: two approved PBA notes on one day, then the same day as an EVV code with one visit',
                       v_txt, '2 units, shares 1+1; with 1 EVV visit: 1'));

    -- T10: a UPI line with unit type S is filled (it was removed as unsupported before)
    v_step := 'T10 payment file S line';
    v_batch := public.e520_build('selftest-v20026.csv', chr(65279) || v_hdr || E'\r\n' || v_line, v_org);
    SELECT string_agg(l.action || ' ' || l.units, ', ' ORDER BY l.ord) INTO v_txt FROM e520_lines l WHERE l.batch_id = v_batch;
    v_res := v_res || jsonb_build_array(jsonb_build_array(10, 'T10 payment file: a January PBA line, unit type S (3 approved notes)',
                       coalesce(v_txt, 'no line'), 'fill 3'));

    RAISE EXCEPTION 'v20026_rollback';                           -- undo everything the test created
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20026_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);

  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail
    FROM jsonb_array_elements(v_res) AS e
   WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 10 THEN
    RAISE EXCEPTION 'v20.0.26 self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 10 checks ran', jsonb_array_length(v_res)));
  END IF;

  INSERT INTO v20026_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20026_test_insert(text, jsonb);

COMMIT;


-- ── 14. Verification — paste this table into chat before the PR merges ───
SELECT * FROM (
  SELECT 1 AS n, 'the three 1056 columns and their checks' AS check_item,
    ((SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'person_service_authorizations'
        AND column_name IN ('approval_id', 'unit_kind', 'max_units_per_month'))
     || ' + ' ||
     (SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.person_service_authorizations'::regclass
        AND conname IN ('psa_unit_kind_valid', 'psa_max_units_nonneg', 'psa_approval_id_not_blank'))) AS value,
    '3 + 3' AS want
  UNION ALL
  SELECT 2, 'PBA is billed per session',
    (SELECT billing_unit::text FROM public.service_code_definitions WHERE code = 'PBA'), 'per_session'
  UNION ALL
  SELECT 3, 'authorizations with a monthly max (copied from the old units value on the first run) — for you to read',
    (SELECT format('%s of %s', count(*) FILTER (WHERE max_units_per_month IS NOT NULL), count(*)) FROM public.person_service_authorizations),
    '(read)'
  UNION ALL
  SELECT 4, 'authorizations whose used units don''t match the rule',
    (SELECT count(*)::text FROM public.person_service_authorizations a
      WHERE a.used_units IS DISTINCT FROM CASE WHEN a.status::text = 'rejected' THEN 0
                  ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id, a.unit_kind) END),
    '0'
  UNION ALL
  -- NOTE (run Sep 30): this row read false on production — a false negative. Postgres prints a
  -- single-table view without its alias, so the stored text is can_see_person(person_id), not
  -- can_see_person(a.person_id). Checked part by part: 5 new columns, rate mask present, guard
  -- org_id() + member_role() + can_see_person(person_id) present, security_barrier=true. View correct.
  SELECT 5, 'read view: the five new columns, rate still masked below manage, same guard',
    (SELECT ((SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'person_service_authorizations_v'
                AND column_name IN ('approval_id', 'unit_kind', 'max_units_per_month', 'unit_kind_effective', 'used_this_month')) = 5
             AND v.definition LIKE '%access_tier() = ''manage''::text%'
             AND v.definition LIKE '%can_see_person(a.person_id)%'
             AND c.reloptions @> ARRAY['security_barrier=true'])::text
       FROM pg_views v JOIN pg_class c ON c.oid = 'public.person_service_authorizations_v'::regclass
      WHERE v.schemaname = 'public' AND v.viewname = 'person_service_authorizations_v'),
    'true'
  UNION ALL
  SELECT 6, 'D1: the front-line rule refuses only a code the client never had',
    (SELECT (p.prosrc LIKE '%provly_note_auth_state(%' AND p.prosrc LIKE '%= ''none''%' AND p.prosrc LIKE '%IS DISTINCT FROM ''deliver''%')::text
       FROM pg_proc p WHERE p.oid = 'public.trg_service_notes_deliver_auth()'::regprocedure),
    'true'
  UNION ALL
  SELECT 7, 'identical-row guard: trigger watches the 1056 fields; unique index',
    (SELECT (pg_get_triggerdef(t.oid) LIKE '%approval_id%' AND pg_get_triggerdef(t.oid) LIKE '%max_units_per_month%')::text
       FROM pg_trigger t WHERE t.tgrelid = 'public.person_service_authorizations'::regclass AND t.tgname = 'trg_psa_reject_identical')
    || ' · ' ||
    coalesce((SELECT CASE WHEN indexdef LIKE '%NULLS NOT DISTINCT%' THEN 'index (nulls not distinct)' ELSE 'index (old form)' END
                FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'uq_psa_identical'), 'trigger only'),
    'true · index (nulls not distinct)'
  UNION ALL
  SELECT 8, 'triggers on authorizations: audit, used units (incl. Kind), identical guard, billed guard',
    (SELECT string_agg(t.tgname, ', ' ORDER BY t.tgname) FROM pg_trigger t
      WHERE t.tgrelid = 'public.person_service_authorizations'::regclass AND NOT t.tgisinternal
        AND t.tgname IN ('psa_audit', 'psa_used_units', 'trg_psa_reject_identical', 'psa_billed_guard'))
    || ' · Kind watched: ' ||
    (SELECT (pg_get_triggerdef(t.oid) LIKE '%unit_kind%')::text FROM pg_trigger t
      WHERE t.tgrelid = 'public.person_service_authorizations'::regclass AND t.tgname = 'psa_used_units'),
    'psa_audit, psa_billed_guard, psa_used_units, trg_psa_reject_identical · Kind watched: true'
  UNION ALL
  SELECT 9, 'payment file: the line filler accepts S; the day count has an S rule',
    (SELECT ((SELECT prosrc FROM pg_proc WHERE oid = 'public.e520_fill_line(uuid,uuid,jsonb,integer)'::regprocedure) LIKE '%''Q'', ''D'', ''M'', ''S''%'
         AND (SELECT prosrc FROM pg_proc WHERE oid = 'public.e520_day_units(uuid,uuid,text,uuid,text,boolean,date)'::regprocedure) LIKE '%p_unit = ''S''%')::text),
    'true'
  UNION ALL
  SELECT 10, 'who may call what: signed-in users may call the kind, this-month and flag functions; not the internals',
    (has_function_privilege('authenticated', 'public.provly_auth_kind(text,uuid)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.provly_auth_used_in_month(uuid,date)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.notes_without_authorization(uuid[])', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.notes_without_authorization(uuid[])', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.provly_note_auth_state(uuid,uuid,uuid,date,uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.provly_auth_used_units(uuid,uuid,uuid,date,date,uuid,text)', 'EXECUTE'))::text,
    'true'
  UNION ALL
  SELECT 11, '(info) service notes on file with no covering authorization now — lapse / never had — for you to read',
    (SELECT format('%s lapse · %s never had', count(*) FILTER (WHERE s.st = 'lapse'), count(*) FILTER (WHERE s.st = 'none'))
       FROM public.service_notes n
      CROSS JOIN LATERAL (SELECT public.provly_note_auth_state(n.org_id, n.person_id, n.service_code_id, n.service_date, n.context_id) AS st) s
      WHERE s.st <> 'covered'),
    '(read)'
  UNION ALL
  SELECT 20 + t.n, t.item, t.value, t.want FROM v20026_selftest t
  UNION ALL
  SELECT 200, 'left behind by the self-test (test client, its payment file, its notes, its audit rows)',
    (SELECT (SELECT count(*) FROM public.persons WHERE identification_number = '099999926')
            + (SELECT count(*) FROM public.e520_batches WHERE source_filename = 'selftest-v20026.csv')
            + (SELECT count(*) FROM public.service_notes WHERE summary_note = 'v20.0.26 self-test')
            + (SELECT count(*) FROM public.audit_log WHERE new_data->>'approval_id' LIKE 'SELFTEST%'))::text,
    '0'
) v ORDER BY n;
