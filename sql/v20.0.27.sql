-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.27 — renewals (docs/authorizations-design.md v1.0, Decisions D2, D3, D4)
--   D2  person_reviews: a review list per client — type (Medicaid · DWS · PCSP
--       meeting · Other with a name), next due date, last completed date, note.
--       Completing one records the date and takes the next due date (one
--       UPDATE; audited as review_completed). Manage tier reads and writes.
--   D3  renewal_warnings(): the one source for the Dashboard's "Renewals &
--       budgets" card and the Compliance section (and, later, the weekly email
--       digest), manage tier only. Thresholds 60 / 30 / 14 days:
--         budget_end  a client + code whose latest row ends within 60 days with
--                     no later row entered — or ended within the last 60 days
--                     with none (after that the service is treated as ended;
--                     notes delivered during a longer lapse stay flagged by D1)
--         review_due  a review due within 60 days, or overdue
--         run_out     D4: a row in its dates with 30+ days of history whose
--                     actual pace uses its units up before the row ends; and,
--                     as the backstop, a row whose units are all used
--   Active clients only (not discharged).
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction;
-- preflight stops before any change if v20.0.26 isn't live; a self-test runs
-- and is rolled back; any failure rolls back the whole file. The last
-- statement is the verification table — paste it into chat.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

-- ── 0. Preflight ─────────────────────────────────────────────────────────
DO $$
DECLARE
  v_missing text[] := '{}';
BEGIN
  IF to_regprocedure('public.provly_auth_kind(text,uuid)') IS NULL THEN v_missing := v_missing || 'v20.0.26 (provly_auth_kind)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND table_name = 'person_service_authorizations' AND column_name = 'max_units_per_month') THEN
    v_missing := v_missing || 'v20.0.26 (max_units_per_month)'::text;
  END IF;
  -- r1: the tenant-bound FK needs a unique index on exactly persons (id, org_id), under any name —
  -- v20.0.23 only creates persons_id_org_uq when an equivalent index (v20.0.4g) isn't already there
  IF NOT EXISTS (
    SELECT 1
      FROM pg_index i
     WHERE i.indrelid = 'public.persons'::regclass
       AND i.indisunique AND i.indpred IS NULL AND i.indnkeyatts = 2
       AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text)
              FROM pg_attribute a
             WHERE a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)) = ARRAY['id', 'org_id']
  ) THEN
    v_missing := v_missing || 'a unique index on persons (id, org_id)'::text;
  END IF;
  IF to_regprocedure('public.my_staff_id()') IS NULL THEN v_missing := v_missing || 'function my_staff_id()'::text; END IF;
  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'v20.0.27 stopped before changing anything — production is missing: %. Paste this message into chat.',
      array_to_string(v_missing, '; ');
  END IF;
END $$;

-- ── 1. D2: the review list ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.person_reviews (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id               uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  person_id            uuid NOT NULL,
  review_type          text NOT NULL,              -- medicaid · dws · pcsp · other
  other_name           text,                       -- required for 'other'
  due_date             date NOT NULL,              -- the next one due
  last_completed_date  date,
  note                 text,
  created_by           uuid REFERENCES public.staff (id) ON DELETE SET NULL,   -- set by trigger
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT person_reviews_person_org_fk FOREIGN KEY (person_id, org_id)
    REFERENCES public.persons (id, org_id) ON DELETE CASCADE,
  CONSTRAINT person_reviews_type_chk CHECK (review_type IN ('medicaid', 'dws', 'pcsp', 'other')),
  CONSTRAINT person_reviews_other_name_chk
    CHECK (review_type <> 'other' OR length(btrim(coalesce(other_name, ''))) > 0),
  CONSTRAINT person_reviews_due_after_done_chk
    CHECK (last_completed_date IS NULL OR due_date > last_completed_date)
);
CREATE INDEX IF NOT EXISTS person_reviews_org_idx ON public.person_reviews (org_id, due_date);
-- one entry per review type per client ('other' entries are one per name)
CREATE UNIQUE INDEX IF NOT EXISTS person_reviews_one_per_type
  ON public.person_reviews (person_id, review_type) WHERE review_type <> 'other';
CREATE UNIQUE INDEX IF NOT EXISTS person_reviews_one_per_other_name
  ON public.person_reviews (person_id, lower(btrim(other_name))) WHERE review_type = 'other';

COMMENT ON TABLE public.person_reviews IS
  'v20.0.27 (authorizations design D2): a client''s recurring reviews (Medicaid, DWS, PCSP meeting, other). Completing one records the date and takes the next due date. Manage tier reads and writes; renewal_warnings() warns 60/30/14 days ahead and when overdue.';

-- 1a. stamps: created_by = the signed-in staff record; a review never moves client or org;
--     a completion can't be dated in the future (Mountain Time)
CREATE OR REPLACE FUNCTION public.trg_person_reviews_stamp()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.last_completed_date IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.last_completed_date IS DISTINCT FROM OLD.last_completed_date)
     AND NEW.last_completed_date > (now() AT TIME ZONE 'America/Denver')::date THEN
    RAISE EXCEPTION 'A review can''t be marked completed on a future date';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF auth.uid() IS NOT NULL THEN NEW.created_by := public.my_staff_id(); END IF;
    NEW.created_at := now();
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  IF NEW.person_id IS DISTINCT FROM OLD.person_id OR NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'A review stays with its client';
  END IF;
  NEW.created_by := OLD.created_by;
  NEW.created_at := OLD.created_at;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS person_reviews_stamp ON public.person_reviews;
CREATE TRIGGER person_reviews_stamp
  BEFORE INSERT OR UPDATE ON public.person_reviews
  FOR EACH ROW EXECUTE FUNCTION public.trg_person_reviews_stamp();

-- 1b. audit: every add, change, completion and delete by a signed-in user
CREATE OR REPLACE FUNCTION public.trg_person_reviews_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (NEW.org_id, auth.uid(), 'review_added', 'person_reviews', NEW.id, NULL, to_jsonb(NEW));
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (NEW.org_id, auth.uid(),
            CASE WHEN NEW.last_completed_date IS DISTINCT FROM OLD.last_completed_date THEN 'review_completed' ELSE 'review_changed' END,
            'person_reviews', NEW.id, to_jsonb(OLD), to_jsonb(NEW));
  ELSE
    INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (OLD.org_id, auth.uid(), 'review_deleted', 'person_reviews', OLD.id, to_jsonb(OLD), NULL);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS person_reviews_audit ON public.person_reviews;
CREATE TRIGGER person_reviews_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.person_reviews
  FOR EACH ROW EXECUTE FUNCTION public.trg_person_reviews_audit();

-- 1c. RLS: the v20.0.12 tenant guard (claim + live membership); manage tier reads and writes
ALTER TABLE public.person_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.person_reviews FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.person_reviews TO authenticated;

DROP POLICY IF EXISTS person_reviews_tenant_guard ON public.person_reviews;
CREATE POLICY person_reviews_tenant_guard ON public.person_reviews
  AS RESTRICTIVE FOR ALL TO authenticated
  USING      (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL);

DROP POLICY IF EXISTS person_reviews_read_tier ON public.person_reviews;
CREATE POLICY person_reviews_read_tier ON public.person_reviews
  FOR SELECT TO authenticated
  USING ((SELECT public.access_tier()) = 'manage');

DROP POLICY IF EXISTS person_reviews_insert_tier ON public.person_reviews;
CREATE POLICY person_reviews_insert_tier ON public.person_reviews
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.access_tier()) = 'manage');

DROP POLICY IF EXISTS person_reviews_update_tier ON public.person_reviews;
CREATE POLICY person_reviews_update_tier ON public.person_reviews
  FOR UPDATE TO authenticated
  USING      ((SELECT public.access_tier()) = 'manage')
  WITH CHECK ((SELECT public.access_tier()) = 'manage');

DROP POLICY IF EXISTS person_reviews_delete_tier ON public.person_reviews;
CREATE POLICY person_reviews_delete_tier ON public.person_reviews
  FOR DELETE TO authenticated
  USING ((SELECT public.access_tier()) = 'manage');

-- ── 2. D3 + D4: the warnings ─────────────────────────────────────────────
-- o_level: 0 = ended / overdue / all used · 14 · 30 · 60 · 999 = a projected run-out further out
-- o_days:  o_date minus today (negative = past)
-- A signed-in caller gets their own org, today's date, and nothing at all below the manage
-- tier. p_org / p_today are honoured only without a signed-in user (service role: the
-- future email digest, and this file's self-test).
CREATE OR REPLACE FUNCTION public.renewal_warnings(p_org uuid DEFAULT NULL, p_today date DEFAULT NULL)
RETURNS TABLE (o_kind text, o_level integer, o_person_id uuid, o_person_name text, o_label text,
               o_date date, o_days integer, o_detail text, o_ref_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_org   uuid := p_org;
  v_today date := coalesce(p_today, (now() AT TIME ZONE 'America/Denver')::date);
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF public.access_tier() IS DISTINCT FROM 'manage' THEN RETURN; END IF;
    v_org := public.org_id();
    IF v_org IS NULL THEN RETURN; END IF;
    v_today := (now() AT TIME ZONE 'America/Denver')::date;
  END IF;

  RETURN QUERY
  WITH active AS (
    SELECT p.id, btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')) AS nm
      FROM persons p
     WHERE (v_org IS NULL OR p.org_id = v_org)
       AND p.is_active = true
       AND (p.discharge_date IS NULL OR p.discharge_date >= v_today)
  ),
  live_rows AS (
    SELECT a.id, a.person_id, a.service_code_id, a.start_date, a.end_date,
           a.authorized_units, a.used_units, a.unit_kind, c.code, act.nm
      FROM person_service_authorizations a
      JOIN active act ON act.id = a.person_id
      JOIN service_code_definitions c ON c.id = a.service_code_id
     WHERE lower(a.status::text) NOT IN ('rejected', 'closed', 'terminated', 'denied', 'inactive', 'cancelled', 'canceled')
  ),
  latest AS (                                  -- each client + code's last row (an open-ended row never ends)
    SELECT DISTINCT ON (r.person_id, r.service_code_id) r.*
      FROM live_rows r
     ORDER BY r.person_id, r.service_code_id, r.end_date DESC NULLS FIRST
  ),
  budget_end AS (
    SELECT 'budget_end'::text AS k, l.person_id, l.nm, l.code AS lbl, l.end_date AS d, (l.end_date - v_today) AS dd, l.id AS ref,
           CASE WHEN l.end_date < v_today
                THEN format('Budget ended %s %s ago — no renewal row entered', v_today - l.end_date,
                            CASE WHEN v_today - l.end_date = 1 THEN 'day' ELSE 'days' END)
                ELSE format('Budget ends in %s %s — no later row entered', l.end_date - v_today,
                            CASE WHEN l.end_date - v_today = 1 THEN 'day' ELSE 'days' END) END AS det
      FROM latest l
     WHERE l.end_date IS NOT NULL AND l.end_date BETWEEN v_today - 60 AND v_today + 60
  ),
  current_rows AS (
    SELECT r.*, (v_today - r.start_date) AS elapsed
      FROM live_rows r
     WHERE r.start_date <= v_today AND (r.end_date IS NULL OR r.end_date >= v_today)
       AND r.authorized_units > 0
  ),
  run_out AS (
    -- the backstop: all units used while the row still runs
    SELECT 'run_out'::text AS k, c.person_id, c.nm, c.code AS lbl, v_today AS d, 0 AS dd, c.id AS ref,
           format('All %s units used — the row runs to %s', c.authorized_units, to_char(c.end_date, 'FMMM/FMDD/YYYY')) AS det
      FROM current_rows c
     WHERE c.used_units >= c.authorized_units
    UNION ALL
    -- D4: at the actual pace (30+ days of history), the units run out before the row ends
    SELECT 'run_out'::text, p.person_id, p.nm, p.code, p.runout, (p.runout - v_today), p.id,
           format('At this pace, runs out around %s — %s %s before the row ends (%s of %s units used)',
                  to_char(p.runout, 'FMMM/FMDD/YYYY'), p.end_date - p.runout,
                  CASE WHEN p.end_date - p.runout = 1 THEN 'day' ELSE 'days' END, p.used_units, p.authorized_units)
      FROM (SELECT c.*, v_today + floor((c.authorized_units - c.used_units)::numeric * c.elapsed / c.used_units)::integer AS runout
              FROM current_rows c
             WHERE c.elapsed >= 30 AND c.used_units > 0 AND c.used_units < c.authorized_units) p
     WHERE p.end_date IS NOT NULL AND p.runout < p.end_date
  ),
  review_due AS (
    SELECT 'review_due'::text AS k, rv.person_id, act.nm,
           CASE rv.review_type WHEN 'medicaid' THEN 'Medicaid' WHEN 'dws' THEN 'DWS'
                               WHEN 'pcsp' THEN 'PCSP meeting' ELSE rv.other_name END AS lbl,
           rv.due_date AS d, (rv.due_date - v_today) AS dd, rv.id AS ref,
           CASE WHEN rv.due_date < v_today
                THEN format('Overdue by %s %s', v_today - rv.due_date, CASE WHEN v_today - rv.due_date = 1 THEN 'day' ELSE 'days' END)
                WHEN rv.due_date = v_today THEN 'Due today'
                ELSE format('Due in %s %s', rv.due_date - v_today, CASE WHEN rv.due_date - v_today = 1 THEN 'day' ELSE 'days' END) END AS det
      FROM person_reviews rv
      JOIN active act ON act.id = rv.person_id
     WHERE rv.due_date <= v_today + 60
  ),
  allw AS (
    SELECT * FROM budget_end UNION ALL SELECT * FROM run_out UNION ALL SELECT * FROM review_due
  )
  -- r2: every column cast to the declared result type (the service code is varchar, and a
  -- UNION keeps the first branch's type — RETURN QUERY needs text exactly)
  SELECT w.k::text,
         (CASE WHEN w.dd < 0 OR (w.k = 'run_out' AND w.dd = 0) THEN 0
               WHEN w.dd <= 14 THEN 14 WHEN w.dd <= 30 THEN 30 WHEN w.dd <= 60 THEN 60 ELSE 999 END)::integer,
         w.person_id::uuid, w.nm::text, w.lbl::text, w.d::date, w.dd::integer, w.det::text, w.ref::uuid
    FROM allw w
   ORDER BY 2, w.dd, w.nm, w.lbl;
END;
$$;

REVOKE ALL ON FUNCTION public.renewal_warnings(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.renewal_warnings(uuid, date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.trg_person_reviews_stamp() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_person_reviews_audit() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 3. Self-test (synthetic clients, 2001 dates, "today" = 2001-03-01), rolled back
CREATE TEMP TABLE IF NOT EXISTS v20027_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20027_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20027_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.27 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res     jsonb := '[]'::jsonb;
  v_fail    text;
  v_org     uuid;
  v_staff   uuid;
  v_pba uuid; v_hhs uuid; v_sln uuid; v_dsg uuid;
  v_person  uuid;
  v_gone    uuid;
  v_rev     uuid;
  v_txt     text;
  v_msg     text;
  v_n       integer;
  i         integer;
  v_step    text := 'setup';
  v_today   date := DATE '2001-03-01';
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s.org_id INTO v_org FROM staff s ORDER BY s.created_at NULLS LAST, s.id LIMIT 1;
  SELECT s.id INTO v_staff FROM staff s WHERE s.org_id = v_org ORDER BY s.id LIMIT 1;
  SELECT id INTO v_pba FROM service_code_definitions WHERE code = 'PBA' LIMIT 1;
  SELECT id INTO v_hhs FROM service_code_definitions WHERE code = 'HHS' LIMIT 1;
  SELECT id INTO v_sln FROM service_code_definitions WHERE code = 'SLN' LIMIT 1;
  SELECT id INTO v_dsg FROM service_code_definitions WHERE code = 'DSG' LIMIT 1;

  BEGIN
    v_step := 'creating the test clients';
    v_person := pg_temp.v20027_test_insert('persons', jsonb_build_object(
      'org_id', v_org, 'first_name', 'V20027', 'last_name', 'Selftest', 'identification_number', '099999928', 'is_active', true));
    v_gone := pg_temp.v20027_test_insert('persons', jsonb_build_object(
      'org_id', v_org, 'first_name', 'V20027', 'last_name', 'Inactive', 'identification_number', '099999929', 'is_active', false));

    v_step := 'creating the 1056 rows';
    -- PBA ends Mar 20 (19 days), no later row; 2 sessions used — pace far too slow to run out
    PERFORM pg_temp.v20027_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_pba, 'authorized_units', 12, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-03-20',
      'rate_per_unit', 18.59, 'status', 'approved', 'unit_kind', 'S', 'max_units_per_month', 4));
    -- HHS ended Feb 15 (14 days ago), no renewal entered
    PERFORM pg_temp.v20027_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_hhs, 'authorized_units', 77, 'used_units', 0, 'start_date', '2000-12-01', 'end_date', '2001-02-15',
      'rate_per_unit', 100, 'status', 'approved', 'unit_kind', 'D', 'max_units_per_month', 31));
    -- DSG ended Feb 10, but the renewal row is entered → no warning
    PERFORM pg_temp.v20027_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_dsg, 'authorized_units', 300, 'used_units', 0, 'start_date', '2000-02-11', 'end_date', '2001-02-10',
      'rate_per_unit', 100, 'status', 'approved', 'unit_kind', 'D', 'max_units_per_month', 31));
    PERFORM pg_temp.v20027_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_dsg, 'authorized_units', 300, 'used_units', 0, 'start_date', '2001-02-11', 'end_date', '2002-02-10',
      'rate_per_unit', 100, 'status', 'approved', 'unit_kind', 'D', 'max_units_per_month', 31));
    -- SLN all year, 100 sessions; 40 used in the first 59 days → runs out around May 28
    PERFORM pg_temp.v20027_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_sln, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-12-31',
      'rate_per_unit', 10, 'status', 'approved', 'unit_kind', 'S', 'max_units_per_month', 40));
    -- the inactive client's budget ends Mar 5 → never shown
    PERFORM pg_temp.v20027_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_gone,
      'service_code_id', v_pba, 'authorized_units', 12, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-03-05',
      'rate_per_unit', 18.59, 'status', 'approved', 'unit_kind', 'S', 'max_units_per_month', 4));

    v_step := 'creating the notes';
    FOR i IN 1 .. 2 LOOP                                         -- two PBA sessions, back to back (no overlaps)
      PERFORM pg_temp.v20027_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
        'service_code_id', v_pba, 'service_date', '2001-01-12',
        'start_time', (TIME '09:00' + (i - 1) * INTERVAL '30 minutes')::text,
        'end_time', (TIME '09:30' + (i - 1) * INTERVAL '30 minutes')::text, 'duration_minutes', 30,
        'billable_units', 1, 'summary_note', 'v20.0.27 self-test', 'status', 'approved'));
    END LOOP;
    FOR i IN 1 .. 40 LOOP                                        -- forty SLN sessions, back to back from 08:00 (no overlaps)
      PERFORM pg_temp.v20027_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
        'service_code_id', v_sln, 'service_date', '2001-01-10',
        'start_time', (TIME '08:00' + (i - 1) * INTERVAL '15 minutes')::text,
        'end_time', (TIME '08:15' + (i - 1) * INTERVAL '15 minutes')::text, 'duration_minutes', 15,
        'billable_units', 1, 'summary_note', 'v20.0.27 self-test', 'status', 'approved'));
    END LOOP;

    v_step := 'creating the reviews';
    v_rev := pg_temp.v20027_test_insert('person_reviews', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'review_type', 'medicaid', 'due_date', '2001-03-10'));
    PERFORM pg_temp.v20027_test_insert('person_reviews', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'review_type', 'pcsp', 'due_date', '2001-02-20'));
    PERFORM pg_temp.v20027_test_insert('person_reviews', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'review_type', 'dws', 'due_date', '2001-06-30'));

    -- W1: every warning for the test clients, as of Mar 1 2001
    v_step := 'W1 warnings';
    SELECT string_agg(format('%s:%s:%s:%s', w.o_kind, w.o_label, w.o_level, w.o_days), ' | ' ORDER BY w.o_kind, w.o_label)
      INTO v_txt FROM public.renewal_warnings(v_org, v_today) AS w WHERE w.o_person_id IN (v_person, v_gone);
    v_res := v_res || jsonb_build_array(jsonb_build_array(1,
      'W1 warnings: PBA ends in 19 days, HHS ended 14 days ago, DSG renewed, SLN at pace, reviews due in 9 / overdue 9 / in 121, inactive client',
      coalesce(v_txt, 'none'),
      'budget_end:HHS:0:-14 | budget_end:PBA:30:19 | review_due:Medicaid:14:9 | review_due:PCSP meeting:0:-9 | run_out:SLN:999:88'));

    -- W2: the run-out date and its wording
    v_step := 'W2 run-out detail';
    SELECT w.o_date::text || ' · ' || w.o_detail INTO v_txt
      FROM public.renewal_warnings(v_org, v_today) AS w WHERE w.o_person_id = v_person AND w.o_kind = 'run_out';
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'W2 the SLN run-out projection', v_txt,
      '2001-05-28 · At this pace, runs out around 5/28/2001 — 217 days before the row ends (40 of 100 units used)'));

    -- W3: below the manage tier the warnings are empty
    v_step := 'W3 tier gate';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_n FROM public.renewal_warnings(v_org, v_today);
    PERFORM set_config('request.jwt.claims', '{}', true);
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'W3 a signed-in user below the manage tier gets no warnings', v_n::text, '0'));

    -- R1: the review rules
    v_step := 'R1 review rules';
    v_msg := '';
    BEGIN
      PERFORM pg_temp.v20027_test_insert('person_reviews', jsonb_build_object('org_id', v_org, 'person_id', v_person,
        'review_type', 'medicaid', 'due_date', '2001-09-01'));
      v_msg := v_msg || 'second Medicaid ALLOWED';
    EXCEPTION WHEN unique_violation THEN v_msg := v_msg || 'second Medicaid refused';
    END;
    BEGIN
      PERFORM pg_temp.v20027_test_insert('person_reviews', jsonb_build_object('org_id', v_org, 'person_id', v_person,
        'review_type', 'other', 'other_name', '   ', 'due_date', '2001-09-01'));
      v_msg := v_msg || '; unnamed other ALLOWED';
    EXCEPTION WHEN check_violation THEN v_msg := v_msg || '; unnamed other refused';
    END;
    BEGIN
      UPDATE person_reviews SET last_completed_date = (now() AT TIME ZONE 'America/Denver')::date + 5, due_date = (now() AT TIME ZONE 'America/Denver')::date + 400 WHERE id = v_rev;
      v_msg := v_msg || '; future completion ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; future completion refused';
    END;
    BEGIN
      UPDATE person_reviews SET last_completed_date = DATE '2001-03-01', due_date = DATE '2001-02-01' WHERE id = v_rev;
      v_msg := v_msg || '; next due before completion ALLOWED';
    EXCEPTION WHEN check_violation THEN v_msg := v_msg || '; next due before completion refused';
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'R1 review rules: a second Medicaid, an unnamed Other, a future completion, a next due before the completion',
      v_msg, 'second Medicaid refused; unnamed other refused; future completion refused; next due before completion refused'));

    -- R2: completing a review records the date, takes the next due date, clears the warning, and is audited
    v_step := 'R2 completing a review';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    UPDATE person_reviews SET last_completed_date = DATE '2001-03-01', due_date = DATE '2002-03-01' WHERE id = v_rev;
    PERFORM set_config('request.jwt.claims', '{}', true);
    SELECT count(*) INTO v_n FROM public.renewal_warnings(v_org, v_today) AS w WHERE w.o_ref_id = v_rev;
    SELECT format('warning rows %s; audit %s', v_n,
                  (SELECT string_agg(action, ',') FROM audit_log WHERE record_id = v_rev)) INTO v_txt;
    v_res := v_res || jsonb_build_array(jsonb_build_array(5, 'R2 completing the Medicaid review (next due a year out)', v_txt,
      'warning rows 0; audit review_completed'));

    RAISE EXCEPTION 'v20027_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20027_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);

  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 5 THEN
    RAISE EXCEPTION 'v20.0.27 self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 5 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20027_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20027_test_insert(text, jsonb);

COMMIT;


-- ── 4. Verification — paste this table into chat before the PR merges ───
SELECT * FROM (
  SELECT 1 AS n, 'person_reviews: table, constraints, unique-per-type indexes' AS check_item,
    ((to_regclass('public.person_reviews') IS NOT NULL)::text || ' · ' ||
     (SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.person_reviews'::regclass
        AND conname IN ('person_reviews_person_org_fk', 'person_reviews_type_chk', 'person_reviews_other_name_chk', 'person_reviews_due_after_done_chk')) || ' · ' ||
     (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname IN ('person_reviews_one_per_type', 'person_reviews_one_per_other_name'))) AS value,
    'true · 4 · 2' AS want
  UNION ALL
  SELECT 2, 'person_reviews: RLS on; tenant guard + manage-only read / insert / update / delete',
    ((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.person_reviews'::regclass)::text || ' · ' ||
     (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'person_reviews')),
    'true · 5'
  UNION ALL
  SELECT 3, 'person_reviews: stamp and audit triggers',
    (SELECT string_agg(tgname, ', ' ORDER BY tgname) FROM pg_trigger
      WHERE tgrelid = 'public.person_reviews'::regclass AND NOT tgisinternal),
    'person_reviews_audit, person_reviews_stamp'
  UNION ALL
  SELECT 4, 'who may call the warnings: signed-in users (gated to manage inside), not anonymous',
    (has_function_privilege('authenticated', 'public.renewal_warnings(uuid,date)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.renewal_warnings(uuid,date)', 'EXECUTE'))::text,
    'true'
  UNION ALL
  SELECT 5, '(info) warnings for your org right now — budget ends / reviews due / run-outs — for you to read',
    (SELECT format('%s budget ends · %s reviews due · %s run-outs',
                   count(*) FILTER (WHERE o_kind = 'budget_end'), count(*) FILTER (WHERE o_kind = 'review_due'),
                   count(*) FILTER (WHERE o_kind = 'run_out'))
       FROM public.renewal_warnings()),
    '(read)'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20027_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test (test clients, their notes)',
    ((SELECT count(*) FROM public.persons WHERE identification_number IN ('099999928', '099999929'))
     + (SELECT count(*) FROM public.service_notes WHERE summary_note = 'v20.0.27 self-test'))::text,
    '0'
) v ORDER BY n;
