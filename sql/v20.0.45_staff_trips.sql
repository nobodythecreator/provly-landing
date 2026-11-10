-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.45_staff_trips.sql
-- Staff trips and mileage (pay-engine design v1.1 §6; decisions 2, 3, 9, 10; Nov 2026 decisions 1A, 2A)
--
--   Trips between visits   From one visit's clock-out point to the next visit's clock-in point, the same
--                          day, when the two visits are with different Persons. Visits are EVV sessions
--                          and time-clock punches with a Person (nursing visits). The first visit of the
--                          day has no trip into it: the commute is never counted.
--   Transport trips        MTP rides (v20.0.44) the staff member drove, pickup to drop-off.
--   Estimate               straight-line distance × road factor (1.30), worked out here from the two
--                          points; nothing is sent anywhere. Drive time = miles ÷ assumed speed (30 mph).
--   Classification         post_gap (not reimbursed) when the gap between the visits was off duty: a valid
--                          schedule release, its notice logged at clock-out, and a gap of at least the
--                          drive time + the off-duty buffer (30 min). Otherwise between_persons. MTP rides
--                          are transport_person. Mileage is paid only on those two, only to W-2 staff
--                          (decision 1A, Nov 2026: hosts' driving is in their scope, covered by the
--                          pass-through payment), always as the driver's own car (decision 2A: no agency
--                          vehicles today).
--   Confirmation           Staff confirm the estimate or correct the miles (a reason when they differ);
--                          miles more than 25% over the estimate are flagged for the reviewer. A trip
--                          whose visits change after it was confirmed goes back to pending.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction: preflight → changes → rolled-back self-test →
-- COMMIT → verification table. The verification table reads tables only (no sign-in-dependent functions).
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $pre$
BEGIN
  IF to_regclass('public.mtp_legs') IS NULL THEN RAISE EXCEPTION 'v20.0.45 preflight: v20.0.44 (MTP trips) has not run'; END IF;
  IF to_regprocedure('public._release_valid(uuid, uuid, boolean)') IS NULL OR to_regclass('public.release_notices') IS NULL THEN
    RAISE EXCEPTION 'v20.0.45 preflight: v20.0.35 (schedule releases) has not run';
  END IF;
  IF to_regclass('public.time_punches') IS NULL
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'evv_sessions' AND column_name = 'server_clock_out_at') THEN
    RAISE EXCEPTION 'v20.0.45 preflight: the time clock and server clock (v20.0.32, 32c) have not run';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'staff' AND column_name = 'employment_type') THEN
    RAISE EXCEPTION 'v20.0.45 preflight: staff.employment_type (v20.0.4c) not found';
  END IF;
  IF to_regclass('public.trips') IS NOT NULL OR to_regclass('public.pay_company_settings') IS NOT NULL THEN
    RAISE EXCEPTION 'v20.0.45 preflight: this migration has already run';
  END IF;
END
$pre$;

-- ── 1. Company pay settings (design §4.3) ────────────────────────────────────────────
CREATE TABLE public.pay_company_settings (
  org_id             uuid PRIMARY KEY REFERENCES public.organizations (id) ON DELETE CASCADE,
  road_factor        numeric(4,2) NOT NULL DEFAULT 1.30 CHECK (road_factor BETWEEN 1.00 AND 2.00),
  assumed_speed_mph  smallint     NOT NULL DEFAULT 30   CHECK (assumed_speed_mph BETWEEN 5 AND 80),
  overclaim_pct      smallint     NOT NULL DEFAULT 25   CHECK (overclaim_pct BETWEEN 0 AND 200),
  updated_at         timestamptz  NOT NULL DEFAULT now()
);
INSERT INTO public.pay_company_settings (org_id) SELECT id FROM public.organizations ON CONFLICT DO NOTHING;

CREATE FUNCTION public.trg_pay_company_settings_seed()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO pay_company_settings (org_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER pay_company_settings_seed AFTER INSERT ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_pay_company_settings_seed();

-- ── 2. Trips ────────────────────────────────────────────────────────────────────────
CREATE TABLE public.trips (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL,
  staff_id           uuid NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('between_visits', 'transport')),
  trip_date          date NOT NULL,                     -- Mountain time
  from_ref           text NOT NULL,                     -- 'evv:<id>' / 'punch:<id>' / 'mtp:<leg id>'
  to_ref             text NOT NULL,
  from_person_id     uuid,
  to_person_id       uuid,
  from_at            timestamptz NOT NULL,
  to_at              timestamptz NOT NULL,
  from_lat           numeric(9,6), from_lng numeric(9,6),
  to_lat             numeric(9,6), to_lng   numeric(9,6),
  est_miles          numeric(7,2),
  est_drive_min      integer,
  gap_min            integer,
  classification     text NOT NULL CHECK (classification IN ('between_persons', 'transport_person', 'post_gap')),
  worker_type        text NOT NULL CHECK (worker_type IN ('w2', 'contractor_1099')),
  reimbursable       boolean NOT NULL,
  status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'void')),
  confirmed_miles    numeric(7,2) CHECK (confirmed_miles IS NULL OR confirmed_miles BETWEEN 0 AND 500),
  miles_source       text CHECK (miles_source IN ('estimate', 'staff_corrected', 'staff_entered')),
  correction_reason  text,
  confirmed_at       timestamptz,
  confirmed_by       uuid,
  flags              jsonb NOT NULL DEFAULT '[]'::jsonb,
  source_sig         text NOT NULL,                     -- the visits' times and points this trip was built from
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trips_staff_fk FOREIGN KEY (staff_id, org_id) REFERENCES public.staff (id, org_id),
  CONSTRAINT trips_one_per_source UNIQUE (staff_id, from_ref, to_ref),
  CONSTRAINT trips_confirmed_shape CHECK ((status = 'confirmed') = (confirmed_miles IS NOT NULL AND confirmed_at IS NOT NULL AND miles_source IS NOT NULL)),
  CONSTRAINT trips_order CHECK (to_at >= from_at)
);
CREATE INDEX trips_staff_date ON public.trips (org_id, staff_id, trip_date);

-- ── 3. Distance and the off-duty test ───────────────────────────────────────────────
CREATE FUNCTION public._trip_miles(p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  -- great-circle (haversine) distance in miles; NULL if either point is missing
  SELECT CASE WHEN p_lat1 IS NULL OR p_lng1 IS NULL OR p_lat2 IS NULL OR p_lng2 IS NULL THEN NULL ELSE
    3958.8 * 2 * asin(least(1, sqrt(
      power(sin(radians((p_lat2 - p_lat1)::float8) / 2), 2)
      + cos(radians(p_lat1::float8)) * cos(radians(p_lat2::float8)) * power(sin(radians((p_lng2 - p_lng1)::float8) / 2), 2))))::numeric END
$$;

-- Decision 9: off duty only with a valid release, its notice logged at clock-out, and a long-enough gap
CREATE FUNCTION public._trip_off_duty(p_org uuid, p_staff uuid, p_out timestamptz, p_in timestamptz, p_drive_min integer, p_buffer integer)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT extract(epoch FROM (p_in - p_out)) / 60 >= coalesce(p_drive_min, 0) + coalesce(p_buffer, 30)
     AND EXISTS (SELECT 1 FROM schedule_releases r JOIN release_notices n ON n.release_id = r.id AND n.org_id = r.org_id
                  WHERE r.org_id = p_org AND r.staff_id = p_staff AND r.revoked_at IS NULL
                    AND n.noticed_at BETWEEN p_out - interval '12 hours' AND p_out + interval '10 minutes'
                    AND r.return_at > p_out AND r.return_at <= p_in + interval '15 minutes'
                    AND public._release_valid(p_org, r.id, false))
$$;

-- W-2 or contractor on the day: an active pay assignment decides; otherwise the staff record
CREATE FUNCTION public._trip_worker_type(p_org uuid, p_staff uuid, p_day date)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(
    (SELECT CASE WHEN bool_or(a.worker_type = 'w2') THEN 'w2' ELSE 'contractor_1099' END
       FROM staff_pay_assignments a
      WHERE a.org_id = p_org AND a.staff_id = p_staff AND a.start_date <= p_day AND (a.end_date IS NULL OR a.end_date >= p_day)
     HAVING count(*) > 0),
    (SELECT s.employment_type FROM staff s WHERE s.id = p_staff),
    'w2')
$$;

-- ── 4. Finding trips ────────────────────────────────────────────────────────────────
-- Rebuilds one staff member's trips for a date range from their visits and MTP rides. Confirmed miles
-- survive as long as the visits behind the trip are unchanged; if they change, the trip returns to pending.
-- A trip whose visits disappear is voided. Serialized per staff member (the same lock confirming takes).
CREATE FUNCTION public._trips_refresh(p_org uuid, p_staff uuid, p_from date, p_to date)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_rf     numeric := 1.30;
  v_mph    integer := 30;
  v_pct    integer := 25;
  v_buffer constant integer := 30;          -- off_duty_buffer_min: 30 in every Hope Haven policy (R1)
  c        record;
  t        trips;
  v_seen   text[] := '{}';
  v_day    date;
  v_est    numeric;
  v_drive  integer;
  v_gap    integer;
  v_class  text;
  v_wt     text;
  v_reimb  boolean;
  v_sig    text;
  v_flags  jsonb;
  v_n      integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('provly-trips'), hashtext(p_staff::text));
  SELECT road_factor, assumed_speed_mph, overclaim_pct INTO v_rf, v_mph, v_pct FROM pay_company_settings WHERE org_id = p_org;
  v_rf := coalesce(v_rf, 1.30); v_mph := coalesce(v_mph, 30); v_pct := coalesce(v_pct, 25);

  FOR c IN
    WITH visits AS (
      SELECT 'evv:' || e.id::text AS ref, e.person_id,
             coalesce(e.server_clock_in_at, e.clock_in_at)   AS in_at,
             coalesce(e.server_clock_out_at, e.clock_out_at) AS out_at,
             e.clock_in_lat AS in_lat, e.clock_in_lng AS in_lng, e.clock_out_lat AS out_lat, e.clock_out_lng AS out_lng
        FROM evv_sessions e
       WHERE e.org_id = p_org AND e.staff_id = p_staff AND e.clock_out_at IS NOT NULL
         AND (coalesce(e.server_clock_in_at, e.clock_in_at) AT TIME ZONE 'America/Denver')::date BETWEEN p_from - 1 AND p_to + 1
      UNION ALL
      SELECT 'punch:' || p.id::text, p.person_id, p.clock_in_at, p.clock_out_at,
             p.clock_in_lat, p.clock_in_lng, p.clock_out_lat, p.clock_out_lng
        FROM time_punches p
       WHERE p.org_id = p_org AND p.staff_id = p_staff AND p.person_id IS NOT NULL AND p.clock_out_at IS NOT NULL
         AND (p.clock_in_at AT TIME ZONE 'America/Denver')::date BETWEEN p_from - 1 AND p_to + 1
    ), ordered AS (
      SELECT v.*, lead(v.ref) OVER w AS n_ref, lead(v.person_id) OVER w AS n_person, lead(v.in_at) OVER w AS n_in,
             lead(v.in_lat) OVER w AS n_lat, lead(v.in_lng) OVER w AS n_lng
        FROM visits v WINDOW w AS (ORDER BY v.in_at, v.ref)
    )
    SELECT 'between_visits'::text AS kind, o.ref AS from_ref, o.n_ref AS to_ref, o.person_id AS from_person, o.n_person AS to_person,
           o.out_at AS from_at, o.n_in AS to_at, o.out_lat AS from_lat, o.out_lng AS from_lng, o.n_lat AS to_lat, o.n_lng AS to_lng
      FROM ordered o
     WHERE o.n_ref IS NOT NULL
       AND o.n_person IS DISTINCT FROM o.person_id                                   -- back-to-back Persons
       AND o.n_in >= o.out_at                                                        -- no overlap
       AND (o.out_at AT TIME ZONE 'America/Denver')::date = (o.n_in AT TIME ZONE 'America/Denver')::date
       AND (o.out_at AT TIME ZONE 'America/Denver')::date BETWEEN p_from AND p_to
    UNION ALL
    SELECT 'transport', 'mtp:' || l.id::text, 'mtp:' || l.id::text, l.person_id, l.person_id, l.pickup_at, l.dropoff_at,
           l.pickup_lat, l.pickup_lng, l.dropoff_lat, l.dropoff_lng
      FROM mtp_legs l
     WHERE l.org_id = p_org AND l.driver_staff_id = p_staff AND l.pickup_at IS NOT NULL AND l.dropoff_at IS NOT NULL
       AND l.service_date BETWEEN p_from AND p_to
  LOOP
    v_day   := (c.from_at AT TIME ZONE 'America/Denver')::date;
    v_est   := round(public._trip_miles(c.from_lat, c.from_lng, c.to_lat, c.to_lng) * v_rf, 2);
    v_drive := CASE WHEN v_est IS NULL THEN NULL ELSE ceil(v_est / v_mph * 60)::integer END;
    v_gap   := floor(extract(epoch FROM (c.to_at - c.from_at)) / 60)::integer;
    v_class := CASE WHEN c.kind = 'transport' THEN 'transport_person'
                    WHEN public._trip_off_duty(p_org, p_staff, c.from_at, c.to_at, v_drive, v_buffer) THEN 'post_gap'
                    ELSE 'between_persons' END;
    v_wt    := public._trip_worker_type(p_org, p_staff, v_day);
    v_reimb := v_wt = 'w2' AND v_class IN ('between_persons', 'transport_person');
    v_flags := '[]'::jsonb;
    IF v_est IS NULL THEN v_flags := v_flags || '["no_location"]'::jsonb; END IF;
    IF c.kind = 'between_visits' AND v_class = 'between_persons' AND v_gap > coalesce(v_drive, 0) + v_buffer THEN
      v_flags := v_flags || '["long_gap_no_release"]'::jsonb;
    END IF;
    v_sig := concat_ws('|', c.from_at, c.to_at, c.from_lat, c.from_lng, c.to_lat, c.to_lng, c.from_person, c.to_person);
    v_seen := v_seen || (c.from_ref || '>' || c.to_ref);

    SELECT * INTO t FROM trips WHERE staff_id = p_staff AND from_ref = c.from_ref AND to_ref = c.to_ref FOR UPDATE;
    IF NOT FOUND THEN
      INSERT INTO trips (org_id, staff_id, kind, trip_date, from_ref, to_ref, from_person_id, to_person_id, from_at, to_at,
                         from_lat, from_lng, to_lat, to_lng, est_miles, est_drive_min, gap_min, classification, worker_type,
                         reimbursable, flags, source_sig)
      VALUES (p_org, p_staff, c.kind, v_day, c.from_ref, c.to_ref, c.from_person, c.to_person, c.from_at, c.to_at,
              c.from_lat, c.from_lng, c.to_lat, c.to_lng, v_est, v_drive, v_gap, v_class, v_wt, v_reimb, v_flags, v_sig);
    ELSIF t.source_sig IS DISTINCT FROM v_sig OR t.status = 'void' THEN
      -- the visits behind it changed (or came back): new estimate, and a confirmed trip is confirmed again
      UPDATE trips SET trip_date = v_day, from_person_id = c.from_person, to_person_id = c.to_person, from_at = c.from_at, to_at = c.to_at,
                       from_lat = c.from_lat, from_lng = c.from_lng, to_lat = c.to_lat, to_lng = c.to_lng,
                       est_miles = v_est, est_drive_min = v_drive, gap_min = v_gap, classification = v_class, worker_type = v_wt,
                       reimbursable = v_reimb, status = 'pending', confirmed_miles = NULL, miles_source = NULL, correction_reason = NULL,
                       confirmed_at = NULL, confirmed_by = NULL,
                       flags = v_flags || CASE WHEN t.status = 'confirmed' THEN '["changed_after_confirm"]'::jsonb ELSE '[]'::jsonb END,
                       source_sig = v_sig, updated_at = now()
       WHERE id = t.id;
    ELSE
      -- same visits: a release or a pay assignment may have changed how it's classified
      v_flags := v_flags
                 || CASE WHEN t.flags ? 'changed_after_confirm' AND t.status <> 'confirmed' THEN '["changed_after_confirm"]'::jsonb ELSE '[]'::jsonb END
                 || CASE WHEN v_reimb AND t.status = 'confirmed' AND v_est IS NOT NULL
                              AND t.confirmed_miles > v_est * (1 + v_pct / 100.0) THEN '["over_estimate"]'::jsonb ELSE '[]'::jsonb END;
      IF (t.classification, t.worker_type, t.reimbursable) IS DISTINCT FROM (v_class, v_wt, v_reimb) OR t.flags IS DISTINCT FROM v_flags THEN
        UPDATE trips SET classification = v_class, worker_type = v_wt, reimbursable = v_reimb,
                         status            = CASE WHEN v_reimb THEN status ELSE 'pending' END,
                         confirmed_miles   = CASE WHEN v_reimb THEN confirmed_miles END,
                         miles_source      = CASE WHEN v_reimb THEN miles_source END,
                         confirmed_at      = CASE WHEN v_reimb THEN confirmed_at END,
                         confirmed_by      = CASE WHEN v_reimb THEN confirmed_by END,
                         correction_reason = CASE WHEN v_reimb THEN correction_reason END,
                         flags = v_flags, updated_at = now()
         WHERE id = t.id;
      END IF;
    END IF;
    v_n := v_n + 1;
  END LOOP;

  -- trips in the range whose visits are gone
  UPDATE trips SET status = 'void', confirmed_miles = NULL, miles_source = NULL, correction_reason = NULL,
                   confirmed_at = NULL, confirmed_by = NULL, flags = '["source_removed"]'::jsonb, updated_at = now()
   WHERE org_id = p_org AND staff_id = p_staff AND trip_date BETWEEN p_from AND p_to AND status <> 'void'
     AND NOT ((from_ref || '>' || to_ref) = ANY (v_seen));
  RETURN v_n;
END;
$$;

-- ── 5. Confirming ───────────────────────────────────────────────────────────────────
-- NULL miles = the estimate. Different miles need a reason (a correction); miles on a trip with no
-- estimate are entered by the staff member. More than overclaim_pct over the estimate is flagged.
-- Staff confirm their own trips; office staff can confirm for someone, with a reason.
CREATE FUNCTION public._trip_confirm(p_trip uuid, p_miles numeric, p_reason text, p_actor uuid, p_tier text)
RETURNS trips
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  t        trips;
  v_pct    integer;
  v_miles  numeric;
  v_src    text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_staff  uuid;
BEGIN
  SELECT staff_id INTO v_staff FROM trips WHERE id = p_trip;
  IF v_staff IS NULL THEN RAISE EXCEPTION 'Trip not found'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('provly-trips'), hashtext(v_staff::text));   -- the refresh's lock first
  SELECT * INTO t FROM trips WHERE id = p_trip FOR UPDATE;                             -- then the row
  IF NOT FOUND THEN RAISE EXCEPTION 'Trip not found'; END IF;
  IF p_actor IS NULL OR p_tier IS NULL OR p_tier NOT IN ('manage', 'operate', 'deliver')
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = t.org_id AND s.is_active) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  IF p_tier = 'deliver' AND t.staff_id <> p_actor THEN RAISE EXCEPTION 'You can confirm only your own trips'; END IF;
  IF t.status = 'void' THEN RAISE EXCEPTION 'This trip no longer exists — its visits changed'; END IF;
  IF NOT t.reimbursable THEN
    RAISE EXCEPTION '%', CASE WHEN t.worker_type <> 'w2' THEN 'Driving is part of the host agreement — this trip isn''t reimbursed'
                              ELSE 'This trip followed an off-duty break and isn''t reimbursed' END;
  END IF;
  IF t.staff_id <> p_actor AND (v_reason IS NULL OR length(v_reason) < 3) THEN
    RAISE EXCEPTION 'Give a reason for confirming someone else''s trip';
  END IF;

  IF p_miles IS NULL THEN
    IF t.est_miles IS NULL THEN RAISE EXCEPTION 'There''s no estimate for this trip — enter the miles'; END IF;
    v_miles := t.est_miles; v_src := 'estimate';
  ELSE
    v_miles := round(p_miles, 2);
    IF v_miles < 0 OR v_miles > 500 THEN RAISE EXCEPTION 'Enter the miles driven (0 to 500)'; END IF;
    IF t.est_miles IS NULL THEN v_src := 'staff_entered';
    ELSIF abs(v_miles - t.est_miles) < 0.05 THEN v_src := 'estimate';
    ELSE
      IF v_reason IS NULL OR length(v_reason) < 3 THEN RAISE EXCEPTION 'Say why the miles differ from the estimate'; END IF;
      v_src := 'staff_corrected';
    END IF;
  END IF;
  IF t.status = 'confirmed' AND v_miles <> t.confirmed_miles AND (v_reason IS NULL OR length(v_reason) < 3) THEN
    RAISE EXCEPTION 'This trip is already confirmed — say why the miles are changing';
  END IF;

  SELECT overclaim_pct INTO v_pct FROM pay_company_settings WHERE org_id = t.org_id;
  v_pct := coalesce(v_pct, 25);
  UPDATE trips SET status = 'confirmed', confirmed_miles = v_miles, miles_source = v_src,
                   correction_reason = CASE WHEN v_src = 'estimate' AND t.staff_id = p_actor THEN NULL ELSE v_reason END,
                   confirmed_at = now(), confirmed_by = p_actor,
                   flags = (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM jsonb_array_elements(t.flags) x
                             WHERE x NOT IN ('"over_estimate"'::jsonb, '"changed_after_confirm"'::jsonb))
                           || CASE WHEN t.est_miles IS NOT NULL AND v_miles > t.est_miles * (1 + v_pct / 100.0)
                                   THEN '["over_estimate"]'::jsonb ELSE '[]'::jsonb END,
                   updated_at = now()
   WHERE id = t.id RETURNING * INTO t;
  RETURN t;
END;
$$;

-- ── 6. Public functions ─────────────────────────────────────────────────────────────
-- A staff member's trips for a date range (their own; office staff for anyone), refreshed first.
CREATE FUNCTION public.trips_for_staff(p_staff uuid, p_from date, p_to date)
RETURNS SETOF trips
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org   uuid := public.org_id();
  v_me    uuid := public.my_staff_id();
  v_tier  text := public.access_tier()::text;
  v_staff uuid := coalesce(p_staff, public.my_staff_id());
BEGIN
  IF v_org IS NULL OR v_me IS NULL OR v_tier IS NULL OR v_tier NOT IN ('manage', 'operate', 'deliver') THEN RAISE EXCEPTION 'Not permitted'; END IF;
  IF v_tier = 'deliver' AND v_staff <> v_me THEN RAISE EXCEPTION 'You can see only your own trips'; END IF;
  IF NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = v_staff AND s.org_id = v_org) THEN RAISE EXCEPTION 'Not permitted'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 62 THEN RAISE EXCEPTION 'Choose a range of up to two months'; END IF;
  PERFORM public._trips_refresh(v_org, v_staff, p_from, p_to);
  RETURN QUERY SELECT * FROM trips WHERE org_id = v_org AND staff_id = v_staff AND trip_date BETWEEN p_from AND p_to AND status <> 'void'
                ORDER BY from_at;
END;
$$;

CREATE FUNCTION public.trip_confirm(p_trip uuid, p_miles numeric, p_reason text)
RETURNS trips
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM trips WHERE id = p_trip;
  IF v_org IS NULL OR v_org IS DISTINCT FROM public.org_id() THEN RAISE EXCEPTION 'Not permitted'; END IF;
  RETURN public._trip_confirm(p_trip, p_miles, p_reason, public.my_staff_id(), public.access_tier()::text);
END;
$$;

-- ── 7. Access and grants ────────────────────────────────────────────────────────────
DO $rls$
BEGIN
  ALTER TABLE public.trips ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.pay_company_settings ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON public.trips, public.pay_company_settings FROM PUBLIC, anon, authenticated;
  GRANT SELECT ON public.trips, public.pay_company_settings TO authenticated;
  CREATE POLICY trips_read ON public.trips FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id())
           AND (staff_id = (SELECT public.my_staff_id()) OR (SELECT public.access_tier())::text IN ('manage', 'operate')));
  CREATE POLICY pay_company_settings_read ON public.pay_company_settings FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id()));
END
$rls$;

DO $fn$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('trg_pay_company_settings_seed', '_trip_miles', '_trip_off_duty', '_trip_worker_type', '_trips_refresh',
                         '_trip_confirm', 'trips_for_staff', 'trip_confirm')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    IF f.proname IN ('trips_for_staff', 'trip_confirm') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
  END LOOP;
END
$fn$;

NOTIFY pgrst, 'reload schema';

-- ── 8. Self-test — synthetic staff, Persons and visits, rolled back ─────────────────
CREATE OR REPLACE FUNCTION pg_temp.v20045_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.45 self-test') || '::' || c.typ END;
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
  v_host  uuid;
  v_p1    uuid;
  v_p2    uuid;
  v_a     uuid;
  v_b     uuid;
  v_day   date := date '2001-03-05';
  t       trips;
  v_n     integer;
  v_est   numeric;
  v_ts    timestamptz;
  f       timestamptz := (TIMESTAMP '2001-03-05 09:00' AT TIME ZONE 'America/Denver');
BEGIN
  SELECT m.org_id INTO v_org FROM org_members m WHERE m.role::text = 'owner' ORDER BY m.org_id LIMIT 1;
  SELECT id INTO v_code FROM service_code_definitions ORDER BY code LIMIT 1;
  IF v_org IS NULL OR v_code IS NULL THEN RAISE EXCEPTION 'SELFTEST FAIL 0: nothing to test with'; END IF;

  BEGIN
    v_w2   := pg_temp.v20045_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'V20045', 'last_name', 'Driver',
                                                                       'employment_type', 'w2', 'is_active', true));
    v_host := pg_temp.v20045_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'V20045', 'last_name', 'Host',
                                                                       'employment_type', 'contractor_1099', 'is_active', true));
    v_p1 := pg_temp.v20045_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20045', 'last_name', 'One',
                                                                        'identification_number', '099999945', 'is_active', true));
    v_p2 := pg_temp.v20045_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20045', 'last_name', 'Two',
                                                                        'identification_number', '099999946', 'is_active', true));
    -- visit A (Person 1) 9–10, downtown; visit B (Person 2) 10:30–11:30, about 6.5 miles south
    v_a := pg_temp.v20045_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_w2, 'person_id', v_p1, 'service_code_id', v_code,
      'clock_in_at', f, 'clock_out_at', f + interval '1 hour', 'server_clock_in_at', f, 'server_clock_out_at', f + interval '1 hour',
      'clock_in_lat', 40.7608, 'clock_in_lng', -111.8910, 'clock_out_lat', 40.7608, 'clock_out_lng', -111.8910));
    v_b := pg_temp.v20045_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_w2, 'person_id', v_p2, 'service_code_id', v_code,
      'clock_in_at', f + interval '90 minutes', 'clock_out_at', f + interval '150 minutes',
      'server_clock_in_at', f + interval '90 minutes', 'server_clock_out_at', f + interval '150 minutes',
      'clock_in_lat', 40.6669, 'clock_in_lng', -111.8880, 'clock_out_lat', 40.6669, 'clock_out_lng', -111.8880));
    -- visit C (Person 2 again) 12–1: no trip from B (same Person)
    PERFORM pg_temp.v20045_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_w2, 'person_id', v_p2, 'service_code_id', v_code,
      'clock_in_at', f + interval '3 hours', 'clock_out_at', f + interval '4 hours',
      'server_clock_in_at', f + interval '3 hours', 'server_clock_out_at', f + interval '4 hours',
      'clock_in_lat', 40.6669, 'clock_in_lng', -111.8880, 'clock_out_lat', 40.6669, 'clock_out_lng', -111.8880));

    -- 1. one trip between the two Persons, estimated from the points × 1.30, reimbursable for W-2
    PERFORM public._trips_refresh(v_org, v_w2, v_day, v_day);
    SELECT count(*) INTO v_n FROM trips WHERE staff_id = v_w2 AND status <> 'void';
    IF v_n <> 1 THEN RAISE EXCEPTION 'SELFTEST FAIL 1: expected one trip (back-to-back Persons only), found %', v_n; END IF;
    SELECT * INTO t FROM trips WHERE staff_id = v_w2 AND status <> 'void';
    v_est := round(public._trip_miles(40.7608, -111.8910, 40.6669, -111.8880) * 1.30, 2);
    IF t.est_miles <> v_est OR t.classification <> 'between_persons' OR NOT t.reimbursable OR t.from_person_id <> v_p1 OR t.to_person_id <> v_p2 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 1b: trip estimate or classification wrong (% mi, %, reimbursable %)', t.est_miles, t.classification, t.reimbursable;
    END IF;
    IF t.est_miles NOT BETWEEN 7 AND 10 THEN RAISE EXCEPTION 'SELFTEST FAIL 1c: implausible estimate % mi', t.est_miles; END IF;

    -- 2. confirming the estimate; another front-line login can't confirm it
    BEGIN
      PERFORM public._trip_confirm(t.id, NULL, NULL, v_host, 'deliver');
      RAISE EXCEPTION 'SELFTEST FAIL 2: someone else confirmed the trip';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    t := public._trip_confirm(t.id, NULL, NULL, v_w2, 'deliver');
    IF t.status <> 'confirmed' OR t.confirmed_miles <> v_est OR t.miles_source <> 'estimate' THEN
      RAISE EXCEPTION 'SELFTEST FAIL 2b: the estimate was not confirmed';
    END IF;

    -- 3. different miles need a reason; well over the estimate is flagged
    BEGIN
      PERFORM public._trip_confirm(t.id, v_est + 3, NULL, v_w2, 'deliver');
      RAISE EXCEPTION 'SELFTEST FAIL 3: miles were changed without a reason';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    t := public._trip_confirm(t.id, v_est + 3, 'road closed, took the detour', v_w2, 'deliver');
    IF t.miles_source <> 'staff_corrected' OR NOT (t.flags ? 'over_estimate') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3b: the correction or its over-estimate flag is missing';
    END IF;

    -- 4. a confirmed trip whose visit changes goes back to pending
    UPDATE evv_sessions SET clock_in_lat = 40.6500, clock_in_lng = -111.8900 WHERE id = v_b;
    PERFORM public._trips_refresh(v_org, v_w2, v_day, v_day);
    SELECT * INTO t FROM trips WHERE staff_id = v_w2 AND status <> 'void';
    IF t.status <> 'pending' OR NOT (t.flags ? 'changed_after_confirm') OR t.confirmed_miles IS NOT NULL THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4: a changed visit kept the old confirmation';
    END IF;

    -- 5. if two visits stop being back-to-back Persons, their trip is voided (and the new pairing gets one)
    UPDATE evv_sessions SET person_id = v_p1 WHERE id = v_b;
    PERFORM public._trips_refresh(v_org, v_w2, v_day, v_day);
    IF NOT EXISTS (SELECT 1 FROM trips WHERE staff_id = v_w2 AND from_ref = 'evv:' || v_a::text AND status = 'void') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 5: a trip outlived its visits';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trips WHERE staff_id = v_w2 AND from_ref = 'evv:' || v_b::text AND status = 'pending') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 5b: the new back-to-back pairing got no trip';
    END IF;
    UPDATE evv_sessions SET person_id = v_p2 WHERE id = v_b;

    -- 6. an MTP ride the staff member drove is a transport trip, reimbursable
    INSERT INTO mtp_legs (org_id, person_id, service_date, direction, pickup_place, pickup_at, pickup_lat, pickup_lng, pickup_source,
                          dropoff_place, dropoff_at, dropoff_lat, dropoff_lng, dropoff_source, driver_staff_id)
    VALUES (v_org, v_p1, v_day, 'to_program', 'Home', f - interval '40 minutes', 40.7000, -111.9000, 'tap',
            'Day program', f - interval '15 minutes', 40.7608, -111.8910, 'tap', v_w2);
    PERFORM public._trips_refresh(v_org, v_w2, v_day, v_day);
    IF NOT EXISTS (SELECT 1 FROM trips WHERE staff_id = v_w2 AND kind = 'transport' AND classification = 'transport_person'
                   AND reimbursable AND status = 'pending' AND est_miles > 0) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6: the MTP ride did not become a reimbursable transport trip';
    END IF;

    -- 7. a host (contractor) gets the same trips recorded, never reimbursed, and can't confirm them
    PERFORM pg_temp.v20045_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_host, 'person_id', v_p1, 'service_code_id', v_code,
      'clock_in_at', f, 'clock_out_at', f + interval '1 hour', 'server_clock_in_at', f, 'server_clock_out_at', f + interval '1 hour',
      'clock_out_lat', 40.7608, 'clock_out_lng', -111.8910, 'clock_in_lat', 40.7608, 'clock_in_lng', -111.8910));
    PERFORM pg_temp.v20045_test_insert('evv_sessions', jsonb_build_object('org_id', v_org, 'staff_id', v_host, 'person_id', v_p2, 'service_code_id', v_code,
      'clock_in_at', f + interval '90 minutes', 'clock_out_at', f + interval '2 hours',
      'server_clock_in_at', f + interval '90 minutes', 'server_clock_out_at', f + interval '2 hours',
      'clock_in_lat', 40.6669, 'clock_in_lng', -111.8880, 'clock_out_lat', 40.6669, 'clock_out_lng', -111.8880));
    PERFORM public._trips_refresh(v_org, v_host, v_day, v_day);
    SELECT * INTO t FROM trips WHERE staff_id = v_host AND status <> 'void';
    IF NOT FOUND OR t.reimbursable OR t.worker_type <> 'contractor_1099' THEN
      RAISE EXCEPTION 'SELFTEST FAIL 7: a host''s trip was not recorded as not reimbursed';
    END IF;
    BEGIN
      PERFORM public._trip_confirm(t.id, NULL, NULL, v_host, 'deliver');
      RAISE EXCEPTION 'SELFTEST FAIL 7b: a host confirmed a mileage trip';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 8. no location → no estimate, flagged; the staff member enters the miles
    UPDATE evv_sessions SET clock_in_lat = NULL, clock_in_lng = NULL WHERE id = v_b;
    PERFORM public._trips_refresh(v_org, v_w2, v_day, v_day);
    SELECT * INTO t FROM trips WHERE staff_id = v_w2 AND kind = 'between_visits' AND status <> 'void';
    IF t.est_miles IS NOT NULL OR NOT (t.flags ? 'no_location') THEN RAISE EXCEPTION 'SELFTEST FAIL 8: a trip with no location was estimated'; END IF;
    t := public._trip_confirm(t.id, 6.2, NULL, v_w2, 'deliver');
    IF t.miles_source <> 'staff_entered' OR t.confirmed_miles <> 6.2 THEN RAISE EXCEPTION 'SELFTEST FAIL 8b: entered miles were not kept'; END IF;

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
  SELECT 1 n, 'Trip and settings tables with RLS' check_name,
    (SELECT count(*) FROM pg_class WHERE relname IN ('trips', 'pay_company_settings') AND relrowsecurity)::text got, '2' want
  UNION ALL SELECT 2, 'Clients cannot write trips or settings directly',
    (has_table_privilege('authenticated', 'public.trips', 'INSERT') OR has_table_privilege('authenticated', 'public.trips', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.pay_company_settings', 'UPDATE'))::text, 'false'
  UNION ALL SELECT 3, 'Every organization has pay settings (1.30 road factor, 30 mph, 25% over-claim)',
    ((SELECT count(*) FROM organizations) = (SELECT count(*) FROM pay_company_settings WHERE road_factor = 1.30 AND assumed_speed_mph = 30 AND overclaim_pct = 25))::text, 'true'
  UNION ALL SELECT 4, 'Public trip functions for signed-in users (not anon)',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('trips_for_staff', 'trip_confirm')
       AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE'))::text, '2'
  UNION ALL SELECT 5, 'Internal trip functions callable by clients',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('_trip_miles', '_trip_off_duty', '_trip_worker_type', '_trips_refresh', '_trip_confirm')
       AND (has_function_privilege('authenticated', oid, 'EXECUTE') OR has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  UNION ALL SELECT 6, 'Self-test leftovers (synthetic staff / Persons / trips)',
    ((SELECT count(*) FROM staff WHERE first_name = 'V20045')::text || '/' ||
     (SELECT count(*) FROM persons WHERE identification_number IN ('099999945', '099999946'))::text || '/' ||
     (SELECT count(*) FROM trips)::text), '0/0/0'
  UNION ALL SELECT 7, 'Staff by pay type (W-2 / contractor — hosts are never reimbursed)',
    ((SELECT count(*) FROM staff WHERE is_active AND employment_type = 'w2')::text || ' / ' ||
     (SELECT count(*) FROM staff WHERE is_active AND employment_type = 'contractor_1099')::text), '(information)'
) t
ORDER BY n;
