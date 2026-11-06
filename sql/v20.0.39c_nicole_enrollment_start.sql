-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.39c_nicole_enrollment_start.sql
-- One Person's PBA enrollment date, corrected.
--
-- Nicole Hyden's enrollment was recorded as starting 2026-10-26 — the day it was entered in Provly — so
-- her PBA cycle began in October and September (already reconciled and reviewed) was outside it: no
-- step status, no due dates, nothing tracking its Form D and Form G. Hope Haven was her representative
-- payee before then: the payee account's first statement (Zions Bank) runs from 2026-09-01, and
-- Hope Haven received her 9/25 deposit as payee. SSA's appointment letter isn't on file, so the start is
-- set to 2026-09-01, the payee account's first statement day; it can be changed to the letter's
-- effective date when the letter is found.
--
-- After this, September is part of her cycle: Forms B and C show done; Forms D and G show their real
-- (overdue) status until they're completed.
--
-- RUN IN SUPABASE (SQL editor), ONCE. It stops without changing anything unless the enrollment still
-- starts on 2026-10-26.
-- r1 (Greptile round 1, before this file ran): the verification checks that both D and G are tracked;
--   their current status is shown as information, not as a pass/fail.
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $fix$
DECLARE
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_person uuid;
  v_n      integer;
  v_enr    uuid;
  v_old    jsonb;
BEGIN
  SELECT count(*) INTO v_n FROM persons
   WHERE org_id = v_org AND first_name ILIKE 'nicole%' AND last_name ILIKE 'hyden%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'v20.0.39c: expected one Person named Nicole Hyden, found %. Nothing was changed.', v_n; END IF;
  SELECT id INTO v_person FROM persons
   WHERE org_id = v_org AND first_name ILIKE 'nicole%' AND last_name ILIKE 'hyden%';

  SELECT id INTO v_enr FROM pba_enrollments
   WHERE person_id = v_person AND started_on = date '2026-10-26' AND ended_on IS NULL;
  IF v_enr IS NULL THEN
    RAISE EXCEPTION 'v20.0.39c: her enrollment no longer starts 2026-10-26 (it may already be corrected). Nothing was changed.';
  END IF;

  SELECT to_jsonb(e) INTO v_old FROM pba_enrollments e WHERE e.id = v_enr;
  UPDATE pba_enrollments SET started_on = date '2026-09-01', updated_at = now() WHERE id = v_enr;
  PERFORM public._pba_audit(v_org, 'pba_enrollment_corrected', 'pba_enrollments', v_enr, v_old,
                            (SELECT to_jsonb(e) || jsonb_build_object('reason',
                               'Started 2026-09-01, the first statement day of the representative-payee account (Zions Bank); '
                               || 'it was recorded as 2026-10-26, the day it was entered in Provly. SSA''s appointment letter '
                               || 'isn''t on file — update to its effective date when found.')
                               FROM pba_enrollments e WHERE e.id = v_enr));
END
$fix$;

COMMIT;

-- ── Verification (paste this result into the PR and the chat) ────────────────────────
WITH p AS (
  SELECT id FROM persons WHERE org_id = '00000000-0000-0000-0000-000000000001'
     AND first_name ILIKE 'nicole%' AND last_name ILIKE 'hyden%' LIMIT 1
)
SELECT n, check_name, got, want,
       CASE WHEN want = '(information)' THEN 'ℹ️' WHEN got = want THEN '✅' ELSE '❌' END AS ok FROM (
  SELECT 1 n, 'Enrollment starts' check_name,
    (SELECT e.started_on::text FROM pba_enrollments e JOIN p ON e.person_id = p.id) got, '2026-09-01' want
  UNION ALL SELECT 2, 'September is part of her cycle (4 steps)',
    (SELECT count(*)::text FROM p, public._pba_cycle(p.id) c WHERE c.o_month = date '2026-09-01'), '4'
  UNION ALL SELECT 3, 'September Form B and Form C show done',
    (SELECT count(*)::text FROM p, public._pba_cycle(p.id) c WHERE c.o_month = date '2026-09-01' AND c.o_step IN ('B', 'C') AND c.o_status = 'done'), '2'
  UNION ALL SELECT 4, 'September Forms D and G are both tracked',
    (SELECT count(DISTINCT c.o_step)::text FROM p, public._pba_cycle(p.id) c WHERE c.o_month = date '2026-09-01' AND c.o_step IN ('D', 'G')), '2'
  UNION ALL SELECT 5, 'September Forms D and G — current status',
    (SELECT coalesce(string_agg(c.o_step || ' ' || c.o_status, ', ' ORDER BY c.o_step), 'none') FROM p, public._pba_cycle(p.id) c
      WHERE c.o_month = date '2026-09-01' AND c.o_step IN ('D', 'G')), '(information)'
) t
ORDER BY n;
