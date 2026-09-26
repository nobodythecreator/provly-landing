-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.24a — e520 arc: HAP, authorization used units, rejected authorizations
--   HAP (rent, Sep 26 decision A): one unit for a month the client is in the
--       provider's care per the placement, whatever the circumstance (a whole
--       month in hospital or jail still bills); nothing once they are out of care
--       or after discharge; absences never split or reduce it; a partial month is
--       flagged. HAP joins the code table as a monthly code (no service notes: the
--       placement is the documentation).
--   Used units: the authorization counter now counts the way the payment file
--       does (nearest quarter hour per day; one per day for daily codes; MTP from
--       DSG ride days; HAP from months in care), matches notes by client + code +
--       date (the app never linked notes to an authorization), recomputes on every
--       note insert / update / delete (Reopen included) and on authorization date or
--       placement changes, and runs regardless of who approves.
--   Coverage: a REJECTED authorization never covers a day.
-- r1: T17–T19 read the uploaded batch (the first draft is replaced by T9's rebuild).
-- r2: verification row 2 checks each event on its own (Postgres prints them as INSERT OR DELETE OR UPDATE).
-- r3 (Greptile r1): HAP used units = months billed (live HAP lines in uploaded files),
--     recounted when a file is marked uploaded or a line released — never stale, and the
--     placement / discharge triggers go; an authorization that exists but is only rejected
--     covers nothing (only "none on file" falls back to UPI's line); a HAP or MTP service
--     note is refused by the database (HAP is documented by the placement, MTP by the DSG note).
-- r4 (Greptile r2): a billed HAP month counts toward the authorization that covers the line's
--     FIRST AUTHORIZED DAY (a Jan 1–31 line billed under an authorization from Jan 15 counts
--     for that authorization); one authorization per month when two meet mid-month; any
--     authorization change recounts the client's HAP months; a rejected authorization uses 0.
-- r5 (Greptile r3): the attribution day is the line's first day IN CARE (placement on file,
--     not after discharge) AND authorized — the days the engine billed on; placement changes
--     (both clients, if one moves) and discharge-date changes recount HAP months again.
-- 🟢 Run in the Supabase SQL editor. Idempotent. The first statement adds the
-- 'monthly' unit label and commits on its own (a new enum label can't be used in
-- the transaction that adds it); everything after it is one transaction that rolls
-- back completely if any of the 21 self-test checks fails.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 0. the 'monthly' unit label (commits on its own) ─────────────────────
DO $$
DECLARE
  v_typ text;
BEGIN
  SELECT format_type(a.atttypid, NULL) INTO v_typ
    FROM pg_attribute a
   WHERE a.attrelid = 'public.service_code_definitions'::regclass AND a.attname = 'billing_unit';
  EXECUTE format('ALTER TYPE %s ADD VALUE IF NOT EXISTS %L', v_typ, 'monthly');
END $$;
COMMIT;

BEGIN;

-- ── 1. HAP in the code table ─────────────────────────────────────────────
INSERT INTO public.service_code_definitions (code, name, sow_article, billing_unit, evv_required, description, outcome_measure)
VALUES ('HAP', 'Housing Assistance (rent)', 0, 'monthly', false,
        'Rent assistance for individuals who don''t have SSI. One unit per month the individual is in the provider''s care per their placement, whatever the circumstance that month (hospital, jail and other absences included); not billed once they are out of care or after discharge. No service notes: the placement is the documentation. sow_article 0 = not a service article.',
        'The individual stays housed in their placement')
ON CONFLICT (code) DO NOTHING;

-- ── 2. The engine's line filler: HAP rule + rejected authorizations never cover ──
-- one UPI line → filled line(s), split parts, or a removed line; returns the next free line number
-- v20.0.24a: a rejected authorization never covers a day; HAP (rent) bills one unit for a
--     month the client is in care per the placement, never reduced by absences.
-- r1: placement and authorization coverage is checked DAY BY DAY (a gap between two
--     placements or two authorizations is a break, never billed); monthly max and
--     remaining units are shared by every line for the same client, code and month.
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
  IF v_reason IS NULL AND v_unit NOT IN ('Q', 'D', 'M') THEN
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
    IF v_incare < v_total_days THEN
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'partial_month',
                   'detail', format('In care %s of %s days on this line; check whether HAP is prorated', v_incare, v_total_days)));
    END IF;
    INSERT INTO e520_lines (batch_id, org_id, ord, line_number, source_line_number, raw, person_id, service_code,
                            unit_type, start_date, end_date, source_start_date, source_end_date, units, action, flags)
    VALUES (p_batch, p_org, v_ord * 100 + 1, v_ln, v_ln, p_row->'vals', v_person, v_code,
            v_unit, v_s, v_e, v_s, v_e, 1, 'fill', v_flags);
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


-- ── 3. Authorization used units ──────────────────────────────────────────

-- the units an authorization has used, counted the way the payment file counts them
-- r4: takes the authorization's id, so a HAP month is attributed to exactly one authorization.
--     Callers give a rejected authorization 0 (the trigger reads NEW.status for that).
DROP FUNCTION IF EXISTS public.provly_auth_used_units(uuid, uuid, uuid, date, date);
CREATE OR REPLACE FUNCTION public.provly_auth_used_units(p_org uuid, p_person uuid, p_code_id uuid, p_start date, p_end date, p_auth uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_code  text;
  v_unit  text;
  v_lo    date := coalesce(p_start, '-infinity'::date);
  v_hi    date := coalesce(p_end, 'infinity'::date);
  v_units integer := 0;
BEGIN
  SELECT c.code, c.billing_unit::text INTO v_code, v_unit FROM service_code_definitions c WHERE c.id = p_code_id;
  IF v_code IS NULL OR p_person IS NULL THEN RETURN 0; END IF;

  IF v_code = 'HAP' OR v_unit = 'monthly' THEN
    -- r3: months BILLED — live lines for this code in files marked uploaded. HAP has no notes,
    --     so billing is when a month is used.
    -- r4: a billed month counts toward the authorization covering the line's FIRST AUTHORIZED
    --     DAY (the line keeps UPI's start date, which can fall before the authorization); when
    --     several cover that day, the later-starting one takes it (then the later-ending, then id).
    -- r5: that day must also be IN CARE (a placement on file, not after discharge), the same
    --     test e520_fill_line bills on.
    SELECT count(DISTINCT date_trunc('month', f.line_start))::integer INTO v_units
      FROM (
        SELECT l.start_date AS line_start,
               (SELECT min(gs::date)
                  FROM generate_series(l.start_date, l.end_date, interval '1 day') AS gs
                 WHERE EXISTS (SELECT 1 FROM person_placements pl
                                WHERE pl.org_id = p_org AND pl.person_id = p_person
                                  AND pl.start_date <= gs::date AND (pl.end_date IS NULL OR pl.end_date >= gs::date))
                   AND NOT EXISTS (SELECT 1 FROM persons pp
                                    WHERE pp.id = p_person AND pp.discharge_date IS NOT NULL AND pp.discharge_date < gs::date)
                   AND EXISTS (SELECT 1 FROM person_service_authorizations a
                                WHERE a.org_id = p_org AND a.person_id = p_person AND a.service_code_id = p_code_id
                                  AND a.status::text <> 'rejected'
                                  AND (a.start_date IS NULL OR a.start_date <= gs::date)
                                  AND (a.end_date IS NULL OR a.end_date >= gs::date))) AS first_day
          FROM e520_lines l JOIN e520_batches b ON b.id = l.batch_id
         WHERE l.org_id = p_org AND l.person_id = p_person AND l.service_code = v_code
           AND l.action <> 'remove' AND l.released_at IS NULL AND b.status = 'uploaded'
           AND l.start_date <= v_hi AND l.end_date >= v_lo
      ) f
     WHERE f.first_day BETWEEN v_lo AND v_hi
       AND NOT EXISTS (SELECT 1 FROM person_service_authorizations a2
                        WHERE a2.org_id = p_org AND a2.person_id = p_person AND a2.service_code_id = p_code_id
                          AND a2.status::text <> 'rejected' AND a2.id IS DISTINCT FROM p_auth
                          AND (a2.start_date IS NULL OR a2.start_date <= f.first_day)
                          AND (a2.end_date IS NULL OR a2.end_date >= f.first_day)
                          AND (coalesce(a2.start_date, '-infinity'::date) > v_lo
                               OR (coalesce(a2.start_date, '-infinity'::date) = v_lo AND coalesce(a2.end_date, 'infinity'::date) > v_hi)
                               OR (coalesce(a2.start_date, '-infinity'::date) = v_lo AND coalesce(a2.end_date, 'infinity'::date) = v_hi
                                   AND a2.id < p_auth)));
  ELSIF v_code = 'MTP' THEN
    -- one per DSG day with a ride by our staff
    SELECT count(DISTINCT n.service_date)::integer INTO v_units
      FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
     WHERE n.org_id = p_org AND n.person_id = p_person AND c.code = 'DSG'
       AND n.status IN ('approved', 'billed') AND coalesce(n.transport, 'to_and_from') <> 'none'
       AND n.service_date BETWEEN v_lo AND v_hi;
  ELSIF v_unit = 'quarter_hour' THEN
    -- D5: each day's minutes rounded to the nearest quarter hour
    SELECT coalesce(sum(e520_round_q(d.m)), 0)::integer INTO v_units
      FROM (SELECT n.service_date, sum(coalesce(n.duration_minutes, 0)) AS m
              FROM service_notes n
             WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
               AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi
             GROUP BY n.service_date) d;
  ELSIF v_unit = 'hourly' THEN
    SELECT coalesce(sum(round(d.m / 60.0)), 0)::integer INTO v_units
      FROM (SELECT n.service_date, sum(coalesce(n.duration_minutes, 0)) AS m
              FROM service_notes n
             WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
               AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi
             GROUP BY n.service_date) d;
  ELSIF v_unit = 'daily' THEN
    SELECT count(DISTINCT n.service_date)::integer INTO v_units
      FROM service_notes n
     WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
       AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi;
  ELSE
    -- per_session / per_trip: one per approved note
    SELECT count(*)::integer INTO v_units
      FROM service_notes n
     WHERE n.org_id = p_org AND n.person_id = p_person AND n.service_code_id = p_code_id
       AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi;
  END IF;
  RETURN coalesce(v_units, 0);
END;
$$;

-- refresh every authorization a note on this day could count toward (a DSG note also counts toward MTP)
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
                 ELSE public.provly_auth_used_units(a2.org_id, a2.person_id, a2.service_code_id, a2.start_date, a2.end_date, a2.id) END AS u
            FROM person_service_authorizations a2
           WHERE a2.org_id = p_org AND a2.person_id = p_person
             AND (a2.service_code_id = p_code_id OR a2.service_code_id = v_mtp)
             AND (a2.start_date IS NULL OR a2.start_date <= p_day)
             AND (a2.end_date IS NULL OR a2.end_date >= p_day)) x
   WHERE a.id = x.id AND a.used_units IS DISTINCT FROM x.u;
END;
$$;

-- the service_notes trigger (same name as before): every insert, update and delete, whoever does it
CREATE OR REPLACE FUNCTION public.update_authorization_units()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM public.provly_recompute_auth_units(OLD.org_id, OLD.person_id, OLD.service_code_id, OLD.service_date);
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM public.provly_recompute_auth_units(NEW.org_id, NEW.person_id, NEW.service_code_id, NEW.service_date);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS service_note_auth_update ON public.service_notes;
CREATE TRIGGER service_note_auth_update
  AFTER INSERT OR UPDATE OR DELETE ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.update_authorization_units();

-- an authorization's own dates, client or code change → recount it
CREATE OR REPLACE FUNCTION public.trg_psa_used_units()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- r4: a rejected authorization uses nothing (read from NEW: in a BEFORE trigger the table still holds the old row)
  NEW.used_units := CASE WHEN NEW.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(NEW.org_id, NEW.person_id, NEW.service_code_id, NEW.start_date, NEW.end_date, NEW.id) END;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS psa_used_units ON public.person_service_authorizations;
CREATE TRIGGER psa_used_units
  BEFORE INSERT OR UPDATE OF person_id, service_code_id, start_date, end_date, status ON public.person_service_authorizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_psa_used_units();

-- r3: the old in-care month count and its triggers are retired (HAP counts months billed);
-- r5 re-creates the placement / discharge triggers below for the attribution day
DROP TRIGGER IF EXISTS person_placements_hap_units ON public.person_placements;
DROP TRIGGER IF EXISTS persons_hap_units ON public.persons;
DROP FUNCTION IF EXISTS public.trg_hap_units_recompute();

-- recount one client's monthly (HAP) authorizations
CREATE OR REPLACE FUNCTION public.provly_recompute_monthly_auths(p_org uuid, p_person uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE person_service_authorizations a
     SET used_units = x.u
    FROM (SELECT a2.id, CASE WHEN a2.status::text = 'rejected' THEN 0
                 ELSE public.provly_auth_used_units(a2.org_id, a2.person_id, a2.service_code_id, a2.start_date, a2.end_date, a2.id) END AS u
            FROM person_service_authorizations a2 JOIN service_code_definitions c ON c.id = a2.service_code_id
           WHERE a2.org_id = p_org AND a2.person_id = p_person
             AND (c.code = 'HAP' OR c.billing_unit::text = 'monthly')) x
   WHERE a.id = x.id AND a.used_units IS DISTINCT FROM x.u;
END;
$$;

-- a file marked uploaded, or a line released → recount the HAP authorizations it touches
CREATE OR REPLACE FUNCTION public.trg_e520_hap_units()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r record;
BEGIN
  IF TG_TABLE_NAME = 'e520_batches' THEN
    FOR r IN SELECT DISTINCT l.org_id, l.person_id FROM e520_lines l
              WHERE l.batch_id = NEW.id AND l.service_code = 'HAP' AND l.person_id IS NOT NULL LOOP
      PERFORM public.provly_recompute_monthly_auths(r.org_id, r.person_id);
    END LOOP;
  ELSIF NEW.service_code = 'HAP' AND NEW.person_id IS NOT NULL THEN
    PERFORM public.provly_recompute_monthly_auths(NEW.org_id, NEW.person_id);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS e520_batches_hap_units ON public.e520_batches;
CREATE TRIGGER e520_batches_hap_units
  AFTER UPDATE OF status ON public.e520_batches
  FOR EACH ROW WHEN (NEW.status = 'uploaded' AND OLD.status IS DISTINCT FROM 'uploaded')
  EXECUTE FUNCTION public.trg_e520_hap_units();
DROP TRIGGER IF EXISTS e520_lines_hap_units ON public.e520_lines;
CREATE TRIGGER e520_lines_hap_units
  AFTER UPDATE OF released_at ON public.e520_lines
  FOR EACH ROW WHEN (NEW.released_at IS NOT NULL AND OLD.released_at IS NULL)
  EXECUTE FUNCTION public.trg_e520_hap_units();

-- r4: an authorization is added, changed or removed → recount that client's HAP months
--     (which authorization a month counts toward can move). A used_units-only update doesn't fire it.
CREATE OR REPLACE FUNCTION public.trg_psa_monthly_recount()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM public.provly_recompute_monthly_auths(OLD.org_id, OLD.person_id);
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM public.provly_recompute_monthly_auths(NEW.org_id, NEW.person_id);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS psa_monthly_recount ON public.person_service_authorizations;
CREATE TRIGGER psa_monthly_recount
  AFTER INSERT OR DELETE OR UPDATE OF person_id, service_code_id, start_date, end_date, status
  ON public.person_service_authorizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_psa_monthly_recount();

-- r5: a placement or a discharge date changes → recount HAP months (the attribution day is a
--     day in care). A placement moved to another client recounts both clients.
CREATE OR REPLACE FUNCTION public.trg_hap_care_recount()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_TABLE_NAME = 'persons' THEN
    PERFORM public.provly_recompute_monthly_auths(NEW.org_id, NEW.id);
    RETURN NULL;
  END IF;
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM public.provly_recompute_monthly_auths(OLD.org_id, OLD.person_id);
  END IF;
  IF TG_OP = 'INSERT'
     OR (TG_OP = 'UPDATE' AND (NEW.person_id IS DISTINCT FROM OLD.person_id OR NEW.org_id IS DISTINCT FROM OLD.org_id)) THEN
    PERFORM public.provly_recompute_monthly_auths(NEW.org_id, NEW.person_id);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS person_placements_hap_units ON public.person_placements;
CREATE TRIGGER person_placements_hap_units
  AFTER INSERT OR DELETE OR UPDATE ON public.person_placements
  FOR EACH ROW EXECUTE FUNCTION public.trg_hap_care_recount();
DROP TRIGGER IF EXISTS persons_hap_units ON public.persons;
CREATE TRIGGER persons_hap_units
  AFTER UPDATE OF discharge_date ON public.persons
  FOR EACH ROW EXECUTE FUNCTION public.trg_hap_care_recount();

-- r3: HAP and MTP aren't documented by their own service notes
CREATE OR REPLACE FUNCTION public.trg_service_notes_code_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_code text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;                 -- service role / SQL editor
  SELECT code INTO v_code FROM service_code_definitions WHERE id = NEW.service_code_id;
  IF v_code = 'HAP' THEN
    RAISE EXCEPTION 'HAP is documented by the client''s placement, not a service note';
  END IF;
  IF v_code = 'MTP' THEN
    RAISE EXCEPTION 'MTP is recorded on the DSG note (Transported), not as its own note';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS service_notes_code_guard ON public.service_notes;
CREATE TRIGGER service_notes_code_guard
  BEFORE INSERT OR UPDATE OF service_code_id ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_code_guard();

-- recount every authorization once, now
UPDATE public.person_service_authorizations a
   SET used_units = CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id) END
 WHERE a.used_units IS DISTINCT FROM CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id) END;

REVOKE ALL ON FUNCTION public.provly_auth_used_units(uuid, uuid, uuid, date, date, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provly_recompute_auth_units(uuid, uuid, uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_authorization_units() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_psa_used_units() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provly_recompute_monthly_auths(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_e520_hap_units() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_service_notes_code_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_psa_monthly_recount() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_hap_care_recount() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_fill_line(uuid, uuid, jsonb, integer) FROM PUBLIC, anon, authenticated;

-- ── 4. Self-test: the full e520 suite (T1–T16) plus HAP and used units (T17–T21), on a synthetic month (January 2001, an inactive test client) run
--       end to end, then rolled back. r1: if ANY check fails, or the test can't
--       run, the whole file is rolled back — nothing in it is applied — and the
--       error lists each failing check. Results go to a session temp table.
CREATE TEMP TABLE IF NOT EXISTS v20024a_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20024a_selftest;

-- test-data helper (session-only): inserts a row, filling any other NOT NULL column
-- that has no default with a neutral value, so the test never depends on the schema's
-- optional-vs-required choices (r1: persons.date_of_birth, note times)
CREATE OR REPLACE FUNCTION pg_temp.e520_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('e520 self-test') || '::' || c.typ END;
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
  v_sln    uuid;
  v_hhs    uuid;
  v_dsg    uuid;
  v_slh    uuid;
  v_rps    uuid;
  v_person uuid;
  v_batch  uuid;
  v_batch2 uuid;
  v_batch3 uuid;
  v_hdr    text := 'line_number,provider_approver_email,consumer_name,consumer_pid,service_code,rate,unit_type,service_start_date,service_end_date,units,remaining_units,sce,monthly_max_units';
  v_l1     text := '1,selftest@example.com,Selftest E520,099999999,SLN,8.27,Q,01/01/2001,01/31/2001,0,520,Test Coordinator,100';
  v_l2     text := '2,selftest@example.com,Selftest E520,099999999,HHS,230.85,D,01/01/2001,01/31/2001,0,365,Test Coordinator,31';
  v_l3     text := '3,selftest@example.com,Selftest E520,099999999,DSI,88.42,D,01/01/2001,01/31/2001,0,244,Test Coordinator,22';
  v_l4     text := '4,selftest@example.com,Selftest E520,099999999,DSG,127,D,01/01/2001,01/31/2001,0,244,Test Coordinator,22';
  v_l5     text := '5,selftest@example.com,Selftest E520,099999999,MTP,20.8,D,01/01/2001,01/31/2001,0,244,Test Coordinator,22';
  v_l6     text := '6,selftest@example.com,Selftest E520,099999999,SLH,9.31,Q,01/01/2001,01/15/2001,0,100,Test Coordinator,3';
  v_l7     text := '7,selftest@example.com,Selftest E520,099999999,SLH,9.31,Q,01/16/2001,01/31/2001,0,100,Test Coordinator,3';
  v_l8     text := '8,selftest@example.com,Selftest E520,099999999,HAP,567,M,01/01/2001,01/31/2001,0,7,Test Coordinator,1';
  v_l9     text := '9,selftest@example.com,Selftest E520,099999999,HAP,567,M,01/01/2001,01/31/2001,0,7,Test Coordinator,1';
  v_l10    text := '10,selftest@example.com,Selftest E520,099999999,HAP,567,M,12/01/2000,12/31/2000,0,7,Test Coordinator,1';
  v_site   uuid;
  v_sln_a  uuid;
  v_auth_a uuid;
  v_auth_b uuid;
  v_auth_c uuid;
  v_auth_hap uuid;
  v_pba    uuid;
  v_hap_draft integer;
  v_auth_hap2 uuid;
  v_hap_fmt text := 'Jan 1-14: %s, Jan 15-31: %s';
  v_l11    text := '11,selftest@example.com,Selftest E520,099999999,PBA,10.00,Q,01/01/2001,01/31/2001,0,100,Test Coordinator,100';
  v_csv    text;
  v_expect text;
  v_txt    text;
  v_msg    text;
  v_n      integer;
  v_n2     integer;
  v_billed uuid;
  v_extra  uuid;
  v_sln_line uuid;
  v_mtp_line uuid;
  v_ok     boolean;
  v_step   text := 'setup';
BEGIN
  -- r2: start from a valid "nobody signed in" state. The SQL editor can hold the
  -- claims setting as an empty string, which the login helpers can't read as JSON.
  PERFORM set_config('request.jwt.claims', '{}', true);
  -- an organization with staff and a residence site (HAP needs a placement)
  SELECT pl.org_id, pl.site_id INTO v_org, v_site FROM person_placements pl
   WHERE EXISTS (SELECT 1 FROM staff s WHERE s.org_id = pl.org_id) ORDER BY pl.id LIMIT 1;
  SELECT s.id INTO v_staff FROM staff s WHERE s.org_id = v_org ORDER BY s.id LIMIT 1;
  SELECT id INTO v_sln FROM service_code_definitions WHERE code = 'SLN' LIMIT 1;
  SELECT id INTO v_hhs FROM service_code_definitions WHERE code = 'HHS' LIMIT 1;
  SELECT id INTO v_dsg FROM service_code_definitions WHERE code = 'DSG' LIMIT 1;
  SELECT id INTO v_slh FROM service_code_definitions WHERE code = 'SLH' LIMIT 1;
  SELECT id INTO v_rps FROM service_code_definitions WHERE code = 'RPS' LIMIT 1;
  SELECT id INTO v_pba FROM service_code_definitions WHERE code = 'PBA' LIMIT 1;
  -- r3: the two SLH lines are listed out of date order (the 16th–31st line first)
  v_csv := chr(65279) || v_hdr || E'\r\n' || v_l1 || E'\r\n' || v_l2 || E'\r\n' || v_l3 || E'\r\n' || v_l4
           || E'\r\n' || v_l5 || E'\r\n' || v_l7 || E'\r\n' || v_l6
           || E'\r\n' || v_l8 || E'\r\n' || v_l9 || E'\r\n' || v_l10 || E'\r\n' || v_l11;

  BEGIN
    -- ── the synthetic month ──
    v_step := 'creating the test client';
    v_person := pg_temp.e520_test_insert('persons', jsonb_build_object(
      'org_id', v_org, 'first_name', 'E520', 'last_name', 'Selftest', 'identification_number', '099999999', 'is_active', false,
      'discharge_date', '2001-01-20'));
    -- in care (placement) from Jan 1; discharged Jan 20 → a partial HAP month
    PERFORM pg_temp.e520_test_insert('person_placements', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'site_id', v_site, 'start_date', '2001-01-01'));

    v_step := 'creating SLN notes, EVV visits and authorizations';
    -- SLN: two 20-minute notes on the 4th (EVV 35 min → the lesser count), one 127-minute note on the 5th (in an authorization gap)
    v_sln_a := pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_sln, 'service_date', '2001-01-04', 'start_time', '09:00', 'end_time', '09:20', 'duration_minutes', 20,
      'billable_units', 1, 'summary_note', 'e520 self-test', 'status', 'approved'));
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_sln, 'service_date', '2001-01-04', 'start_time', '10:00', 'end_time', '10:20', 'duration_minutes', 20,
      'billable_units', 1, 'summary_note', 'e520 self-test', 'status', 'approved'));
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_sln, 'service_date', '2001-01-05', 'start_time', '09:00', 'end_time', '11:07', 'duration_minutes', 127,
      'billable_units', 8, 'summary_note', 'e520 self-test', 'status', 'approved'));
    PERFORM pg_temp.e520_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_staff, 'person_id', v_person,
      'service_code_id', v_sln,
      'clock_in_at', (TIMESTAMP '2001-01-04 09:00' AT TIME ZONE 'America/Denver'),
      'clock_out_at', (TIMESTAMP '2001-01-04 09:35' AT TIME ZONE 'America/Denver')));
    PERFORM pg_temp.e520_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_staff, 'person_id', v_person,
      'service_code_id', v_sln,
      'clock_in_at', (TIMESTAMP '2001-01-05 09:00' AT TIME ZONE 'America/Denver'),
      'clock_out_at', (TIMESTAMP '2001-01-05 10:50' AT TIME ZONE 'America/Denver')));
    -- SLN authorizations with a gap on the 5th
    v_auth_a := pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_sln, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-01-04', 'rate_per_unit', 8.27, 'status', 'approved'));
    v_auth_b := pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_sln, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-06', 'end_date', '2001-01-31', 'rate_per_unit', 8.27, 'status', 'approved'));
    -- v20.0.24a: a REJECTED authorization on the 5th must not close the gap
    v_auth_c := pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_sln, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-05', 'end_date', '2001-01-05', 'rate_per_unit', 8.27, 'status', 'rejected'));

    v_step := 'creating HHS notes';
    -- HHS: daily notes on the 1st–3rd and the 12th
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_hhs, 'service_date', d::date, 'start_time', '08:00', 'end_time', '16:00', 'duration_minutes', 480,
      'billable_units', 1, 'summary_note', 'e520 self-test', 'status', 'approved'))
      FROM unnest(ARRAY[DATE '2001-01-01', DATE '2001-01-02', DATE '2001-01-03', DATE '2001-01-12']) AS d;

    v_step := 'creating the DSG note';
    -- DSG on the 15th (transport preset to_and_from by the database) → one DSG day and one MTP day
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_dsg, 'service_date', '2001-01-15', 'start_time', '09:00', 'end_time', '15:00', 'duration_minutes', 360,
      'billable_units', 1, 'summary_note', 'e520 self-test', 'status', 'approved'));

    v_step := 'creating SLH notes and EVV visits';
    -- SLH: 30 minutes on the 7th and the 20th, each with a 30-minute EVV visit; the two UPI lines share a monthly max of 3
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_slh, 'service_date', d::date, 'start_time', '13:00', 'end_time', '13:30', 'duration_minutes', 30,
      'billable_units', 2, 'summary_note', 'e520 self-test', 'status', 'approved'))
      FROM unnest(ARRAY[DATE '2001-01-07', DATE '2001-01-20']) AS d;
    PERFORM pg_temp.e520_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_staff, 'person_id', v_person,
      'service_code_id', v_slh,
      'clock_in_at', ((d::date + TIME '13:00') AT TIME ZONE 'America/Denver'),
      'clock_out_at', ((d::date + TIME '13:30') AT TIME ZONE 'America/Denver')))
      FROM unnest(ARRAY[DATE '2001-01-07', DATE '2001-01-20']) AS d;

    v_step := 'creating the RPS note';
    -- RPS: a documented service with no UPI line
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_rps, 'service_date', '2001-01-08', 'start_time', '09:00', 'end_time', '10:00', 'duration_minutes', 60,
      'billable_units', 4, 'summary_note', 'e520 self-test', 'status', 'approved'));

    v_step := 'recording the absence';
    -- r3: PBA with a documented hour but only a REJECTED authorization → nothing is covered
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_pba, 'service_date', '2001-01-08', 'start_time', '13:00', 'end_time', '14:00', 'duration_minutes', 60,
      'billable_units', 4, 'summary_note', 'e520 self-test', 'status', 'approved'));
    PERFORM pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_pba, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-01-31', 'rate_per_unit', 10, 'status', 'rejected'));
    -- r3: a HAP authorization for January (its used units = months billed)
    v_auth_hap := pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', (SELECT id FROM service_code_definitions WHERE code = 'HAP'), 'authorized_units', 12, 'used_units', 0,
      'start_date', '2001-01-15', 'end_date', '2001-01-31', 'rate_per_unit', 567, 'status', 'approved'));

    -- a hospital day on the 10th
    INSERT INTO person_absences (org_id, person_id, start_date, end_date, reason)
    VALUES (v_org, v_person, DATE '2001-01-10', DATE '2001-01-10', 'hospital');

    -- ── T1–T8: the first build ──
    v_step := 'T1-T8 first build';
    v_batch := public.e520_build('selftest.csv', v_csv, v_org);

    SELECT string_agg(line_number || ':' || to_char(start_date, 'MM/DD') || '-' || to_char(end_date, 'MM/DD') || '=' || units, ', ' ORDER BY ord)
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch AND service_code = 'SLN' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'T1 SLN: day total rounded, EVV lesser, authorization gap (a rejected one doesn''t close it) and absence break the span', v_txt, '1:01/01-01/04=2'));

    SELECT (flags @> '[{"kind":"evv_gap"}]'::jsonb)::text || ',' || (flags @> '[{"kind":"outside_coverage"}]'::jsonb)::text
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch AND service_code = 'SLN' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'T2 SLN flags: EVV gap, day outside the authorization', v_txt, 'true,true'));

    SELECT string_agg(line_number || ':' || to_char(start_date, 'MM/DD') || '-' || to_char(end_date, 'MM/DD') || '=' || units, ', ' ORDER BY ord)
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch AND service_code = 'HHS' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'T3 HHS: split around the absence, new part numbered after the file''s highest', v_txt, '2:01/01-01/09=3, 12:01/11-01/31=1'));

    SELECT action || ': ' || coalesce(remove_reason, '') INTO v_txt
      FROM e520_lines WHERE batch_id = v_batch AND service_code = 'DSI';
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'T4 DSI: no documentation, removed', v_txt, 'remove: No approved documentation for these dates'));

    v_expect := chr(65279) || v_hdr
      || E'\r\n' || '1,selftest@example.com,Selftest E520,099999999,SLN,8.27,Q,01/01/2001,01/04/2001,2,520,Test Coordinator,100'
      || E'\r\n' || '2,selftest@example.com,Selftest E520,099999999,HHS,230.85,D,01/01/2001,01/09/2001,3,365,Test Coordinator,31'
      || E'\r\n' || '12,selftest@example.com,Selftest E520,099999999,HHS,230.85,D,01/11/2001,01/31/2001,1,365,Test Coordinator,31'
      || E'\r\n' || '4,selftest@example.com,Selftest E520,099999999,DSG,127,D,01/11/2001,01/31/2001,1,244,Test Coordinator,22'
      || E'\r\n' || '5,selftest@example.com,Selftest E520,099999999,MTP,20.8,D,01/11/2001,01/31/2001,1,244,Test Coordinator,22'
      || E'\r\n' || '7,selftest@example.com,Selftest E520,099999999,SLH,9.31,Q,01/16/2001,01/31/2001,1,100,Test Coordinator,3'
      || E'\r\n' || '6,selftest@example.com,Selftest E520,099999999,SLH,9.31,Q,01/01/2001,01/09/2001,2,100,Test Coordinator,3'
      || E'\r\n' || '8,selftest@example.com,Selftest E520,099999999,HAP,567,M,01/01/2001,01/31/2001,1,7,Test Coordinator,1';
    SELECT (export_csv = v_expect)::text INTO v_txt FROM e520_batches WHERE id = v_batch;
    v_res := v_res || jsonb_build_array(jsonb_build_array(5, 'T5 export byte for byte: BOM, CRLF, UPI values verbatim, only units / dates / new numbers changed', v_txt, 'true'));

    SELECT count(*) || ' notes, SLN units ' || coalesce(sum(x.units) FILTER (WHERE x.service_code = 'SLN'), 0)
      INTO v_txt
      FROM e520_line_notes x JOIN e520_lines l ON l.id = x.line_id WHERE l.batch_id = v_batch;
    v_res := v_res || jsonb_build_array(jsonb_build_array(6, 'T6 reservations: every note behind a unit (the DSG note twice: DSG and MTP)', v_txt, '10 notes, SLN units 2'));

    SELECT (unmatched @> '[{"code":"RPS","notes":1}]'::jsonb)::text INTO v_txt FROM e520_batches WHERE id = v_batch;
    v_res := v_res || jsonb_build_array(jsonb_build_array(7, 'T7 delivered but not in the budget (RPS note, no RPS line)', v_txt, 'true'));

    SELECT string_agg(line_number || ':' || to_char(start_date, 'MM/DD') || '-' || to_char(end_date, 'MM/DD') || '=' || units, ', ' ORDER BY ord)
           || '; capped ' || bool_or(flags @> '[{"kind":"capped"}]'::jsonb)::text
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch AND service_code = 'SLH' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(8, 'T8 one monthly max shared by two SLH lines listed out of date order: the earliest days get it', v_txt, '7:01/16-01/31=1, 6:01/01-01/09=2; capped true'));

    SELECT used_units INTO v_hap_draft FROM person_service_authorizations WHERE id = v_auth_hap;

    -- ── T9: a rebuild replaces the draft ──
    v_step := 'T9 rebuild';
    v_batch2 := public.e520_build('selftest.csv', v_csv, v_org);
    SELECT count(*) || ' batch, seq ' || max(seq) || CASE WHEN v_batch2 <> v_batch THEN ', new id' ELSE ', SAME id' END
      INTO v_txt FROM e520_batches WHERE org_id = v_org AND service_month = DATE '2001-01-01';
    v_res := v_res || jsonb_build_array(jsonb_build_array(9, 'T9 rebuild replaces the month''s draft', v_txt, '1 batch, seq 1, new id'));

    v_step := 'T10 mark uploaded';
    -- ── T10: mark uploaded — the wrong file refused, the right one bills the notes ──
    v_msg := NULL;
    BEGIN
      PERFORM public.e520_mark_uploaded(v_batch2, 'not-the-file', NULL);
    EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
    END;
    SELECT export_sha256 INTO v_txt FROM e520_batches WHERE id = v_batch2;
    v_n := public.e520_mark_uploaded(v_batch2, v_txt, 12345);
    SELECT CASE WHEN v_msg LIKE 'This isn''t the file Provly built%' THEN 'wrong file refused' ELSE 'WRONG FILE: ' || coalesce(v_msg, 'accepted') END
           || '; ' || v_n || ' billed; ' || status INTO v_txt FROM e520_batches WHERE id = v_batch2;
    v_res := v_res || jsonb_build_array(jsonb_build_array(10, 'T10 mark uploaded (D8)', v_txt, 'wrong file refused; 9 billed; uploaded'));

    SELECT x.note_id INTO v_billed
      FROM e520_line_notes x JOIN e520_lines l ON l.id = x.line_id
     WHERE l.batch_id = v_batch2 AND x.service_code = 'HHS' LIMIT 1;
    v_extra := pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
      'service_code_id', v_hhs, 'service_date', '2001-01-20', 'start_time', '08:00', 'end_time', '16:00', 'duration_minutes', 480,
      'billable_units', 1, 'summary_note', 'e520 self-test', 'status', 'approved'));

    -- ── T11: a signed-in user can't reopen a billed note ──
    v_step := 'T11 billed lock';
    v_msg := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      BEGIN
        UPDATE service_notes SET status = 'submitted' WHERE id = v_billed;
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      RAISE EXCEPTION 'v20024a_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024a_rollback' THEN RAISE; END IF;
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(11, 'T11 billed note: no Reopen', coalesce('refused: ' || v_msg, 'NOT REFUSED'),
                       'refused: This service note is billed and locked. It returns to approved only when its payment line is released.'));

    -- ── T12: approved → billed only through Mark uploaded ──
    v_step := 'T12 approved to billed';
    v_msg := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      BEGIN
        UPDATE service_notes SET status = 'billed' WHERE id = v_extra;
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      RAISE EXCEPTION 'v20024a_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024a_rollback' THEN RAISE; END IF;
    END;
    v_ok := false;
    BEGIN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      PERFORM set_config('provly.e520_transition', 'upload', true);
      UPDATE service_notes SET status = 'billed' WHERE id = v_extra;
      v_ok := true;
      RAISE EXCEPTION 'v20024a_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024a_rollback' THEN RAISE; END IF;
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(12, 'T12 approved → billed: refused directly, allowed inside Mark uploaded',
                       coalesce('refused: ' || v_msg, 'NOT REFUSED') || CASE WHEN v_ok THEN ' / allowed' ELSE ' / NOT ALLOWED' END,
                       'refused: A note becomes billed only when its payment file is marked uploaded / allowed'));

    v_step := 'T13 release';
    -- ── T13: release — a live status refused; SLN notes return; the MTP release keeps the DSG note billed ──
    SELECT id INTO v_sln_line FROM e520_lines WHERE batch_id = v_batch2 AND service_code = 'SLN' AND action <> 'remove';
    SELECT id INTO v_mtp_line FROM e520_lines WHERE batch_id = v_batch2 AND service_code = 'MTP' AND action <> 'remove';
    v_msg := NULL;
    BEGIN
      PERFORM public.e520_release_line(v_sln_line, 'Paid by CAPS', 'self-test');
    EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
    END;
    v_n  := public.e520_release_line(v_sln_line, 'Denied by SC', 'self-test');
    v_n2 := public.e520_release_line(v_mtp_line, 'Denied by SC', 'self-test');
    v_res := v_res || jsonb_build_array(jsonb_build_array(13, 'T13 release: Paid by CAPS refused; SLN notes return; MTP release leaves the DSG note billed',
                       CASE WHEN v_msg LIKE 'Only a line UPI has closed%' THEN 'live status refused' ELSE 'LIVE STATUS: ' || coalesce(v_msg, 'accepted') END
                       || '; SLN ' || v_n || ' returned; MTP ' || v_n2 || ' returned',
                       'live status refused; SLN 2 returned; MTP 0 returned'));

    -- ── T14: a supplemental claims only what no live line holds ──
    v_step := 'T14 supplemental';
    v_batch3 := public.e520_build('selftest-2.csv', v_csv, v_org);
    SELECT 'seq ' || b.seq || '; ' || string_agg(l.service_code || ' ' || l.line_number || ':' || to_char(l.start_date, 'MM/DD') || '-' || to_char(l.end_date, 'MM/DD') || '=' || l.units, ', ' ORDER BY l.ord)
      INTO v_txt
      FROM e520_batches b JOIN e520_lines l ON l.batch_id = b.id
     WHERE b.id = v_batch3 AND l.action <> 'remove' GROUP BY b.seq;
    v_res := v_res || jsonb_build_array(jsonb_build_array(14, 'T14 supplemental: SLN reclaimed, billed days skipped, new HHS day billed, MTP reclaimed from the billed DSG note', v_txt,
                       'seq 2; SLN 1:01/01-01/04=2, HHS 2:01/11-01/31=1, MTP 5:01/11-01/31=1'));

    -- ── T15: the D3 guards and the tier gate ──
    v_step := 'T15 guards';
    v_msg := NULL;
    BEGIN
      PERFORM public.e520_build('bad.csv', v_hdr || E'\r\n' || replace(v_l1, '099999999', '99999999'), v_org);
    EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
    END;
    v_txt := CASE WHEN v_msg LIKE 'Row 1: the PID is not 9 digits%' THEN 'PID refused' ELSE 'PID: ' || coalesce(v_msg, 'accepted') END;
    v_msg := NULL;
    BEGIN
      PERFORM public.e520_build('bad.csv', v_hdr || E'\r\n' || replace(v_l1, 'Selftest E520', '"Selftest, E520"'), v_org);
    EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
    END;
    v_txt := v_txt || '; ' || CASE WHEN v_msg LIKE 'The file has quoted fields%' THEN 'quotes refused' ELSE 'QUOTES: ' || coalesce(v_msg, 'accepted') END;
    v_msg := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      BEGIN
        PERFORM public.e520_build('x.csv', v_csv, NULL);
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      RAISE EXCEPTION 'v20024a_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024a_rollback' THEN RAISE; END IF;
    END;
    v_txt := v_txt || '; ' || CASE WHEN v_msg LIKE 'Only an owner, admin or compliance director%' THEN 'non-manage refused' ELSE 'GATE: ' || coalesce(v_msg, 'accepted') END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(15, 'T15 guards: PID without its zero, quoted fields, a non-manage caller', v_txt,
                       'PID refused; quotes refused; non-manage refused'));

    v_res := v_res || jsonb_build_array(jsonb_build_array(16, 'T16 rounding spot checks (127, 40, 7, 8 minutes)',
                       public.e520_round_q(127) || ',' || public.e520_round_q(40) || ',' || public.e520_round_q(7) || ',' || public.e520_round_q(8),
                       '8,3,0,1'));

    -- ── v20.0.24a: HAP and authorization used units ──
    -- r1: read the HAP lines from v_batch2 (T9's rebuild deleted the first draft, v_batch)
    v_step := 'T17-T19 HAP';
    SELECT string_agg(line_number || ':' || to_char(start_date, 'MM/DD') || '-' || to_char(end_date, 'MM/DD') || '=' || units, ', ' ORDER BY ord)
           || '; partial ' || bool_or(flags @> '[{"kind":"partial_month"}]'::jsonb)::text
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch2 AND service_code = 'HAP' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(17, 'T17 HAP: one unit, the absence doesn''t split or reduce it, a mid-month discharge is flagged', v_txt, '8:01/01-01/31=1; partial true'));
    SELECT action || ': ' || coalesce(remove_reason, '') INTO v_txt FROM e520_lines WHERE batch_id = v_batch2 AND service_code = 'HAP' AND line_number = 9;
    v_res := v_res || jsonb_build_array(jsonb_build_array(18, 'T18 HAP: a second line for the same month', v_txt, 'remove: HAP is already billed for this month'));
    SELECT action || ': ' || coalesce(remove_reason, '') INTO v_txt FROM e520_lines WHERE batch_id = v_batch2 AND service_code = 'HAP' AND line_number = 10;
    v_res := v_res || jsonb_build_array(jsonb_build_array(19, 'T19 HAP: a month before the placement', v_txt, 'remove: Not in care on any of these dates (no placement, or after discharge)'));

    v_step := 'T20 authorization used units';
    SELECT format('A %s, B %s, C %s', (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_a),
                  (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_b),
                  (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_c)) INTO v_txt;
    UPDATE service_notes SET status = 'submitted' WHERE id = v_sln_a;           -- a Reopen takes its minutes back out
    v_txt := v_txt || format('; after reopen A %s', (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_a));
    v_res := v_res || jsonb_build_array(jsonb_build_array(20, 'T20 used units: nearest quarter hour per day, matched by client + code + date, a rejected one uses 0, recomputed on Reopen', v_txt,
                       'A 3, B 0, C 0; after reopen A 1'));

    v_step := 'T21 HAP code';
    SELECT code || ' ' || billing_unit::text INTO v_txt FROM service_code_definitions WHERE code = 'HAP';
    v_res := v_res || jsonb_build_array(jsonb_build_array(21, 'T21 HAP is in the code table as a monthly code', v_txt, 'HAP monthly'));

    v_step := 'T22-T24';
    SELECT action || ': ' || coalesce(remove_reason, '') INTO v_txt
      FROM e520_lines WHERE batch_id = v_batch2 AND service_code = 'PBA';
    v_res := v_res || jsonb_build_array(jsonb_build_array(22, 'T22 an authorization that is only rejected covers nothing', v_txt,
                       'remove: No day on this line falls inside a placement or authorization'));

    SELECT format('draft %s, uploaded %s', v_hap_draft, (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_hap)) INTO v_txt;
    v_res := v_res || jsonb_build_array(jsonb_build_array(23, 'T23 HAP used units = months billed, counted for an authorization starting after the line (Jan 15 vs Jan 1)', v_txt,
                       'draft 0, uploaded 1'));

    v_txt := '';
    BEGIN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      v_msg := NULL;
      BEGIN
        PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
          'service_code_id', (SELECT id FROM service_code_definitions WHERE code = 'HAP'), 'service_date', '2001-01-09',
          'start_time', '09:00', 'end_time', '10:00', 'duration_minutes', 60, 'billable_units', 1, 'summary_note', 'e520 self-test', 'status', 'draft'));
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      v_txt := CASE WHEN v_msg LIKE 'HAP is documented by the client''s placement%' THEN 'HAP refused' ELSE 'HAP: ' || coalesce(v_msg, 'accepted') END;
      v_msg := NULL;
      BEGIN
        PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
          'service_code_id', (SELECT id FROM service_code_definitions WHERE code = 'MTP'), 'service_date', '2001-01-09',
          'start_time', '09:00', 'end_time', '10:00', 'duration_minutes', 60, 'billable_units', 1, 'summary_note', 'e520 self-test', 'status', 'draft'));
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      v_txt := v_txt || '; ' || CASE WHEN v_msg LIKE 'MTP is recorded on the DSG note%' THEN 'MTP refused' ELSE 'MTP: ' || coalesce(v_msg, 'accepted') END;
      RAISE EXCEPTION 'v20024a_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024a_rollback' THEN RAISE; END IF;
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(24, 'T24 no HAP or MTP service notes from a signed-in user', v_txt, 'HAP refused; MTP refused'));

    -- T25: a second HAP authorization for Jan 1–14 is added → the month moves to it (its first
    --      authorized day is now Jan 1), counted once, and the Jan 15 one is recounted to 0
    v_step := 'T25 HAP month attribution';
    v_auth_hap2 := pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', (SELECT id FROM service_code_definitions WHERE code = 'HAP'), 'authorized_units', 12, 'used_units', 0,
      'start_date', '2001-01-01', 'end_date', '2001-01-14', 'rate_per_unit', 567, 'status', 'approved'));
    SELECT format('Jan 1-14: %s, Jan 15-31: %s',
                  (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_hap2),
                  (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_hap)) INTO v_txt;
    v_res := v_res || jsonb_build_array(jsonb_build_array(25, 'T25 two HAP authorizations meet mid-month: the month counts once, and adding one recounts the other', v_txt,
                       'Jan 1-14: 1, Jan 15-31: 0'));

    -- T26: care now begins Jan 15 (placement moved) → the Jan 1–14 authorization never covered a
    --      day in care, so the month moves to the Jan 15 one — recounted by the placement trigger
    v_step := 'T26 HAP attribution follows care';
    UPDATE person_placements SET start_date = DATE '2001-01-15' WHERE person_id = v_person;
    SELECT format(v_hap_fmt, (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_hap2),
                  (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_hap)) INTO v_txt;
    v_res := v_res || jsonb_build_array(jsonb_build_array(26, 'T26 care begins Jan 15: the month counts toward the authorization covering a day in care', v_txt,
                       'Jan 1-14: 0, Jan 15-31: 1'));

    -- T27: the discharge date moves before care begins → no day in care → neither authorization
    v_step := 'T27 HAP attribution follows discharge';
    UPDATE persons SET discharge_date = DATE '2001-01-14' WHERE id = v_person;
    SELECT format(v_hap_fmt, (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_hap2),
                  (SELECT used_units FROM person_service_authorizations WHERE id = v_auth_hap)) INTO v_txt;
    v_res := v_res || jsonb_build_array(jsonb_build_array(27, 'T27 a discharge date change recounts: no day in care, no authorization uses the month', v_txt,
                       'Jan 1-14: 0, Jan 15-31: 0'));

    RAISE EXCEPTION 'v20024a_rollback';                          -- undo the whole synthetic month
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20024a_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;

  -- r1: a failing or unfinished self-test rolls the whole file back
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail
    FROM jsonb_array_elements(v_res) AS e
   WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 27 THEN
    RAISE EXCEPTION 'v20.0.24a self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 27 checks ran', jsonb_array_length(v_res)));
  END IF;

  INSERT INTO v20024a_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.e520_test_insert(text, jsonb);

COMMIT;


-- ── 5. Verification — paste this table into chat before the PR merges ────
SELECT * FROM (
  SELECT 1 AS n, 'HAP in the code table' AS check_item,
    (SELECT code || ' ' || billing_unit::text || ' evv=' || evv_required::text FROM public.service_code_definitions WHERE code = 'HAP') AS value,
    'HAP monthly evv=false' AS want
  UNION ALL
  SELECT 2, 'used-units trigger fires on insert, update and delete',
    (SELECT (pg_get_triggerdef(t.oid) LIKE '%INSERT%' AND pg_get_triggerdef(t.oid) LIKE '%UPDATE%'
             AND pg_get_triggerdef(t.oid) LIKE '%DELETE%')::text FROM pg_trigger t
      WHERE t.tgrelid = 'public.service_notes'::regclass AND t.tgname = 'service_note_auth_update'),
    'true'
  UNION ALL
  SELECT 3, 'recount triggers (authorization dates, file uploaded, line released, authorization changes, placements, discharge) + HAP / MTP note guard; retired function gone',
    ((SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.person_service_authorizations'::regclass AND tgname = 'psa_used_units')
     + (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.e520_batches'::regclass AND tgname = 'e520_batches_hap_units')
     + (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.e520_lines'::regclass AND tgname = 'e520_lines_hap_units')
     + (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.service_notes'::regclass AND tgname = 'service_notes_code_guard')
     + (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.person_service_authorizations'::regclass AND tgname = 'psa_monthly_recount')
     + (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.person_placements'::regclass AND tgname = 'person_placements_hap_units')
     + (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.persons'::regclass AND tgname = 'persons_hap_units'))::text
    || ' + ' || ((SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'trg_hap_units_recompute'))::text,
    '7 + 0'
  UNION ALL
  SELECT 4, 'authorizations whose used units don''t match the rule',
    (SELECT count(*)::text FROM public.person_service_authorizations a
      WHERE a.used_units IS DISTINCT FROM CASE WHEN a.status::text = 'rejected' THEN 0
                  ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id) END),
    '0'
  UNION ALL
  SELECT 5, 'rejected authorizations never cover a day',
    (SELECT (pg_get_functiondef(p.oid) LIKE '%status::text <> ''rejected''%')::text FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'e520_fill_line'),
    'true'
  UNION ALL
  SELECT 5 + t.n, t.item, t.value, t.want FROM v20024a_selftest t
  UNION ALL
  SELECT 200, 'left behind by the self-test (test client, its batches, its notes)',
    (SELECT (SELECT count(*) FROM public.persons WHERE identification_number = '099999999')
            + (SELECT count(*) FROM public.e520_batches WHERE service_month = DATE '2001-01-01')
            + (SELECT count(*) FROM public.service_notes WHERE summary_note = 'e520 self-test'))::text,
    '0'
) v ORDER BY n;
