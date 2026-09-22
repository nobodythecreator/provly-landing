-- ============================================================================
-- Provly v20.0.16 — EVV corrections as one database transaction
-- Run in the Supabase SQL editor (production) BEFORE the app ships. Idempotent.
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
    v_exc := CASE WHEN jsonb_typeof(p_patch->'exceptions') = 'null' THEN NULL ELSE p_patch->'exceptions' END;
    v_exc_chg := v_exc IS DISTINCT FROM v_old.exceptions;
  END IF;

  IF NOT (v_in_chg OR v_out_chg OR v_exc_chg) THEN
    RAISE EXCEPTION 'No changes to save';
  END IF;
  IF v_in IS NULL THEN
    RAISE EXCEPTION 'Clock-in time is required — a visit cannot exist without one';
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
  v_evidence text[] := ARRAY['clock_in_at', 'clock_out_at', 'clock_in_lat', 'clock_in_lng', 'clock_out_lat', 'clock_out_lng', 'geofence_valid', 'exceptions'];
  v_k text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;                          -- service role / SQL editor
  IF current_setting('provly.evv_correction', true) = 'on' THEN RETURN NEW; END IF;  -- inside correct_evv_session

  IF v_tier IN ('manage', 'operate') THEN
    -- v20.0.16 — a correction is a correction whoever makes it: through the RPC,
    -- with a reason and a log entry. Live clock-out of an open session is not one.
    IF NEW.clock_in_at IS DISTINCT FROM OLD.clock_in_at THEN
      RAISE EXCEPTION 'EVV corrections are saved with a reason through Correct times (correct_evv_session)';
    END IF;
    IF OLD.clock_out_at IS NOT NULL THEN
      FOREACH v_k IN ARRAY v_evidence LOOP
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
DROP POLICY IF EXISTS evv_edit_log_insert_tier ON public.evv_edit_log;

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
  SELECT 7, '(info) evv_edit_log rows today',
         (SELECT count(*)::text FROM public.evv_edit_log),
         'read'
) v ORDER BY ord;
