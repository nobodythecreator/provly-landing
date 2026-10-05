-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.29 — PBA Release 1: the record (docs/pba-design.md v1.1; requirements docs/pba-module-spec-v1.md)
--   Gaps 16 enrollment · 17 accounts · 18 ledger, receipts, cash log, lost-receipt affidavit ·
--   20 roles + separation of duties — plus the shared pieces they need: per-provider settings,
--   add-only file storage, signatures, purchase requests, and flags.
--   Decisions: 2 block at the request, never at the record · 3 private add-only bucket, SHA-256 ·
--   5 read = the Person's assigned PBA roles + Compliance Director + owner · 6 entries editable
--   (with a reason, audited) until the month closes, sealed after · 7 signed in Provly ·
--   8 a ledger starts "Pending enrollment".
--   Every write is a SECURITY DEFINER RPC that checks the caller's PBA role for that Person;
--   clients get SELECT only (through RLS), never INSERT / UPDATE / DELETE.
--   Each public RPC is a thin wrapper: it passes the caller's staff id (my_staff_id()) and
--   membership role (member_role()) to an internal _pba_* function, which holds the rule. The
--   internal functions are not callable by clients; the self-test drives them with synthetic staff.
-- 🟢 Run in the Supabase SQL editor (production). Idempotent. One transaction; preflight stops
-- before any change if something it builds on is missing; a self-test runs and is rolled back;
-- any failure rolls back the whole file. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

-- ── 0. Preflight ─────────────────────────────────────────────────────────
DO $$
DECLARE
  v_missing text[] := '{}';
  x text;
BEGIN
  FOREACH x IN ARRAY ARRAY['public.org_id()', 'public.member_role()', 'public.my_staff_id()', 'public.access_tier()'] LOOP
    IF to_regprocedure(x) IS NULL THEN v_missing := v_missing || ('function ' || x); END IF;
  END LOOP;
  FOREACH x IN ARRAY ARRAY['public.persons', 'public.staff', 'public.org_sites', 'public.staff_assignments',
                           'public.person_placements', 'public.audit_log', 'public.org_members', 'storage.buckets', 'storage.objects'] LOOP
    IF to_regclass(x) IS NULL THEN v_missing := v_missing || ('table ' || x); END IF;
  END LOOP;
  -- tenant-bound FKs need a unique index on exactly (id, org_id), under any name
  FOREACH x IN ARRAY ARRAY['persons', 'staff'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_index i
       WHERE i.indrelid = ('public.' || x)::regclass AND i.indisunique AND i.indpred IS NULL AND i.indnkeyatts = 2
         AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text) FROM pg_attribute a
               WHERE a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)) = ARRAY['id', 'org_id']) THEN
      v_missing := v_missing || ('a unique index on ' || x || ' (id, org_id)');
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'org_sites' AND column_name = 'site_type') THEN
    v_missing := v_missing || 'column org_sites.site_type'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'staff_assignments' AND column_name = 'site_id') THEN
    v_missing := v_missing || 'column staff_assignments.site_id'::text;
  END IF;
  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'v20.0.29 stopped before changing anything — production is missing: %. Paste this message into chat.',
      array_to_string(v_missing, '; ');
  END IF;
END $$;

-- ── 1. Shared helpers ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._pba_today() RETURNS date
LANGUAGE sql STABLE AS $$ SELECT (now() AT TIME ZONE 'America/Denver')::date $$;

-- audit row (user = the signed-in user; NULL from the SQL editor)
CREATE OR REPLACE FUNCTION public._pba_audit(p_org uuid, p_action text, p_table text, p_record uuid, p_old jsonb, p_new jsonb)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  INSERT INTO audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
  VALUES (p_org, auth.uid(), left(p_action, 20), p_table, p_record, p_old, p_new)
$$;

-- ── 2. Per-provider settings (the spec's [tenant setting] values; shared later with pay rules) ──
CREATE TABLE IF NOT EXISTS public.org_settings (
  org_id      uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  key         text NOT NULL,
  value       jsonb NOT NULL,
  updated_by  uuid REFERENCES public.staff (id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, key),
  CONSTRAINT org_settings_key_chk CHECK (key ~ '^[a-z0-9_]+(\.[a-z0-9_]+)*$')
);
COMMENT ON TABLE public.org_settings IS
  'v20.0.29: per-provider settings (key → jsonb). provly_setting() returns the provider''s value or the built-in default. SOW constants are not settings.';

-- the provider's value, else the built-in default (Hope Haven's PBA-001 values)
CREATE OR REPLACE FUNCTION public.provly_setting(p_org uuid, p_key text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(
    (SELECT s.value FROM org_settings s WHERE s.org_id = p_org AND s.key = p_key),
    CASE p_key
      WHEN 'pba.third_party_count'  THEN '3'::jsonb
      WHEN 'pba.third_party_amount' THEN '150'::jsonb
      WHEN 'pba.third_party_days'   THEN '90'::jsonb
      WHEN 'pba.affidavit_count'    THEN '3'::jsonb
      WHEN 'pba.affidavit_days'     THEN '90'::jsonb
    END)
$$;

-- ── 3. Tables ────────────────────────────────────────────────────────────
-- 3a. files: every receipt, proof document, signature image and scan (add-only, fingerprinted)
CREATE TABLE IF NOT EXISTS public.pba_files (
  id            uuid PRIMARY KEY,
  org_id        uuid NOT NULL,
  person_id     uuid NOT NULL,
  purpose       text NOT NULL,
  storage_path  text NOT NULL UNIQUE,
  sha256        text NOT NULL,
  mime          text,
  bytes         bigint,
  uploaded_by   uuid,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_files_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_files_staff_fk  FOREIGN KEY (uploaded_by, org_id) REFERENCES public.staff (id, org_id),
  CONSTRAINT pba_files_purpose_chk CHECK (purpose IN ('receipt', 'fiduciary_proof', 'form_scan', 'signature', 'statement', 'document')),
  CONSTRAINT pba_files_sha_chk CHECK (sha256 ~ '^[0-9a-f]{64}$')
);

-- 3b. enrollment (Gap 16): one per Person; "enrolled" is computed (proof + signed Form A), else pending
CREATE TABLE IF NOT EXISTS public.pba_enrollments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL,
  person_id       uuid NOT NULL UNIQUE,
  fiduciary_type  text,
  proof_file_id   uuid REFERENCES public.pba_files (id),
  started_on      date NOT NULL DEFAULT public._pba_today(),
  ended_on        date,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_enrollments_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_enrollments_type_chk CHECK (fiduciary_type IS NULL OR fiduciary_type IN ('ssa_payee', 'conservator', 'voluntary'))
);

-- 3c. Natural Support Determination (Form A): versions, insert-only; signed through pba_signatures
CREATE TABLE IF NOT EXISTS public.pba_natural_support_determinations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  person_id   uuid NOT NULL,
  version     integer NOT NULL,
  entries     jsonb NOT NULL,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_nsd_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_nsd_entries_chk CHECK (jsonb_typeof(entries) = 'array'),
  CONSTRAINT pba_nsd_version_uq UNIQUE (person_id, version)
);

-- 3d. roles per Person (Gap 20)
CREATE TABLE IF NOT EXISTS public.pba_role_assignments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  person_id   uuid NOT NULL,
  staff_id    uuid NOT NULL,
  role        text NOT NULL,
  start_date  date NOT NULL DEFAULT public._pba_today(),
  end_date    date,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  ended_by    uuid,
  CONSTRAINT pba_roles_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_roles_staff_fk  FOREIGN KEY (staff_id, org_id) REFERENCES public.staff (id, org_id),
  CONSTRAINT pba_roles_role_chk CHECK (role IN ('manager', 'reviewer', 'auditor')),
  CONSTRAINT pba_roles_dates_chk CHECK (end_date IS NULL OR end_date >= start_date)
);
-- separation of duties: one staff member holds at most one PBA role per Person; one holder per role
CREATE UNIQUE INDEX IF NOT EXISTS pba_roles_one_role_per_staff ON public.pba_role_assignments (person_id, staff_id) WHERE end_date IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS pba_roles_one_holder_per_role ON public.pba_role_assignments (person_id, role) WHERE end_date IS NULL;

-- 3e. accounts (Gap 17)
CREATE TABLE IF NOT EXISTS public.pba_accounts (
  id                          uuid PRIMARY KEY,
  org_id                      uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  person_id                   uuid,                    -- NULL only for a collective account
  kind                        text NOT NULL,
  institution                 text,
  last4                       text,
  titling                     text NOT NULL,
  holding                     text NOT NULL DEFAULT 'individual',
  supervising_institution     text,
  opening_balance             numeric(12,2) NOT NULL DEFAULT 0,
  opening_date                date,
  opened_on                   date,
  closed_on                   date,
  not_provider_funds_attested boolean NOT NULL,
  created_by                  uuid,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_accounts_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_accounts_kind_chk CHECK (kind IN ('bank', 'pay_card', 'cash', 'able')),
  CONSTRAINT pba_accounts_holding_chk CHECK (holding IN ('individual', 'collective')),
  CONSTRAINT pba_accounts_holder_chk CHECK ((holding = 'individual') = (person_id IS NOT NULL)),
  CONSTRAINT pba_accounts_last4_chk CHECK (last4 IS NULL OR last4 ~ '^[0-9]{4}$'),
  CONSTRAINT pba_accounts_titling_chk CHECK (length(btrim(titling)) > 0),
  CONSTRAINT pba_accounts_attest_chk CHECK (not_provider_funds_attested),          -- SOW 15.2(8), 15.4(5)
  CONSTRAINT pba_accounts_paycard_chk CHECK (kind <> 'pay_card' OR length(btrim(coalesce(supervising_institution, ''))) > 0)  -- SOW 15.3(2)
);

-- 3f. purchase requests (Decision 2: the blocks live here)
CREATE TABLE IF NOT EXISTS public.pba_purchase_requests (
  id                        uuid PRIMARY KEY,
  org_id                    uuid NOT NULL,
  person_id                 uuid NOT NULL,
  amount                    numeric(12,2) NOT NULL,
  payee                     text,
  category                  text,
  beneficiary               text NOT NULL DEFAULT 'person',
  beneficiary_name          text,
  beneficiary_relationship  text,
  person_choice             text,
  needs_met                 jsonb,
  status                    text NOT NULL DEFAULT 'requested',
  requested_by              uuid,
  requested_at              timestamptz NOT NULL DEFAULT now(),
  decided_by                uuid,
  decided_at                timestamptz,
  decline_reason            text,
  CONSTRAINT pba_requests_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_requests_amount_chk CHECK (amount > 0),
  CONSTRAINT pba_requests_benef_chk CHECK (beneficiary IN ('person', 'other') AND (beneficiary = 'person' OR length(btrim(coalesce(beneficiary_name, ''))) > 0)),
  CONSTRAINT pba_requests_status_chk CHECK (status IN ('requested', 'approved', 'declined', 'spent', 'cancelled'))
);

-- 3g. ledger (Gap 18)
CREATE TABLE IF NOT EXISTS public.pba_transactions (
  id                        uuid PRIMARY KEY,
  org_id                    uuid NOT NULL,
  person_id                 uuid NOT NULL,
  account_id                uuid NOT NULL REFERENCES public.pba_accounts (id),
  entry_date                date NOT NULL,
  type                      text NOT NULL,
  amount                    numeric(12,2) NOT NULL,
  to_account_id             uuid REFERENCES public.pba_accounts (id),
  payee                     text,
  category                  text,
  beneficiary               text NOT NULL DEFAULT 'person',
  beneficiary_name          text,
  beneficiary_relationship  text,
  purchased_by              text,
  purchased_by_staff_id     uuid,
  handed_to                 text,
  handed_to_staff_id        uuid,
  handed_to_name            text,
  purpose                   text,
  request_id                uuid REFERENCES public.pba_purchase_requests (id),
  reverses_id               uuid REFERENCES public.pba_transactions (id),
  status                    text NOT NULL DEFAULT 'active',
  void_reason               text,
  voided_by                 uuid,
  voided_at                 timestamptz,
  notes                     text,
  flag_resolution           text,
  flag_resolved_by          uuid,
  flag_resolved_at          timestamptz,
  created_by                uuid,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_txn_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_txn_type_chk CHECK (type IN ('deposit', 'withdrawal', 'transfer', 'interest', 'fee', 'cash_out')),
  CONSTRAINT pba_txn_amount_chk CHECK (amount > 0),
  CONSTRAINT pba_txn_transfer_chk CHECK ((type = 'transfer') = (to_account_id IS NOT NULL) AND (to_account_id IS NULL OR to_account_id <> account_id)),
  CONSTRAINT pba_txn_benef_chk CHECK (beneficiary IN ('person', 'other') AND (beneficiary = 'person' OR length(btrim(coalesce(beneficiary_name, ''))) > 0)),
  CONSTRAINT pba_txn_purchased_chk CHECK (purchased_by IS NULL OR purchased_by IN ('staff', 'host', 'person')),
  CONSTRAINT pba_txn_handed_chk CHECK (handed_to IS NULL OR handed_to IN ('person', 'staff', 'host')),
  CONSTRAINT pba_txn_cashout_chk CHECK (type <> 'cash_out' OR (handed_to IS NOT NULL AND length(btrim(coalesce(purpose, ''))) > 0)),
  CONSTRAINT pba_txn_status_chk CHECK (status IN ('active', 'voided') AND (status = 'active' OR length(btrim(coalesce(void_reason, ''))) > 0))
);
CREATE INDEX IF NOT EXISTS pba_txn_person_date ON public.pba_transactions (person_id, entry_date);
CREATE UNIQUE INDEX IF NOT EXISTS pba_txn_one_reversal ON public.pba_transactions (reverses_id) WHERE reverses_id IS NOT NULL AND status = 'active';

-- 3h. receipts: a transaction ↔ an add-only file (never replaced; a correction is a new entry)
CREATE TABLE IF NOT EXISTS public.pba_receipts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL,
  transaction_id  uuid NOT NULL REFERENCES public.pba_transactions (id),
  file_id         uuid NOT NULL UNIQUE REFERENCES public.pba_files (id),
  added_by        uuid,
  added_at        timestamptz NOT NULL DEFAULT now()
);

-- 3i. Lost Receipt Affidavit (Form F): one per transaction, insert-only
CREATE TABLE IF NOT EXISTS public.pba_lost_receipt_affidavits (
  id                    uuid PRIMARY KEY,
  org_id                uuid NOT NULL,
  person_id             uuid NOT NULL,
  transaction_id        uuid NOT NULL UNIQUE REFERENCES public.pba_transactions (id),
  purchaser_staff_id    uuid NOT NULL,
  store                 text NOT NULL,
  purchase_date         date NOT NULL,
  amount                numeric(12,2) NOT NULL,
  statement_line_ref    text,
  reason                text NOT NULL,
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_aff_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_aff_purchaser_fk FOREIGN KEY (purchaser_staff_id, org_id) REFERENCES public.staff (id, org_id),
  CONSTRAINT pba_aff_amount_chk CHECK (amount > 0),
  CONSTRAINT pba_aff_text_chk CHECK (length(btrim(store)) > 0 AND length(btrim(reason)) > 0)
);

-- 3j. signatures (Decision 7): insert-only; the content fingerprint is computed by the database at signing
CREATE TABLE IF NOT EXISTS public.pba_signatures (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL,
  person_id              uuid NOT NULL,
  form_type              text NOT NULL,
  form_id                uuid NOT NULL,
  capacity               text NOT NULL,
  signer_kind            text NOT NULL,
  signer_staff_id        uuid,
  signer_name            text NOT NULL,
  attestation            text NOT NULL,
  content_sha256         text NOT NULL,
  drawn_file_id          uuid REFERENCES public.pba_files (id),
  scan_file_id           uuid REFERENCES public.pba_files (id),
  witnessed_by_staff_id  uuid,
  signed_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_sig_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_sig_form_chk CHECK (form_type IN ('form_a', 'form_f')),
  CONSTRAINT pba_sig_capacity_chk CHECK (capacity IN ('preparer', 'purchaser', 'countersigner', 'person', 'guardian')),
  CONSTRAINT pba_sig_kind_chk CHECK (signer_kind IN ('staff', 'person', 'guardian')
                                     AND (signer_kind = 'staff') = (signer_staff_id IS NOT NULL)
                                     AND (signer_kind = 'staff' OR (witnessed_by_staff_id IS NOT NULL AND (drawn_file_id IS NOT NULL OR scan_file_id IS NOT NULL)))),
  CONSTRAINT pba_sig_sha_chk CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT pba_sig_one_per_capacity UNIQUE (form_type, form_id, capacity)
);

-- 3k. month closes (written by Release 2's reconciliation; the seal is enforced from today)
CREATE TABLE IF NOT EXISTS public.pba_month_closes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  person_id   uuid NOT NULL,
  month       date NOT NULL,
  closed_by   uuid,
  closed_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_close_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_close_month_chk CHECK (month = date_trunc('month', month)::date),
  CONSTRAINT pba_close_one UNIQUE (person_id, month)
);

-- ── 4. Access (Decision 5) ───────────────────────────────────────────────
-- The actor's standing for one Person: their PBA role there (if any), whether they are the
-- provider's owner or Compliance Director, and what that lets them do.
--   read  = an active PBA role for the Person, or owner, or Compliance Director
--   write = the Person's active PBA Manager
CREATE OR REPLACE FUNCTION public._pba_access(p_person uuid, p_actor uuid, p_actor_role text,
  OUT o_org uuid, OUT o_role text, OUT o_owner boolean, OUT o_cd boolean, OUT o_read boolean, OUT o_write boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  o_owner := false; o_cd := false; o_read := false; o_write := false;
  SELECT p.org_id INTO o_org FROM persons p WHERE p.id = p_person;
  IF o_org IS NULL OR p_actor IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = o_org AND s.is_active) THEN RETURN; END IF;
  SELECT r.role INTO o_role FROM pba_role_assignments r
   WHERE r.person_id = p_person AND r.staff_id = p_actor AND r.end_date IS NULL LIMIT 1;
  o_owner := coalesce(p_actor_role, '') = 'owner';
  o_cd    := coalesce(p_actor_role, '') = 'compliance_director';
  o_read  := o_role IS NOT NULL OR o_owner OR o_cd;
  o_write := coalesce(o_role, '') = 'manager';
END;
$$;

-- the signed-in caller's standing (the RLS predicate; also what the app asks before showing the PBA tab)
CREATE OR REPLACE FUNCTION public.pba_can_read(p_person uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT (public._pba_access(p_person, public.my_staff_id(), public.member_role()::text)).o_read
$$;

CREATE OR REPLACE FUNCTION public.pba_access(p_person uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object('role', a.o_role, 'owner', a.o_owner, 'compliance', a.o_cd, 'read', a.o_read, 'write', a.o_write,
                            'staff_id', public.my_staff_id())
    FROM public._pba_access(p_person, public.my_staff_id(), public.member_role()::text) a
$$;

-- does the caller hold any active PBA role in their org (collective accounts are visible to role-holders)
CREATE OR REPLACE FUNCTION public.pba_holds_any_role()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM pba_role_assignments r WHERE r.staff_id = public.my_staff_id() AND r.end_date IS NULL)
$$;

-- SOW 11.4(1): the Person's host (staff on the HHS site where the Person lives, or the Person's
-- hhs_operator) can never hold a PBA role or payee status for that Person
CREATE OR REPLACE FUNCTION public._pba_is_host(p_person uuid, p_staff uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
           SELECT 1 FROM person_placements pl
             JOIN org_sites st ON st.id = pl.site_id
             JOIN staff_assignments sa ON sa.site_id = pl.site_id
            WHERE pl.person_id = p_person AND pl.end_date IS NULL AND st.site_type::text = 'hhs'
              AND sa.staff_id = p_staff
              AND (sa.end_date IS NULL OR sa.end_date >= public._pba_today()))
      OR EXISTS (
           SELECT 1 FROM staff_assignments sa JOIN staff s ON s.id = sa.staff_id
            WHERE sa.person_id = p_person AND sa.staff_id = p_staff AND s.role::text = 'hhs_operator'
              AND (sa.end_date IS NULL OR sa.end_date >= public._pba_today()))
$$;

-- a month that Release 2's reconciliation has closed is sealed
CREATE OR REPLACE FUNCTION public._pba_month_closed(p_person uuid, p_day date)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM pba_month_closes c WHERE c.person_id = p_person AND c.month = date_trunc('month', p_day)::date)
$$;

-- the balance effect of one entry on one account (+ in, − out; a reversing entry negates)
CREATE OR REPLACE FUNCTION public._pba_effect(t public.pba_transactions, p_account uuid)
RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN t.status <> 'active' THEN 0 ELSE
           (CASE WHEN t.reverses_id IS NULL THEN 1 ELSE -1 END) *
           (CASE
              WHEN t.type IN ('deposit', 'interest') AND t.account_id = p_account THEN t.amount
              WHEN t.type IN ('withdrawal', 'fee', 'cash_out') AND t.account_id = p_account THEN -t.amount
              WHEN t.type = 'transfer' AND t.account_id = p_account THEN -t.amount
              WHEN t.type = 'transfer' AND t.to_account_id = p_account THEN t.amount
              ELSE 0 END)
         END
$$;

-- expenses the receipt rule watches (SOW 15.3(6)): an active, un-reversed purchase or payment over $50
CREATE OR REPLACE FUNCTION public._pba_needs_receipt(t public.pba_transactions)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT t.status = 'active' AND t.reverses_id IS NULL AND t.type = 'withdrawal' AND t.amount > 50.00
     AND NOT EXISTS (SELECT 1 FROM pba_transactions r WHERE r.reverses_id = t.id AND r.status = 'active')
$$;

-- an affidavit counts once both of its signatures exist
CREATE OR REPLACE FUNCTION public._pba_affidavit_complete(p_txn uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM pba_lost_receipt_affidavits a
                  WHERE a.transaction_id = p_txn
                    AND EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = 'form_f' AND s.form_id = a.id AND s.capacity = 'purchaser')
                    AND EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = 'form_f' AND s.form_id = a.id AND s.capacity = 'countersigner'))
$$;

-- Decision 2: what the request step would have refused, recorded anyway
CREATE OR REPLACE FUNCTION public._pba_needs_approval(t public.pba_transactions)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT t.type = 'withdrawal' AND t.reverses_id IS NULL
     AND (t.beneficiary = 'other' OR coalesce(t.category, '') IN ('gift', 'savings', 'debt_repayment'))
$$;

-- needs met (SOW 15.2(4)): all four confirmed
CREATE OR REPLACE FUNCTION public._pba_needs_all_met(p jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((p->>'food')::boolean, false) AND coalesce((p->>'shelter')::boolean, false)
     AND coalesce((p->>'clothing')::boolean, false) AND coalesce((p->>'medical')::boolean, false)
$$;

-- enrollment status (Decision 8): enrolled = fiduciary type + proof + a staff-signed Form A (latest version)
CREATE OR REPLACE FUNCTION public._pba_enrollment_status(p_person uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE
    WHEN e.id IS NULL THEN 'none'
    WHEN e.ended_on IS NOT NULL THEN 'ended'
    WHEN e.fiduciary_type IS NOT NULL AND e.proof_file_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM pba_natural_support_determinations d
                      WHERE d.person_id = p_person
                        AND d.version = (SELECT max(d2.version) FROM pba_natural_support_determinations d2 WHERE d2.person_id = p_person)
                        AND EXISTS (SELECT 1 FROM pba_signatures s WHERE s.form_type = 'form_a' AND s.form_id = d.id AND s.signer_kind = 'staff'))
      THEN 'enrolled'
    ELSE 'pending' END
    FROM (SELECT 1) one LEFT JOIN pba_enrollments e ON e.person_id = p_person
$$;

-- ── 5. Flags (computed on read; nothing stored, so each clears itself) ───
CREATE OR REPLACE FUNCTION public._pba_flags(p_person uuid, p_today date DEFAULT NULL)
RETURNS TABLE (o_flag text, o_detail text, o_ref uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org    uuid;
  v_today  date := coalesce(p_today, public._pba_today());
  v_status text := public._pba_enrollment_status(p_person);
  v_tp_n   integer; v_tp_amt numeric; v_tp_days integer; v_af_n integer; v_af_days integer;
BEGIN
  SELECT p.org_id INTO v_org FROM persons p WHERE p.id = p_person;
  IF v_org IS NULL OR v_status IN ('none', 'ended') THEN RETURN; END IF;
  v_tp_n    := (public.provly_setting(v_org, 'pba.third_party_count'))::text::integer;
  v_tp_amt  := (public.provly_setting(v_org, 'pba.third_party_amount'))::text::numeric;
  v_tp_days := (public.provly_setting(v_org, 'pba.third_party_days'))::text::integer;
  v_af_n    := (public.provly_setting(v_org, 'pba.affidavit_count'))::text::integer;
  v_af_days := (public.provly_setting(v_org, 'pba.affidavit_days'))::text::integer;

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

  RETURN QUERY
  SELECT 'affidavit_pattern'::text,
         format('%s %s: %s Lost Receipt Affidavits in the last %s days — corrective action review',
                s.first_name, s.last_name, x.n, v_af_days),
         x.purchaser_staff_id
    FROM (SELECT a.purchaser_staff_id, count(*)::integer AS n
            FROM pba_lost_receipt_affidavits a
           WHERE a.org_id = v_org AND a.purchase_date > v_today - v_af_days
             AND a.purchaser_staff_id IN (SELECT a2.purchaser_staff_id FROM pba_lost_receipt_affidavits a2 WHERE a2.person_id = p_person)
           GROUP BY a.purchaser_staff_id) x
    JOIN staff s ON s.id = x.purchaser_staff_id
   WHERE x.n >= v_af_n;

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

-- one Person's flags, for a caller who may read that Person
CREATE OR REPLACE FUNCTION public.pba_flags(p_person uuid)
RETURNS TABLE (o_flag text, o_detail text, o_ref uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.pba_can_read(p_person) THEN RETURN; END IF;
  RETURN QUERY SELECT f.o_flag, f.o_detail, f.o_ref FROM public._pba_flags(p_person) f;
END;
$$;

-- every enrolled Person's flags, for the owner and the Compliance Director (Compliance → PBA)
CREATE OR REPLACE FUNCTION public.pba_org_flags()
RETURNS TABLE (o_person_id uuid, o_person_name text, o_status text, o_flag text, o_detail text, o_ref uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF coalesce(public.member_role()::text, '') NOT IN ('owner', 'compliance_director') OR public.org_id() IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT e.person_id, btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, ''))::text,
         public._pba_enrollment_status(e.person_id), f.o_flag, f.o_detail, f.o_ref
    FROM pba_enrollments e
    JOIN persons p ON p.id = e.person_id
   CROSS JOIN LATERAL public._pba_flags(e.person_id) f
   WHERE e.org_id = public.org_id() AND e.ended_on IS NULL
   ORDER BY 2, 4;
END;
$$;

-- ── 6. Writes: internal rules (_pba_*) and the thin public wrappers ──────
-- Every internal function takes the actor's staff id and membership role; the wrappers pass
-- my_staff_id() and member_role(). Refusals raise with a sentence the app shows as is.

-- 6a. start a Person's PBA record (owner or Compliance Director) — Decision 8: it starts pending
CREATE OR REPLACE FUNCTION public._pba_start(p_person uuid, p_fiduciary_type text, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_id uuid;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only the owner or the Compliance Director can start a Person''s PBA record'; END IF;
  SELECT e.id INTO v_id FROM pba_enrollments e WHERE e.person_id = p_person;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;                                   -- already started: same answer
  INSERT INTO pba_enrollments (org_id, person_id, fiduciary_type, created_by)
  VALUES (a.o_org, p_person, nullif(p_fiduciary_type, ''), p_actor) RETURNING id INTO v_id;
  PERFORM public._pba_audit(a.o_org, 'pba_enrolled', 'pba_enrollments', v_id, NULL, jsonb_build_object('person_id', p_person, 'fiduciary_type', p_fiduciary_type));
  RETURN v_id;
END;
$$;

-- 6b. enrollment details: fiduciary type and proof (owner, Compliance Director or the PBA Manager)
CREATE OR REPLACE FUNCTION public._pba_set_enrollment(p_person uuid, p_fiduciary_type text, p_proof_file uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; e record;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_owner OR a.o_cd OR a.o_write) THEN RAISE EXCEPTION 'Only the owner, the Compliance Director or this Person''s PBA Manager can change the enrollment'; END IF;
  SELECT * INTO e FROM pba_enrollments WHERE person_id = p_person;
  IF NOT FOUND THEN RAISE EXCEPTION 'Start this Person''s PBA record first'; END IF;
  IF p_proof_file IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = p_proof_file AND f.person_id = p_person AND f.purpose = 'fiduciary_proof') THEN
    RAISE EXCEPTION 'That proof document isn''t on file for this Person';
  END IF;
  UPDATE pba_enrollments SET fiduciary_type = coalesce(nullif(p_fiduciary_type, ''), fiduciary_type),
                             proof_file_id = coalesce(p_proof_file, proof_file_id), updated_at = now()
   WHERE person_id = p_person;
  PERFORM public._pba_audit(a.o_org, 'pba_enroll_changed', 'pba_enrollments', e.id, to_jsonb(e),
                            jsonb_build_object('fiduciary_type', p_fiduciary_type, 'proof_file_id', p_proof_file));
END;
$$;

-- 6c. Form A: a new version (owner, Compliance Director or the PBA Manager)
CREATE OR REPLACE FUNCTION public._pba_save_form_a(p_person uuid, p_entries jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_id uuid; v_ver integer;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_owner OR a.o_cd OR a.o_write) THEN RAISE EXCEPTION 'Only the owner, the Compliance Director or this Person''s PBA Manager can prepare Form A'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pba_enrollments WHERE person_id = p_person) THEN RAISE EXCEPTION 'Start this Person''s PBA record first'; END IF;
  IF jsonb_typeof(p_entries) <> 'array' OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_entries) x
        WHERE length(btrim(coalesce(x->>'name', ''))) = 0 OR length(btrim(coalesce(x->>'reason', ''))) = 0) THEN
    RAISE EXCEPTION 'Each natural support needs a name and the reason they are not the payee';
  END IF;
  SELECT coalesce(max(version), 0) + 1 INTO v_ver FROM pba_natural_support_determinations WHERE person_id = p_person;
  INSERT INTO pba_natural_support_determinations (org_id, person_id, version, entries, created_by)
  VALUES (a.o_org, p_person, v_ver, p_entries, p_actor) RETURNING id INTO v_id;
  PERFORM public._pba_audit(a.o_org, 'pba_form_a_saved', 'pba_natural_support_determinations', v_id, NULL, jsonb_build_object('version', v_ver));
  RETURN v_id;
END;
$$;

-- 6d. roles (owner or Compliance Director). Separation of duties is two unique indexes; the
--     host rule is checked here (SOW 11.4(1)).
CREATE OR REPLACE FUNCTION public._pba_assign_role(p_person uuid, p_staff uuid, p_role text, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_id uuid; v_name text;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT (a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only the owner or the Compliance Director can assign PBA roles'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pba_enrollments WHERE person_id = p_person) THEN RAISE EXCEPTION 'Start this Person''s PBA record first'; END IF;
  SELECT s.first_name || ' ' || s.last_name INTO v_name FROM staff s WHERE s.id = p_staff AND s.org_id = a.o_org AND s.is_active;
  IF v_name IS NULL THEN RAISE EXCEPTION 'That staff member isn''t an active member of this provider'; END IF;
  IF public._pba_is_host(p_person, p_staff) THEN
    RAISE EXCEPTION '% is this Person''s host (or on the host home''s staff) and can never hold a PBA role for them (SOW 11.4(1))', v_name;
  END IF;
  IF EXISTS (SELECT 1 FROM pba_role_assignments r WHERE r.person_id = p_person AND r.staff_id = p_staff AND r.end_date IS NULL) THEN
    RAISE EXCEPTION '% already holds a PBA role for this Person — one person can''t hold two (separation of duties)', v_name;
  END IF;
  IF EXISTS (SELECT 1 FROM pba_role_assignments r WHERE r.person_id = p_person AND r.role = p_role AND r.end_date IS NULL) THEN
    RAISE EXCEPTION 'This Person already has an active % — end that assignment first',
      CASE p_role WHEN 'manager' THEN 'PBA Manager' WHEN 'reviewer' THEN 'Administrative Reviewer' ELSE 'Quarterly Auditor' END;
  END IF;
  INSERT INTO pba_role_assignments (org_id, person_id, staff_id, role, created_by)
  VALUES (a.o_org, p_person, p_staff, p_role, p_actor) RETURNING id INTO v_id;
  PERFORM public._pba_audit(a.o_org, 'pba_role_assigned', 'pba_role_assignments', v_id, NULL,
                            jsonb_build_object('person_id', p_person, 'staff_id', p_staff, 'role', p_role));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_end_role(p_assignment uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; r record;
BEGIN
  SELECT * INTO r FROM pba_role_assignments WHERE id = p_assignment;
  IF NOT FOUND THEN RAISE EXCEPTION 'That assignment doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(r.person_id, p_actor, p_actor_role);
  IF NOT (a.o_owner OR a.o_cd) THEN RAISE EXCEPTION 'Only the owner or the Compliance Director can end PBA roles'; END IF;
  IF r.end_date IS NOT NULL THEN RETURN; END IF;
  UPDATE pba_role_assignments SET end_date = greatest(public._pba_today(), start_date), ended_by = p_actor WHERE id = p_assignment;
  PERFORM public._pba_audit(a.o_org, 'pba_role_ended', 'pba_role_assignments', p_assignment, to_jsonb(r), NULL);
END;
$$;

-- 6e. files: register an object already uploaded to the pba bucket (any reader of the Person)
CREATE OR REPLACE FUNCTION public._pba_register_file(p_id uuid, p_person uuid, p_purpose text, p_path text, p_sha256 text,
                                                     p_mime text, p_bytes bigint, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT a.o_read THEN RAISE EXCEPTION 'You can''t add files to this Person''s PBA record'; END IF;
  IF EXISTS (SELECT 1 FROM pba_files f WHERE f.id = p_id) THEN
    IF EXISTS (SELECT 1 FROM pba_files f WHERE f.id = p_id AND f.person_id = p_person AND f.storage_path = p_path) THEN RETURN p_id; END IF;
    RAISE EXCEPTION 'That file id is already used';
  END IF;
  IF p_path NOT LIKE a.o_org::text || '/' || p_person::text || '/%' THEN RAISE EXCEPTION 'The file isn''t filed under this Person'; END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'pba' AND o.name = p_path) THEN
    RAISE EXCEPTION 'The upload didn''t arrive — add the file again';
  END IF;
  INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, mime, bytes, uploaded_by)
  VALUES (p_id, a.o_org, p_person, p_purpose, p_path, lower(p_sha256), p_mime, p_bytes, p_actor);
  PERFORM public._pba_audit(a.o_org, 'pba_file_added', 'pba_files', p_id, NULL, jsonb_build_object('purpose', p_purpose, 'sha256', lower(p_sha256)));
  RETURN p_id;
END;
$$;

-- 6f. accounts (the PBA Manager, the owner or the Compliance Director)
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

-- 6g. the ledger's coherence rules (shared by record and edit)
CREATE OR REPLACE FUNCTION public._pba_check_txn(t public.pba_transactions)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE acc record; acc2 record;
BEGIN
  SELECT * INTO acc FROM pba_accounts WHERE id = t.account_id;
  IF NOT FOUND OR acc.org_id <> t.org_id OR (acc.person_id IS NOT NULL AND acc.person_id <> t.person_id) THEN
    RAISE EXCEPTION 'That account isn''t one of this Person''s accounts';
  END IF;
  IF acc.closed_on IS NOT NULL AND t.entry_date > acc.closed_on THEN RAISE EXCEPTION 'That account was closed on %', acc.closed_on; END IF;
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
  IF t.request_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pba_purchase_requests q WHERE q.id = t.request_id AND q.person_id = t.person_id) THEN
    RAISE EXCEPTION 'That request belongs to someone else';
  END IF;
  IF public._pba_month_closed(t.person_id, t.entry_date) THEN
    RAISE EXCEPTION '% is closed and sealed — record a reversing entry in an open month instead', to_char(t.entry_date, 'FMMonth YYYY');
  END IF;
END;
$$;

-- 6h. record a transaction (the Person's PBA Manager). The client supplies the id, so a retried
--     request returns the same entry instead of adding a twin.
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
  PERFORM public._pba_check_txn(t);
  INSERT INTO pba_transactions VALUES (t.*);
  IF t.request_id IS NOT NULL THEN
    UPDATE pba_purchase_requests SET status = 'spent' WHERE id = t.request_id AND status = 'approved';
  END IF;
  PERFORM public._pba_audit(a.o_org, 'pba_txn_recorded', 'pba_transactions', p_id, NULL, to_jsonb(t));
  RETURN p_id;
END;
$$;

-- 6i. edit (Decision 6): only before the month closes, always with a reason, before/after audited
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
  PERFORM public._pba_audit(a.o_org, 'pba_txn_edited', 'pba_transactions', p_id, to_jsonb(v_old),
                            to_jsonb(t) || jsonb_build_object('edit_reason', p_reason));
END;
$$;

-- 6j. void (replaces delete; before the month closes)
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
  PERFORM public._pba_audit(a.o_org, 'pba_txn_voided', 'pba_transactions', p_id, to_jsonb(v_old), jsonb_build_object('void_reason', p_reason));
END;
$$;

-- 6k. reverse (the fix for a sealed month): same type and amount, opposite effect, dated today
CREATE OR REPLACE FUNCTION public._pba_reverse_txn(p_new_id uuid, p_id uuid, p_reason text, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; v_old pba_transactions; t pba_transactions;
BEGIN
  IF EXISTS (SELECT 1 FROM pba_transactions x WHERE x.id = p_new_id AND x.reverses_id = p_id) THEN RETURN p_new_id; END IF;
  SELECT * INTO v_old FROM pba_transactions WHERE id = p_id;
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

-- 6l. receipts: attach an uploaded receipt file to an entry (the PBA Manager); never replaced
CREATE OR REPLACE FUNCTION public._pba_attach_receipt(p_txn uuid, p_file uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; t pba_transactions;
BEGIN
  SELECT * INTO t FROM pba_transactions WHERE id = p_txn;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(t.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can attach receipts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = p_file AND f.person_id = t.person_id AND f.purpose = 'receipt') THEN
    RAISE EXCEPTION 'That receipt file isn''t on file for this Person';
  END IF;
  IF EXISTS (SELECT 1 FROM pba_receipts r WHERE r.file_id = p_file) THEN RETURN; END IF;
  INSERT INTO pba_receipts (org_id, transaction_id, file_id, added_by) VALUES (a.o_org, p_txn, p_file, p_actor);
  PERFORM public._pba_audit(a.o_org, 'pba_receipt_added', 'pba_receipts', p_txn, NULL, jsonb_build_object('file_id', p_file));
END;
$$;

-- 6m. Lost Receipt Affidavit (Form F): filed by the PBA Manager; signed by the purchaser and a countersigner
CREATE OR REPLACE FUNCTION public._pba_file_affidavit(p_id uuid, p_txn uuid, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; t pba_transactions; v_purchaser uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM pba_lost_receipt_affidavits x WHERE x.id = p_id AND x.transaction_id = p_txn) THEN RETURN p_id; END IF;
  SELECT * INTO t FROM pba_transactions WHERE id = p_txn;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(t.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can file a Lost Receipt Affidavit'; END IF;
  IF NOT public._pba_needs_receipt(t) THEN RAISE EXCEPTION 'This entry doesn''t need a receipt'; END IF;
  IF EXISTS (SELECT 1 FROM pba_receipts r WHERE r.transaction_id = p_txn) THEN RAISE EXCEPTION 'This entry already has a receipt'; END IF;
  v_purchaser := coalesce((nullif(p_data->>'purchaser_staff_id', ''))::uuid, t.purchased_by_staff_id);
  IF v_purchaser IS NULL THEN RAISE EXCEPTION 'Name the staff member who made the purchase'; END IF;
  INSERT INTO pba_lost_receipt_affidavits (id, org_id, person_id, transaction_id, purchaser_staff_id, store, purchase_date, amount,
                                           statement_line_ref, reason, created_by)
  VALUES (p_id, a.o_org, t.person_id, p_txn, v_purchaser, coalesce(btrim(p_data->>'store'), ''),
          coalesce((nullif(p_data->>'purchase_date', ''))::date, t.entry_date), coalesce((p_data->>'amount')::numeric, t.amount),
          nullif(btrim(p_data->>'statement_line_ref'), ''), coalesce(btrim(p_data->>'reason'), ''), p_actor);
  PERFORM public._pba_audit(a.o_org, 'pba_affidavit_filed', 'pba_lost_receipt_affidavits', p_id, NULL, p_data);
  RETURN p_id;
END;
$$;

-- 6n. signing (Decision 7). The fingerprint is the form's stored content at this moment.
--   form_a: a staff signer is a reader of the Person (capacity preparer); the Person or guardian signs
--           on screen (drawn file) or by scan, witnessed by the signed-in staff member.
--   form_f: the purchaser signs as purchaser; the countersigner is never the purchaser — the
--           Compliance Director (unless they are this Person's PBA Manager) or else the owner.
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
    IF p_signer_kind = 'staff' THEN v_capacity := 'preparer';
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

-- 6o. purchase requests (Decision 2): requested and decided by the PBA Manager; the blocks apply at approval
CREATE OR REPLACE FUNCTION public._pba_request(p_id uuid, p_person uuid, p_data jsonb, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM public._pba_access(p_person, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can enter purchase requests'; END IF;
  IF EXISTS (SELECT 1 FROM pba_purchase_requests q WHERE q.id = p_id) THEN
    IF EXISTS (SELECT 1 FROM pba_purchase_requests q WHERE q.id = p_id AND q.person_id = p_person) THEN RETURN p_id; END IF;
    RAISE EXCEPTION 'That request id is already used';
  END IF;
  INSERT INTO pba_purchase_requests (id, org_id, person_id, amount, payee, category, beneficiary, beneficiary_name,
                                     beneficiary_relationship, person_choice, requested_by)
  VALUES (p_id, a.o_org, p_person, (p_data->>'amount')::numeric, nullif(btrim(p_data->>'payee'), ''), nullif(p_data->>'category', ''),
          coalesce(nullif(p_data->>'beneficiary', ''), 'person'), nullif(btrim(p_data->>'beneficiary_name'), ''),
          nullif(btrim(p_data->>'beneficiary_relationship'), ''), nullif(btrim(p_data->>'person_choice'), ''), p_actor);
  PERFORM public._pba_audit(a.o_org, 'pba_request_made', 'pba_purchase_requests', p_id, NULL, p_data);
  RETURN p_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._pba_decide(p_id uuid, p_approve boolean, p_needs_met jsonb, p_reason text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; q pba_purchase_requests;
BEGIN
  SELECT * INTO q FROM pba_purchase_requests WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That request doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(q.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can decide purchase requests'; END IF;
  IF q.status <> 'requested' THEN RAISE EXCEPTION 'This request was already %', q.status; END IF;
  IF p_approve THEN
    IF q.beneficiary = 'other' OR coalesce(q.category, '') IN ('gift', 'savings', 'debt_repayment') THEN
      IF length(btrim(coalesce(q.person_choice, ''))) = 0 THEN
        RAISE EXCEPTION 'Record the Person''s choice in their own words before approving';
      END IF;
      IF NOT public._pba_needs_all_met(p_needs_met) THEN
        RAISE EXCEPTION 'Not approved: this month''s needs (food, shelter, clothing, medical care) must all be met first (SOW 15.2(4))';
      END IF;
    END IF;
    UPDATE pba_purchase_requests SET status = 'approved', needs_met = p_needs_met, decided_by = p_actor, decided_at = now() WHERE id = p_id;
  ELSE
    IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason for declining'; END IF;
    UPDATE pba_purchase_requests SET status = 'declined', needs_met = p_needs_met, decline_reason = p_reason,
                                     decided_by = p_actor, decided_at = now() WHERE id = p_id;
  END IF;
  PERFORM public._pba_audit(a.o_org, 'pba_request_decided', 'pba_purchase_requests', p_id, to_jsonb(q),
                            jsonb_build_object('approved', p_approve, 'needs_met', p_needs_met, 'reason', p_reason));
END;
$$;

-- 6p. resolve "recorded over a block" (Decision 2): the Compliance Director — never for a Person
--     they manage — or the owner, always with a reason
CREATE OR REPLACE FUNCTION public._pba_resolve_flag(p_txn uuid, p_reason text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE a record; t pba_transactions;
BEGIN
  SELECT * INTO t FROM pba_transactions WHERE id = p_txn;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(t.person_id, p_actor, p_actor_role);
  IF NOT (a.o_owner OR (a.o_cd AND coalesce(a.o_role, '') <> 'manager')) THEN
    RAISE EXCEPTION 'The Compliance Director resolves this — or the owner when the Compliance Director manages this Person''s money';
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason'; END IF;
  UPDATE pba_transactions SET flag_resolution = p_reason, flag_resolved_by = p_actor, flag_resolved_at = now() WHERE id = p_txn;
  PERFORM public._pba_audit(a.o_org, 'pba_flag_resolved', 'pba_transactions', p_txn, NULL, jsonb_build_object('reason', p_reason));
END;
$$;

-- 6q. settings (owner or Compliance Director)
CREATE OR REPLACE FUNCTION public._set_org_setting(p_key text, p_value jsonb, p_actor uuid, p_actor_role text, p_org uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF coalesce(p_actor_role, '') NOT IN ('owner', 'compliance_director') OR p_org IS NULL
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = p_org AND s.is_active) THEN
    RAISE EXCEPTION 'Only the owner or the Compliance Director can change provider settings';
  END IF;
  IF public.provly_setting(p_org, p_key) IS NULL THEN RAISE EXCEPTION 'Unknown setting %', p_key; END IF;
  IF jsonb_typeof(p_value) <> 'number' OR (p_value::text)::numeric < 0 THEN RAISE EXCEPTION 'The setting needs a number of zero or more'; END IF;
  INSERT INTO org_settings (org_id, key, value, updated_by, updated_at) VALUES (p_org, p_key, p_value, p_actor, now())
  ON CONFLICT (org_id, key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM public._pba_audit(p_org, 'org_setting_saved', 'org_settings', p_org, NULL, jsonb_build_object('key', p_key, 'value', p_value));
END;
$$;

-- ── 7. Public wrappers (the signed-in caller is the actor) ───────────────
CREATE OR REPLACE FUNCTION public.pba_start(p_person uuid, p_fiduciary_type text DEFAULT NULL) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_start(p_person, p_fiduciary_type, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_set_enrollment(p_person uuid, p_fiduciary_type text, p_proof_file uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_set_enrollment(p_person, p_fiduciary_type, p_proof_file, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_save_form_a(p_person uuid, p_entries jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_save_form_a(p_person, p_entries, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_assign_role(p_person uuid, p_staff uuid, p_role text) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_assign_role(p_person, p_staff, p_role, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_end_role(p_assignment uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_end_role(p_assignment, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_register_file(p_id uuid, p_person uuid, p_purpose text, p_path text, p_sha256 text, p_mime text, p_bytes bigint) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_register_file(p_id, p_person, p_purpose, p_path, p_sha256, p_mime, p_bytes, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_save_account(p_id uuid, p_person uuid, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_save_account(p_id, p_person, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_record_txn(p_id uuid, p_person uuid, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_record_txn(p_id, p_person, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_edit_txn(p_id uuid, p_changes jsonb, p_reason text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_edit_txn(p_id, p_changes, p_reason, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_void_txn(p_id uuid, p_reason text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_void_txn(p_id, p_reason, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_reverse_txn(p_new_id uuid, p_id uuid, p_reason text) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_reverse_txn(p_new_id, p_id, p_reason, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_attach_receipt(p_txn uuid, p_file uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_attach_receipt(p_txn, p_file, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_file_affidavit(p_id uuid, p_txn uuid, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_file_affidavit(p_id, p_txn, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_sign(p_form_type text, p_form_id uuid, p_signer_kind text, p_signer_name text, p_attestation text, p_drawn_file uuid DEFAULT NULL, p_scan_file uuid DEFAULT NULL) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_sign(p_form_type, p_form_id, p_signer_kind, p_signer_name, p_attestation, p_drawn_file, p_scan_file, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_request(p_id uuid, p_person uuid, p_data jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_request(p_id, p_person, p_data, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_decide(p_id uuid, p_approve boolean, p_needs_met jsonb, p_reason text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_decide(p_id, p_approve, p_needs_met, p_reason, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.pba_resolve_flag(p_txn uuid, p_reason text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_resolve_flag(p_txn, p_reason, public.my_staff_id(), public.member_role()::text) $$;
CREATE OR REPLACE FUNCTION public.set_org_setting(p_key text, p_value jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._set_org_setting(p_key, p_value, public.my_staff_id(), public.member_role()::text, public.org_id()) $$;

-- balances for one Person's accounts: opening balance + every active entry's effect
CREATE OR REPLACE FUNCTION public._pba_balances(p_person uuid)
RETURNS TABLE (o_account_id uuid, o_balance numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT acc.id, (acc.opening_balance + coalesce((SELECT sum(public._pba_effect(t, acc.id)) FROM pba_transactions t
                                                  WHERE t.person_id = p_person AND (t.account_id = acc.id OR t.to_account_id = acc.id)), 0))::numeric
    FROM pba_accounts acc
   WHERE acc.person_id = p_person
      OR (acc.person_id IS NULL AND EXISTS (SELECT 1 FROM pba_transactions t WHERE t.person_id = p_person AND (t.account_id = acc.id OR t.to_account_id = acc.id)))
$$;
CREATE OR REPLACE FUNCTION public.pba_balances(p_person uuid)
RETURNS TABLE (o_account_id uuid, o_balance numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.pba_can_read(p_person) THEN RETURN; END IF;
  RETURN QUERY SELECT b.o_account_id, b.o_balance FROM public._pba_balances(p_person) b;
END;
$$;

-- ── 8. RLS: read per Decision 5; clients never write these tables directly ──
DO $$
DECLARE
  tbl text;
  person_tables text[] := ARRAY['pba_files', 'pba_enrollments', 'pba_natural_support_determinations', 'pba_role_assignments',
                                'pba_purchase_requests', 'pba_transactions', 'pba_lost_receipt_affidavits', 'pba_signatures', 'pba_month_closes'];
BEGIN
  FOREACH tbl IN ARRAY person_tables || ARRAY['pba_accounts', 'pba_receipts', 'org_settings'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', tbl);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', tbl || '_tenant_guard', tbl);
    EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated
                      USING (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL)', tbl || '_tenant_guard', tbl);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', tbl || '_read', tbl);
  END LOOP;
  FOREACH tbl IN ARRAY person_tables LOOP
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.pba_can_read(person_id))', tbl || '_read', tbl);
  END LOOP;
END $$;

-- accounts: a Person's own account per Decision 5; a collective account is visible to the owner,
-- the Compliance Director and anyone holding a PBA role (each Person's share is in their own entries)
CREATE POLICY pba_accounts_read ON public.pba_accounts FOR SELECT TO authenticated
  USING ((person_id IS NOT NULL AND public.pba_can_read(person_id))
      OR (person_id IS NULL AND (coalesce((SELECT public.member_role())::text, '') IN ('owner', 'compliance_director') OR public.pba_holds_any_role())));
-- receipts: as their transaction
CREATE POLICY pba_receipts_read ON public.pba_receipts FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.pba_transactions t WHERE t.id = transaction_id AND public.pba_can_read(t.person_id)));
-- settings: the provider's office
CREATE POLICY org_settings_read ON public.org_settings FOR SELECT TO authenticated
  USING ((SELECT public.access_tier()) = 'manage');

-- ── 9. Storage (Decision 3): one private, add-only bucket ────────────────
INSERT INTO storage.buckets (id, name, public) VALUES ('pba', 'pba', false) ON CONFLICT (id) DO UPDATE SET public = false;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'storage' AND table_name = 'buckets' AND column_name = 'file_size_limit') THEN
    EXECUTE 'UPDATE storage.buckets SET file_size_limit = 15728640 WHERE id = ''pba''';              -- 15 MB per file
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'storage' AND table_name = 'buckets' AND column_name = 'allowed_mime_types') THEN
    EXECUTE 'UPDATE storage.buckets SET allowed_mime_types = ARRAY[''image/jpeg'', ''image/png'', ''image/webp'', ''image/heic'', ''image/heif'', ''application/pdf'', ''text/csv'', ''text/plain''] WHERE id = ''pba''';
  END IF;
END $$;

-- paths: {org_id}/{person_id}/{receipts|documents|signatures|statements}/{uuid}.{ext}
-- the Person segment is read as text and matched as text, so a malformed path is simply refused
CREATE OR REPLACE FUNCTION public.pba_path_person_ok(p_name text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_parts text[] := string_to_array(p_name, '/'); v_person uuid;
BEGIN
  IF array_length(v_parts, 1) <> 4 OR v_parts[1] <> coalesce(public.org_id()::text, '-')
     OR v_parts[3] NOT IN ('receipts', 'documents', 'signatures', 'statements') THEN RETURN false; END IF;
  SELECT p.id INTO v_person FROM persons p WHERE p.id::text = v_parts[2] AND p.org_id = public.org_id();
  RETURN v_person IS NOT NULL AND public.pba_can_read(v_person);
END;
$$;

DROP POLICY IF EXISTS pba_objects_insert ON storage.objects;
CREATE POLICY pba_objects_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'pba' AND public.pba_path_person_ok(name));
DROP POLICY IF EXISTS pba_objects_select ON storage.objects;
CREATE POLICY pba_objects_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'pba' AND public.pba_path_person_ok(name));
-- deliberately NO update and NO delete policy for the pba bucket: a file can be added, never replaced or removed

-- ── 10. Privileges ───────────────────────────────────────────────────────
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace
              AND (p.proname LIKE '\_pba\_%' OR p.proname IN ('_set_org_setting'))
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace
              AND p.proname IN ('pba_can_read', 'pba_access', 'pba_holds_any_role', 'pba_flags', 'pba_org_flags', 'pba_balances',
                                'pba_start', 'pba_set_enrollment', 'pba_save_form_a', 'pba_assign_role', 'pba_end_role',
                                'pba_register_file', 'pba_save_account', 'pba_record_txn', 'pba_edit_txn', 'pba_void_txn',
                                'pba_reverse_txn', 'pba_attach_receipt', 'pba_file_affidavit', 'pba_sign', 'pba_request',
                                'pba_decide', 'pba_resolve_flag', 'set_org_setting', 'pba_path_person_ok', 'provly_setting')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';


-- ── 11. Self-test: synthetic staff, client and host home (2001 dates), driven through the
--        internal functions with explicit actors; rolled back. Any failure rolls back the file.
CREATE TEMP TABLE IF NOT EXISTS v20029_selftest (n integer, item text, value text, want text) ON COMMIT PRESERVE ROWS;
TRUNCATE v20029_selftest;

CREATE OR REPLACE FUNCTION pg_temp.v20029_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.29 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $$
DECLARE
  v_res jsonb := '[]'::jsonb; v_fail text; v_step text := 'setup';
  v_org uuid; v_person uuid; v_site uuid;
  s_owner uuid; s_cd uuid; s_mgr uuid; s_rev uuid; s_aud uuid; s_host uuid; s_dsp uuid;
  v_bank uuid := gen_random_uuid(); v_cash uuid := gen_random_uuid();
  tx1 uuid := gen_random_uuid(); tx2 uuid := gen_random_uuid(); tx3 uuid := gen_random_uuid(); tx4 uuid := gen_random_uuid();
  tx5 uuid := gen_random_uuid(); tx6 uuid := gen_random_uuid(); tx7 uuid := gen_random_uuid(); tx8 uuid := gen_random_uuid();
  tx9 uuid := gen_random_uuid(); txc1 uuid := gen_random_uuid(); txc2 uuid := gen_random_uuid(); txr uuid := gen_random_uuid();
  v_req uuid := gen_random_uuid(); v_aff uuid := gen_random_uuid(); v_aff2 uuid := gen_random_uuid(); v_aff3 uuid := gen_random_uuid();
  v_formA uuid; v_file uuid; v_proof uuid; v_aud_role uuid;
  v_today date := DATE '2001-01-20';
  v_txt text; v_msg text; v_n integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  SELECT s.org_id INTO v_org FROM staff s ORDER BY s.created_at NULLS LAST, s.id LIMIT 1;

  BEGIN
    v_step := 'setup';
    v_person := pg_temp.v20029_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20029', 'last_name', 'Selftest',
                  'identification_number', '099999931', 'is_active', true));
    s_owner := pg_temp.v20029_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'Test', 'last_name', 'Owner'));
    s_cd    := pg_temp.v20029_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'Test', 'last_name', 'Compliance'));
    s_mgr   := pg_temp.v20029_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'Test', 'last_name', 'Manager'));
    s_rev   := pg_temp.v20029_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'Test', 'last_name', 'Reviewer'));
    s_aud   := pg_temp.v20029_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'Test', 'last_name', 'Auditor'));
    s_host  := pg_temp.v20029_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'Test', 'last_name', 'Host'));
    s_dsp   := pg_temp.v20029_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'Test', 'last_name', 'Dsp'));
    v_site  := pg_temp.v20029_test_insert('org_sites', jsonb_build_object('org_id', v_org, 'name', 'V20029 Selftest HHS', 'site_type', 'hhs', 'capacity', 2, 'is_active', true));
    PERFORM pg_temp.v20029_test_insert('person_placements', jsonb_build_object('org_id', v_org, 'person_id', v_person, 'site_id', v_site, 'start_date', '2000-06-01'));
    PERFORM pg_temp.v20029_test_insert('staff_assignments', jsonb_build_object('org_id', v_org, 'staff_id', s_host, 'site_id', v_site, 'start_date', '2000-06-01'));

    -- T1: only the owner / Compliance Director starts a record; it starts pending
    v_step := 'T1 start';
    v_msg := '';
    BEGIN PERFORM public._pba_start(v_person, 'voluntary', s_mgr, 'dsp'); v_msg := 'dsp ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'dsp refused'; END;
    PERFORM public._pba_start(v_person, 'voluntary', s_owner, 'owner');
    v_res := v_res || jsonb_build_array(jsonb_build_array(1, 'T1 starting a PBA record: a DSP, then the owner (status)',
               v_msg || '; owner → ' || public._pba_enrollment_status(v_person), 'dsp refused; owner → pending'));

    -- T2: roles — separation of duties and the host rule (P8)
    v_step := 'T2 roles';
    PERFORM public._pba_assign_role(v_person, s_mgr, 'manager', s_cd, 'compliance_director');
    PERFORM public._pba_assign_role(v_person, s_rev, 'reviewer', s_cd, 'compliance_director');
    v_aud_role := public._pba_assign_role(v_person, s_aud, 'auditor', s_cd, 'compliance_director');
    v_msg := '';
    BEGIN PERFORM public._pba_assign_role(v_person, s_mgr, 'auditor', s_cd, 'compliance_director'); v_msg := 'two roles ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'two roles refused'; END;
    BEGIN PERFORM public._pba_assign_role(v_person, s_host, 'auditor', s_cd, 'compliance_director'); v_msg := v_msg || '; host ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; host refused'; END;
    BEGIN PERFORM public._pba_assign_role(v_person, s_dsp, 'manager', s_cd, 'compliance_director'); v_msg := v_msg || '; second manager ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; second manager refused'; END;
    BEGIN PERFORM public._pba_assign_role(v_person, s_dsp, 'auditor', s_mgr, 'dsp'); v_msg := v_msg || '; by a manager ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; by a manager refused'; END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(2,
      'T2 roles: the manager as auditor too, the host as auditor (P8), a second manager, a manager assigning roles',
      v_msg, 'two roles refused; host refused; second manager refused; by a manager refused'));

    -- T3: who reads and who writes (Decision 5)
    v_step := 'T3 access';
    SELECT string_agg(x.lbl || ' ' || CASE WHEN (public._pba_access(v_person, x.s, x.r)).o_write THEN 'rw'
                                             WHEN (public._pba_access(v_person, x.s, x.r)).o_read THEN 'r' ELSE '-' END, ', ' ORDER BY x.ord)
      INTO v_txt
      FROM (VALUES (1, 'manager', s_mgr, 'dsp'), (2, 'reviewer', s_rev, 'dsp'), (3, 'compliance', s_cd, 'compliance_director'),
                   (4, 'owner', s_owner, 'owner'), (5, 'host', s_host, 'hhs_operator'), (6, 'dsp', s_dsp, 'dsp'),
                   (7, 'auditor', s_aud, 'dsp')) AS x(ord, lbl, s, r);
    v_res := v_res || jsonb_build_array(jsonb_build_array(3, 'T3 access by standing', v_txt,
      'manager rw, reviewer r, compliance r, owner r, host -, dsp -, auditor r'));

    -- T4: accounts — titling and the "not provider funds" attestation; cash on hand
    v_step := 'T4 accounts';
    PERFORM public._pba_save_account(v_bank, v_person, jsonb_build_object('kind', 'bank', 'institution', 'Zions', 'last4', '1234',
              'titling', 'V20029 Selftest', 'opening_balance', 500, 'opening_date', '2001-01-01', 'not_provider_funds_attested', true), s_mgr, 'dsp');
    PERFORM public._pba_save_account(v_cash, v_person, jsonb_build_object('kind', 'cash', 'titling', 'V20029 Selftest — cash on hand',
              'not_provider_funds_attested', true), s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_save_account(gen_random_uuid(), v_person, jsonb_build_object('kind', 'bank', 'titling', 'X',
              'not_provider_funds_attested', false), s_mgr, 'dsp'); v_msg := 'no attestation ALLOWED';
    EXCEPTION WHEN check_violation THEN v_msg := 'no attestation refused'; END;
    BEGIN PERFORM public._pba_save_account(gen_random_uuid(), v_person, jsonb_build_object('kind', 'pay_card', 'titling', 'X',
              'not_provider_funds_attested', true), s_mgr, 'dsp'); v_msg := v_msg || '; pay card without supervising bank ALLOWED';
    EXCEPTION WHEN check_violation THEN v_msg := v_msg || '; pay card without supervising bank refused'; END;
    v_res := v_res || jsonb_build_array(jsonb_build_array(4, 'T4 accounts: missing attestation, pay card without its supervising institution',
      v_msg, 'no attestation refused; pay card without supervising bank refused'));

    -- the ledger (January 2001)
    v_step := 'ledger';
    PERFORM public._pba_record_txn(tx8, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-03', 'type', 'deposit', 'amount', 900, 'payee', 'SSA', 'category', 'benefit_deposit'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(tx1, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-10', 'type', 'withdrawal', 'amount', 63.40,
              'payee', 'Pharmacy', 'category', 'medical', 'beneficiary', 'other', 'beneficiary_name', 'Girlfriend', 'beneficiary_relationship', 'girlfriend',
              'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(tx2, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-11', 'type', 'withdrawal', 'amount', 48, 'payee', 'Store', 'category', 'personal'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(tx3, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-12', 'type', 'withdrawal', 'amount', 53, 'payee', 'Store', 'category', 'clothing'), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(txc1, v_person, jsonb_build_object('account_id', v_bank, 'to_account_id', v_cash, 'entry_date', '2001-01-05', 'type', 'transfer', 'amount', 40), s_mgr, 'dsp');

    -- T5: P1 + P5 + P6 + P7 + the replay
    v_step := 'T5 flags after P1';
    SELECT string_agg(f.o_flag, ', ' ORDER BY f.o_flag) INTO v_txt FROM public._pba_flags(v_person, v_today) f;
    v_msg := '';
    BEGIN PERFORM public._pba_edit_txn(tx2, '{"amount": 47}'::jsonb, 'typo', s_rev, 'dsp'); v_msg := 'reviewer edit ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'reviewer edit refused'; END;
    v_msg := v_msg || '; replay ' || CASE WHEN public._pba_record_txn(tx2, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-11',
              'type', 'withdrawal', 'amount', 48), s_mgr, 'dsp') = tx2 THEN 'same entry' ELSE 'NEW ENTRY' END;
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'missing_receipt';
    v_res := v_res || jsonb_build_array(jsonb_build_array(5,
      'T5 after the girlfriend''s $63.40 (P1), $48 (P5), $53 (P6): flags · missing receipts · reviewer edit (P7) · a retried record',
      v_txt || ' · ' || v_n || ' missing · ' || v_msg,
      'missing_receipt, missing_receipt, pending_enrollment, recorded_over_block · 2 missing · reviewer edit refused; replay same entry'));

    -- T6: P3 — the request step blocks; approved properly it backs the spend
    v_step := 'T6 request';
    PERFORM public._pba_request(v_req, v_person, jsonb_build_object('amount', 63.40, 'payee', 'Pharmacy', 'category', 'medical', 'beneficiary', 'other',
              'beneficiary_name', 'Girlfriend', 'beneficiary_relationship', 'girlfriend',
              'person_choice', 'He asked to buy cold medicine for his girlfriend'), s_mgr, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_decide(v_req, true, '{"food": true, "shelter": false, "clothing": true, "medical": true}'::jsonb, NULL, s_mgr, 'dsp');
          v_msg := 'needs unmet ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'needs unmet refused'; END;
    PERFORM public._pba_decide(v_req, true, '{"food": true, "shelter": true, "clothing": true, "medical": true}'::jsonb, NULL, s_mgr, 'dsp');
    PERFORM public._pba_record_txn(tx4, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-13', 'type', 'withdrawal', 'amount', 63.40,
              'payee', 'Pharmacy', 'category', 'medical', 'beneficiary', 'other', 'beneficiary_name', 'Girlfriend', 'request_id', v_req,
              'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'recorded_over_block' AND f.o_ref = tx4;
    v_res := v_res || jsonb_build_array(jsonb_build_array(6, 'T6 P3: approval with shelter unmet, then all met; the spend recorded against it',
      v_msg || '; request ' || (SELECT status FROM pba_purchase_requests WHERE id = v_req) || '; over-block flags on it ' || v_n,
      'needs unmet refused; request spent; over-block flags on it 0'));

    -- T7: P4 — the third purchase for the same person in 90 days; then the provider raises the threshold
    v_step := 'T7 third party';
    PERFORM public._pba_record_txn(tx5, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-14', 'type', 'withdrawal', 'amount', 20,
              'payee', 'Florist', 'category', 'gift', 'beneficiary', 'other', 'beneficiary_name', ' Girlfriend '), s_mgr, 'dsp');
    SELECT f.o_detail INTO v_txt FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'third_party_pattern';
    v_msg := '';
    BEGIN PERFORM public._set_org_setting('pba.third_party_count', '5'::jsonb, s_dsp, 'dsp', v_org); v_msg := 'dsp ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'dsp refused'; END;
    PERFORM public._set_org_setting('pba.third_party_count', '5'::jsonb, s_owner, 'owner', v_org);
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'third_party_pattern';
    v_res := v_res || jsonb_build_array(jsonb_build_array(7, 'T7 P4: three purchases for one other person; a DSP then the owner set the threshold to 5',
      coalesce(v_txt, 'no flag') || ' · ' || v_msg || ' · flags at 5: ' || v_n,
      '3 purchases ($146.80) for Girlfriend in the last 90 days — review for possible exploitation · dsp refused · flags at 5: 0'));

    -- T8: receipts — an upload that never arrived is refused; an attached receipt clears its flag
    v_step := 'T8 receipts';
    v_msg := '';
    BEGIN PERFORM public._pba_register_file(gen_random_uuid(), v_person, 'receipt', v_org || '/' || v_person || '/receipts/none.jpg', repeat('a', 64), 'image/jpeg', 10, s_mgr, 'dsp');
          v_msg := 'missing upload ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'missing upload refused'; END;
    v_file := gen_random_uuid();
    INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, mime, bytes, uploaded_by)
    VALUES (v_file, v_org, v_person, 'receipt', v_org || '/' || v_person || '/receipts/' || v_file || '.jpg', repeat('b', 64), 'image/jpeg', 10, s_mgr);
    PERFORM public._pba_attach_receipt(tx3, v_file, s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'missing_receipt' AND f.o_ref = tx3;
    v_res := v_res || jsonb_build_array(jsonb_build_array(8, 'T8 receipts: registering an upload that never arrived; the $53 receipt attached',
      v_msg || '; $53 still flagged ' || v_n, 'missing upload refused; $53 still flagged 0'));

    -- T9: Lost Receipt Affidavit — purchaser signs, a reviewer can't countersign, the Compliance Director does
    v_step := 'T9 affidavit';
    PERFORM public._pba_file_affidavit(v_aff, tx1, jsonb_build_object('store', 'Pharmacy', 'reason', 'Receipt lost on the way home', 'statement_line_ref', '01/10 PHARMACY 63.40'), s_mgr, 'dsp');
    PERFORM public._pba_sign('form_f', v_aff, 'staff', 'Test Dsp', 'I made this purchase and the receipt is lost', NULL, NULL, s_dsp, 'dsp');
    v_msg := '';
    BEGIN PERFORM public._pba_sign('form_f', v_aff, 'staff', 'Test Reviewer', 'Countersigned', NULL, NULL, s_rev, 'dsp'); v_msg := 'reviewer countersign ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'reviewer countersign refused'; END;
    PERFORM public._pba_sign('form_f', v_aff, 'staff', 'Test Compliance', 'Reviewed and countersigned', NULL, NULL, s_cd, 'compliance_director');
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'missing_receipt' AND f.o_ref = tx1;
    v_res := v_res || jsonb_build_array(jsonb_build_array(9, 'T9 Form F on the $63.40: purchaser signs; reviewer then Compliance Director countersign',
      v_msg || '; $63.40 still flagged ' || v_n, 'reviewer countersign refused; $63.40 still flagged 0'));

    -- T10: the affidavit pattern — three affidavits for one purchaser in 90 days
    v_step := 'T10 affidavit pattern';
    PERFORM public._pba_record_txn(tx6, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-15', 'type', 'withdrawal', 'amount', 75,
              'payee', 'Store', 'category', 'personal', 'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    PERFORM public._pba_record_txn(tx7, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-16', 'type', 'withdrawal', 'amount', 80,
              'payee', 'Store', 'category', 'personal', 'purchased_by', 'staff', 'purchased_by_staff_id', s_dsp), s_mgr, 'dsp');
    PERFORM public._pba_file_affidavit(v_aff2, tx6, jsonb_build_object('store', 'Store', 'reason', 'Lost'), s_mgr, 'dsp');
    PERFORM public._pba_file_affidavit(v_aff3, tx7, jsonb_build_object('store', 'Store', 'reason', 'Lost'), s_mgr, 'dsp');
    SELECT f.o_detail INTO v_txt FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'affidavit_pattern';
    v_res := v_res || jsonb_build_array(jsonb_build_array(10, 'T10 three Lost Receipt Affidavits for one purchaser in 90 days',
      coalesce(v_txt, 'no flag'), 'Test Dsp: 3 Lost Receipt Affidavits in the last 90 days — corrective action review'));

    -- T11: the cash log, edits with a reason, voids
    v_step := 'T11 cash, edit, void';
    v_msg := '';
    BEGIN PERFORM public._pba_record_txn(gen_random_uuid(), v_person, jsonb_build_object('account_id', v_cash, 'entry_date', '2001-01-06', 'type', 'withdrawal', 'amount', 15), s_mgr, 'dsp');
          v_msg := 'cash without recipient ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'cash without recipient refused'; END;
    PERFORM public._pba_record_txn(txc2, v_person, jsonb_build_object('account_id', v_cash, 'entry_date', '2001-01-06', 'type', 'withdrawal', 'amount', 15,
              'handed_to', 'person', 'purpose', 'Spending money for the movies'), s_mgr, 'dsp');
    BEGIN PERFORM public._pba_edit_txn(tx2, '{"amount": 47}'::jsonb, '  ', s_mgr, 'dsp'); v_msg := v_msg || '; edit without reason ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; edit without reason refused'; END;
    PERFORM public._pba_edit_txn(tx2, '{"amount": 47}'::jsonb, 'Typo: the statement says 47.00', s_mgr, 'dsp');
    PERFORM public._pba_record_txn(tx9, v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-17', 'type', 'withdrawal', 'amount', 10, 'payee', 'Duplicate'), s_mgr, 'dsp');
    PERFORM public._pba_void_txn(tx9, 'Entered twice', s_mgr, 'dsp');
    SELECT count(*) INTO v_n FROM audit_log WHERE record_id = tx2 AND action = 'pba_txn_edited' AND new_data->>'edit_reason' = 'Typo: the statement says 47.00';
    v_res := v_res || jsonb_build_array(jsonb_build_array(11, 'T11 cash without a recipient; an edit without, then with, a reason (audited); a void',
      v_msg || '; audited ' || v_n || '; voided ' || (SELECT status FROM pba_transactions WHERE id = tx9),
      'cash without recipient refused; edit without reason refused; audited 1; voided voided'));

    -- T12: the month closes (as Release 2 will) — sealed; a reversing entry is the fix
    v_step := 'T12 seal';
    INSERT INTO pba_month_closes (org_id, person_id, month) VALUES (v_org, v_person, DATE '2001-01-01');
    v_msg := '';
    BEGIN PERFORM public._pba_edit_txn(tx2, '{"amount": 46}'::jsonb, 'again', s_mgr, 'dsp'); v_msg := 'edit ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'edit refused'; END;
    BEGIN PERFORM public._pba_void_txn(tx2, 'oops', s_mgr, 'dsp'); v_msg := v_msg || '; void ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; void refused'; END;
    BEGIN PERFORM public._pba_record_txn(gen_random_uuid(), v_person, jsonb_build_object('account_id', v_bank, 'entry_date', '2001-01-25', 'type', 'fee', 'amount', 2), s_mgr, 'dsp');
          v_msg := v_msg || '; new January entry ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := v_msg || '; new January entry refused'; END;
    PERFORM public._pba_reverse_txn(txr, tx3, 'Returned the clothing', s_mgr, 'dsp');
    v_res := v_res || jsonb_build_array(jsonb_build_array(12, 'T12 after January closes: edit, void, a new January entry, then a reversing entry',
      v_msg || '; reversal ' || CASE WHEN EXISTS (SELECT 1 FROM pba_transactions WHERE id = txr AND reverses_id = tx3) THEN 'recorded' ELSE 'MISSING' END,
      'edit refused; void refused; new January entry refused; reversal recorded'));

    -- T13: balances — opening 500 + 900 − 63.40 − 47 − 53 − 63.40 − 20 − 75 − 80 − 40 (+ the 10 voided) + 53 reversed; cash 40 − 15
    v_step := 'T13 balances';
    SELECT string_agg(CASE WHEN b.o_account_id = v_bank THEN 'bank ' ELSE 'cash ' END || to_char(b.o_balance, 'FM999990.00'), ', ' ORDER BY (b.o_account_id = v_cash))
      INTO v_txt FROM public._pba_balances(v_person) b;
    v_res := v_res || jsonb_build_array(jsonb_build_array(13, 'T13 balances', v_txt, 'bank 1011.20, cash 25.00'));

    -- T14: the over-block flag on the $63.40 — the manager can't resolve it, the Compliance Director can
    v_step := 'T14 resolve';
    v_msg := '';
    BEGIN PERFORM public._pba_resolve_flag(tx1, 'ok', s_mgr, 'dsp'); v_msg := 'manager ALLOWED';
    EXCEPTION WHEN raise_exception THEN v_msg := 'manager refused'; END;
    PERFORM public._pba_resolve_flag(tx1, 'He chose it; needs were met that week (confirmed with the SC)', s_cd, 'compliance_director');
    SELECT count(*) INTO v_n FROM public._pba_flags(v_person, v_today) f WHERE f.o_flag = 'recorded_over_block';
    v_res := v_res || jsonb_build_array(jsonb_build_array(14, 'T14 resolving recorded-over-a-block on the $63.40 (the $20 florist gift is still open)',
      v_msg || '; open over-block flags ' || v_n, 'manager refused; open over-block flags 1'));

    -- T15: enrollment completes (fiduciary proof + signed Form A); then the host conflict and an ended role
    v_step := 'T15 enrollment';
    v_proof := gen_random_uuid();
    INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, mime, bytes, uploaded_by)
    VALUES (v_proof, v_org, v_person, 'fiduciary_proof', v_org || '/' || v_person || '/documents/' || v_proof || '.pdf', repeat('c', 64), 'application/pdf', 10, s_owner);
    PERFORM public._pba_set_enrollment(v_person, 'voluntary', v_proof, s_owner, 'owner');
    v_formA := public._pba_save_form_a(v_person, '[{"name": "Mother", "relationship": "mother", "reason": "Lives out of state and declined"}]'::jsonb, s_mgr, 'dsp');
    v_txt := public._pba_enrollment_status(v_person);
    PERFORM public._pba_sign('form_a', v_formA, 'staff', 'Test Manager', 'I prepared this determination and it is accurate', NULL, NULL, s_mgr, 'dsp');
    v_txt := v_txt || ' → ' || public._pba_enrollment_status(v_person)
             || '; fingerprint ' || CASE WHEN (SELECT content_sha256 FROM pba_signatures WHERE form_id = v_formA) ~ '^[0-9a-f]{64}$' THEN 'ok' ELSE 'BAD' END;
    PERFORM pg_temp.v20029_test_insert('staff_assignments', jsonb_build_object('org_id', v_org, 'staff_id', s_rev, 'site_id', v_site, 'start_date', '2001-01-18'));
    PERFORM public._pba_end_role(v_aud_role, s_cd, 'compliance_director');
    SELECT string_agg(f.o_flag, ', ' ORDER BY f.o_flag) INTO v_msg FROM public._pba_flags(v_person, v_today) f
     WHERE f.o_flag IN ('pending_enrollment', 'host_conflict', 'roles_incomplete');
    v_res := v_res || jsonb_build_array(jsonb_build_array(15,
      'T15 proof + Form A (unsigned → signed); then the reviewer joins the host home and the auditor role is ended',
      v_txt || ' · ' || coalesce(v_msg, 'none'), 'pending → enrolled; fingerprint ok · host_conflict, roles_incomplete'));

    RAISE EXCEPTION 'v20029_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'v20029_rollback' THEN
      v_res := v_res || jsonb_build_array(jsonb_build_array(99, 'self-test stopped early', 'at ' || v_step || ': ' || SQLERRM, '(this row should not appear)'));
    END IF;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);

  SELECT string_agg(format('check %s got [%s], want [%s]', e->>0, coalesce(e->>2, 'NULL'), e->>3), ' | ' ORDER BY (e->>0)::integer)
    INTO v_fail FROM jsonb_array_elements(v_res) AS e WHERE (e->>2) IS DISTINCT FROM (e->>3);
  IF v_fail IS NOT NULL OR jsonb_array_length(v_res) <> 15 THEN
    RAISE EXCEPTION 'v20.0.29 self-test failed, so nothing in this file was applied: %',
      coalesce(v_fail, format('%s of 15 checks ran', jsonb_array_length(v_res)));
  END IF;
  INSERT INTO v20029_selftest (n, item, value, want)
  SELECT (e->>0)::integer, e->>1, e->>2, e->>3 FROM jsonb_array_elements(v_res) AS e;
END $$;

DROP FUNCTION IF EXISTS pg_temp.v20029_test_insert(text, jsonb);

COMMIT;


-- ── 12. Verification — paste this table into chat before the PR merges ───
SELECT * FROM (
  SELECT 1 AS n, 'PBA tables (12) with RLS on' AS check_item,
    (SELECT count(*) FILTER (WHERE c.relrowsecurity) || ' of ' || count(*) FROM pg_class c
      WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
        AND c.relname IN ('org_settings', 'pba_files', 'pba_enrollments', 'pba_natural_support_determinations', 'pba_role_assignments',
                          'pba_accounts', 'pba_purchase_requests', 'pba_transactions', 'pba_receipts', 'pba_lost_receipt_affidavits',
                          'pba_signatures', 'pba_month_closes'))::text AS value,
    '12 of 12' AS want
  UNION ALL
  SELECT 2, 'clients can only read PBA tables (no insert / update / delete for signed-in users)',
    (SELECT count(*) FROM information_schema.role_table_grants g
      WHERE g.table_schema = 'public' AND g.grantee IN ('authenticated', 'anon') AND g.privilege_type <> 'SELECT'
        AND (g.table_name LIKE 'pba\_%' OR g.table_name = 'org_settings'))::text, '0'
  UNION ALL
  SELECT 3, 'separation of duties: one role per staff member per Person, one holder per role',
    (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname IN ('pba_roles_one_role_per_staff', 'pba_roles_one_holder_per_role'))::text, '2'
  UNION ALL
  SELECT 4, 'the pba bucket is private, with insert + read policies and NO update or delete policy',
    ((SELECT NOT public FROM storage.buckets WHERE id = 'pba')::text || ' · ' ||
     (SELECT string_agg(policyname, ', ' ORDER BY policyname) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'pba\_%')),
    'true · pba_objects_insert, pba_objects_select'
  UNION ALL
  SELECT 5, 'internal rule functions are not callable by clients; the public RPCs are',
    ((SELECT bool_and(NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p
       WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '\_pba\_%')
     AND has_function_privilege('authenticated', 'public.pba_record_txn(uuid,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.pba_record_txn(uuid,uuid,jsonb)', 'EXECUTE'))::text, 'true'
  UNION ALL
  SELECT 6, '(info) PBA records on file — for you to read', (SELECT count(*) FROM public.pba_enrollments)::text, '(read)'
  UNION ALL
  SELECT 20 + t.n, t.item, t.value, t.want FROM v20029_selftest t
  UNION ALL
  SELECT 100, 'left behind by the self-test (test client, staff, host home, PBA rows)',
    ((SELECT count(*) FROM public.persons WHERE identification_number = '099999931')
     + (SELECT count(*) FROM public.org_sites WHERE name = 'V20029 Selftest HHS')
     + (SELECT count(*) FROM public.staff WHERE first_name = 'Test' AND last_name IN ('Owner', 'Compliance', 'Manager', 'Reviewer', 'Auditor', 'Host', 'Dsp')
          AND hire_date = DATE '1990-01-01' AND date_of_birth = DATE '1990-01-01'))::text,
    '0'
) v ORDER BY n;
