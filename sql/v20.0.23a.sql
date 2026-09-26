-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.23a — bulk approve (C: authors Submit; the office approves what was submitted)
--   approve_service_notes(p_note_ids uuid[]) approves the chosen SUBMITTED notes
--   in one statement (one transaction). SECURITY INVOKER: the caller's RLS applies,
--   and trg_service_notes_lock stamps approved_by / approved_at on every note exactly
--   as a single approval does. Drafts, rejected, approved and billed notes are skipped.
-- Run on production in the Supabase SQL editor BEFORE the app ships. Idempotent.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.approve_service_notes(p_note_ids uuid[])
RETURNS TABLE (approved integer, skipped integer)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public'
AS $$
DECLARE
  v_tier  text := public.access_tier();
  v_asked integer;
  v_done  integer;
BEGIN
  IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
    RAISE EXCEPTION 'Only a supervisor or manager can approve service notes';
  END IF;

  SELECT count(DISTINCT x) INTO v_asked FROM unnest(coalesce(p_note_ids, ARRAY[]::uuid[])) AS x;
  IF v_asked > 500 THEN
    RAISE EXCEPTION 'Approve at most 500 notes at a time';
  END IF;
  IF v_asked = 0 THEN
    approved := 0; skipped := 0; RETURN NEXT; RETURN;
  END IF;

  UPDATE public.service_notes
     SET status = 'approved'
   WHERE id = ANY (p_note_ids)
     AND status = 'submitted';
  GET DIAGNOSTICS v_done = ROW_COUNT;

  approved := v_done;
  skipped  := v_asked - v_done;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.approve_service_notes(uuid[]) IS
  'v20.0.23a: office tiers approve up to 500 submitted notes at once, in one transaction; the approved-note lock stamps approved_by/approved_at per note. Returns (approved, skipped).';

REVOKE ALL ON FUNCTION public.approve_service_notes(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_service_notes(uuid[]) TO authenticated;

-- Self-test: a caller with no membership (the SQL editor) is refused.
DO $$
DECLARE
  v_refused boolean := false;
BEGIN
  BEGIN
    PERFORM * FROM public.approve_service_notes(ARRAY[]::uuid[]);
  EXCEPTION WHEN raise_exception THEN
    v_refused := SQLERRM LIKE 'Only a supervisor or manager%';
  END;
  IF NOT v_refused THEN
    RAISE EXCEPTION 'v20.0.23a self-test: a caller without a membership was NOT refused';
  END IF;
END $$;

COMMIT;

-- Verification — paste this table into chat before the PR merges.
SELECT * FROM (
  SELECT 1 AS n, 'approve_service_notes signature' AS check_item,
    (SELECT string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
       FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'approve_service_notes') AS value,
    'approve_service_notes(p_note_ids uuid[])' AS want
  UNION ALL
  SELECT 2, 'runs as the caller (SECURITY INVOKER)',
    (SELECT (NOT p.prosecdef)::text FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'approve_service_notes'),
    'true'
  UNION ALL
  SELECT 3, 'anon can execute',
    has_function_privilege('anon', 'public.approve_service_notes(uuid[])', 'EXECUTE')::text,
    'false'
  UNION ALL
  SELECT 4, 'authenticated can execute',
    has_function_privilege('authenticated', 'public.approve_service_notes(uuid[])', 'EXECUTE')::text,
    'true'
  UNION ALL
  SELECT 5, 'approved-note lock still on service_notes',
    (SELECT count(*)::text FROM pg_trigger
      WHERE tgrelid = 'public.service_notes'::regclass AND tgname = 'service_notes_lock' AND NOT tgisinternal),
    '1'
  UNION ALL
  SELECT 6, 'submitted notes waiting (informational)',
    (SELECT count(*)::text FROM public.service_notes WHERE status = 'submitted'),
    'any'
) v ORDER BY n;
