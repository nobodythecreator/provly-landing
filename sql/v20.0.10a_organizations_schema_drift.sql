-- ============================================================================
-- Provly v20.0.10a — organizations schema drift. Additive. Safe to re-run.
--
-- WHY: production carries columns that were added live (white-label branding,
-- legal identity, enforcement toggles) and never committed. The v20.0.9 review
-- caught this twice (r15, r17): a migration and the checkout function each
-- referenced a production-only column and would have failed on any fresh
-- install. Item 4 writes RLS policies against this table; they must be written
-- against the schema that actually exists.
--
-- SOURCE OF TRUTH: information_schema.columns on production, 2026-09-07.
-- Every column below is declared with production's exact type, nullability
-- and default. On production every ADD COLUMN is a no-op (IF NOT EXISTS); on
-- a fresh install it creates exactly what production has.
--
-- checkout_lock_at and stripe_checkout_session_id are NOT here — they were
-- committed in sql/v20.0.9.sql.
-- ============================================================================

ALTER TABLE public.organizations
  -- legal identity
  ADD COLUMN IF NOT EXISTS legal_name             text,
  ADD COLUMN IF NOT EXISTS display_name           text,
  ADD COLUMN IF NOT EXISTS contract_award_number  text,
  ADD COLUMN IF NOT EXISTS fein                   text,
  -- white-label branding
  ADD COLUMN IF NOT EXISTS primary_color_hex      text,
  ADD COLUMN IF NOT EXISTS accent_color_hex       text,
  ADD COLUMN IF NOT EXISTS logo_url               text,
  -- enforcement posture (soft-cap doctrine: guidance first, walls only for
  -- the org's own conduct). Defaults match production.
  ADD COLUMN IF NOT EXISTS enforcement_role             text DEFAULT 'soft'::text,
  ADD COLUMN IF NOT EXISTS enforcement_training         text DEFAULT 'warn'::text,
  ADD COLUMN IF NOT EXISTS enforcement_person_specific  text DEFAULT 'warn'::text;

COMMENT ON COLUMN public.organizations.legal_name            IS 'Legal entity name as it appears on the DSPD contract (distinct from display name).';
COMMENT ON COLUMN public.organizations.display_name          IS 'Name shown in the app header / white-label surfaces.';
COMMENT ON COLUMN public.organizations.contract_award_number IS 'DHHS/DSPD contract award number.';
COMMENT ON COLUMN public.organizations.fein                  IS 'Federal Employer Identification Number.';
COMMENT ON COLUMN public.organizations.primary_color_hex     IS 'White-label primary brand color: six hex characters, uppercase, NO leading # (the app strips it on save, e.g. 0F2A4B).';
COMMENT ON COLUMN public.organizations.accent_color_hex      IS 'White-label accent brand color: six hex characters, uppercase, NO leading # (the app strips it on save).';
COMMENT ON COLUMN public.organizations.logo_url              IS 'White-label logo URL.';
COMMENT ON COLUMN public.organizations.enforcement_role      IS 'Role-permission enforcement (app ENFORCE_ROLE_LEVELS, stored verbatim): loose | soft (default) | strict.';
COMMENT ON COLUMN public.organizations.enforcement_training  IS 'Training-compliance enforcement at shift/clock-in time (app ENFORCE_TRAIN_LEVELS, stored verbatim): warn (default) | block.';
COMMENT ON COLUMN public.organizations.enforcement_person_specific IS 'Person-specific-training enforcement at shift/clock-in time (app ENFORCE_TRAIN_LEVELS, stored verbatim): warn (default) | block.';


-- ── Verification (single statement — the SQL editor shows only the last result) ──
-- Every expected column present with production's type and default. The total
-- is reported for information only, NOT asserted: production reads 27, while a
-- fresh install from the committed base schema reads 30 — the base schema
-- carries 18 columns against production's 15 pre-drift columns, i.e. three
-- committed columns production does not have. That reverse drift is out of
-- scope here and is filed as a follow-up to reconcile before Item 4 RLS.
WITH expected(column_name, data_type, column_default) AS (VALUES
  ('legal_name',                  'text', NULL),
  ('display_name',                'text', NULL),
  ('contract_award_number',       'text', NULL),
  ('fein',                        'text', NULL),
  ('primary_color_hex',           'text', NULL),
  ('accent_color_hex',            'text', NULL),
  ('logo_url',                    'text', NULL),
  ('enforcement_role',            'text', '''soft''::text'),
  ('enforcement_training',        'text', '''warn''::text'),
  ('enforcement_person_specific', 'text', '''warn''::text')
)
SELECT e.column_name AS what,
       CASE
         WHEN c.column_name IS NULL THEN 'MISSING'
         WHEN c.data_type <> e.data_type THEN 'WRONG TYPE: ' || c.data_type
         WHEN c.column_default IS DISTINCT FROM e.column_default THEN 'WRONG DEFAULT: ' || coalesce(c.column_default, 'null')
         ELSE 'ok'
       END AS result
FROM expected e
LEFT JOIN information_schema.columns c
  ON c.table_schema = 'public' AND c.table_name = 'organizations' AND c.column_name = e.column_name
UNION ALL
SELECT 'organizations column count (info: 27 on production, 30 on a fresh install)', count(*)::text
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'organizations'
ORDER BY what;
-- Expect: ten 'ok' rows. The count line is informational (see note above).
