-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.30 — PBA Release 2: the monthly close (docs/pba-design.md v1.2; Decisions R2-1 … R2-7)
--   Statements    per-account column mapping (R2-2); statements with their period and opening /
--                 closing balances; lines matched to entries by the PBA Manager from suggestions (R2-3);
--                 an unmatched bank line becomes an entry in one step; an unmatched entry is explained.
--   Form B        the reconciliation: refused until every line is matched, every entry is matched or
--                 explained, each account reconciles to its statement (outstanding items accounted for),
--                 cash on hand is counted, every purchase over $50 has its receipt or signed affidavit,
--                 and enrollment is complete. Signing it SEALS the month (R2-1) and records the
--                 countable assets for the official SSI check (R2-7).
--   Form C        the review with the Person: the Person's / guardian's signature, or a recorded
--                 exception that completes the step and is flagged for the reviewer (R2-4).
--   Form D        the Administrative Reviewer's checklist (pre-checked from the data) and findings;
--                 each finding is an open item the Compliance Director answers; the cycle continues (R2-5).
--   Form G        the SC report: the package PDF stored add-only, with the date, recipient and method (R2-6).
--   Cycle         due day 5 / 10 / 15 / 30 of the next month; each step needs the one before it; overdue
--                 steps are flagged; pba_cycles() is the org overview.
--   Benefits      the asset alert (bank + pay card + cash; ABLE excluded) at each close and live between
--                 closes, needing notices + a plan (R2-7); Medicaid spend-down; SSA payee-accounting reminders;
--                 a flag when the Person's reviewer or auditor bills PBA time for them.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; preflight; a self-test runs
-- and is rolled back; any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $$
BEGIN
  IF to_regprocedure('public._pba_sync_request(uuid)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.30 stopped before changing anything — v20.0.29 r2 isn''t live (run sql/v20.0.29r2_pba.sql first). Paste this message into chat.';
  END IF;
  IF to_regclass('public.service_notes') IS NULL OR to_regclass('public.service_code_definitions') IS NULL THEN
    RAISE EXCEPTION 'v20.0.30 stopped before changing anything — service_notes / service_code_definitions missing. Paste this message into chat.';
  END IF;
END $$;

-- ── 1. Settings: the asset alert threshold ───────────────────────────────
CREATE OR REPLACE FUNCTION public.provly_setting(p_org uuid, p_key text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(
    (SELECT s.value FROM org_settings s WHERE s.org_id = p_org AND s.key = p_key),
    CASE p_key
      WHEN 'pba.third_party_count'   THEN '3'::jsonb
      WHEN 'pba.third_party_amount'  THEN '150'::jsonb
      WHEN 'pba.third_party_days'    THEN '90'::jsonb
      WHEN 'pba.affidavit_count'     THEN '3'::jsonb
      WHEN 'pba.affidavit_days'      THEN '90'::jsonb
      WHEN 'pba.asset_alert_amount'  THEN '1500'::jsonb      -- v20.0.30: alert below the $2,000 SSI resource limit
    END)
$$;

-- ── 2. Tables ────────────────────────────────────────────────────────────
-- 2a. the column mapping of an account's bank file (R2-2)
CREATE TABLE IF NOT EXISTS public.pba_statement_mappings (
  account_id   uuid PRIMARY KEY REFERENCES public.pba_accounts (id),
  org_id       uuid NOT NULL,
  person_id    uuid NOT NULL,
  headers      jsonb NOT NULL,
  date_col     integer NOT NULL,
  desc_col     integer,
  amount_col   integer,
  debit_col    integer,
  credit_col   integer,
  date_format  text NOT NULL,
  updated_by   uuid,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_map_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_map_cols_chk CHECK (amount_col IS NOT NULL OR (debit_col IS NOT NULL AND credit_col IS NOT NULL)),
  CONSTRAINT pba_map_fmt_chk CHECK (date_format IN ('MM/DD/YYYY', 'YYYY-MM-DD', 'DD/MM/YYYY')),
  CONSTRAINT pba_map_headers_chk CHECK (jsonb_typeof(headers) = 'array')
);

-- 2b. a statement: one per account per month (the statement whose period ends in that month)
CREATE TABLE IF NOT EXISTS public.pba_statements (
  id               uuid PRIMARY KEY,
  org_id           uuid NOT NULL,
  person_id        uuid NOT NULL,
  account_id       uuid NOT NULL REFERENCES public.pba_accounts (id),
  month            date NOT NULL,
  period_start     date NOT NULL,
  period_end       date NOT NULL,
  opening_balance  numeric(12,2) NOT NULL,
  closing_balance  numeric(12,2) NOT NULL,
  source           text NOT NULL,
  file_id          uuid REFERENCES public.pba_files (id),
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_stmt_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_stmt_month_chk CHECK (month = date_trunc('month', month)::date),
  CONSTRAINT pba_stmt_period_chk CHECK (period_end >= period_start AND date_trunc('month', period_end)::date = month),
  CONSTRAINT pba_stmt_source_chk CHECK (source IN ('import', 'manual')),
  CONSTRAINT pba_stmt_one UNIQUE (account_id, month)
);

-- 2c. statement lines (amount signed: + into the account, − out of it)
CREATE TABLE IF NOT EXISTS public.pba_statement_lines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL,
  person_id       uuid NOT NULL,
  statement_id    uuid NOT NULL REFERENCES public.pba_statements (id) ON DELETE CASCADE,
  account_id      uuid NOT NULL REFERENCES public.pba_accounts (id),
  line_no         integer NOT NULL,
  line_date       date NOT NULL,
  description     text,
  amount          numeric(12,2) NOT NULL,
  matched_txn_id  uuid REFERENCES public.pba_transactions (id),
  matched_by      uuid,
  matched_at      timestamptz,
  CONSTRAINT pba_line_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_line_amount_chk CHECK (amount <> 0),
  CONSTRAINT pba_line_no_uq UNIQUE (statement_id, line_no)
);
-- an entry is matched at most once per account (a transfer between two statement accounts matches one line on each)
CREATE UNIQUE INDEX IF NOT EXISTS pba_line_one_match ON public.pba_statement_lines (account_id, matched_txn_id) WHERE matched_txn_id IS NOT NULL;

-- 2d. why an entry has no statement line yet (e.g. a check that hasn't cleared)
CREATE TABLE IF NOT EXISTS public.pba_unmatched_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  person_id    uuid NOT NULL,
  month        date NOT NULL,
  txn_id       uuid NOT NULL REFERENCES public.pba_transactions (id),
  account_id   uuid NOT NULL REFERENCES public.pba_accounts (id),
  explanation  text NOT NULL,
  created_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_unm_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_unm_text_chk CHECK (length(btrim(explanation)) > 0),
  CONSTRAINT pba_unm_one UNIQUE (txn_id, account_id, month)
);

-- 2e. the monthly count of cash on hand (cash has no statement)
CREATE TABLE IF NOT EXISTS public.pba_cash_counts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  person_id   uuid NOT NULL,
  account_id  uuid NOT NULL REFERENCES public.pba_accounts (id),
  month       date NOT NULL,
  counted     numeric(12,2) NOT NULL,
  note        text,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_cash_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_cash_counted_chk CHECK (counted >= 0),
  CONSTRAINT pba_cash_one UNIQUE (account_id, month)
);

-- 2f. the four monthly forms
CREATE TABLE IF NOT EXISTS public.pba_form_b (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  person_id   uuid NOT NULL,
  month       date NOT NULL,
  summary     jsonb NOT NULL,
  countable   numeric(12,2) NOT NULL,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_fb_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_fb_one UNIQUE (person_id, month)
);
CREATE TABLE IF NOT EXISTS public.pba_form_c (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL,
  person_id         uuid NOT NULL,
  month             date NOT NULL,
  review_date       date NOT NULL,
  mode              text NOT NULL,
  attendees         text,
  person_comments   text,
  exception_reason  text,
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_fc_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_fc_mode_chk CHECK (mode IN ('in_person', 'virtual')),
  CONSTRAINT pba_fc_one UNIQUE (person_id, month)
);
CREATE TABLE IF NOT EXISTS public.pba_form_d (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  person_id   uuid NOT NULL,
  month       date NOT NULL,
  checklist   jsonb NOT NULL,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_fd_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_fd_one UNIQUE (person_id, month)
);
CREATE TABLE IF NOT EXISTS public.pba_findings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL,
  person_id     uuid NOT NULL,
  month         date NOT NULL,
  form_d_id     uuid NOT NULL REFERENCES public.pba_form_d (id),
  finding       text NOT NULL,
  response      text,
  responded_by  uuid,
  responded_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_find_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_find_text_chk CHECK (length(btrim(finding)) > 0)
);
CREATE TABLE IF NOT EXISTS public.pba_form_g (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL,
  person_id      uuid NOT NULL,
  month          date NOT NULL,
  sent_on        date NOT NULL,
  sent_to_name   text NOT NULL,
  sent_to_email  text,
  method         text NOT NULL,
  file_id        uuid NOT NULL REFERENCES public.pba_files (id),
  created_by     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_fg_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_fg_text_chk CHECK (length(btrim(sent_to_name)) > 0 AND length(btrim(method)) > 0),
  CONSTRAINT pba_fg_one UNIQUE (person_id, month)
);

-- 2g. benefits
CREATE TABLE IF NOT EXISTS public.pba_asset_responses (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL,
  person_id     uuid NOT NULL,
  month         date NOT NULL,
  countable     numeric(12,2),
  notices       jsonb NOT NULL,
  plan_type     text NOT NULL,
  plan_detail   text NOT NULL,
  target_date   date NOT NULL,
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_asset_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_asset_plan_chk CHECK (plan_type IN ('planned_purchase', 'able', 'other') AND length(btrim(plan_detail)) > 0),
  CONSTRAINT pba_asset_notices_chk CHECK (notices ? 'person' AND notices ? 'residential' AND notices ? 'sc'),
  CONSTRAINT pba_asset_one UNIQUE (person_id, month)
);
CREATE TABLE IF NOT EXISTS public.pba_spenddowns (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  person_id    uuid NOT NULL,
  month        date NOT NULL,
  amount       numeric(12,2) NOT NULL,
  due_date     date NOT NULL,
  paid_txn_id  uuid REFERENCES public.pba_transactions (id),
  created_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_sd_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_sd_amount_chk CHECK (amount > 0),
  CONSTRAINT pba_sd_one UNIQUE (person_id, month)
);
CREATE TABLE IF NOT EXISTS public.pba_payee_reports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL,
  person_id     uuid NOT NULL,
  requested_on  date NOT NULL,
  due_date      date NOT NULL,
  completed_on  date,
  notes         text,
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_payee_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_payee_dates_chk CHECK (due_date >= requested_on)
);

-- 2h. signatures for the new forms
ALTER TABLE public.pba_signatures DROP CONSTRAINT IF EXISTS pba_sig_form_chk;
ALTER TABLE public.pba_signatures ADD CONSTRAINT pba_sig_form_chk CHECK (form_type IN ('form_a', 'form_f', 'form_b', 'form_c', 'form_d'));
ALTER TABLE public.pba_signatures DROP CONSTRAINT IF EXISTS pba_sig_capacity_chk;
ALTER TABLE public.pba_signatures ADD CONSTRAINT pba_sig_capacity_chk CHECK (capacity IN ('preparer', 'purchaser', 'countersigner', 'person', 'guardian', 'reconciler', 'reviewer'));

-- ── 3. Helpers: months, balances, reconciliation, the cycle ──────────────
CREATE OR REPLACE FUNCTION public._pba_month_end(p_month date) RETURNS date
LANGUAGE sql IMMUTABLE AS $$ SELECT (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date $$;

-- an account's ledger balance at the end of a day
CREATE OR REPLACE FUNCTION public._pba_balance_at(p_account uuid, p_day date)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT acc.opening_balance + coalesce((SELECT sum(public._pba_effect(t, acc.id)) FROM pba_transactions t
                                          WHERE (t.account_id = acc.id OR t.to_account_id = acc.id) AND t.entry_date <= p_day), 0)
    FROM pba_accounts acc WHERE acc.id = p_account
$$;

-- is an entry matched on this account by a line of a statement ending on or before p_day?
CREATE OR REPLACE FUNCTION public._pba_matched_by(p_txn uuid, p_account uuid, p_day date)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM pba_statement_lines l JOIN pba_statements s ON s.id = l.statement_id
                  WHERE l.matched_txn_id = p_txn AND l.account_id = p_account AND s.period_end <= p_day)
$$;

-- an account's accounts open during a month (the ones a close must cover)
CREATE OR REPLACE FUNCTION public._pba_month_accounts(p_person uuid, p_month date)
RETURNS SETOF public.pba_accounts
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT acc.* FROM pba_accounts acc
   WHERE acc.person_id = p_person
     AND (acc.opened_on IS NULL OR acc.opened_on <= public._pba_month_end(p_month))
     AND (acc.closed_on IS NULL OR acc.closed_on >= p_month)
     AND (acc.opening_date IS NULL OR acc.opening_date <= public._pba_month_end(p_month))
$$;

-- the reconciliation of one account for one month (R2-3): statement accounts reconcile to their
-- statement with outstanding items accounted for; cash reconciles to its count
CREATE OR REPLACE FUNCTION public._pba_recon(p_account uuid, p_month date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  acc record; st record; v_end date; v_L numeric; v_out numeric; v_ahead numeric; v_unm_lines integer; v_unexpl integer;
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
    'ready', v_unm_lines = 0 AND v_unexpl = 0 AND v_L = st.closing_balance + v_out - v_ahead);
END;
$$;

-- countable resources for SSI (R2-7): bank + pay card + cash on hand; ABLE is excluded
CREATE OR REPLACE FUNCTION public._pba_countable(p_person uuid, p_day date)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(sum(public._pba_balance_at(acc.id, p_day)), 0)
    FROM pba_accounts acc
   WHERE acc.person_id = p_person AND acc.kind IN ('bank', 'pay_card', 'cash')
     AND (acc.closed_on IS NULL OR acc.closed_on >= p_day)
$$;

-- purchases over $50 in a month still missing their receipt (or a fully signed affidavit)
CREATE OR REPLACE FUNCTION public._pba_missing_receipts(p_person uuid, p_month date)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT count(*)::integer FROM pba_transactions t
   WHERE t.person_id = p_person AND t.entry_date BETWEEN p_month AND public._pba_month_end(p_month)
     AND public._pba_needs_receipt(t)
     AND NOT EXISTS (SELECT 1 FROM pba_receipts r WHERE r.transaction_id = t.id)
     AND NOT public._pba_affidavit_complete(t.id)
$$;

-- the due dates of a month's cycle (in the next month): B day 5, C day 10, D day 15, G day 30 (or the last day)
CREATE OR REPLACE FUNCTION public._pba_due(p_month date, p_step text)
RETURNS date
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_step
    WHEN 'B' THEN (date_trunc('month', p_month) + interval '1 month')::date + 4
    WHEN 'C' THEN (date_trunc('month', p_month) + interval '1 month')::date + 9
    WHEN 'D' THEN (date_trunc('month', p_month) + interval '1 month')::date + 14
    ELSE least((date_trunc('month', p_month) + interval '1 month')::date + 29, (date_trunc('month', p_month) + interval '2 month' - interval '1 day')::date)
  END
$$;

-- is a step done?
CREATE OR REPLACE FUNCTION public._pba_step_done(p_person uuid, p_month date, p_step text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE p_step
    WHEN 'B' THEN EXISTS (SELECT 1 FROM pba_form_b f WHERE f.person_id = p_person AND f.month = p_month)
    WHEN 'C' THEN EXISTS (SELECT 1 FROM pba_form_c f WHERE f.person_id = p_person AND f.month = p_month)
    WHEN 'D' THEN EXISTS (SELECT 1 FROM pba_form_d f WHERE f.person_id = p_person AND f.month = p_month)
    ELSE EXISTS (SELECT 1 FROM pba_form_g f WHERE f.person_id = p_person AND f.month = p_month)
  END
$$;

-- every month of a Person's cycle from enrollment through last month: each step's status and due date
CREATE OR REPLACE FUNCTION public._pba_cycle(p_person uuid, p_today date DEFAULT NULL)
RETURNS TABLE (o_month date, o_step text, o_status text, o_due date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH t AS (SELECT coalesce(p_today, public._pba_today()) AS today),
       e AS (SELECT date_trunc('month', en.started_on)::date AS first_month
               FROM pba_enrollments en WHERE en.person_id = p_person AND en.ended_on IS NULL),
       months AS (SELECT gs::date AS m FROM e, t,
                         generate_series(e.first_month, (date_trunc('month', t.today) - interval '1 month')::date, interval '1 month') gs)
  SELECT months.m, s.step,
         CASE WHEN public._pba_step_done(p_person, months.m, s.step) THEN 'done'
              WHEN t.today > public._pba_due(months.m, s.step) THEN 'overdue'
              WHEN public._pba_due(months.m, s.step) - t.today <= 3 THEN 'due_soon'
              ELSE 'open' END,
         public._pba_due(months.m, s.step)
    FROM months CROSS JOIN t CROSS JOIN (VALUES ('B', 1), ('C', 2), ('D', 3), ('G', 4)) AS s(step, ord)
   ORDER BY months.m, s.ord
$$;

-- Form D's checklist, pre-checked from the record (R2-5)
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
  v_resp := EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person AND r.month >= p_month);
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

-- ── 4. Writes ────────────────────────────────────────────────────────────
-- a signature row with the database's own fingerprint of the content (Decision 7)
CREATE OR REPLACE FUNCTION public._pba_add_signature(p_org uuid, p_person uuid, p_form_type text, p_form_id uuid, p_capacity text,
                                                     p_kind text, p_staff uuid, p_name text, p_attest text, p_content jsonb,
                                                     p_drawn uuid, p_scan uuid, p_witness uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid;
BEGIN
  IF length(btrim(coalesce(p_name, ''))) = 0 OR length(btrim(coalesce(p_attest, ''))) = 0 THEN RAISE EXCEPTION 'Type the signer''s name to sign'; END IF;
  INSERT INTO pba_signatures (org_id, person_id, form_type, form_id, capacity, signer_kind, signer_staff_id, signer_name, attestation,
                              content_sha256, drawn_file_id, scan_file_id, witnessed_by_staff_id)
  VALUES (p_org, p_person, p_form_type, p_form_id, p_capacity, p_kind, p_staff, btrim(p_name), p_attest,
          encode(sha256(convert_to(p_content::text, 'UTF8')), 'hex'), p_drawn, p_scan, p_witness)
  RETURNING id INTO v_id;
  PERFORM public._pba_audit(p_org, 'pba_form_signed', 'pba_signatures', v_id, NULL,
                            jsonb_build_object('form_type', p_form_type, 'form_id', p_form_id, 'capacity', p_capacity));
  RETURN v_id;
END;
$$;

-- 4a. the column mapping (the PBA Manager, the owner or the Compliance Director)
CREATE OR REPLACE FUNCTION public._pba_save_mapping(p_account uuid, p_map jsonb, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE acc record; a record;
BEGIN
  SELECT * INTO acc FROM pba_accounts WHERE id = p_account;
  IF NOT FOUND OR acc.person_id IS NULL THEN RAISE EXCEPTION 'That account isn''t a Person''s own account'; END IF;
  SELECT * INTO a FROM public._pba_access(acc.person_id, p_actor, p_actor_role);
  IF NOT (a.o_write OR a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only this Person''s PBA Manager, the owner or the Compliance Director can set the file layout'; END IF;
  INSERT INTO pba_statement_mappings (account_id, org_id, person_id, headers, date_col, desc_col, amount_col, debit_col, credit_col, date_format, updated_by, updated_at)
  VALUES (p_account, a.o_org, acc.person_id, p_map->'headers', (p_map->>'date_col')::integer, (nullif(p_map->>'desc_col', ''))::integer,
          (nullif(p_map->>'amount_col', ''))::integer, (nullif(p_map->>'debit_col', ''))::integer, (nullif(p_map->>'credit_col', ''))::integer,
          p_map->>'date_format', p_actor, now())
  ON CONFLICT (account_id) DO UPDATE SET headers = EXCLUDED.headers, date_col = EXCLUDED.date_col, desc_col = EXCLUDED.desc_col,
    amount_col = EXCLUDED.amount_col, debit_col = EXCLUDED.debit_col, credit_col = EXCLUDED.credit_col,
    date_format = EXCLUDED.date_format, updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM public._pba_audit(a.o_org, 'pba_mapping_saved', 'pba_statement_mappings', p_account, NULL, p_map);
END;
$$;

-- 4b. a statement and its lines (the PBA Manager). The client-supplied id makes a retry return the same statement.
CREATE OR REPLACE FUNCTION public._pba_import_statement(p_id uuid, p_account uuid, p_month date, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE acc record; a record; v_month date := date_trunc('month', p_month)::date; v_ps date; v_pe date; x jsonb; i integer := 0; v_d date; v_amt numeric;
BEGIN
  IF EXISTS (SELECT 1 FROM pba_statements s WHERE s.id = p_id) THEN
    IF EXISTS (SELECT 1 FROM pba_statements s WHERE s.id = p_id AND s.account_id = p_account) THEN RETURN p_id; END IF;
    RAISE EXCEPTION 'That statement id is already used';
  END IF;
  SELECT * INTO acc FROM pba_accounts WHERE id = p_account;
  IF NOT FOUND OR acc.person_id IS NULL THEN RAISE EXCEPTION 'That account isn''t a Person''s own account'; END IF;
  IF acc.kind = 'cash' THEN RAISE EXCEPTION 'Cash on hand has no statement — record its count instead'; END IF;
  SELECT * INTO a FROM public._pba_access(acc.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can add statements'; END IF;
  IF public._pba_month_closed(acc.person_id, v_month) THEN RAISE EXCEPTION '% is already closed', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF EXISTS (SELECT 1 FROM pba_statements s WHERE s.account_id = p_account AND s.month = v_month) THEN
    RAISE EXCEPTION 'This account already has a statement for % — discard it first to replace it', to_char(v_month, 'FMMonth YYYY');
  END IF;
  v_ps := coalesce((nullif(p_data->>'period_start', ''))::date, v_month);
  v_pe := coalesce((nullif(p_data->>'period_end', ''))::date, public._pba_month_end(v_month));
  IF date_trunc('month', v_pe)::date <> v_month OR v_ps > v_pe THEN RAISE EXCEPTION 'The statement period must end in %', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF (p_data->>'opening_balance') IS NULL OR (p_data->>'closing_balance') IS NULL THEN RAISE EXCEPTION 'Enter the statement''s beginning and ending balances'; END IF;
  INSERT INTO pba_statements (id, org_id, person_id, account_id, month, period_start, period_end, opening_balance, closing_balance, source, file_id, created_by)
  VALUES (p_id, a.o_org, acc.person_id, p_account, v_month, v_ps, v_pe, (p_data->>'opening_balance')::numeric, (p_data->>'closing_balance')::numeric,
          coalesce(nullif(p_data->>'source', ''), 'manual'), (nullif(p_data->>'file_id', ''))::uuid, p_actor);
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_data->'lines', '[]'::jsonb)) LOOP
    i := i + 1;
    v_d := (x->>'date')::date; v_amt := (x->>'amount')::numeric;
    IF v_d < v_ps OR v_d > v_pe THEN RAISE EXCEPTION 'Line % (%) is outside the statement period', i, v_d; END IF;
    IF v_amt IS NULL OR v_amt = 0 THEN RAISE EXCEPTION 'Line % has no amount', i; END IF;
    INSERT INTO pba_statement_lines (org_id, person_id, statement_id, account_id, line_no, line_date, description, amount)
    VALUES (a.o_org, acc.person_id, p_id, p_account, i, v_d, nullif(btrim(x->>'description'), ''), v_amt);
  END LOOP;
  PERFORM public._pba_audit(a.o_org, 'pba_statement_added', 'pba_statements', p_id, NULL,
                            jsonb_build_object('account_id', p_account, 'month', v_month, 'lines', i, 'file_id', p_data->>'file_id'));
  RETURN p_id;
END;
$$;

-- add one manual line to an open statement
CREATE OR REPLACE FUNCTION public._pba_add_line(p_statement uuid, p_line jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE st record; a record; v_id uuid; v_d date := (p_line->>'date')::date; v_amt numeric := (p_line->>'amount')::numeric;
BEGIN
  SELECT * INTO st FROM pba_statements WHERE id = p_statement;
  IF NOT FOUND THEN RAISE EXCEPTION 'That statement doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(st.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can change statements'; END IF;
  IF public._pba_month_closed(st.person_id, st.month) THEN RAISE EXCEPTION '% is already closed', to_char(st.month, 'FMMonth YYYY'); END IF;
  IF v_d < st.period_start OR v_d > st.period_end THEN RAISE EXCEPTION 'That date is outside the statement period'; END IF;
  IF v_amt IS NULL OR v_amt = 0 THEN RAISE EXCEPTION 'Enter the amount (+ into the account, − out of it)'; END IF;
  INSERT INTO pba_statement_lines (org_id, person_id, statement_id, account_id, line_no, line_date, description, amount)
  VALUES (st.org_id, st.person_id, st.id, st.account_id,
          coalesce((SELECT max(line_no) FROM pba_statement_lines WHERE statement_id = st.id), 0) + 1, v_d, nullif(btrim(p_line->>'description'), ''), v_amt)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- discard an open statement (its source file stays in the add-only bucket)
CREATE OR REPLACE FUNCTION public._pba_discard_statement(p_statement uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE st record; a record;
BEGIN
  SELECT * INTO st FROM pba_statements WHERE id = p_statement FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO a FROM public._pba_access(st.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can discard statements'; END IF;
  IF public._pba_month_closed(st.person_id, st.month) THEN RAISE EXCEPTION '% is closed — its statement is part of the sealed record', to_char(st.month, 'FMMonth YYYY'); END IF;
  DELETE FROM pba_statement_lines WHERE statement_id = st.id;
  DELETE FROM pba_statements WHERE id = st.id;
  PERFORM public._pba_audit(st.org_id, 'pba_statement_discard', 'pba_statements', st.id, to_jsonb(st), NULL);
END;
$$;

-- 4c. matching (R2-3): the PBA Manager confirms; the amount must be the entry's exact effect on that account
CREATE OR REPLACE FUNCTION public._pba_match(p_line uuid, p_txn uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l record; st record; t pba_transactions; a record;
BEGIN
  SELECT * INTO l FROM pba_statement_lines WHERE id = p_line FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That statement line doesn''t exist'; END IF;
  SELECT * INTO st FROM pba_statements WHERE id = l.statement_id;
  SELECT * INTO a FROM public._pba_access(l.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can match statement lines'; END IF;
  IF public._pba_month_closed(l.person_id, st.month) THEN RAISE EXCEPTION '% is closed', to_char(st.month, 'FMMonth YYYY'); END IF;
  IF l.matched_txn_id IS NOT NULL THEN
    IF l.matched_txn_id = p_txn THEN RETURN; END IF;
    RAISE EXCEPTION 'That line is already matched — unmatch it first';
  END IF;
  SELECT * INTO t FROM pba_transactions WHERE id = p_txn;
  IF NOT FOUND OR t.person_id <> l.person_id OR t.status <> 'active' THEN RAISE EXCEPTION 'That entry isn''t an active entry of this Person'; END IF;
  IF public._pba_effect(t, l.account_id) = 0 THEN RAISE EXCEPTION 'That entry doesn''t touch this account'; END IF;
  IF public._pba_effect(t, l.account_id) <> l.amount THEN
    RAISE EXCEPTION 'The amounts differ: the line is %, the entry is % on this account', l.amount, public._pba_effect(t, l.account_id);
  END IF;
  IF EXISTS (SELECT 1 FROM pba_statement_lines x WHERE x.account_id = l.account_id AND x.matched_txn_id = p_txn) THEN
    RAISE EXCEPTION 'That entry is already matched to another line on this account';
  END IF;
  UPDATE pba_statement_lines SET matched_txn_id = p_txn, matched_by = p_actor, matched_at = now() WHERE id = p_line;
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_unmatch(p_line uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l record; st record; a record;
BEGIN
  SELECT * INTO l FROM pba_statement_lines WHERE id = p_line FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO st FROM pba_statements WHERE id = l.statement_id;
  SELECT * INTO a FROM public._pba_access(l.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can change matches'; END IF;
  IF public._pba_month_closed(l.person_id, st.month) THEN RAISE EXCEPTION '% is closed', to_char(st.month, 'FMMonth YYYY'); END IF;
  UPDATE pba_statement_lines SET matched_txn_id = NULL, matched_by = NULL, matched_at = NULL WHERE id = p_line;
END;
$$;

-- an unmatched bank line becomes a ledger entry (pre-filled from the line), already matched
CREATE OR REPLACE FUNCTION public._pba_entry_from_line(p_new_id uuid, p_line uuid, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE l record; v_data jsonb;
BEGIN
  SELECT * INTO l FROM pba_statement_lines WHERE id = p_line;
  IF NOT FOUND THEN RAISE EXCEPTION 'That statement line doesn''t exist'; END IF;
  IF l.matched_txn_id IS NOT NULL THEN
    IF l.matched_txn_id = p_new_id THEN RETURN p_new_id; END IF;
    RAISE EXCEPTION 'That line is already matched';
  END IF;
  v_data := jsonb_build_object('account_id', l.account_id, 'entry_date', l.line_date, 'amount', abs(l.amount),
                               'type', CASE WHEN l.amount > 0 THEN 'deposit' ELSE 'withdrawal' END, 'payee', l.description)
            || coalesce(p_data, '{}'::jsonb) - ARRAY['account_id', 'amount', 'entry_date'];
  PERFORM public._pba_record_txn(p_new_id, l.person_id, v_data, p_actor, p_actor_role);
  PERFORM public._pba_match(p_line, p_new_id, p_actor, p_actor_role);
  RETURN p_new_id;
END;
$$;

-- an entry with no statement line yet, explained (e.g. an uncleared check)
CREATE OR REPLACE FUNCTION public._pba_explain(p_txn uuid, p_account uuid, p_month date, p_text text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE t pba_transactions; a record; v_month date := date_trunc('month', p_month)::date;
BEGIN
  SELECT * INTO t FROM pba_transactions WHERE id = p_txn;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(t.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can explain entries'; END IF;
  IF public._pba_month_closed(t.person_id, v_month) THEN RAISE EXCEPTION '% is closed', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF length(btrim(coalesce(p_text, ''))) = 0 THEN RAISE EXCEPTION 'Write the explanation'; END IF;
  INSERT INTO pba_unmatched_notes (org_id, person_id, month, txn_id, account_id, explanation, created_by)
  VALUES (t.org_id, t.person_id, v_month, p_txn, p_account, btrim(p_text), p_actor)
  ON CONFLICT (txn_id, account_id, month) DO UPDATE SET explanation = EXCLUDED.explanation, created_by = EXCLUDED.created_by, created_at = now();
END;
$$;

-- cash on hand: the monthly count
CREATE OR REPLACE FUNCTION public._pba_cash_count(p_account uuid, p_month date, p_counted numeric, p_note text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE acc record; a record; v_month date := date_trunc('month', p_month)::date;
BEGIN
  SELECT * INTO acc FROM pba_accounts WHERE id = p_account;
  IF NOT FOUND OR acc.kind <> 'cash' OR acc.person_id IS NULL THEN RAISE EXCEPTION 'That isn''t a cash-on-hand account'; END IF;
  SELECT * INTO a FROM public._pba_access(acc.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can record the cash count'; END IF;
  IF public._pba_month_closed(acc.person_id, v_month) THEN RAISE EXCEPTION '% is closed', to_char(v_month, 'FMMonth YYYY'); END IF;
  INSERT INTO pba_cash_counts (org_id, person_id, account_id, month, counted, note, created_by)
  VALUES (a.o_org, acc.person_id, p_account, v_month, p_counted, nullif(btrim(p_note), ''), p_actor)
  ON CONFLICT (account_id, month) DO UPDATE SET counted = EXCLUDED.counted, note = EXCLUDED.note, created_by = EXCLUDED.created_by, created_at = now();
END;
$$;

-- 4d. Form B — reconcile, sign, SEAL (R2-1); the official asset check (R2-7)
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

-- 4e. Form C — the review with the Person (R2-4); signed by the PBA Manager, plus the Person / guardian or an exception
CREATE OR REPLACE FUNCTION public._pba_complete_form_c(p_person uuid, p_month date, p_data jsonb, p_name text, p_attest text,
                                                       p_person_sig jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_month date := date_trunc('month', p_month)::date; v_id uuid; v_review date; v_exc text; v_kind text; v_content jsonb;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager completes the monthly review'; END IF;
  IF NOT public._pba_step_done(p_person, v_month, 'B') THEN RAISE EXCEPTION 'Close % (Form B) first', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF public._pba_step_done(p_person, v_month, 'C') THEN RAISE EXCEPTION 'The % review is already complete', to_char(v_month, 'FMMonth YYYY'); END IF;
  v_review := (p_data->>'review_date')::date;
  IF v_review IS NULL OR v_review > public._pba_today() THEN RAISE EXCEPTION 'Enter the date of the review (not in the future)'; END IF;
  v_exc := nullif(btrim(p_data->>'exception_reason'), '');
  v_kind := p_person_sig->>'kind';
  IF p_person_sig IS NULL AND v_exc IS NULL THEN RAISE EXCEPTION 'The Person (or guardian) signs — or record why they can''t'; END IF;
  IF p_person_sig IS NOT NULL AND (v_kind NOT IN ('person', 'guardian')
       OR ((p_person_sig->>'drawn_file') IS NULL AND (p_person_sig->>'scan_file') IS NULL)) THEN
    RAISE EXCEPTION 'The Person''s signature needs to be drawn on screen or attached as a scan';
  END IF;
  INSERT INTO pba_form_c (org_id, person_id, month, review_date, mode, attendees, person_comments, exception_reason, created_by)
  VALUES (a.o_org, p_person, v_month, v_review, coalesce(p_data->>'mode', 'in_person'), nullif(btrim(p_data->>'attendees'), ''),
          nullif(btrim(p_data->>'person_comments'), ''), CASE WHEN p_person_sig IS NULL THEN v_exc END, p_actor)
  RETURNING id INTO v_id;
  SELECT to_jsonb(c) INTO v_content FROM pba_form_c c WHERE c.id = v_id;
  PERFORM public._pba_add_signature(a.o_org, p_person, 'form_c', v_id, 'preparer', 'staff', p_actor, p_name, p_attest, v_content, NULL, NULL, NULL);
  IF p_person_sig IS NOT NULL THEN
    IF (p_person_sig->>'drawn_file') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = (p_person_sig->>'drawn_file')::uuid AND f.person_id = p_person AND f.purpose = 'signature')
       OR (p_person_sig->>'scan_file') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = (p_person_sig->>'scan_file')::uuid AND f.person_id = p_person AND f.purpose = 'form_scan') THEN
      RAISE EXCEPTION 'That signature file isn''t on file for this Person';
    END IF;
    PERFORM public._pba_add_signature(a.o_org, p_person, 'form_c', v_id, v_kind, v_kind, NULL, p_person_sig->>'name',
              coalesce(nullif(p_person_sig->>'attestation', ''), 'I reviewed my money for the month with my PBA Manager.'), v_content,
              (nullif(p_person_sig->>'drawn_file', ''))::uuid, (nullif(p_person_sig->>'scan_file', ''))::uuid, p_actor);
  END IF;
  PERFORM public._pba_audit(a.o_org, 'pba_form_c_done', 'pba_form_c', v_id, NULL, jsonb_build_object('month', v_month, 'exception', v_exc IS NOT NULL AND p_person_sig IS NULL));
  RETURN v_id;
END;
$$;

-- 4f. Form D — the administrative review (R2-5): the reviewer only; findings open items for the Compliance Director
CREATE OR REPLACE FUNCTION public._pba_complete_form_d(p_person uuid, p_month date, p_checklist jsonb, p_findings jsonb, p_name text, p_attest text,
                                                       p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_month date := date_trunc('month', p_month)::date; v_id uuid; x jsonb; v_list jsonb;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF coalesce(a.o_role, '') <> 'reviewer' THEN RAISE EXCEPTION 'Only this Person''s Administrative Reviewer completes Form D'; END IF;
  IF NOT public._pba_step_done(p_person, v_month, 'C') THEN RAISE EXCEPTION 'The % review with the Person (Form C) comes first', to_char(v_month, 'FMMonth YYYY'); END IF;
  IF public._pba_step_done(p_person, v_month, 'D') THEN RAISE EXCEPTION 'The % administrative review is already complete', to_char(v_month, 'FMMonth YYYY'); END IF;
  v_list := coalesce(p_findings, '[]'::jsonb);
  IF jsonb_typeof(v_list) <> 'array' THEN RAISE EXCEPTION 'Findings must be a list'; END IF;
  INSERT INTO pba_form_d (org_id, person_id, month, checklist, created_by)
  VALUES (a.o_org, p_person, v_month,
          jsonb_build_object('prechecks', public._pba_form_d_prechecks(p_person, v_month), 'reviewer', coalesce(p_checklist, '{}'::jsonb), 'findings', v_list), p_actor)
  RETURNING id INTO v_id;
  PERFORM public._pba_add_signature(a.o_org, p_person, 'form_d', v_id, 'reviewer', 'staff', p_actor, p_name, p_attest,
                                    (SELECT to_jsonb(f) FROM pba_form_d f WHERE f.id = v_id), NULL, NULL, NULL);
  FOR x IN SELECT * FROM jsonb_array_elements(v_list) LOOP
    IF length(btrim(coalesce(x #>> '{}', ''))) > 0 THEN
      INSERT INTO pba_findings (org_id, person_id, month, form_d_id, finding) VALUES (a.o_org, p_person, v_month, v_id, btrim(x #>> '{}'));
    END IF;
  END LOOP;
  PERFORM public._pba_audit(a.o_org, 'pba_form_d_done', 'pba_form_d', v_id, NULL, jsonb_build_object('month', v_month, 'findings', jsonb_array_length(v_list)));
  RETURN v_id;
END;
$$;

-- a finding's response: the Compliance Director (never for a Person they manage) or the owner
CREATE OR REPLACE FUNCTION public._pba_answer_finding(p_finding uuid, p_response text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE f record; a record;
BEGIN
  SELECT * INTO f FROM pba_findings WHERE id = p_finding FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That finding doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(f.person_id, p_actor, p_actor_role);
  IF NOT (a.o_owner OR (a.o_cd AND coalesce(a.o_role, '') <> 'manager')) THEN
    RAISE EXCEPTION 'The Compliance Director answers findings — or the owner when the Compliance Director manages this Person''s money';
  END IF;
  IF length(btrim(coalesce(p_response, ''))) = 0 THEN RAISE EXCEPTION 'Write the response'; END IF;
  UPDATE pba_findings SET response = btrim(p_response), responded_by = p_actor, responded_at = now() WHERE id = p_finding;
  PERFORM public._pba_audit(f.org_id, 'pba_finding_answered', 'pba_findings', p_finding, NULL, jsonb_build_object('response', p_response));
END;
$$;

-- 4g. Form G — the SC report (R2-6): the package PDF on file + how it was sent
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
  IF v_file IS NULL OR NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = v_file AND f.person_id = p_person) THEN RAISE EXCEPTION 'The report PDF isn''t on file'; END IF;
  INSERT INTO pba_form_g (org_id, person_id, month, sent_on, sent_to_name, sent_to_email, method, file_id, created_by)
  VALUES (a.o_org, p_person, v_month, v_sent, coalesce(btrim(p_data->>'sent_to_name'), ''), nullif(btrim(p_data->>'sent_to_email'), ''),
          coalesce(btrim(p_data->>'method'), ''), v_file, p_actor)
  RETURNING id INTO v_id;
  PERFORM public._pba_audit(a.o_org, 'pba_form_g_sent', 'pba_form_g', v_id, NULL, p_data);
  RETURN v_id;
END;
$$;

-- 4h. benefits: the asset response (R2-7), spend-down, SSA payee accounting
CREATE OR REPLACE FUNCTION public._pba_save_asset_response(p_person uuid, p_month date, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_month date := date_trunc('month', p_month)::date;
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

CREATE OR REPLACE FUNCTION public._pba_save_spenddown(p_person uuid, p_month date, p_amount numeric, p_due date, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_write OR a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only this Person''s PBA Manager, the owner or the Compliance Director records spend-down'; END IF;
  IF p_due IS NULL THEN RAISE EXCEPTION 'Enter the due date'; END IF;
  INSERT INTO pba_spenddowns (org_id, person_id, month, amount, due_date, created_by)
  VALUES (a.o_org, p_person, date_trunc('month', p_month)::date, p_amount, p_due, p_actor)
  ON CONFLICT (person_id, month) DO UPDATE SET amount = EXCLUDED.amount, due_date = EXCLUDED.due_date;
  PERFORM public._pba_audit(a.o_org, 'pba_spenddown_saved', 'pba_spenddowns', p_person, NULL, jsonb_build_object('month', p_month, 'amount', p_amount, 'due', p_due));
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
  IF NOT EXISTS (SELECT 1 FROM pba_transactions t WHERE t.id = p_txn AND t.person_id = s.person_id AND t.status = 'active' AND t.type IN ('withdrawal', 'transfer')) THEN
    RAISE EXCEPTION 'That isn''t an active payment of this Person';
  END IF;
  UPDATE pba_spenddowns SET paid_txn_id = p_txn WHERE id = p_spenddown;
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_save_payee_report(p_id uuid, p_person uuid, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_write OR a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only this Person''s PBA Manager, the owner or the Compliance Director records SSA payee reports'; END IF;
  INSERT INTO pba_payee_reports (id, org_id, person_id, requested_on, due_date, completed_on, notes, created_by)
  VALUES (p_id, a.o_org, p_person, (p_data->>'requested_on')::date, (p_data->>'due_date')::date, (nullif(p_data->>'completed_on', ''))::date,
          nullif(btrim(p_data->>'notes'), ''), p_actor)
  ON CONFLICT (id) DO UPDATE SET completed_on = EXCLUDED.completed_on, notes = coalesce(EXCLUDED.notes, pba_payee_reports.notes),
    due_date = EXCLUDED.due_date
  WHERE pba_payee_reports.person_id = p_person;
  RETURN p_id;
END;
$$;

-- 4i. match suggestions (R2-3): same account, the exact amount, within 3 days; "exact" when it's the only candidate both ways
CREATE OR REPLACE FUNCTION public._pba_match_suggestions(p_person uuid, p_month date)
RETURNS TABLE (o_line_id uuid, o_txn_id uuid, o_exact boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH lines AS (
    SELECT l.* FROM pba_statement_lines l JOIN pba_statements s ON s.id = l.statement_id
     WHERE s.person_id = p_person AND s.month = date_trunc('month', p_month)::date AND l.matched_txn_id IS NULL),
  cands AS (
    SELECT l.id AS line_id, t.id AS txn_id, abs(t.entry_date - l.line_date) AS gap
      FROM lines l JOIN pba_transactions t
        ON t.person_id = p_person AND t.status = 'active' AND (t.account_id = l.account_id OR t.to_account_id = l.account_id)
       AND public._pba_effect(t, l.account_id) = l.amount AND abs(t.entry_date - l.line_date) <= 3
     WHERE NOT EXISTS (SELECT 1 FROM pba_statement_lines x WHERE x.account_id = l.account_id AND x.matched_txn_id = t.id))
  SELECT c.line_id, c.txn_id,
         (SELECT count(*) FROM cands c2 WHERE c2.line_id = c.line_id) = 1 AND (SELECT count(*) FROM cands c3 WHERE c3.txn_id = c.txn_id) = 1
    FROM cands c ORDER BY c.line_id, c.gap
$$;

CREATE OR REPLACE FUNCTION public._pba_flags(p_person uuid, p_today date DEFAULT NULL)
RETURNS TABLE (o_flag text, o_detail text, o_ref uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org    uuid;
  v_today  date := coalesce(p_today, public._pba_today());
  v_status text := public._pba_enrollment_status(p_person);
  v_tp_n   integer; v_tp_amt numeric; v_tp_days integer;
  v_thr numeric; v_live numeric; v_close_month date; v_close_countable numeric;
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
  SELECT f.month, f.countable INTO v_close_month, v_close_countable FROM pba_form_b f WHERE f.person_id = p_person ORDER BY f.month DESC LIMIT 1;
  IF v_close_month IS NOT NULL AND v_close_countable >= v_thr AND v_live >= v_thr
     AND NOT EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person AND r.month >= v_close_month) THEN
    RETURN QUERY SELECT 'asset_alert'::text,
      format('Countable assets were $%s at the %s close (alert at $%s; the SSI resource limit is $2,000) — record the notices to the Person, the residential team and the SC, and a plan',
             to_char(v_close_countable, 'FM999999990.00'), to_char(v_close_month, 'FMMonth YYYY'), to_char(v_thr, 'FM999999990.00')), NULL::uuid;
  ELSIF v_live >= v_thr
     AND NOT EXISTS (SELECT 1 FROM pba_asset_responses r WHERE r.person_id = p_person AND r.month >= coalesce(v_close_month, date_trunc('month', v_today)::date)) THEN
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

-- ── 5. Reads for the app ─────────────────────────────────────────────────
-- one Person's cycle (a reader of the Person)
CREATE OR REPLACE FUNCTION public.pba_cycle(p_person uuid)
RETURNS TABLE (o_month date, o_step text, o_status text, o_due date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.pba_can_read(p_person) THEN RETURN; END IF;
  RETURN QUERY SELECT c.o_month, c.o_step, c.o_status, c.o_due FROM public._pba_cycle(p_person) c;
END;
$$;
-- every enrolled Person's open steps (owner and Compliance Director)
CREATE OR REPLACE FUNCTION public.pba_cycles()
RETURNS TABLE (o_person_id uuid, o_person_name text, o_month date, o_step text, o_status text, o_due date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF coalesce(public.member_role()::text, '') NOT IN ('owner', 'compliance_director') OR public.org_id() IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT e.person_id, btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, ''))::text, c.o_month, c.o_step, c.o_status, c.o_due
    FROM pba_enrollments e JOIN persons p ON p.id = e.person_id
   CROSS JOIN LATERAL public._pba_cycle(e.person_id) c
   WHERE e.org_id = public.org_id() AND e.ended_on IS NULL AND c.o_status <> 'done'
   ORDER BY c.o_due, 2;
END;
$$;
-- one account's reconciliation for a month (a reader of the Person)
CREATE OR REPLACE FUNCTION public.pba_recon(p_account uuid, p_month date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_person uuid;
BEGIN
  SELECT person_id INTO v_person FROM pba_accounts WHERE id = p_account;
  IF v_person IS NULL OR NOT public.pba_can_read(v_person) THEN RETURN NULL; END IF;
  RETURN public._pba_recon(p_account, date_trunc('month', p_month)::date);
END;
$$;
CREATE OR REPLACE FUNCTION public.pba_match_suggestions(p_person uuid, p_month date)
RETURNS TABLE (o_line_id uuid, o_txn_id uuid, o_exact boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.pba_can_read(p_person) THEN RETURN; END IF;
  RETURN QUERY SELECT s.o_line_id, s.o_txn_id, s.o_exact FROM public._pba_match_suggestions(p_person, p_month) s;
END;
$$;
CREATE OR REPLACE FUNCTION public.pba_form_d_prechecks(p_person uuid, p_month date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.pba_can_read(p_person) THEN RETURN NULL; END IF;
  RETURN public._pba_form_d_prechecks(p_person, date_trunc('month', p_month)::date);
END;
$$;
CREATE OR REPLACE FUNCTION public.pba_countable(p_person uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.pba_can_read(p_person) THEN RETURN NULL; END IF;
  RETURN public._pba_countable(p_person, public._pba_today());
END;
$$;

-- ── 6. Public wrappers ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pba_save_mapping(p_account uuid, p_map jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_save_mapping(p_account, p_map, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_import_statement(p_id uuid, p_account uuid, p_month date, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_import_statement(p_id, p_account, p_month, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_add_line(p_statement uuid, p_line jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_add_line(p_statement, p_line, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_discard_statement(p_statement uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_discard_statement(p_statement, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_match(p_line uuid, p_txn uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_match(p_line, p_txn, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_unmatch(p_line uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_unmatch(p_line, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_entry_from_line(p_new_id uuid, p_line uuid, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_entry_from_line(p_new_id, p_line, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_explain(p_txn uuid, p_account uuid, p_month date, p_text text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_explain(p_txn, p_account, p_month, p_text, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_cash_count(p_account uuid, p_month date, p_counted numeric, p_note text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_cash_count(p_account, p_month, p_counted, p_note, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_close_month(p_person uuid, p_month date, p_name text, p_attest text) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_close_month(p_person, p_month, p_name, p_attest, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_complete_form_c(p_person uuid, p_month date, p_data jsonb, p_name text, p_attest text, p_person_sig jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_complete_form_c(p_person, p_month, p_data, p_name, p_attest, p_person_sig, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_complete_form_d(p_person uuid, p_month date, p_checklist jsonb, p_findings jsonb, p_name text, p_attest text) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_complete_form_d(p_person, p_month, p_checklist, p_findings, p_name, p_attest, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_answer_finding(p_finding uuid, p_response text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_answer_finding(p_finding, p_response, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_record_form_g(p_person uuid, p_month date, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_record_form_g(p_person, p_month, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_save_asset_response(p_person uuid, p_month date, p_data jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_save_asset_response(p_person, p_month, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_save_spenddown(p_person uuid, p_month date, p_amount numeric, p_due date) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_save_spenddown(p_person, p_month, p_amount, p_due, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_pay_spenddown(p_spenddown uuid, p_txn uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_pay_spenddown(p_spenddown, p_txn, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_save_payee_report(p_id uuid, p_person uuid, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_save_payee_report(p_id, p_person, p_data, public.my_staff_id(), public.member_role()::text) $$;

-- ── 7. RLS + privileges ──────────────────────────────────────────────────
DO $$
DECLARE tbl text; f record;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['pba_statement_mappings', 'pba_statements', 'pba_statement_lines', 'pba_unmatched_notes', 'pba_cash_counts',
                             'pba_form_b', 'pba_form_c', 'pba_form_d', 'pba_findings', 'pba_form_g', 'pba_asset_responses',
                             'pba_spenddowns', 'pba_payee_reports'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', tbl);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', tbl || '_tenant_guard', tbl);
    EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated
                      USING (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL)', tbl || '_tenant_guard', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', tbl || '_read', tbl);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.pba_can_read(person_id))', tbl || '_read', tbl);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '\_pba\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace
              AND p.proname IN ('pba_cycle', 'pba_cycles', 'pba_recon', 'pba_match_suggestions', 'pba_form_d_prechecks', 'pba_countable',
                                'pba_save_mapping', 'pba_import_statement', 'pba_add_line', 'pba_discard_statement', 'pba_match', 'pba_unmatch',
                                'pba_entry_from_line', 'pba_explain', 'pba_cash_count', 'pba_close_month', 'pba_complete_form_c',
                                'pba_complete_form_d', 'pba_answer_finding', 'pba_record_form_g', 'pba_save_asset_response',
                                'pba_save_spenddown', 'pba_pay_spenddown', 'pba_save_payee_report', 'provly_setting') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';


-- ── 8. Self-test: a synthetic Person through a whole January 2001 close; rolled back ──
CREATE TEMP TABLE IF NOT EXISTS v20030_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20030_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20030_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.30 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res jsonb := '[]'::jsonb; v_fail text; v_step text := 'setup';
  v_org uuid; v_person uuid; s_owner uuid; s_cd uuid; s_mgr uuid; s_rev uuid; s_aud uuid; v_pba uuid;
  v_bank uuid := gen_random_uuid(); v_cash uuid := gen_random_uuid(); v_stmt uuid := gen_random_uuid();
  t_ssi uuid := gen_random_uuid(); t_rent uuid := gen_random_uuid(); t_store uuid := gen_random_uuid(); t_xfer uuid := gen_random_uuid();
  t_cash uuid := gen_random_uuid(); t_check uuid := gen_random_uuid(); t_fee uuid := gen_random_uuid(); t_feb uuid := gen_random_uuid();
  v_formA uuid; v_fid uuid; v_line uuid; v_fb uuid; v_fd uuid; v_find uuid; v_sd uuid; v_pr uuid := gen_random_uuid();
  v_jan date := DATE '2001-01-01'; v_today date := DATE '2001-02-16';
  v_msg text; v_txt text; v_n integer; s record; r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s2.org_id INTO v_org FROM staff s2 ORDER BY s2.created_at NULLS LAST, s2.id LIMIT 1;
  SELECT id INTO v_pba FROM service_code_definitions WHERE code = 'PBA' LIMIT 1;
  BEGIN
    v_person := pg_temp.v20030_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20030', 'last_name', 'Selftest', 'identification_number', '099999935', 'is_active', true));
    s_owner := pg_temp.v20030_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R30test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20030_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R30test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20030_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R30test', 'last_name', 'Manager'));
    s_rev   := pg_temp.v20030_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R30test', 'last_name', 'Reviewer'));
    s_aud   := pg_temp.v20030_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'R30test', 'last_name', 'Auditor'));
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    UPDATE pba_enrollments SET started_on = v_jan WHERE person_id = v_person;          -- the record began in January 2001
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    PERFORM public._pba_assign_role(v_person, s_rev, 'reviewer', s_cd, 'compliance_director');
    PERFORM public._pba_assign_role(v_person, s_aud, 'auditor', s_cd, 'compliance_director');
    UPDATE pba_role_assignments SET start_date = v_jan WHERE person_id = v_person;     -- the roles began with the record
    v_fid := gen_random_uuid();
    INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, uploaded_by)
    VALUES (v_fid, v_org, v_person, 'fiduciary_proof', v_org || '/' || v_person || '/documents/' || v_fid || '.pdf', repeat('a', 64), s_owner);
    PERFORM public._pba_set_enrollment(v_person, 'voluntary', v_fid, s_owner, 'owner');
    v_formA := public._pba_save_form_a(v_person, '[{"name": "Mother", "relationship": "mother", "reason": "Declined"}]'::jsonb, s_mgr, 'dsp');
    PERFORM public._pba_sign('form_a', v_formA, 'staff', 'R30test Manager', 'Prepared', NULL, NULL, s_mgr, 'dsp');
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'institution', 'Zions', 'last4', '4321', 'titling', 'V20030 Selftest',
              'opening_balance', 1000, 'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');
    PERFORM public._pba_save_account(v_cash, v_person, jsonb_build_object('kind', 'cash', 'titling', 'V20030 Selftest — cash', 'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');

    v_step := 'January ledger';
    PERFORM public._pba_record_txn(t_ssi, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-03', 'type', 'deposit', 'amount', 943, 'payee', 'SSA', 'category', 'benefit_deposit'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t_rent, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-05', 'type', 'withdrawal', 'amount', 300, 'payee', 'Host home', 'category', 'room_board'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t_store, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-10', 'type', 'withdrawal', 'amount', 60, 'payee', 'Store', 'category', 'clothing'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t_xfer, v_person, jsonb_build_object('account_id', v_bank, 'to_account_id', v_cash, 'entry_date', '2001-01-12', 'type', 'transfer', 'amount', 40), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t_cash, v_person, jsonb_build_object('account_id', v_cash, 'entry_date', '2001-01-13', 'type', 'withdrawal', 'amount', 15, 'handed_to', 'person', 'purpose', 'Movies'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(t_check, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-28', 'type', 'withdrawal', 'amount', 100, 'payee', 'Check 101 — dentist', 'category', 'medical'), s_mgr, 'dsp');
    FOR s IN SELECT x AS t FROM unnest(ARRAY[t_rent, t_store, t_check]) x LOOP
      v_fid := gen_random_uuid();
      INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, uploaded_by)
      VALUES (v_fid, v_org, v_person, 'receipt', v_org || '/' || v_person || '/receipts/' || v_fid || '.jpg', repeat('b', 64), s_mgr);
      PERFORM public._pba_attach_receipt(s.t, v_fid, s_mgr, 'dsp');
    END LOOP;

    -- S1: the column mapping is kept per account; the statement imports (fee 2.00 not yet in the ledger)
    v_step := 'S1 statement';
    PERFORM public._pba_save_mapping(v_bank, '{"headers": ["Date", "Description", "Amount"], "date_col": 0, "desc_col": 1, "amount_col": 2, "date_format": "MM/DD/YYYY"}'::jsonb, s_mgr, 'dsp');
    PERFORM public._pba_import_statement(v_stmt, v_bank, v_jan, jsonb_build_object('source', 'import', 'opening_balance', 1000, 'closing_balance', 1541,
      'lines', '[{"date": "2001-01-03", "description": "SSA TREAS 310", "amount": 943},
                 {"date": "2001-01-05", "description": "CHECK 100", "amount": -300},
                 {"date": "2001-01-11", "description": "STORE #12", "amount": -60},
                 {"date": "2001-01-12", "description": "ATM", "amount": -40},
                 {"date": "2001-01-31", "description": "SERVICE FEE", "amount": -2}]'::jsonb), s_mgr, 'dsp');
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'S1 mapping saved; a 5-line January statement imported; a retry returns the same statement',
      (SELECT date_format FROM pba_statement_mappings WHERE account_id = v_bank) || '; lines ' || (SELECT count(*) FROM pba_statement_lines WHERE statement_id = v_stmt)
      || '; retry ' || CASE WHEN public._pba_import_statement(v_stmt, v_bank, v_jan, '{}'::jsonb, s_mgr, 'dsp') = v_stmt THEN 'same' ELSE 'NEW' END,
      'MM/DD/YYYY; lines 5; retry same'));

    -- S2: Form B is refused while anything is open
    v_step := 'S2 premature close';
    v_msg := '';
    BEGIN PERFORM public._pba_close_month(v_person, v_jan, 'R30test Manager', 'Reconciled', s_mgr, 'dsp'); v_msg := 'close ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := CASE WHEN SQLERRM LIKE '%unmatched statement line%' AND SQLERRM LIKE '%no cash count%' THEN 'refused: lines + cash count named' ELSE 'refused: ' || SQLERRM END; END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2, 'S2 closing January before matching and counting', v_msg, 'refused: lines + cash count named'));

    -- S3: suggestions; accept the exact ones; the fee becomes an entry from its line; the uncleared check is explained
    v_step := 'S3 matching';
    SELECT count(*) FILTER (WHERE o_exact) INTO v_n FROM public._pba_match_suggestions(v_person, v_jan);
    v_txt := 'exact ' || v_n;
    FOR s IN SELECT * FROM public._pba_match_suggestions(v_person, v_jan) WHERE o_exact LOOP
      PERFORM public._pba_match(s.o_line_id, s.o_txn_id, s_mgr, 'dsp');
    END LOOP;
    SELECT id INTO v_line FROM pba_statement_lines WHERE statement_id = v_stmt AND matched_txn_id IS NULL;
    v_msg := '';
    BEGIN PERFORM public._pba_match(v_line, t_check, s_mgr, 'dsp'); v_msg := 'wrong amount ALLOWED';      -- the $2 fee line against the $100 check
    EXCEPTION WHEN raise_exception THEN v_msg := 'wrong amount refused'; END;
    PERFORM public._pba_entry_from_line(t_fee, v_line, '{"type": "fee", "category": "other"}'::jsonb, s_mgr, 'dsp');
    PERFORM public._pba_explain(t_check, v_bank, v_jan, 'Check 101 written 1/28, not cleared yet', s_mgr, 'dsp');
    PERFORM public._pba_cash_count(v_cash, v_jan, 25, 'Counted with the Person', s_mgr, 'dsp');
    r := public._pba_recon(v_bank, v_jan);
    v_res := v_res || jsonb_build_array(jsonb_build_array(3,
      'S3 suggestions (4 exact), the fee from its line, a wrong-amount match, the uncleared check explained, cash counted: the bank reconciliation',
      v_txt || '; ' || v_msg || format('; ledger %s = statement %s + outstanding %s; ready %s', r->>'ledger_closing', r->>'statement_closing', r->>'outstanding', r->>'ready'),
      'exact 4; wrong amount refused; ledger 1441.00 = statement 1541.00 + outstanding -100.00; ready true'));

    -- S4: Form B signs and seals; the official asset check (threshold set to $1,400 for the test)
    v_step := 'S4 close';
    PERFORM public._set_org_setting('pba.asset_alert_amount', '1400'::jsonb, s_owner, 'owner', v_org);
    v_fb := public._pba_close_month(v_person, v_jan, 'R30test Manager', 'I reconciled every account for January', s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_edit_txn(t_store, '{"amount": 59}'::jsonb, 'late fix', s_mgr, 'dsp'); v_msg := 'edit ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'edit refused'; END;
    BEGIN PERFORM public._pba_unmatch(v_line, s_mgr, 'dsp'); v_msg := v_msg || '; unmatch ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; unmatch refused'; END;
    SELECT string_agg(f.o_flag, ', ' ORDER BY f.o_flag) INTO v_txt FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag LIKE 'asset%';
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'S4 Form B signed: sealed (edit, unmatch), countable at the close, the asset flag',
      format('closed %s; countable %s; ', public._pba_month_closed(v_person, v_jan)::text, (SELECT countable FROM pba_form_b WHERE id = v_fb)) || v_msg || '; flags ' || coalesce(v_txt, 'none'),
      'closed true; countable 1466.00; edit refused; unmatch refused; flags asset_alert'));

    -- S5: the cycle on Feb 16 (C due the 10th, D the 15th, G the 2nd of March)
    v_step := 'S5 cycle';
    SELECT string_agg(c.o_step || ' ' || c.o_status, ', ' ORDER BY c.o_step) INTO v_txt FROM public._pba_cycle(v_person, v_today) c WHERE c.o_month = v_jan;
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'step_overdue';
    v_res := v_res || jsonb_build_array(jsonb_build_array(5, 'S5 the January cycle on February 16', v_txt || '; overdue flags ' || v_n,
      'B done, C overdue, D overdue, G open; overdue flags 2'));

    -- S6: the asset response clears the alert; Form C with an exception completes and flags
    v_step := 'S6 asset + Form C';
    PERFORM public._pba_save_asset_response(v_person, v_jan, jsonb_build_object('notices', jsonb_build_object('person', '2001-02-06', 'residential', '2001-02-06', 'sc', '2001-02-07'),
              'plan_type', 'planned_purchase', 'plan_detail', 'New winter coat and boots', 'target_date', '2001-02-28'), s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_complete_form_c(v_person, v_jan, jsonb_build_object('review_date', '2001-02-08', 'mode', 'in_person'), 'R30test Manager', 'Reviewed', NULL, s_mgr, 'dsp');
          v_msg := 'no signature and no reason ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'no signature and no reason refused'; END;
    PERFORM public._pba_complete_form_c(v_person, v_jan, jsonb_build_object('review_date', '2001-02-08', 'mode', 'in_person', 'attendees', 'Host',
              'person_comments', 'He wants to save for a bike', 'exception_reason', 'He declined to sign this month'), 'R30test Manager', 'I reviewed January with him', NULL, s_mgr, 'dsp');
    SELECT string_agg(f.o_flag, ', ' ORDER BY f.o_flag) INTO v_txt FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag IN ('asset_alert', 'asset_warning', 'person_did_not_sign');
    v_res := v_res || jsonb_build_array(jsonb_build_array(6, 'S6 asset response recorded; Form C without a signature or reason, then with the exception',
      v_msg || '; flags ' || coalesce(v_txt, 'none'), 'no signature and no reason refused; flags person_did_not_sign'));

    -- S7: Form D — only the reviewer; a finding goes to the Compliance Director
    v_step := 'S7 Form D';
    v_msg := '';
    BEGIN PERFORM public._pba_complete_form_d(v_person, v_jan, '{}'::jsonb, '[]'::jsonb, 'R30test Manager', 'x', s_mgr, 'dsp'); v_msg := 'manager ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'manager refused'; END;
    v_fd := public._pba_complete_form_d(v_person, v_jan, '{"receipts": {"ok": true}}'::jsonb, '["The rent receipt is a photo of the lease, not a receipt"]'::jsonb,
              'R30test Reviewer', 'I reviewed January', s_rev, 'dsp');
    SELECT id INTO v_find FROM pba_findings WHERE form_d_id = v_fd;
    SELECT string_agg(f.o_flag, ', ' ORDER BY f.o_flag) INTO v_txt FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag IN ('finding_open', 'person_did_not_sign');
    v_res := v_res || jsonb_build_array(jsonb_build_array(7, 'S7 Form D by the manager, then by the reviewer with one finding; the prechecks on file',
      v_msg || '; flags ' || coalesce(v_txt, 'none') || '; person_signed_c ' || ((SELECT checklist FROM pba_form_d WHERE id = v_fd) #>> '{prechecks,person_signed_c,ok}')
      || ', balances ' || ((SELECT checklist FROM pba_form_d WHERE id = v_fd) #>> '{prechecks,balances,ok}'),
      'manager refused; flags finding_open; person_signed_c false, balances true'));

    -- S8: the finding is answered; Form G recorded
    v_step := 'S8 answer + Form G';
    v_msg := '';
    BEGIN PERFORM public._pba_answer_finding(v_find, 'ok', s_mgr, 'dsp'); v_msg := 'manager ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'manager refused'; END;
    PERFORM public._pba_answer_finding(v_find, 'Real receipt requested from the host; filed with February', s_cd, 'compliance_director');
    v_fid := gen_random_uuid();
    INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, uploaded_by)
    VALUES (v_fid, v_org, v_person, 'document', v_org || '/' || v_person || '/documents/' || v_fid || '.pdf', repeat('c', 64), s_mgr);
    PERFORM public._pba_record_form_g(v_person, v_jan, jsonb_build_object('sent_on', '2001-02-20', 'sent_to_name', 'Test SC', 'sent_to_email', 'sc@example.com',
              'method', 'Secure email', 'file_id', v_fid), s_mgr, 'dsp');
    SELECT string_agg(c.o_step || ' ' || c.o_status, ', ' ORDER BY c.o_step) INTO v_txt FROM public._pba_cycle(v_person, DATE '2001-02-21') c WHERE c.o_month = v_jan;
    v_res := v_res || jsonb_build_array(jsonb_build_array(8, 'S8 the finding answered by the manager, then the Compliance Director; Form G recorded; the cycle',
      v_msg || '; open findings ' || (SELECT count(*) FROM pba_findings WHERE person_id = v_person AND responded_at IS NULL) || '; ' || v_txt,
      'manager refused; open findings 0; B done, C done, D done, G done'));

    -- S9: spend-down, SSA payee accounting, and PBA time billed by the reviewer
    v_step := 'S9 benefits + billing';
    PERFORM public._pba_save_spenddown(v_person, v_jan, 50, DATE '2001-02-10', s_mgr, 'dsp');
    PERFORM public._pba_save_payee_report(v_pr, v_person, jsonb_build_object('requested_on', '2001-01-15', 'due_date', '2001-02-14'), s_mgr, 'dsp');
    PERFORM pg_temp.v20030_test_insert('service_notes', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'staff_id', s_rev, 'service_code_id', v_pba,
              'service_date', '2001-01-20', 'start_time', '10:00', 'end_time', '11:00', 'duration_minutes', 60, 'billable_units', 1,
              'summary_note', 'v20.0.30 self-test', 'status', 'approved'));
    SELECT string_agg(f.o_flag, ', ' ORDER BY f.o_flag) INTO v_txt FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag IN ('spenddown_overdue', 'payee_report_overdue', 'reviewer_billed');
    SELECT id INTO v_sd FROM pba_spenddowns WHERE person_id = v_person;
    PERFORM public._pba_record_txn(t_feb, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-02-12', 'type', 'withdrawal', 'amount', 50, 'payee', 'Medicaid spend-down'), s_mgr, 'dsp');
    PERFORM public._pba_pay_spenddown(v_sd, t_feb, s_mgr, 'dsp');
    PERFORM public._pba_save_payee_report(v_pr, v_person, jsonb_build_object('requested_on', '2001-01-15', 'due_date', '2001-02-14', 'completed_on', '2001-02-15'), s_mgr, 'dsp');
    SELECT string_agg(f.o_flag, ', ' ORDER BY f.o_flag) INTO v_msg FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag IN ('spenddown_overdue', 'payee_report_overdue', 'reviewer_billed');
    v_res := v_res || jsonb_build_array(jsonb_build_array(9, 'S9 an overdue spend-down and payee report, a PBA note by the reviewer; then paid and completed',
      coalesce(v_txt, 'none') || ' → ' || coalesce(v_msg, 'none'), 'payee_report_overdue, reviewer_billed, spenddown_overdue → reviewer_billed'));

    RAISE EXCEPTION 'v20030_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20030_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 9 THEN
    RAISE EXCEPTION 'v20.0.30 self-test failed, so nothing in this file was applied: %', coalesce(v_fail, format('%s of 9 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20030_selftest (n, item, value, want) SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20030_test_insert(text, jsonb);

COMMIT;


-- ── 9. Verification — paste this table into chat before the PR merges ───
SELECT * FROM (
  SELECT 1 AS n, 'Release 2 tables (13) with RLS on, clients read-only' AS check_item,
    ((SELECT count(*) FILTER (WHERE c.relrowsecurity) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
        AND c.relname IN ('pba_statement_mappings', 'pba_statements', 'pba_statement_lines', 'pba_unmatched_notes', 'pba_cash_counts', 'pba_form_b',
                          'pba_form_c', 'pba_form_d', 'pba_findings', 'pba_form_g', 'pba_asset_responses', 'pba_spenddowns', 'pba_payee_reports'))
     || ' · non-select grants ' ||
     (SELECT count(*) FROM information_schema.role_table_grants g WHERE g.table_schema = 'public' AND g.grantee IN ('authenticated', 'anon')
        AND g.privilege_type <> 'SELECT' AND g.table_name IN ('pba_statement_mappings', 'pba_statements', 'pba_statement_lines', 'pba_unmatched_notes',
          'pba_cash_counts', 'pba_form_b', 'pba_form_c', 'pba_form_d', 'pba_findings', 'pba_form_g', 'pba_asset_responses', 'pba_spenddowns', 'pba_payee_reports')))::text AS value,
    '13 · non-select grants 0' AS want
  UNION ALL
  SELECT 2, 'signatures accept the new forms and capacities',
    (pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'pba_sig_form_chk')) LIKE '%form_d%'
     AND pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'pba_sig_capacity_chk')) LIKE '%reconciler%')::text, 'true'
  UNION ALL
  SELECT 3, 'internal functions not callable by clients; the public RPCs are',
    ((SELECT bool_and(NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '\_pba\_%')
     AND has_function_privilege('authenticated', 'public.pba_close_month(uuid,date,text,text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.pba_close_month(uuid,date,text,text)', 'EXECUTE'))::text, 'true'
  UNION ALL
  SELECT 4, '(info) PBA months closed so far — for you to read', (SELECT count(*) FROM public.pba_form_b)::text, '(read)'
  UNION ALL
  SELECT 20 + t.n, t.item, t.value, t.want FROM v20030_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999935')
     + (SELECT count(*) FROM public.staff WHERE first_name = 'R30test')
     + (SELECT count(*) FROM public.service_notes WHERE summary_note = 'v20.0.30 self-test'))::text, '0'
) v ORDER BY n;
