-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.29 r1 — PBA Release 1 fixes (Greptile r1; v20.0.29.sql was already run, so this is a new migration)
--   1 A linked purchase request must be THE approval for that purchase: same Person, still approved
--     (or already spent by this very entry), same beneficiary, an amount that covers it — and one
--     active entry per approval (unique index). A wrong link is refused; the entry can always be
--     saved without one, and is then flagged. Voiding or re-linking an entry frees its approval.
--   2 Only those who may prepare Form A (owner, Compliance Director, the PBA Manager) can sign it as
--     its preparer — a reviewer or auditor can no longer complete enrollment.
--   3 Purchasers sign their own Lost Receipt Affidavits from anywhere: pba_affidavits_to_sign()
--     lists theirs (the app shows it on the Dashboard), whether or not they hold a PBA role.
--   4 Once any month is sealed for a Person, account opening balances and dates are sealed too.
--   5 A reversing entry may land after its account closed (it is a correction, not new activity).
--   6 Settings: counts and day windows must be whole numbers of at least 1; flags read settings
--     tolerantly, so a stored value can never stop them loading.
--   7 The affidavit pattern is a staff-level flag (pba_staff_flags, Compliance → PBA), no longer
--     shown on Persons whose own affidavits didn't reach it.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; a self-test runs and
-- is rolled back; any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public._pba_check_txn(public.pba_transactions)') IS NULL OR to_regclass('public.pba_transactions') IS NULL THEN
    RAISE EXCEPTION 'v20.0.29 r1 stopped before changing anything — run sql/v20.0.29.sql first. Paste this message into chat.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pba_transactions WHERE request_id IS NOT NULL AND status = 'active' AND reverses_id IS NULL
             GROUP BY request_id HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'v20.0.29 r1 stopped before changing anything — some purchase request is linked to two active entries. Paste this message into chat.';
  END IF;
END $$;

-- a setting as a number (provider value or default)
CREATE OR REPLACE FUNCTION public._pba_setting_num(p_org uuid, p_key text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN jsonb_typeof(public.provly_setting(p_org, p_key)) = 'number'
              THEN (public.provly_setting(p_org, p_key))::text::numeric END
$$;

-- 1. one active entry per approval
CREATE UNIQUE INDEX IF NOT EXISTS pba_txn_one_per_request ON public.pba_transactions (request_id)
  WHERE request_id IS NOT NULL AND status = 'active' AND reverses_id IS NULL;

CREATE OR REPLACE FUNCTION public._pba_check_txn(t public.pba_transactions)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE acc record; acc2 record; q record;
BEGIN
  SELECT * INTO acc FROM pba_accounts WHERE id = t.account_id;
  IF NOT FOUND OR acc.org_id <> t.org_id OR (acc.person_id IS NOT NULL AND acc.person_id <> t.person_id) THEN
    RAISE EXCEPTION 'That account isn''t one of this Person''s accounts';
  END IF;
  -- r1: a reversing entry is a correction, not new activity — it may land after the account closed
  IF acc.closed_on IS NOT NULL AND t.entry_date > acc.closed_on AND t.reverses_id IS NULL THEN
    RAISE EXCEPTION 'That account was closed on %', acc.closed_on;
  END IF;
  IF t.to_account_id IS NOT NULL THEN
    SELECT * INTO acc2 FROM pba_accounts WHERE id = t.to_account_id;
    IF NOT FOUND OR acc2.org_id <> t.org_id OR (acc2.person_id IS NOT NULL AND acc2.person_id <> t.person_id) THEN
      RAISE EXCEPTION 'The receiving account isn''t one of this Person''s accounts';
    END IF;
  END IF;
  -- the cash log: every cash withdrawal and every hand-off from cash on hand names who got it and why
  IF (t.type = 'cash_out' OR (acc.kind = 'cash' AND t.type IN ('withdrawal', 'transfer')))
     AND (t.handed_to IS NULL OR length(btrim(coalesce(t.purpose, ''))) = 0) THEN
    RAISE EXCEPTION 'Cash needs who received it and what it was for';
  END IF;
  IF t.handed_to IN ('staff', 'host') AND t.handed_to_staff_id IS NULL AND length(btrim(coalesce(t.handed_to_name, ''))) = 0 THEN
    RAISE EXCEPTION 'Name the staff member or host who received the cash';
  END IF;
  -- r1: a linked request must be THE approval for this purchase: the same Person, still approved
  -- (or already spent by this very entry), the same beneficiary, and an amount it covers.
  -- A wrong link is refused; the entry can always be saved without one (and is then flagged).
  IF t.request_id IS NOT NULL THEN
    SELECT * INTO q FROM pba_purchase_requests WHERE id = t.request_id;
    IF NOT FOUND OR q.person_id <> t.person_id THEN RAISE EXCEPTION 'That request belongs to someone else'; END IF;
    IF NOT (q.status = 'approved'
            OR (q.status = 'spent' AND EXISTS (SELECT 1 FROM pba_transactions x
                                                WHERE x.request_id = q.id AND x.id = t.id AND x.status = 'active'))) THEN
      RAISE EXCEPTION 'That request isn''t an open approval (it is %) — save the entry without it, or approve a new request', q.status;
    END IF;
    IF t.type <> 'withdrawal' OR t.reverses_id IS NOT NULL THEN RAISE EXCEPTION 'Only a purchase can spend a request'; END IF;
    IF t.beneficiary IS DISTINCT FROM q.beneficiary
       OR (q.beneficiary = 'other' AND lower(btrim(coalesce(t.beneficiary_name, ''))) <> lower(btrim(coalesce(q.beneficiary_name, '')))) THEN
      RAISE EXCEPTION 'That request was approved for a different beneficiary';
    END IF;
    IF t.amount > q.amount THEN
      RAISE EXCEPTION 'That request covers $% — this purchase is $%', to_char(q.amount, 'FM999999990.00'), to_char(t.amount, 'FM999999990.00');
    END IF;
  END IF;
  IF public._pba_month_closed(t.person_id, t.entry_date) THEN
    RAISE EXCEPTION '% is closed and sealed — record a reversing entry in an open month instead', to_char(t.entry_date, 'FMMonth YYYY');
  END IF;
END;
$$;


CREATE OR REPLACE FUNCTION public._pba_edit_txn(p_id uuid, p_changes jsonb, p_reason text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_old pba_transactions; t pba_transactions;
BEGIN
  SELECT * INTO v_old FROM pba_transactions WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(v_old.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can edit transactions'; END IF;
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason for the change'; END IF;
  IF v_old.status <> 'active' THEN RAISE EXCEPTION 'A voided entry can''t be edited'; END IF;
  IF public._pba_month_closed(v_old.person_id, v_old.entry_date) THEN
    RAISE EXCEPTION '% is closed and sealed — record a reversing entry instead', to_char(v_old.entry_date, 'FMMonth YYYY');
  END IF;
  t := jsonb_populate_record(v_old, p_changes - ARRAY['id', 'org_id', 'person_id', 'status', 'void_reason', 'voided_by', 'voided_at',
         'reverses_id', 'flag_resolution', 'flag_resolved_by', 'flag_resolved_at', 'created_by', 'created_at', 'updated_at']);
  t.updated_at := now();
  PERFORM public._pba_check_txn(t);
  UPDATE pba_transactions SET
    account_id = t.account_id, entry_date = t.entry_date, type = t.type, amount = t.amount, to_account_id = t.to_account_id,
    payee = t.payee, category = t.category, beneficiary = t.beneficiary, beneficiary_name = t.beneficiary_name,
    beneficiary_relationship = t.beneficiary_relationship, purchased_by = t.purchased_by, purchased_by_staff_id = t.purchased_by_staff_id,
    handed_to = t.handed_to, handed_to_staff_id = t.handed_to_staff_id, handed_to_name = t.handed_to_name, purpose = t.purpose,
    request_id = t.request_id, notes = t.notes, updated_at = t.updated_at
   WHERE id = p_id;
  -- r1: the approval follows the entry (one entry per approval)
  IF v_old.request_id IS DISTINCT FROM t.request_id THEN
    IF v_old.request_id IS NOT NULL THEN
      UPDATE pba_purchase_requests SET status = 'approved' WHERE id = v_old.request_id AND status = 'spent';
    END IF;
    IF t.request_id IS NOT NULL THEN
      UPDATE pba_purchase_requests SET status = 'spent' WHERE id = t.request_id AND status = 'approved';
    END IF;
  END IF;
  PERFORM public._pba_audit(a.o_org, 'pba_txn_edited', 'pba_transactions', p_id, to_jsonb(v_old),
                            to_jsonb(t) || jsonb_build_object('edit_reason', p_reason));
END;
$$;


CREATE OR REPLACE FUNCTION public._pba_void_txn(p_id uuid, p_reason text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_old pba_transactions;
BEGIN
  SELECT * INTO v_old FROM pba_transactions WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(v_old.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can void transactions'; END IF;
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason for voiding'; END IF;
  IF v_old.status = 'voided' THEN RETURN; END IF;
  IF public._pba_month_closed(v_old.person_id, v_old.entry_date) THEN
    RAISE EXCEPTION '% is closed and sealed — record a reversing entry instead', to_char(v_old.entry_date, 'FMMonth YYYY');
  END IF;
  UPDATE pba_transactions SET status = 'voided', void_reason = p_reason, voided_by = p_actor, voided_at = now(), updated_at = now() WHERE id = p_id;
  IF v_old.request_id IS NOT NULL THEN                              -- r1: the approval is free again for the corrected entry
    UPDATE pba_purchase_requests SET status = 'approved' WHERE id = v_old.request_id AND status = 'spent';
  END IF;
  PERFORM public._pba_audit(a.o_org, 'pba_txn_voided', 'pba_transactions', p_id, to_jsonb(v_old), jsonb_build_object('void_reason', p_reason));
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
BEGIN
  SELECT p.org_id INTO v_org FROM persons p WHERE p.id = p_person;
  IF v_org IS NULL OR v_status IN ('none', 'ended') THEN RETURN; END IF;
  -- r1: read tolerantly (whole numbers, at least 1) so a stored value can never stop the flags loading
  v_tp_n    := greatest(1, floor(public._pba_setting_num(v_org, 'pba.third_party_count'))::integer);
  v_tp_amt  := greatest(0, public._pba_setting_num(v_org, 'pba.third_party_amount'));
  v_tp_days := greatest(1, floor(public._pba_setting_num(v_org, 'pba.third_party_days'))::integer);

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
END;
$$;


CREATE OR REPLACE FUNCTION public._pba_sign(p_form_type text, p_form_id uuid, p_signer_kind text, p_signer_name text, p_attestation text,
                                            p_drawn_file uuid, p_scan_file uuid, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_person uuid; v_content jsonb; v_capacity text; v_id uuid; v_purchaser uuid;
BEGIN
  IF length(btrim(coalesce(p_signer_name, ''))) = 0 OR length(btrim(coalesce(p_attestation, ''))) = 0 THEN
    RAISE EXCEPTION 'Type your name to sign';
  END IF;
  IF p_form_type = 'form_a' THEN
    SELECT d.person_id, to_jsonb(d) INTO v_person, v_content FROM pba_natural_support_determinations d WHERE d.id = p_form_id;
  ELSIF p_form_type = 'form_f' THEN
    SELECT f.person_id, to_jsonb(f), f.purchaser_staff_id INTO v_person, v_content, v_purchaser FROM pba_lost_receipt_affidavits f WHERE f.id = p_form_id;
  ELSE
    RAISE EXCEPTION 'Unknown form';
  END IF;
  IF v_person IS NULL THEN RAISE EXCEPTION 'That form doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(v_person, p_actor, p_actor_role);
  -- the purchaser signs their own affidavit even without PBA access to the Person
  IF NOT a.o_read AND NOT (p_form_type = 'form_f' AND p_actor = v_purchaser
                           AND EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = a.o_org AND s.is_active)) THEN
    RAISE EXCEPTION 'You can''t sign forms for this Person';
  END IF;

  IF p_form_type = 'form_a' THEN
    IF p_signer_kind = 'staff' THEN
      -- r1: the preparer is someone who may prepare Form A (owner, Compliance Director or the PBA Manager)
      IF NOT (a.o_owner OR a.o_cd OR a.o_write) THEN
        RAISE EXCEPTION 'Only the owner, the Compliance Director or this Person''s PBA Manager can sign Form A as its preparer';
      END IF;
      v_capacity := 'preparer';
    ELSIF p_signer_kind IN ('person', 'guardian') THEN
      v_capacity := p_signer_kind;
      IF p_drawn_file IS NULL AND p_scan_file IS NULL THEN RAISE EXCEPTION 'The signature needs to be drawn on screen or attached as a scan'; END IF;
    ELSE RAISE EXCEPTION 'Unknown signer'; END IF;
  ELSE
    IF p_signer_kind <> 'staff' THEN RAISE EXCEPTION 'The Lost Receipt Affidavit is signed by staff'; END IF;
    IF p_actor = v_purchaser THEN v_capacity := 'purchaser';
    ELSIF a.o_owner OR (a.o_cd AND coalesce(a.o_role, '') <> 'manager') THEN v_capacity := 'countersigner';
    ELSE RAISE EXCEPTION 'The countersignature is the Compliance Director''s — or the owner''s when the Compliance Director made the purchase or manages this Person''s money';
    END IF;
  END IF;
  IF (p_drawn_file IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = p_drawn_file AND f.person_id = v_person AND f.purpose = 'signature'))
     OR (p_scan_file IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = p_scan_file AND f.person_id = v_person AND f.purpose = 'form_scan')) THEN
    RAISE EXCEPTION 'That signature file isn''t on file for this Person';
  END IF;
  IF EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = p_form_type AND s.form_id = p_form_id AND s.capacity = v_capacity) THEN
    RAISE EXCEPTION 'This form already has that signature';
  END IF;
  INSERT INTO pba_signatures (org_id, person_id, form_type, form_id, capacity, signer_kind, signer_staff_id, signer_name, attestation,
                              content_sha256, drawn_file_id, scan_file_id, witnessed_by_staff_id)
  VALUES (a.o_org, v_person, p_form_type, p_form_id, v_capacity, p_signer_kind,
          CASE WHEN p_signer_kind = 'staff' THEN p_actor END, btrim(p_signer_name), p_attestation,
          encode(sha256(convert_to(v_content::text, 'UTF8')), 'hex'), p_drawn_file, p_scan_file,
          CASE WHEN p_signer_kind <> 'staff' THEN p_actor END)
  RETURNING id INTO v_id;
  PERFORM public._pba_audit(a.o_org, 'pba_form_signed', 'pba_signatures', v_id, NULL,
                            jsonb_build_object('form_type', p_form_type, 'form_id', p_form_id, 'capacity', v_capacity));
  RETURN v_id;
END;
$$;


CREATE OR REPLACE FUNCTION public._pba_save_account(p_id uuid, p_person uuid, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_old record;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_write OR a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only this Person''s PBA Manager, the owner or the Compliance Director can change accounts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pba_enrollments WHERE person_id = p_person) THEN RAISE EXCEPTION 'Start this Person''s PBA record first'; END IF;
  SELECT * INTO v_old FROM pba_accounts WHERE id = p_id;
  IF FOUND THEN
    IF v_old.person_id IS DISTINCT FROM p_person THEN RAISE EXCEPTION 'That account belongs to someone else'; END IF;
    -- r1: once any month is sealed, the opening balance and its date are part of a reviewed balance
    IF ((p_data ? 'opening_balance' AND (p_data->>'opening_balance')::numeric IS DISTINCT FROM v_old.opening_balance)
        OR (p_data ? 'opening_date' AND (nullif(p_data->>'opening_date', ''))::date IS DISTINCT FROM v_old.opening_date))
       AND EXISTS (SELECT 1 FROM pba_month_closes c WHERE c.person_id = p_person) THEN
      RAISE EXCEPTION 'A month is already closed for this Person, so the opening balance is sealed — correct it with an entry in an open month instead';
    END IF;
    UPDATE pba_accounts SET
      kind = coalesce(p_data->>'kind', kind), institution = CASE WHEN p_data ? 'institution' THEN nullif(btrim(p_data->>'institution'), '') ELSE institution END,
      last4 = CASE WHEN p_data ? 'last4' THEN nullif(btrim(p_data->>'last4'), '') ELSE last4 END,
      titling = coalesce(nullif(btrim(p_data->>'titling'), ''), titling),
      supervising_institution = CASE WHEN p_data ? 'supervising_institution' THEN nullif(btrim(p_data->>'supervising_institution'), '') ELSE supervising_institution END,
      opening_balance = coalesce((p_data->>'opening_balance')::numeric, opening_balance),
      opening_date = CASE WHEN p_data ? 'opening_date' THEN (nullif(p_data->>'opening_date', ''))::date ELSE opening_date END,
      opened_on = CASE WHEN p_data ? 'opened_on' THEN (nullif(p_data->>'opened_on', ''))::date ELSE opened_on END,
      closed_on = CASE WHEN p_data ? 'closed_on' THEN (nullif(p_data->>'closed_on', ''))::date ELSE closed_on END,
      not_provider_funds_attested = coalesce((p_data->>'not_provider_funds_attested')::boolean, not_provider_funds_attested),
      updated_at = now()
     WHERE id = p_id;
    PERFORM public._pba_audit(a.o_org, 'pba_account_changed', 'pba_accounts', p_id, to_jsonb(v_old), p_data);
  ELSE
    INSERT INTO pba_accounts (id, org_id, person_id, kind, institution, last4, titling, holding, supervising_institution,
                              opening_balance, opening_date, opened_on, not_provider_funds_attested, created_by)
    VALUES (p_id, a.o_org, p_person, p_data->>'kind', nullif(btrim(p_data->>'institution'), ''), nullif(btrim(p_data->>'last4'), ''),
            coalesce(btrim(p_data->>'titling'), ''), 'individual', nullif(btrim(p_data->>'supervising_institution'), ''),
            coalesce((p_data->>'opening_balance')::numeric, 0), (nullif(p_data->>'opening_date', ''))::date,
            (nullif(p_data->>'opened_on', ''))::date, coalesce((p_data->>'not_provider_funds_attested')::boolean, false), p_actor);
    PERFORM public._pba_audit(a.o_org, 'pba_account_added', 'pba_accounts', p_id, NULL, p_data);
  END IF;
  RETURN p_id;
END;
$$;


CREATE OR REPLACE FUNCTION public._set_org_setting(p_key text, p_value jsonb, p_actor uuid, p_actor_role text, p_org uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF coalesce(p_actor_role, '') NOT IN ('owner', 'compliance_director') OR p_org IS NULL
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = p_org AND s.is_active) THEN
    RAISE EXCEPTION 'Only the owner or the Compliance Director can change provider settings';
  END IF;
  IF public.provly_setting(p_org, p_key) IS NULL THEN RAISE EXCEPTION 'Unknown setting %', p_key; END IF;
  IF jsonb_typeof(p_value) <> 'number' THEN RAISE EXCEPTION 'The setting needs a number'; END IF;
  -- r1: counts and day windows are whole numbers of at least 1; amounts are zero or more
  IF p_key ~ '(count|days)$' AND ((p_value::text)::numeric <> floor((p_value::text)::numeric) OR (p_value::text)::numeric < 1) THEN
    RAISE EXCEPTION 'This setting needs a whole number of 1 or more';
  END IF;
  IF (p_value::text)::numeric < 0 THEN RAISE EXCEPTION 'The setting needs a number of zero or more'; END IF;
  INSERT INTO org_settings (org_id, key, value, updated_by, updated_at) VALUES (p_org, p_key, p_value, p_actor, now())
  ON CONFLICT (org_id, key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM public._pba_audit(p_org, 'org_setting_saved', 'org_settings', p_org, NULL, jsonb_build_object('key', p_key, 'value', p_value));
END;
$$;


-- 7. staff-level flags (owner and Compliance Director): the affidavit pattern
CREATE OR REPLACE FUNCTION public._pba_staff_flags(p_org uuid, p_today date DEFAULT NULL)
RETURNS TABLE (o_staff_id uuid, o_staff_name text, o_flag text, o_detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_today date := coalesce(p_today, public._pba_today());
  v_n     integer := greatest(1, floor(coalesce(public._pba_setting_num(p_org, 'pba.affidavit_count'), 3))::integer);
  v_days  integer := greatest(1, floor(coalesce(public._pba_setting_num(p_org, 'pba.affidavit_days'), 90))::integer);
BEGIN
  RETURN QUERY
  SELECT x.purchaser_staff_id, (s.first_name || ' ' || s.last_name)::text, 'affidavit_pattern'::text,
         format('%s Lost Receipt Affidavits in the last %s days (for %s Person%s) — corrective action review',
                x.n, v_days, x.persons, CASE WHEN x.persons = 1 THEN '' ELSE 's' END)
    FROM (SELECT a.purchaser_staff_id, count(*)::integer AS n, count(DISTINCT a.person_id)::integer AS persons
            FROM pba_lost_receipt_affidavits a
           WHERE a.org_id = p_org AND a.purchase_date > v_today - v_days
           GROUP BY a.purchaser_staff_id) x
    JOIN staff s ON s.id = x.purchaser_staff_id
   WHERE x.n >= v_n
   ORDER BY 2;
END;
$$;

CREATE OR REPLACE FUNCTION public.pba_staff_flags()
RETURNS TABLE (o_staff_id uuid, o_staff_name text, o_flag text, o_detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF coalesce(public.member_role()::text, '') NOT IN ('owner', 'compliance_director') OR public.org_id() IS NULL THEN RETURN; END IF;
  RETURN QUERY SELECT f.o_staff_id, f.o_staff_name, f.o_flag, f.o_detail FROM public._pba_staff_flags(public.org_id()) f;
END;
$$;

-- 3. the purchaser's own affidavits awaiting their signature (no PBA role needed)
CREATE OR REPLACE FUNCTION public._pba_affidavits_to_sign(p_actor uuid)
RETURNS TABLE (o_affidavit_id uuid, o_person_name text, o_store text, o_amount numeric, o_purchase_date date, o_reason text, o_statement_line_ref text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT a.id, btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, ''))::text, a.store, a.amount, a.purchase_date, a.reason, a.statement_line_ref
    FROM pba_lost_receipt_affidavits a JOIN persons p ON p.id = a.person_id
   WHERE p_actor IS NOT NULL AND a.purchaser_staff_id = p_actor
     AND NOT EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = 'form_f' AND s.form_id = a.id AND s.capacity = 'purchaser')
   ORDER BY a.purchase_date
$$;
CREATE OR REPLACE FUNCTION public.pba_affidavits_to_sign()
RETURNS TABLE (o_affidavit_id uuid, o_person_name text, o_store text, o_amount numeric, o_purchase_date date, o_reason text, o_statement_line_ref text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT * FROM public._pba_affidavits_to_sign(public.my_staff_id())
$$;

-- privileges
REVOKE ALL ON FUNCTION public._pba_setting_num(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_staff_flags(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_affidavits_to_sign(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_check_txn(public.pba_transactions) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_edit_txn(uuid, jsonb, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_void_txn(uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_flags(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_sign(text, uuid, text, text, text, uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_save_account(uuid, uuid, jsonb, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._set_org_setting(text, jsonb, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pba_staff_flags() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pba_staff_flags() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.pba_affidavits_to_sign() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pba_affidavits_to_sign() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ── Self-test (synthetic, 2001 dates), rolled back ───────────────────────
CREATE TEMP TABLE IF NOT EXISTS v20029r1_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20029r1_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20029r1_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.29r1 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res jsonb := '[]'::jsonb; v_fail text; v_step text := 'setup';
  v_org uuid; v_person uuid; v_p2 uuid;
  s_owner uuid; s_cd uuid; s_mgr uuid; s_rev uuid; s_dsp uuid;
  v_bank uuid := gen_random_uuid(); v_old uuid := gen_random_uuid();
  q1 uuid := gen_random_uuid(); t1 uuid := gen_random_uuid(); t2 uuid := gen_random_uuid(); t3 uuid := gen_random_uuid();
  t4 uuid := gen_random_uuid(); tr uuid := gen_random_uuid();
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
  v_formA uuid; v_today date := DATE '2001-01-20';
  v_msg text; v_txt text; v_n integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s.org_id INTO v_org FROM staff s ORDER BY s.created_at NULLS LAST, s.id LIMIT 1;
  BEGIN
    v_person := pg_temp.v20029r1_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20029R1', 'last_name', 'Selftest', 'identification_number', '099999932', 'is_active', true));
    v_p2     := pg_temp.v20029r1_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20029R1', 'last_name', 'Second', 'identification_number', '099999933', 'is_active', true));
    s_owner := pg_temp.v20029r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R1test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20029r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R1test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20029r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R1test', 'last_name', 'Manager'));
    s_rev   := pg_temp.v20029r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R1test', 'last_name', 'Reviewer'));
    s_dsp   := pg_temp.v20029r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R1test', 'last_name', 'Dsp'));
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    PERFORM public._pba_start(v_p2, 'voluntary', s_owner, 'owner');
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    PERFORM public._pba_assign_role(v_person, s_rev, 'reviewer', s_cd, 'compliance_director');
    PERFORM public._pba_assign_role(v_p2, s_mgr, 'manager', s_cd, 'compliance_director');
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20029R1 Selftest', 'opening_balance', 500, 'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');
    PERFORM public._pba_save_account(v_old, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20029R1 Selftest (old)', 'not_provider_funds_attested', true), s_mgr, 'dsp');

    -- R1: a linked request must be the approval for this purchase
    v_step := 'R1 request links';
    PERFORM public._pba_request(q1, v_person, jsonb_build_object('amount', 63.40, 'payee', 'Pharmacy', 'category', 'medical', 'beneficiary', 'other',
              'beneficiary_name', 'Girlfriend', 'person_choice', 'He asked to buy medicine for his girlfriend'), s_mgr, 'dsp');
    PERFORM public._pba_decide(q1, true, '{"food": true, "shelter": true, "clothing": true, "medical": true}'::jsonb, NULL, s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_record_txn(gen_random_uuid(), v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-10', 'type', 'withdrawal',
              'amount', 40, 'beneficiary', 'other', 'beneficiary_name', 'Cousin', 'category', 'gift', 'request_id', q1), s_mgr, 'dsp'); v_msg := 'other beneficiary ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'other beneficiary refused'; END;
    BEGIN PERFORM public._pba_record_txn(gen_random_uuid(), v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-10', 'type', 'withdrawal',
              'amount', 90, 'beneficiary', 'other', 'beneficiary_name', 'girlfriend', 'request_id', q1), s_mgr, 'dsp'); v_msg := v_msg || '; over the amount ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; over the amount refused'; END;
    PERFORM public._pba_record_txn(t1, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-10', 'type', 'withdrawal',
              'amount', 63.40, 'beneficiary', 'other', 'beneficiary_name', ' girlfriend ', 'category', 'medical', 'request_id', q1), s_mgr, 'dsp');
    BEGIN PERFORM public._pba_record_txn(gen_random_uuid(), v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-11', 'type', 'withdrawal',
              'amount', 10, 'beneficiary', 'other', 'beneficiary_name', 'Girlfriend', 'request_id', q1), s_mgr, 'dsp'); v_msg := v_msg || '; reused ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; reused refused'; END;
    PERFORM public._pba_void_txn(t1, 'Wrong account', s_mgr, 'dsp');
    v_msg := v_msg || '; after void ' || (SELECT status FROM pba_purchase_requests WHERE id = q1);
    PERFORM public._pba_record_txn(t2, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-12', 'type', 'withdrawal',
              'amount', 63.40, 'beneficiary', 'other', 'beneficiary_name', 'Girlfriend', 'category', 'medical', 'request_id', q1), s_mgr, 'dsp');
    v_msg := v_msg || '; relinked ' || (SELECT status FROM pba_purchase_requests WHERE id = q1);
    PERFORM public._pba_record_txn(t3, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-13', 'type', 'withdrawal',
              'amount', 25, 'beneficiary', 'other', 'beneficiary_name', 'Girlfriend', 'category', 'gift'), s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'recorded_over_block';
    v_res := v_res || jsonb_build_array(jsonb_build_array(1,
      'R1 request links: another beneficiary, over the amount, valid, reused, void frees it, relinked; an unlinked gift',
      v_msg || '; over-block flags ' || v_n,
      'other beneficiary refused; over the amount refused; reused refused; after void approved; relinked spent; over-block flags 1'));

    -- R2: only a preparer can sign Form A as its preparer
    v_step := 'R2 Form A preparer';
    v_formA := public._pba_save_form_a(v_person, '[{"name": "Mother", "relationship": "mother", "reason": "Declined"}]'::jsonb, s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_sign('form_a', v_formA, 'staff', 'R1test Reviewer', 'I prepared this', NULL, NULL, s_rev, 'dsp'); v_msg := 'reviewer ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'reviewer refused'; END;
    PERFORM public._pba_sign('form_a', v_formA, 'staff', 'R1test Manager', 'I prepared this', NULL, NULL, s_mgr, 'dsp');
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'R2 Form A signed as preparer by the reviewer, then by the PBA Manager',
      v_msg || '; signatures ' || (SELECT count(*) FROM pba_signatures WHERE form_id = v_formA), 'reviewer refused; signatures 1'));

    -- R3: the purchaser's affidavits to sign, without any PBA role
    v_step := 'R3 affidavits to sign';
    PERFORM public._pba_record_txn(t4, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-14', 'type', 'withdrawal', 'amount', 80,
              'payee', 'Store', 'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    PERFORM public._pba_file_affidavit(a1, t4, jsonb_build_object('store', 'Store', 'reason', 'Lost'), s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_affidavits_to_sign(s_dsp);
    v_txt := 'before ' || v_n;
    PERFORM public._pba_sign('form_f', a1, 'staff', 'R1test Dsp', 'I made this purchase', NULL, NULL, s_dsp, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_affidavits_to_sign(s_dsp);
    v_txt := v_txt || ', after signing ' || v_n || ', for others ' || (SELECT count(*) FROM public._pba_affidavits_to_sign(s_rev));
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'R3 a DSP purchaser with no PBA role: affidavits awaiting their signature', v_txt, 'before 1, after signing 0, for others 0'));

    -- R4 + R5: sealed opening balance; a reversal after the account closed
    v_step := 'R4 R5 seal and closed account';
    PERFORM public._pba_record_txn(tr, v_person, jsonb_build_object('account_id', v_old, 'entry_date', '2001-01-05', 'type', 'deposit', 'amount', 30), s_mgr, 'dsp');
    PERFORM public._pba_save_account(v_old, v_person, jsonb_build_object('closed_on', '2001-01-31'), s_mgr, 'dsp');
    INSERT INTO pba_month_closes (org_id, person_id, month) VALUES (v_org, v_person, DATE '2001-01-01');
    v_msg := '';
    BEGIN PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('opening_balance', 600), s_mgr, 'dsp'); v_msg := 'opening balance ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'opening balance refused'; END;
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('institution', 'Zions Bank'), s_mgr, 'dsp');
    v_msg := v_msg || '; institution ' || (SELECT institution FROM pba_accounts WHERE id = v_bank);
    PERFORM public._pba_reverse_txn(gen_random_uuid(), tr, 'Deposit belonged to another account', s_mgr, 'dsp');
    v_msg := v_msg || '; reversal on the closed account ' || CASE WHEN EXISTS (SELECT 1 FROM pba_transactions WHERE reverses_id = tr) THEN 'recorded' ELSE 'MISSING' END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'R4/R5 after January seals: opening balance, institution, a reversal on a closed account',
      v_msg, 'opening balance refused; institution Zions Bank; reversal on the closed account recorded'));

    -- R6: settings — whole numbers for counts and windows
    v_step := 'R6 settings';
    v_msg := '';
    BEGIN PERFORM public._set_org_setting('pba.third_party_count', '1.5'::jsonb, s_owner, 'owner', v_org); v_msg := '1.5 ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := '1.5 refused'; END;
    BEGIN PERFORM public._set_org_setting('pba.affidavit_days', '0'::jsonb, s_owner, 'owner', v_org); v_msg := v_msg || '; 0 days ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; 0 days refused'; END;
    PERFORM public._set_org_setting('pba.third_party_amount', '120.5'::jsonb, s_owner, 'owner', v_org);
    -- a bad value that slipped in some other way still can't stop the flags
    INSERT INTO org_settings (org_id, key, value) VALUES (v_org, 'pba.third_party_days', '2.7'::jsonb)
      ON CONFLICT (org_id, key) DO UPDATE SET value = EXCLUDED.value;
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today);
    v_res := v_res || jsonb_build_array(jsonb_build_array(5, 'R6 settings: 1.5 as a count, 0 days, 120.5 as an amount; flags still load with a stored 2.7',
      v_msg || '; amount ' || (SELECT value::text FROM org_settings WHERE org_id = v_org AND key = 'pba.third_party_amount') || '; flags load ' || (v_n >= 0)::text,
      '1.5 refused; 0 days refused; amount 120.5; flags load true'));

    -- R7: the affidavit pattern is about the staff member, not the Person
    v_step := 'R7 staff flags';
    PERFORM public._pba_save_account(gen_random_uuid(), v_p2, jsonb_build_object('kind', 'bank', 'titling', 'V20029R1 Second', 'not_provider_funds_attested', true), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(gen_random_uuid(), v_p2, jsonb_build_object('account_id', (SELECT id FROM pba_accounts WHERE person_id = v_p2 LIMIT 1),
              'entry_date', '2001-01-15', 'type', 'withdrawal', 'amount', 70, 'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    PERFORM public._pba_file_affidavit(a2, (SELECT id FROM pba_transactions WHERE person_id = v_p2 LIMIT 1), jsonb_build_object('store', 'Store', 'reason', 'Lost'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(gen_random_uuid(), v_p2, jsonb_build_object('account_id', (SELECT id FROM pba_accounts WHERE person_id = v_p2 LIMIT 1),
              'entry_date', '2001-01-16', 'type', 'withdrawal', 'amount', 75, 'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    PERFORM public._pba_file_affidavit(a3, (SELECT id FROM pba_transactions WHERE person_id = v_p2 AND amount = 75 LIMIT 1), jsonb_build_object('store', 'Store', 'reason', 'Lost'), s_mgr, 'dsp');
    SELECT string_agg(f.o_staff_name || ': ' || f.o_detail, ' | ') INTO v_txt FROM public._pba_staff_flags(v_org, v_today) f WHERE f.o_staff_id = s_dsp;
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'affidavit_pattern';
    v_res := v_res || jsonb_build_array(jsonb_build_array(6, 'R7 one DSP, three affidavits across two Persons: the staff flag, and the Person''s own flags',
      coalesce(v_txt, 'no staff flag') || ' · on the Person ' || v_n,
      'R1test Dsp: 3 Lost Receipt Affidavits in the last 90 days (for 2 Persons) — corrective action review · on the Person 0'));

    RAISE EXCEPTION 'v20029r1_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20029r1_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 6 THEN
    RAISE EXCEPTION 'v20.0.29 r1 self-test failed, so nothing in this file was applied: %', coalesce(v_fail, format('%s of 6 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20029r1_selftest (n, item, value, want) SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20029r1_test_insert(text, jsonb);

COMMIT;


-- ── Verification — paste this table into chat before the PR merges ─────
SELECT * FROM (
  SELECT 1 AS n, 'one active entry per purchase request (unique index)' AS check_item,
    (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'pba_txn_one_per_request')::text AS value, '1' AS want
  UNION ALL
  SELECT 2, 'new functions: staff flags + affidavits to sign callable by signed-in users, internals not',
    (has_function_privilege('authenticated', 'public.pba_staff_flags()', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.pba_affidavits_to_sign()', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._pba_staff_flags(uuid,date)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._pba_setting_num(uuid,text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.pba_affidavits_to_sign()', 'EXECUTE'))::text, 'true'
  UNION ALL
  SELECT 3, 'the per-Person flags no longer compute the affidavit pattern',
    ((SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_flags(uuid,date)'::regprocedure) NOT LIKE '%''affidavit_pattern''::text,%')::text, 'true'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20029r1_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test',
    ((SELECT count(*) FROM public.persons WHERE identification_number IN ('099999932', '099999933'))
     + (SELECT count(*) FROM public.staff WHERE first_name = 'R1test'))::text, '0'
) v ORDER BY n;
