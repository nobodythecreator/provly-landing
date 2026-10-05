-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.29 r2 — PBA hardening (Greptile r2; v20.0.29 and r1 already ran, so this is a new migration)
--   1 An approval's state is derived, not toggled: 'spent' exactly while an active original entry
--     spends it (_pba_sync_request). Edits, voids and reversals lock the entry row (FOR UPDATE) and
--     re-derive every approval they touch; recording or re-linking locks the approval first. A
--     concurrent edit-and-void now serializes, so no approval is left spent with no entry.
--   2 Settings have upper bounds (counts ≤ 1,000, windows ≤ 3,650 days, amounts ≤ $1,000,000), and the
--     flags clamp before casting, so no stored value can stop the flag views loading.
--   3 An affidavit whose purchase was voided, reversed or has since got its receipt drops off the
--     purchaser's to-sign list, and signing it is refused.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; a self-test runs and is
-- rolled back; any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public._pba_affidavits_to_sign(uuid)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.29 r2 stopped before changing anything — run sql/v20.0.29r1_pba.sql first. Paste this message into chat.';
  END IF;
END $$;

-- the approval's state is derived from the ledger: 'spent' exactly while an active, original entry
-- spends it; otherwise 'approved'. Every write that touches a link re-derives it, so concurrent
-- edits and voids can never leave an approval spent with no entry (or free with one).
CREATE OR REPLACE FUNCTION public._pba_sync_request(p_request uuid)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  UPDATE pba_purchase_requests q
     SET status = CASE WHEN EXISTS (SELECT 1 FROM pba_transactions x
                                     WHERE x.request_id = q.id AND x.status = 'active' AND x.reverses_id IS NULL)
                       THEN 'spent' ELSE 'approved' END
   WHERE q.id = p_request AND q.status IN ('approved', 'spent')
$$;

CREATE OR REPLACE FUNCTION public._pba_record_txn(p_id uuid, p_person uuid, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; t pba_transactions;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can record transactions'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pba_enrollments WHERE person_id = p_person AND ended_on IS NULL) THEN RAISE EXCEPTION 'Start this Person''s PBA record first'; END IF;
  IF EXISTS (SELECT 1 FROM pba_transactions x WHERE x.id = p_id) THEN
    IF EXISTS (SELECT 1 FROM pba_transactions x WHERE x.id = p_id AND x.person_id = p_person) THEN RETURN p_id; END IF;
    RAISE EXCEPTION 'That entry id is already used';
  END IF;
  t := jsonb_populate_record(NULL::pba_transactions, p_data - ARRAY['id', 'org_id', 'person_id', 'status', 'void_reason', 'voided_by', 'voided_at',
         'reverses_id', 'flag_resolution', 'flag_resolved_by', 'flag_resolved_at', 'created_by', 'created_at', 'updated_at']);
  t.id := p_id; t.org_id := a.o_org; t.person_id := p_person; t.status := 'active';
  t.beneficiary := coalesce(t.beneficiary, 'person'); t.created_by := p_actor; t.created_at := now(); t.updated_at := now();
  -- r2: lock the approval this entry would spend, so two entries can't both pass the check
  IF t.request_id IS NOT NULL THEN PERFORM 1 FROM pba_purchase_requests WHERE id = t.request_id FOR UPDATE; END IF;
  PERFORM public._pba_check_txn(t);
  INSERT INTO pba_transactions VALUES (t.*);
  IF t.request_id IS NOT NULL THEN PERFORM public._pba_sync_request(t.request_id); END IF;
  PERFORM public._pba_audit(a.o_org, 'pba_txn_recorded', 'pba_transactions', p_id, NULL, to_jsonb(t));
  RETURN p_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_edit_txn(p_id uuid, p_changes jsonb, p_reason text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_old pba_transactions; t pba_transactions;
BEGIN
  SELECT * INTO v_old FROM pba_transactions WHERE id = p_id FOR UPDATE;     -- r2: one change to an entry at a time
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
  IF t.request_id IS NOT NULL AND t.request_id IS DISTINCT FROM v_old.request_id THEN
    PERFORM 1 FROM pba_purchase_requests WHERE id = t.request_id FOR UPDATE;
  END IF;
  PERFORM public._pba_check_txn(t);
  UPDATE pba_transactions SET
    account_id = t.account_id, entry_date = t.entry_date, type = t.type, amount = t.amount, to_account_id = t.to_account_id,
    payee = t.payee, category = t.category, beneficiary = t.beneficiary, beneficiary_name = t.beneficiary_name,
    beneficiary_relationship = t.beneficiary_relationship, purchased_by = t.purchased_by, purchased_by_staff_id = t.purchased_by_staff_id,
    handed_to = t.handed_to, handed_to_staff_id = t.handed_to_staff_id, handed_to_name = t.handed_to_name, purpose = t.purpose,
    request_id = t.request_id, notes = t.notes, updated_at = t.updated_at
   WHERE id = p_id;
  -- r2: both approvals' states are re-derived from the ledger
  IF v_old.request_id IS NOT NULL THEN PERFORM public._pba_sync_request(v_old.request_id); END IF;
  IF t.request_id IS NOT NULL AND t.request_id IS DISTINCT FROM v_old.request_id THEN PERFORM public._pba_sync_request(t.request_id); END IF;
  PERFORM public._pba_audit(a.o_org, 'pba_txn_edited', 'pba_transactions', p_id, to_jsonb(v_old),
                            to_jsonb(t) || jsonb_build_object('edit_reason', p_reason));
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_void_txn(p_id uuid, p_reason text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_old pba_transactions;
BEGIN
  SELECT * INTO v_old FROM pba_transactions WHERE id = p_id FOR UPDATE;     -- r2: one change to an entry at a time
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(v_old.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can void transactions'; END IF;
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason for voiding'; END IF;
  IF v_old.status = 'voided' THEN RETURN; END IF;
  IF public._pba_month_closed(v_old.person_id, v_old.entry_date) THEN
    RAISE EXCEPTION '% is closed and sealed — record a reversing entry instead', to_char(v_old.entry_date, 'FMMonth YYYY');
  END IF;
  UPDATE pba_transactions SET status = 'voided', void_reason = p_reason, voided_by = p_actor, voided_at = now(), updated_at = now() WHERE id = p_id;
  IF v_old.request_id IS NOT NULL THEN PERFORM public._pba_sync_request(v_old.request_id); END IF;   -- r2: derived, under the lock
  PERFORM public._pba_audit(a.o_org, 'pba_txn_voided', 'pba_transactions', p_id, to_jsonb(v_old), jsonb_build_object('void_reason', p_reason));
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_reverse_txn(p_new_id uuid, p_id uuid, p_reason text, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_old pba_transactions; t pba_transactions;
BEGIN
  IF EXISTS (SELECT 1 FROM pba_transactions x WHERE x.id = p_new_id AND x.reverses_id = p_id) THEN RETURN p_new_id; END IF;
  SELECT * INTO v_old FROM pba_transactions WHERE id = p_id FOR UPDATE;     -- r2: one change to an entry at a time
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(v_old.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can reverse transactions'; END IF;
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason for the reversal'; END IF;
  IF v_old.status <> 'active' OR v_old.reverses_id IS NOT NULL THEN RAISE EXCEPTION 'Only an active, original entry can be reversed'; END IF;
  IF EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = p_id AND r.status = 'active') THEN RAISE EXCEPTION 'That entry is already reversed'; END IF;
  t := v_old;
  t.id := p_new_id; t.entry_date := public._pba_today(); t.reverses_id := p_id; t.request_id := NULL;
  t.notes := 'Reverses the ' || to_char(v_old.entry_date, 'FMMM/FMDD/YYYY') || ' entry: ' || p_reason;
  t.flag_resolution := NULL; t.flag_resolved_by := NULL; t.flag_resolved_at := NULL;
  t.created_by := p_actor; t.created_at := now(); t.updated_at := now();
  PERFORM public._pba_check_txn(t);
  INSERT INTO pba_transactions VALUES (t.*);
  PERFORM public._pba_audit(a.o_org, 'pba_txn_reversed', 'pba_transactions', p_new_id, to_jsonb(v_old), to_jsonb(t));
  RETURN p_new_id;
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
  -- r2: upper bounds — a count up to 1,000, a window up to 3,650 days (ten years), an amount up to $1,000,000
  IF (p_key ~ 'count$' AND (p_value::text)::numeric > 1000) OR (p_key ~ 'days$' AND (p_value::text)::numeric > 3650)
     OR (p_key ~ 'amount$' AND (p_value::text)::numeric > 1000000) THEN
    RAISE EXCEPTION 'That value is out of range (counts up to 1,000; days up to 3,650; amounts up to $1,000,000)';
  END IF;
  INSERT INTO org_settings (org_id, key, value, updated_by, updated_at) VALUES (p_org, p_key, p_value, p_actor, now())
  ON CONFLICT (org_id, key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM public._pba_audit(p_org, 'org_setting_saved', 'org_settings', p_org, NULL, jsonb_build_object('key', p_key, 'value', p_value));
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
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_staff_flags(p_org uuid, p_today date DEFAULT NULL)
RETURNS TABLE (o_staff_id uuid, o_staff_name text, o_flag text, o_detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_today date := coalesce(p_today, public._pba_today());
  v_n     integer := least(greatest(floor(coalesce(public._pba_setting_num(p_org, 'pba.affidavit_count'), 3)), 1), 1000)::integer;
  v_days  integer := least(greatest(floor(coalesce(public._pba_setting_num(p_org, 'pba.affidavit_days'), 90)), 1), 3650)::integer;
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

CREATE OR REPLACE FUNCTION public._pba_affidavits_to_sign(p_actor uuid)
RETURNS TABLE (o_affidavit_id uuid, o_person_name text, o_store text, o_amount numeric, o_purchase_date date, o_reason text, o_statement_line_ref text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT a.id, btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, ''))::text, a.store, a.amount, a.purchase_date, a.reason, a.statement_line_ref
    FROM pba_lost_receipt_affidavits a JOIN persons p ON p.id = a.person_id
    JOIN pba_transactions t ON t.id = a.transaction_id
   WHERE p_actor IS NOT NULL AND a.purchaser_staff_id = p_actor
     AND public._pba_needs_receipt(t)                                        -- r2: not voided, not reversed
     AND NOT EXISTS (SELECT 1 FROM pba_receipts r WHERE r.transaction_id = t.id)
     AND NOT EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = 'form_f' AND s.form_id = a.id AND s.capacity = 'purchaser')
   ORDER BY a.purchase_date
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
    -- r2: an affidavit for a voided or reversed purchase, or one that now has its receipt, is not signed
    IF NOT EXISTS (SELECT 1 FROM pba_lost_receipt_affidavits f JOIN pba_transactions t ON t.id = f.transaction_id
                    WHERE f.id = p_form_id AND public._pba_needs_receipt(t)
                      AND NOT EXISTS (SELECT 1 FROM pba_receipts r WHERE r.transaction_id = t.id)) THEN
      RAISE EXCEPTION 'This purchase no longer needs a receipt (it was voided, reversed, or the receipt was attached) — nothing to sign';
    END IF;
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


REVOKE ALL ON FUNCTION public._pba_sync_request(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_record_txn(uuid, uuid, jsonb, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_edit_txn(uuid, jsonb, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_void_txn(uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_reverse_txn(uuid, uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._set_org_setting(text, jsonb, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_flags(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_staff_flags(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_affidavits_to_sign(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pba_sign(text, uuid, text, text, text, uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- an approval left out of step by the earlier code is put right now
UPDATE public.pba_purchase_requests q
   SET status = CASE WHEN EXISTS (SELECT 1 FROM public.pba_transactions x WHERE x.request_id = q.id AND x.status = 'active' AND x.reverses_id IS NULL)
                     THEN 'spent' ELSE 'approved' END
 WHERE q.status IN ('approved', 'spent');

NOTIFY pgrst, 'reload schema';

CREATE TEMP TABLE IF NOT EXISTS v20029r2_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20029r2_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20029r2_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.29r2 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res jsonb := '[]'::jsonb; v_fail text; v_step text := 'setup';
  v_org uuid; v_person uuid; s_owner uuid; s_cd uuid; s_mgr uuid; s_dsp uuid;
  v_bank uuid := gen_random_uuid(); qa uuid := gen_random_uuid(); qb uuid := gen_random_uuid();
  t1 uuid := gen_random_uuid(); t2 uuid := gen_random_uuid(); af uuid := gen_random_uuid();
  v_today date := DATE '2001-01-20'; v_msg text; v_n integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s.org_id INTO v_org FROM staff s ORDER BY s.created_at NULLS LAST, s.id LIMIT 1;
  BEGIN
    v_person := pg_temp.v20029r2_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20029R2', 'last_name', 'Selftest', 'identification_number', '099999934', 'is_active', true));
    s_owner := pg_temp.v20029r2_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R2test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20029r2_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R2test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20029r2_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R2test', 'last_name', 'Manager'));
    s_dsp   := pg_temp.v20029r2_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R2test', 'last_name', 'Dsp'));
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20029R2 Selftest', 'opening_balance', 500, 'not_provider_funds_attested', true), s_mgr, 'dsp');

    -- S1: relink A → B, then void: neither approval is left spent without an entry
    v_step := 'S1 relink + void';
    PERFORM public._pba_request(qa, v_person, jsonb_build_object('amount', 50, 'beneficiary', 'other', 'beneficiary_name', 'Friend', 'person_choice', 'A gift', 'category', 'gift'), s_mgr, 'dsp');
    PERFORM public._pba_request(qb, v_person, jsonb_build_object('amount', 50, 'beneficiary', 'other', 'beneficiary_name', 'Friend', 'person_choice', 'A gift', 'category', 'gift'), s_mgr, 'dsp');
    PERFORM public._pba_decide(qa, true, '{"food": true, "shelter": true, "clothing": true, "medical": true}'::jsonb, NULL, s_mgr, 'dsp');
    PERFORM public._pba_decide(qb, true, '{"food": true, "shelter": true, "clothing": true, "medical": true}'::jsonb, NULL, s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t1, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-10', 'type', 'withdrawal', 'amount', 40,
              'beneficiary', 'other', 'beneficiary_name', 'Friend', 'category', 'gift', 'request_id', qa), s_mgr, 'dsp');
    v_msg := 'linked A ' || (SELECT status FROM pba_purchase_requests WHERE id = qa);
    PERFORM public._pba_edit_txn(t1, jsonb_build_object('request_id', qb), 'Belongs to the second approval', s_mgr, 'dsp');
    v_msg := v_msg || '; relinked A ' || (SELECT status FROM pba_purchase_requests WHERE id = qa) || ' B ' || (SELECT status FROM pba_purchase_requests WHERE id = qb);
    PERFORM public._pba_void_txn(t1, 'Entered in error', s_mgr, 'dsp');
    v_msg := v_msg || '; voided A ' || (SELECT status FROM pba_purchase_requests WHERE id = qa) || ' B ' || (SELECT status FROM pba_purchase_requests WHERE id = qb);
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'S1 link A, relink to B, then void', v_msg,
      'linked A spent; relinked A approved B spent; voided A approved B approved'));

    -- S2: an approval out of step with the ledger is put right by deriving it
    v_step := 'S2 derived state';
    UPDATE pba_purchase_requests SET status = 'spent' WHERE id = qa;          -- as the old toggling code could leave it
    PERFORM public._pba_sync_request(qa);
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'S2 an approval marked spent with no entry, re-derived',
      (SELECT status FROM pba_purchase_requests WHERE id = qa), 'approved'));

    -- S3: settings bounds; flags survive an out-of-range stored value
    v_step := 'S3 settings';
    v_msg := '';
    BEGIN PERFORM public._set_org_setting('pba.third_party_days', '5000'::jsonb, s_owner, 'owner', v_org); v_msg := '5000 days ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := '5000 days refused'; END;
    BEGIN PERFORM public._set_org_setting('pba.affidavit_count', '3000000000'::jsonb, s_owner, 'owner', v_org); v_msg := v_msg || '; 3 billion ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; 3 billion refused'; END;
    PERFORM public._set_org_setting('pba.third_party_days', '3650'::jsonb, s_owner, 'owner', v_org);
    INSERT INTO org_settings (org_id, key, value) VALUES (v_org, 'pba.third_party_count', '99999999999999'::jsonb), (v_org, 'pba.affidavit_days', '99999999999'::jsonb)
      ON CONFLICT (org_id, key) DO UPDATE SET value = EXCLUDED.value;
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today);
    v_msg := v_msg || '; 3650 ok; flags load ' || (v_n >= 0)::text;
    SELECT count(*) INTO v_n FROM public._pba_staff_flags(v_org, v_today);
    v_msg := v_msg || '; staff flags load ' || (v_n >= 0)::text;
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'S3 settings: 5,000 days, a 3-billion count, 3,650 days; flags with huge stored values',
      v_msg, '5000 days refused; 3 billion refused; 3650 ok; flags load true; staff flags load true'));

    -- S4: an affidavit for a voided purchase is no longer asked for, and can't be signed
    v_step := 'S4 obsolete affidavit';
    PERFORM public._pba_record_txn(t2, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-12', 'type', 'withdrawal', 'amount', 80,
              'payee', 'Store', 'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    PERFORM public._pba_file_affidavit(af, t2, jsonb_build_object('store', 'Store', 'reason', 'Lost'), s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_affidavits_to_sign(s_dsp);
    v_msg := 'before ' || v_n;
    PERFORM public._pba_void_txn(t2, 'Duplicate of the card statement entry', s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_affidavits_to_sign(s_dsp);
    v_msg := v_msg || ', after void ' || v_n;
    BEGIN PERFORM public._pba_sign('form_f', af, 'staff', 'R2test Dsp', 'I made this purchase', NULL, NULL, s_dsp, 'dsp'); v_msg := v_msg || '; sign ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; sign refused'; END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'S4 an affidavit, then its purchase voided: the to-sign list and signing', v_msg,
      'before 1, after void 0; sign refused'));

    RAISE EXCEPTION 'v20029r2_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20029r2_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 4 THEN
    RAISE EXCEPTION 'v20.0.29 r2 self-test failed, so nothing in this file was applied: %', coalesce(v_fail, format('%s of 4 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20029r2_selftest (n, item, value, want) SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20029r2_test_insert(text, jsonb);

COMMIT;


-- ── Verification — paste this table into chat before the PR merges ─────
SELECT * FROM (
  SELECT 1 AS n, 'edits, voids and reversals lock the entry row; recording locks the approval' AS check_item,
    ((SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_edit_txn(uuid,jsonb,text,uuid,text)'::regprocedure) LIKE '%FOR UPDATE%'
     AND (SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_void_txn(uuid,text,uuid,text)'::regprocedure) LIKE '%FOR UPDATE%'
     AND (SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_reverse_txn(uuid,uuid,text,uuid,text)'::regprocedure) LIKE '%FOR UPDATE%'
     AND (SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_record_txn(uuid,uuid,jsonb,uuid,text)'::regprocedure) LIKE '%FOR UPDATE%')::text AS value,
    'true' AS want
  UNION ALL
  SELECT 2, 'approvals out of step with the ledger right now',
    (SELECT count(*) FROM public.pba_purchase_requests q
      WHERE q.status IN ('approved', 'spent')
        AND q.status <> CASE WHEN EXISTS (SELECT 1 FROM public.pba_transactions x WHERE x.request_id = q.id AND x.status = 'active' AND x.reverses_id IS NULL)
                             THEN 'spent' ELSE 'approved' END)::text, '0'
  UNION ALL
  SELECT 3, 'stored settings outside their ranges right now',
    (SELECT count(*) FROM public.org_settings s
      WHERE (s.key ~ 'count$' AND (jsonb_typeof(s.value) <> 'number' OR (s.value::text)::numeric NOT BETWEEN 1 AND 1000))
         OR (s.key ~ 'days$' AND (jsonb_typeof(s.value) <> 'number' OR (s.value::text)::numeric NOT BETWEEN 1 AND 3650))
         OR (s.key ~ 'amount$' AND (jsonb_typeof(s.value) <> 'number' OR (s.value::text)::numeric NOT BETWEEN 0 AND 1000000)))::text, '0'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20029r2_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999934')
     + (SELECT count(*) FROM public.staff WHERE first_name = 'R2test'))::text, '0'
) v ORDER BY n;
