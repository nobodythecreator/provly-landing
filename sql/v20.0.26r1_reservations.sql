-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.26 r1 — payment file: reserve only the S notes that billed (Greptile r1, P1)
--   A payment line reserves the notes behind it (e520_line_notes) so no note is
--   claimed twice. For D and M a day is one unit and every note that day stays
--   with it; for Q the day's minutes are rounded as one total. But an S (per
--   session) note is its own unit: when the EVV visits or the month's cap leave a
--   session unbilled, its share is 0 — and v20.0.26 still reserved it, so marking
--   the file uploaded would lock an unbilled note out of every supplemental file.
--   Now an S note is reserved only when it billed a unit; D / M / Q unchanged.
--   e520_fill_line is otherwise exactly as installed by v20.0.26.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction;
-- a self-test runs and is rolled back; any failure rolls back the whole file.
-- The last statement is the verification table — paste it into chat.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

-- ── 0. Preflight: v20.0.26 must be live (the filler already accepts S) ──
DO $$
BEGIN
  IF to_regprocedure('public.e520_fill_line(uuid,uuid,jsonb,integer)') IS NULL
     OR (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure('public.e520_fill_line(uuid,uuid,jsonb,integer)'))
          NOT LIKE '%''Q'', ''D'', ''M'', ''S''%' THEN
    RAISE EXCEPTION 'v20.0.26 r1 stopped before changing anything — run sql/v20.0.26.sql first. Paste this message into chat.';
  END IF;
END $$;

-- ── 1. The line filler ───────────────────────────────────────────────────
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
           WHERE (dd->>'used')::integer > 0
             AND (v_unit <> 'S' OR (n->>'u')::integer > 0);   -- v20.0.26 r1: an S note that billed nothing stays free for a supplemental file
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

REVOKE ALL ON FUNCTION public.e520_fill_line(uuid, uuid, jsonb, integer) FROM PUBLIC, anon, authenticated;

-- ── 2. Self-test: three approved PBA sessions on one day, a UPI line whose
--       monthly max leaves room for two. Rolled back.
CREATE TEMP TABLE IF NOT EXISTS v20026r1_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20026r1_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20026r1_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.26r1 self-test') || '::' || c.typ END;
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
  v_person uuid;
  v_batch  uuid;
  v_txt    text;
  v_n      integer;
  v_step   text := 'setup';
  v_hdr    text := 'line_number,provider_approver_email,consumer_name,consumer_pid,service_code,rate,unit_type,service_start_date,service_end_date,units,remaining_units,sce,monthly_max_units';
  v_line   text := '1,selftest@example.com,Selftest V20026R1,099999927,PBA,18.59,S,01/01/2001,01/31/2001,0,2,Test Coordinator,2';
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s.org_id INTO v_org FROM staff s ORDER BY s.created_at NULLS LAST, s.id LIMIT 1;
  SELECT s.id INTO v_staff FROM staff s WHERE s.org_id = v_org ORDER BY s.id LIMIT 1;
  SELECT id INTO v_pba FROM service_code_definitions WHERE code = 'PBA' LIMIT 1;

  BEGIN
    v_step := 'creating the test client, authorization and notes';
    v_person := pg_temp.v20026r1_test_insert('persons', jsonb_build_object(
      'org_id', v_org, 'first_name', 'V20026R1', 'last_name', 'Selftest', 'identification_number', '099999927', 'is_active', false));
    PERFORM pg_temp.v20026r1_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_pba, 'authorized_units', 12, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-03-31',
      'rate_per_unit', 18.59, 'status', 'approved', 'unit_kind', 'S', 'max_units_per_month', 4));
    PERFORM pg_temp.v20026r1_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-05', 'start_time', '09:00', 'end_time', '09:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26r1 self-test', 'status', 'approved'));
    PERFORM pg_temp.v20026r1_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-05', 'start_time', '11:00', 'end_time', '11:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26r1 self-test', 'status', 'approved'));
    PERFORM pg_temp.v20026r1_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-05', 'start_time', '14:00', 'end_time', '14:30', 'duration_minutes', 30,
      'billable_units', 1, 'summary_note', 'v20.0.26r1 self-test', 'status', 'approved'));

    v_step := 'building the payment file';
    v_batch := public.e520_build('selftest-v20026r1.csv', chr(65279) || v_hdr || E'\r\n' || v_line, v_org);

    -- R1: the line bills the two sessions the cap allows
    SELECT string_agg(l.action || ' ' || l.units, ', ' ORDER BY l.ord) INTO v_txt FROM e520_lines l WHERE l.batch_id = v_batch;
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'R1 line for 3 sessions on one day under a monthly max of 2', coalesce(v_txt, 'no line'), 'fill 2'));

    -- R2: only the two billed sessions are reserved
    SELECT format('%s notes, %s units', count(*), coalesce(sum(x.units), 0)) INTO v_txt
      FROM e520_line_notes x JOIN e520_lines l ON l.id = x.line_id WHERE l.batch_id = v_batch;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'R2 notes reserved on the line', v_txt, '2 notes, 2 units'));

    -- R3: the unbilled session is still free for a supplemental file
    SELECT d.o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'PBA', v_pba, 'S', false, DATE '2001-01-05') AS d;
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'R3 sessions on that day still available to bill', v_n::text, '1'));

    RAISE EXCEPTION 'v20026r1_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20026r1_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);

  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 3 THEN
    RAISE EXCEPTION 'v20.0.26 r1 self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 3 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20026r1_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20026r1_test_insert(text, jsonb);

COMMIT;


-- ── 3. Verification — paste this table into chat before the PR merges ────
SELECT * FROM (
  SELECT 1 AS n, 'the line filler reserves an S note only when it billed' AS check_item,
    ((SELECT prosrc FROM pg_proc WHERE oid = 'public.e520_fill_line(uuid,uuid,jsonb,integer)'::regprocedure)
       LIKE '%v_unit <> ''S'' OR (n->>''u'')::integer > 0%')::text AS value,
    'true' AS want
  UNION ALL
  SELECT 2, 'clients cannot call the line filler',
    (NOT has_function_privilege('authenticated', 'public.e520_fill_line(uuid,uuid,jsonb,integer)', 'EXECUTE'))::text, 'true'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20026r1_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test (test client, its payment file, its notes)',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999927')
     + (SELECT count(*) FROM public.e520_batches WHERE source_filename = 'selftest-v20026r1.csv')
     + (SELECT count(*) FROM public.service_notes WHERE summary_note = 'v20.0.26r1 self-test'))::text,
    '0'
) v ORDER BY n;
