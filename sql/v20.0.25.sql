-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.25 — Payment Files (e520 PR 3, part 1): the flags review (decision P2 = B)
--   Download is always available. Marking a file uploaded — the step where its
--   notes become billed and lock — needs a recorded review whenever the file has
--   anything to review: a line with a flag, a removed line, or a "delivered but
--   not in the budget" group.
--   • e520_batches gains review_items, flags_reviewed_by, flags_reviewed_at
--   • e520_confirm_review(batch) records who reviewed how many items, and when
--   • e520_batches_review_guard refuses draft → uploaded for a signed-in user
--     until that review is recorded (service-role repairs pass)
-- r1 (Greptile r1): the review must match what the reviewer saw — the page sends the item
--     count it showed and e520_confirm_review refuses a different one; the self-test's
--     positive case runs as a real signed-in owner / admin / compliance director.
-- 🟢 Run in the Supabase SQL editor. Idempotent. Rolls back completely if any
-- self-test check fails.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.e520_batches
  ADD COLUMN IF NOT EXISTS review_items integer,
  ADD COLUMN IF NOT EXISTS flags_reviewed_by uuid REFERENCES public.staff (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS flags_reviewed_at timestamptz;

-- items to review: a line with a flag, a removed line, a not-in-budget group
CREATE OR REPLACE FUNCTION public.e520_review_items(p_batch uuid)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT (SELECT count(*) FROM e520_lines l
           WHERE l.batch_id = p_batch
             AND (l.action = 'remove' OR jsonb_array_length(coalesce(l.flags, '[]'::jsonb)) > 0))::integer
       + coalesce((SELECT jsonb_array_length(coalesce(b.unmatched, '[]'::jsonb)) FROM e520_batches b WHERE b.id = p_batch), 0)
$$;

DROP FUNCTION IF EXISTS public.e520_confirm_review(uuid);
CREATE OR REPLACE FUNCTION public.e520_confirm_review(p_batch uuid, p_items integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_b e520_batches%ROWTYPE;
  v_n integer;
BEGIN
  SELECT * INTO v_b FROM e520_batches WHERE id = p_batch FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment file not found'; END IF;
  IF auth.uid() IS NOT NULL AND v_b.org_id IS DISTINCT FROM public.e520_caller_org(NULL) THEN
    RAISE EXCEPTION 'Payment file not found';
  END IF;
  IF v_b.status <> 'draft' THEN RAISE EXCEPTION 'This payment file is already marked uploaded'; END IF;
  v_n := public.e520_review_items(p_batch);
  IF p_items IS DISTINCT FROM v_n THEN                             -- r1: the review covers exactly what was shown
    RAISE EXCEPTION 'This payment file has % item(s) to review, not %. Reload it and review it again.', v_n, coalesce(p_items::text, 'none');
  END IF;
  UPDATE e520_batches
     SET review_items = v_n, flags_reviewed_by = public.my_staff_id(), flags_reviewed_at = now()
   WHERE id = p_batch;
  INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, new_data)
  VALUES (v_b.org_id, auth.uid(), 'e520_reviewed', 'e520_batches', p_batch, jsonb_build_object('items', v_n));
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_e520_review_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;                 -- service role / SQL editor
  IF public.e520_review_items(NEW.id) > 0 AND NEW.flags_reviewed_at IS NULL THEN
    RAISE EXCEPTION 'Confirm you''ve reviewed the flagged items before marking this file uploaded';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS e520_batches_review_guard ON public.e520_batches;
CREATE TRIGGER e520_batches_review_guard
  BEFORE UPDATE OF status ON public.e520_batches
  FOR EACH ROW WHEN (NEW.status = 'uploaded' AND OLD.status = 'draft')
  EXECUTE FUNCTION public.trg_e520_review_guard();

REVOKE ALL ON FUNCTION public.e520_review_items(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_e520_review_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.e520_confirm_review(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.e520_confirm_review(uuid, integer) TO authenticated;

-- Self-test (rolled back): a synthetic draft with one removed line
CREATE TEMP TABLE IF NOT EXISTS v20025_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20025_selftest;

DO $$
DECLARE
  v_res    jsonb := '[]'::jsonb;
  v_fail   text;
  v_org    uuid;
  v_batch  uuid;
  v_msg    text;
  v_ok     boolean;
  v_n      integer;
  v_by     boolean;
  v_mgr    uuid;
  v_mgr_user uuid;
  v_claims text;
  c        record;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);           -- "nobody signed in"

  -- a real owner / admin / compliance director login, as the page uses
  FOR c IN SELECT s.id, s.user_id, s.org_id FROM staff s WHERE s.user_id IS NOT NULL ORDER BY s.id LIMIT 50 LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', c.user_id, 'role', 'authenticated', 'org_id', c.org_id,
                                                               'app_metadata', json_build_object('org_id', c.org_id))::text, true);
    IF public.access_tier() IS NOT DISTINCT FROM 'manage' AND public.org_id() IS NOT DISTINCT FROM c.org_id
       AND public.my_staff_id() IS NOT DISTINCT FROM c.id THEN
      v_mgr := c.id; v_mgr_user := c.user_id; v_org := c.org_id;
      v_claims := current_setting('request.jwt.claims', true);
      EXIT;
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '{}', true);

  BEGIN
    IF v_mgr IS NULL THEN RAISE EXCEPTION 'no signed-in owner, admin or compliance director login found to test with'; END IF;
    INSERT INTO e520_batches (org_id, service_month, seq, status, source_csv, source_sha256, header, export_csv, export_sha256, unmatched)
    VALUES (v_org, DATE '2001-02-01', 1, 'draft', 'self-test', 'self-test', 'self-test', 'self-test', 'self-test', '[]'::jsonb)
    RETURNING id INTO v_batch;
    INSERT INTO e520_lines (batch_id, org_id, ord, line_number, source_line_number, raw, action, remove_reason)
    VALUES (v_batch, v_org, 100, 1, 1, '[]'::jsonb, 'remove', 'self-test');

    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'T1 items to review are counted (one removed line)',
                       public.e520_review_items(v_batch)::text, '1'));

    -- T2: a signed-in user can't mark it uploaded before the review
    v_msg := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims', v_claims, true);
      BEGIN
        UPDATE e520_batches SET status = 'uploaded' WHERE id = v_batch;
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      RAISE EXCEPTION 'v20025_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20025_rollback' THEN RAISE; END IF;
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'T2 the reviewer can''t mark it uploaded before confirming the review',
                       coalesce('refused: ' || v_msg, 'NOT REFUSED'),
                       'refused: Confirm you''ve reviewed the flagged items before marking this file uploaded'));

    -- T3: a review of a different count than the file has is refused (the page didn't show it all)
    v_msg := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims', v_claims, true);
      BEGIN
        PERFORM public.e520_confirm_review(v_batch, 5);
      EXCEPTION WHEN raise_exception THEN v_msg := SQLERRM;
      END;
      RAISE EXCEPTION 'v20025_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20025_rollback' THEN RAISE; END IF;
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'T3 a review of a different count than the file has is refused',
                       coalesce('refused: ' || v_msg, 'NOT REFUSED'),
                       'refused: This payment file has 1 item(s) to review, not 5. Reload it and review it again.'));

    -- T4: the signed-in reviewer confirms the right count, the review is recorded as theirs, and the file can be marked uploaded
    v_ok := false; v_n := NULL; v_by := NULL;
    BEGIN
      PERFORM set_config('request.jwt.claims', v_claims, true);
      v_n := public.e520_confirm_review(v_batch, 1);
      SELECT (flags_reviewed_by = v_mgr) INTO v_by FROM e520_batches WHERE id = v_batch;
      UPDATE e520_batches SET status = 'uploaded' WHERE id = v_batch;
      v_ok := true;
      RAISE EXCEPTION 'v20025_rollback';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'v20025_rollback' THEN RAISE; END IF;
    END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'T4 the signed-in reviewer confirms, the review is recorded as theirs, and it can be marked uploaded',
                       format('reviewed %s, by the reviewer %s; %s', coalesce(v_n::text, 'NULL'), coalesce(v_by::text, 'NULL'),
                              CASE WHEN v_ok THEN 'allowed' ELSE 'NOT ALLOWED' END),
                       'reviewed 1, by the reviewer true; allowed'));

    RAISE EXCEPTION 'v20025_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20025_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', SQLERRM, '(this row should not appear)'));
    END IF;
  END;

  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 4 THEN
    RAISE EXCEPTION 'v20.0.25 self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 4 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20025_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

COMMIT;

-- Verification — paste this table into chat before the PR merges.
SELECT * FROM (
  SELECT 1 AS n, 'review columns on e520_batches' AS check_item,
    (SELECT count(*)::text FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'e520_batches'
        AND column_name IN ('review_items', 'flags_reviewed_by', 'flags_reviewed_at')) AS value,
    '3' AS want
  UNION ALL
  SELECT 2, 'e520_confirm_review(batch, items): SECURITY DEFINER, callable by signed-in users, not anon',
    (SELECT (p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
             AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))::text
       FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'e520_confirm_review'),
    'true'
  UNION ALL
  SELECT 3, 'review guard on e520_batches',
    (SELECT count(*)::text FROM pg_trigger
      WHERE tgrelid = 'public.e520_batches'::regclass AND tgname = 'e520_batches_review_guard'),
    '1'
  UNION ALL
  SELECT 3 + t.n, t.item, t.value, t.want FROM v20025_selftest t
  UNION ALL
  SELECT 200, 'left behind by the self-test',
    (SELECT count(*)::text FROM public.e520_batches WHERE service_month = DATE '2001-02-01'),
    '0'
) v ORDER BY n;
