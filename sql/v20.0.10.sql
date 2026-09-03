-- ============================================================================
-- Provly v20.0.10 — additive migration. Safe to re-run.
-- Run AFTER discovery (Aug 2026): evv_sessions has no original_* columns and
-- no triggers; person_service_authorizations.status is the enum
-- authorization_status (pending, approved, rejected, expired), default
-- 'pending'; PM1 / PM2 / SEI carry zero authorizations.
-- ============================================================================


-- ── Item 5: EVV originals live on the visit row, stamped by trigger ──────────
-- The edit log (evv_edit_log) says what changed and why. The row itself must
-- still say what was captured at the point of care — that is what an EVV
-- auditor reads. The original_* columns are DERIVED ONLY: the trigger discards
-- any caller-supplied value on INSERT and on UPDATE, then stamps them from the
-- pre-correction clock values the first time a clock time changes. Write-once
-- after that. (Greptile r1: the first cut only guarded a non-null original, so
-- a direct UPDATE could plant an arbitrary "captured" time while it was still
-- null; now no code path can write these columns at all.)

ALTER TABLE public.evv_sessions
  ADD COLUMN IF NOT EXISTS original_clock_in_at  timestamptz,
  ADD COLUMN IF NOT EXISTS original_clock_out_at timestamptz;

COMMENT ON COLUMN public.evv_sessions.original_clock_in_at  IS 'v20.0.10 — clock_in_at as captured at the point of care; stamped by trigger on first manual correction; write-once.';
COMMENT ON COLUMN public.evv_sessions.original_clock_out_at IS 'v20.0.10 — clock_out_at as captured at the point of care; stamped by trigger on first manual correction; write-once.';

CREATE OR REPLACE FUNCTION public.evv_sessions_preserve_originals()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- INSERT: a new visit has no history. Whatever the caller sent for the
  -- original_* columns is discarded — they start NULL, always.
  IF TG_OP = 'INSERT' THEN
    NEW.original_clock_in_at  := NULL;
    NEW.original_clock_out_at := NULL;
    RETURN NEW;
  END IF;

  -- UPDATE: originals are never accepted from the caller. Start from what the
  -- row already holds (this also makes an existing original write-once) ...
  NEW.original_clock_in_at  := OLD.original_clock_in_at;
  NEW.original_clock_out_at := OLD.original_clock_out_at;

  -- ... then stamp on the FIRST correction of a captured instant, from the
  -- pre-correction value only. (A live clock-out — NULL -> value — copies
  -- NULL, so a normal visit never acquires a false "edited" marker.)
  IF NEW.clock_in_at IS DISTINCT FROM OLD.clock_in_at AND OLD.original_clock_in_at IS NULL THEN
    NEW.original_clock_in_at := OLD.clock_in_at;
  END IF;
  IF NEW.clock_out_at IS DISTINCT FROM OLD.clock_out_at AND OLD.original_clock_out_at IS NULL THEN
    NEW.original_clock_out_at := OLD.clock_out_at;
  END IF;

  RETURN NEW;
END
$$;

-- Fires on every INSERT and UPDATE (no column list): the columns are derived
-- unconditionally, so there is no write that should bypass the function.
DROP TRIGGER IF EXISTS trg_evv_sessions_preserve_originals ON public.evv_sessions;
CREATE TRIGGER trg_evv_sessions_preserve_originals
  BEFORE INSERT OR UPDATE
  ON public.evv_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.evv_sessions_preserve_originals();


-- ── Item 3: one-time status backfill ────────────────────────────────────────
-- authorization_status is an APPROVAL vocabulary. Every row created before
-- v20.0.10 landed on the column default ('pending') because no insert path
-- ever wrote status. An auth entered from a DSPD worksheet is approved by
-- definition; a fully-past window is expired. 'rejected' rows (none today)
-- are left alone. Re-running only re-derives the same truth.

UPDATE public.person_service_authorizations
SET status = CASE
               WHEN end_date IS NOT NULL AND end_date < CURRENT_DATE THEN 'expired'::authorization_status
               ELSE 'approved'::authorization_status
             END
WHERE status IN ('pending'::authorization_status, 'approved'::authorization_status)
  AND status IS DISTINCT FROM CASE
                                WHEN end_date IS NOT NULL AND end_date < CURRENT_DATE THEN 'expired'::authorization_status
                                ELSE 'approved'::authorization_status
                              END;


-- ── Item 1 (Greptile r1 → r2): retry-safe authorization creation ───────────
-- Retry safety lives in the app: each row attempt carries a client-generated
-- id, so a replay of a committed-but-lost request hits the primary key and is
-- recognized as already on file (confirmed by execution in round 1). Round 1
-- also added a unique index on (person_id, service_code_id, start_date); round
-- 2 showed it rejects legitimately distinct authorizations (same code and
-- start date, different units / end date / negotiated rate), so it is removed.
-- Re-runnable: drops the index wherever round 1 created it, no-op otherwise.

DROP INDEX IF EXISTS public.uq_psa_person_code_start;


-- ── Item 2: service codes new on DHHS91172 (effective 7/1/2026) ─────────────
-- The service-code dropdowns read service_code_definitions, so BILLING_RULES
-- entries alone don't make SJD / SJR / SJP selectable. Several columns are
-- NOT NULL (billing_unit enum, description, outcome_measure, sow_article,
-- documentation/licensing/staff jsonb), so each new row is CLONED from SEI —
-- the Supported Employment sibling — with its own code/name/description.
-- SJR / SJP are milestone (per-session) payments: billing_unit is taken from
-- RPS (the existing per-session code) when that row exists, else SEI's.
-- ► Verify sow_article / documentation requirements for these three against
--   the SOW; they are inherited from SEI as the best available default.

INSERT INTO public.service_code_definitions
  (code, name, description, billing_unit, sow_article, outcome_measure, evv_required,
   requires_quarterly_summary, requires_support_strategy,
   documentation_requirements, licensing_requirements, staff_qualifications, service_limitations)
SELECT 'SJD', 'Supported Job Development',
       'Supported Job Development — quarter hour, $17.31 (DHHS91172 eff. 7/1/2026). Metadata cloned from SEI at v20.0.10; verify SOW article.',
       s.billing_unit, s.sow_article, s.outcome_measure, s.evv_required,
       s.requires_quarterly_summary, s.requires_support_strategy,
       s.documentation_requirements, s.licensing_requirements, s.staff_qualifications, s.service_limitations
FROM public.service_code_definitions s
WHERE s.code = 'SEI'
  AND NOT EXISTS (SELECT 1 FROM public.service_code_definitions WHERE code = 'SJD');

INSERT INTO public.service_code_definitions
  (code, name, description, billing_unit, sow_article, outcome_measure, evv_required,
   requires_quarterly_summary, requires_support_strategy,
   documentation_requirements, licensing_requirements, staff_qualifications, service_limitations)
SELECT 'SJR', 'Supported Job Retention Milestone Payment',
       'Supported Job Retention Milestone Payment — per session, $620.00 (DHHS91172 eff. 7/1/2026). Metadata cloned from SEI at v20.0.10; verify SOW article.',
       COALESCE((SELECT r.billing_unit FROM public.service_code_definitions r WHERE r.code = 'RPS' LIMIT 1), s.billing_unit),
       s.sow_article, s.outcome_measure, s.evv_required,
       s.requires_quarterly_summary, s.requires_support_strategy,
       s.documentation_requirements, s.licensing_requirements, s.staff_qualifications, s.service_limitations
FROM public.service_code_definitions s
WHERE s.code = 'SEI'
  AND NOT EXISTS (SELECT 1 FROM public.service_code_definitions WHERE code = 'SJR');

INSERT INTO public.service_code_definitions
  (code, name, description, billing_unit, sow_article, outcome_measure, evv_required,
   requires_quarterly_summary, requires_support_strategy,
   documentation_requirements, licensing_requirements, staff_qualifications, service_limitations)
SELECT 'SJP', 'Supported Initial Job Placement Milestone Payment',
       'Supported Initial Job Placement Milestone Payment — per session, $620.00 (DHHS91172 eff. 7/1/2026). Metadata cloned from SEI at v20.0.10; verify SOW article.',
       COALESCE((SELECT r.billing_unit FROM public.service_code_definitions r WHERE r.code = 'RPS' LIMIT 1), s.billing_unit),
       s.sow_article, s.outcome_measure, s.evv_required,
       s.requires_quarterly_summary, s.requires_support_strategy,
       s.documentation_requirements, s.licensing_requirements, s.staff_qualifications, s.service_limitations
FROM public.service_code_definitions s
WHERE s.code = 'SEI'
  AND NOT EXISTS (SELECT 1 FROM public.service_code_definitions WHERE code = 'SJP');


-- ── Verification (single statement — the SQL editor shows only the last result) ──
SELECT 'evv originals cols'          AS what, count(*)::text AS result
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'evv_sessions'
   AND column_name IN ('original_clock_in_at', 'original_clock_out_at')
UNION ALL
SELECT 'evv trigger', count(*)::text
  FROM pg_trigger WHERE tgname = 'trg_evv_sessions_preserve_originals'
UNION ALL
SELECT 'auth status: ' || status::text, count(*)::text
  FROM public.person_service_authorizations GROUP BY status
UNION ALL
SELECT 'service code present: ' || code, name
  FROM public.service_code_definitions WHERE code IN ('SJD', 'SJR', 'SJP')
UNION ALL
SELECT 'psa r1 unique index (want 0 — dropped)', count(*)::text
  FROM pg_indexes WHERE indexname = 'uq_psa_person_code_start'
UNION ALL
SELECT 'evv trigger events', string_agg(event_manipulation, '+' ORDER BY event_manipulation)
  FROM information_schema.triggers WHERE trigger_name = 'trg_evv_sessions_preserve_originals'
ORDER BY what;
-- Expect: originals cols = 2, trigger = 1 (events INSERT+UPDATE), no 'pending'
-- auth rows, three SJ* codes, r1 unique index = 0 (dropped).
