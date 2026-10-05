-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.30 r1 — the monthly close, hardened (Greptile r1; v20.0.30 already ran, so this is a new migration)
--   1 The seal is a database invariant: every write to the ledger, statements, lines, cash counts and
--     explanations goes through a trigger that first takes the same per-Person lock the close takes, then
--     refuses anything in a sealed month. A write racing the signing of Form B waits, then is refused —
--     a sealed month can never differ from its signed summary. (Resolving a flag, which moves no money,
--     stays allowed.) Opening balances are sealed the same way.
--   2 Each statement must open where the chain left off: the previous statement's closing, or the
--     account's opening balance for the first. Form B names the break if it doesn't.
--   3 Only the PBA Manager can witness a Person's later signature on Form C.
--   4 A spend-down is paid only by a withdrawal (not a transfer between the Person's own accounts) that
--     covers it, on or after its month, credited to one spend-down only.
--   5 An asset alert clears only with notices + a plan recorded after the close it answers; a response
--     is always dated in the current month.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; a self-test runs and is
-- rolled back; any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public._pba_close_month(uuid,date,text,text,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.30 r1 stopped before changing anything — run sql/v20.0.30.sql first. Paste this message into chat.';
  END IF;
END $$;


-- ── 1. The seal, in the database ─────────────────────────────────────────
-- the per-Person lock the close takes (on the enrollment row)
CREATE OR REPLACE FUNCTION public._pba_lock_person(p_person uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF p_person IS NOT NULL THEN PERFORM 1 FROM pba_enrollments WHERE person_id = p_person FOR UPDATE; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_pba_seal_txn()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_skip text[] := ARRAY['flag_resolution', 'flag_resolved_by', 'flag_resolved_at', 'updated_at'];
BEGIN
  PERFORM public._pba_lock_person(coalesce(NEW.person_id, OLD.person_id));
  IF TG_OP = 'INSERT' THEN
    IF public._pba_month_closed(NEW.person_id, NEW.entry_date) THEN
      RAISE EXCEPTION '% is closed and sealed — record the entry in an open month', to_char(NEW.entry_date, 'FMMonth YYYY');
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF (to_jsonb(NEW) - v_skip) IS DISTINCT FROM (to_jsonb(OLD) - v_skip)
       AND (public._pba_month_closed(OLD.person_id, OLD.entry_date) OR public._pba_month_closed(NEW.person_id, NEW.entry_date)) THEN
      RAISE EXCEPTION '% is closed and sealed — correct it with a reversing entry', to_char(OLD.entry_date, 'FMMonth YYYY');
    END IF;
    RETURN NEW;
  ELSE
    IF public._pba_month_closed(OLD.person_id, OLD.entry_date) THEN RAISE EXCEPTION '% is closed and sealed', to_char(OLD.entry_date, 'FMMonth YYYY'); END IF;
    RETURN OLD;
  END IF;
END;
$$;
DROP TRIGGER IF EXISTS pba_seal_txn ON public.pba_transactions;
CREATE TRIGGER pba_seal_txn BEFORE INSERT OR UPDATE OR DELETE ON public.pba_transactions
  FOR EACH ROW EXECUTE FUNCTION public.trg_pba_seal_txn();

-- statements, cash counts and explanations carry their month
CREATE OR REPLACE FUNCTION public.trg_pba_seal_month_row()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM public._pba_lock_person(coalesce(NEW.person_id, OLD.person_id));
  IF (TG_OP <> 'DELETE' AND public._pba_month_closed(NEW.person_id, NEW.month))
     OR (TG_OP <> 'INSERT' AND public._pba_month_closed(OLD.person_id, OLD.month)) THEN
    RAISE EXCEPTION '% is closed and sealed', to_char(coalesce(NEW.month, OLD.month), 'FMMonth YYYY');
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
DROP TRIGGER IF EXISTS pba_seal_statements ON public.pba_statements;
CREATE TRIGGER pba_seal_statements BEFORE INSERT OR UPDATE OR DELETE ON public.pba_statements FOR EACH ROW EXECUTE FUNCTION public.trg_pba_seal_month_row();
DROP TRIGGER IF EXISTS pba_seal_cash ON public.pba_cash_counts;
CREATE TRIGGER pba_seal_cash BEFORE INSERT OR UPDATE OR DELETE ON public.pba_cash_counts FOR EACH ROW EXECUTE FUNCTION public.trg_pba_seal_month_row();
DROP TRIGGER IF EXISTS pba_seal_notes ON public.pba_unmatched_notes;
CREATE TRIGGER pba_seal_notes BEFORE INSERT OR UPDATE OR DELETE ON public.pba_unmatched_notes FOR EACH ROW EXECUTE FUNCTION public.trg_pba_seal_month_row();

-- statement lines take their statement's month
CREATE OR REPLACE FUNCTION public.trg_pba_seal_line()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_month date;
BEGIN
  PERFORM public._pba_lock_person(coalesce(NEW.person_id, OLD.person_id));
  SELECT s.month INTO v_month FROM pba_statements s WHERE s.id = coalesce(NEW.statement_id, OLD.statement_id);
  IF v_month IS NOT NULL AND public._pba_month_closed(coalesce(NEW.person_id, OLD.person_id), v_month) THEN
    RAISE EXCEPTION '% is closed and sealed', to_char(v_month, 'FMMonth YYYY');
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
DROP TRIGGER IF EXISTS pba_seal_lines ON public.pba_statement_lines;
CREATE TRIGGER pba_seal_lines BEFORE INSERT OR UPDATE OR DELETE ON public.pba_statement_lines FOR EACH ROW EXECUTE FUNCTION public.trg_pba_seal_line();

-- an account's opening balance is part of every sealed month's balance
CREATE OR REPLACE FUNCTION public.trg_pba_seal_account()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NEW.person_id IS NULL THEN RETURN NEW; END IF;
  PERFORM public._pba_lock_person(NEW.person_id);
  IF (NEW.opening_balance IS DISTINCT FROM OLD.opening_balance OR NEW.opening_date IS DISTINCT FROM OLD.opening_date)
     AND EXISTS (SELECT 1 FROM pba_month_closes c WHERE c.person_id = NEW.person_id) THEN
    RAISE EXCEPTION 'A month is already closed for this Person, so the opening balance is sealed — correct it with an entry in an open month';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pba_seal_account ON public.pba_accounts;
CREATE TRIGGER pba_seal_account BEFORE UPDATE ON public.pba_accounts FOR EACH ROW EXECUTE FUNCTION public.trg_pba_seal_account();

CREATE OR REPLACE FUNCTION public._pba_recon(p_account uuid, p_month date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  acc record; st record; v_end date; v_L numeric; v_out numeric; v_ahead numeric; v_unm_lines integer; v_unexpl integer;
  v_prev numeric; v_expect_open numeric;
  v_count record;
BEGIN
  SELECT * INTO acc FROM pba_accounts WHERE id = p_account;
  IF acc.kind = 'cash' THEN
    SELECT * INTO v_count FROM pba_cash_counts WHERE account_id = p_account AND month = p_month;
    v_L := public._pba_balance_at(p_account, public._pba_month_end(p_month));
    RETURN jsonb_build_object('account_id', p_account, 'kind', acc.kind, 'ledger_closing', v_L,
      'counted', v_count.counted, 'has_count', v_count.id IS NOT NULL,
      'difference', CASE WHEN v_count.id IS NULL THEN NULL ELSE v_L - v_count.counted END,
      'ready', v_count.id IS NOT NULL AND v_L = v_count.counted);
  END IF;
  SELECT * INTO st FROM pba_statements WHERE account_id = p_account AND month = p_month;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('account_id', p_account, 'kind', acc.kind, 'has_statement', false, 'ready', false);
  END IF;
  v_end := st.period_end;
  -- r1: the opening must continue the chain — the previous statement's closing, or (for the first
  -- statement) the account's opening balance
  SELECT s2.closing_balance INTO v_prev FROM pba_statements s2
   WHERE s2.account_id = p_account AND s2.period_end < st.period_start ORDER BY s2.period_end DESC LIMIT 1;
  v_expect_open := coalesce(v_prev, acc.opening_balance);
  v_L := public._pba_balance_at(p_account, v_end);
  -- in the ledger, not yet on any statement through this one
  SELECT coalesce(sum(public._pba_effect(t, p_account)), 0) INTO v_out
    FROM pba_transactions t
   WHERE (t.account_id = p_account OR t.to_account_id = p_account) AND t.status = 'active' AND t.entry_date <= v_end
     AND NOT public._pba_matched_by(t.id, p_account, v_end);
  -- on a statement through this one, dated later in the ledger
  SELECT coalesce(sum(l.amount), 0) INTO v_ahead
    FROM pba_statement_lines l JOIN pba_statements s ON s.id = l.statement_id JOIN pba_transactions t ON t.id = l.matched_txn_id
   WHERE l.account_id = p_account AND s.period_end <= v_end AND t.entry_date > v_end;
  SELECT count(*) INTO v_unm_lines FROM pba_statement_lines l WHERE l.statement_id = st.id AND l.matched_txn_id IS NULL;
  -- this month's entries (through the statement's end) with no line and no explanation
  SELECT count(*) INTO v_unexpl
    FROM pba_transactions t
   WHERE (t.account_id = p_account OR t.to_account_id = p_account) AND t.status = 'active'
     AND t.entry_date <= v_end AND public._pba_effect(t, p_account) <> 0
     AND NOT public._pba_matched_by(t.id, p_account, v_end)
     AND NOT EXISTS (SELECT 1 FROM pba_unmatched_notes n WHERE n.txn_id = t.id AND n.account_id = p_account AND n.month <= p_month);
  RETURN jsonb_build_object('account_id', p_account, 'kind', acc.kind, 'has_statement', true, 'statement_id', st.id,
    'period_start', st.period_start, 'period_end', st.period_end, 'statement_opening', st.opening_balance,
    'statement_closing', st.closing_balance, 'ledger_closing', v_L, 'outstanding', v_out, 'ahead', v_ahead,
    'difference', v_L - (st.closing_balance + v_out - v_ahead),
    'unmatched_lines', v_unm_lines, 'unexplained_entries', v_unexpl,
    'expected_opening', v_expect_open, 'opening_ok', st.opening_balance = v_expect_open,
    'ready', v_unm_lines = 0 AND v_unexpl = 0 AND v_L = st.closing_balance + v_out - v_ahead AND st.opening_balance = v_expect_open);
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_close_month(p_person uuid, p_month date, p_name text, p_attest text, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  a record; v_month date := date_trunc('month', p_month)::date; v_today date := public._pba_today();
  v_problems text[] := '{}'; acc record; r jsonb; v_accts jsonb := '[]'::jsonb; v_id uuid; v_countable numeric; v_first date;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager signs the reconciliation'; END IF;
  PERFORM 1 FROM pba_enrollments WHERE person_id = p_person FOR UPDATE;          -- one close at a time per Person
  IF public._pba_month_closed(p_person, v_month) THEN RAISE EXCEPTION '% is already closed', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF v_month >= date_trunc('month', v_today)::date THEN RAISE EXCEPTION '% hasn''t ended yet', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF public._pba_enrollment_status(p_person) <> 'enrolled' THEN
    v_problems := v_problems || 'enrollment isn''t complete (fiduciary proof and a signed Form A)'::text;
  END IF;
  SELECT date_trunc('month', started_on)::date INTO v_first FROM pba_enrollments WHERE person_id = p_person;
  IF EXISTS (SELECT 1 FROM generate_series(v_first, v_month - interval '1 month', interval '1 month') gs
              WHERE NOT public._pba_month_closed(p_person, gs::date)) THEN
    v_problems := v_problems || 'an earlier month isn''t closed yet'::text;
  END IF;
  FOR acc IN SELECT * FROM public._pba_month_accounts(p_person, v_month) LOOP
    r := public._pba_recon(acc.id, v_month) || jsonb_build_object('label', concat_ws(' ', acc.institution, CASE WHEN acc.last4 IS NOT NULL THEN '··' || acc.last4 END, '(' || acc.kind || ')'));
    v_accts := v_accts || jsonb_build_array(r);
    IF NOT coalesce((r->>'ready')::boolean, false) THEN
      v_problems := v_problems || (coalesce(r->>'label', 'an account') || ': ' ||
        CASE WHEN acc.kind = 'cash' AND NOT coalesce((r->>'has_count')::boolean, false) THEN 'no cash count'
             WHEN acc.kind = 'cash' THEN format('the count differs from the ledger by $%s', r->>'difference')
             WHEN NOT coalesce((r->>'has_statement')::boolean, false) THEN 'no statement'
             WHEN NOT coalesce((r->>'opening_ok')::boolean, true) THEN format('the statement opens at $%s but should continue from $%s', r->>'statement_opening', r->>'expected_opening')
             WHEN (r->>'unmatched_lines')::integer > 0 THEN (r->>'unmatched_lines') || ' unmatched statement line(s)'
             WHEN (r->>'unexplained_entries')::integer > 0 THEN (r->>'unexplained_entries') || ' entry(ies) with no line and no explanation'
             ELSE format('doesn''t reconcile (off by $%s)', r->>'difference') END);
    END IF;
  END LOOP;
  IF public._pba_missing_receipts(p_person, v_month) > 0 THEN
    v_problems := v_problems || (public._pba_missing_receipts(p_person, v_month) || ' purchase(s) over $50 without a receipt or signed affidavit');
  END IF;
  IF array_length(v_problems, 1) > 0 THEN
    RAISE EXCEPTION 'Not ready to close %: %', to_char(v_month, 'FMMonth YYYY'), array_to_string(v_problems, '; ');
  END IF;
  v_countable := public._pba_countable(p_person, public._pba_month_end(v_month));
  INSERT INTO pba_form_b (org_id, person_id, month, summary, countable, created_by)
  VALUES (a.o_org, p_person, v_month, jsonb_build_object('accounts', v_accts), v_countable, p_actor) RETURNING id INTO v_id;
  PERFORM public._pba_add_signature(a.o_org, p_person, 'form_b', v_id, 'reconciler', 'staff', p_actor, p_name, p_attest,
                                    (SELECT to_jsonb(f) FROM pba_form_b f WHERE f.id = v_id), NULL, NULL, NULL);
  INSERT INTO pba_month_closes (org_id, person_id, month, closed_by) VALUES (a.o_org, p_person, v_month, p_actor);
  PERFORM public._pba_audit(a.o_org, 'pba_month_closed', 'pba_form_b', v_id, NULL, jsonb_build_object('month', v_month, 'countable', v_countable));
  RETURN v_id;
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
  ELSIF p_form_type = 'form_c' THEN                                          -- v20.0.30
    SELECT c.person_id, to_jsonb(c) INTO v_person, v_content FROM pba_form_c c WHERE c.id = p_form_id;
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
  ELSIF p_form_type = 'form_c' THEN
    -- v20.0.30 (R2-4): the Person or guardian signs the monthly review later (a scan after a virtual review)
    IF p_signer_kind NOT IN ('person', 'guardian') THEN RAISE EXCEPTION 'The PBA Manager signs Form C when completing it; here only the Person or guardian signs'; END IF;
    IF p_drawn_file IS NULL AND p_scan_file IS NULL THEN RAISE EXCEPTION 'The signature needs to be drawn on screen or attached as a scan'; END IF;
    -- r1: the Person's signature is witnessed by the PBA Manager who held the review — never a reviewer or auditor
    IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can witness the Person''s signature on the monthly review'; END IF;
    v_capacity := p_signer_kind;
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

CREATE OR REPLACE FUNCTION public._pba_pay_spenddown(p_spenddown uuid, p_txn uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE s record; a record;
BEGIN
  SELECT * INTO s FROM pba_spenddowns WHERE id = p_spenddown FOR UPDATE;
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
  UPDATE pba_spenddowns SET paid_txn_id = p_txn WHERE id = p_spenddown;
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_save_asset_response(p_person uuid, p_month date, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_month date := date_trunc('month', public._pba_today())::date;   -- r1: always the current month (p_month is ignored)
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_write OR a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only this Person''s PBA Manager, the owner or the Compliance Director records the asset response'; END IF;
  IF (p_data #>> '{notices,person}') IS NULL OR (p_data #>> '{notices,residential}') IS NULL OR (p_data #>> '{notices,sc}') IS NULL THEN
    RAISE EXCEPTION 'Record the date each notice was given: the Person, the residential team and the SC';
  END IF;
  INSERT INTO pba_asset_responses (org_id, person_id, month, countable, notices, plan_type, plan_detail, target_date, created_by)
  VALUES (a.o_org, p_person, v_month, public._pba_countable(p_person, public._pba_today()), p_data->'notices', p_data->>'plan_type',
          coalesce(btrim(p_data->>'plan_detail'), ''), (p_data->>'target_date')::date, p_actor)
  ON CONFLICT (person_id, month) DO UPDATE SET notices = EXCLUDED.notices, plan_type = EXCLUDED.plan_type, plan_detail = EXCLUDED.plan_detail,
    target_date = EXCLUDED.target_date, countable = EXCLUDED.countable, created_by = EXCLUDED.created_by, created_at = now();
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
  v_thr numeric; v_live numeric; v_close_month date; v_close_countable numeric; v_close_at timestamptz;
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
  SELECT f.month, f.countable, f.created_at INTO v_close_month, v_close_countable, v_close_at FROM pba_form_b f WHERE f.person_id = p_person ORDER BY f.month DESC LIMIT 1;
  -- r1: the official alert clears only with notices + a plan recorded after that close
  IF v_close_month IS NOT NULL AND v_close_countable >= v_thr AND v_live >= v_thr
     AND NOT EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person AND r.created_at >= v_close_at) THEN
    RETURN QUERY SELECT 'asset_alert'::text,
      format('Countable assets were $%s at the %s close (alert at $%s; the SSI resource limit is $2,000) — record the notices to the Person, the residential team and the SC, and a plan',
             to_char(v_close_countable, 'FM999999990.00'), to_char(v_close_month, 'FMMonth YYYY'), to_char(v_thr, 'FM999999990.00')), NULL::uuid;
  ELSIF v_live >= v_thr
     AND NOT EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person
                      AND r.created_at >= coalesce(v_close_at, '-infinity'::timestamptz) AND r.month >= date_trunc('month', v_today)::date) THEN
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
    FROM pba_spenddowns s WHERE s.person_id = p_person AND s.paid_txn_id IS NULL AND s.due_date < v_today;

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
  v_resp := v_b.id IS NOT NULL AND EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person AND r.created_at >= v_b.created_at);   -- r1
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


DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND (p.proname LIKE '\_pba\_%' OR p.proname LIKE 'trg\_pba\_%') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

CREATE TEMP TABLE IF NOT EXISTS v20030r1_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20030r1_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20030r1_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.30r1 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res jsonb := '[]'::jsonb; v_fail text; v_step text := 'setup';
  v_org uuid; v_person uuid; s_owner uuid; s_cd uuid; s_mgr uuid; s_rev uuid;
  v_bank uuid := gen_random_uuid(); v_bank2 uuid := gen_random_uuid(); v_stmt uuid := gen_random_uuid(); v_fc uuid; v_fid uuid; v_sd uuid;
  t_jan uuid := gen_random_uuid(); t_small uuid := gen_random_uuid(); t_big uuid := gen_random_uuid(); t_xfer uuid := gen_random_uuid();
  v_jan date := DATE '2001-01-01'; v_today date := DATE '2001-02-16';
  v_msg text; v_txt text; v_n integer; r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s2.org_id INTO v_org FROM staff s2 ORDER BY s2.created_at NULLS LAST, s2.id LIMIT 1;
  BEGIN
    v_person := pg_temp.v20030r1_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20030R1', 'last_name', 'Selftest', 'identification_number', '099999936', 'is_active', true));
    s_owner := pg_temp.v20030r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R31test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20030r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R31test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20030r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R31test', 'last_name', 'Manager'));
    s_rev   := pg_temp.v20030r1_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R31test', 'last_name', 'Reviewer'));
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    UPDATE pba_enrollments SET started_on = v_jan WHERE person_id = v_person;
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    PERFORM public._pba_assign_role(v_person, s_rev, 'reviewer', s_cd, 'compliance_director');
    -- the test pins its own threshold (inside the rolled-back block), so a provider's setting can't change the expected result
    PERFORM public._set_org_setting('pba.asset_alert_amount', '1500'::jsonb, s_owner, 'owner', v_org);
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20030R1 Selftest', 'opening_balance', 1800,
              'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');
    PERFORM public._pba_save_account(v_bank2, v_person, jsonb_build_object('kind', 'bank', 'titling', 'V20030R1 Selftest savings',
              'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');

    -- R1: the opening-balance chain
    v_step := 'R1 opening chain';
    PERFORM public._pba_import_statement(v_stmt, v_bank, v_jan, jsonb_build_object('opening_balance', 1799, 'closing_balance', 1799, 'lines', '[]'::jsonb), s_mgr, 'dsp');
    r := public._pba_recon(v_bank, v_jan);
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'R1 a statement opening at $1,799 on an account that opened at $1,800',
      format('opening ok %s; expected %s; ready %s', r->>'opening_ok', r->>'expected_opening', r->>'ready'), 'opening ok false; expected 1800.00; ready false'));

    -- R2: the seal holds even for direct writes, once a month is closed
    v_step := 'R2 seal';
    PERFORM public._pba_record_txn(t_jan, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-10', 'type', 'withdrawal', 'amount', 20,
              'beneficiary', 'other', 'beneficiary_name', 'Friend', 'category', 'gift'), s_mgr, 'dsp');
    INSERT INTO pba_month_closes (org_id, person_id, month) VALUES (v_org, v_person, v_jan);
    v_msg := '';
    BEGIN INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount) VALUES (gen_random_uuid(), v_org, v_person, v_bank, '2001-01-15', 'fee', 1);
          v_msg := 'insert ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'insert refused'; END;
    BEGIN UPDATE pba_transactions SET amount = 21 WHERE id = t_jan; v_msg := v_msg || '; amount ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; amount refused'; END;
    BEGIN UPDATE pba_statement_lines SET description = 'x' WHERE statement_id = v_stmt;
          INSERT INTO pba_statement_lines (org_id, person_id, statement_id, account_id, line_no, line_date, amount) VALUES (v_org, v_person, v_stmt, v_bank, 1, '2001-01-10', -20);
          v_msg := v_msg || '; line ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; line refused'; END;
    BEGIN INSERT INTO pba_cash_counts (org_id, person_id, account_id, month, counted) VALUES (v_org, v_person, v_bank, v_jan, 0); v_msg := v_msg || '; count ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; count refused'; END;
    BEGIN UPDATE pba_accounts SET opening_balance = 1700 WHERE id = v_bank; v_msg := v_msg || '; opening ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; opening refused'; END;
    PERFORM public._pba_resolve_flag(t_jan, 'His choice; needs were met', s_cd, 'compliance_director');
    v_msg := v_msg || '; flag resolution ' || CASE WHEN (SELECT flag_resolved_at FROM pba_transactions WHERE id = t_jan) IS NOT NULL THEN 'allowed' ELSE 'MISSING' END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'R2 after January closes, direct writes: an entry, its amount, a statement line, a cash count, the opening balance; then a flag resolution',
      v_msg, 'insert refused; amount refused; line refused; count refused; opening refused; flag resolution allowed'));

    -- R3: a later Form C signature — the reviewer can't witness it, the PBA Manager can
    v_step := 'R3 Form C signature';
    INSERT INTO pba_form_c (org_id, person_id, month, review_date, mode, exception_reason) VALUES (v_org, v_person, v_jan, '2001-02-08', 'in_person', 'Declined that day')
      RETURNING id INTO v_fc;
    v_fid := gen_random_uuid();
    INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, uploaded_by)
    VALUES (v_fid, v_org, v_person, 'signature', v_org || '/' || v_person || '/signatures/' || v_fid || '.png', repeat('d', 64), s_rev);
    v_msg := '';
    BEGIN PERFORM public._pba_sign('form_c', v_fc, 'person', 'V20030R1 Selftest', 'I reviewed my money', v_fid, NULL, s_rev, 'dsp'); v_msg := 'reviewer ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'reviewer refused'; END;
    PERFORM public._pba_sign('form_c', v_fc, 'person', 'V20030R1 Selftest', 'I reviewed my money', v_fid, NULL, s_mgr, 'dsp');
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'R3 the Person''s later signature on Form C, witnessed by the reviewer, then by the PBA Manager',
      v_msg || '; signatures ' || (SELECT count(*) FROM pba_signatures WHERE form_id = v_fc), 'reviewer refused; signatures 1'));

    -- R4: spend-down payments
    v_step := 'R4 spend-down';
    PERFORM public._pba_save_spenddown(v_person, DATE '2001-02-01', 75, DATE '2001-02-20', s_mgr, 'dsp');
    SELECT id INTO v_sd FROM pba_spenddowns WHERE person_id = v_person;
    PERFORM public._pba_record_txn(t_xfer, v_person, jsonb_build_object('account_id', v_bank, 'to_account_id', v_bank2, 'entry_date', '2001-02-05', 'type', 'transfer', 'amount', 100), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t_small, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-02-05', 'type', 'withdrawal', 'amount', 20, 'payee', 'Store'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t_big, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-02-06', 'type', 'withdrawal', 'amount', 75, 'payee', 'Medicaid'), s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_pay_spenddown(v_sd, t_xfer, s_mgr, 'dsp'); v_msg := 'transfer ALLOWED'; EXCEPTION WHEN raise_exception THEN v_msg := 'transfer refused'; END;
    BEGIN PERFORM public._pba_pay_spenddown(v_sd, t_small, s_mgr, 'dsp'); v_msg := v_msg || '; $20 ALLOWED'; EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; $20 refused'; END;
    PERFORM public._pba_pay_spenddown(v_sd, t_big, s_mgr, 'dsp');
    PERFORM public._pba_save_spenddown(v_person, DATE '2001-03-01', 75, DATE '2001-03-20', s_mgr, 'dsp');
    BEGIN PERFORM public._pba_pay_spenddown((SELECT id FROM pba_spenddowns WHERE person_id = v_person AND month = DATE '2001-03-01'), t_big, s_mgr, 'dsp');
          v_msg := v_msg || '; reused ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; reused refused'; END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'R4 a $75 spend-down paid by a transfer, by $20, by $75; the $75 again for another month',
      v_msg || '; paid ' || ((SELECT paid_txn_id FROM pba_spenddowns WHERE id = v_sd) = t_big)::text,
      'transfer refused; $20 refused; reused refused; paid true'));

    -- R5: an asset alert clears only with a response recorded after the close
    v_step := 'R5 asset response';
    INSERT INTO pba_asset_responses (org_id, person_id, month, notices, plan_type, plan_detail, target_date, created_at)
    VALUES (v_org, v_person, DATE '2000-12-01', '{"person": "2000-12-05", "residential": "2000-12-05", "sc": "2000-12-05"}'::jsonb, 'other', 'An old plan', DATE '2000-12-31',
            now() - interval '1 day');
    INSERT INTO pba_form_b (org_id, person_id, month, summary, countable) VALUES (v_org, v_person, v_jan, '{"accounts": []}'::jsonb, 1800);
    SELECT string_agg(f.o_flag, ', ') INTO v_txt FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%';
    PERFORM public._pba_save_asset_response(v_person, DATE '2030-01-01', jsonb_build_object('notices', jsonb_build_object('person', '2001-02-10', 'residential', '2001-02-10', 'sc', '2001-02-11'),
              'plan_type', 'able', 'plan_detail', 'Open an ABLE account and move $500', 'target_date', '2001-02-28'), s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%';
    v_res := v_res || jsonb_build_array(jsonb_build_array(5, 'R5 $1,800 at the close with only an older plan on file; then notices + a plan (asked for 2030, dated now)',
      coalesce(v_txt, 'none') || '; after the response ' || v_n || '; response month is now ' ||
      ((SELECT month FROM pba_asset_responses WHERE person_id = v_person ORDER BY created_at DESC LIMIT 1) = date_trunc('month', public._pba_today())::date)::text,
      'asset_alert; after the response 0; response month is now true'));

    RAISE EXCEPTION 'v20030r1_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20030r1_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 5 THEN
    RAISE EXCEPTION 'v20.0.30 r1 self-test failed, so nothing in this file was applied: %', coalesce(v_fail, format('%s of 5 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20030r1_selftest (n, item, value, want) SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20030r1_test_insert(text, jsonb);

COMMIT;


-- ── Verification — paste this table into chat before the PR merges ─────
SELECT * FROM (
  SELECT 1 AS n, 'seal triggers on the ledger, statements, lines, cash counts, explanations and accounts' AS check_item,
    (SELECT string_agg(t.tgname, ', ' ORDER BY t.tgname) FROM pg_trigger t
      WHERE NOT t.tgisinternal AND t.tgname IN ('pba_seal_txn', 'pba_seal_statements', 'pba_seal_lines', 'pba_seal_cash', 'pba_seal_notes', 'pba_seal_account')) AS value,
    'pba_seal_account, pba_seal_cash, pba_seal_lines, pba_seal_notes, pba_seal_statements, pba_seal_txn' AS want
  UNION ALL
  SELECT 2, 'reconciliation checks the opening-balance chain',
    ((SELECT prosrc FROM pg_proc WHERE oid = 'public._pba_recon(uuid,date)'::regprocedure) LIKE '%opening_ok%')::text, 'true'
  UNION ALL
  SELECT 3, 'internal and trigger functions not callable by clients',
    (SELECT bool_and(NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND (p.proname LIKE '\_pba\_%' OR p.proname LIKE 'trg\_pba\_%'))::text, 'true'
  UNION ALL
  SELECT 10 + t.n, t.item, t.value, t.want FROM v20030r1_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999936')
     + (SELECT count(*) FROM public.staff WHERE first_name = 'R31test'))::text, '0'
) v ORDER BY n;
