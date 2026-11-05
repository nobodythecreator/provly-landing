-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.39_pba_ledger_fixes.sql
-- PBA ledger correctness (found on a real close: an Oct 2 opening balance was counted on Sept 30)
--
--   1. Opening dates are respected. An entry can't be dated before its account's opening date (new or
--      edited entries are refused; earlier data is flagged), an account's opening date can't move past its
--      earliest entry, and countable assets on a day include only accounts Provly tracks on that day.
--   2. Back pay is excluded the way SSA counts it (POMS SI 01130.600 / .700): a deposit — or part of one —
--      marked as retroactive SSI or RSDI (SSDI) is not counted for the 9 calendar months after the month it
--      arrived. Withdrawals are assumed to come from other money first, so the excluded amount only falls
--      when the balance falls below it, and later deposits don't restore it. Marked by the Person's PBA
--      Manager; a flag stays until the SSA notice is uploaded.
--   3. A sealed month can be reopened — the Owner or Compliance Director (two-factor, via the access
--      helpers), with a written reason, newest sealed month first. The close, its Forms B/C/D/G, findings and
--      asset response are kept, exactly as they were, in pba_reopened_months; the month is open again to
--      reconcile and sign. A Form G sent afterwards is labeled "Amended" (app).
--
-- r1 (Greptile round 1, before this file ran): back pay is tracked as ONE pool across the Person's counted
--   accounts, day by day — several marked deposits share it, transfers between their own accounts leave it
--   whole, spending reduces it once (the soonest-ending exclusion first), later ordinary deposits never
--   restore it; a marked deposit can't be changed, voided or reversed until its mark is removed; marking or
--   removing back pay takes the Person's lock and is refused while a month it affects is sealed; reopening
--   keeps every asset response for the month.
-- r2 (Greptile round 2, before this file ran): the pool is also checked the day after an account closes,
--   the first day it leaves the balance; verification check 2 looks where the opening-date rule now lives.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction: preflight → changes → rolled-back self-test on
-- synthetic Persons (2099 dates) → COMMIT → verification table.
-- Then, separately: sql/v20.0.39a_nicole_correction.sql (the one Person whose record needs correcting).
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $pre$
BEGIN
  IF to_regclass('public.pba_month_closes') IS NULL OR to_regprocedure('public._pba_countable(uuid, date)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.39 preflight: the PBA release 2 migrations (v20.0.30–30r4) have not run';
  END IF;
  IF to_regclass('public.pba_resource_exclusions') IS NOT NULL THEN
    RAISE EXCEPTION 'v20.0.39 preflight: this migration has already run';
  END IF;
END
$pre$;

-- ── 1. Opening dates ─────────────────────────────────────────────────────────────────
CREATE FUNCTION public.trg_pba_txn_after_opening()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_open date;
BEGIN
  -- only a new entry, or a change to its date or accounts, is checked (a void changes neither)
  IF TG_OP = 'UPDATE' AND NEW.entry_date IS NOT DISTINCT FROM OLD.entry_date
     AND NEW.account_id IS NOT DISTINCT FROM OLD.account_id
     AND NEW.to_account_id IS NOT DISTINCT FROM OLD.to_account_id THEN
    RETURN NEW;
  END IF;
  SELECT max(a.opening_date) INTO v_open
    FROM pba_accounts a
   WHERE a.id IN (NEW.account_id, NEW.to_account_id) AND a.opening_date IS NOT NULL AND NEW.entry_date < a.opening_date;
  IF v_open IS NOT NULL THEN
    RAISE EXCEPTION 'This entry is dated % — before the account''s opening date (%). Date it on or after the opening date, or move the account''s opening date earlier, with the balance on that earlier date.',
      to_char(NEW.entry_date, 'FMMM/FMDD/YYYY'), to_char(v_open, 'FMMM/FMDD/YYYY');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER pba_txn_after_opening BEFORE INSERT OR UPDATE ON public.pba_transactions
  FOR EACH ROW EXECUTE FUNCTION public.trg_pba_txn_after_opening();

CREATE FUNCTION public.trg_pba_account_opening_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_first date;
BEGIN
  IF NEW.opening_date IS NOT DISTINCT FROM OLD.opening_date OR NEW.opening_date IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT min(t.entry_date) INTO v_first
    FROM pba_transactions t
   WHERE (t.account_id = NEW.id OR t.to_account_id = NEW.id) AND t.status = 'active';
  IF v_first IS NOT NULL AND NEW.opening_date > v_first THEN
    RAISE EXCEPTION 'This account has an entry dated % — its opening date can''t be later than that', to_char(v_first, 'FMMM/FMDD/YYYY');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER pba_account_opening_guard BEFORE UPDATE OF opening_date ON public.pba_accounts
  FOR EACH ROW EXECUTE FUNCTION public.trg_pba_account_opening_guard();

-- ── 2. Back pay ──────────────────────────────────────────────────────────────────────
CREATE TABLE public.pba_resource_exclusions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL,
  person_id         uuid NOT NULL,
  transaction_id    uuid NOT NULL REFERENCES public.pba_transactions (id),
  kind              text NOT NULL,
  amount            numeric(12,2) NOT NULL,
  received_on       date NOT NULL,
  excluded_through  date NOT NULL,     -- the last day of the 9th calendar month after the month received
  notice_file_id    uuid REFERENCES public.pba_files (id),
  note              text,
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  removed_at        timestamptz,
  removed_by        uuid,
  removed_reason    text,
  CONSTRAINT pba_excl_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_excl_kind_chk CHECK (kind IN ('retro_ssi', 'retro_rsdi')),
  CONSTRAINT pba_excl_amount_chk CHECK (amount > 0),
  CONSTRAINT pba_excl_removed_chk CHECK ((removed_at IS NULL) = (removed_reason IS NULL))
);
CREATE UNIQUE INDEX pba_excl_one_active ON public.pba_resource_exclusions (transaction_id) WHERE removed_at IS NULL;
CREATE INDEX pba_excl_person ON public.pba_resource_exclusions (person_id);

-- The Person's money in counted accounts that Provly tracks on p_day (bank, pay card, cash; opened by
-- that day and not closed before it).
CREATE FUNCTION public._pba_tracked_balance(p_person uuid, p_day date)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT coalesce(sum(public._pba_balance_at(acc.id, p_day)), 0)
    FROM pba_accounts acc
   WHERE acc.person_id = p_person AND acc.kind IN ('bank', 'pay_card', 'cash')
     AND (acc.closed_on IS NULL OR acc.closed_on >= p_day)
     AND (acc.opening_date IS NULL OR acc.opening_date <= p_day)
$$;

-- How much of that money is excluded back pay on p_day (SSA POMS SI 01130.700). Back pay is one pool per
-- Person, followed day by day from the first marked deposit: each marked amount joins the pool on the day
-- it arrived and leaves it when its window ends (excluded_through, the first day it counts). Whenever the
-- tracked balance drops below the pool, the pool drops to the balance — other money is spent first — and
-- the reduction comes from the exclusion that ends soonest, leaving as much excluded as possible. Moving
-- money between the Person's own counted accounts doesn't change the balance, so it doesn't touch the pool;
-- later ordinary deposits raise the balance but never restore spent back pay.
CREATE FUNCTION public._pba_excluded_at(p_person uuid, p_day date)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  ex_amt  numeric[];
  ex_recv date[];
  ex_thru date[];
  ex_left numeric[];
  n       integer;
  i       integer;
  v_first date;
  v_dates date[];
  d       date;
  v_bal   numeric;
  v_over  numeric;
  v_take  numeric;
BEGIN
  -- marked deposits into counted accounts, received by p_day; ordered soonest-ending first
  SELECT array_agg(e.amount ORDER BY e.excluded_through, e.received_on, e.id),
         array_agg(e.received_on ORDER BY e.excluded_through, e.received_on, e.id),
         array_agg(e.excluded_through ORDER BY e.excluded_through, e.received_on, e.id)
    INTO ex_amt, ex_recv, ex_thru
    FROM pba_resource_exclusions e
    JOIN pba_transactions t ON t.id = e.transaction_id AND t.status = 'active'
    JOIN pba_accounts a ON a.id = t.account_id AND a.kind IN ('bank', 'pay_card', 'cash')
   WHERE e.person_id = p_person AND e.removed_at IS NULL AND e.received_on <= p_day;
  IF ex_amt IS NULL THEN
    RETURN 0;
  END IF;
  n := array_length(ex_amt, 1);
  ex_left := array_fill(0::numeric, ARRAY[n]);
  SELECT min(x) INTO v_first FROM unnest(ex_recv) x;

  -- every day on which the pool or the balance can change, through p_day
  SELECT array_agg(dd ORDER BY dd) INTO v_dates FROM (
    SELECT DISTINCT dd FROM (
      SELECT unnest(ex_recv) AS dd
      UNION ALL SELECT unnest(ex_thru)
      UNION ALL SELECT t.entry_date FROM pba_transactions t
                 WHERE t.person_id = p_person AND t.entry_date BETWEEN v_first AND p_day
      UNION ALL SELECT a.opening_date FROM pba_accounts a WHERE a.person_id = p_person AND a.opening_date IS NOT NULL
      UNION ALL SELECT a.closed_on FROM pba_accounts a WHERE a.person_id = p_person AND a.closed_on IS NOT NULL
      UNION ALL SELECT a.closed_on + 1 FROM pba_accounts a WHERE a.person_id = p_person AND a.closed_on IS NOT NULL  -- r2: the first day it leaves the balance
      UNION ALL SELECT p_day
    ) z WHERE dd BETWEEN v_first AND p_day
  ) y;

  FOREACH d IN ARRAY v_dates LOOP
    FOR i IN 1..n LOOP
      IF ex_recv[i] = d THEN ex_left[i] := ex_amt[i]; END IF;     -- arrives
      IF ex_thru[i] <= d THEN ex_left[i] := 0; END IF;           -- its window is over: it counts from here
    END LOOP;
    v_bal := greatest(public._pba_tracked_balance(p_person, d), 0);
    SELECT coalesce(sum(x), 0) INTO v_over FROM unnest(ex_left) x;
    v_over := v_over - v_bal;
    IF v_over > 0 THEN
      FOR i IN 1..n LOOP
        EXIT WHEN v_over <= 0;
        v_take := least(ex_left[i], v_over);
        ex_left[i] := ex_left[i] - v_take;
        v_over := v_over - v_take;
      END LOOP;
    END IF;
  END LOOP;

  RETURN (SELECT coalesce(sum(x), 0) FROM unnest(ex_left) x);
END;
$$;

-- Countable assets on p_day: the tracked balance less excluded back pay.
CREATE OR REPLACE FUNCTION public._pba_countable(p_person uuid, p_day date)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT greatest(public._pba_tracked_balance(p_person, p_day) - public._pba_excluded_at(p_person, p_day), 0)
$$;

-- A marked deposit stays exactly as it was marked: no change to its amount, date, type, account or status,
-- and no reversal, until the mark is removed (the exclusion was measured against that deposit).
CREATE FUNCTION public.trg_pba_back_pay_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.reverses_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM pba_resource_exclusions e WHERE e.transaction_id = NEW.reverses_id AND e.removed_at IS NULL) THEN
      RAISE EXCEPTION 'That deposit is marked as back pay — remove the back-pay mark before reversing it';
    END IF;
  ELSIF EXISTS (SELECT 1 FROM pba_resource_exclusions e WHERE e.transaction_id = NEW.id AND e.removed_at IS NULL)
        AND (NEW.amount, NEW.entry_date, NEW.type, NEW.account_id, NEW.status)
            IS DISTINCT FROM (OLD.amount, OLD.entry_date, OLD.type, OLD.account_id, OLD.status) THEN
    RAISE EXCEPTION 'This deposit is marked as back pay — remove the back-pay mark before changing or voiding it';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER pba_back_pay_guard BEFORE INSERT OR UPDATE ON public.pba_transactions
  FOR EACH ROW EXECUTE FUNCTION public.trg_pba_back_pay_guard();

-- Marking or removing back pay changes countable assets from the month it arrived onward, so it waits
-- for any sealed month from then on to be reopened. (Uses the Person's lock, like every close step.)
CREATE FUNCTION public._pba_back_pay_seal_check(p_person uuid, p_from date)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_sealed date;
BEGIN
  PERFORM public._pba_lock_person(p_person);
  SELECT min(c.month) INTO v_sealed FROM pba_month_closes c
   WHERE c.person_id = p_person AND c.month >= date_trunc('month', p_from)::date;
  IF v_sealed IS NOT NULL THEN
    RAISE EXCEPTION '% is sealed, and back pay changes its countable assets — reopen the sealed months from % on first (newest first)',
      to_char(v_sealed, 'FMMonth YYYY'), to_char(v_sealed, 'FMMonth YYYY');
  END IF;
END;
$$;

CREATE FUNCTION public._pba_mark_back_pay(p_txn uuid, p_kind text, p_amount numeric, p_note text, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  t pba_transactions; a record; v_id uuid;
BEGIN
  SELECT * INTO t FROM pba_transactions WHERE id = p_txn FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That entry doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(t.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can mark back pay'; END IF;
  PERFORM public._pba_back_pay_seal_check(t.person_id, t.entry_date);
  IF t.type <> 'deposit' OR t.status <> 'active' OR t.reverses_id IS NOT NULL THEN
    RAISE EXCEPTION 'Only an active deposit can be marked as back pay';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('retro_ssi', 'retro_rsdi') THEN
    RAISE EXCEPTION 'Choose SSI or Social Security (SSDI) back pay';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount > t.amount THEN
    RAISE EXCEPTION 'The back-pay amount must be more than $0 and no more than the deposit ($%)', to_char(t.amount, 'FM999999990.00');
  END IF;
  IF EXISTS (SELECT 1 FROM pba_resource_exclusions e WHERE e.transaction_id = p_txn AND e.removed_at IS NULL) THEN
    RAISE EXCEPTION 'That deposit is already marked as back pay';
  END IF;
  INSERT INTO pba_resource_exclusions (org_id, person_id, transaction_id, kind, amount, received_on, excluded_through, note, created_by)
  VALUES (t.org_id, t.person_id, p_txn, p_kind, round(p_amount, 2), t.entry_date,
          (date_trunc('month', t.entry_date) + interval '10 months' - interval '1 day')::date,
          nullif(btrim(coalesce(p_note, '')), ''), p_actor)
  RETURNING id INTO v_id;
  PERFORM public._pba_audit(t.org_id, 'pba_back_pay_marked', 'pba_resource_exclusions', v_id, NULL,
                            (SELECT to_jsonb(e) FROM pba_resource_exclusions e WHERE e.id = v_id));
  RETURN v_id;
END;
$$;

CREATE FUNCTION public._pba_back_pay_notice(p_exclusion uuid, p_file uuid, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  e pba_resource_exclusions; a record;
BEGIN
  SELECT * INTO e FROM pba_resource_exclusions WHERE id = p_exclusion FOR UPDATE;
  IF NOT FOUND OR e.removed_at IS NOT NULL THEN RAISE EXCEPTION 'That back-pay record doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(e.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can attach the SSA notice'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.id = p_file AND f.person_id = e.person_id) THEN
    RAISE EXCEPTION 'That file doesn''t belong to this Person';
  END IF;
  UPDATE pba_resource_exclusions SET notice_file_id = p_file WHERE id = p_exclusion;
  PERFORM public._pba_audit(e.org_id, 'pba_back_pay_notice', 'pba_resource_exclusions', p_exclusion, to_jsonb(e),
                            (SELECT to_jsonb(x) FROM pba_resource_exclusions x WHERE x.id = p_exclusion));
END;
$$;

CREATE FUNCTION public._pba_remove_back_pay(p_exclusion uuid, p_reason text, p_actor uuid, p_actor_role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  e pba_resource_exclusions; a record;
BEGIN
  SELECT * INTO e FROM pba_resource_exclusions WHERE id = p_exclusion FOR UPDATE;
  IF NOT FOUND OR e.removed_at IS NOT NULL THEN RAISE EXCEPTION 'That back-pay record doesn''t exist'; END IF;
  SELECT * INTO a FROM public._pba_access(e.person_id, p_actor, p_actor_role);
  IF NOT a.o_write THEN RAISE EXCEPTION 'Only this Person''s PBA Manager can remove a back-pay mark'; END IF;
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason for removing the back-pay mark'; END IF;
  PERFORM public._pba_back_pay_seal_check(e.person_id, e.received_on);
  UPDATE pba_resource_exclusions SET removed_at = now(), removed_by = p_actor, removed_reason = btrim(p_reason) WHERE id = p_exclusion;
  PERFORM public._pba_audit(e.org_id, 'pba_back_pay_removed', 'pba_resource_exclusions', p_exclusion, to_jsonb(e),
                            (SELECT to_jsonb(x) FROM pba_resource_exclusions x WHERE x.id = p_exclusion));
END;
$$;

-- ── 3. Reopening a sealed month ─────────────────────────────────────────────────────
CREATE TABLE public.pba_reopened_months (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL,
  person_id           uuid NOT NULL,
  month               date NOT NULL,
  reason              text NOT NULL,
  original_countable  numeric(12,2),
  snapshot            jsonb NOT NULL,   -- the superseded close, exactly as it was
  reopened_by         uuid,
  reopened_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pba_reopen_person_fk FOREIGN KEY (person_id, org_id) REFERENCES public.persons (id, org_id),
  CONSTRAINT pba_reopen_reason_chk CHECK (length(btrim(reason)) > 0),
  CONSTRAINT pba_reopen_month_chk CHECK (month = date_trunc('month', month)::date)
);
CREATE INDEX pba_reopen_person ON public.pba_reopened_months (person_id, month);

CREATE FUNCTION public._pba_reopen_month(p_person uuid, p_month date, p_reason text, p_actor uuid, p_actor_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_org    uuid;
  v_month  date := date_trunc('month', p_month)::date;
  v_later  date;
  v_fb     pba_form_b;
  v_fc_id  uuid;
  v_fd_id  uuid;
  v_snap   jsonb;
  v_id     uuid;
BEGIN
  SELECT p.org_id INTO v_org FROM persons p WHERE p.id = p_person;
  IF v_org IS NULL THEN RAISE EXCEPTION 'That Person doesn''t exist'; END IF;
  IF coalesce(p_actor_role, '') NOT IN ('owner', 'compliance_director')
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = v_org AND s.is_active) THEN
    RAISE EXCEPTION 'Only the Owner or the Compliance Director can reopen a sealed month';
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN RAISE EXCEPTION 'Give a reason for reopening the month'; END IF;
  PERFORM public._pba_lock_person(p_person);
  IF NOT EXISTS (SELECT 1 FROM pba_month_closes c WHERE c.person_id = p_person AND c.month = v_month) THEN
    RAISE EXCEPTION '% isn''t sealed', to_char(v_month, 'FMMonth YYYY');
  END IF;
  SELECT max(c.month) INTO v_later FROM pba_month_closes c WHERE c.person_id = p_person AND c.month > v_month;
  IF v_later IS NOT NULL THEN
    RAISE EXCEPTION 'Reopen % first — sealed months are reopened newest first', to_char(v_later, 'FMMonth YYYY');
  END IF;

  SELECT * INTO v_fb FROM pba_form_b WHERE person_id = p_person AND month = v_month;
  SELECT id INTO v_fc_id FROM pba_form_c WHERE person_id = p_person AND month = v_month;
  SELECT id INTO v_fd_id FROM pba_form_d WHERE person_id = p_person AND month = v_month;
  v_snap := jsonb_build_object(
    'month_close',    (SELECT to_jsonb(c) FROM pba_month_closes c WHERE c.person_id = p_person AND c.month = v_month),
    'form_b',         to_jsonb(v_fb),
    'form_c',         (SELECT to_jsonb(f) FROM pba_form_c f WHERE f.id = v_fc_id),
    'form_d',         (SELECT to_jsonb(f) FROM pba_form_d f WHERE f.id = v_fd_id),
    'form_g',         (SELECT to_jsonb(f) FROM pba_form_g f WHERE f.person_id = p_person AND f.month = v_month),
    'findings',       (SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) FROM pba_findings x WHERE x.form_d_id = v_fd_id),
    'asset_responses', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.created_at), '[]'::jsonb) FROM pba_asset_responses r
                         WHERE r.person_id = p_person AND r.month = v_month),
    'signatures',     (SELECT coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) FROM pba_signatures s
                        WHERE s.person_id = p_person AND s.form_id IN (v_fb.id, v_fc_id, v_fd_id)));

  INSERT INTO pba_reopened_months (org_id, person_id, month, reason, original_countable, snapshot, reopened_by)
  VALUES (v_org, p_person, v_month, btrim(p_reason), v_fb.countable, v_snap, p_actor)
  RETURNING id INTO v_id;

  -- the month opens: its close and forms leave the live tables (they are in the snapshot above; the
  -- signatures stay where they are, pointing at the superseded forms' ids)
  DELETE FROM pba_findings WHERE form_d_id = v_fd_id;
  DELETE FROM pba_asset_responses WHERE person_id = p_person AND month = v_month;
  DELETE FROM pba_form_g WHERE person_id = p_person AND month = v_month;
  DELETE FROM pba_form_d WHERE id = v_fd_id;
  DELETE FROM pba_form_c WHERE id = v_fc_id;
  DELETE FROM pba_form_b WHERE person_id = p_person AND month = v_month;
  DELETE FROM pba_month_closes WHERE person_id = p_person AND month = v_month;

  PERFORM public._pba_audit(v_org, 'pba_month_reopened', 'pba_reopened_months', v_id, v_snap,
                            jsonb_build_object('month', v_month, 'reason', btrim(p_reason)));
  RETURN v_id;
END;
$$;

-- ── 4. Public wrappers (identity from the access helpers — so two-factor applies) ──────
CREATE FUNCTION public.pba_mark_back_pay(p_txn uuid, p_kind text, p_amount numeric, p_note text DEFAULT NULL) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_mark_back_pay(p_txn, p_kind, p_amount, p_note, public.my_staff_id(), public.member_role()::text) $$;
CREATE FUNCTION public.pba_back_pay_notice(p_exclusion uuid, p_file uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_back_pay_notice(p_exclusion, p_file, public.my_staff_id(), public.member_role()::text) $$;
CREATE FUNCTION public.pba_remove_back_pay(p_exclusion uuid, p_reason text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_remove_back_pay(p_exclusion, p_reason, public.my_staff_id(), public.member_role()::text) $$;
CREATE FUNCTION public.pba_reopen_month(p_person uuid, p_month date, p_reason text) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$ SELECT public._pba_reopen_month(p_person, p_month, p_reason, public.my_staff_id(), public.member_role()::text) $$;

-- ── 5. Flags: back pay with no SSA notice; entries before their account's opening date ──
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

  -- v20.0.39: back pay marked as excluded but with no SSA notice on file yet
  RETURN QUERY
  SELECT 'back_pay_notice'::text,
         format('%s deposit of $%s is marked as back pay (not counted through %s) — upload the SSA notice for it',
                to_char(t.entry_date, 'FMMM/FMDD/YYYY'), to_char(e.amount, 'FM999999990.00'), to_char(e.excluded_through, 'FMMM/FMDD/YYYY')),
         e.id
    FROM pba_resource_exclusions e JOIN pba_transactions t ON t.id = e.transaction_id
   WHERE e.person_id = p_person AND e.removed_at IS NULL AND e.notice_file_id IS NULL AND t.status = 'active';

  -- v20.0.39: entries dated before their account's opening date (earlier data — new ones are refused)
  RETURN QUERY
  SELECT 'entry_before_opening'::text,
         format('%s %s of $%s is dated before its account''s opening date (%s) — move the opening date earlier, with the balance on that date',
                to_char(t.entry_date, 'FMMM/FMDD/YYYY'), t.type, to_char(t.amount, 'FM999999990.00'), to_char(a.opening_date, 'FMMM/FMDD/YYYY')),
         t.id
    FROM pba_transactions t JOIN pba_accounts a ON a.id IN (t.account_id, t.to_account_id)
   WHERE t.person_id = p_person AND t.status = 'active' AND a.opening_date IS NOT NULL AND t.entry_date < a.opening_date;
END;
$$;

-- ── 6. Read access (RLS) and function grants ────────────────────────────────────────
DO $rls$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['pba_resource_exclusions', 'pba_reopened_months'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', tbl);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', tbl);
    EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated
                      USING (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL)', tbl || '_tenant_guard', tbl);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.pba_can_read(person_id))', tbl || '_read', tbl);
  END LOOP;
END
$rls$;

DO $fn$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('trg_pba_txn_after_opening', 'trg_pba_account_opening_guard', '_pba_excluded_at', '_pba_countable',
                         '_pba_tracked_balance', 'trg_pba_back_pay_guard', '_pba_back_pay_seal_check',
                         '_pba_mark_back_pay', '_pba_back_pay_notice', '_pba_remove_back_pay', '_pba_reopen_month', '_pba_flags',
                         'pba_mark_back_pay', 'pba_back_pay_notice', 'pba_remove_back_pay', 'pba_reopen_month')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    IF f.proname IN ('pba_mark_back_pay', 'pba_back_pay_notice', 'pba_remove_back_pay', 'pba_reopen_month') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
  END LOOP;
END
$fn$;

NOTIFY pgrst, 'reload schema';

-- ── 7. Self-test — a synthetic Person, 2099 dates, always rolled back ───────────────
CREATE OR REPLACE FUNCTION pg_temp.v20039_test_insert(p_table text, p_given jsonb)
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
      ELSE quote_literal('v20.0.39 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $test$
DECLARE
  v_org    uuid;
  v_owner  uuid;
  v_person uuid;
  v_acc    uuid := gen_random_uuid();
  v_dep    uuid := gen_random_uuid();
  v_n      numeric;
  v_hist   uuid;
  v_p2     uuid;
  v_mgr    uuid;
  v_a2     uuid := gen_random_uuid();
  v_b2     uuid := gen_random_uuid();
  v_d1     uuid := gen_random_uuid();
  v_d2     uuid := gen_random_uuid();
  v_d4     uuid := gen_random_uuid();
  v_fb4    uuid;
  v_p3     uuid;
  v_c3     uuid := gen_random_uuid();
  v_e3     uuid := gen_random_uuid();
  v_k3     uuid := gen_random_uuid();
BEGIN
  SELECT m.org_id, s.id INTO v_org, v_owner
    FROM org_members m JOIN staff s ON s.user_id = m.user_id AND s.org_id = m.org_id AND s.is_active
   WHERE m.role::text = 'owner' ORDER BY m.joined_at, s.id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'SELFTEST FAIL 0: no active owner to test with'; END IF;

  BEGIN
    v_person := pg_temp.v20039_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20039', 'last_name', 'Selftest',
                                                                            'identification_number', '099999939', 'is_active', true));
    INSERT INTO pba_accounts (id, org_id, person_id, kind, titling, opening_balance, opening_date, not_provider_funds_attested)
    VALUES (v_acc, v_org, v_person, 'bank', 'V20039 Selftest', 100, date '2099-03-01', true);

    -- 1. an entry before the account's opening date is refused
    BEGIN
      INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
      VALUES (gen_random_uuid(), v_org, v_person, v_acc, date '2099-02-15', 'deposit', 50);
      RAISE EXCEPTION 'SELFTEST FAIL 1: an entry before the opening date was accepted';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 2. countable counts only accounts tracked on the day
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
    VALUES (v_dep, v_org, v_person, v_acc, date '2099-03-05', 'deposit', 200);
    IF public._pba_countable(v_person, date '2099-02-28') <> 0 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 2: an account counted before its opening date';
    END IF;
    IF public._pba_countable(v_person, date '2099-03-31') <> 300 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 2b: March countable is not 300';
    END IF;

    -- 3. the opening date can't move past the earliest entry
    BEGIN
      UPDATE pba_accounts SET opening_date = date '2099-03-10' WHERE id = v_acc;
      RAISE EXCEPTION 'SELFTEST FAIL 3: the opening date moved past an entry';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 4. back pay: excluded; other money spent first; later deposits don't restore it; counted after its window
    INSERT INTO pba_resource_exclusions (org_id, person_id, transaction_id, kind, amount, received_on, excluded_through, created_by)
    VALUES (v_org, v_person, v_dep, 'retro_rsdi', 200, date '2099-03-05', date '2099-12-31', v_owner);
    IF public._pba_countable(v_person, date '2099-03-31') <> 100 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4: back pay was counted';
    END IF;
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
    VALUES (gen_random_uuid(), v_org, v_person, v_acc, date '2099-04-10', 'withdrawal', 150);   -- 300 → 150
    IF public._pba_countable(v_person, date '2099-04-30') <> 0 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4b: withdrawals did not come from other money first';
    END IF;
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
    VALUES (gen_random_uuid(), v_org, v_person, v_acc, date '2099-05-03', 'deposit', 500);      -- 150 → 650
    IF public._pba_countable(v_person, date '2099-05-31') <> 500 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4c: a later deposit restored spent back pay';
    END IF;
    IF public._pba_countable(v_person, date '2099-12-31') <> 650 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4d: back pay stayed excluded after its 9 months';
    END IF;

    -- 4e. several marked deposits share one pool: $100 + $100 marked, $100 spent, $400 ordinary → $400 counts
    v_p2 := pg_temp.v20039_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20039', 'last_name', 'Second',
                                                                        'identification_number', '099999938', 'is_active', true));
    INSERT INTO pba_accounts (id, org_id, person_id, kind, titling, opening_balance, opening_date, not_provider_funds_attested)
    VALUES (v_a2, v_org, v_p2, 'bank', 'V20039 Second A', 0, date '2099-06-01', true),
           (v_b2, v_org, v_p2, 'bank', 'V20039 Second B', 0, date '2099-06-01', true);
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
    VALUES (v_d1, v_org, v_p2, v_a2, date '2099-06-02', 'deposit', 100),
           (v_d2, v_org, v_p2, v_a2, date '2099-06-03', 'deposit', 100);
    INSERT INTO pba_resource_exclusions (org_id, person_id, transaction_id, kind, amount, received_on, excluded_through, created_by)
    VALUES (v_org, v_p2, v_d1, 'retro_rsdi', 100, date '2099-06-02', date '2100-03-31', v_owner),
           (v_org, v_p2, v_d2, 'retro_ssi',  100, date '2099-06-03', date '2100-03-31', v_owner);
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
    VALUES (gen_random_uuid(), v_org, v_p2, v_a2, date '2099-06-04', 'withdrawal', 100),
           (v_d4, v_org, v_p2, v_a2, date '2099-06-05', 'deposit', 400);
    IF public._pba_countable(v_p2, date '2099-06-30') <> 400 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4e: spent back pay came back (countable %, expected 400)', public._pba_countable(v_p2, date '2099-06-30');
    END IF;

    -- 4f. moving money between the Person's own accounts leaves back pay whole
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, to_account_id, entry_date, type, amount)
    VALUES (gen_random_uuid(), v_org, v_p2, v_a2, v_b2, date '2099-06-10', 'transfer', 450);
    IF public._pba_countable(v_p2, date '2099-06-30') <> 400 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4f: a transfer between the Person''s accounts changed back pay (countable %)', public._pba_countable(v_p2, date '2099-06-30');
    END IF;

    -- 4i. an account that closes holding back pay takes it out of the pool: later ordinary money counts
    v_p3 := pg_temp.v20039_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20039', 'last_name', 'Third',
                                                                        'identification_number', '099999937', 'is_active', true));
    INSERT INTO pba_accounts (id, org_id, person_id, kind, titling, opening_balance, opening_date, closed_on, not_provider_funds_attested)
    VALUES (v_c3, v_org, v_p3, 'bank', 'V20039 Third C', 0, date '2099-08-01', date '2099-08-10', true),
           (v_e3, v_org, v_p3, 'bank', 'V20039 Third E', 0, date '2099-08-01', NULL, true);
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
    VALUES (v_k3, v_org, v_p3, v_c3, date '2099-08-02', 'deposit', 100);
    INSERT INTO pba_resource_exclusions (org_id, person_id, transaction_id, kind, amount, received_on, excluded_through, created_by)
    VALUES (v_org, v_p3, v_k3, 'retro_rsdi', 100, date '2099-08-02', date '2100-05-31', v_owner);
    INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount)
    VALUES (gen_random_uuid(), v_org, v_p3, v_e3, date '2099-08-12', 'deposit', 100);
    IF public._pba_countable(v_p3, date '2099-08-31') <> 100 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4i: back pay outlived its closed account (countable %, expected 100)', public._pba_countable(v_p3, date '2099-08-31');
    END IF;

    -- 4g. a marked deposit can't be changed or reversed until the mark is removed
    BEGIN
      UPDATE pba_transactions SET amount = 50 WHERE id = v_d1;
      RAISE EXCEPTION 'SELFTEST FAIL 4g: a marked deposit''s amount was changed';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      INSERT INTO pba_transactions (id, org_id, person_id, account_id, entry_date, type, amount, reverses_id)
      VALUES (gen_random_uuid(), v_org, v_p2, v_a2, date '2099-06-20', 'deposit', 100, v_d1);
      RAISE EXCEPTION 'SELFTEST FAIL 4h: a marked deposit was reversed';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    -- 5. marking back pay needs the PBA Manager, and waits while a month it affects is sealed
    BEGIN
      PERFORM public._pba_mark_back_pay(v_d4, 'retro_rsdi', 100, NULL, v_owner, 'owner');
      RAISE EXCEPTION 'SELFTEST FAIL 5: someone other than the PBA Manager marked back pay';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    v_mgr := pg_temp.v20039_test_insert('staff', jsonb_build_object('org_id', v_org, 'first_name', 'V20039', 'last_name', 'Manager'));
    PERFORM public._pba_start(v_p2, 'voluntary', v_owner, 'owner');
    PERFORM public._pba_assign_role(v_p2, v_mgr, 'manager', v_owner, 'compliance_director');
    INSERT INTO pba_month_closes (org_id, person_id, month, closed_by) VALUES (v_org, v_p2, date '2099-07-01', v_owner);
    BEGIN
      PERFORM public._pba_mark_back_pay(v_d4, 'retro_rsdi', 100, NULL, v_mgr, 'dsp');
      RAISE EXCEPTION 'SELFTEST FAIL 5b: back pay was marked while a later month was sealed';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
      IF SQLERRM NOT LIKE '%sealed%' THEN RAISE EXCEPTION 'SELFTEST FAIL 5b: refused for another reason: %', SQLERRM; END IF;
    END;
    PERFORM public._pba_reopen_month(v_p2, date '2099-07-01', 'self-test', v_owner, 'owner');
    PERFORM public._pba_mark_back_pay(v_d4, 'retro_rsdi', 100, NULL, v_mgr, 'dsp');
    IF NOT EXISTS (SELECT 1 FROM pba_resource_exclusions WHERE transaction_id = v_d4 AND removed_at IS NULL
                   AND excluded_through = date '2100-03-31') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 5c: the PBA Manager could not mark back pay, or its window is wrong';
    END IF;
    PERFORM public._pba_remove_back_pay((SELECT id FROM pba_resource_exclusions WHERE transaction_id = v_d4 AND removed_at IS NULL),
                                        'self-test', v_mgr, 'dsp');

    -- 6. reopening: Owner / Compliance Director only, a reason, newest first; the close is kept in history
    INSERT INTO pba_month_closes (org_id, person_id, month, closed_by) VALUES (v_org, v_person, date '2099-03-01', v_owner);
    INSERT INTO pba_form_b (org_id, person_id, month, summary, countable, created_by) VALUES (v_org, v_person, date '2099-03-01', '{"accounts": []}', 111, v_owner);
    INSERT INTO pba_month_closes (org_id, person_id, month, closed_by) VALUES (v_org, v_person, date '2099-04-01', v_owner);
    INSERT INTO pba_form_b (org_id, person_id, month, summary, countable, created_by) VALUES (v_org, v_person, date '2099-04-01', '{"accounts": []}', 222, v_owner)
    RETURNING id INTO v_fb4;
    -- two asset responses for April: one to the live warning, one to the close-time alert
    INSERT INTO pba_asset_responses (org_id, person_id, month, countable, notices, plan_type, plan_detail, target_date, created_by, form_b_id)
    VALUES (v_org, v_person, date '2099-04-01', 222, '{"person": true, "residential": true, "sc": true}', 'other', 'self-test', date '2099-05-01', v_owner, NULL),
           (v_org, v_person, date '2099-04-01', 222, '{"person": true, "residential": true, "sc": true}', 'other', 'self-test', date '2099-05-01', v_owner, v_fb4);
    BEGIN
      PERFORM public._pba_reopen_month(v_person, date '2099-03-01', 'self-test', v_owner, 'owner');
      RAISE EXCEPTION 'SELFTEST FAIL 6: an older month reopened before the newest';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public._pba_reopen_month(v_person, date '2099-04-01', 'self-test', v_owner, 'dsp');
      RAISE EXCEPTION 'SELFTEST FAIL 6b: a role other than Owner / Compliance Director reopened a month';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public._pba_reopen_month(v_person, date '2099-04-01', '  ', v_owner, 'owner');
      RAISE EXCEPTION 'SELFTEST FAIL 6c: a month reopened without a reason';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;
    v_hist := public._pba_reopen_month(v_person, date '2099-04-01', 'self-test', v_owner, 'owner');
    IF EXISTS (SELECT 1 FROM pba_month_closes WHERE person_id = v_person AND month = date '2099-04-01')
       OR EXISTS (SELECT 1 FROM pba_form_b WHERE person_id = v_person AND month = date '2099-04-01') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6d: the reopened month is still sealed';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pba_reopened_months WHERE id = v_hist AND original_countable = 222
                   AND (snapshot -> 'form_b' ->> 'countable')::numeric = 222 AND snapshot ? 'month_close'
                   AND jsonb_array_length(snapshot -> 'asset_responses') = 2) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6e: the superseded close (with both asset responses) was not kept';
    END IF;
    IF EXISTS (SELECT 1 FROM pba_asset_responses WHERE person_id = v_person AND month = date '2099-04-01') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6e2: asset responses for the reopened month are still live';
    END IF;
    PERFORM public._pba_reopen_month(v_person, date '2099-03-01', 'self-test', v_owner, 'compliance_director');
    IF public._pba_month_closed(v_person, date '2099-03-15') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6f: March did not reopen after April';
    END IF;

    -- 7. without a signed-in session the wrappers refuse (no staff id → no access)
    BEGIN
      PERFORM public.pba_reopen_month(v_person, date '2099-03-01', 'self-test');
      RAISE EXCEPTION 'SELFTEST FAIL 7: pba_reopen_month ran without a session';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'SELFTEST%' THEN RAISE; END IF;
    END;

    RAISE EXCEPTION 'SELFTEST_ROLLBACK' USING ERRCODE = 'PRVOK';
  EXCEPTION WHEN SQLSTATE 'PRVOK' THEN
    NULL;  -- every self-test write above is rolled back here
  END;
END
$test$;

COMMIT;

-- ── Verification table (paste this result into the PR and the chat) ────────────────
SELECT n, check_name, got, want, CASE WHEN got = want THEN '✅' ELSE '❌' END AS ok FROM (
  SELECT 1 n, 'Entries before an account''s opening date are refused' check_name,
    (SELECT count(*) FROM pg_trigger WHERE tgname IN ('pba_txn_after_opening', 'pba_account_opening_guard') AND NOT tgisinternal)::text got, '2' want
  UNION ALL SELECT 2, 'Countable assets: tracked accounts only, less excluded back pay',
    (position('_pba_tracked_balance' IN pg_get_functiondef('public._pba_countable(uuid, date)'::regprocedure)) > 0
     AND position('_pba_excluded_at' IN pg_get_functiondef('public._pba_countable(uuid, date)'::regprocedure)) > 0
     AND position('opening_date' IN pg_get_functiondef('public._pba_tracked_balance(uuid, date)'::regprocedure)) > 0)::text, 'true'
  UNION ALL SELECT 3, 'Back-pay and reopen tables with RLS',
    (SELECT count(*) FROM pg_class WHERE relname IN ('pba_resource_exclusions', 'pba_reopened_months') AND relrowsecurity)::text, '2'
  UNION ALL SELECT 4, 'Clients cannot write them directly',
    (has_table_privilege('authenticated', 'public.pba_resource_exclusions', 'INSERT')
     OR has_table_privilege('authenticated', 'public.pba_reopened_months', 'INSERT'))::text, 'false'
  UNION ALL SELECT 5, 'New public PBA functions for signed-in users (not anon)',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('pba_mark_back_pay', 'pba_back_pay_notice', 'pba_remove_back_pay', 'pba_reopen_month')
       AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE'))::text, '4'
  UNION ALL SELECT 6, 'Internal functions callable by clients',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('_pba_excluded_at', '_pba_tracked_balance', '_pba_back_pay_seal_check', '_pba_mark_back_pay',
                                                    '_pba_back_pay_notice', '_pba_remove_back_pay', '_pba_reopen_month')
       AND (has_function_privilege('authenticated', oid, 'EXECUTE') OR has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  UNION ALL SELECT 7, 'New flags: back-pay notice, entry before opening',
    ((position('back_pay_notice' IN pg_get_functiondef('public._pba_flags(uuid, date)'::regprocedure)) > 0)
     AND (position('entry_before_opening' IN pg_get_functiondef('public._pba_flags(uuid, date)'::regprocedure)) > 0))::text, 'true'
  UNION ALL SELECT 8, 'Self-test leftovers (synthetic Persons)',
    (SELECT count(*) FROM persons WHERE identification_number IN ('099999939', '099999938', '099999937'))::text, '0'
  UNION ALL SELECT 10, 'Marked deposits locked until the mark is removed',
    (SELECT count(*) FROM pg_trigger WHERE tgname = 'pba_back_pay_guard' AND NOT tgisinternal)::text, '1'
  UNION ALL SELECT 9, 'Entries already dated before their account''s opening date (corrected by 39a or by hand)',
    (SELECT count(DISTINCT t.id) FROM pba_transactions t JOIN pba_accounts a ON a.id IN (t.account_id, t.to_account_id)
      WHERE t.status = 'active' AND a.opening_date IS NOT NULL AND t.entry_date < a.opening_date)::text,
    (SELECT count(DISTINCT t.id) FROM pba_transactions t JOIN pba_accounts a ON a.id IN (t.account_id, t.to_account_id)
      WHERE t.status = 'active' AND a.opening_date IS NOT NULL AND t.entry_date < a.opening_date)::text
) t
ORDER BY n;
