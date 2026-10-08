-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.30 r4 — a close-time asset breach stays flagged (Greptile r4; runs after sql/v20.0.30r3_benefits.sql)
--   If countable assets were at or over the alert threshold when Form B was signed, the asset_alert flag
--   stays until notices + a plan are recorded for that close — even if a later withdrawal brings the live
--   balance back under. (v1.2 of the design said the flag also cleared when the total dropped back under;
--   the SOW requires the notice once the threshold is reached, so that clause is removed — docs updated.)
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; a self-test runs and is
-- rolled back; any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public.trg_pba_asset_response_after_close()') IS NULL THEN
    RAISE EXCEPTION 'v20.0.30 r4 stopped before changing anything — run sql/v20.0.30r3_benefits.sql first. Paste this message into chat.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._pba_flags(p_person uuid, p_today date DEFAULT NULL)
RETURNS TABLE (o_flag text, o_detail text, o_ref uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org    uuid;
  v_today  date := coalesce(p_today, public._pba_today());
  v_status text := public._pba_enrollment_status(p_person);
  v_tp_n   integer; v_tp_amt numeric; v_tp_days integer;
  v_thr numeric; v_live numeric; v_close_month date; v_close_countable numeric; v_close_at timestamptz; v_close_id uuid;
BEGIN
  SELECT p.org_id INTO v_org FROM persons p WHERE p.id = p_person;
  IF v_org IS NULL OR v_status IN ('none', 'ended') THEN RETURN; END IF;
  -- r1: read tolerantly (whole numbers, at least 1) so a stored value can never stop the flags loading
  -- r2: clamped to the settings' ranges before the integer cast
  v_tp_n    := least(greatest(floor(coalesce(public._pba_setting_num(v_org, 'pba.third_party_count'), 3)), 1), 1000)::integer;
  v_tp_amt  := least(greatest(coalesce(public._pba_setting_num(v_org, 'pba.third_party_amount'), 150), 0), 1000000);
  v_tp_days := least(greatest(floor(coalesce(public._pba_setting_num(v_org, 'pba.third_party_days'), 90)), 1), 3650)::integer;

  IF v_status = 'pending' THEN
    RETURN QUERY SELECT 'pending_enrollment'::text,
      'Enrollment papers incomplete: ' || concat_ws(', ',
        CASE WHEN e.fiduciary_type IS NULL THEN 'fiduciary type' END,
        CASE WHEN e.proof_file_id IS NULL THEN 'fiduciary proof' END,
        CASE WHEN NOT EXISTS (SELECT 1 FROM pba_natural_support_determinations d
                               JOIN pba_signatures s ON s.form_type = 'form_a' AND s.form_id = d.id AND s.signer_kind = 'staff'
                              WHERE d.person_id = p_person
                                AND d.version = (SELECT max(d2.version) FROM pba_natural_support_determinations d2 WHERE d2.person_id = p_person))
             THEN 'signed Natural Support Determination (Form A)' END) || '. No month can close until they are filed.',
      e.id
      FROM pba_enrollments e WHERE e.person_id = p_person;
  END IF;

  RETURN QUERY
  SELECT 'missing_receipt'::text,
         format('%s · $%s · %s — over $50 with no receipt or signed Lost Receipt Affidavit', to_char(t.entry_date, 'FMMM/FMDD/YYYY'),
                to_char(t.amount, 'FM999999990.00'), coalesce(t.payee, 'no payee')),
         t.id
    FROM pba_transactions t
   WHERE t.person_id = p_person AND public._pba_needs_receipt(t)
     AND NOT EXISTS (SELECT 1 FROM pba_receipts r WHERE r.transaction_id = t.id)
     AND NOT public._pba_affidavit_complete(t.id);

  RETURN QUERY
  SELECT 'third_party_pattern'::text,
         format('%s purchase%s ($%s) for %s in the last %s days — review for possible exploitation',
                g.n, CASE WHEN g.n = 1 THEN '' ELSE 's' END, to_char(g.total, 'FM999999990.00'), g.nm, v_tp_days),
         NULL::uuid
    FROM (SELECT min(btrim(t.beneficiary_name)) AS nm, count(*)::integer AS n, sum(t.amount) AS total
            FROM pba_transactions t
           WHERE t.person_id = p_person AND t.status = 'active' AND t.reverses_id IS NULL AND t.type = 'withdrawal'
             AND t.beneficiary = 'other' AND t.entry_date > v_today - v_tp_days
             AND NOT EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = t.id AND r.status = 'active')
           GROUP BY lower(btrim(t.beneficiary_name))) g
   WHERE g.n >= v_tp_n OR g.total >= v_tp_amt;

  -- r1: the affidavit pattern is about a staff member, not this Person — see _pba_staff_flags

  RETURN QUERY
  SELECT 'roles_incomplete'::text,
         'No active ' || string_agg(CASE r WHEN 'manager' THEN 'PBA Manager' WHEN 'reviewer' THEN 'Administrative Reviewer' ELSE 'Quarterly Auditor' END, ', ' ORDER BY r),
         NULL::uuid
    FROM unnest(ARRAY['manager', 'reviewer', 'auditor']) AS r
   WHERE NOT EXISTS (SELECT 1 FROM pba_role_assignments a WHERE a.person_id = p_person AND a.role = r AND a.end_date IS NULL)
  HAVING count(*) > 0;

  RETURN QUERY
  SELECT 'host_conflict'::text,
         format('%s %s is this Person''s host and holds the %s role — SOW 11.4(1): end the role', s.first_name, s.last_name,
                CASE a.role WHEN 'manager' THEN 'PBA Manager' WHEN 'reviewer' THEN 'Administrative Reviewer' ELSE 'Quarterly Auditor' END),
         a.id
    FROM pba_role_assignments a JOIN staff s ON s.id = a.staff_id
   WHERE a.person_id = p_person AND a.end_date IS NULL AND public._pba_is_host(p_person, a.staff_id);

  RETURN QUERY
  SELECT 'recorded_over_block'::text,
         format('%s · $%s%s — recorded without an approved request (gift, savings, debt or another person''s benefit); the Compliance Director resolves it with a reason',
                to_char(t.entry_date, 'FMMM/FMDD/YYYY'), to_char(t.amount, 'FM999999990.00'),
                CASE WHEN t.beneficiary = 'other' THEN ' for ' || t.beneficiary_name ELSE '' END),
         t.id
    FROM pba_transactions t
   WHERE t.person_id = p_person AND t.status = 'active' AND public._pba_needs_approval(t)
     AND NOT EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = t.id AND r.status = 'active')
     AND t.flag_resolved_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM pba_purchase_requests q WHERE q.id = t.request_id AND q.status IN ('approved', 'spent'));
  -- v20.0.30: the monthly cycle — every step past its due day
  RETURN QUERY
  SELECT 'step_overdue'::text,
         format('%s: %s overdue — due %s', to_char(c.o_month, 'FMMonth YYYY'),
                CASE c.o_step WHEN 'B' THEN 'Form B (reconciliation)' WHEN 'C' THEN 'Form C (review with the Person)'
                              WHEN 'D' THEN 'Form D (administrative review)' ELSE 'Form G (SC report)' END,
                to_char(c.o_due, 'FMMM/FMDD/YYYY')),
         NULL::uuid
    FROM public._pba_cycle(p_person, v_today) c WHERE c.o_status = 'overdue';

  -- v20.0.30 (R2-7): assets — the official check at the latest close, and the live warning
  v_thr := least(greatest(coalesce(public._pba_setting_num(v_org, 'pba.asset_alert_amount'), 1500), 0), 1000000);
  v_live := public._pba_countable(p_person, v_today);
  SELECT f.id, f.month, f.countable, f.created_at INTO v_close_id, v_close_month, v_close_countable, v_close_at FROM pba_form_b f WHERE f.person_id = p_person ORDER BY f.month DESC LIMIT 1;
  -- r4: a breach at the close stands until notices + a plan are recorded FOR that close — spending back
  -- under the threshold afterwards doesn't erase it (SOW 15.2(6): the notice was due at the close)
  IF v_close_month IS NOT NULL AND v_close_countable >= v_thr
     AND NOT EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person AND r.form_b_id = v_close_id) THEN
    RETURN QUERY SELECT 'asset_alert'::text,
      format('Countable assets were $%s at the %s close (alert at $%s; the SSI resource limit is $2,000) — record the notices to the Person, the residential team and the SC, and a plan',
             to_char(v_close_countable, 'FM999999990.00'), to_char(v_close_month, 'FMMonth YYYY'), to_char(v_thr, 'FM999999990.00')), NULL::uuid;
  ELSIF v_live >= v_thr
     AND NOT EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person
                      AND (r.form_b_id = v_close_id
                           OR (r.form_b_id IS NULL AND r.month = date_trunc('month', v_today)::date AND r.created_at >= coalesce(v_close_at, '-infinity'::timestamptz)))) THEN
    RETURN QUERY SELECT 'asset_warning'::text,
      format('Countable assets are $%s right now (alert at $%s; the SSI resource limit is $2,000) — plan before the month ends',
             to_char(v_live, 'FM999999990.00'), to_char(v_thr, 'FM999999990.00')), NULL::uuid;
  END IF;

  -- v20.0.30: Form C completed with an exception, until the reviewer has seen it (Form D)
  RETURN QUERY
  SELECT 'person_did_not_sign'::text, format('%s review: the Person did not sign — %s', to_char(c.month, 'FMMonth YYYY'), c.exception_reason), c.id
    FROM pba_form_c c
   WHERE c.person_id = p_person AND c.exception_reason IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = 'form_c' AND s.form_id = c.id AND s.capacity IN ('person', 'guardian'))
     AND NOT EXISTS (SELECT 1 FROM pba_form_d d WHERE d.person_id = p_person AND d.month = c.month);

  -- v20.0.30 (R2-5): administrative-review findings awaiting the Compliance Director
  RETURN QUERY
  SELECT 'finding_open'::text, format('%s administrative review: %s', to_char(f.month, 'FMMonth YYYY'), f.finding), f.id
    FROM pba_findings f WHERE f.person_id = p_person AND f.responded_at IS NULL;

  -- v20.0.30: Medicaid spend-down past its due date with no payment linked
  RETURN QUERY
  SELECT 'spenddown_overdue'::text, format('%s Medicaid spend-down of $%s was due %s', to_char(s.month, 'FMMonth YYYY'),
                                           to_char(s.amount, 'FM999999990.00'), to_char(s.due_date, 'FMMM/FMDD/YYYY')), s.id
    FROM pba_spenddowns s WHERE s.person_id = p_person AND s.due_date < v_today AND NOT public._pba_spenddown_paid(s.id);   -- r2: derived

  -- v20.0.30: SSA representative-payee accounting past its due date
  RETURN QUERY
  SELECT 'payee_report_overdue'::text, format('SSA payee accounting requested %s was due %s', to_char(r.requested_on, 'FMMM/FMDD/YYYY'),
                                              to_char(r.due_date, 'FMMM/FMDD/YYYY')), r.id
    FROM pba_payee_reports r WHERE r.person_id = p_person AND r.completed_on IS NULL AND r.due_date < v_today;

  -- v20.0.30 (spec §3): PBA time billed by the Person's reviewer or auditor (internal control, not billable)
  RETURN QUERY
  SELECT 'reviewer_billed'::text,
         format('%s · a PBA note by %s %s, this Person''s %s — that time is internal control and not billable',
                to_char(n.service_date, 'FMMM/FMDD/YYYY'), st.first_name, st.last_name,
                CASE ra.role WHEN 'reviewer' THEN 'Administrative Reviewer' ELSE 'Quarterly Auditor' END),
         n.id
    FROM service_notes n
    JOIN service_code_definitions sc ON sc.id = n.service_code_id AND sc.code = 'PBA'
    JOIN pba_role_assignments ra ON ra.person_id = n.person_id AND ra.staff_id = n.staff_id AND ra.role IN ('reviewer', 'auditor')
                                AND ra.start_date <= n.service_date AND (ra.end_date IS NULL OR ra.end_date >= n.service_date)
    JOIN staff st ON st.id = n.staff_id
   WHERE n.person_id = p_person AND n.status::text NOT IN ('draft', 'rejected');
END;
$$;

REVOKE ALL ON FUNCTION public._pba_flags(uuid, date) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

CREATE TEMP TABLE IF NOT EXISTS v20030r4_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20030r4_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20030r4_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.30r4 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res jsonb := '[]'::jsonb; v_fail text; v_step text := 'setup';
  v_org uuid; v_person uuid; s_owner uuid; s_cd uuid; s_mgr uuid; v_bank uuid := gen_random_uuid(); v_msg text;
  v_today date := DATE '2001-02-16';
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s2.org_id INTO v_org FROM staff s2 ORDER BY s2.created_at NULLS LAST, s2.id LIMIT 1;
  BEGIN
    v_person := pg_temp.v20030r4_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20030R4', 'last_name', 'Selftest', 'identification_number', '099999939', 'is_active', true));
    s_owner := pg_temp.v20030r4_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R34test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20030r4_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R34test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20030r4_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R34test', 'last_name', 'Manager'));
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    -- the test pins its own threshold (inside the rolled-back block), so a provider's setting can't change the expected result
    PERFORM public._set_org_setting('pba.asset_alert_amount', '1500'::jsonb, s_owner, 'owner', v_org);
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20030R4 Selftest', 'opening_balance', 1900,
              'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');
    INSERT INTO pba_form_b (org_id, person_id, month, summary, countable) VALUES (v_org, v_person, DATE '2001-01-01', '{"accounts": []}'::jsonb, 1900);

    v_step := 'S1';
    v_msg := 'at the close: ' || coalesce((SELECT string_agg(f.o_flag, ',') FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%'), 'none');
    PERFORM public._pba_record_txn(gen_random_uuid(), v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-02-05', 'type', 'withdrawal',
              'amount', 900, 'payee', 'Furniture store', 'category', 'personal'), s_mgr, 'dsp');
    v_msg := v_msg || '; after spending down to ' || to_char(public._pba_countable(v_person, v_today), 'FM999990.00') || ': '
             || coalesce((SELECT string_agg(f.o_flag, ',') FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%'), 'none');
    PERFORM public._pba_save_asset_response(v_person, DATE '2001-01-01', jsonb_build_object('notices', jsonb_build_object('person', '2001-02-06', 'residential', '2001-02-06', 'sc', '2001-02-06'),
              'plan_type', 'planned_purchase', 'plan_detail', 'Bedroom furniture (bought 2/5)', 'target_date', '2001-02-05'), s_mgr, 'dsp');
    v_msg := v_msg || '; after the response: ' || coalesce((SELECT string_agg(f.o_flag, ',') FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%'), 'none');
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'S1 $1,900 at the January close; $900 spent in February; then notices + the plan recorded for that close',
      v_msg, 'at the close: asset_alert; after spending down to 1000.00: asset_alert; after the response: none'));

    RAISE EXCEPTION 'v20030r4_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20030r4_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 1 THEN
    RAISE EXCEPTION 'v20.0.30 r4 self-test failed, so nothing in this file was applied: %', coalesce(v_fail, format('%s of 1 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20030r4_selftest (n, item, value, want) SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20030r4_test_insert(text, jsonb);

COMMIT;


-- ── Verification — paste this table into chat before the PR merges ─────
SELECT * FROM (
  SELECT 1 AS n, 'the close-time alert no longer depends on the live balance' AS check_item,
    ((SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_flags(uuid,date)'::regprocedure) NOT LIKE '%v_close_countable >= v_thr AND v_live >= v_thr%')::text AS value, 'true' AS want
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20030r4_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999939')
     + (SELECT count(*) FROM public.staff WHERE first_name = 'R34test'))::text, '0'
) v ORDER BY n;
