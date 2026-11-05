-- ⚠ RUN ONLY AFTER sql/v20.0.39_pba_ledger_fixes.sql HAS RUN (and the PR's review is 5/5) ⚠
-- =====================================================================================
-- sql/v20.0.39a_nicole_correction.sql
-- One Person's record, corrected from her Zions Bank statements (September and October 2026).
--
-- What was wrong: bank account ··7716 was added with an opening balance of $4,688.00 dated Oct 2 — the
-- bank's balance at the end of Oct 2, which already included the 9/25 deposit ($3,516) and the 10/2
-- deposit ($1,172). Provly then counted that opening balance on Sept 30, before its date, and counted
-- the 9/25 deposit again: $8,204 "countable" at the September close. (Provly bug, fixed in v20.0.39.)
--
-- What the statements show: the account's first statement period began Sept 1 at $0.00. The 9/25
-- deposit is three months of Social Security (on her father's record) paid together — back pay, which SSA
-- does not count toward the resource limit until July 1, 2027.
--
-- This file: reopens September (the signed close is kept as superseded, with the reason below); starts
-- the account Sept 1 at $0.00; relabels the two Social Security deposits; marks the 9/25 deposit as back
-- pay (the SSA notice can be uploaded in the app). Then it checks itself against the statements: Sept 30
-- must be $3,516.00 and countable $0.00, or nothing is saved.
--
-- Afterwards, in Provly: enter September's statement (opening $0.00, closing $3,516.00, the 9/25 line),
-- reconcile and sign Form B; then October's (opening $3,516.00, closing $4,235.00 — the $449.95 card
-- payment dated 10/30 shows as outstanding), and continue the close as normal.
--
-- RUN IN SUPABASE (SQL editor), ONCE. It stops without changing anything if the record isn't exactly as
-- described above (for example, if it was already corrected by hand) — both deposits must be present.
-- r1 (Greptile round 1, before this file ran): the 10/2 deposit is required too.
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $fix$
DECLARE
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_reason constant text := 'Corrected from the Zions Bank statements: the account was added with a $4,688.00 opening balance dated Oct 2, '
                         || 'which already included the 9/25 and 10/2 deposits, and Provly counted it on Sept 30 (fixed in v20.0.39). '
                         || 'The account opened in September at $0.00; the 9/25 deposit of $3,516.00 is three months of Social Security '
                         || 'back pay, not counted toward the resource limit through June 2027. September is reopened to reconcile '
                         || 'against the September statement and sign again.';
  v_person uuid;
  v_n      integer;
  v_acc    uuid;
  v_dep    uuid;
  v_oct    uuid;
  v_owner  uuid;
  v_old    jsonb;
  v_excl   uuid;
  v_bal    numeric;
  v_cnt    numeric;
BEGIN
  IF to_regclass('public.pba_resource_exclusions') IS NULL THEN
    RAISE EXCEPTION 'v20.0.39a: run sql/v20.0.39_pba_ledger_fixes.sql first. Nothing was changed.';
  END IF;

  SELECT count(*) INTO v_n FROM persons
   WHERE org_id = v_org AND first_name ILIKE 'nicole%' AND last_name ILIKE 'hyden%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'v20.0.39a: expected one Person named Nicole Hyden, found %. Nothing was changed.', v_n; END IF;
  SELECT id INTO v_person FROM persons
   WHERE org_id = v_org AND first_name ILIKE 'nicole%' AND last_name ILIKE 'hyden%';

  SELECT id INTO v_acc FROM pba_accounts WHERE person_id = v_person AND kind = 'bank' AND last4 = '7716';
  IF v_acc IS NULL THEN RAISE EXCEPTION 'v20.0.39a: bank account ··7716 not found. Nothing was changed.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pba_accounts WHERE id = v_acc AND opening_balance = 4688.00 AND opening_date = date '2026-10-02') THEN
    RAISE EXCEPTION 'v20.0.39a: account ··7716 no longer opens Oct 2 at $4,688.00 — it may already be corrected. Nothing was changed.';
  END IF;

  SELECT id INTO v_dep FROM pba_transactions
   WHERE person_id = v_person AND account_id = v_acc AND entry_date = date '2026-09-25'
     AND type = 'deposit' AND amount = 3516.00 AND status = 'active' AND reverses_id IS NULL;
  IF v_dep IS NULL THEN RAISE EXCEPTION 'v20.0.39a: the 9/25 deposit of $3,516.00 was not found. Nothing was changed.'; END IF;
  SELECT id INTO v_oct FROM pba_transactions
   WHERE person_id = v_person AND account_id = v_acc AND entry_date = date '2026-10-02'
     AND type = 'deposit' AND amount = 1172.00 AND status = 'active' AND reverses_id IS NULL;
  IF v_oct IS NULL THEN RAISE EXCEPTION 'v20.0.39a: the 10/2 deposit of $1,172.00 was not found. Nothing was changed.'; END IF;

  IF NOT EXISTS (SELECT 1 FROM pba_month_closes WHERE person_id = v_person AND month = date '2026-09-01') THEN
    RAISE EXCEPTION 'v20.0.39a: September is not sealed. Nothing was changed.';
  END IF;
  IF EXISTS (SELECT 1 FROM pba_month_closes WHERE person_id = v_person AND month > date '2026-09-01') THEN
    RAISE EXCEPTION 'v20.0.39a: a month after September is sealed — tell me before going further. Nothing was changed.';
  END IF;

  SELECT s.id INTO v_owner
    FROM org_members m JOIN staff s ON s.user_id = m.user_id AND s.org_id = m.org_id AND s.is_active
   WHERE m.org_id = v_org AND m.role::text = 'owner' ORDER BY m.joined_at, s.id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'v20.0.39a: no active owner found. Nothing was changed.'; END IF;

  -- 1. reopen September (the signed close is kept, exactly as it was, in pba_reopened_months)
  PERFORM public._pba_reopen_month(v_person, date '2026-09-01', v_reason, v_owner, 'owner');

  -- 2. the account starts Sept 1 at $0.00 — the bank's balance on 8/31
  SELECT to_jsonb(a) INTO v_old FROM pba_accounts a WHERE a.id = v_acc;
  UPDATE pba_accounts SET opening_date = date '2026-09-01', opening_balance = 0.00, updated_at = now() WHERE id = v_acc;
  PERFORM public._pba_audit(v_org, 'pba_account_corrected', 'pba_accounts', v_acc, v_old,
                            (SELECT to_jsonb(a) FROM pba_accounts a WHERE a.id = v_acc));

  -- 3. the deposits are Social Security (SSDI on her father's record), not SSI
  SELECT to_jsonb(t) INTO v_old FROM pba_transactions t WHERE t.id = v_dep;
  UPDATE pba_transactions SET payee = 'Social Security (SSDI) — back pay', updated_at = now() WHERE id = v_dep;
  PERFORM public._pba_audit(v_org, 'pba_txn_relabeled', 'pba_transactions', v_dep, v_old,
                            (SELECT to_jsonb(t) FROM pba_transactions t WHERE t.id = v_dep));
  SELECT to_jsonb(t) INTO v_old FROM pba_transactions t WHERE t.id = v_oct;
  UPDATE pba_transactions SET payee = 'Social Security (SSDI)', updated_at = now() WHERE id = v_oct;
  PERFORM public._pba_audit(v_org, 'pba_txn_relabeled', 'pba_transactions', v_oct, v_old,
                            (SELECT to_jsonb(t) FROM pba_transactions t WHERE t.id = v_oct));

  -- 4. the 9/25 deposit is back pay: not counted through June 30, 2027 (SSA notice to be uploaded in the app)
  INSERT INTO pba_resource_exclusions (org_id, person_id, transaction_id, kind, amount, received_on, excluded_through, note, created_by)
  VALUES (v_org, v_person, v_dep, 'retro_rsdi', 3516.00, date '2026-09-25', date '2027-06-30',
          'Three months of Social Security (her father''s record, $1,172 a month) paid together on 9/25 after the benefit was on hold.',
          v_owner)
  RETURNING id INTO v_excl;
  PERFORM public._pba_audit(v_org, 'pba_back_pay_marked', 'pba_resource_exclusions', v_excl, NULL,
                            (SELECT to_jsonb(e) FROM pba_resource_exclusions e WHERE e.id = v_excl));

  -- 5. check against the September statement — any mismatch undoes everything above
  v_bal := public._pba_balance_at(v_acc, date '2026-09-30');
  IF v_bal IS DISTINCT FROM 3516.00 THEN
    RAISE EXCEPTION 'v20.0.39a check: Provly shows % for Sept 30; the statement says $3,516.00. Nothing was changed.', v_bal;
  END IF;
  v_cnt := public._pba_countable(v_person, date '2026-09-30');
  IF v_cnt IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'v20.0.39a check: countable for Sept 30 is %, expected $0.00. Nothing was changed.', v_cnt;
  END IF;
END
$fix$;

COMMIT;

-- ── Verification (paste this result into the PR and the chat) ────────────────────────
WITH p AS (
  SELECT id FROM persons WHERE org_id = '00000000-0000-0000-0000-000000000001'
     AND first_name ILIKE 'nicole%' AND last_name ILIKE 'hyden%' LIMIT 1
), a AS (
  SELECT acc.* FROM pba_accounts acc JOIN p ON acc.person_id = p.id WHERE acc.kind = 'bank' AND acc.last4 = '7716'
)
SELECT n, check_name, got, want, CASE WHEN got = want THEN '✅' ELSE '❌' END AS ok FROM (
  SELECT 1 n, 'Account ··7716 opens' check_name, (SELECT opening_date::text || ' at ' || opening_balance::text FROM a) got, '2026-09-01 at 0.00' want
  UNION ALL SELECT 2, 'Balance on Sept 30 (statement: 3516.00)', (SELECT round(public._pba_balance_at(a.id, date '2026-09-30'), 2)::text FROM a), '3516.00'
  UNION ALL SELECT 3, 'Countable on Sept 30', (SELECT round(public._pba_countable(p.id, date '2026-09-30'), 2)::text FROM p), '0.00'
  UNION ALL SELECT 4, 'September open again (reconcile and sign in Provly)',
    (SELECT (NOT public._pba_month_closed(p.id, date '2026-09-15'))::text FROM p), 'true'
  UNION ALL SELECT 5, 'Original September close kept (countable 8204.00)',
    (SELECT max(r.original_countable)::text FROM pba_reopened_months r JOIN p ON r.person_id = p.id WHERE r.month = date '2026-09-01'), '8204.00'
  UNION ALL SELECT 6, 'Back pay marked on the 9/25 deposit',
    (SELECT count(*)::text FROM pba_resource_exclusions e JOIN p ON e.person_id = p.id WHERE e.removed_at IS NULL AND e.amount = 3516.00), '1'
  UNION ALL SELECT 7, 'Ledger balance on Oct 30 (4235.00 at the bank, less the $449.95 card payment not yet cleared)',
    (SELECT round(public._pba_balance_at(a.id, date '2026-10-30'), 2)::text FROM a), '3785.05'
) t
ORDER BY n;
