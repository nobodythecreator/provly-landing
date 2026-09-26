-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.23a r2 — close the reassignment bypass in the author-only Submit (A).
--   r1 checked only the note's staff_id AFTER the update, so an office user
--   could set staff_id to themselves and status to submitted in one update
--   (or in two). r2:
--     1. A note is never reassigned TO the person making the change. An office
--        user may still correct a draft's author to someone else; to author a
--        note yourself, you write your own.
--     2. A note becomes submitted (insert, or from draft/rejected) only when the
--        caller is its author both before and after the update.
--   The trigger now also fires when staff_id changes. Reopen (approved →
--   submitted) and the office's single approval of a draft stay untouched.
-- Run on production in the Supabase SQL editor BEFORE the app ships. Idempotent.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_service_notes_submit_author()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_me uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;                 -- service role / SQL editor
  v_me := public.my_staff_id();

  -- 1. never reassigned to yourself
  IF TG_OP = 'UPDATE'
     AND NEW.staff_id IS DISTINCT FROM OLD.staff_id
     AND v_me IS NOT NULL AND NEW.staff_id = v_me THEN
    RAISE EXCEPTION 'A note can''t be reassigned to yourself — write your own note instead';
  END IF;

  -- 2. only the author, before and after, submits
  IF NEW.status = 'submitted'
     AND (TG_OP = 'INSERT' OR OLD.status IN ('draft', 'rejected')) THEN
    IF v_me IS NULL
       OR NEW.staff_id IS DISTINCT FROM v_me
       OR (TG_OP = 'UPDATE' AND OLD.staff_id IS DISTINCT FROM v_me) THEN
      RAISE EXCEPTION 'Only the note''s author can submit it';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_service_notes_submit_author() IS
  'v20.0.23a r2 (decision A): a note is never reassigned to the caller, and becomes submitted (insert, or from draft/rejected) only when the caller is its primary staff member before and after. Reopen (approved → submitted) is untouched.';

DROP TRIGGER IF EXISTS service_notes_submit_author ON public.service_notes;
CREATE TRIGGER service_notes_submit_author
  BEFORE INSERT OR UPDATE OF status, staff_id ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_submit_author();

-- Self-tests. Each runs inside a sub-transaction that is rolled back; the outcome
-- is kept in a session temp table so the verification below can show it.
CREATE TEMP TABLE IF NOT EXISTS v20023ar2_selftest (n int, item text, result text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20023ar2_selftest;

DO $$
DECLARE
  v_note   uuid;
  v_staff  uuid;
  v_user   uuid;
  v_org    uuid;
  v_me     uuid;
  v_msg    text;
BEGIN
  -- T1: a signed-in user with no staff record cannot submit a draft
  SELECT id INTO v_note FROM public.service_notes WHERE status = 'draft' ORDER BY id LIMIT 1;
  IF v_note IS NULL THEN
    INSERT INTO v20023ar2_selftest VALUES (1, 'T1 made-up user submits a draft', 'skipped — no draft notes');
  ELSE
    v_msg := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      BEGIN
        UPDATE public.service_notes SET status = 'submitted' WHERE id = v_note;
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      RAISE EXCEPTION 'v20023ar2_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20023ar2_rollback' THEN RAISE; END IF;
    END;
    INSERT INTO v20023ar2_selftest VALUES (1, 'T1 made-up user submits a draft', coalesce('refused: ' || v_msg, 'NOT REFUSED'));
  END IF;

  -- T2/T3: a real office login takes someone else's draft (one update, then two)
  SELECT s.id, s.user_id, s.org_id, n.id
    INTO v_staff, v_user, v_org, v_note
    FROM public.staff s
    JOIN public.service_notes n
      ON n.org_id = s.org_id AND n.status = 'draft' AND n.staff_id IS DISTINCT FROM s.id
   WHERE s.user_id IS NOT NULL AND s.is_active
   ORDER BY s.id, n.id
   LIMIT 1;

  IF v_staff IS NULL THEN
    INSERT INTO v20023ar2_selftest VALUES
      (2, 'T2 office user: staff_id → self + submitted', 'skipped — no login with someone else''s draft'),
      (3, 'T3 office user: staff_id → self (draft)',     'skipped — no login with someone else''s draft');
  ELSE
    -- T2: one update
    v_msg := NULL; v_me := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_user, 'role', 'authenticated', 'org_id', v_org,
                          'app_metadata', json_build_object('org_id', v_org))::text, true);
      v_me := public.my_staff_id();
      IF v_me IS NOT DISTINCT FROM v_staff THEN
        BEGIN
          UPDATE public.service_notes SET staff_id = v_staff, status = 'submitted' WHERE id = v_note;
        EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
        END;
      END IF;
      RAISE EXCEPTION 'v20023ar2_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20023ar2_rollback' THEN RAISE; END IF;
    END;
    INSERT INTO v20023ar2_selftest VALUES (2, 'T2 office user: staff_id → self + submitted',
      CASE WHEN v_me IS DISTINCT FROM v_staff THEN 'skipped — claims did not resolve to the staff record'
           ELSE coalesce('refused: ' || v_msg, 'NOT REFUSED') END);

    -- T3: the first half of the two-step (reassign only)
    v_msg := NULL; v_me := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_user, 'role', 'authenticated', 'org_id', v_org,
                          'app_metadata', json_build_object('org_id', v_org))::text, true);
      v_me := public.my_staff_id();
      IF v_me IS NOT DISTINCT FROM v_staff THEN
        BEGIN
          UPDATE public.service_notes SET staff_id = v_staff WHERE id = v_note;
        EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
        END;
      END IF;
      RAISE EXCEPTION 'v20023ar2_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20023ar2_rollback' THEN RAISE; END IF;
    END;
    INSERT INTO v20023ar2_selftest VALUES (3, 'T3 office user: staff_id → self (draft)',
      CASE WHEN v_me IS DISTINCT FROM v_staff THEN 'skipped — claims did not resolve to the staff record'
           ELSE coalesce('refused: ' || v_msg, 'NOT REFUSED') END);
  END IF;
END $$;

COMMIT;

-- Verification — paste this table into chat before the PR merges.
SELECT * FROM (
  SELECT 1 AS n, 'submit_author trigger fires on status and staff_id' AS check_item,
    (SELECT pg_get_triggerdef(t.oid) LIKE '%UPDATE OF status, staff_id%' FROM pg_trigger t
      WHERE t.tgrelid = 'public.service_notes'::regclass AND t.tgname = 'service_notes_submit_author')::text AS value,
    'true' AS want
  UNION ALL
  SELECT 1 + t.n, t.item, t.result,
    CASE t.n WHEN 1 THEN 'refused: Only the note''s author can submit it'
             ELSE 'refused: A note can''t be reassigned to yourself — write your own note instead' END
    FROM v20023ar2_selftest t
  UNION ALL
  SELECT 5, 'submitted notes (the tests leave nothing behind)',
    (SELECT count(*)::text FROM public.service_notes WHERE status = 'submitted'),
    'same as before the run (0)'
) v ORDER BY n;
