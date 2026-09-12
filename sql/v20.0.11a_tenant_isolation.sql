-- ============================================================================
-- Provly v20.0.11a — TENANT ISOLATION HOTFIX (found by Item 4 PR (b) discovery)
-- Run in the Supabase SQL editor (production). Additive and idempotent.
--
-- Finding (Sep 11 2026, pg_policies inventory): seven tables carried a second
-- policy of USING (true) for authenticated. Permissive policies OR together,
-- so `true` won and every signed-in user of ANY organization could read —
-- and on most of them write — every organization's rows:
--   training_decks, training_deck_service_codes, staff_deck_completions,
--   service_delivery_contexts, service_delivery_context_members,
--   generated_documents (all commands); training_topic_definitions (read);
--   waitlist (read by any user, insert by anonymous).
-- r1 (Greptile r1, Sep 11): verification asserts exact policy shape; DDL unchanged.
-- Production counts (Sep 11): no table holds shared rows (org_id IS NULL = 0
-- everywhere), so the fix is straight org scoping. No app change: the app
-- only ever displayed the caller's own org; other orgs' rows were reachable,
-- not shown. Badge stays v20.0.11 (SQL-only).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Drop every USING (true) policy on the affected tables
-- ─────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "td_all"                                     ON public.training_decks;
DROP POLICY IF EXISTS "tdsc_all"                                   ON public.training_deck_service_codes;
DROP POLICY IF EXISTS "sdc_all"                                    ON public.staff_deck_completions;
DROP POLICY IF EXISTS "sdc_all"                                    ON public.service_delivery_contexts;
DROP POLICY IF EXISTS "sdcm_all"                                   ON public.service_delivery_context_members;
DROP POLICY IF EXISTS "gd_all"                                     ON public.generated_documents;
DROP POLICY IF EXISTS "Allow authenticated users to read training topics" ON public.training_topic_definitions;
DROP POLICY IF EXISTS "Only authenticated users can read"          ON public.waitlist;
DROP POLICY IF EXISTS "Allow anonymous inserts"                    ON public.waitlist;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Org-scoped replacements where no org-scoped policy existed
--    (service_delivery_contexts / _members keep "Contexts/Members visible to
--    org"; training_topic_definitions keeps "ttd_isolation" — all org-scoped.)
--    (SELECT org_id()) so Postgres evaluates the helper once per statement.
-- ─────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "training_decks_org" ON public.training_decks;
CREATE POLICY "training_decks_org" ON public.training_decks
  FOR ALL TO authenticated
  USING      (org_id = (SELECT public.org_id()))
  WITH CHECK (org_id = (SELECT public.org_id()));

DROP POLICY IF EXISTS "staff_deck_completions_org" ON public.staff_deck_completions;
CREATE POLICY "staff_deck_completions_org" ON public.staff_deck_completions
  FOR ALL TO authenticated
  USING      (org_id = (SELECT public.org_id()))
  WITH CHECK (org_id = (SELECT public.org_id()));

DROP POLICY IF EXISTS "generated_documents_org" ON public.generated_documents;
CREATE POLICY "generated_documents_org" ON public.generated_documents
  FOR ALL TO authenticated
  USING      (org_id = (SELECT public.org_id()))
  WITH CHECK (org_id = (SELECT public.org_id()));

-- training_deck_service_codes has no org_id: scope it through its deck. The
-- table was created outside the migration journal, so the FK column name is
-- read from the catalog rather than assumed; a missing FK fails LOUDLY.
DO $$
DECLARE
  v_col text;
BEGIN
  SELECT a.attname INTO v_col
  FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
  WHERE c.conrelid = 'public.training_deck_service_codes'::regclass
    AND c.contype  = 'f'
    AND c.confrelid = 'public.training_decks'::regclass
  LIMIT 1;
  IF v_col IS NULL THEN
    RAISE EXCEPTION 'training_deck_service_codes has no foreign key to training_decks — cannot scope it; add the FK first';
  END IF;
  EXECUTE 'DROP POLICY IF EXISTS "training_deck_service_codes_org" ON public.training_deck_service_codes';
  EXECUTE format($p$
    CREATE POLICY "training_deck_service_codes_org" ON public.training_deck_service_codes
      FOR ALL TO authenticated
      USING (EXISTS (SELECT 1 FROM public.training_decks d
                     WHERE d.id = training_deck_service_codes.%1$I
                       AND d.org_id = (SELECT public.org_id())))
      WITH CHECK (EXISTS (SELECT 1 FROM public.training_decks d
                          WHERE d.id = training_deck_service_codes.%1$I
                            AND d.org_id = (SELECT public.org_id())))
  $p$, v_col);
END $$;

-- waitlist: the landing page no longer has a waitlist form (v20.0.10d). No
-- policy = no access for anon/authenticated; service role only.
ALTER TABLE public.waitlist ENABLE ROW LEVEL SECURITY;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification — one statement
-- ─────────────────────────────────────────────────────────────────────────────
SELECT check_name, value, want FROM (
  SELECT 1 AS ord, 'USING (true) policies left on the seven tables' AS check_name,
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public'
             AND tablename IN ('training_decks','training_deck_service_codes','staff_deck_completions',
                               'service_delivery_contexts','service_delivery_context_members',
                               'generated_documents','training_topic_definitions','waitlist')
             AND (qual = 'true' OR with_check = 'true')) AS value,
         '0' AS want
  UNION ALL
  SELECT 2, 'USING (true) SELECT policies anywhere in public (service_code_definitions is the one intended)',
         (SELECT coalesce(string_agg(tablename || '.' || policyname, '; '), 'none') FROM pg_policies
           WHERE schemaname = 'public' AND cmd IN ('SELECT','ALL') AND qual = 'true'),
         'service_code_definitions.Allow authenticated users to read service codes'
  UNION ALL
  -- v20.0.11a r1 (Greptile r1): assert the exact policy SHAPE, not a mention of org_id():
  -- (table, policy name, command ALL, applies-to role, USING scoped, WITH CHECK scoped).
  SELECT 3, 'seven org-scoped policies with the expected name / cmd=ALL / role / USING / WITH CHECK',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.cmd = 'ALL'
             AND (p.tablename, p.policyname, p.roles::text) IN (
                   ('training_decks',                   'training_decks_org',                  '{authenticated}'),
                   ('staff_deck_completions',           'staff_deck_completions_org',          '{authenticated}'),
                   ('generated_documents',              'generated_documents_org',             '{authenticated}'),
                   ('training_deck_service_codes',      'training_deck_service_codes_org',     '{authenticated}'),
                   ('service_delivery_contexts',        'Contexts visible to org',             '{public}'),
                   ('service_delivery_context_members', 'Members visible to org',              '{public}'),
                   ('training_topic_definitions',       'ttd_isolation',                       '{authenticated}'))
             AND p.qual       LIKE '%org_id()%'
             AND p.with_check LIKE '%org_id()%'
             AND (p.tablename <> 'training_deck_service_codes'
                  OR (p.qual LIKE '%training_decks%' AND p.with_check LIKE '%training_decks%'))),
         '7'
  UNION ALL
  SELECT 31, 'write-capable policies on the seven tables with NO WITH CHECK (silent write hole)',
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public' AND cmd IN ('INSERT','UPDATE','ALL')
             AND tablename IN ('training_decks','training_deck_service_codes','staff_deck_completions',
                               'service_delivery_contexts','service_delivery_context_members',
                               'generated_documents','training_topic_definitions')
             AND with_check IS NULL),
         '0'
  UNION ALL
  SELECT 32, 'policies on the seven tables that are NOT the expected one (stragglers)',
         (SELECT coalesce(string_agg(tablename || '.' || policyname, '; '), 'none') FROM pg_policies
           WHERE schemaname = 'public'
             AND tablename IN ('training_decks','training_deck_service_codes','staff_deck_completions',
                               'service_delivery_contexts','service_delivery_context_members',
                               'generated_documents','training_topic_definitions')
             AND policyname NOT IN ('training_decks_org','staff_deck_completions_org','generated_documents_org',
                                    'training_deck_service_codes_org','Contexts visible to org',
                                    'Members visible to org','ttd_isolation')),
         'none'
  UNION ALL
  SELECT 4, 'waitlist policies',
         (SELECT count(*)::text FROM pg_policies WHERE schemaname = 'public' AND tablename = 'waitlist'),
         '0'
  UNION ALL
  SELECT 5, 'deck-service-code policy present (scoped via deck FK)',
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'training_deck_service_codes'
             AND policyname = 'training_deck_service_codes_org'),
         '1'
  UNION ALL
  SELECT 6, '(info) rows visible to YOUR org now: decks / contexts / members / topics',
         (SELECT (SELECT count(*) FROM public.training_decks)::text || ' / ' ||
                 (SELECT count(*) FROM public.service_delivery_contexts)::text || ' / ' ||
                 (SELECT count(*) FROM public.service_delivery_context_members)::text || ' / ' ||
                 (SELECT count(*) FROM public.training_topic_definitions)::text),
         'read (SQL editor runs as postgres and bypasses RLS — expect the full counts here; the app will see only its org)'
) v ORDER BY ord;
