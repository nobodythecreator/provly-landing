-- ============================================================================
-- Provly v20.0.12 — Item 4 PR (b): READ POLICIES
-- Run in the Supabase SQL editor (production) BEFORE the app ships.
-- Additive and idempotent: re-running yields the same policies, views, trigger.
--
-- Design: docs/item4-rls-design.md v1.2 (§3.1 amended by B1; §4 table→class
-- sheet = B2; staff_directory_v = B3; schedule-edge window = B4; nav = B5).
-- Decisions locked Sep 16 2026:
--   B1  Tenant guard = org_id claim AND live membership. Every tenant table gets
--       ONE RESTRICTIVE FOR ALL policy:
--         org_id = (SELECT org_id()) AND (SELECT member_role()) IS NOT NULL
--       so a terminated login (org_members row deleted by the staff trigger)
--       loses database access instantly, JWT claim or not.
--   B2  Reads by tier: manage / operate / deliver (deliver via can_see_person,
--       own rows on staff-scoped tables, none on money). Every pre-existing
--       permissive SELECT and ALL policy is dropped — a surviving one would OR
--       straight past the tier policies (the v20.0.11a lesson). Writes stay
--       org-wide until PR (c): existing per-command write policies are kept;
--       tables whose writes lived only in a dropped ALL policy get equivalent
--       per-command org-wide write policies (<t>_insert_org / _update_org /
--       _delete_org).
--   B3  staff_directory_v — id, name, role of active staff, readable by every
--       tiered member; base `staff` stays own-row for deliver.
--   B4  Schedule → sight edge: a shift for a deliver-tier staff with no sight of
--       the person opens a time-boxed edge (shift date → +7 days, origin =
--       'schedule'); later shifts extend it; manual edges are never touched.
--   R3  person_service_authorizations base read = manage only;
--       person_service_authorizations_v masks rate_per_unit below manage.
-- Cleanup carried in (b): org_members loses its moot write policies (the app
-- has no privileges there since v20.0.11); staff_assignments loses the
-- person_staff_assignments_* duplicate set left by the v20.0.4d rename.
-- Out of scope (unchanged policies): org_partnerships, person_collaborations,
-- collaboration_messages, person_transfers — they only gain the membership
-- half of the guard (no org_id column). service_code_definitions unchanged.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Pre-flight — refuse to run while any live login would be locked out by B1
--    (Sep 16: the one straggler, siamon@, was bound by hand before this file.)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_claim_orphans int;
  v_staff_orphans int;
BEGIN
  SELECT count(*) INTO v_claim_orphans
  FROM auth.users u
  WHERE (u.raw_app_meta_data->>'org_id') IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.org_members m
                    WHERE m.user_id = u.id
                      AND m.org_id = (u.raw_app_meta_data->>'org_id')::uuid);
  SELECT count(*) INTO v_staff_orphans
  FROM public.staff s
  WHERE s.user_id IS NOT NULL AND s.is_active AND s.termination_date IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.org_members m
                    WHERE m.user_id = s.user_id AND m.org_id = s.org_id);
  IF v_claim_orphans > 0 OR v_staff_orphans > 0 THEN
    RAISE EXCEPTION 'v20.0.12 refused: % auth user(s) carry an org_id claim without a membership row and % linked active staff lack one. Bind or terminate them first (see the straggler read in the PR description), then re-run.',
      v_claim_orphans, v_staff_orphans;
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Helpers — sight of a person for a GIVEN staff row (trigger needs this);
--    can_see_person(p) now delegates to it for the caller. Grants preserved by
--    CREATE OR REPLACE.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.staff_sees_person(p_staff_id uuid, p_org_id uuid, p_person_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_staff_id IS NOT NULL AND p_org_id IS NOT NULL AND p_person_id IS NOT NULL AND (
    EXISTS (                                            -- open person edge
      SELECT 1 FROM public.staff_assignments sa
      WHERE sa.staff_id  = p_staff_id
        AND sa.org_id    = p_org_id
        AND sa.person_id = p_person_id
        AND (sa.end_date IS NULL OR sa.end_date >= CURRENT_DATE))
    OR EXISTS (                                         -- open site edge + open placement
      SELECT 1
      FROM public.staff_assignments sa
      JOIN public.person_placements pp
        ON pp.site_id = sa.site_id AND pp.org_id = sa.org_id
      WHERE sa.staff_id = p_staff_id
        AND sa.org_id   = p_org_id
        AND sa.site_id IS NOT NULL
        AND (sa.end_date IS NULL OR sa.end_date >= CURRENT_DATE)
        AND pp.person_id = p_person_id
        AND (pp.end_date IS NULL OR pp.end_date >= CURRENT_DATE))
  )
$$;
-- Reached only from can_see_person() and the shifts trigger (both SECURITY
-- DEFINER, so the call runs as the owner); app roles cannot probe another
-- staff member's sight with it.
REVOKE ALL ON FUNCTION public.staff_sees_person(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_sees_person(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.can_see_person(p_person_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE public.access_tier()
    WHEN 'manage'  THEN true
    WHEN 'operate' THEN true
    WHEN 'deliver' THEN public.staff_sees_person(public.my_staff_id(), public.org_id(), p_person_id)
    ELSE false
  END
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. B4 — staff_assignments.origin: 'manual' (Assignments UI / RPC) or
--    'schedule' (opened by the shifts trigger). The trigger only ever
--    extends its own edges.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.staff_assignments
  ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'manual';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.staff_assignments'::regclass
                   AND conname  = 'staff_assignments_origin_check') THEN
    ALTER TABLE public.staff_assignments
      ADD CONSTRAINT staff_assignments_origin_check CHECK (origin IN ('manual', 'schedule'));
  END IF;
END $$;
COMMENT ON COLUMN public.staff_assignments.origin IS
  'v20.0.12 B4 — manual (Assignments UI/RPC) | schedule (time-boxed sight edge opened by trg_shift_open_sight_edge)';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Policy applier — one call per table. For the table it:
--      • enables RLS;
--      • drops every PERMISSIVE SELECT / ALL policy (they would OR past the
--        tier read), the two policies this file owns, and — when p_write =
--        'none' — every write policy;
--      • creates <t>_tenant_guard  (RESTRICTIVE, FOR ALL, TO authenticated);
--      • creates <t>_read_tier     (PERMISSIVE, FOR SELECT) from p_read;
--      • if the table's writes lived in a dropped ALL policy (or were
--        recreated by an earlier run), recreates per-command org-wide write
--        policies for the commands that have no permissive policy left.
--    Maintenance helper, not callable by app roles. Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.provly_v12_apply(
  p_table text,
  p_read  text,                       -- SELECT predicate; NULL = no read policy (RPC-only table)
  p_guard text DEFAULT NULL,          -- RESTRICTIVE predicate; NULL = default org_id + membership guard
  p_write text DEFAULT 'keep'         -- 'keep' | 'none' | a predicate for recreated org-wide write policies
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_guard     text := coalesce(p_guard,
                 'org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL');
  v_write     text := CASE WHEN p_write IN ('keep', 'none') OR p_write IS NULL
                           THEN 'org_id = (SELECT public.org_id())' ELSE p_write END;
  v_recreate  boolean := false;
  v_pol       record;
  v_cmd       text;
BEGIN
  IF to_regclass('public.' || p_table) IS NULL THEN
    RAISE EXCEPTION 'v20.0.12: table public.% does not exist on this database', p_table;
  END IF;
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', p_table);

  FOR v_pol IN
    SELECT policyname, cmd, permissive
    FROM pg_policies WHERE schemaname = 'public' AND tablename = p_table
  LOOP
    IF v_pol.permissive = 'PERMISSIVE' AND v_pol.cmd = 'ALL' THEN
      v_recreate := true;                          -- writes lived in an ALL policy
    END IF;
    IF v_pol.policyname IN (p_table || '_insert_org', p_table || '_update_org', p_table || '_delete_org') THEN
      v_recreate := true;                          -- earlier run of this file
    END IF;
    IF (v_pol.permissive = 'PERMISSIVE' AND v_pol.cmd IN ('SELECT', 'ALL'))
       OR v_pol.policyname IN (p_table || '_tenant_guard', p_table || '_read_tier',
                               p_table || '_insert_org', p_table || '_update_org', p_table || '_delete_org')
       OR (p_write = 'none' AND v_pol.cmd IN ('INSERT', 'UPDATE', 'DELETE'))
    THEN
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_pol.policyname, p_table);
    END IF;
  END LOOP;

  EXECUTE format(
    'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (%s) WITH CHECK (%s)',
    p_table || '_tenant_guard', p_table, v_guard, v_guard);

  IF p_read IS NOT NULL THEN
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS PERMISSIVE FOR SELECT TO authenticated USING (%s)',
      p_table || '_read_tier', p_table, p_read);
  END IF;

  IF v_recreate AND p_write IS DISTINCT FROM 'none' THEN
    FOREACH v_cmd IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_policies
                     WHERE schemaname = 'public' AND tablename = p_table
                       AND permissive = 'PERMISSIVE' AND cmd = v_cmd) THEN
        EXECUTE format(
          CASE v_cmd
            WHEN 'INSERT' THEN 'CREATE POLICY %1$I ON public.%2$I AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (%3$s)'
            WHEN 'UPDATE' THEN 'CREATE POLICY %1$I ON public.%2$I AS PERMISSIVE FOR UPDATE TO authenticated USING (%3$s) WITH CHECK (%3$s)'
            ELSE               'CREATE POLICY %1$I ON public.%2$I AS PERMISSIVE FOR DELETE TO authenticated USING (%3$s)'
          END,
          p_table || '_' || lower(v_cmd) || '_org', p_table, v_write);
      END IF;
    END LOOP;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.provly_v12_apply(text, text, text, text) FROM PUBLIC, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. B2 — per-table read policies. Predicates:
--      MANAGE   = manage only              MO       = manage or operate
--      ANY_TIER = any tiered member        PERSON   = MO or can_see_person(person_id)
--      OWN      = MO or staff_id = my_staff_id()
--    (SELECT fn()) forms evaluate once per statement; can_see_person(col) is
--    per row and only reached by deliver-tier callers (manage/operate short-
--    circuit on the first term).
-- ─────────────────────────────────────────────────────────────────────────────

-- Person-scoped (16) ---------------------------------------------------------
SELECT public.provly_v12_apply('persons',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(id)$q$);
SELECT public.provly_v12_apply('person_placements',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('service_notes',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('evv_sessions',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('incidents',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('medications',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('medication_logs',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('medication_administrations',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('pcsp_goals',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('pcsp_progress_notes',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('support_strategies',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('documents',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('quarterly_summaries',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('belongings_inventory',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('day_activity_absence_days',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);
SELECT public.provly_v12_apply('service_delivery_context_members',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR public.can_see_person(person_id)$q$);

-- Person-scoped, indirect (2) ------------------------------------------------
-- evv_edit_log keys on the session; the session's own RLS is the sight rule.
SELECT public.provly_v12_apply('evv_edit_log',
  $q$(SELECT public.access_tier()) IN ('manage','operate')
     OR EXISTS (SELECT 1 FROM public.evv_sessions s
                WHERE s.id = evv_edit_log.session_id
                  AND s.org_id = evv_edit_log.org_id
                  AND public.can_see_person(s.person_id))$q$);
-- compliance_alerts is polymorphic (related_entity_type/id); the app never
-- reads it today. deliver: person alerts they can see, staff alerts of their own.
SELECT public.provly_v12_apply('compliance_alerts',
  $q$(SELECT public.access_tier()) IN ('manage','operate')
     OR (related_entity_type = 'person' AND related_entity_id IS NOT NULL
         AND public.can_see_person(related_entity_id))
     OR (related_entity_type = 'staff'  AND related_entity_id = (SELECT public.my_staff_id()))$q$);

-- Authorizations (R3): base table manage only; everyone else reads the view --
SELECT public.provly_v12_apply('person_service_authorizations',
  $q$(SELECT public.access_tier()) = 'manage'$q$);

-- Staff-scoped (4) -----------------------------------------------------------
SELECT public.provly_v12_apply('shifts',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR staff_id = (SELECT public.my_staff_id())$q$);
SELECT public.provly_v12_apply('staff_trainings',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR staff_id = (SELECT public.my_staff_id())$q$);
SELECT public.provly_v12_apply('staff_deck_completions',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR staff_id = (SELECT public.my_staff_id())$q$);
SELECT public.provly_v12_apply('messages',
  $q$(SELECT public.access_tier()) IN ('manage','operate')
     OR sender_staff_id    = (SELECT public.my_staff_id())
     OR recipient_staff_id = (SELECT public.my_staff_id())$q$);

-- Money (6): manage only -----------------------------------------------------
SELECT public.provly_v12_apply('claim_submissions',   $q$(SELECT public.access_tier()) = 'manage'$q$);
SELECT public.provly_v12_apply('payments',            $q$(SELECT public.access_tier()) = 'manage'$q$);
SELECT public.provly_v12_apply('payment_line_items',  $q$(SELECT public.access_tier()) = 'manage'$q$);
SELECT public.provly_v12_apply('contracts',           $q$(SELECT public.access_tier()) = 'manage'$q$);
SELECT public.provly_v12_apply('billing_claims',      $q$(SELECT public.access_tier()) = 'manage'$q$);
SELECT public.provly_v12_apply('subscription_events', $q$(SELECT public.access_tier()) = 'manage'$q$);

-- Org structure (8) ----------------------------------------------------------
SELECT public.provly_v12_apply('staff',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR id = (SELECT public.my_staff_id())$q$);
-- v20.0.4d rename left the old policy set behind: retire it, then apply.
DROP POLICY IF EXISTS "person_staff_assignments_select" ON public.staff_assignments;
DROP POLICY IF EXISTS "person_staff_assignments_insert" ON public.staff_assignments;
DROP POLICY IF EXISTS "person_staff_assignments_update" ON public.staff_assignments;
DROP POLICY IF EXISTS "person_staff_assignments_delete" ON public.staff_assignments;
SELECT public.provly_v12_apply('staff_assignments',
  $q$(SELECT public.access_tier()) IN ('manage','operate') OR staff_id = (SELECT public.my_staff_id())$q$);
-- deliver: sites they hold an open site edge to, or where a person they can see is placed
SELECT public.provly_v12_apply('org_sites',
  $q$(SELECT public.access_tier()) IN ('manage','operate')
     OR EXISTS (SELECT 1 FROM public.staff_assignments sa
                WHERE sa.staff_id = (SELECT public.my_staff_id())
                  AND sa.site_id  = org_sites.id
                  AND sa.org_id   = org_sites.org_id
                  AND (sa.end_date IS NULL OR sa.end_date >= CURRENT_DATE))
     OR EXISTS (SELECT 1 FROM public.person_placements pp
                WHERE pp.site_id = org_sites.id
                  AND pp.org_id  = org_sites.org_id
                  AND (pp.end_date IS NULL OR pp.end_date >= CURRENT_DATE)
                  AND public.can_see_person(pp.person_id))$q$);
-- deliver: the unit on their own staff row
SELECT public.provly_v12_apply('org_units',
  $q$(SELECT public.access_tier()) IN ('manage','operate')
     OR id IN (SELECT s.org_unit_id FROM public.staff s WHERE s.id = (SELECT public.my_staff_id()))$q$);
-- deliver: contexts with at least one currently-visible member
SELECT public.provly_v12_apply('service_delivery_contexts',
  $q$(SELECT public.access_tier()) IN ('manage','operate')
     OR EXISTS (SELECT 1 FROM public.service_delivery_context_members m
                WHERE m.context_id = service_delivery_contexts.id
                  AND m.org_id     = service_delivery_contexts.org_id
                  AND coalesce(m.is_active, true)
                  AND (m.end_date IS NULL OR m.end_date >= CURRENT_DATE)
                  AND public.can_see_person(m.person_id))$q$);
-- nothing to scope a deliver read on (or a rate column): office tiers only
SELECT public.provly_v12_apply('org_service_codes',    $q$(SELECT public.access_tier()) IN ('manage','operate')$q$);
SELECT public.provly_v12_apply('generated_documents',  $q$(SELECT public.access_tier()) IN ('manage','operate')$q$);
SELECT public.provly_v12_apply('evacuation_drills',    $q$(SELECT public.access_tier()) IN ('manage','operate')$q$);

-- Training (3): every tiered member -------------------------------------------
SELECT public.provly_v12_apply('training_decks',            $q$(SELECT public.access_tier()) IS NOT NULL$q$);
SELECT public.provly_v12_apply('training_topic_definitions', $q$(SELECT public.access_tier()) IS NOT NULL$q$);
-- no org_id: tenant-closed through its deck (FK column deck_id, per the Sep 16 inventory)
SELECT public.provly_v12_apply('training_deck_service_codes',
  $q$(SELECT public.access_tier()) IS NOT NULL$q$,
  $q$EXISTS (SELECT 1 FROM public.training_decks d
             WHERE d.id = training_deck_service_codes.deck_id
               AND d.org_id = (SELECT public.org_id()))
     AND (SELECT public.member_role()) IS NOT NULL$q$,
  $q$EXISTS (SELECT 1 FROM public.training_decks d
             WHERE d.id = training_deck_service_codes.deck_id
               AND d.org_id = (SELECT public.org_id()))$q$);

-- Org row / membership / audit -----------------------------------------------
SELECT public.provly_v12_apply('organizations',
  $q$(SELECT public.access_tier()) IS NOT NULL$q$,
  $q$id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL$q$);
-- org_members: derived from staff by trigger; the app has no write privileges
-- (v20.0.11) — the write policies were moot, and now they are gone.
SELECT public.provly_v12_apply('org_members',
  $q$(SELECT public.access_tier()) = 'manage' OR user_id = auth.uid()$q$,
  NULL, 'none');
SELECT public.provly_v12_apply('audit_log', $q$(SELECT public.access_tier()) = 'manage'$q$);

-- RPC-only: guard, no read policy (0 permissive policies = deny) ------------
SELECT public.provly_v12_apply('invites', NULL);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Cross-org tables (out of Item 4 scope): existing policies untouched; they
--    gain only the membership half of the B1 guard — no org_id column to bind.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['org_partnerships', 'person_collaborations', 'collaboration_messages', 'person_transfers'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_member_guard', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING ((SELECT public.member_role()) IS NOT NULL) WITH CHECK ((SELECT public.member_role()) IS NOT NULL)',
      t || '_member_guard', t);
  END LOOP;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Reference — compliance_deadline_definitions (design §4: any authenticated).
--    The only widening in this file; the table is DSPD's own deadline list.
--    service_code_definitions keeps its existing read-all policy. waitlist stays
--    at 0 policies (service role only, v20.0.11a).
-- ─────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "compliance_deadline_definitions_read_all" ON public.compliance_deadline_definitions;
CREATE POLICY "compliance_deadline_definitions_read_all" ON public.compliance_deadline_definitions
  FOR SELECT TO authenticated USING (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. R3 — person_service_authorizations_v: same helpers as the policies;
--    rate_per_unit is NULL below manage. security_barrier so the planner cannot
--    hoist a caller's predicate above the guard; the view runs with its owner's
--    privileges, so the WHERE clause IS the tenant + membership + sight guard.
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.person_service_authorizations_v;
CREATE VIEW public.person_service_authorizations_v
WITH (security_barrier = true, security_invoker = false) AS
SELECT a.id, a.org_id, a.person_id, a.service_code_id,
       a.authorized_units, a.used_units, a.start_date, a.end_date, a.status,
       a.upi_approved_at,
       CASE WHEN public.access_tier() = 'manage' THEN a.rate_per_unit ELSE NULL END AS rate_per_unit,
       a.notes, a.created_at, a.updated_at
FROM public.person_service_authorizations a
WHERE a.org_id = public.org_id()
  AND public.member_role() IS NOT NULL
  AND public.can_see_person(a.person_id);
REVOKE ALL ON public.person_service_authorizations_v FROM PUBLIC, anon;
GRANT SELECT ON public.person_service_authorizations_v TO authenticated, service_role;
COMMENT ON VIEW public.person_service_authorizations_v IS
  'v20.0.12 R3 — read view of person_service_authorizations; rate_per_unit masked below the manage tier; sight via can_see_person. App read sites use this; the Add Auth write path stays on the base table.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. B3 — staff_directory_v: id, name, role of ACTIVE staff in the caller's
--    org, readable by every tiered member. Nothing else from the staff row
--    crosses it. Base table read stays own-row for the deliver tier.
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.staff_directory_v;
CREATE VIEW public.staff_directory_v
WITH (security_barrier = true, security_invoker = false) AS
SELECT s.id, s.org_id, s.first_name, s.last_name, s.role
FROM public.staff s
WHERE s.org_id = public.org_id()
  AND public.member_role() IS NOT NULL
  AND public.access_tier() IS NOT NULL
  AND s.is_active;
REVOKE ALL ON public.staff_directory_v FROM PUBLIC, anon;
GRANT SELECT ON public.staff_directory_v TO authenticated, service_role;
COMMENT ON VIEW public.staff_directory_v IS
  'v20.0.12 B3 — names and roles of active staff for record display (notes, EVV, incidents, shifts); no contact, HR, pay or W-9 fields. App switches to it in PR (c).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. B4 / R4 — schedule → sight edge. AFTER INSERT (or reassignment /
--    reschedule) on shifts: if the shift's staff is deliver tier and has no
--    sight of the person, open a schedule-origin person edge from the shift
--    date through +7 days; a later shift for the same pair extends it. Manual
--    edges and placements already grant sight → nothing happens. Schedule
--    edges carry service_code_id NULL so they never collide with the
--    (org, person, staff, service_code) uniqueness of manual edges.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_shift_open_sight_edge()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role    public.user_role;
  v_start   date;
  v_end     date;
  v_edge_id uuid;
BEGIN
  IF NEW.staff_id IS NULL OR NEW.person_id IS NULL OR NEW.org_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT s.role INTO v_role
  FROM public.staff s
  WHERE s.id = NEW.staff_id AND s.org_id = NEW.org_id;
  IF v_role IS NULL OR public.role_tier(v_role) IS DISTINCT FROM 'deliver' THEN
    RETURN NEW;                                   -- office tiers see the org already
  END IF;

  v_start := coalesce(NEW.scheduled_date, CURRENT_DATE);
  v_end   := v_start + 7;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.staff_id::text || ':' || NEW.person_id::text));

  -- 1. our own edge for this pair: extend it (never a manual edge)
  SELECT sa.id INTO v_edge_id
  FROM public.staff_assignments sa
  WHERE sa.staff_id  = NEW.staff_id
    AND sa.org_id    = NEW.org_id
    AND sa.person_id = NEW.person_id
    AND sa.origin    = 'schedule'
  ORDER BY sa.end_date DESC NULLS FIRST
  LIMIT 1;
  IF v_edge_id IS NOT NULL THEN
    UPDATE public.staff_assignments
    SET start_date = LEAST(start_date, v_start),
        end_date   = CASE WHEN end_date IS NULL THEN NULL ELSE GREATEST(end_date, v_end) END
    WHERE id = v_edge_id;
    RETURN NEW;
  END IF;

  -- 2. sight already granted by a manual edge or a placement: nothing to do
  IF public.staff_sees_person(NEW.staff_id, NEW.org_id, NEW.person_id) THEN
    RETURN NEW;
  END IF;

  -- 3. open a time-boxed edge
  INSERT INTO public.staff_assignments
    (org_id, staff_id, person_id, service_code_id, is_primary, start_date, end_date, origin)
  VALUES
    (NEW.org_id, NEW.staff_id, NEW.person_id, NULL, false, v_start, v_end, 'schedule');
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_shift_open_sight_edge() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS shifts_open_sight_edge ON public.shifts;
CREATE TRIGGER shifts_open_sight_edge
  AFTER INSERT OR UPDATE OF staff_id, person_id, scheduled_date ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.trg_shift_open_sight_edge();

-- Tell PostgREST about the two new views (Supabase also reloads on DDL).
NOTIFY pgrst, 'reload schema';

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification — one statement. Paste the whole result.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT check_name, value, want FROM (
  SELECT 1 AS ord, 'B1 pre-flight: auth users with an org_id claim but no org_members row' AS check_name,
         (SELECT count(*)::text FROM auth.users u
           WHERE (u.raw_app_meta_data->>'org_id') IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM public.org_members m
                             WHERE m.user_id = u.id AND m.org_id = (u.raw_app_meta_data->>'org_id')::uuid)) AS value,
         '0' AS want
  UNION ALL
  SELECT 2, 'B1 pre-flight: linked active staff without an org_members row',
         (SELECT count(*)::text FROM public.staff s
           WHERE s.user_id IS NOT NULL AND s.is_active AND s.termination_date IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.org_members m WHERE m.user_id = s.user_id AND m.org_id = s.org_id)),
         '0'
  UNION ALL
  SELECT 3, 'tenant guards: RESTRICTIVE / ALL / {authenticated} / USING + WITH CHECK both bind org_id() and member_role()',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.policyname = p.tablename || '_tenant_guard'
             AND p.permissive = 'RESTRICTIVE' AND p.cmd = 'ALL' AND p.roles::text = '{authenticated}'
             AND p.qual       LIKE '%org_id()%' AND p.qual       LIKE '%member_role()%'
             AND p.with_check LIKE '%org_id()%' AND p.with_check LIKE '%member_role()%'),
         '44'
  UNION ALL
  SELECT 4, 'cross-org tables: RESTRICTIVE membership guard only (existing policies untouched)',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.policyname = p.tablename || '_member_guard'
             AND p.permissive = 'RESTRICTIVE' AND p.cmd = 'ALL' AND p.roles::text = '{authenticated}'
             AND p.tablename IN ('org_partnerships','person_collaborations','collaboration_messages','person_transfers')),
         '4'
  UNION ALL
  SELECT 5, 'public tables with NO restrictive guard at all (the three reference / service-role tables)',
         (SELECT coalesce(string_agg(t.tablename, '; ' ORDER BY t.tablename COLLATE "C"), 'none') FROM pg_tables t
           WHERE t.schemaname = 'public'
             AND NOT EXISTS (SELECT 1 FROM pg_policies p
                             WHERE p.schemaname = 'public' AND p.tablename = t.tablename AND p.permissive = 'RESTRICTIVE')),
         'compliance_deadline_definitions; service_code_definitions; waitlist'
  UNION ALL
  SELECT 6, 'tier read policies <t>_read_tier: PERMISSIVE / SELECT / {authenticated}',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.policyname = p.tablename || '_read_tier'
             AND p.permissive = 'PERMISSIVE' AND p.cmd = 'SELECT' AND p.roles::text = '{authenticated}'),
         '43'
  UNION ALL
  SELECT 7, 'tables with MORE than one permissive SELECT policy (a second one ORs past the tier)',
         (SELECT coalesce(string_agg(x.tablename, '; ' ORDER BY x.tablename COLLATE "C"), 'none') FROM (
            SELECT tablename FROM pg_policies
            WHERE schemaname = 'public' AND permissive = 'PERMISSIVE' AND cmd = 'SELECT'
            GROUP BY tablename HAVING count(*) > 1) x),
         'none'
  UNION ALL
  SELECT 8, 'permissive ALL policies left anywhere except the cross-org tables',
         (SELECT coalesce(string_agg(tablename || '.' || policyname, '; ' ORDER BY tablename COLLATE "C"), 'none') FROM pg_policies
           WHERE schemaname = 'public' AND permissive = 'PERMISSIVE' AND cmd = 'ALL'
             AND tablename NOT IN ('org_partnerships','person_collaborations','collaboration_messages','person_transfers')),
         'none'
  UNION ALL
  SELECT 9, 'USING (true) read policies anywhere in public (the two reference tables)',
         (SELECT coalesce(string_agg(tablename || '.' || policyname, '; ' ORDER BY tablename COLLATE "C"), 'none') FROM pg_policies
           WHERE schemaname = 'public' AND cmd IN ('SELECT','ALL') AND qual = 'true'),
         'compliance_deadline_definitions.compliance_deadline_definitions_read_all; service_code_definitions.Allow authenticated users to read service codes'
  UNION ALL
  SELECT 10, 'person_service_authorizations base read = manage only',
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'person_service_authorizations'
             AND policyname = 'person_service_authorizations_read_tier'
             AND qual LIKE '%access_tier()%' AND qual LIKE '%manage%' AND qual NOT LIKE '%operate%' AND qual NOT LIKE '%can_see_person%'),
         '1'
  UNION ALL
  SELECT 11, 'org_members write policies (must be 0 — membership is trigger/RPC written)',
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'org_members' AND cmd IN ('INSERT','UPDATE','DELETE','ALL')),
         '0'
  UNION ALL
  SELECT 12, 'person_staff_assignments_* policies left on staff_assignments (v20.0.4d rename residue)',
         (SELECT count(*)::text FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'staff_assignments' AND policyname LIKE 'person_staff_assignments%'),
         '0'
  UNION ALL
  SELECT 13, 'guarded tables with NO permissive INSERT policy (writes stay org-wide until PR c; these three take no app writes)',
         (SELECT coalesce(string_agg(t.tablename, '; ' ORDER BY t.tablename COLLATE "C"), 'none') FROM pg_tables t
           WHERE t.schemaname = 'public'
             AND EXISTS (SELECT 1 FROM pg_policies g WHERE g.schemaname = 'public' AND g.tablename = t.tablename AND g.policyname = t.tablename || '_tenant_guard')
             AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = t.tablename
                             AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('INSERT','ALL'))),
         'invites; org_members; subscription_events'
  UNION ALL
  SELECT 14, 'guarded tables with NO permissive UPDATE policy',
         (SELECT coalesce(string_agg(t.tablename, '; ' ORDER BY t.tablename COLLATE "C"), 'none') FROM pg_tables t
           WHERE t.schemaname = 'public'
             AND EXISTS (SELECT 1 FROM pg_policies g WHERE g.schemaname = 'public' AND g.tablename = t.tablename AND g.policyname = t.tablename || '_tenant_guard')
             AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = t.tablename
                             AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('UPDATE','ALL'))),
         'evv_edit_log; invites; org_members; subscription_events'
  UNION ALL
  SELECT 15, 'guarded tables with NO permissive DELETE policy',
         (SELECT coalesce(string_agg(t.tablename, '; ' ORDER BY t.tablename COLLATE "C"), 'none') FROM pg_tables t
           WHERE t.schemaname = 'public'
             AND EXISTS (SELECT 1 FROM pg_policies g WHERE g.schemaname = 'public' AND g.tablename = t.tablename AND g.policyname = t.tablename || '_tenant_guard')
             AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = t.tablename
                             AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('DELETE','ALL'))),
         'evv_edit_log; invites; org_members; organizations; subscription_events'
  UNION ALL
  SELECT 16, 'person_service_authorizations_v: security_barrier, rate masked below manage, sight via can_see_person, authenticated may SELECT',
         (SELECT count(*)::text FROM pg_views v
           JOIN pg_class c ON c.relname = v.viewname AND c.relnamespace = 'public'::regnamespace
           WHERE v.schemaname = 'public' AND v.viewname = 'person_service_authorizations_v'
             AND coalesce(array_to_string(c.reloptions, ','), '') LIKE '%security_barrier=true%'
             AND v.definition LIKE '%CASE%' AND v.definition LIKE '%manage%'
             AND v.definition LIKE '%can_see_person%' AND v.definition LIKE '%member_role()%'
             AND has_table_privilege('authenticated', 'public.person_service_authorizations_v', 'SELECT')
             AND NOT has_table_privilege('anon', 'public.person_service_authorizations_v', 'SELECT')),
         '1'
  UNION ALL
  SELECT 17, 'staff_directory_v: security_barrier, exactly id/org_id/first_name/last_name/role, active only, authenticated may SELECT',
         (SELECT count(*)::text FROM pg_views v
           JOIN pg_class c ON c.relname = v.viewname AND c.relnamespace = 'public'::regnamespace
           WHERE v.schemaname = 'public' AND v.viewname = 'staff_directory_v'
             AND coalesce(array_to_string(c.reloptions, ','), '') LIKE '%security_barrier=true%'
             AND v.definition LIKE '%is_active%' AND v.definition LIKE '%member_role()%'
             AND (SELECT string_agg(a.attname, ',' ORDER BY a.attnum) FROM pg_attribute a
                   WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) = 'id,org_id,first_name,last_name,role'
             AND has_table_privilege('authenticated', 'public.staff_directory_v', 'SELECT')
             AND NOT has_table_privilege('anon', 'public.staff_directory_v', 'SELECT')),
         '1'
  UNION ALL
  SELECT 18, 'helpers: staff_sees_person exists and can_see_person delegates to it',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'can_see_person'
             AND p.prosrc LIKE '%staff_sees_person%'
             AND EXISTS (SELECT 1 FROM pg_proc q WHERE q.pronamespace = 'public'::regnamespace AND q.proname = 'staff_sees_person')),
         '1'
  UNION ALL
  SELECT 19, 'B4: staff_assignments.origin column + CHECK (manual|schedule)',
         (SELECT count(*)::text FROM information_schema.columns c
           WHERE c.table_schema = 'public' AND c.table_name = 'staff_assignments' AND c.column_name = 'origin'
             AND c.column_default LIKE '%manual%'
             AND EXISTS (SELECT 1 FROM pg_constraint k
                         WHERE k.conrelid = 'public.staff_assignments'::regclass AND k.conname = 'staff_assignments_origin_check')),
         '1'
  UNION ALL
  SELECT 20, 'B4: trigger shifts_open_sight_edge on shifts (AFTER INSERT OR UPDATE OF staff_id, person_id, scheduled_date)',
         (SELECT count(*)::text FROM pg_trigger t
           WHERE t.tgrelid = 'public.shifts'::regclass AND t.tgname = 'shifts_open_sight_edge' AND NOT t.tgisinternal),
         '1'
  UNION ALL
  SELECT 21, '(info) schedule-origin sight edges today',
         (SELECT count(*)::text FROM public.staff_assignments WHERE origin = 'schedule'),
         '0 (none until a shift is scheduled for an unassigned deliver-tier staff)'
  UNION ALL
  SELECT 22, '(info) active staff with no tier (billing / readonly / unmapped) — would see nothing',
         (SELECT coalesce(string_agg(s.first_name || ' ' || s.last_name || ' (' || s.role::text || ')', '; '), 'none')
            FROM public.staff s WHERE s.is_active AND public.role_tier(s.role) IS NULL),
         'none'
) v ORDER BY ord;
