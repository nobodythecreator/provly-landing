-- ============================================================================
-- Provly v20.0.16 — EVV corrections as one database transaction
-- Run in the Supabase SQL editor (production) BEFORE the app ships. Idempotent.
-- r1: run AFTER sql/v20.0.13.sql (which carries the older EVV guard); the
-- edit-log write policies are now removed by kind, not by name.
-- r2 (Greptile r1): office tiers are held to the same line on OPEN sessions —
-- the only direct change is a live clock-out (clock_out_at / lat / lng); the
-- EVV data elements (who, whom, what, where, when) change only through the RPC;
-- and the RPC no longer reopens a completed visit (clearing a clock-out was the
-- door to an unlogged edit in between).
-- r3 (Greptile r2): clearing exceptions stores the column's empty value, '[]'
-- (the column is NOT NULL) — a cleared note no longer rolls the correction back.
--
-- Small debt filed Sep 16 (Greptile on the Item 4 docs): a supervisor's EVV
-- correction required a reason and an evv_edit_log entry, but only the APP
-- enforced it — two separate requests (log first, then the session update),
-- so a direct API call from an office-tier session could change a clock time
-- with no reason and no log. This makes both a database guarantee:
--
--   correct_evv_session(p_session_id, p_patch, p_reason)
--     • SECURITY DEFINER, office tiers only (manage / operate), own org only
--     • p_patch may carry clock_in_at, clock_out_at (null = clear), exceptions
--     • reason required; clock-in never empty; clock-in before clock-out
--     • writes one evv_edit_log row per changed field AND the session update in
--       the same transaction — both land or neither does
--
--   evv_deliver_guard (trigger) — office tiers may no longer change clock_in_at,
--     nor any evidence column of a COMPLETED session, except inside
--     correct_evv_session. Live clock-in / clock-out are unchanged for everyone.
--
--   evv_edit_log — no app write policies at all: the log is written only by the
--     RPC, so it can neither be skipped nor forged.
--
-- Service-role / SQL-editor writes (no auth.uid()) still pass untouched.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The RPC
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.correct_evv_session(p_session_id uuid, p_patch jsonb, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier     text := public.access_tier();
  v_staff_id uuid := public.my_staff_id();
  v_name     text;
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_old      public.evv_sessions%ROWTYPE;
  v_in       timestamptz;
  v_out      timestamptz;
  v_exc      jsonb;
  v_in_chg   boolean := false;
  v_out_chg  boolean := false;
  v_exc_chg  boolean := false;
  v_key      text;
BEGIN
  IF auth.uid() IS NULL OR public.member_role() IS NULL THEN
    RAISE EXCEPTION 'Not signed in to an organization';
  END IF;
  IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
    RAISE EXCEPTION 'EVV corrections are made by a supervisor or manager';
  END IF;
  IF v_reason = '' THEN
    RAISE EXCEPTION 'A reason is required for any manual EVV correction';
  END IF;
  IF length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'Keep the correction reason under 1000 characters';
  END IF;
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'Nothing to correct';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
    IF v_key NOT IN ('clock_in_at', 'clock_out_at', 'exceptions') THEN
      RAISE EXCEPTION 'Field % cannot be corrected here', v_key;
    END IF;
  END LOOP;

  SELECT * INTO v_old FROM public.evv_sessions
  WHERE id = p_session_id AND org_id = public.org_id()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'EVV session not found';
  END IF;
  IF NOT public.can_see_person(v_old.person_id) THEN
    RAISE EXCEPTION 'EVV session not found';
  END IF;

  v_in  := v_old.clock_in_at;
  v_out := v_old.clock_out_at;
  v_exc := v_old.exceptions;
  IF p_patch ? 'clock_in_at' THEN
    v_in := NULLIF(p_patch->>'clock_in_at', '')::timestamptz;
    v_in_chg := v_in IS DISTINCT FROM v_old.clock_in_at;
  END IF;
  IF p_patch ? 'clock_out_at' THEN
    v_out := NULLIF(p_patch->>'clock_out_at', '')::timestamptz;
    v_out_chg := v_out IS DISTINCT FROM v_old.clock_out_at;
  END IF;
  IF p_patch ? 'exceptions' THEN
    -- r3 — evv_sessions.exceptions is NOT NULL DEFAULT '[]': "cleared" means the empty list
    v_exc := CASE WHEN jsonb_typeof(p_patch->'exceptions') = 'null' THEN '[]'::jsonb ELSE p_patch->'exceptions' END;
    v_exc_chg := v_exc IS DISTINCT FROM v_old.exceptions;
  END IF;

  IF NOT (v_in_chg OR v_out_chg OR v_exc_chg) THEN
    RAISE EXCEPTION 'No changes to save';
  END IF;
  IF v_in IS NULL THEN
    RAISE EXCEPTION 'Clock-in time is required — a visit cannot exist without one';
  END IF;
  -- r2 — a completed visit is never reopened: correct its clock-out instead.
  -- (Clearing it made the row "open", where a live clock-out is allowed — an
  -- unlogged edit between two logged ones.)
  IF v_old.clock_out_at IS NOT NULL AND v_out IS NULL THEN
    RAISE EXCEPTION 'A completed visit cannot be reopened — correct its clock-out time instead';
  END IF;
  IF v_out IS NOT NULL AND v_in >= v_out THEN
    RAISE EXCEPTION 'Clock-in must be earlier than clock-out';
  END IF;

  SELECT nullif(btrim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '')
    INTO v_name FROM public.staff WHERE id = v_staff_id;

  -- the log, in the same transaction as the correction
  IF v_in_chg THEN
    INSERT INTO public.evv_edit_log (org_id, session_id, field, old_value, new_value, reason,
                                     edited_by_user_id, edited_by_staff_id, edited_by_name, edited_at)
    VALUES (v_old.org_id, v_old.id, 'clock_in_at',
            to_char(v_old.clock_in_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            to_char(v_in AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            v_reason, auth.uid(), v_staff_id, v_name, now());
  END IF;
  IF v_out_chg THEN
    INSERT INTO public.evv_edit_log (org_id, session_id, field, old_value, new_value, reason,
                                     edited_by_user_id, edited_by_staff_id, edited_by_name, edited_at)
    VALUES (v_old.org_id, v_old.id, 'clock_out_at',
            to_char(v_old.clock_out_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            to_char(v_out AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            v_reason, auth.uid(), v_staff_id, v_name, now());
  END IF;
  IF v_exc_chg THEN
    INSERT INTO public.evv_edit_log (org_id, session_id, field, old_value, new_value, reason,
                                     edited_by_user_id, edited_by_staff_id, edited_by_name, edited_at)
    VALUES (v_old.org_id, v_old.id, 'exceptions',
            CASE WHEN jsonb_typeof(v_old.exceptions) = 'string' THEN v_old.exceptions #>> '{}' ELSE v_old.exceptions::text END,
            CASE WHEN jsonb_typeof(v_exc) = 'string' THEN v_exc #>> '{}' ELSE v_exc::text END,
            v_reason, auth.uid(), v_staff_id, v_name, now());
  END IF;

  -- the correction; the guard admits it only while this flag is set
  PERFORM set_config('provly.evv_correction', 'on', true);
  UPDATE public.evv_sessions
     SET clock_in_at = v_in, clock_out_at = v_out, exceptions = v_exc
   WHERE id = v_old.id;
  PERFORM set_config('provly.evv_correction', 'off', true);
END;
$$;
REVOKE ALL ON FUNCTION public.correct_evv_session(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_evv_session(uuid, jsonb, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.correct_evv_session(uuid, jsonb, text) IS
  'v20.0.16 — the only office-tier path to correct an EVV session: reason required, one evv_edit_log row per changed field, log + correction in one transaction.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The guard — office tiers correct only through the RPC
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_evv_deliver_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier text := public.access_tier();
  -- original_* are derive-only (trg_evv_sessions_preserve_originals rewrites them
  -- after this trigger); excluded so the check does not depend on trigger order.
  v_derived  text[] := ARRAY['original_clock_in_at', 'original_clock_out_at'];
  v_clockout text[] := ARRAY['clock_out_at', 'clock_out_lat', 'clock_out_lng', 'original_clock_in_at', 'original_clock_out_at'];
  -- r2 — the EVV record: who (staff_id), whom (person_id), what (service_code_id),
  -- where (coordinates, geofence), when (clock times), and the exceptions note.
  v_evidence text[] := ARRAY['clock_in_at', 'clock_out_at', 'clock_in_lat', 'clock_in_lng', 'clock_out_lat', 'clock_out_lng',
                             'geofence_valid', 'exceptions', 'person_id', 'staff_id', 'service_code_id', 'org_id'];
  -- on an OPEN session the only direct change is the live clock-out itself
  v_open_locked text[] := ARRAY['clock_in_at', 'clock_in_lat', 'clock_in_lng', 'geofence_valid', 'exceptions',
                                'person_id', 'staff_id', 'service_code_id', 'org_id'];
  v_k text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;                          -- service role / SQL editor
  IF current_setting('provly.evv_correction', true) = 'on' THEN RETURN NEW; END IF;  -- inside correct_evv_session

  IF v_tier IN ('manage', 'operate') THEN
    -- v20.0.16 / r2 — a correction is a correction whoever makes it: through the
    -- RPC, with a reason and a log entry. The one direct change is a live
    -- clock-out of an OPEN session (clock_out_at / lat / lng).
    IF OLD.clock_out_at IS NOT NULL THEN                          -- completed: every EVV element frozen
      FOREACH v_k IN ARRAY v_evidence LOOP
        IF (to_jsonb(NEW) -> v_k) IS DISTINCT FROM (to_jsonb(OLD) -> v_k) THEN
          RAISE EXCEPTION 'EVV corrections are saved with a reason through Correct times (correct_evv_session)';
        END IF;
      END LOOP;
    ELSE                                                          -- open: live clock-out only
      FOREACH v_k IN ARRAY v_open_locked LOOP
        IF (to_jsonb(NEW) -> v_k) IS DISTINCT FROM (to_jsonb(OLD) -> v_k) THEN
          RAISE EXCEPTION 'EVV corrections are saved with a reason through Correct times (correct_evv_session)';
        END IF;
      END LOOP;
    END IF;
    RETURN NEW;
  END IF;

  -- deliver (unchanged from v20.0.13r1)
  IF OLD.clock_out_at IS NOT NULL THEN                          -- completed: frozen for deliver
    IF (to_jsonb(NEW) - v_derived) <> (to_jsonb(OLD) - v_derived) THEN
      RAISE EXCEPTION 'This session is already clocked out. Ask a supervisor to correct it.';
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - v_clockout) <> (to_jsonb(OLD) - v_clockout) THEN   -- open: clock-out fields only
    RAISE EXCEPTION 'EVV time corrections are made by a supervisor, with a reason';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_evv_deliver_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS evv_deliver_guard ON public.evv_sessions;
CREATE TRIGGER evv_deliver_guard
  BEFORE UPDATE ON public.evv_sessions
  FOR EACH ROW EXECUTE FUNCTION public.trg_evv_deliver_guard();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. evv_edit_log — written only by the RPC (no app write policies at all)
-- ─────────────────────────────────────────────────────────────────────────────
-- r1 — by kind, not by name: production still carried the pre-Item-4
-- evv_edit_log_insert (roles public), so drop EVERY permissive write policy.
DO $$
DECLARE v_pol record;
BEGIN
  FOR v_pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'evv_edit_log'
      AND permissive = 'PERMISSIVE' AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.evv_edit_log', v_pol.policyname);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification — one statement. Paste the whole result.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT check_name, value, want FROM (
  SELECT 1 AS ord, 'correct_evv_session: SECURITY DEFINER, office-tier gate, reason required, log + update in one body' AS check_name,
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'correct_evv_session' AND p.prosecdef
             AND p.prosrc LIKE '%made by a supervisor or manager%'
             AND p.prosrc LIKE '%A reason is required%'
             AND p.prosrc LIKE '%INSERT INTO public.evv_edit_log%'
             AND p.prosrc LIKE '%UPDATE public.evv_sessions%') AS value,
         '1' AS want
  UNION ALL
  SELECT 2, 'grants: authenticated may execute, anon may not',
         (SELECT (has_function_privilege('authenticated', 'public.correct_evv_session(uuid, jsonb, text)', 'EXECUTE')
                  AND NOT has_function_privilege('anon', 'public.correct_evv_session(uuid, jsonb, text)', 'EXECUTE'))::text),
         'true'
  UNION ALL
  SELECT 3, 'evv_deliver_guard: honours only the RPC flag for office-tier corrections',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_evv_deliver_guard'
             AND p.prosrc LIKE '%provly.evv_correction%'
             AND p.prosrc LIKE '%v_tier IN (''manage'', ''operate'')%'
             AND p.prosrc LIKE '%correct_evv_session%'),
         '1'
  UNION ALL
  SELECT 4, 'evv_edit_log: permissive write policies (must be 0 — only the RPC writes it)',
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'evv_edit_log' AND permissive = 'PERMISSIVE'
             AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
         '0'
  UNION ALL
  SELECT 5, 'evv_edit_log: tier read policy still in place',
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'evv_edit_log' AND policyname = 'evv_edit_log_read_tier'),
         '1'
  UNION ALL
  SELECT 6, 'evv_deliver_guard trigger present on evv_sessions',
         (SELECT count(*)::text FROM pg_trigger WHERE tgrelid = 'public.evv_sessions'::regclass AND tgname = 'evv_deliver_guard' AND NOT tgisinternal),
         '1'
  UNION ALL
  SELECT 8, 'r2: guard holds office tiers on OPEN sessions (live clock-out only) and freezes who/whom/what on completed ones',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_evv_deliver_guard'
             AND p.prosrc LIKE '%v_open_locked%' AND p.prosrc LIKE '%''person_id'', ''staff_id'', ''service_code_id''%'),
         '1'
  UNION ALL
  SELECT 9, 'r2: correct_evv_session refuses to reopen a completed visit',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'correct_evv_session'
             AND p.prosrc LIKE '%cannot be reopened%'),
         '1'
  UNION ALL
  SELECT 10, 'r3: clearing exceptions stores ''[]'' (column is NOT NULL)',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'correct_evv_session'
             AND p.prosrc LIKE '%THEN ''[]''::jsonb ELSE%'),
         '1'
  UNION ALL
  SELECT 7, '(info) evv_edit_log rows today',
         (SELECT count(*)::text FROM public.evv_edit_log),
         'read'
) v ORDER BY ord;
