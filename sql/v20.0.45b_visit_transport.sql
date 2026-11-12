-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.45b_visit_transport.sql
-- Start / End transport during an ordinary visit (pay-engine design v1.1 §6, Decision 10)
--
-- When staff drive a Person during a visit (an SL outing: groceries, an appointment), they tap Start transport
-- and End transport. Each tap records the server's time and the phone's location if it gives one. The ride
-- becomes a "driving a Person" trip (reimbursable for W-2 staff, never for hosts — decision 1A).
--   • Only on the staff member's own open visit that has a Person (an EVV visit, or a time-clock visit such
--     as nursing); one transport at a time.
--   • A transport left open ends at its visit's clock-out, at the clock-out point.
--   • A transport that overlaps an MTP ride the same driver made isn't counted again.
--   • The trip finder (v20.0.45) is replaced only to add this one source; everything else in it is unchanged.
--
-- r1 (Greptile round 1, before this file ran): a transport left open when its visit ended is closed for real
--   (at the visit's clock-out time and point) before the next Start transport, so a forgotten End never
--   blocks later rides.
-- r2 (Greptile round 2, before this file ran): a ride closed at clock-out is marked as such, and its end keeps
--   following the visit — if the office corrects the clock-out, the ride's end moves with it (and a ride the
--   correction leaves outside the visit drops out). A tapped End is kept, but never past the visit's end.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction: preflight → changes → rolled-back self-test →
-- COMMIT → verification table (reads tables only).
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $pre$
BEGIN
  IF to_regclass('public.trips') IS NULL OR to_regprocedure('public._trip_upsert(uuid, uuid, text, text, text, uuid, uuid, timestamptz, timestamptz, numeric, numeric, numeric, numeric, uuid, uuid, timestamptz, boolean, numeric, integer, integer)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.45b preflight: v20.0.45 (staff trips, r2) has not run';
  END IF;
  IF to_regclass('public.visit_transports') IS NOT NULL THEN
    RAISE EXCEPTION 'v20.0.45b preflight: this migration has already run';
  END IF;
END
$pre$;

-- ── 1. Transports during visits ─────────────────────────────────────────────────────
CREATE TABLE public.visit_transports (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  staff_id    uuid NOT NULL,
  person_id   uuid NOT NULL,
  visit_ref   text NOT NULL CHECK (visit_ref ~ '^(evv|punch):[0-9a-f-]{36}$'),
  started_at  timestamptz NOT NULL,
  start_lat   numeric(9,6) CHECK (start_lat BETWEEN -90 AND 90),
  start_lng   numeric(9,6) CHECK (start_lng BETWEEN -180 AND 180),
  ended_at    timestamptz,
  end_lat     numeric(9,6) CHECK (end_lat BETWEEN -90 AND 90),
  end_lng     numeric(9,6) CHECK (end_lng BETWEEN -180 AND 180),
  ended_by    text CHECK (ended_by IN ('tap', 'clock_out')),     -- r2 — a clock_out end keeps following the visit
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT visit_transports_staff_fk FOREIGN KEY (staff_id, org_id) REFERENCES public.staff (id, org_id),
  CONSTRAINT visit_transports_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id) ON DELETE CASCADE,
  CONSTRAINT visit_transports_order CHECK (ended_at IS NULL OR ended_at > started_at),
  CONSTRAINT visit_transports_ended_shape CHECK ((ended_at IS NULL) = (ended_by IS NULL)),
  CONSTRAINT visit_transports_start_point CHECK ((start_lat IS NULL) = (start_lng IS NULL)),
  CONSTRAINT visit_transports_end_point CHECK ((end_lat IS NULL) = (end_lng IS NULL))
);
CREATE UNIQUE INDEX visit_transports_one_open ON public.visit_transports (staff_id) WHERE ended_at IS NULL;
CREATE INDEX visit_transports_staff_time ON public.visit_transports (org_id, staff_id, started_at);

-- The staff member's own open visit with a Person: its org, Person, and whether it's still open
CREATE FUNCTION public._vt_visit(p_kind text, p_id uuid)
RETURNS TABLE (o_org uuid, o_staff uuid, o_person uuid, o_open boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT e.org_id, e.staff_id, e.person_id, e.clock_out_at IS NULL FROM evv_sessions e WHERE p_kind = 'evv' AND e.id = p_id
  UNION ALL
  SELECT p.org_id, p.staff_id, p.person_id, p.clock_out_at IS NULL FROM time_punches p WHERE p_kind = 'punch' AND p.id = p_id AND p.person_id IS NOT NULL
$$;

-- A transport still open after its visit ended is closed at the visit's clock-out (its pay time and point)
CREATE FUNCTION public._vt_settle(p_staff uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE visit_transports vt
     SET ended_at = greatest(x.out_at, vt.started_at + interval '1 second'), end_lat = x.out_lat, end_lng = x.out_lng,
         ended_by = 'clock_out'
    FROM (SELECT t.id,
                 CASE WHEN e.id IS NOT NULL THEN
                        CASE WHEN e.original_clock_out_at IS NOT NULL THEN e.clock_out_at ELSE coalesce(e.server_clock_out_at, e.clock_out_at) END
                      ELSE p.clock_out_at END AS out_at,
                 coalesce(e.clock_out_lat, p.clock_out_lat) AS out_lat,
                 coalesce(e.clock_out_lng, p.clock_out_lng) AS out_lng
            FROM visit_transports t
            LEFT JOIN evv_sessions e ON t.visit_ref = 'evv:' || e.id::text
            LEFT JOIN time_punches p ON t.visit_ref = 'punch:' || p.id::text
           WHERE t.staff_id = p_staff AND t.ended_at IS NULL) x
   WHERE vt.id = x.id AND x.out_at IS NOT NULL
     AND (x.out_lat IS NULL) = (x.out_lng IS NULL);
END;
$$;

CREATE FUNCTION public._transport_start(p_kind text, p_id uuid, p_lat numeric, p_lng numeric, p_actor uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v  record;
  v_id uuid;
BEGIN
  IF p_kind NOT IN ('evv', 'punch') OR p_id IS NULL OR p_actor IS NULL THEN RAISE EXCEPTION 'Not permitted'; END IF;
  SELECT * INTO v FROM public._vt_visit(p_kind, p_id);
  IF NOT FOUND OR v.o_staff <> p_actor THEN RAISE EXCEPTION 'Start transport only on your own visit with a Person'; END IF;
  IF NOT v.o_open THEN RAISE EXCEPTION 'This visit has ended'; END IF;
  IF (p_lat IS NULL) <> (p_lng IS NULL) OR (p_lat IS NOT NULL AND (abs(p_lat) > 90 OR abs(p_lng) > 180)) THEN
    RAISE EXCEPTION 'The location from the phone is not valid';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('provly-trips'), hashtext(p_actor::text));     -- the trip finder's lock
  PERFORM public._vt_settle(p_actor);            -- r1 — one forgotten at an earlier clock-out is closed first
  IF EXISTS (SELECT 1 FROM visit_transports WHERE staff_id = p_actor AND ended_at IS NULL) THEN
    RAISE EXCEPTION 'A transport is already going — end it first';
  END IF;
  INSERT INTO visit_transports (org_id, staff_id, person_id, visit_ref, started_at, start_lat, start_lng)
  VALUES (v.o_org, p_actor, v.o_person, p_kind || ':' || p_id::text, clock_timestamp(), p_lat, p_lng)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE FUNCTION public._transport_end(p_transport uuid, p_lat numeric, p_lng numeric, p_actor uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  t  visit_transports;
  v  record;
  v_staff uuid;
BEGIN
  SELECT staff_id INTO v_staff FROM visit_transports WHERE id = p_transport;
  IF v_staff IS NULL OR v_staff IS DISTINCT FROM p_actor THEN RAISE EXCEPTION 'Not permitted'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('provly-trips'), hashtext(p_actor::text));     -- lock first, then the row
  SELECT * INTO t FROM visit_transports WHERE id = p_transport FOR UPDATE;
  IF t.ended_at IS NOT NULL THEN RAISE EXCEPTION 'This transport has already ended'; END IF;
  IF (p_lat IS NULL) <> (p_lng IS NULL) OR (p_lat IS NOT NULL AND (abs(p_lat) > 90 OR abs(p_lng) > 180)) THEN
    RAISE EXCEPTION 'The location from the phone is not valid';
  END IF;
  SELECT * INTO v FROM public._vt_visit(split_part(t.visit_ref, ':', 1), split_part(t.visit_ref, ':', 2)::uuid);
  IF NOT FOUND OR NOT v.o_open THEN
    RAISE EXCEPTION 'The visit has ended — the transport ended with it at clock-out';
  END IF;
  UPDATE visit_transports SET ended_at = greatest(clock_timestamp(), t.started_at + interval '1 second'), end_lat = p_lat, end_lng = p_lng,
                              ended_by = 'tap'
   WHERE id = t.id;
END;
$$;

CREATE FUNCTION public.transport_start(p_visit_kind text, p_visit_id uuid, p_lat numeric, p_lng numeric)
RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public._transport_start(p_visit_kind, p_visit_id, p_lat, p_lng, public.my_staff_id())
$$;

CREATE FUNCTION public.transport_end(p_transport uuid, p_lat numeric, p_lng numeric)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public._transport_end(p_transport, p_lat, p_lng, public.my_staff_id())
$$;

-- ── 2. The trip finder, with transports during visits added ─────────────────────────
CREATE OR REPLACE FUNCTION public._trips_refresh(p_org uuid, p_staff uuid, p_from date, p_to date)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_rf    numeric := 1.30;
  v_mph   integer := 30;
  v_pct   integer := 25;
  c       record;
  l       record;
  v_seen  text[] := '{}';
  v_split boolean;
  v_pref  text; v_pat timestamptz; v_plat numeric; v_plng numeric; v_pperson uuid;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('provly-trips'), hashtext(p_staff::text));
  SELECT road_factor, assumed_speed_mph, overclaim_pct INTO v_rf, v_mph, v_pct FROM pay_company_settings WHERE org_id = p_org;
  v_rf := coalesce(v_rf, 1.30); v_mph := coalesce(v_mph, 30); v_pct := coalesce(v_pct, 25);

  FOR c IN
    WITH visits AS (
      SELECT 'evv:' || e.id::text AS ref, e.person_id, e.shift_id, NULL::uuid AS work_block_id,
             CASE WHEN e.original_clock_in_at  IS NOT NULL THEN e.clock_in_at  ELSE coalesce(e.server_clock_in_at,  e.clock_in_at)  END AS in_at,
             CASE WHEN e.original_clock_out_at IS NOT NULL THEN e.clock_out_at ELSE coalesce(e.server_clock_out_at, e.clock_out_at) END AS out_at,
             e.clock_in_lat AS in_lat, e.clock_in_lng AS in_lng, e.clock_out_lat AS out_lat, e.clock_out_lng AS out_lng
        FROM evv_sessions e
       WHERE e.org_id = p_org AND e.staff_id = p_staff AND e.clock_out_at IS NOT NULL
         AND (e.clock_in_at AT TIME ZONE 'America/Denver')::date BETWEEN p_from - 1 AND p_to + 1
      UNION ALL
      SELECT 'punch:' || p.id::text, p.person_id, p.shift_id, p.work_block_id, p.clock_in_at, p.clock_out_at,
             p.clock_in_lat, p.clock_in_lng, p.clock_out_lat, p.clock_out_lng
        FROM time_punches p
       WHERE p.org_id = p_org AND p.staff_id = p_staff AND p.person_id IS NOT NULL AND p.clock_out_at IS NOT NULL
         AND (p.clock_in_at AT TIME ZONE 'America/Denver')::date BETWEEN p_from - 1 AND p_to + 1
    ), ordered AS (
      SELECT v.*, lead(v.ref) OVER w AS n_ref, lead(v.person_id) OVER w AS n_person, lead(v.in_at) OVER w AS n_in,
             lead(v.in_lat) OVER w AS n_lat, lead(v.in_lng) OVER w AS n_lng
        FROM visits v WINDOW w AS (ORDER BY v.in_at, v.ref)
    )
    SELECT o.ref AS from_ref, o.n_ref AS to_ref, o.person_id AS from_person, o.n_person AS to_person,
           o.out_at AS from_at, o.n_in AS to_at, o.out_lat AS from_lat, o.out_lng AS from_lng, o.n_lat AS to_lat, o.n_lng AS to_lng,
           o.shift_id AS a_shift, o.work_block_id AS a_block, o.in_at AS a_in
      FROM ordered o
     WHERE o.n_ref IS NOT NULL
       AND o.n_person IS DISTINCT FROM o.person_id                                   -- back-to-back Persons
       AND o.n_in >= o.out_at                                                        -- no overlap
       AND (o.out_at AT TIME ZONE 'America/Denver')::date = (o.n_in AT TIME ZONE 'America/Denver')::date
       AND (o.out_at AT TIME ZONE 'America/Denver')::date BETWEEN p_from AND p_to
  LOOP
    -- MTP rides this driver made during the gap split it, so no drive is counted twice
    v_split := false;
    v_pref := c.from_ref; v_pat := c.from_at; v_plat := c.from_lat; v_plng := c.from_lng; v_pperson := c.from_person;
    FOR l IN SELECT * FROM mtp_legs m
              WHERE m.org_id = p_org AND m.driver_staff_id = p_staff AND m.pickup_at IS NOT NULL AND m.dropoff_at IS NOT NULL
                AND m.dropoff_at > c.from_at AND m.pickup_at < c.to_at
              ORDER BY m.pickup_at, m.id
    LOOP
      v_split := true;
      IF l.pickup_at >= v_pat AND NOT public._trip_negligible(v_plat, v_plng, l.pickup_lat, l.pickup_lng, v_pat, l.pickup_at) THEN
        v_seen := v_seen || public._trip_upsert(p_org, p_staff, 'between_visits', v_pref, 'mtppick:' || l.id::text, v_pperson, l.person_id,
                                                v_pat, l.pickup_at, v_plat, v_plng, l.pickup_lat, l.pickup_lng, NULL, NULL, NULL, false, v_rf, v_mph, v_pct);
      END IF;
      IF l.dropoff_at > v_pat THEN
        v_pref := 'mtpdrop:' || l.id::text; v_pat := l.dropoff_at; v_plat := l.dropoff_lat; v_plng := l.dropoff_lng; v_pperson := l.person_id;
      END IF;
    END LOOP;
    IF NOT v_split THEN
      v_seen := v_seen || public._trip_upsert(p_org, p_staff, 'between_visits', c.from_ref, c.to_ref, c.from_person, c.to_person,
                                              c.from_at, c.to_at, c.from_lat, c.from_lng, c.to_lat, c.to_lng, c.a_shift, c.a_block, c.a_in, true, v_rf, v_mph, v_pct);
    ELSIF v_pat <= c.to_at AND NOT public._trip_negligible(v_plat, v_plng, c.to_lat, c.to_lng, v_pat, c.to_at) THEN
      v_seen := v_seen || public._trip_upsert(p_org, p_staff, 'between_visits', v_pref, c.to_ref, v_pperson, c.to_person,
                                              v_pat, c.to_at, v_plat, v_plng, c.to_lat, c.to_lng, NULL, NULL, NULL, false, v_rf, v_mph, v_pct);
    END IF;
  END LOOP;

  -- every complete MTP ride the staff member drove is a transport trip
  FOR l IN SELECT * FROM mtp_legs m
            WHERE m.org_id = p_org AND m.driver_staff_id = p_staff AND m.pickup_at IS NOT NULL AND m.dropoff_at IS NOT NULL
              AND m.service_date BETWEEN p_from AND p_to
  LOOP
    v_seen := v_seen || public._trip_upsert(p_org, p_staff, 'transport', 'mtp:' || l.id::text, 'mtp:' || l.id::text, l.person_id, l.person_id,
                                            l.pickup_at, l.dropoff_at, l.pickup_lat, l.pickup_lng, l.dropoff_lat, l.dropoff_lng,
                                            NULL, NULL, NULL, false, v_rf, v_mph, v_pct);
  END LOOP;

  -- v20.0.45b — transports during visits (Start / End transport taps). One left open, or closed at clock-out,
  -- ends at its visit's clock-out as corrected, at the clock-out point; a tapped End never runs past the visit. A transport overlapping an MTP ride the same driver made is left out
  -- (the ride is already counted). One still in progress is skipped until it ends.
  FOR l IN SELECT x.id, x.person_id, x.started_at, x.start_lat, x.start_lng,
                  CASE WHEN x.ended_by = 'tap' THEN least(x.ended_at, coalesce(x.visit_out, x.ended_at)) ELSE x.visit_out END AS end_at,
                  CASE WHEN x.ended_by = 'tap' AND x.ended_at <= coalesce(x.visit_out, x.ended_at) THEN x.end_lat ELSE x.visit_out_lat END AS end_lat,
                  CASE WHEN x.ended_by = 'tap' AND x.ended_at <= coalesce(x.visit_out, x.ended_at) THEN x.end_lng ELSE x.visit_out_lng END AS end_lng
             FROM (SELECT vt.*,
                          CASE WHEN e.id IS NOT NULL THEN
                                 CASE WHEN e.original_clock_out_at IS NOT NULL THEN e.clock_out_at ELSE coalesce(e.server_clock_out_at, e.clock_out_at) END
                               ELSE p.clock_out_at END AS visit_out,                 -- the visit's end as corrected (pay time)
                          coalesce(e.clock_out_lat, p.clock_out_lat) AS visit_out_lat,
                          coalesce(e.clock_out_lng, p.clock_out_lng) AS visit_out_lng
                     FROM visit_transports vt
                     LEFT JOIN evv_sessions e ON vt.visit_ref = 'evv:' || e.id::text
                     LEFT JOIN time_punches p ON vt.visit_ref = 'punch:' || p.id::text
                    WHERE vt.org_id = p_org AND vt.staff_id = p_staff
                      AND (vt.started_at AT TIME ZONE 'America/Denver')::date BETWEEN p_from AND p_to) x
  LOOP
    CONTINUE WHEN l.end_at IS NULL OR l.end_at <= l.started_at;
    CONTINUE WHEN EXISTS (SELECT 1 FROM mtp_legs m
                           WHERE m.org_id = p_org AND m.driver_staff_id = p_staff AND m.pickup_at IS NOT NULL AND m.dropoff_at IS NOT NULL
                             AND m.pickup_at < l.end_at AND m.dropoff_at > l.started_at);
    v_seen := v_seen || public._trip_upsert(p_org, p_staff, 'transport', 'vt:' || l.id::text, 'vt:' || l.id::text, l.person_id, l.person_id,
                                            l.started_at, l.end_at, l.start_lat, l.start_lng, l.end_lat, l.end_lng,
                                            NULL, NULL, NULL, false, v_rf, v_mph, v_pct);
  END LOOP;

  -- trips in the range whose source is gone
  UPDATE trips SET status = 'void', confirmed_miles = NULL, miles_source = NULL, correction_reason = NULL,
                   confirmed_at = NULL, confirmed_by = NULL, flags = '["source_removed"]'::jsonb, updated_at = now()
   WHERE org_id = p_org AND staff_id = p_staff AND trip_date BETWEEN p_from AND p_to AND status <> 'void'
     AND NOT ((from_ref || '>' || to_ref) = ANY (v_seen));
  RETURN coalesce(array_length(v_seen, 1), 0);
END;
$$;

-- ── 3. Access and grants ────────────────────────────────────────────────────────────
DO $rls$
BEGIN
  ALTER TABLE public.visit_transports ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON public.visit_transports FROM PUBLIC, anon, authenticated;
  GRANT SELECT ON public.visit_transports TO authenticated;
  CREATE POLICY visit_transports_read ON public.visit_transports FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id())
           AND (staff_id = (SELECT public.my_staff_id()) OR (SELECT public.access_tier())::text IN ('manage', 'operate')));
END
$rls$;

DO $fn$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname IN ('_vt_visit', '_vt_settle', '_transport_start', '_transport_end', 'transport_start', 'transport_end', '_trips_refresh')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    IF f.proname IN ('transport_start', 'transport_end') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
  END LOOP;
END
$fn$;

NOTIFY pgrst, 'reload schema';

-- ── 4. Self-test — synthetic staff, Person and visits, rolled back ──────────────────
CREATE OR REPLACE FUNCTION pg_temp.v20045b_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.45b self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $test$
DECLARE
  v_org   uuid;
  v_code  uuid;
  v_w2    uuid;
  v_other uuid;
  v_p     uuid;
  v_s     uuid;
  v_s2    uuid;
  v_t     uuid;
  v_t2    uuid;
  v_s3    uuid;
  v_today date := (now() AT TIME ZONE 'America/Denver')::date;
  tr      trips;
BEGIN
  SELECT m.org_id INTO v_org FROM org_members m WHERE m.role::text = 'owner' ORDER BY m.org_id LIMIT 1;
  SELECT id INTO v_code FROM service_code_definitions ORDER BY code LIMIT 1;
  IF v_org IS NULL OR v_code IS NULL THEN RAISE EXCEPTION 'SELFTEST FAIL 0: nothing to test with'; END IF;

  BEGIN
    v_w2    := pg_temp.v20045b_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'V20045B', 'last_name', 'Driver', 'employment_type', 'w2', 'is_active', true));
    v_other := pg_temp.v20045b_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'V20045B', 'last_name', 'Other', 'employment_type', 'w2', 'is_active', true));
    v_p     := pg_temp.v20045b_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20045B', 'last_name', 'Person',
                                                                            'identification_number', '099999947', 'is_active', true));
    -- an open visit (clocked in an hour ago)
    v_s := pg_temp.v20045b_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_w2, 'person_id', v_p, 'service_code_id', v_code,
      'clock_in_at', clock_timestamp() - interval '1 hour', 'server_clock_in_at', clock_timestamp() - interval '1 hour',
      'clock_in_lat', 40.7608, 'clock_in_lng', -111.8910));

    -- 1. Start transport on your own open visit; not twice; not on someone else's visit
    v_t := public._transport_start('evv', v_s, 40.7608, -111.8910, v_w2);
    BEGIN
      PERFORM public._transport_start('evv', v_s, 40.7608, -111.8910, v_w2);
      RAISE EXCEPTION 'SELFTEST FAIL 1: a second transport started while one was going';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public._transport_start('evv', v_s, NULL, NULL, v_other);
      RAISE EXCEPTION 'SELFTEST FAIL 1b: a transport started on someone else''s visit';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public._transport_end(v_t, NULL, NULL, v_other);
      RAISE EXCEPTION 'SELFTEST FAIL 1c: someone else ended the transport';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 2. End transport (as if after a 20-minute drive), then the visit ends: one reimbursable "driving a Person" trip
    UPDATE visit_transports SET started_at = clock_timestamp() - interval '25 minutes' WHERE id = v_t;
    PERFORM public._transport_end(v_t, 40.7000, -111.9000, v_w2);
    UPDATE evv_sessions SET clock_out_at = clock_timestamp(), clock_out_lat = 40.7000, clock_out_lng = -111.9000 WHERE id = v_s;
    PERFORM public._trips_refresh(v_org, v_w2, v_today, v_today);
    SELECT * INTO tr FROM trips WHERE staff_id = v_w2 AND from_ref = 'vt:' || v_t::text AND status <> 'void';
    IF NOT FOUND OR tr.kind <> 'transport' OR tr.classification <> 'transport_person' OR NOT tr.reimbursable OR coalesce(tr.est_miles, 0) <= 0 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 2: the transport did not become a reimbursable driving-a-Person trip';
    END IF;

    -- 3. a transport left open ends at the visit's clock-out, at the clock-out point; ending it after is refused
    v_s2 := pg_temp.v20045b_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_w2, 'person_id', v_p, 'service_code_id', v_code,
      'clock_in_at', clock_timestamp() - interval '10 minutes', 'server_clock_in_at', clock_timestamp() - interval '10 minutes',
      'clock_in_lat', 40.7000, 'clock_in_lng', -111.9000));
    v_t2 := public._transport_start('evv', v_s2, 40.7000, -111.9000, v_w2);
    UPDATE visit_transports SET started_at = clock_timestamp() - interval '8 minutes' WHERE id = v_t2;
    UPDATE evv_sessions SET clock_out_at = clock_timestamp(), clock_out_lat = 40.7608, clock_out_lng = -111.8910 WHERE id = v_s2;
    BEGIN
      PERFORM public._transport_end(v_t2, NULL, NULL, v_w2);
      RAISE EXCEPTION 'SELFTEST FAIL 3: a transport was ended after its visit had ended';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    PERFORM public._trips_refresh(v_org, v_w2, v_today, v_today);
    IF NOT EXISTS (SELECT 1 FROM trips WHERE staff_id = v_w2 AND from_ref = 'vt:' || v_t2::text AND status <> 'void'
                   AND to_lat = 40.7608 AND est_miles > 0) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3b: an open transport did not end at the visit''s clock-out point';
    END IF;

    -- 3c. a transport forgotten at clock-out doesn't block the next one: it's closed at the clock-out first
    v_s3 := pg_temp.v20045b_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_w2, 'person_id', v_p, 'service_code_id', v_code,
      'clock_in_at', clock_timestamp(), 'server_clock_in_at', clock_timestamp(), 'clock_in_lat', 40.7608, 'clock_in_lng', -111.8910));
    PERFORM public._transport_start('evv', v_s3, 40.7608, -111.8910, v_w2);
    IF NOT EXISTS (SELECT 1 FROM visit_transports WHERE id = v_t2 AND ended_at IS NOT NULL AND end_lat = 40.7608) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3c: the forgotten transport was not closed at its visit''s clock-out';
    END IF;
    IF (SELECT count(*) FROM visit_transports WHERE staff_id = v_w2 AND ended_at IS NULL) <> 1 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3d: the next transport could not start';
    END IF;

    -- 3e. the office corrects that visit's clock-out to before the ride started: the ride drops out
    UPDATE evv_sessions SET clock_out_at = (SELECT started_at FROM visit_transports WHERE id = v_t2) - interval '1 minute' WHERE id = v_s2;
    PERFORM public._trips_refresh(v_org, v_w2, v_today, v_today);
    IF EXISTS (SELECT 1 FROM trips WHERE staff_id = v_w2 AND from_ref = 'vt:' || v_t2::text AND status <> 'void') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3e: a ride closed at clock-out ignored the corrected clock-out';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM visit_transports WHERE id = v_t2 AND ended_by = 'clock_out') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3f: the ride closed at clock-out is not marked as such';
    END IF;

    -- 4. a transport overlapping an MTP ride the same driver made isn't counted twice
    INSERT INTO mtp_legs (org_id, person_id, service_date, direction, pickup_place, pickup_at, pickup_lat, pickup_lng, pickup_source,
                          dropoff_place, dropoff_at, dropoff_lat, dropoff_lng, dropoff_source, driver_staff_id)
    SELECT v_org, v_p, v_today, 'to_program', 'Home', vt.started_at, 40.7608, -111.8910, 'tap',
           'Day program', vt.ended_at, 40.7000, -111.9000, 'tap', v_w2
      FROM visit_transports vt WHERE vt.id = v_t;
    PERFORM public._trips_refresh(v_org, v_w2, v_today, v_today);
    IF EXISTS (SELECT 1 FROM trips WHERE staff_id = v_w2 AND from_ref = 'vt:' || v_t::text AND status <> 'void') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4: a transport was counted on top of the MTP ride covering it';
    END IF;

    RAISE EXCEPTION 'SELFTEST_ROLLBACK' USING ERRCODE = 'PRVOK';
  EXCEPTION WHEN SQLSTATE 'PRVOK' THEN
    NULL;  -- every self-test write above is rolled back here
  END;
END
$test$;

SELECT set_config('request.jwt.claims', '{}', true);

COMMIT;

-- ── Verification table (reads tables only — safe after COMMIT) ──────────────────────
SELECT n, check_name, got, want,
       CASE WHEN want = '(information)' THEN 'ℹ️' WHEN got = want THEN '✅' ELSE '❌' END AS ok FROM (
  SELECT 1 n, 'Visit transports table with RLS' check_name,
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.visit_transports'::regclass)::text got, 'true' want
  UNION ALL SELECT 2, 'Clients cannot write transports directly',
    (has_table_privilege('authenticated', 'public.visit_transports', 'INSERT') OR has_table_privilege('authenticated', 'public.visit_transports', 'UPDATE'))::text, 'false'
  UNION ALL SELECT 3, 'One transport at a time per staff member',
    (SELECT count(*) FROM pg_indexes WHERE indexname = 'visit_transports_one_open')::text, '1'
  UNION ALL SELECT 4, 'Public transport functions for signed-in users (not anon)',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('transport_start', 'transport_end')
       AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE'))::text, '2'
  UNION ALL SELECT 5, 'Internal functions callable by clients',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('_vt_visit', '_vt_settle', '_transport_start', '_transport_end', '_trips_refresh')
       AND (has_function_privilege('authenticated', oid, 'EXECUTE') OR has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  UNION ALL SELECT 6, 'The trip finder reads transports during visits',
    (position('visit_transports' IN pg_get_functiondef('public._trips_refresh(uuid, uuid, date, date)'::regprocedure)) > 0)::text, 'true'
  UNION ALL SELECT 7, 'Self-test leftovers (synthetic staff / Person / transports)',
    ((SELECT count(*) FROM staff WHERE first_name = 'V20045B')::text || '/' ||
     (SELECT count(*) FROM persons WHERE identification_number = '099999947')::text || '/' ||
     (SELECT count(*) FROM visit_transports)::text), '0/0/0'
) t
ORDER BY n;
