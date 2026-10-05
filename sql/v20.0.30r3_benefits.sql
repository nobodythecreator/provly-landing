-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.30 r3 — benefits integrity, finished (Greptile r3; runs after sql/v20.0.30r2_benefits.sql)
--   1 A spend-down is paid only while its payment still meets EVERY linking rule — including being dated
--     on or after the spend-down's month (an edit into an earlier month un-pays it).
--   2 A response can answer a close only if it was recorded after that close. r2's one-time backfill could
--     attach an earlier live-warning response to a later close in the same month; any such link is undone
--     here, and a trigger now refuses one from ever being written again.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; a self-test runs and is
-- rolled back; any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public._pba_spenddown_paid(uuid)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.30 r3 stopped before changing anything — run sql/v20.0.30r2_benefits.sql first. Paste this message into chat.';
  END IF;
END $$;

-- 1. paid = the payment still meets every linking rule
CREATE OR REPLACE FUNCTION public._pba_spenddown_paid(p_spenddown uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM pba_spenddowns s JOIN pba_transactions t ON t.id = s.paid_txn_id
                  WHERE s.id = p_spenddown AND t.status = 'active' AND t.type = 'withdrawal' AND t.reverses_id IS NULL
                    AND t.amount >= s.amount AND t.entry_date >= s.month          -- r3: still dated on or after the spend-down's month
                    AND NOT EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = t.id AND r.status = 'active'))
$$;

-- 2a. undo any backfilled link to a close that was signed after the response was recorded
UPDATE public.pba_asset_responses r SET form_b_id = NULL
  FROM public.pba_form_b f
 WHERE r.form_b_id = f.id AND r.created_at < f.created_at;

-- 2b. and never allow one again
CREATE OR REPLACE FUNCTION public.trg_pba_asset_response_after_close()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NEW.form_b_id IS NOT NULL AND EXISTS (SELECT 1 FROM pba_form_b f WHERE f.id = NEW.form_b_id
                                             AND (f.person_id <> NEW.person_id OR NEW.created_at < f.created_at)) THEN
    RAISE EXCEPTION 'A response can only answer a close of the same Person, recorded after that close';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pba_asset_response_after_close ON public.pba_asset_responses;
CREATE TRIGGER pba_asset_response_after_close BEFORE INSERT OR UPDATE ON public.pba_asset_responses
  FOR EACH ROW EXECUTE FUNCTION public.trg_pba_asset_response_after_close();

REVOKE ALL ON FUNCTION public._pba_spenddown_paid(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_pba_asset_response_after_close() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

CREATE TEMP TABLE IF NOT EXISTS v20030r3_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20030r3_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20030r3_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.30r3 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res jsonb := '[]'::jsonb; v_fail text; v_step text := 'setup';
  v_org uuid; v_person uuid; s_owner uuid; s_cd uuid; s_mgr uuid;
  v_bank uuid := gen_random_uuid(); v_sd uuid; t1 uuid := gen_random_uuid(); fb uuid; v_msg text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s2.org_id INTO v_org FROM staff s2 ORDER BY s2.created_at NULLS LAST, s2.id LIMIT 1;
  BEGIN
    v_person := pg_temp.v20030r3_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20030R3', 'last_name', 'Selftest', 'identification_number', '099999938', 'is_active', true));
    s_owner := pg_temp.v20030r3_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R33test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20030r3_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R33test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20030r3_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R33test', 'last_name', 'Manager'));
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20030R3 Selftest', 'opening_balance', 500,
              'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');

    -- S1: the payment edited into an earlier month no longer pays the spend-down
    v_step := 'S1 edited date';
    PERFORM public._pba_save_spenddown(v_person, DATE '2001-03-01', 60, DATE '2001-03-20', s_mgr, 'dsp');
    SELECT id INTO v_sd FROM pba_spenddowns WHERE person_id = v_person;
    PERFORM public._pba_record_txn(t1, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-03-05', 'type', 'withdrawal', 'amount', 60, 'payee', 'Medicaid'), s_mgr, 'dsp');
    PERFORM public._pba_pay_spenddown(v_sd, t1, s_mgr, 'dsp');
    v_msg := 'paid ' || public._pba_spenddown_paid(v_sd)::text;
    PERFORM public._pba_edit_txn(t1, '{"entry_date": "2001-02-25"}'::jsonb, 'Paid in February, not March', s_mgr, 'dsp');
    v_msg := v_msg || '; after moving it to February ' || public._pba_spenddown_paid(v_sd)::text
             || ', flag ' || (EXISTS (SELECT 1 FROM public._pba_flags(v_person, DATE '2001-03-25') f WHERE f.o_flag = 'spenddown_overdue' AND f.o_ref = v_sd))::text;
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'S1 a March spend-down paid on 3/5, then the payment re-dated to 2/25',
      v_msg, 'paid true; after moving it to February false, flag true'));

    -- S2: a response recorded before a close can't be attached to it
    v_step := 'S2 response before close';
    INSERT INTO pba_form_b (org_id, person_id, month, summary, countable, created_at) VALUES (v_org, v_person, DATE '2001-01-01', '{"accounts": []}'::jsonb, 1900, now())
      RETURNING id INTO fb;
    v_msg := '';
    BEGIN
      INSERT INTO pba_asset_responses (org_id, person_id, month, form_b_id, notices, plan_type, plan_detail, target_date, created_at)
      VALUES (v_org, v_person, DATE '2001-01-01', fb, '{"person": "2001-01-20", "residential": "2001-01-20", "sc": "2001-01-20"}'::jsonb,
              'other', 'An earlier live-warning plan', DATE '2001-01-31', now() - interval '1 day');
      v_msg := 'earlier response ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'earlier response refused'; END;
    PERFORM public._pba_save_asset_response(v_person, DATE '2001-01-01', jsonb_build_object('notices', jsonb_build_object('person', '2001-02-03', 'residential', '2001-02-03', 'sc', '2001-02-03'),
              'plan_type', 'planned_purchase', 'plan_detail', 'Winter coat', 'target_date', '2001-02-28'), s_mgr, 'dsp');
    v_msg := v_msg || '; a response after the close ' || CASE WHEN EXISTS (SELECT 1 FROM pba_asset_responses WHERE form_b_id = fb) THEN 'kept' ELSE 'MISSING' END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'S2 attaching a response recorded the day before the close; then one recorded after it',
      v_msg, 'earlier response refused; a response after the close kept'));

    RAISE EXCEPTION 'v20030r3_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20030r3_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 2 THEN
    RAISE EXCEPTION 'v20.0.30 r3 self-test failed, so nothing in this file was applied: %', coalesce(v_fail, format('%s of 2 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20030r3_selftest (n, item, value, want) SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20030r3_test_insert(text, jsonb);

COMMIT;


-- ── Verification — paste this table into chat before the PR merges ─────
SELECT * FROM (
  SELECT 1 AS n, 'spend-down paid requires the payment date rule' AS check_item,
    ((SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_spenddown_paid(uuid)'::regprocedure) LIKE '%t.entry_date >= s.month%')::text AS value, 'true' AS want
  UNION ALL
  SELECT 2, 'responses attached to a close recorded before it (should be none)',
    (SELECT count(*) FROM public.pba_asset_responses r JOIN public.pba_form_b f ON f.id = r.form_b_id WHERE r.created_at < f.created_at)::text, '0'
  UNION ALL
  SELECT 3, 'the after-close trigger is in place',
    (SELECT count(*) FROM pg_trigger WHERE tgname = 'pba_asset_response_after_close' AND NOT tgisinternal)::text, '1'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20030r3_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999938')
     + (SELECT count(*) FROM public.staff WHERE first_name = 'R33test'))::text, '0'
) v ORDER BY n;
