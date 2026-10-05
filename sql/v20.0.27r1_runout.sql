-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.27 r1 — run-outs: a row with units left is never "used up" (Greptile r1, P1)
--   renewal_warnings() projected the run-out as today + floor(remaining ÷ pace).
--   With less than a day of units left at the current pace, floor() put the
--   run-out at today, which the card shows as "Used up" while units remain.
--   Now ceil(): with any units left the run-out is at least tomorrow, and
--   "Used up" means exactly that — every unit used. Otherwise unchanged from
--   sql/v20.0.27.sql.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction;
-- a self-test runs and is rolled back; any failure rolls back the whole file.
-- The last statement is the verification table — paste it into chat.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public.renewal_warnings(uuid,date)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.27 r1 stopped before changing anything — run sql/v20.0.27.sql first. Paste this message into chat.';
  END IF;
END $$;

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
      -- r1: ceil — with units left, the run-out is never today (today is only "all used")
      FROM (SELECT c.*, v_today + ceil((c.authorized_units - c.used_units)::numeric * c.elapsed / c.used_units)::integer AS runout
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

-- ── Self-test ("today" = 2001-03-01), rolled back
CREATE TEMP TABLE IF NOT EXISTS v20027r1_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20027r1_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20027r1_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.27r1 self-test') || '::' || c.typ END;
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
  v_pba uuid; v_sln uuid; v_hhs uuid;
  v_person uuid;
  v_txt    text;
  i        integer;
  v_step   text := 'setup';
  v_today  date := DATE '2001-03-01';
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s.org_id INTO v_org FROM staff s ORDER BY s.created_at NULLS LAST, s.id LIMIT 1;
  SELECT s.id INTO v_staff FROM staff s WHERE s.org_id = v_org ORDER BY s.id LIMIT 1;
  SELECT id INTO v_pba FROM service_code_definitions WHERE code = 'PBA' LIMIT 1;
  SELECT id INTO v_sln FROM service_code_definitions WHERE code = 'SLN' LIMIT 1;
  SELECT id INTO v_hhs FROM service_code_definitions WHERE code = 'HHS' LIMIT 1;

  BEGIN
    v_step := 'creating the test client and rows';
    v_person := pg_temp.v20027r1_test_insert('persons', jsonb_build_object(
      'org_id', v_org, 'first_name', 'V20027R1', 'last_name', 'Selftest', 'identification_number', '099999930', 'is_active', true));
    -- PBA: 39 of 40 sessions in the 30 days since Jan 30 — under a day of units left at this pace
    PERFORM pg_temp.v20027r1_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_pba, 'authorized_units', 40, 'used_units', 0, 'start_date', '2001-01-30', 'end_date', '2001-12-31',
      'rate_per_unit', 18.59, 'status', 'approved', 'unit_kind', 'S', 'max_units_per_month', 40));
    -- SLN: 40 of 100 in the 59 days since Jan 1 (the v20.0.27 case)
    PERFORM pg_temp.v20027r1_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_sln, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-12-31',
      'rate_per_unit', 10, 'status', 'approved', 'unit_kind', 'S', 'max_units_per_month', 40));
    -- HHS (as sessions): 2 of 2 used — truly used up
    PERFORM pg_temp.v20027r1_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_hhs, 'authorized_units', 2, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-12-31',
      'rate_per_unit', 100, 'status', 'approved', 'unit_kind', 'S', 'max_units_per_month', 31));

    v_step := 'creating the notes';
    FOR i IN 1 .. 39 LOOP
      PERFORM pg_temp.v20027r1_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
        'service_code_id', v_pba, 'service_date', '2001-02-05',
        'start_time', (TIME '06:00' + (i - 1) * INTERVAL '15 minutes')::text,
        'end_time', (TIME '06:15' + (i - 1) * INTERVAL '15 minutes')::text, 'duration_minutes', 15,
        'billable_units', 1, 'summary_note', 'v20.0.27r1 self-test', 'status', 'approved'));
    END LOOP;
    FOR i IN 1 .. 40 LOOP
      PERFORM pg_temp.v20027r1_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
        'service_code_id', v_sln, 'service_date', '2001-01-10',
        'start_time', (TIME '08:00' + (i - 1) * INTERVAL '15 minutes')::text,
        'end_time', (TIME '08:15' + (i - 1) * INTERVAL '15 minutes')::text, 'duration_minutes', 15,
        'billable_units', 1, 'summary_note', 'v20.0.27r1 self-test', 'status', 'approved'));
    END LOOP;
    FOR i IN 1 .. 2 LOOP
      PERFORM pg_temp.v20027r1_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
        'service_code_id', v_hhs, 'service_date', '2001-01-20',
        'start_time', (TIME '09:00' + (i - 1) * INTERVAL '30 minutes')::text,
        'end_time', (TIME '09:30' + (i - 1) * INTERVAL '30 minutes')::text, 'duration_minutes', 30,
        'billable_units', 1, 'summary_note', 'v20.0.27r1 self-test', 'status', 'approved'));
    END LOOP;

    v_step := 'reading the run-outs';
    SELECT string_agg(format('%s:%s:%s', w.o_label, w.o_level, w.o_days), ' | ' ORDER BY w.o_label)
      INTO v_txt FROM public.renewal_warnings(v_org, v_today) AS w WHERE w.o_person_id = v_person AND w.o_kind = 'run_out';
    v_res := v_res || jsonb_build_array(jsonb_build_array(1,
      'R1 run-outs: HHS 2 of 2 used, PBA 39 of 40 (under a day left), SLN 40 of 100 at 59 days',
      coalesce(v_txt, 'none'), 'HHS:0:0 | PBA:14:1 | SLN:999:89'));

    SELECT string_agg(w.o_label || ' ' || w.o_detail, ' | ' ORDER BY w.o_label)
      INTO v_txt FROM public.renewal_warnings(v_org, v_today) AS w WHERE w.o_person_id = v_person AND w.o_kind = 'run_out';
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'R2 the wording', v_txt,
      'HHS All 2 units used — the row runs to 12/31/2001 | PBA At this pace, runs out around 3/2/2001 — 304 days before the row ends (39 of 40 units used) | SLN At this pace, runs out around 5/29/2001 — 216 days before the row ends (40 of 100 units used)'));

    RAISE EXCEPTION 'v20027r1_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20027r1_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);

  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 2 THEN
    RAISE EXCEPTION 'v20.0.27 r1 self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 2 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20027r1_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20027r1_test_insert(text, jsonb);

COMMIT;


-- ── Verification — paste this table into chat before the PR merges ─────
SELECT * FROM (
  SELECT 1 AS n, 'the run-out projection rounds up (ceil), never down' AS check_item,
    ((SELECT prosrc FROM pg_proc WHERE oid = 'public.renewal_warnings(uuid,date)'::regprocedure) LIKE '%v_today + ceil((c.authorized_units%'
     AND (SELECT prosrc FROM pg_proc WHERE oid = 'public.renewal_warnings(uuid,date)'::regprocedure) NOT LIKE '%v_today + floor(%')::text AS value,
    'true' AS want
  UNION ALL
  SELECT 2, 'who may call the warnings: signed-in users (gated to manage inside), not anonymous',
    (has_function_privilege('authenticated', 'public.renewal_warnings(uuid,date)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.renewal_warnings(uuid,date)', 'EXECUTE'))::text, 'true'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20027r1_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test (test client, its notes)',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999930')
     + (SELECT count(*) FROM public.service_notes WHERE summary_note = 'v20.0.27r1 self-test'))::text, '0'
) v ORDER BY n;
