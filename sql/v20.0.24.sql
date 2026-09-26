-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.24 — e520 arc, PR 2: the engine (docs/e520-design.md v1.1 §4–§7)
--   Tables     e520_batches · e520_lines · e520_line_notes (read-only to clients:
--              manage tier reads; only the RPCs below write)
--   Engine     e520_build(filename, csv) — parse UPI's CSV (D3 guards), match by
--              PID + code, units per D4 (note + EVV, lesser) / D5 (nearest ¼ hour
--              per day) / D6 (MTP from DSG rides) / D7 (absences split lines),
--              trim to placement / authorization, cap at monthly max / remaining,
--              reserve the notes behind every unit, write UPI's file back
--              byte-for-byte except the fields Provly owns (D2).
--   Lifecycle  e520_mark_uploaded · e520_release_line · e520_delete_draft ·
--              e520_set_upi_record (D8)
--   Lock       billed is locked like approved, with no Reopen; approved → billed
--              only through e520_mark_uploaded, billed → approved only through
--              e520_release_line.
-- r1 (Greptile r1): a note is eligible for a unit if no LIVE line holds it for that
--     code (so a released MTP day can be reclaimed from a DSG note still billed for
--     DSG); placement / authorization coverage is checked day by day (gaps are
--     breaks, never billed); monthly max and remaining units are shared by every
--     line for the same client, code and month; the self-test builds its test data
--     against the real schema and now ROLLS THE WHOLE FILE BACK if any check fails.
-- r2: the SQL editor can leave request.jwt.claims as an empty string, which is
--     not valid JSON; the self-test now starts from '{}' ("nobody signed in"), and
--     an early stop names the step it stopped at.
-- r3: lines are filled in order of their start dates (then file order), so a shared
--     monthly cap always goes to the earliest documented days, whatever order UPI
--     lists the lines in. The export keeps the file's order.
-- Run on production in the Supabase SQL editor. Idempotent. Nothing calls the
-- engine until PR 3 (v20.0.25) ships the page. The last statement is the
-- verification table, including a synthetic end-to-end self-test (January 2001,
-- inactive test client) that is rolled back and leaves nothing behind.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Tables ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.e520_batches (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  service_month      date NOT NULL CHECK (service_month = date_trunc('month', service_month)::date),
  seq                integer NOT NULL CHECK (seq >= 1),              -- 1 = main file, 2+ = supplementals
  status             text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'uploaded')),
  source_filename    text,
  source_csv         text NOT NULL,                                  -- the file exactly as received
  source_sha256      text NOT NULL,
  header             text NOT NULL,                                  -- UPI's header line, verbatim
  approver_email     text,
  export_filename    text,
  export_csv         text,                                           -- the upload file (BOM + CRLF)
  export_sha256      text,
  unmatched          jsonb NOT NULL DEFAULT '[]'::jsonb,             -- approved notes with no UPI line
  upi_file_record_id integer,                                        -- UPI's Payment File Record ID
  built_by           uuid REFERENCES public.staff (id) ON DELETE SET NULL,
  built_at           timestamptz NOT NULL DEFAULT now(),
  uploaded_by        uuid REFERENCES public.staff (id) ON DELETE SET NULL,
  uploaded_at        timestamptz,
  CONSTRAINT e520_batches_month_seq_uq UNIQUE (org_id, service_month, seq),
  CONSTRAINT e520_batches_id_org_uq UNIQUE (id, org_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS e520_batches_one_draft
  ON public.e520_batches (org_id, service_month) WHERE status = 'draft';

CREATE TABLE IF NOT EXISTS public.e520_lines (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id           uuid NOT NULL,
  org_id             uuid NOT NULL,
  ord                integer NOT NULL,                               -- position in the export
  line_number        integer NOT NULL,
  source_line_number integer NOT NULL,
  raw                jsonb NOT NULL,                                 -- UPI's values, verbatim, in header order
  person_id          uuid REFERENCES public.persons (id) ON DELETE SET NULL,
  service_code       text,
  unit_type          text,
  start_date         date,
  end_date           date,
  source_start_date  date,
  source_end_date    date,
  units              integer NOT NULL DEFAULT 0,
  action             text NOT NULL CHECK (action IN ('fill', 'split', 'remove')),
  remove_reason      text,
  flags              jsonb NOT NULL DEFAULT '[]'::jsonb,
  upi_status         text CHECK (upi_status IS NULL OR upi_status IN (
                       'Waiting SC Approval', 'Waiting DSPD Approval', 'Submitted to CAPS', 'Held by CAPS',
                       'Error', 'Review', 'Deleted', 'Denied by SC', 'Denied by DSPD', 'Error by CAPS',
                       'Rejected by CAPS', 'Paid by CAPS')),
  upi_status_at      timestamptz,
  released_at        timestamptz,
  released_by        uuid REFERENCES public.staff (id) ON DELETE SET NULL,
  release_reason     text,
  CONSTRAINT e520_lines_batch_fk FOREIGN KEY (batch_id, org_id)
    REFERENCES public.e520_batches (id, org_id) ON DELETE CASCADE,
  CONSTRAINT e520_lines_id_org_uq UNIQUE (id, org_id)
);
CREATE INDEX IF NOT EXISTS e520_lines_batch_idx ON public.e520_lines (batch_id, ord);

CREATE TABLE IF NOT EXISTS public.e520_line_notes (
  line_id       uuid NOT NULL,
  org_id        uuid NOT NULL,
  note_id       uuid NOT NULL REFERENCES public.service_notes (id) ON DELETE RESTRICT,
  service_code  text NOT NULL,        -- the LINE's code: a DSG note backs its DSG day and its MTP day
  service_date  date NOT NULL,
  units         integer NOT NULL DEFAULT 0,
  released      boolean NOT NULL DEFAULT false,
  CONSTRAINT e520_line_notes_pk PRIMARY KEY (line_id, note_id, service_code),
  CONSTRAINT e520_line_notes_line_fk FOREIGN KEY (line_id, org_id)
    REFERENCES public.e520_lines (id, org_id) ON DELETE CASCADE
);
-- a note backs at most one live unit per code, in any batch, draft or uploaded
CREATE UNIQUE INDEX IF NOT EXISTS e520_line_notes_one_live
  ON public.e520_line_notes (note_id, service_code) WHERE NOT released;

COMMENT ON TABLE public.e520_batches IS 'v20.0.24 (e520): one UPI payment file — built from UPI''s download, frozen when marked uploaded. Written only by the e520_* RPCs.';
COMMENT ON TABLE public.e520_lines IS 'v20.0.24 (e520): one payment line of a batch; UPI''s values verbatim in raw, Provly''s units / dates / split parts beside them.';
COMMENT ON TABLE public.e520_line_notes IS 'v20.0.24 (e520): the approved notes behind each line''s units — the reservation that stops a note being claimed twice.';

-- ── 2. RLS: manage tier reads; no client writes (the RPCs are the only way in)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['e520_batches', 'e520_lines', 'e520_line_notes'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.%I FROM authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_tenant_guard', t);
    EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated
                      USING (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL)
                      WITH CHECK (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL)',
                   t || '_tenant_guard', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read_manage', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING ((SELECT public.access_tier()) = ''manage'')', t || '_read_manage', t);
  END LOOP;
END $$;

-- ── 3. The billed lock (extends v20.0.13's trg_service_notes_lock) ────────
CREATE OR REPLACE FUNCTION public.trg_service_notes_lock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tier text := public.access_tier();
  v_strip text[] := ARRAY['status', 'approved_by', 'approved_at', 'updated_at'];
  v_move text := coalesce(current_setting('provly.e520_transition', true), '');  -- v20.0.24: set only by e520_* RPCs
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;              -- service role / SQL editor

  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'billed' THEN                              -- v20.0.24
      RAISE EXCEPTION 'A note becomes billed only when its payment file is marked uploaded';
    END IF;
    IF NEW.status = 'approved' THEN
      IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
        RAISE EXCEPTION 'Only a supervisor or manager can approve a service note';
      END IF;
      NEW.approved_by := public.my_staff_id();
      NEW.approved_at := now();
    ELSE
      NEW.approved_by := NULL; NEW.approved_at := NULL;
    END IF;
    RETURN NEW;
  END IF;

  IF v_tier = 'deliver' THEN
    IF NEW.staff_id IS DISTINCT FROM OLD.staff_id OR NEW.person_id IS DISTINCT FROM OLD.person_id THEN
      RAISE EXCEPTION 'A service note stays with its author and client';
    END IF;
    IF NEW.status = 'approved' THEN
      RAISE EXCEPTION 'Only a supervisor or manager can approve a service note';
    END IF;
  END IF;

  -- v20.0.24 (e520 D8): BILLED — locked like approved, and no Reopen
  IF OLD.status = 'billed' THEN
    IF NEW.status = 'billed' THEN
      IF (to_jsonb(NEW) - 'updated_at') <> (to_jsonb(OLD) - 'updated_at') THEN
        RAISE EXCEPTION 'This service note is billed and locked.';
      END IF;
      RETURN NEW;                                              -- no-op update
    END IF;
    IF NEW.status = 'approved' AND v_move = 'release' THEN     -- e520_release_line only
      IF (to_jsonb(NEW) - v_strip) <> (to_jsonb(OLD) - v_strip) THEN
        RAISE EXCEPTION 'A released note returns to approved unchanged';
      END IF;
      NEW.approved_by := OLD.approved_by; NEW.approved_at := OLD.approved_at;
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'This service note is billed and locked. It returns to approved only when its payment line is released.';
  END IF;

  IF OLD.status = 'approved' THEN                               -- LOCKED
    IF NEW.status = 'approved' THEN
      IF (to_jsonb(NEW) - 'updated_at') <> (to_jsonb(OLD) - 'updated_at') THEN
        RAISE EXCEPTION 'This service note is approved and locked. Reopen it to make changes.';
      END IF;
      RETURN NEW;                                                -- no-op update
    END IF;
    IF NEW.status = 'billed' THEN                                -- v20.0.24: e520_mark_uploaded only
      IF v_move <> 'upload' THEN
        RAISE EXCEPTION 'A note becomes billed only when its payment file is marked uploaded';
      END IF;
      IF (to_jsonb(NEW) - v_strip) <> (to_jsonb(OLD) - v_strip) THEN
        RAISE EXCEPTION 'A note is billed unchanged';
      END IF;
      NEW.approved_by := OLD.approved_by; NEW.approved_at := OLD.approved_at;
      RETURN NEW;
    END IF;
    IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' OR NEW.status <> 'submitted' THEN
      RAISE EXCEPTION 'An approved service note can only be reopened (to submitted) by a supervisor or manager';
    END IF;
    IF (to_jsonb(NEW) - v_strip) <> (to_jsonb(OLD) - v_strip) THEN
      RAISE EXCEPTION 'Reopen the note first; edit it in a second step';
    END IF;
    NEW.approved_by := NULL; NEW.approved_at := NULL;
    INSERT INTO public.audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (OLD.org_id, auth.uid(), 'note_reopened', 'service_notes', OLD.id,
            jsonb_build_object('status', OLD.status, 'approved_by', OLD.approved_by, 'approved_at', OLD.approved_at),
            jsonb_build_object('status', NEW.status, 'reopened_by_staff_id', public.my_staff_id()));
    RETURN NEW;
  END IF;

  IF NEW.status = 'billed' THEN                                   -- v20.0.24: only approved → billed
    RAISE EXCEPTION 'Only an approved note can become billed';
  END IF;

  IF NEW.status = 'approved' THEN                               -- approving now
    IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
      RAISE EXCEPTION 'Only a supervisor or manager can approve a service note';
    END IF;
    NEW.approved_by := public.my_staff_id();
    NEW.approved_at := now();
  ELSE
    NEW.approved_by := NULL; NEW.approved_at := NULL;            -- not approved: no stamp survives
  END IF;
  RETURN NEW;
END;
$function$;

-- ── 4. Engine helpers (not callable by clients) ──────────────────────────

-- D5: minutes → quarter-hour units, nearest quarter hour (8+ leftover minutes earn a unit)
CREATE OR REPLACE FUNCTION public.e520_round_q(p_minutes numeric)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN coalesce(p_minutes, 0) <= 0 THEN 0
              ELSE (round(p_minutes)::int / 15) + CASE WHEN round(p_minutes)::int % 15 >= 8 THEN 1 ELSE 0 END
         END
$$;

-- who may work with payment files: manage tier; the service role passes its org explicitly
CREATE OR REPLACE FUNCTION public.e520_caller_org(p_org uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN p_org; END IF;
  IF public.access_tier() IS DISTINCT FROM 'manage' THEN
    RAISE EXCEPTION 'Only an owner, admin or compliance director can work with payment files';
  END IF;
  IF p_org IS NOT NULL AND p_org IS DISTINCT FROM public.org_id() THEN
    RAISE EXCEPTION 'That payment file belongs to another organization';
  END IF;
  RETURN public.org_id();
END;
$$;

-- one day's units for one person + code (D4/D5/D6), and each unreserved note's share
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
  ELSE
    o_note_units := 1;                                          -- D and M: a documented day
  END IF;

  IF p_evv THEN                                                  -- D4: note AND EVV visit, bill the lesser
    SELECT coalesce(sum(floor(extract(epoch FROM (e.clock_out_at - e.clock_in_at)) / 60)), 0)::integer,
           bool_or(true)
      INTO v_emin, v_eany
      FROM evv_sessions e
     WHERE e.org_id = p_org AND e.person_id = p_person AND e.service_code_id = p_code_id
       AND e.clock_out_at IS NOT NULL AND e.clock_out_at > e.clock_in_at
       AND (e.clock_in_at AT TIME ZONE 'America/Denver')::date = p_day;
    o_evv_units := CASE WHEN p_unit = 'Q' THEN e520_round_q(v_emin)
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

-- one UPI line → filled line(s), split parts, or a removed line; returns the next free line number
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
  v_need_auth := EXISTS (SELECT 1 FROM person_service_authorizations a
                          WHERE a.org_id = p_org AND a.person_id = v_person AND a.service_code_id = v_code_id
                            AND (a.start_date IS NULL OR a.start_date <= v_e) AND (a.end_date IS NULL OR a.end_date >= v_s));
  IF NOT v_need_auth THEN
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('kind', 'no_authorization',
                 'detail', 'No Provly authorization covers these dates; UPI''s line is used as the authority'));
  ELSE
    SELECT a.rate_per_unit INTO v_auth_rate
      FROM person_service_authorizations a
     WHERE a.org_id = p_org AND a.person_id = v_person AND a.service_code_id = v_code_id
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

-- D2: UPI's file back, byte for byte, except the fields Provly owns
CREATE OR REPLACE FUNCTION public.e520_render(p_batch uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_header text;
  v_hdr    text[];
  i        integer;
  i_ln     integer;
  i_units  integer;
  i_s      integer;
  i_e      integer;
  v_out    text;
  v_vals   text[];
  l        record;
BEGIN
  SELECT header INTO v_header FROM e520_batches WHERE id = p_batch;
  v_hdr := string_to_array(v_header, ',');
  FOR i IN 1 .. array_length(v_hdr, 1) LOOP
    CASE lower(btrim(v_hdr[i]))
      WHEN 'line_number'        THEN i_ln := i;
      WHEN 'units'              THEN i_units := i;
      WHEN 'service_start_date' THEN i_s := i;
      WHEN 'service_end_date'   THEN i_e := i;
      ELSE NULL;
    END CASE;
  END LOOP;
  v_out := v_header;
  FOR l IN SELECT * FROM e520_lines WHERE batch_id = p_batch AND action <> 'remove' ORDER BY ord LOOP
    SELECT array_agg(x ORDER BY o) INTO v_vals FROM jsonb_array_elements_text(l.raw) WITH ORDINALITY AS t(x, o);
    IF l.line_number <> l.source_line_number THEN v_vals[i_ln] := l.line_number::text; END IF;
    v_vals[i_units] := l.units::text;
    IF l.start_date <> l.source_start_date THEN v_vals[i_s] := to_char(l.start_date, 'MM/DD/YYYY'); END IF;
    IF l.end_date   <> l.source_end_date   THEN v_vals[i_e] := to_char(l.end_date,   'MM/DD/YYYY'); END IF;
    v_out := v_out || E'\r\n' || array_to_string(v_vals, ',');
  END LOOP;
  RETURN chr(65279) || v_out;                                    -- UTF-8 BOM, CRLF, no newline after the last row
END;
$$;

-- ── 5. The RPCs (SECURITY DEFINER: every query below is scoped to the batch's org) ──

CREATE OR REPLACE FUNCTION public.e520_build(p_filename text, p_csv text, p_org uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  c_required constant text[] := ARRAY['line_number', 'provider_approver_email', 'consumer_name', 'consumer_pid',
                                      'service_code', 'rate', 'unit_type', 'service_start_date', 'service_end_date',
                                      'units', 'remaining_units', 'sce'];
  v_org    uuid := public.e520_caller_org(p_org);
  v_text   text;
  v_lines  text[];
  v_header text;
  v_cols   text[];
  v_ncols  integer;
  v_idx    jsonb := '{}'::jsonb;
  v_col    text;
  v_i      integer;
  v_n      integer := 0;
  v_rows   jsonb := '[]'::jsonb;
  v_row    text;
  v_vals   text[];
  v_ln     text;
  v_pid    text;
  v_s      date;
  v_e      date;
  v_email  text;
  v_first_email text;
  v_max_ln integer := 0;
  v_month  date;
  v_seq    integer;
  v_batch  uuid;
  v_next   integer;
  r        jsonb;
  v_name   text;
  v_fname  text;
  v_out    text;
BEGIN
  IF v_org IS NULL THEN RAISE EXCEPTION 'No organization for this payment file'; END IF;

  -- D3: the Excel-saved CSV of UPI's download
  v_text := coalesce(p_csv, '');
  IF left(v_text, 1) = chr(65279) THEN v_text := substr(v_text, 2); END IF;
  IF btrim(v_text) = '' THEN RAISE EXCEPTION 'The file is empty'; END IF;
  IF position('"' IN v_text) > 0 THEN
    RAISE EXCEPTION 'The file has quoted fields, which UPI''s download never has. Save it again from Excel as CSV.';
  END IF;
  v_lines  := regexp_split_to_array(v_text, E'\r?\n');
  v_header := v_lines[1];
  v_cols   := string_to_array(v_header, ',');
  v_ncols  := array_length(v_cols, 1);
  FOR v_i IN 1 .. v_ncols LOOP
    v_idx := v_idx || jsonb_build_object(lower(btrim(v_cols[v_i])), v_i);
  END LOOP;
  FOREACH v_col IN ARRAY c_required LOOP
    IF NOT (v_idx ? v_col) THEN
      RAISE EXCEPTION 'The header has no % column. Use the file exactly as UPI downloads it.', v_col;
    END IF;
  END LOOP;

  FOR v_i IN 2 .. coalesce(array_length(v_lines, 1), 1) LOOP
    v_row := v_lines[v_i];
    CONTINUE WHEN regexp_replace(coalesce(v_row, ''), '[,[:space:]]', '', 'g') = '';
    v_vals := string_to_array(v_row, ',');
    IF array_length(v_vals, 1) <> v_ncols THEN
      RAISE EXCEPTION 'Row % has % fields but the header has %.', v_i - 1, array_length(v_vals, 1), v_ncols;
    END IF;
    v_n := v_n + 1;
    v_ln := btrim(v_vals[(v_idx->>'line_number')::integer]);
    IF v_ln !~ '^[0-9]+$' THEN RAISE EXCEPTION 'Row %: line_number is not a whole number.', v_i - 1; END IF;
    v_pid := btrim(v_vals[(v_idx->>'consumer_pid')::integer]);
    IF v_pid !~ '^0[0-9]{8}$' THEN
      RAISE EXCEPTION 'Row %: the PID is not 9 digits with a leading 0. Excel may have dropped the zero; fix the file and upload it again.', v_i - 1;
    END IF;
    BEGIN
      v_s := to_date(btrim(v_vals[(v_idx->>'service_start_date')::integer]), 'MM/DD/YYYY');
      v_e := to_date(btrim(v_vals[(v_idx->>'service_end_date')::integer]), 'MM/DD/YYYY');
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Row %: the dates are not mm/dd/yyyy.', v_i - 1;
    END;
    IF v_s IS NULL OR v_e IS NULL OR extract(year FROM v_s) NOT BETWEEN 2000 AND 2100 THEN
      RAISE EXCEPTION 'Row %: the dates are not mm/dd/yyyy.', v_i - 1;
    END IF;
    IF v_e < v_s OR date_trunc('month', v_s) <> date_trunc('month', v_e) THEN
      RAISE EXCEPTION 'Row %: a payment line''s dates must fall within one month.', v_i - 1;
    END IF;
    v_email := lower(btrim(v_vals[(v_idx->>'provider_approver_email')::integer]));
    IF v_first_email IS NULL THEN
      v_first_email := v_email;
    ELSIF v_email <> v_first_email THEN
      RAISE EXCEPTION 'The file has more than one provider_approver_email; UPI needs the same one on every line.';
    END IF;
    v_max_ln := greatest(v_max_ln, v_ln::integer);
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'ord',         v_n,
      'line_number', v_ln::integer,
      'pid',         v_pid,
      'code',        upper(btrim(v_vals[(v_idx->>'service_code')::integer])),
      'unit',        upper(btrim(v_vals[(v_idx->>'unit_type')::integer])),
      'rate',        btrim(v_vals[(v_idx->>'rate')::integer]),
      'start',       v_s,
      'end',         v_e,
      'max',         CASE WHEN v_idx ? 'monthly_max_units' THEN btrim(v_vals[(v_idx->>'monthly_max_units')::integer]) END,
      'remaining',   btrim(v_vals[(v_idx->>'remaining_units')::integer]),
      'vals',        to_jsonb(v_vals)));
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'The file has no payment lines.'; END IF;

  -- the batch month = the month most lines are in (late lines for earlier months ride along)
  SELECT z.m INTO v_month FROM (
    SELECT date_trunc('month', (x->>'start')::date)::date AS m, count(*) AS c
      FROM jsonb_array_elements(v_rows) AS x GROUP BY 1 ORDER BY c DESC, m DESC LIMIT 1) z;

  -- a rebuild replaces the month's draft; after an upload, the next build is a supplemental
  DELETE FROM e520_batches WHERE org_id = v_org AND service_month = v_month AND status = 'draft';
  SELECT coalesce(max(seq), 0) + 1 INTO v_seq FROM e520_batches WHERE org_id = v_org AND service_month = v_month;
  INSERT INTO e520_batches (org_id, service_month, seq, status, source_filename, source_csv, source_sha256,
                            header, approver_email, built_by)
  VALUES (v_org, v_month, v_seq, 'draft', p_filename, p_csv, encode(sha256(convert_to(p_csv, 'UTF8')), 'hex'),
          v_header, v_first_email, public.my_staff_id())
  RETURNING id INTO v_batch;

  v_next := v_max_ln + 1;
  -- r3: fill in date order so shared caps go to the earliest days; the export keeps file order (ord)
  FOR r IN SELECT x FROM jsonb_array_elements(v_rows) AS x ORDER BY (x->>'start')::date, (x->>'ord')::integer LOOP
    v_next := public.e520_fill_line(v_batch, v_org, r, v_next);
  END LOOP;

  -- delivered but not in the budget: approved notes of the month with no UPI line for that person + code
  UPDATE e520_batches b SET unmatched = coalesce((
    SELECT jsonb_agg(jsonb_build_object('person_id', z.person_id, 'code', z.code, 'notes', z.cnt,
                                        'first', z.first_day, 'last', z.last_day) ORDER BY z.code, z.first_day)
      FROM (
        SELECT n.person_id, c.code, count(*) AS cnt, min(n.service_date) AS first_day, max(n.service_date) AS last_day
          FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
         WHERE n.org_id = v_org AND n.status IN ('approved', 'billed')
           AND n.service_date >= v_month AND n.service_date < (v_month + interval '1 month')::date
           AND c.code <> 'MTP'
           AND NOT EXISTS (SELECT 1 FROM e520_line_notes x
                            WHERE x.note_id = n.id AND x.service_code = c.code AND NOT x.released)
           AND NOT EXISTS (SELECT 1 FROM e520_lines l
                            WHERE l.batch_id = v_batch AND l.person_id = n.person_id AND l.service_code = c.code)
         GROUP BY n.person_id, c.code) z), '[]'::jsonb)
   WHERE b.id = v_batch;

  -- the upload file and its name (YYYY-MM + org name, -2, -3 … for supplementals)
  SELECT regexp_replace(
           regexp_replace(coalesce(nullif(btrim(o.display_name), ''), nullif(btrim(o.legal_name), ''), o.name, 'Provider'),
                          '[,.]?\s+(inc|llc|l\.l\.c|corp|corporation|co|ltd)\.?$', '', 'i'),
           '[^A-Za-z0-9]', '', 'g')
    INTO v_name FROM organizations o WHERE o.id = v_org;
  v_fname := to_char(v_month, 'YYYY-MM') || coalesce(nullif(v_name, ''), 'Provider')
             || CASE WHEN v_seq > 1 THEN '-' || v_seq ELSE '' END || '.csv';
  v_out := public.e520_render(v_batch);
  UPDATE e520_batches
     SET export_filename = v_fname, export_csv = v_out,
         export_sha256 = encode(sha256(convert_to(v_out, 'UTF8')), 'hex')
   WHERE id = v_batch;

  INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, new_data)
  VALUES (v_org, auth.uid(), 'e520_built', 'e520_batches', v_batch,
          jsonb_build_object('month', v_month, 'seq', v_seq, 'lines', v_n));
  RETURN v_batch;
END;
$$;

CREATE OR REPLACE FUNCTION public.e520_mark_uploaded(p_batch uuid, p_export_sha256 text, p_upi_record_id integer DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_b   e520_batches%ROWTYPE;
  v_bad integer;
  v_n   integer;
BEGIN
  SELECT * INTO v_b FROM e520_batches WHERE id = p_batch FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment file not found'; END IF;
  IF auth.uid() IS NOT NULL AND v_b.org_id IS DISTINCT FROM public.e520_caller_org(NULL) THEN
    RAISE EXCEPTION 'Payment file not found';
  END IF;
  IF v_b.status <> 'draft' THEN RAISE EXCEPTION 'This payment file is already marked uploaded'; END IF;
  IF p_export_sha256 IS DISTINCT FROM v_b.export_sha256 THEN
    RAISE EXCEPTION 'This isn''t the file Provly built for this batch; it was rebuilt after you downloaded it. Download it again.';
  END IF;
  SELECT count(DISTINCT x.note_id) INTO v_bad
    FROM e520_line_notes x
    JOIN e520_lines l ON l.id = x.line_id
    JOIN service_notes n ON n.id = x.note_id
   WHERE l.batch_id = p_batch AND NOT x.released AND n.status NOT IN ('approved', 'billed');
  IF v_bad > 0 THEN
    RAISE EXCEPTION '% note(s) behind this file are no longer approved. Rebuild it before uploading.', v_bad;
  END IF;

  PERFORM set_config('provly.e520_transition', 'upload', true);
  UPDATE service_notes n SET status = 'billed'
   WHERE n.status = 'approved'
     AND n.id IN (SELECT x.note_id FROM e520_line_notes x JOIN e520_lines l ON l.id = x.line_id
                   WHERE l.batch_id = p_batch AND NOT x.released);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('provly.e520_transition', '', true);

  UPDATE e520_batches
     SET status = 'uploaded', uploaded_by = public.my_staff_id(), uploaded_at = now(),
         upi_file_record_id = coalesce(p_upi_record_id, upi_file_record_id)
   WHERE id = p_batch;
  INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, new_data)
  VALUES (v_b.org_id, auth.uid(), 'e520_uploaded', 'e520_batches', p_batch,
          jsonb_build_object('notes_billed', v_n, 'export_sha256', v_b.export_sha256, 'upi_file_record_id', p_upi_record_id));
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION public.e520_release_line(p_line uuid, p_upi_status text, p_reason text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  c_dead constant text[] := ARRAY['Deleted', 'Denied by SC', 'Denied by DSPD', 'Error by CAPS', 'Rejected by CAPS'];
  v_l       e520_lines%ROWTYPE;
  v_bstatus text;
  v_n       integer;
BEGIN
  IF p_upi_status IS NULL OR NOT (p_upi_status = ANY (c_dead)) THEN
    RAISE EXCEPTION 'Only a line UPI has closed can be released: Deleted, Denied by SC, Denied by DSPD, Error by CAPS or Rejected by CAPS';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Say why the line is being released';
  END IF;
  SELECT * INTO v_l FROM e520_lines WHERE id = p_line FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment line not found'; END IF;
  IF auth.uid() IS NOT NULL AND v_l.org_id IS DISTINCT FROM public.e520_caller_org(NULL) THEN
    RAISE EXCEPTION 'Payment line not found';
  END IF;
  SELECT status INTO v_bstatus FROM e520_batches WHERE id = v_l.batch_id;
  IF v_bstatus <> 'uploaded' THEN
    RAISE EXCEPTION 'Only a line in an uploaded file can be released; rebuild the draft instead';
  END IF;
  IF v_l.action = 'remove' THEN RAISE EXCEPTION 'This line was never sent'; END IF;
  IF v_l.released_at IS NOT NULL THEN RAISE EXCEPTION 'This line is already released'; END IF;

  UPDATE e520_lines
     SET upi_status = p_upi_status, upi_status_at = now(), released_at = now(),
         released_by = public.my_staff_id(), release_reason = btrim(p_reason)
   WHERE id = p_line;
  UPDATE e520_line_notes SET released = true WHERE line_id = p_line;

  PERFORM set_config('provly.e520_transition', 'release', true);
  UPDATE service_notes n SET status = 'approved'
   WHERE n.status = 'billed'
     AND n.id IN (SELECT x.note_id FROM e520_line_notes x WHERE x.line_id = p_line)
     AND NOT EXISTS (SELECT 1 FROM e520_line_notes x2
                       JOIN e520_lines l2 ON l2.id = x2.line_id
                       JOIN e520_batches b2 ON b2.id = l2.batch_id
                      WHERE x2.note_id = n.id AND NOT x2.released AND b2.status = 'uploaded');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('provly.e520_transition', '', true);

  INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, new_data)
  VALUES (v_l.org_id, auth.uid(), 'e520_line_released', 'e520_lines', p_line,
          jsonb_build_object('upi_status', p_upi_status, 'reason', btrim(p_reason), 'notes_released', v_n));
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION public.e520_delete_draft(p_batch uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_b e520_batches%ROWTYPE;
BEGIN
  SELECT * INTO v_b FROM e520_batches WHERE id = p_batch FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment file not found'; END IF;
  IF auth.uid() IS NOT NULL AND v_b.org_id IS DISTINCT FROM public.e520_caller_org(NULL) THEN
    RAISE EXCEPTION 'Payment file not found';
  END IF;
  IF v_b.status <> 'draft' THEN RAISE EXCEPTION 'An uploaded payment file is kept; release its lines instead'; END IF;
  DELETE FROM e520_batches WHERE id = p_batch;
  INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data)
  VALUES (v_b.org_id, auth.uid(), 'e520_draft_deleted', 'e520_batches', p_batch,
          jsonb_build_object('month', v_b.service_month, 'seq', v_b.seq));
END;
$$;

CREATE OR REPLACE FUNCTION public.e520_set_upi_record(p_batch uuid, p_record_id integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_b e520_batches%ROWTYPE;
BEGIN
  SELECT * INTO v_b FROM e520_batches WHERE id = p_batch FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment file not found'; END IF;
  IF auth.uid() IS NOT NULL AND v_b.org_id IS DISTINCT FROM public.e520_caller_org(NULL) THEN
    RAISE EXCEPTION 'Payment file not found';
  END IF;
  UPDATE e520_batches SET upi_file_record_id = p_record_id WHERE id = p_batch;
  INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
  VALUES (v_b.org_id, auth.uid(), 'e520_record_set', 'e520_batches', p_batch,
          jsonb_build_object('upi_file_record_id', v_b.upi_file_record_id),
          jsonb_build_object('upi_file_record_id', p_record_id));
END;
$$;

-- ── 6. Privileges ────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.e520_round_q(numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_caller_org(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_fill_line(uuid, uuid, jsonb, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_render(uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.e520_build(text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.e520_mark_uploaded(uuid, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.e520_release_line(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.e520_delete_draft(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.e520_set_upi_record(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.e520_build(text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.e520_mark_uploaded(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.e520_release_line(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.e520_delete_draft(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.e520_set_upi_record(uuid, integer) TO authenticated;

-- ── 7. Self-test: a synthetic month (January 2001, an inactive test client) run
--       end to end, then rolled back. r1: if ANY check fails, or the test can't
--       run, the whole file is rolled back — nothing in it is applied — and the
--       error lists each failing check. Results go to a session temp table.
CREATE TEMP TABLE IF NOT EXISTS v20024_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20024_selftest;

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
  SELECT s.org_id, s.id INTO v_org, v_staff FROM staff s ORDER BY s.id LIMIT 1;
  SELECT id INTO v_sln FROM service_code_definitions WHERE code = 'SLN' LIMIT 1;
  SELECT id INTO v_hhs FROM service_code_definitions WHERE code = 'HHS' LIMIT 1;
  SELECT id INTO v_dsg FROM service_code_definitions WHERE code = 'DSG' LIMIT 1;
  SELECT id INTO v_slh FROM service_code_definitions WHERE code = 'SLH' LIMIT 1;
  SELECT id INTO v_rps FROM service_code_definitions WHERE code = 'RPS' LIMIT 1;
  -- r3: the two SLH lines are listed out of date order (the 16th–31st line first)
  v_csv := chr(65279) || v_hdr || E'\r\n' || v_l1 || E'\r\n' || v_l2 || E'\r\n' || v_l3 || E'\r\n' || v_l4
           || E'\r\n' || v_l5 || E'\r\n' || v_l7 || E'\r\n' || v_l6;

  BEGIN
    -- ── the synthetic month ──
    v_step := 'creating the test client';
    v_person := pg_temp.e520_test_insert('persons', jsonb_build_object(
      'org_id', v_org, 'first_name', 'E520', 'last_name', 'Selftest', 'identification_number', '099999999', 'is_active', false));

    v_step := 'creating SLN notes, EVV visits and authorizations';
    -- SLN: two 20-minute notes on the 4th (EVV 35 min → the lesser count), one 127-minute note on the 5th (in an authorization gap)
    PERFORM pg_temp.e520_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_staff,
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
    PERFORM pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_sln, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-01-04', 'rate_per_unit', 8.27));
    PERFORM pg_temp.e520_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
      'service_code_id', v_sln, 'authorized_units', 100, 'used_units', 0, 'start_date', '2001-01-06', 'end_date', '2001-01-31', 'rate_per_unit', 8.27));

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
    -- a hospital day on the 10th
    INSERT INTO person_absences (org_id, person_id, start_date, end_date, reason)
    VALUES (v_org, v_person, DATE '2001-01-10', DATE '2001-01-10', 'hospital');

    -- ── T1–T8: the first build ──
    v_step := 'T1-T8 first build';
    v_batch := public.e520_build('selftest.csv', v_csv, v_org);

    SELECT string_agg(line_number || ':' || to_char(start_date, 'MM/DD') || '-' || to_char(end_date, 'MM/DD') || '=' || units, ', ' ORDER BY ord)
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch AND service_code = 'SLN' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'T1 SLN: day total rounded, EVV lesser, authorization gap and absence break the span', v_txt, '1:01/01-01/04=2'));

    SELECT (flags @> '[{"kind":"evv_gap"}]'::jsonb)::text || ',' || (flags @> '[{"kind":"outside_coverage"}]'::jsonb)::text
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch AND service_code = 'SLN' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'T2 SLN flags: EVV gap, day outside the authorization', v_txt, 'true,true'));

    SELECT string_agg(line_number || ':' || to_char(start_date, 'MM/DD') || '-' || to_char(end_date, 'MM/DD') || '=' || units, ', ' ORDER BY ord)
      INTO v_txt FROM e520_lines WHERE batch_id = v_batch AND service_code = 'HHS' AND action <> 'remove';
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'T3 HHS: split around the absence, new part numbered after the file''s highest', v_txt, '2:01/01-01/09=3, 8:01/11-01/31=1'));

    SELECT action || ': ' || coalesce(remove_reason, '') INTO v_txt
      FROM e520_lines WHERE batch_id = v_batch AND service_code = 'DSI';
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'T4 DSI: no documentation, removed', v_txt, 'remove: No approved documentation for these dates'));

    v_expect := chr(65279) || v_hdr
      || E'\r\n' || '1,selftest@example.com,Selftest E520,099999999,SLN,8.27,Q,01/01/2001,01/04/2001,2,520,Test Coordinator,100'
      || E'\r\n' || '2,selftest@example.com,Selftest E520,099999999,HHS,230.85,D,01/01/2001,01/09/2001,3,365,Test Coordinator,31'
      || E'\r\n' || '8,selftest@example.com,Selftest E520,099999999,HHS,230.85,D,01/11/2001,01/31/2001,1,365,Test Coordinator,31'
      || E'\r\n' || '4,selftest@example.com,Selftest E520,099999999,DSG,127,D,01/11/2001,01/31/2001,1,244,Test Coordinator,22'
      || E'\r\n' || '5,selftest@example.com,Selftest E520,099999999,MTP,20.8,D,01/11/2001,01/31/2001,1,244,Test Coordinator,22'
      || E'\r\n' || '7,selftest@example.com,Selftest E520,099999999,SLH,9.31,Q,01/16/2001,01/31/2001,1,100,Test Coordinator,3'
      || E'\r\n' || '6,selftest@example.com,Selftest E520,099999999,SLH,9.31,Q,01/01/2001,01/09/2001,2,100,Test Coordinator,3';
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
      RAISE EXCEPTION 'v20024_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024_rollback' THEN RAISE; END IF;
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
      RAISE EXCEPTION 'v20024_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024_rollback' THEN RAISE; END IF;
    END;
    v_ok := false;
    BEGIN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      PERFORM set_config('provly.e520_transition', 'upload', true);
      UPDATE service_notes SET status = 'billed' WHERE id = v_extra;
      v_ok := true;
      RAISE EXCEPTION 'v20024_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024_rollback' THEN RAISE; END IF;
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
      RAISE EXCEPTION 'v20024_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20024_rollback' THEN RAISE; END IF;
    END;
    v_txt := v_txt || '; ' || CASE WHEN v_msg LIKE 'Only an owner, admin or compliance director%' THEN 'non-manage refused' ELSE 'GATE: ' || coalesce(v_msg, 'accepted') END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(15, 'T15 guards: PID without its zero, quoted fields, a non-manage caller', v_txt,
                       'PID refused; quotes refused; non-manage refused'));

    v_res := v_res || jsonb_build_array(jsonb_build_array(16, 'T16 rounding spot checks (127, 40, 7, 8 minutes)',
                       public.e520_round_q(127) || ',' || public.e520_round_q(40) || ',' || public.e520_round_q(7) || ',' || public.e520_round_q(8),
                       '8,3,0,1'));

    RAISE EXCEPTION 'v20024_rollback';                          -- undo the whole synthetic month
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20024_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;

  -- r1: a failing or unfinished self-test rolls the whole file back
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail
    FROM jsonb_array_elements(v_res) AS e
   WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 16 THEN
    RAISE EXCEPTION 'v20.0.24 self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 16 checks ran', jsonb_array_length(v_res)));
  END IF;

  INSERT INTO v20024_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.e520_test_insert(text, jsonb);

COMMIT;

-- ── 8. Verification — paste this table into chat before the PR merges ────
SELECT * FROM (
  SELECT 1 AS n, 'e520 tables' AS check_item,
    (SELECT count(*)::text FROM pg_class
      WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'
        AND relname IN ('e520_batches', 'e520_lines', 'e520_line_notes')) AS value,
    '3' AS want
  UNION ALL
  SELECT 2, 'RLS on, read = manage tier, no client write policies',
    (SELECT (count(*) FILTER (WHERE c.relrowsecurity))::text || ' RLS, '
            || (SELECT count(*) FROM pg_policies p WHERE p.schemaname = 'public'
                  AND p.tablename IN ('e520_batches', 'e520_lines', 'e520_line_notes') AND p.cmd = 'SELECT') || ' read, '
            || (SELECT count(*) FROM pg_policies p WHERE p.schemaname = 'public'
                  AND p.tablename IN ('e520_batches', 'e520_lines', 'e520_line_notes') AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE')) || ' write'
       FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('e520_batches', 'e520_lines', 'e520_line_notes')),
    '3 RLS, 3 read, 0 write'
  UNION ALL
  SELECT 3, 'client write privileges on e520 tables (authenticated + anon)',
    (SELECT count(*)::text FROM information_schema.role_table_grants
      WHERE table_schema = 'public' AND table_name IN ('e520_batches', 'e520_lines', 'e520_line_notes')
        AND grantee IN ('authenticated', 'anon') AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
    '0'
  UNION ALL
  SELECT 4, 'RPCs: SECURITY DEFINER and callable by signed-in users',
    (SELECT string_agg(p.proname || '=' || CASE WHEN p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
                                               AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') THEN 'ok' ELSE 'NO' END,
                       ', ' ORDER BY p.proname)
       FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('e520_build', 'e520_mark_uploaded', 'e520_release_line', 'e520_delete_draft', 'e520_set_upi_record')),
    'e520_build=ok, e520_delete_draft=ok, e520_mark_uploaded=ok, e520_release_line=ok, e520_set_upi_record=ok'
  UNION ALL
  SELECT 5, 'engine helpers not callable by clients',
    (SELECT count(*)::text FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('e520_round_q', 'e520_caller_org', 'e520_day_units', 'e520_fill_line', 'e520_render')
        AND (has_function_privilege('authenticated', p.oid, 'EXECUTE') OR has_function_privilege('anon', p.oid, 'EXECUTE'))),
    '0'
  UNION ALL
  SELECT 6, 'approved-note lock now covers billed',
    (SELECT (pg_get_functiondef(p.oid) LIKE '%provly.e520_transition%')::text FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_service_notes_lock'),
    'true'
  UNION ALL
  SELECT 7, 'one live reservation per note and code; one draft per month',
    (SELECT count(*)::text FROM pg_indexes WHERE schemaname = 'public'
        AND indexname IN ('e520_line_notes_one_live', 'e520_batches_one_draft')),
    '2'
  UNION ALL
  SELECT 7 + t.n, t.item, t.value, t.want FROM v20024_selftest t
  UNION ALL
  SELECT 200, 'left behind by the self-test (test client, its batches, its notes)',
    (SELECT (SELECT count(*) FROM public.persons WHERE identification_number = '099999999')
            + (SELECT count(*) FROM public.e520_batches WHERE service_month = DATE '2001-01-01')
            + (SELECT count(*) FROM public.service_notes WHERE summary_note = 'e520 self-test'))::text,
    '0'
) v ORDER BY n;
