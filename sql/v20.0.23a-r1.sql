-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.23a r1 — decision A: only a note's AUTHOR can submit it.
--   Submit is the author's statement that the note is complete; bulk approve
--   (approve_service_notes) trusts it. So a note may become 'submitted' —
--   created as submitted, or moved there from draft or rejected — only when the
--   signed-in person is the note's primary staff member (staff_id).
--   Unchanged: the office Reopen (approved → submitted) and the office's own
--   single approval of any draft from the note itself.
-- Run on production in the Supabase SQL editor BEFORE the app ships. Idempotent.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_service_notes_submit_author()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;                 -- service role / SQL editor
  IF NEW.status = 'submitted'
     AND (TG_OP = 'INSERT' OR OLD.status IN ('draft', 'rejected')) THEN
    IF NEW.staff_id IS DISTINCT FROM public.my_staff_id() THEN
      RAISE EXCEPTION 'Only the note''s author can submit it';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_service_notes_submit_author() IS
  'v20.0.23a r1 (decision A): a note becomes submitted (insert, or from draft/rejected) only when the caller is its primary staff member. Reopen (approved → submitted) is untouched.';

DROP TRIGGER IF EXISTS service_notes_submit_author ON public.service_notes;
CREATE TRIGGER service_notes_submit_author
  BEFORE INSERT OR UPDATE OF status ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_submit_author();

-- Self-test: a signed-in caller who is not the author is refused. Uses a real draft
-- note if one exists, under a made-up signed-in user; everything is rolled back.
DO $$
DECLARE
  v_note    uuid;
  v_refused boolean := false;
BEGIN
  SELECT id INTO v_note FROM public.service_notes WHERE status = 'draft' ORDER BY id LIMIT 1;
  IF v_note IS NULL THEN RETURN; END IF;                         -- nothing to test against
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    BEGIN
      UPDATE public.service_notes SET status = 'submitted' WHERE id = v_note;
    EXCEPTION WHEN raise_exception THEN
      v_refused := SQLERRM = 'Only the note''s author can submit it';
    END;
    RAISE EXCEPTION 'v20023ar1_selftest_rollback';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'v20023ar1_selftest_rollback' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  IF NOT v_refused THEN
    RAISE EXCEPTION 'v20.0.23a r1 self-test: a non-author submit was NOT refused';
  END IF;
END $$;

COMMIT;

-- Verification — paste this table into chat before the PR merges.
SELECT * FROM (
  SELECT 1 AS n, 'submit_author trigger on service_notes' AS check_item,
    (SELECT count(*)::text FROM pg_trigger
      WHERE tgrelid = 'public.service_notes'::regclass AND tgname = 'service_notes_submit_author' AND NOT tgisinternal) AS value,
    '1' AS want
  UNION ALL
  SELECT 2, 'service_notes triggers',
    (SELECT string_agg(tgname, ', ' ORDER BY tgname) FROM pg_trigger
      WHERE tgrelid = 'public.service_notes'::regclass AND NOT tgisinternal),
    'service_note_auth_update, service_notes_delete_audit, service_notes_deliver_auth, service_notes_lock, service_notes_submit_author, service_notes_transport, service_notes_updated_at'
  UNION ALL
  SELECT 3, 'draft notes on production (self-test ran if > 0)',
    (SELECT count(*)::text FROM public.service_notes WHERE status = 'draft'),
    'any'
  UNION ALL
  SELECT 4, 'submitted notes (unchanged by the self-test)',
    (SELECT count(*)::text FROM public.service_notes WHERE status = 'submitted'),
    'same as before the run (0 at the v20.0.23a check)'
) v ORDER BY n;
