-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.44_mtp_documentation.sql
-- MTP trip records (DHHS91172 Scope of Work, Article 13.3(3); decision C, Nov 2026)
--
-- Article 13.3(3) requires written billing documentation for MTP with, for each time the Person is picked
-- up or dropped off: the Person, the date, the pickup and drop-off LOCATIONS, the pickup and drop-off TIMES,
-- the code (MTP) and the staff member. The DSG note's "Transported: to and from" field (v20.0.23, e520 D6)
-- doesn't hold locations or times, so it can no longer stand behind an MTP day.
--
--   mtp_legs      One row per trip each way (home → program, program → home) for a Person on a day: pickup
--                 place + time, drop-off place + time, the driver. Filled by Start/End transport taps (place,
--                 GPS point, server time) or typed; corrections need a reason and are kept in mtp_leg_history.
--                 A leg typed after its day has ended is a LATE ENTRY and needs a reason.
--   Billing       An MTP day bills only when its DSG note is approved AND the day has at least one leg AND
--                 every leg on it is complete (_mtp_day_documented). Authorization usage counts the same days,
--                 plus days already billed for MTP. The transport field is no longer read by billing.
--   Locking       A day whose MTP is in an e520 file (a live line) can't have its legs changed.
--
-- r1 (Greptile round 1, before this file ran): a front-line login can change only trips it drove (the
--   existing trip's driver is checked, by typed entry and by taps); trip changes and the e520 build's MTP
--   check share a per-Person lock, so a trip can't be removed between the build reading it and reserving
--   the day (e520_day_units becomes VOLATILE so it reads after taking the lock); a typed save changes the
--   source and GPS of only the parts that actually changed.
-- r3 (after it ran — the changes committed; only the final check failed): verification row 10 called a
--   function that reads the session's sign-in details, which are blank once the transaction has ended. The
--   row now counts the days directly; row 4 looks for the old rule itself (n.transport) rather than the word,
--   which also appears in a comment. Nothing above COMMIT changed. DON'T RUN THIS FILE AGAIN — its
--   preflight would stop it anyway.
-- r2 (Greptile round 2, before this file ran): every write takes the Person lock BEFORE locking a trip row —
--   removing a trip now reads it, takes the Person lock, then locks and re-reads the row (as saving and
--   tapping already did), so a removal and a save on the same trip can't deadlock.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction: preflight → changes → rolled-back self-test on a
-- synthetic Person → COMMIT → verification table.
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $pre$
BEGIN
  IF to_regprocedure('public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date)') IS NULL
     OR to_regprocedure('public.provly_auth_used_units(uuid, uuid, uuid, date, date, uuid, text)') IS NULL
     OR to_regprocedure('public.provly_recompute_auth_units(uuid, uuid, uuid, date)') IS NULL
     OR to_regclass('public.e520_line_notes') IS NULL THEN
    RAISE EXCEPTION 'v20.0.44 preflight: the e520 billing functions (v20.0.26) were not found';
  END IF;
  IF to_regprocedure('public.can_see_person(uuid)') IS NULL OR to_regprocedure('public.access_tier()') IS NULL
     OR to_regprocedure('public.staff_sees_person(uuid, uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.44 preflight: the access helpers (v20.0.11/12) were not found';
  END IF;
  IF position('transport' IN pg_get_functiondef('public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'v20.0.44 preflight: e520_day_units is not the v20.0.26 version this file replaces';
  END IF;
  IF to_regclass('public.mtp_legs') IS NOT NULL THEN
    RAISE EXCEPTION 'v20.0.44 preflight: this migration has already run';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM service_code_definitions WHERE code = 'DSG') THEN
    RAISE EXCEPTION 'v20.0.44 preflight: service code DSG not found';
  END IF;
END
$pre$;

-- ── 1. Trip legs and their history ──────────────────────────────────────────────────
CREATE TABLE public.mtp_legs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL,
  person_id        uuid NOT NULL,
  service_date     date NOT NULL,
  direction        text NOT NULL CHECK (direction IN ('to_program', 'from_program')),
  pickup_place     text CHECK (pickup_place IS NULL OR length(btrim(pickup_place)) BETWEEN 2 AND 300),
  pickup_at        timestamptz,
  pickup_lat       numeric(9,6),
  pickup_lng       numeric(9,6),
  pickup_source    text CHECK (pickup_source IN ('tap', 'typed')),
  dropoff_place    text CHECK (dropoff_place IS NULL OR length(btrim(dropoff_place)) BETWEEN 2 AND 300),
  dropoff_at       timestamptz,
  dropoff_lat      numeric(9,6),
  dropoff_lng      numeric(9,6),
  dropoff_source   text CHECK (dropoff_source IN ('tap', 'typed')),
  driver_staff_id  uuid NOT NULL REFERENCES public.staff (id),
  late_entry       boolean NOT NULL DEFAULT false,
  late_reason      text,
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mtp_legs_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id) ON DELETE CASCADE,
  CONSTRAINT mtp_legs_order CHECK (pickup_at IS NULL OR dropoff_at IS NULL OR dropoff_at > pickup_at),
  CONSTRAINT mtp_legs_late_reason CHECK (NOT late_entry OR length(btrim(coalesce(late_reason, ''))) >= 3),
  CONSTRAINT mtp_legs_one_each_way UNIQUE (person_id, service_date, direction)
);
CREATE INDEX mtp_legs_person_day ON public.mtp_legs (org_id, person_id, service_date);

CREATE TABLE public.mtp_leg_history (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL,
  leg_id        uuid NOT NULL,
  person_id     uuid NOT NULL,
  service_date  date NOT NULL,
  action        text NOT NULL CHECK (action IN ('tap', 'record', 'correct', 'delete')),
  changed_by    uuid,
  changed_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  old_values    jsonb,
  new_values    jsonb,
  reason        text
);
CREATE INDEX mtp_leg_history_leg ON public.mtp_leg_history (leg_id, changed_at);

CREATE FUNCTION public.trg_mtp_leg_history_append_only()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'MTP trip history can''t be changed or deleted';
END;
$$;
CREATE TRIGGER mtp_leg_history_append_only BEFORE UPDATE OR DELETE ON public.mtp_leg_history
  FOR EACH ROW EXECUTE FUNCTION public.trg_mtp_leg_history_append_only();

-- ── 2. What makes an MTP day billable ───────────────────────────────────────────────
-- At least one leg, and every leg on the day has its pickup place and time and its drop-off place and time.
CREATE FUNCTION public._mtp_day_documented(p_org uuid, p_person uuid, p_day date)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT (public.org_id() IS NULL OR public.org_id() = p_org)
     AND EXISTS (SELECT 1 FROM mtp_legs l WHERE l.org_id = p_org AND l.person_id = p_person AND l.service_date = p_day)
     AND NOT EXISTS (SELECT 1 FROM mtp_legs l
                      WHERE l.org_id = p_org AND l.person_id = p_person AND l.service_date = p_day
                        AND (l.pickup_place IS NULL OR l.pickup_at IS NULL OR l.dropoff_place IS NULL OR l.dropoff_at IS NULL))
$$;

-- For authorization usage: a documented day, or one this note already backs on an e520 line
CREATE FUNCTION public._mtp_day_counts(p_org uuid, p_person uuid, p_day date, p_note uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public._mtp_day_documented(p_org, p_person, p_day)
      OR ((public.org_id() IS NULL OR public.org_id() = p_org)
          AND EXISTS (SELECT 1 FROM e520_line_notes x WHERE x.note_id = p_note AND x.service_code = 'MTP' AND NOT x.released))
$$;

-- A day whose MTP is on an e520 line (draft or uploaded) is locked
CREATE FUNCTION public._mtp_day_locked(p_org uuid, p_person uuid, p_day date)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM e520_line_notes x JOIN service_notes n ON n.id = x.note_id
                  WHERE x.org_id = p_org AND n.person_id = p_person AND n.service_date = p_day
                    AND x.service_code = 'MTP' AND NOT x.released)
$$;

-- ── 3. Recording trips ──────────────────────────────────────────────────────────────
-- Who may record: active staff of the Person's organization who can see the Person (a front-line login only
-- for Persons assigned to them); never on a day whose MTP is already in an e520 file.
CREATE FUNCTION public._mtp_check(p_person uuid, p_day date, p_actor uuid, p_tier text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM persons WHERE id = p_person;
  IF v_org IS NULL THEN RAISE EXCEPTION 'Person not found'; END IF;
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = v_org AND s.is_active) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  IF p_tier IS NULL OR p_tier NOT IN ('manage', 'operate', 'deliver') THEN RAISE EXCEPTION 'Not permitted'; END IF;
  IF p_tier = 'deliver' AND NOT public.staff_sees_person(p_actor, v_org, p_person) THEN RAISE EXCEPTION 'Not permitted'; END IF;
  IF p_day IS NULL THEN RAISE EXCEPTION 'Give the date of the trip'; END IF;
  -- r1 — the same per-Person lock the e520 build takes for MTP, held to the end of this change
  PERFORM pg_advisory_xact_lock(hashtext('provly-mtp'), hashtext(p_person::text));
  IF public._mtp_day_locked(v_org, p_person, p_day) THEN
    RAISE EXCEPTION 'MTP for % is in an e520 file — release that line before changing its trips', to_char(p_day, 'MM/DD/YYYY');
  END IF;
  RETURN v_org;
END;
$$;

-- A pickup or drop-off time must fall on the trip's date (Mountain time) and not be in the future
CREATE FUNCTION public._mtp_time_ok(p_at timestamptz, p_day date)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_at IS NULL OR ((p_at AT TIME ZONE 'America/Denver')::date = p_day AND p_at <= now() + interval '5 minutes')
$$;

CREATE FUNCTION public._mtp_dsg_recompute()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  r   record;
  v_dsg uuid;
BEGIN
  SELECT id INTO v_dsg FROM service_code_definitions WHERE code = 'DSG' LIMIT 1;
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  PERFORM public.provly_recompute_auth_units(r.org_id, r.person_id, v_dsg, r.service_date);
  IF TG_OP = 'UPDATE' AND (OLD.person_id, OLD.service_date) IS DISTINCT FROM (NEW.person_id, NEW.service_date) THEN
    PERFORM public.provly_recompute_auth_units(OLD.org_id, OLD.person_id, v_dsg, OLD.service_date);
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER mtp_legs_recompute AFTER INSERT OR UPDATE OR DELETE ON public.mtp_legs
  FOR EACH ROW EXECUTE FUNCTION public._mtp_dsg_recompute();

-- Start / End transport: the place the driver picks, the phone's location if it gave one, the server's time
CREATE FUNCTION public._mtp_tap(p_person uuid, p_direction text, p_stage text, p_place text,
                                p_lat numeric, p_lng numeric, p_actor uuid, p_tier text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_day   date := (now() AT TIME ZONE 'America/Denver')::date;
  v_org   uuid;
  v_place text := nullif(btrim(coalesce(p_place, '')), '');
  l       mtp_legs;
  v_old   jsonb;
  v_found boolean;
BEGIN
  v_org := public._mtp_check(p_person, v_day, p_actor, p_tier);
  IF p_direction NOT IN ('to_program', 'from_program') THEN RAISE EXCEPTION 'Choose the trip: to the program, or home'; END IF;
  IF p_stage NOT IN ('pickup', 'dropoff') THEN RAISE EXCEPTION 'Choose pickup or drop-off'; END IF;
  IF v_place IS NULL OR length(v_place) < 2 THEN RAISE EXCEPTION 'Say where — the pickup or drop-off place'; END IF;
  IF (p_lat IS NULL) <> (p_lng IS NULL) OR (p_lat IS NOT NULL AND (abs(p_lat) > 90 OR abs(p_lng) > 180)) THEN
    RAISE EXCEPTION 'The location from the phone is not valid';
  END IF;
  SELECT * INTO l FROM mtp_legs WHERE person_id = p_person AND service_date = v_day AND direction = p_direction FOR UPDATE;
  v_found := FOUND;
  IF v_found THEN v_old := to_jsonb(l); END IF;
  -- r1 — a front-line login finishes only a trip it started
  IF v_found AND p_tier = 'deliver' AND l.driver_staff_id <> p_actor THEN
    RAISE EXCEPTION 'Another driver recorded this trip — ask the office to correct it';
  END IF;
  IF p_stage = 'pickup' THEN
    IF v_found AND l.pickup_at IS NOT NULL THEN RAISE EXCEPTION 'This pickup is already recorded — correct it on the DSG note'; END IF;
    IF v_found AND l.dropoff_at IS NOT NULL AND l.dropoff_at <= now() THEN RAISE EXCEPTION 'The drop-off is already recorded; a pickup can''t come after it'; END IF;
    IF v_found THEN
      UPDATE mtp_legs SET pickup_place = v_place, pickup_at = now(), pickup_lat = p_lat, pickup_lng = p_lng, pickup_source = 'tap', updated_at = now()
       WHERE id = l.id RETURNING * INTO l;
    ELSE
      INSERT INTO mtp_legs (org_id, person_id, service_date, direction, pickup_place, pickup_at, pickup_lat, pickup_lng, pickup_source, driver_staff_id, created_by)
      VALUES (v_org, p_person, v_day, p_direction, v_place, now(), p_lat, p_lng, 'tap', p_actor, p_actor) RETURNING * INTO l;
    END IF;
  ELSE
    IF v_found AND l.dropoff_at IS NOT NULL THEN RAISE EXCEPTION 'This drop-off is already recorded — correct it on the DSG note'; END IF;
    IF v_found AND l.pickup_at IS NOT NULL AND l.pickup_at >= now() THEN RAISE EXCEPTION 'The drop-off must come after the pickup'; END IF;
    IF v_found THEN
      UPDATE mtp_legs SET dropoff_place = v_place, dropoff_at = now(), dropoff_lat = p_lat, dropoff_lng = p_lng, dropoff_source = 'tap', updated_at = now()
       WHERE id = l.id RETURNING * INTO l;
    ELSE
      INSERT INTO mtp_legs (org_id, person_id, service_date, direction, dropoff_place, dropoff_at, dropoff_lat, dropoff_lng, dropoff_source, driver_staff_id, created_by)
      VALUES (v_org, p_person, v_day, p_direction, v_place, now(), p_lat, p_lng, 'tap', p_actor, p_actor) RETURNING * INTO l;
    END IF;
  END IF;
  INSERT INTO mtp_leg_history (org_id, leg_id, person_id, service_date, action, changed_by, old_values, new_values)
  VALUES (v_org, l.id, p_person, v_day, 'tap', p_actor, v_old, to_jsonb(l));
  RETURN l.id;
END;
$$;

-- Typed entry or correction. A NULL argument leaves that field as it is. Changing anything already recorded
-- is a correction and needs a reason; filling a field after the trip's day has ended is a late entry and
-- needs a reason. Front-line logins record only their own trips.
CREATE FUNCTION public._mtp_record(p_person uuid, p_day date, p_direction text,
                                   p_pickup_place text, p_pickup_at timestamptz, p_dropoff_place text, p_dropoff_at timestamptz,
                                   p_driver uuid, p_reason text, p_actor uuid, p_tier text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org     uuid;
  v_pp      text := nullif(btrim(coalesce(p_pickup_place, '')), '');
  v_dp      text := nullif(btrim(coalesce(p_dropoff_place, '')), '');
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_late    boolean;
  v_driver  uuid;
  l         mtp_legs;
  n         mtp_legs;
  v_found   boolean;
  v_correct boolean := false;
  v_fill    boolean := false;
  v_pchg    boolean := false;
  v_dchg    boolean := false;
BEGIN
  v_org := public._mtp_check(p_person, p_day, p_actor, p_tier);
  IF p_direction NOT IN ('to_program', 'from_program') THEN RAISE EXCEPTION 'Choose the trip: to the program, or home'; END IF;
  IF NOT public._mtp_time_ok(p_pickup_at, p_day) OR NOT public._mtp_time_ok(p_dropoff_at, p_day) THEN
    RAISE EXCEPTION 'Pickup and drop-off times must be on % and not in the future', to_char(p_day, 'MM/DD/YYYY');
  END IF;
  IF (v_pp IS NOT NULL AND length(v_pp) < 2) OR (v_dp IS NOT NULL AND length(v_dp) < 2) THEN RAISE EXCEPTION 'Name the place'; END IF;
  v_late := (now() AT TIME ZONE 'America/Denver')::date > p_day;

  SELECT * INTO l FROM mtp_legs WHERE person_id = p_person AND service_date = p_day AND direction = p_direction FOR UPDATE;
  v_found := FOUND;
  v_driver := coalesce(p_driver, CASE WHEN v_found THEN l.driver_staff_id END, p_actor);
  IF NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = v_driver AND s.org_id = v_org) THEN RAISE EXCEPTION 'The driver isn''t on this organization''s staff'; END IF;
  IF p_tier = 'deliver' AND v_driver <> p_actor THEN RAISE EXCEPTION 'You can record only trips you drove'; END IF;
  -- r1 — and it can change only a trip it drove: the existing trip's driver, not the one asked for
  IF p_tier = 'deliver' AND v_found AND l.driver_staff_id <> p_actor THEN
    RAISE EXCEPTION 'Another driver recorded this trip — ask the office to correct it';
  END IF;

  IF NOT v_found THEN
    IF v_pp IS NULL AND p_pickup_at IS NULL AND v_dp IS NULL AND p_dropoff_at IS NULL THEN RAISE EXCEPTION 'Enter the pickup or the drop-off'; END IF;
    v_fill := true;
  ELSE
    v_correct := (v_pp IS NOT NULL AND l.pickup_place IS NOT NULL AND v_pp IS DISTINCT FROM l.pickup_place)
              OR (p_pickup_at IS NOT NULL AND l.pickup_at IS NOT NULL AND p_pickup_at IS DISTINCT FROM l.pickup_at)
              OR (v_dp IS NOT NULL AND l.dropoff_place IS NOT NULL AND v_dp IS DISTINCT FROM l.dropoff_place)
              OR (p_dropoff_at IS NOT NULL AND l.dropoff_at IS NOT NULL AND p_dropoff_at IS DISTINCT FROM l.dropoff_at)
              OR (p_driver IS NOT NULL AND p_driver IS DISTINCT FROM l.driver_staff_id);
    v_fill := (v_pp IS NOT NULL AND l.pickup_place IS NULL) OR (p_pickup_at IS NOT NULL AND l.pickup_at IS NULL)
           OR (v_dp IS NOT NULL AND l.dropoff_place IS NULL) OR (p_dropoff_at IS NOT NULL AND l.dropoff_at IS NULL);
    IF NOT v_correct AND NOT v_fill THEN RETURN l.id; END IF;               -- nothing changed
    -- r1 — which parts actually change (an unchanged part keeps its source and GPS)
    v_pchg := (v_pp IS NOT NULL AND v_pp IS DISTINCT FROM l.pickup_place) OR (p_pickup_at IS NOT NULL AND p_pickup_at IS DISTINCT FROM l.pickup_at);
    v_dchg := (v_dp IS NOT NULL AND v_dp IS DISTINCT FROM l.dropoff_place) OR (p_dropoff_at IS NOT NULL AND p_dropoff_at IS DISTINCT FROM l.dropoff_at);
  END IF;
  IF v_correct AND (v_reason IS NULL OR length(v_reason) < 3) THEN RAISE EXCEPTION 'Give a reason for the correction'; END IF;
  IF v_fill AND v_late AND (v_reason IS NULL OR length(v_reason) < 3) THEN
    RAISE EXCEPTION 'This is a late entry (after %) — give a reason, such as where the times came from', to_char(p_day, 'MM/DD/YYYY');
  END IF;
  IF coalesce(p_dropoff_at, l.dropoff_at) IS NOT NULL AND coalesce(p_pickup_at, l.pickup_at) IS NOT NULL
     AND coalesce(p_dropoff_at, l.dropoff_at) <= coalesce(p_pickup_at, l.pickup_at) THEN
    RAISE EXCEPTION 'The drop-off must come after the pickup';
  END IF;

  IF NOT v_found THEN
    INSERT INTO mtp_legs (org_id, person_id, service_date, direction, pickup_place, pickup_at, pickup_source, dropoff_place, dropoff_at, dropoff_source,
                          driver_staff_id, late_entry, late_reason, created_by)
    VALUES (v_org, p_person, p_day, p_direction, v_pp, p_pickup_at, CASE WHEN v_pp IS NOT NULL OR p_pickup_at IS NOT NULL THEN 'typed' END,
            v_dp, p_dropoff_at, CASE WHEN v_dp IS NOT NULL OR p_dropoff_at IS NOT NULL THEN 'typed' END,
            v_driver, v_late, CASE WHEN v_late THEN v_reason END, p_actor)
    RETURNING * INTO n;
  ELSE
    UPDATE mtp_legs SET
      pickup_place  = coalesce(v_pp, pickup_place),
      pickup_at     = coalesce(p_pickup_at, pickup_at),
      pickup_lat    = CASE WHEN v_pchg THEN NULL ELSE pickup_lat END,
      pickup_lng    = CASE WHEN v_pchg THEN NULL ELSE pickup_lng END,
      pickup_source = CASE WHEN v_pchg THEN 'typed' ELSE pickup_source END,
      dropoff_place = coalesce(v_dp, dropoff_place),
      dropoff_at    = coalesce(p_dropoff_at, dropoff_at),
      dropoff_lat   = CASE WHEN v_dchg THEN NULL ELSE dropoff_lat END,
      dropoff_lng   = CASE WHEN v_dchg THEN NULL ELSE dropoff_lng END,
      dropoff_source = CASE WHEN v_dchg THEN 'typed' ELSE dropoff_source END,
      driver_staff_id = v_driver,
      late_entry    = late_entry OR (v_fill AND v_late),
      late_reason   = CASE WHEN v_fill AND v_late THEN v_reason ELSE late_reason END,
      updated_at    = now()
     WHERE id = l.id RETURNING * INTO n;
  END IF;
  INSERT INTO mtp_leg_history (org_id, leg_id, person_id, service_date, action, changed_by, old_values, new_values, reason)
  VALUES (v_org, n.id, p_person, p_day, CASE WHEN v_correct THEN 'correct' ELSE 'record' END, p_actor,
          CASE WHEN v_found THEN to_jsonb(l) END, to_jsonb(n), v_reason);
  RETURN n.id;
END;
$$;

CREATE FUNCTION public._mtp_delete(p_leg uuid, p_reason text, p_actor uuid, p_tier text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  l     mtp_legs;
  v_org uuid;
BEGIN
  -- r2 — lock order on every write path: the Person lock first (in _mtp_check), then the trip row
  SELECT * INTO l FROM mtp_legs WHERE id = p_leg;
  IF NOT FOUND THEN RAISE EXCEPTION 'Trip not found'; END IF;
  v_org := public._mtp_check(l.person_id, l.service_date, p_actor, p_tier);
  SELECT * INTO l FROM mtp_legs WHERE id = p_leg FOR UPDATE;        -- re-read under the lock
  IF NOT FOUND THEN RAISE EXCEPTION 'Trip not found — it was removed a moment ago'; END IF;
  IF p_tier = 'deliver' AND l.driver_staff_id <> p_actor THEN RAISE EXCEPTION 'You can remove only trips you drove'; END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'Give a reason for removing the trip'; END IF;
  INSERT INTO mtp_leg_history (org_id, leg_id, person_id, service_date, action, changed_by, old_values, reason)
  VALUES (v_org, l.id, l.person_id, l.service_date, 'delete', p_actor, to_jsonb(l), btrim(p_reason));
  DELETE FROM mtp_legs WHERE id = l.id;
END;
$$;

-- ── 4. Public functions (the caller must be able to see the Person) ─────────────────
CREATE FUNCTION public.mtp_tap(p_person uuid, p_direction text, p_stage text, p_place text, p_lat numeric, p_lng numeric)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.can_see_person(p_person) THEN RAISE EXCEPTION 'Not permitted'; END IF;
  RETURN public._mtp_tap(p_person, p_direction, p_stage, p_place, p_lat, p_lng, public.my_staff_id(), public.access_tier()::text);
END;
$$;

CREATE FUNCTION public.mtp_record(p_person uuid, p_day date, p_direction text, p_pickup_place text, p_pickup_at timestamptz,
                                  p_dropoff_place text, p_dropoff_at timestamptz, p_driver uuid, p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.can_see_person(p_person) THEN RAISE EXCEPTION 'Not permitted'; END IF;
  RETURN public._mtp_record(p_person, p_day, p_direction, p_pickup_place, p_pickup_at, p_dropoff_place, p_dropoff_at,
                            p_driver, p_reason, public.my_staff_id(), public.access_tier()::text);
END;
$$;

CREATE FUNCTION public.mtp_delete(p_leg uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_person uuid;
BEGIN
  SELECT person_id INTO v_person FROM mtp_legs WHERE id = p_leg;
  IF v_person IS NULL OR NOT public.can_see_person(v_person) THEN RAISE EXCEPTION 'Not permitted'; END IF;
  PERFORM public._mtp_delete(p_leg, p_reason, public.my_staff_id(), public.access_tier()::text);
END;
$$;

-- DSG days that won't bill MTP because their trip record is missing or incomplete (for review screens)
CREATE FUNCTION public.mtp_undocumented_days(p_person uuid, p_from date, p_to date)
RETURNS TABLE (service_date date, legs integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org uuid;
BEGIN
  IF NOT public.can_see_person(p_person) THEN RAISE EXCEPTION 'Not permitted'; END IF;
  SELECT org_id INTO v_org FROM persons WHERE id = p_person;
  RETURN QUERY
    SELECT DISTINCT n.service_date,
           (SELECT count(*)::integer FROM mtp_legs l WHERE l.person_id = p_person AND l.service_date = n.service_date)
      FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
     WHERE n.org_id = v_org AND n.person_id = p_person AND c.code = 'DSG'
       AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN p_from AND p_to
       AND NOT public._mtp_day_documented(v_org, p_person, n.service_date)
       AND NOT EXISTS (SELECT 1 FROM e520_line_notes x WHERE x.note_id = n.id AND x.service_code = 'MTP' AND NOT x.released)
     ORDER BY 1;
END;
$$;

-- ── 5. Billing reads the trip record ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.e520_day_units(
  p_org uuid, p_person uuid, p_code text, p_code_id uuid, p_unit text, p_evv boolean, p_day date)
RETURNS TABLE (o_units integer, o_note_units integer, o_evv_units integer, o_notes jsonb, o_null_min boolean)
LANGUAGE plpgsql
VOLATILE   -- v20.0.44 r1: takes the MTP lock, then reads (a STABLE function would read the caller's older snapshot)
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
    -- one MTP day per approved DSG note day whose MTP trip record is complete (v20.0.44; was D6's transport field)
    -- r1 — the per-Person lock trip changes take: no trip can change between this read and the build reserving
    -- the day (the lock is held until the build's transaction ends)
    PERFORM pg_advisory_xact_lock(hashtext('provly-mtp'), hashtext(p_person::text));
    SELECT array_agg(n.id ORDER BY n.start_time NULLS LAST, n.id) INTO v_ids
      FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
     WHERE n.org_id = p_org AND n.person_id = p_person AND c.code = 'DSG'
       AND n.service_date = p_day AND n.status IN ('approved', 'billed')   -- r1: billed for DSG can still back a released MTP day
       AND public._mtp_day_documented(p_org, p_person, p_day)              -- v20.0.44: Article 13.3(3) trip record, every element
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
       AND n.status IN ('approved', 'billed') AND n.service_date BETWEEN v_lo AND v_hi
       -- v20.0.44: a day counts once its trip record is complete, or if it was already billed for MTP
       AND public._mtp_day_counts(p_org, p_person, n.service_date, n.id);
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

-- Authorization usage counts change with the rule: recompute every MTP authorization once, now
CREATE TEMP TABLE v20044_mtp_before ON COMMIT DROP AS
  SELECT a.id, a.used_units FROM person_service_authorizations a
    JOIN service_code_definitions c ON c.id = a.service_code_id WHERE c.code = 'MTP';
UPDATE person_service_authorizations a
   SET used_units = CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id, a.unit_kind) END
  FROM service_code_definitions c
 WHERE c.id = a.service_code_id AND c.code = 'MTP'
   AND a.used_units IS DISTINCT FROM CASE WHEN a.status::text = 'rejected' THEN 0
                         ELSE public.provly_auth_used_units(a.org_id, a.person_id, a.service_code_id, a.start_date, a.end_date, a.id, a.unit_kind) END;
CREATE TEMP TABLE v20044_mtp_changed ON COMMIT PRESERVE ROWS AS
  SELECT b.id, b.used_units AS before_units, a.used_units AS after_units
    FROM v20044_mtp_before b JOIN person_service_authorizations a ON a.id = b.id
   WHERE a.used_units IS DISTINCT FROM b.used_units;

-- ── 6. Access and grants ────────────────────────────────────────────────────────────
DO $rls$
BEGIN
  ALTER TABLE public.mtp_legs ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.mtp_leg_history ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON public.mtp_legs, public.mtp_leg_history FROM PUBLIC, anon, authenticated;
  GRANT SELECT ON public.mtp_legs, public.mtp_leg_history TO authenticated;
  CREATE POLICY mtp_legs_read ON public.mtp_legs FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id()) AND public.can_see_person(person_id));
  CREATE POLICY mtp_leg_history_read ON public.mtp_leg_history FOR SELECT TO authenticated
    USING (org_id = (SELECT public.org_id()) AND public.can_see_person(person_id));
END
$rls$;

DO $fn$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('trg_mtp_leg_history_append_only', '_mtp_day_documented', '_mtp_day_counts', '_mtp_day_locked', '_mtp_check',
                         '_mtp_time_ok', '_mtp_dsg_recompute', '_mtp_tap', '_mtp_record', '_mtp_delete',
                         'mtp_tap', 'mtp_record', 'mtp_delete', 'mtp_undocumented_days')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    -- the two billing checks run inside triggers a signed-in save fires (they're org-guarded and reveal nothing)
    IF f.proname IN ('mtp_tap', 'mtp_record', 'mtp_delete', 'mtp_undocumented_days', '_mtp_day_documented', '_mtp_day_counts') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
  END LOOP;
END
$fn$;

NOTIFY pgrst, 'reload schema';

-- ── 7. Self-test — a synthetic Person, rolled back ──────────────────────────────────
CREATE OR REPLACE FUNCTION pg_temp.v20044_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.44 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $test$
DECLARE
  v_org     uuid;
  v_owner   uuid;
  v_person  uuid;
  v_dsg     uuid;
  v_mtp     uuid;
  v_auth    uuid;
  v_day     date := date '2001-01-15';
  v_leg     uuid;
  v_leg2    uuid;
  v_today   date := (now() AT TIME ZONE 'America/Denver')::date;
  v_n       integer;
  v_ok      boolean;
  v_other   uuid;
  v_leg3    uuid;
  r         record;
  t0        timestamptz := (TIMESTAMP '2001-01-15 08:10' AT TIME ZONE 'America/Denver');
BEGIN
  SELECT m.org_id, s.id INTO v_org, v_owner
    FROM org_members m JOIN staff s ON s.user_id = m.user_id AND s.org_id = m.org_id AND s.is_active
   WHERE m.role::text = 'owner' ORDER BY s.id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'SELFTEST FAIL 0: no active owner to test with'; END IF;
  SELECT id INTO v_dsg FROM service_code_definitions WHERE code = 'DSG' LIMIT 1;
  SELECT id INTO v_mtp FROM service_code_definitions WHERE code = 'MTP' LIMIT 1;

  BEGIN
    v_person := pg_temp.v20044_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20044', 'last_name', 'Selftest',
                                                                            'identification_number', '099999944', 'is_active', true));
    PERFORM pg_temp.v20044_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', v_owner,
      'service_code_id', v_dsg, 'service_date', v_day, 'start_time', '09:00', 'end_time', '15:00', 'duration_minutes', 360,
      'billable_units', 1, 'summary_note', 'v20.0.44 self-test', 'status', 'approved'));
    IF v_mtp IS NOT NULL THEN
      v_auth := pg_temp.v20044_test_insert('person_service_authorizations', jsonb_build_object('org_id', v_org, 'person_id', v_person,
        'service_code_id', v_mtp, 'authorized_units', 20, 'used_units', 0, 'start_date', '2001-01-01', 'end_date', '2001-01-31', 'rate_per_unit', 20.8));
    END IF;

    -- 1. an approved DSG day with no trip record bills no MTP (the old "to and from" field no longer counts)
    SELECT o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'MTP', v_mtp, 'D', false, v_day);
    IF v_n <> 0 THEN RAISE EXCEPTION 'SELFTEST FAIL 1: MTP billed with no trip record'; END IF;

    -- 2. a typed leg after the day is a late entry: refused without a reason
    BEGIN
      PERFORM public._mtp_record(v_person, v_day, 'to_program', 'Home', t0, 'Day program', t0 + interval '25 minutes', NULL, NULL, v_owner, 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 2: a late entry was saved without a reason';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 3. with a reason it's saved, marked late, and the day bills one MTP unit
    v_leg := public._mtp_record(v_person, v_day, 'to_program', 'Home', t0, 'Day program', t0 + interval '25 minutes', NULL,
                                'from the DSG sign-in sheet', v_owner, 'manage');
    IF NOT EXISTS (SELECT 1 FROM mtp_legs WHERE id = v_leg AND late_entry AND pickup_source = 'typed' AND driver_staff_id = v_owner) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3: the late entry was not recorded as late';
    END IF;
    SELECT o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'MTP', v_mtp, 'D', false, v_day);
    IF v_n <> 1 THEN RAISE EXCEPTION 'SELFTEST FAIL 3b: a complete trip record did not bill MTP (%)', v_n; END IF;

    -- 4. an incomplete leg on the day stops the bill until it's complete
    v_leg2 := public._mtp_record(v_person, v_day, 'from_program', 'Day program', t0 + interval '7 hours', NULL, NULL, NULL,
                                 'from the DSG sign-in sheet', v_owner, 'manage');
    SELECT o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'MTP', v_mtp, 'D', false, v_day);
    IF v_n <> 0 THEN RAISE EXCEPTION 'SELFTEST FAIL 4: a day with an incomplete leg billed MTP'; END IF;
    PERFORM public._mtp_record(v_person, v_day, 'from_program', NULL, NULL, 'Home', t0 + interval '7 hours 30 minutes', NULL,
                               'from the DSG sign-in sheet', v_owner, 'manage');
    SELECT o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'MTP', v_mtp, 'D', false, v_day);
    IF v_n <> 1 THEN RAISE EXCEPTION 'SELFTEST FAIL 4b: completing the leg did not restore the MTP day'; END IF;

    -- 5. impossible times are refused: drop-off before pickup, a time on another day, a time in the future
    BEGIN
      PERFORM public._mtp_record(v_person, v_day, 'to_program', NULL, NULL, NULL, t0 - interval '5 minutes', NULL, 'self-test', v_owner, 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 5: a drop-off before the pickup was saved';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public._mtp_record(v_person, v_day, 'to_program', NULL, t0 + interval '1 day', NULL, NULL, NULL, 'self-test', v_owner, 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 5b: a time on another day was saved';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public._mtp_record(v_person, v_today, 'to_program', 'Home', now() + interval '2 hours', NULL, NULL, NULL, 'self-test', v_owner, 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 5c: a future time was saved';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 6. changing a recorded time is a correction: refused without a reason, kept in the history with one
    BEGIN
      PERFORM public._mtp_record(v_person, v_day, 'to_program', NULL, t0 + interval '5 minutes', NULL, NULL, NULL, NULL, v_owner, 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 6: a correction was saved without a reason';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    PERFORM public._mtp_record(v_person, v_day, 'to_program', NULL, t0 + interval '5 minutes', NULL, NULL, NULL, 'driver''s log said 8:15', v_owner, 'manage');
    IF NOT EXISTS (SELECT 1 FROM mtp_leg_history WHERE leg_id = v_leg AND action = 'correct' AND reason = 'driver''s log said 8:15') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6b: the correction is not in the history';
    END IF;
    BEGIN
      UPDATE mtp_leg_history SET reason = 'changed' WHERE leg_id = v_leg;
      RAISE EXCEPTION 'SELFTEST FAIL 6c: the history was changed';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 7. authorization usage follows the trip record (the leg trigger recomputes it)
    IF v_auth IS NOT NULL THEN
      SELECT used_units INTO v_n FROM person_service_authorizations WHERE id = v_auth;
      IF v_n <> 1 THEN RAISE EXCEPTION 'SELFTEST FAIL 7: MTP authorization usage is % (expected 1)', v_n; END IF;
    END IF;

    -- 8. taps: pickup then drop-off today make a complete leg, driver = the person tapping, sources = tap
    v_leg := public._mtp_tap(v_person, 'to_program', 'pickup', 'Home', 40.6, -111.9, v_owner, 'manage');
    BEGIN
      PERFORM public._mtp_tap(v_person, 'to_program', 'pickup', 'Home', NULL, NULL, v_owner, 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 8: a second pickup tap replaced the first';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    UPDATE mtp_legs SET pickup_at = now() - interval '20 minutes' WHERE id = v_leg;     -- as if the drive took 20 minutes
    PERFORM public._mtp_tap(v_person, 'to_program', 'dropoff', 'Day program', NULL, NULL, v_owner, 'manage');
    IF NOT EXISTS (SELECT 1 FROM mtp_legs WHERE id = v_leg AND pickup_source = 'tap' AND dropoff_source = 'tap'
                   AND driver_staff_id = v_owner AND NOT late_entry AND dropoff_at > pickup_at) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 8b: the taps did not make a complete leg';
    END IF;

    -- 8c. a typed drop-off fix on a tapped trip leaves the pickup's tap and GPS alone
    PERFORM public._mtp_record(v_person, v_today, 'to_program', NULL, NULL, 'Day program — west door', NULL, NULL, 'wrong door picked', v_owner, 'manage');
    IF NOT EXISTS (SELECT 1 FROM mtp_legs WHERE id = v_leg AND pickup_source = 'tap' AND pickup_lat = 40.6
                   AND dropoff_source = 'typed' AND dropoff_place = 'Day program — west door') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 8c: fixing the drop-off changed the untouched pickup';
    END IF;

    -- 8d. a front-line driver can't take over another driver's trip, by tap or by typed entry
    SELECT s.id INTO v_other FROM staff s WHERE s.org_id = v_org AND s.is_active AND s.id <> v_owner ORDER BY s.id LIMIT 1;
    IF v_other IS NOT NULL THEN
      INSERT INTO staff_assignments (org_id, person_id, staff_id) VALUES (v_org, v_person, v_other);
      v_leg3 := public._mtp_tap(v_person, 'from_program', 'pickup', 'Day program', NULL, NULL, v_owner, 'manage');
      BEGIN
        PERFORM public._mtp_tap(v_person, 'from_program', 'dropoff', 'Home', NULL, NULL, v_other, 'deliver');
        RAISE EXCEPTION 'SELFTEST FAIL 8d: a front-line driver finished another driver''s trip';
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
      END;
      BEGIN
        PERFORM public._mtp_record(v_person, v_today, 'from_program', 'Somewhere else', NULL, NULL, NULL, v_other, 'mine now', v_other, 'deliver');
        RAISE EXCEPTION 'SELFTEST FAIL 8e: a front-line driver took over another driver''s trip';
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
      END;
      IF NOT EXISTS (SELECT 1 FROM mtp_legs WHERE id = v_leg3 AND driver_staff_id = v_owner AND pickup_place = 'Day program' AND dropoff_at IS NULL) THEN
        RAISE EXCEPTION 'SELFTEST FAIL 8f: another driver''s trip was changed';
      END IF;
    END IF;

    -- 9. a front-line login can't record for a Person who isn't assigned to them; nobody outside the staff can
    BEGIN
      PERFORM public._mtp_record(v_person, v_day, 'to_program', 'Home', NULL, NULL, NULL, NULL, 'self-test', v_owner, 'deliver');
      RAISE EXCEPTION 'SELFTEST FAIL 9: a front-line login recorded for an unassigned Person';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public._mtp_tap(v_person, 'from_program', 'pickup', 'Day program', NULL, NULL, gen_random_uuid(), 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 9b: someone outside the staff recorded a trip';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 10. removing a leg needs a reason, is kept in the history, and the day stops billing if nothing complete is left
    BEGIN
      PERFORM public._mtp_delete(v_leg2, '', v_owner, 'manage');
      RAISE EXCEPTION 'SELFTEST FAIL 10: a trip was removed without a reason';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    PERFORM public._mtp_delete(v_leg2, 'entered on the wrong day', v_owner, 'manage');
    PERFORM public._mtp_delete((SELECT id FROM mtp_legs WHERE person_id = v_person AND service_date = v_day AND direction = 'to_program'),
                               'entered on the wrong day', v_owner, 'manage');
    SELECT o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'MTP', v_mtp, 'D', false, v_day);
    IF v_n <> 0 OR (SELECT count(*) FROM mtp_leg_history WHERE person_id = v_person AND action = 'delete') <> 2 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 10b: removal did not stop the MTP day or was not kept in the history';
    END IF;

    -- 11. other codes are untouched: a DSG day still bills DSG
    SELECT o_units INTO v_n FROM public.e520_day_units(v_org, v_person, 'DSG', v_dsg, 'D', false, v_day);
    IF v_n <> 1 THEN RAISE EXCEPTION 'SELFTEST FAIL 11: the DSG day itself stopped billing (%)', v_n; END IF;

    RAISE EXCEPTION 'SELFTEST_ROLLBACK' USING ERRCODE = 'PRVOK';
  EXCEPTION WHEN SQLSTATE 'PRVOK' THEN
    NULL;  -- every self-test write above is rolled back here
  END;
END
$test$;

SELECT set_config('request.jwt.claims', '{}', true);

COMMIT;

-- ── Verification table (paste this result into the PR and the chat) ─────────────────
SELECT n, check_name, got, want,
       CASE WHEN want = '(information)' THEN 'ℹ️' WHEN got = want THEN '✅' ELSE '❌' END AS ok FROM (
  SELECT 1 n, 'Trip tables with RLS' check_name,
    (SELECT count(*) FROM pg_class WHERE relname IN ('mtp_legs', 'mtp_leg_history') AND relrowsecurity)::text got, '2' want
  UNION ALL SELECT 2, 'Clients cannot write trip tables directly',
    (has_table_privilege('authenticated', 'public.mtp_legs', 'INSERT') OR has_table_privilege('authenticated', 'public.mtp_legs', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.mtp_legs', 'DELETE') OR has_table_privilege('authenticated', 'public.mtp_leg_history', 'INSERT'))::text, 'false'
  UNION ALL SELECT 3, 'Trip history is append-only',
    (SELECT count(*) FROM pg_trigger WHERE tgname = 'mtp_leg_history_append_only' AND NOT tgisinternal)::text, '1'
  UNION ALL SELECT 4, 'e520 MTP days read the trip record (not the transport field)',
    (position('_mtp_day_documented' IN pg_get_functiondef('public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date)'::regprocedure)) > 0
     AND position('n.transport' IN pg_get_functiondef('public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date)'::regprocedure)) = 0)::text, 'true'
  UNION ALL SELECT 5, 'Authorization usage reads the trip record',
    (position('_mtp_day_counts' IN pg_get_functiondef('public.provly_auth_used_units(uuid, uuid, uuid, date, date, uuid, text)'::regprocedure)) > 0)::text, 'true'
  UNION ALL SELECT 6, 'Public trip functions for signed-in users (not anon)',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('mtp_tap', 'mtp_record', 'mtp_delete', 'mtp_undocumented_days')
       AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE'))::text, '4'
  UNION ALL SELECT 7, 'Internal trip functions callable by clients',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('_mtp_day_locked', '_mtp_check', '_mtp_tap', '_mtp_record', '_mtp_delete', '_mtp_dsg_recompute')
       AND (has_function_privilege('authenticated', oid, 'EXECUTE') OR has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  UNION ALL SELECT 8, 'Self-test leftovers (synthetic Person)',
    (SELECT count(*) FROM persons WHERE identification_number = '099999944')::text, '0'
  UNION ALL SELECT 9, 'MTP authorizations whose used units changed under the new rule',
    (SELECT count(*) FROM v20044_mtp_changed)::text || coalesce(' (' || (SELECT string_agg(before_units || '→' || after_units, ', ') FROM v20044_mtp_changed) || ')', ''),
    '(information)'
  UNION ALL SELECT 11, 'Trip changes and the e520 MTP check share a lock',
    ((position('pg_advisory_xact_lock' IN pg_get_functiondef('public._mtp_check(uuid, date, uuid, text)'::regprocedure)) > 0)
     AND (position('pg_advisory_xact_lock' IN pg_get_functiondef('public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date)'::regprocedure)) > 0)
     AND (SELECT provolatile = 'v' FROM pg_proc WHERE oid = 'public.e520_day_units(uuid, uuid, text, uuid, text, boolean, date)'::regprocedure))::text, 'true'
  UNION ALL SELECT 12, 'Removing a trip takes the Person lock before the trip row (same order as saves and taps)',
    (position('_mtp_check' IN pg_get_functiondef('public._mtp_delete(uuid, text, uuid, text)'::regprocedure))
       < position('FOR UPDATE' IN pg_get_functiondef('public._mtp_delete(uuid, text, uuid, text)'::regprocedure)))::text, 'true'
  UNION ALL SELECT 10, 'Approved DSG days with no complete trip record (won''t bill MTP until documented)',
    (SELECT count(DISTINCT (n.person_id, n.service_date))::text FROM service_notes n JOIN service_code_definitions c ON c.id = n.service_code_id
      WHERE c.code = 'DSG' AND n.status = 'approved'
        AND NOT (EXISTS (SELECT 1 FROM mtp_legs l WHERE l.person_id = n.person_id AND l.service_date = n.service_date)
                 AND NOT EXISTS (SELECT 1 FROM mtp_legs l WHERE l.person_id = n.person_id AND l.service_date = n.service_date
                                   AND (l.pickup_place IS NULL OR l.pickup_at IS NULL OR l.dropoff_place IS NULL OR l.dropoff_at IS NULL)))),
    '(information)'
) t
ORDER BY n;
