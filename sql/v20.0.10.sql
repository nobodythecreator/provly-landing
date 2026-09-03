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
-- auditor reads. Set-once: written the first time a clock time is corrected,
-- never overwritten afterwards, and immune to any client path that forgets.

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
  -- First correction of a captured instant: remember what it was.
  -- (A live clock-out — NULL -> value — copies NULL, so a normal visit never
  --  acquires a false "edited" marker.)
  IF NEW.clock_in_at IS DISTINCT FROM OLD.clock_in_at AND OLD.original_clock_in_at IS NULL THEN
    NEW.original_clock_in_at := OLD.clock_in_at;
  END IF;
  IF NEW.clock_out_at IS DISTINCT FROM OLD.clock_out_at AND OLD.original_clock_out_at IS NULL THEN
    NEW.original_clock_out_at := OLD.clock_out_at;
  END IF;

  -- Write-once: once an original exists, no UPDATE can alter it.
  IF OLD.original_clock_in_at IS NOT NULL THEN
    NEW.original_clock_in_at := OLD.original_clock_in_at;
  END IF;
  IF OLD.original_clock_out_at IS NOT NULL THEN
    NEW.original_clock_out_at := OLD.original_clock_out_at;
  END IF;

  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_evv_sessions_preserve_originals ON public.evv_sessions;
CREATE TRIGGER trg_evv_sessions_preserve_originals
  BEFORE UPDATE OF clock_in_at, clock_out_at, original_clock_in_at, original_clock_out_at
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
ORDER BY what;
-- Expect: originals cols = 2, trigger = 1, no 'pending' auth rows, three SJ* codes.
