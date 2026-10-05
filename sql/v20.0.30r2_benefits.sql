-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.30 r2 — benefits integrity (Greptile r2; v20.0.30 and r1 already ran, so this is a new migration)
--   1 One withdrawal pays one spend-down, whatever the timing: a unique index (pba_spenddowns_one_payment)
--     decides any race; linking locks the payment row too.
--   2 "Paid" is derived, never stored: a spend-down counts as paid only while its payment is still an
--     active, unreversed withdrawal that covers the amount. A void or reversal un-pays it at once, and
--     the overdue flag comes back (pba_spenddown_status() tells the app).
--   3 Asset responses are insert-only and each answers a specific close (form_b_id) — or the current
--     month's live warning. Answering two closes never overwrites one with the other; an official alert
--     clears only with a response for that very close.
--   4 Form G's report must be a PDF document of the Person.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; a self-test runs and is
-- rolled back; any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public.trg_pba_seal_txn()') IS NULL THEN
    RAISE EXCEPTION 'v20.0.30 r2 stopped before changing anything — run sql/v20.0.30r1_close.sql first. Paste this message into chat.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pba_spenddowns WHERE paid_txn_id IS NOT NULL GROUP BY paid_txn_id HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'v20.0.30 r2 stopped before changing anything — one payment is credited to two spend-downs. Paste this message into chat.';
  END IF;
END $$;

-- 1. one payment, one spend-down
CREATE UNIQUE INDEX IF NOT EXISTS pba_spenddowns_one_payment ON public.pba_spenddowns (paid_txn_id) WHERE paid_txn_id IS NOT NULL;

-- 3. responses tied to the close they answer; no more one-per-month overwrite
ALTER TABLE public.pba_asset_responses ADD COLUMN IF NOT EXISTS form_b_id uuid REFERENCES public.pba_form_b (id);
ALTER TABLE public.pba_asset_responses DROP CONSTRAINT IF EXISTS pba_asset_one;
UPDATE public.pba_asset_responses r SET form_b_id = f.id FROM public.pba_form_b f
 WHERE r.form_b_id IS NULL AND f.person_id = r.person_id AND f.month = r.month;
CREATE INDEX IF NOT EXISTS pba_asset_by_close ON public.pba_asset_responses (form_b_id);

CREATE OR REPLACE FUNCTION public._pba_pay_spenddown(p_spenddown uuid, p_txn uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE s record; a record;
BEGIN
  SELECT * INTO s FROM pba_spenddowns WHERE id = p_spenddown FOR UPDATE;
  PERFORM 1 FROM pba_transactions WHERE id = p_txn FOR UPDATE;             -- r2: the payment row too (a void waits for this)
  IF NOT FOUND THEN RAISE EXCEPTION 'That spend-down doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(s.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager links the payment'; END IF;
  -- r1: a payment out of the Person's money (not a transfer between their own accounts), covering the
  -- spend-down, on or after its month, and not already credited to another spend-down
  IF NOT EXISTS (SELECT 1 FROM pba_transactions t WHERE t.id = p_txn AND t.person_id = s.person_id AND t.status = 'active'
                   AND t.type = 'withdrawal' AND t.reverses_id IS NULL AND t.amount >= s.amount AND t.entry_date >= s.month
                   AND NOT EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = t.id AND r.status = 'active')) THEN
    RAISE EXCEPTION 'That isn''t a payment of at least $% made on or after % (a withdrawal, not a transfer)', to_char(s.amount, 'FM999999990.00'), to_char(s.month, 'FMMonth YYYY');
  END IF;
  IF EXISTS (SELECT 1 FROM pba_spenddowns x WHERE x.paid_txn_id = p_txn AND x.id <> p_spenddown) THEN
    RAISE EXCEPTION 'That payment is already credited to another spend-down';
  END IF;
  BEGIN
    UPDATE pba_spenddowns SET paid_txn_id = p_txn WHERE id = p_spenddown;
  EXCEPTION WHEN unique_violation THEN                                       -- r2: pba_spenddowns_one_payment decides any race
    RAISE EXCEPTION 'That payment is already credited to another spend-down';
  END;
END;
$$;

-- r2: "paid" is derived, never stored: the linked payment must still be an active, unreversed withdrawal that covers the amount
CREATE OR REPLACE FUNCTION public._pba_spenddown_paid(p_spenddown uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM pba_spenddowns s JOIN pba_transactions t ON t.id = s.paid_txn_id
                  WHERE s.id = p_spenddown AND t.status = 'active' AND t.type = 'withdrawal' AND t.reverses_id IS NULL
                    AND t.amount >= s.amount
                    AND NOT EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = t.id AND r.status = 'active'))
$$;
CREATE OR REPLACE FUNCTION public.pba_spenddown_status(p_person uuid)
RETURNS TABLE (o_id uuid, o_paid boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.pba_can_read(p_person) THEN RETURN; END IF;
  RETURN QUERY SELECT s.id, public._pba_spenddown_paid(s.id) FROM pba_spenddowns s WHERE s.person_id = p_person;
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_save_asset_response(p_person uuid, p_month date, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_now date := date_trunc('month', public._pba_today())::date; v_month date := date_trunc('month', p_month)::date; v_close uuid;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_write OR a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only this Person''s PBA Manager, the owner or the Compliance Director records the asset response'; END IF;
  IF (p_data #>> '{notices,person}') IS NULL OR (p_data #>> '{notices,residential}') IS NULL OR (p_data #>> '{notices,sc}') IS NULL THEN
    RAISE EXCEPTION 'Record the date each notice was given: the Person, the residential team and the SC';
  END IF;
  -- r2: p_month names what is answered — a closed month (its Form B) or the current month (the live warning);
  -- every response is a new row, so answering two alerts never overwrites one with the other
  IF v_month > v_now THEN RAISE EXCEPTION 'A response can''t answer a month that hasn''t happened yet'; END IF;
  SELECT f.id INTO v_close FROM pba_form_b f WHERE f.person_id = p_person AND f.month = v_month;
  IF v_close IS NULL AND v_month <> v_now THEN RAISE EXCEPTION '% has no close to answer', to_char(v_month, 'FMMonth YYYY'); END IF;
  INSERT INTO pba_asset_responses (org_id, person_id, month, form_b_id, countable, notices, plan_type, plan_detail, target_date, created_by)
  VALUES (a.o_org, p_person, v_month, v_close,
          CASE WHEN v_close IS NOT NULL THEN (SELECT f.countable FROM pba_form_b f WHERE f.id = v_close) ELSE public._pba_countable(p_person, public._pba_today()) END,
          p_data->'notices', p_data->>'plan_type', coalesce(btrim(p_data->>'plan_detail'), ''), (p_data->>'target_date')::date, p_actor);
  PERFORM public._pba_audit(a.o_org, 'pba_asset_response', 'pba_asset_responses', p_person, NULL, p_data);
END;
$$;

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
  -- r2: the official alert clears only with notices + a plan recorded FOR that close
  IF v_close_month IS NOT NULL AND v_close_countable >= v_thr AND v_live >= v_thr
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

CREATE OR REPLACE FUNCTION public._pba_form_d_prechecks(p_person uuid, p_month date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_org uuid; v_b record; v_c record; v_third integer; v_threshold numeric; v_resp boolean; v_attest boolean;
BEGIN
  SELECT p.org_id INTO v_org FROM persons p WHERE p.id = p_person;
  SELECT * INTO v_b FROM pba_form_b WHERE person_id = p_person AND month = p_month;
  SELECT * INTO v_c FROM pba_form_c WHERE person_id = p_person AND month = p_month;
  SELECT count(*) INTO v_third FROM pba_transactions t
   WHERE t.person_id = p_person AND t.entry_date BETWEEN p_month AND public._pba_month_end(p_month)
     AND t.status = 'active' AND public._pba_needs_approval(t) AND t.flag_resolved_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = t.id AND r.status = 'active')
     AND NOT EXISTS (SELECT 1 FROM pba_purchase_requests q WHERE q.id = t.request_id AND q.status IN ('approved', 'spent'));
  v_threshold := least(greatest(coalesce(public._pba_setting_num(v_org, 'pba.asset_alert_amount'), 1500), 0), 1000000);
  v_resp := v_b.id IS NOT NULL AND EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.form_b_id = v_b.id);   -- r2: a response for this close
  SELECT coalesce(bool_and(acc.not_provider_funds_attested), true) INTO v_attest FROM pba_accounts acc WHERE acc.person_id = p_person;
  RETURN jsonb_build_object(
    'receipts',        jsonb_build_object('ok', public._pba_missing_receipts(p_person, p_month) = 0, 'detail', 'Every purchase over $50 has its receipt or a signed Lost Receipt Affidavit'),
    'balances',        jsonb_build_object('ok', v_b.id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b.summary->'accounts') x WHERE coalesce((x->>'difference')::numeric, 0) <> 0), 'detail', 'Every account reconciles to its statement (or its count)'),
    'third_party',     jsonb_build_object('ok', v_third = 0, 'detail', 'Every gift, saving, debt payment or purchase for another person was approved (the Person''s choice, needs met) or resolved'),
    'cash_log',        jsonb_build_object('ok', true, 'detail', 'Every cash withdrawal and hand-off names who received it and why'),
    'assets',          jsonb_build_object('ok', v_b.id IS NOT NULL AND (v_b.countable < v_threshold OR v_resp), 'detail', format('Countable assets at the close: $%s (alert at $%s) — under it, or notices and a plan are on file', to_char(coalesce(v_b.countable, 0), 'FM999999990.00'), to_char(v_threshold, 'FM999999990.00'))),
    'provider_funds',  jsonb_build_object('ok', v_attest, 'detail', 'Every account is the Person''s own and not linked to the provider''s funds'),
    'person_signed_c', jsonb_build_object('ok', v_c.id IS NOT NULL AND EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = 'form_c' AND s.form_id = v_c.id AND s.capacity IN ('person', 'guardian')),
                                          'detail', CASE WHEN v_c.exception_reason IS NOT NULL THEN 'Not signed by the Person: ' || v_c.exception_reason ELSE 'The Person (or guardian) signed the monthly review' END)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_record_form_g(p_person uuid, p_month date, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_month date := date_trunc('month', p_month)::date; v_id uuid; v_sent date := (p_data->>'sent_on')::date; v_file uuid := (nullif(p_data->>'file_id', ''))::uuid;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager records the SC report'; END IF;
  IF NOT public._pba_step_done(p_person, v_month, 'D') THEN RAISE EXCEPTION 'The % administrative review (Form D) comes first', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF public._pba_step_done(p_person, v_month, 'G') THEN RAISE EXCEPTION 'The % SC report is already recorded', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF v_sent IS NULL OR v_sent > public._pba_today() THEN RAISE EXCEPTION 'Enter the date it was sent (not in the future)'; END IF;
  IF v_file IS NULL OR NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = v_file AND f.person_id = p_person AND f.purpose = 'document' AND f.mime = 'application/pdf') THEN
    RAISE EXCEPTION 'The report PDF isn''t on file';                       -- r2: a PDF document of this Person
  END IF;
  INSERT INTO pba_form_g (org_id, person_id, month, sent_on, sent_to_name, sent_to_email, method, file_id, created_by)
  VALUES (a.o_org, p_person, v_month, v_sent, coalesce(btrim(p_data->>'sent_to_name'), ''), nullif(btrim(p_data->>'sent_to_email'), ''),
          coalesce(btrim(p_data->>'method'), ''), v_file, p_actor)
  RETURNING id INTO v_id;
  PERFORM public._pba_audit(a.o_org, 'pba_form_g_sent', 'pba_form_g', v_id, NULL, p_data);
  RETURN v_id;
END;
$$;


DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND (p.proname LIKE '\_pba\_%' OR p.proname LIKE 'trg\_pba\_%') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.pba_spenddown_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pba_spenddown_status(uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

CREATE TEMP TABLE IF NOT EXISTS v20030r2_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20030r2_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20030r2_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.30r2 self-test') || '::' || c.typ END;
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
  v_bank uuid := gen_random_uuid(); sd_feb uuid; sd_mar uuid; t1 uuid := gen_random_uuid(); t2 uuid := gen_random_uuid();
  fb_jan uuid; fb_feb uuid; v_fid uuid;
  v_today date := DATE '2001-03-16'; v_msg text; v_txt text; v_n integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s2.org_id INTO v_org FROM staff s2 ORDER BY s2.created_at NULLS LAST, s2.id LIMIT 1;
  BEGIN
    v_person := pg_temp.v20030r2_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20030R2', 'last_name', 'Selftest', 'identification_number', '099999937', 'is_active', true));
    s_owner := pg_temp.v20030r2_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R32test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20030r2_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R32test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20030r2_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R32test', 'last_name', 'Manager'));
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    -- the test pins its own threshold (inside the rolled-back block), so a provider's setting can't change the expected result
    PERFORM public._set_org_setting('pba.asset_alert_amount', '1500'::jsonb, s_owner, 'owner', v_org);
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20030R2 Selftest', 'opening_balance', 1900,
              'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');

    -- S1 + S2: one payment for one spend-down (the index decides); a void un-pays it; relinking pays it again
    v_step := 'S1 S2 spend-down';
    PERFORM public._pba_save_spenddown(v_person, DATE '2001-02-01', 60, DATE '2001-02-20', s_mgr, 'dsp');
    PERFORM public._pba_save_spenddown(v_person, DATE '2001-03-01', 60, DATE '2001-03-10', s_mgr, 'dsp');
    SELECT id INTO sd_feb FROM pba_spenddowns WHERE person_id = v_person AND month = DATE '2001-02-01';
    SELECT id INTO sd_mar FROM pba_spenddowns WHERE person_id = v_person AND month = DATE '2001-03-01';
    PERFORM public._pba_record_txn(t1, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-03-05', 'type', 'withdrawal', 'amount', 60, 'payee', 'Medicaid'), s_mgr, 'dsp');
    PERFORM public._pba_pay_spenddown(sd_mar, t1, s_mgr, 'dsp');
    v_msg := '';
    BEGIN UPDATE pba_spenddowns SET paid_txn_id = t1 WHERE id = sd_feb; v_msg := 'second credit ALLOWED';     -- as a racing request would
    EXCEPTION WHEN unique_violation THEN v_msg := 'second credit refused by the index'; END;
    v_msg := v_msg || '; paid ' || public._pba_spenddown_paid(sd_mar)::text;
    PERFORM public._pba_void_txn(t1, 'Payment bounced', s_mgr, 'dsp');
    v_msg := v_msg || '; after void ' || public._pba_spenddown_paid(sd_mar)::text
             || ', flag ' || (EXISTS (SELECT 1 FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'spenddown_overdue' AND f.o_ref = sd_mar))::text;
    PERFORM public._pba_record_txn(t2, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-03-12', 'type', 'withdrawal', 'amount', 60, 'payee', 'Medicaid'), s_mgr, 'dsp');
    PERFORM public._pba_pay_spenddown(sd_mar, t2, s_mgr, 'dsp');
    v_msg := v_msg || '; relinked ' || public._pba_spenddown_paid(sd_mar)::text;
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'S1/S2 one $60 payment credited to March, then to February too; the payment voided; a new one linked',
      v_msg, 'second credit refused by the index; paid true; after void false, flag true; relinked true'));

    -- S3: two closes, two responses — neither overwrites the other; each clears only its own close
    v_step := 'S3 asset responses';
    INSERT INTO pba_form_b (org_id, person_id, month, summary, countable) VALUES (v_org, v_person, DATE '2001-01-01', '{"accounts": []}'::jsonb, 1900) RETURNING id INTO fb_jan;
    INSERT INTO pba_form_b (org_id, person_id, month, summary, countable) VALUES (v_org, v_person, DATE '2001-02-01', '{"accounts": []}'::jsonb, 1900) RETURNING id INTO fb_feb;
    PERFORM public._pba_save_asset_response(v_person, DATE '2001-01-01', jsonb_build_object('notices', jsonb_build_object('person', '2001-02-03', 'residential', '2001-02-03', 'sc', '2001-02-03'),
              'plan_type', 'planned_purchase', 'plan_detail', 'Winter coat', 'target_date', '2001-02-28'), s_mgr, 'dsp');
    v_txt := coalesce((SELECT string_agg(f.o_flag, ',') FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%'), 'none');
    PERFORM public._pba_save_asset_response(v_person, DATE '2001-02-01', jsonb_build_object('notices', jsonb_build_object('person', '2001-03-03', 'residential', '2001-03-03', 'sc', '2001-03-03'),
              'plan_type', 'able', 'plan_detail', 'ABLE deposit of $500', 'target_date', '2001-03-31'), s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_save_asset_response(v_person, DATE '2001-04-01', jsonb_build_object('notices', jsonb_build_object('person', '2001-03-03', 'residential', '2001-03-03', 'sc', '2001-03-03'),
              'plan_type', 'other', 'plan_detail', 'x', 'target_date', '2001-04-30'), s_mgr, 'dsp'); v_msg := 'unclosed month ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'unclosed month refused'; END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'S3 closes in January and February at $1,900: answer January, then February, then a month with no close',
      'after January only: ' || v_txt || '; after both: ' || coalesce((SELECT string_agg(f.o_flag, ',') FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%'), 'none')
      || '; responses kept ' || (SELECT count(*) FROM pba_asset_responses WHERE person_id = v_person) || ' (Jan ' || (SELECT plan_detail FROM pba_asset_responses WHERE form_b_id = fb_jan)
      || ', Feb ' || (SELECT plan_detail FROM pba_asset_responses WHERE form_b_id = fb_feb) || '); ' || v_msg,
      'after January only: asset_alert; after both: none; responses kept 2 (Jan Winter coat, Feb ABLE deposit of $500); unclosed month refused'));

    -- S4: Form G needs a PDF document of the Person
    v_step := 'S4 Form G file';
    INSERT INTO pba_form_c (org_id, person_id, month, review_date, mode, exception_reason) VALUES (v_org, v_person, DATE '2001-01-01', '2001-02-08', 'in_person', 'Declined');
    INSERT INTO pba_form_d (org_id, person_id, month, checklist) VALUES (v_org, v_person, DATE '2001-01-01', '{}'::jsonb);
    v_fid := gen_random_uuid();
    INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, mime, uploaded_by)
    VALUES (v_fid, v_org, v_person, 'receipt', v_org || '/' || v_person || '/receipts/' || v_fid || '.jpg', repeat('e', 64), 'image/jpeg', s_mgr);
    v_msg := '';
    BEGIN PERFORM public._pba_record_form_g(v_person, DATE '2001-01-01', jsonb_build_object('sent_on', '2001-02-20', 'sent_to_name', 'SC', 'method', 'Secure email', 'file_id', v_fid), s_mgr, 'dsp');
          v_msg := 'a receipt image ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'a receipt image refused'; END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'S4 recording Form G with a receipt image as the report', v_msg, 'a receipt image refused'));

    RAISE EXCEPTION 'v20030r2_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20030r2_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 3 THEN
    RAISE EXCEPTION 'v20.0.30 r2 self-test failed, so nothing in this file was applied: %', coalesce(v_fail, format('%s of 3 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20030r2_selftest (n, item, value, want) SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20030r2_test_insert(text, jsonb);

COMMIT;


-- ── Verification — paste this table into chat before the PR merges ─────
SELECT * FROM (
  SELECT 1 AS n, 'one payment credits one spend-down (unique index)' AS check_item,
    (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'pba_spenddowns_one_payment')::text AS value, '1' AS want
  UNION ALL
  SELECT 2, 'asset responses: tied to their close, no one-per-month overwrite',
    ((SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pba_asset_responses' AND column_name = 'form_b_id')
     || ' · ' || (SELECT count(*) FROM pg_constraint WHERE conname = 'pba_asset_one'))::text, '1 · 0'
  UNION ALL
  SELECT 3, 'spend-down status callable by signed-in users; internals not',
    (has_function_privilege('authenticated', 'public.pba_spenddown_status(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._pba_spenddown_paid(uuid)', 'EXECUTE'))::text, 'true'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20030r2_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999937')
     + (SELECT count(*) FROM public.staff WHERE first_name = 'R32test'))::text, '0'
) v ORDER BY n;
