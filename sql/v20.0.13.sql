-- ============================================================================
-- Provly v20.0.13 — Item 4 PR (c): WRITE POLICIES
-- Run in the Supabase SQL editor (production) BEFORE the app ships.
-- Additive and idempotent: re-running yields the same policies and triggers.
-- Requires v20.0.12 (tenant guards + tier reads) — refuses to run without it.
--
-- Design: docs/item4-rls-design.md v1.3 (§5 as written, plus C1–C4 locked Sep 16).
--   §5  Every guarded table's INSERT/UPDATE/DELETE policies are replaced by ONE
--       tier policy per command (<t>_insert_tier / _update_tier / _delete_tier).
--       deliver writes its own records on people it can see; operate writes the
--       operational record; manage writes everything else; owner/admin write the
--       org row; compliance_director is excluded from intake and staff HR.
--       audit_log is append-only. evv_edit_log and evv_sessions are never deleted.
--   C1  Approved service notes are LOCKED for every tier. The only accepted
--       change is an explicit reopen (approved → submitted) by operate/manage,
--       written to audit_log. Approval stamps approved_by / approved_at from the
--       database, never from the client. Deliver can never set approved.
--   C2  The same lock covers incidents once reviewed (reviewed_at) and quarterly
--       summaries once submitted (status/submitted_to_sc_at).
--   C3  persons: name, date of birth, Medicaid #, ID #, admission/discharge dates
--       and is_active change only under the manage tier (trigger). Intake is
--       manage and not compliance_director.
--   C4  evv_sessions: a deliver login clocks in and clocks out ONCE; every other
--       change (times, coordinates, exceptions) is operate/manage, with the
--       v20.0.10 reason + edit log the app already requires.
--   Deliver on shifts: own row, status column only. messages: a recipient may
--   set read_at and nothing else; manage may edit.
-- Service-role / SQL-editor writes (auth.uid() IS NULL) pass every trigger
-- untouched — data repair stays possible; the triggers govern app logins.
-- r1 (Greptile r1, Sep 16) — RE-RUN REQUIRED: (1) audit_log.action is
-- VARCHAR(20); the reopen actions are now note_reopened / incident_reopened /
-- summary_reopened and the verification asserts they fit; (2) C4 tightened —
-- a deliver login may change ONLY clock_out_at/lat/lng, and only while the
-- session is open; a completed session is frozen for deliver entirely
-- (geofence_valid and exceptions included).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Pre-flight — (b) must be in place
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_guards int;
BEGIN
  SELECT count(*) INTO v_guards FROM pg_policies p
  WHERE p.schemaname = 'public' AND p.policyname = p.tablename || '_tenant_guard' AND p.permissive = 'RESTRICTIVE';
  IF v_guards < 44 THEN
    RAISE EXCEPTION 'v20.0.13 refused: found % tenant guards, expected 44 — run sql/v20.0.12.sql first', v_guards;
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Write applier — one call per table: drops every PERMISSIVE INSERT/UPDATE/
--    DELETE policy (the org-wide ones, and (b) r1's _office set) and creates
--    <t>_insert_tier / _update_tier / _delete_tier from the given predicates.
--    A NULL predicate = no policy = that command is denied to every app login.
--    The (b) RESTRICTIVE guard (org_id + membership) is untouched and still
--    applies to every write. Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.provly_v13_writes(p_table text, p_insert text, p_update text, p_delete text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_pol record;
BEGIN
  IF to_regclass('public.' || p_table) IS NULL THEN
    RAISE EXCEPTION 'v20.0.13: table public.% does not exist on this database', p_table;
  END IF;
  FOR v_pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = p_table
      AND permissive = 'PERMISSIVE' AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_pol.policyname, p_table);
  END LOOP;
  IF p_insert IS NOT NULL THEN
    EXECUTE format('CREATE POLICY %I ON public.%I AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (%s)',
                   p_table || '_insert_tier', p_table, p_insert);
  END IF;
  IF p_update IS NOT NULL THEN
    EXECUTE format('CREATE POLICY %I ON public.%I AS PERMISSIVE FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)',
                   p_table || '_update_tier', p_table, p_update, p_update);
  END IF;
  IF p_delete IS NOT NULL THEN
    EXECUTE format('CREATE POLICY %I ON public.%I AS PERMISSIVE FOR DELETE TO authenticated USING (%s)',
                   p_table || '_delete_tier', p_table, p_delete);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.provly_v13_writes(text, text, text, text) FROM PUBLIC, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. §5 — write policies. Predicates:
--      MO   = (SELECT access_tier()) IN ('manage','operate')
--      M    = (SELECT access_tier()) = 'manage'
--      MnCD = M AND member_role() <> 'compliance_director'
--      OWN  = (SELECT access_tier()) = 'deliver' AND staff_id = (SELECT my_staff_id())
-- ─────────────────────────────────────────────────────────────────────────────

-- Person-scoped ---------------------------------------------------------------
SELECT public.provly_v13_writes('persons',
  $i$(SELECT public.access_tier()) = 'manage' AND (SELECT public.member_role()) <> 'compliance_director'$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,                       -- C3 trigger holds identity columns
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('person_placements',                                    -- (b) r1: placements are sight
  $i$(SELECT public.access_tier()) = 'manage'$i$,
  $u$(SELECT public.access_tier()) = 'manage'$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('service_notes',
  $i$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()) AND public.can_see_person(person_id))$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()) AND status IN ('draft','submitted','rejected'))$u$,
  $d$(SELECT public.access_tier()) = 'manage' AND status IS DISTINCT FROM 'approved'$d$);   -- C1: approved notes are never deleted

SELECT public.provly_v13_writes('evv_sessions',
  $i$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()) AND public.can_see_person(person_id))$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()))$u$,   -- C4 trigger: clock-out once
  NULL);                                                                                -- §5: EVV sessions are never deleted

SELECT public.provly_v13_writes('evv_edit_log',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,                          -- C4: corrections are office-tier
  NULL, NULL);                                                                          -- append-only

SELECT public.provly_v13_writes('incidents',
  $i$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND reported_by = (SELECT public.my_staff_id()) AND public.can_see_person(person_id))$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND reported_by = (SELECT public.my_staff_id()) AND reviewed_at IS NULL)$u$,
  $d$(SELECT public.access_tier()) = 'manage' AND reviewed_at IS NULL$d$);              -- C2: reviewed incidents are never deleted

SELECT public.provly_v13_writes('medications',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('medication_logs',
  $i$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()) AND public.can_see_person(person_id))$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()))$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('medication_administrations',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('pcsp_goals',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('pcsp_progress_notes',
  $i$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()) AND public.can_see_person(person_id))$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()))$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('support_strategies',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('documents',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('quarterly_summaries',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage' AND submitted_to_sc_at IS NULL AND status IS DISTINCT FROM 'submitted'$d$);  -- C2

SELECT public.provly_v13_writes('belongings_inventory',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('day_activity_absence_days',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Context membership is the day-to-day roster of a group service; the contexts
-- themselves (structure) are manage per §5.
SELECT public.provly_v13_writes('service_delivery_context_members',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

SELECT public.provly_v13_writes('compliance_alerts',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Authorizations (R3): manage only, incl. rate. The v20.0.10 duplicate guard stays.
SELECT public.provly_v13_writes('person_service_authorizations',
  $i$(SELECT public.access_tier()) = 'manage'$i$,
  $u$(SELECT public.access_tier()) = 'manage'$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Staff-scoped ----------------------------------------------------------------
SELECT public.provly_v13_writes('shifts',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()))$u$,   -- trigger: status only
  $d$(SELECT public.access_tier()) IN ('manage','operate')$d$);

SELECT public.provly_v13_writes('staff_trainings',
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Staff record their own deck completions (the Training page); office tiers record anyone's.
SELECT public.provly_v13_writes('staff_deck_completions',
  $i$(SELECT public.access_tier()) IN ('manage','operate')
     OR ((SELECT public.access_tier()) = 'deliver' AND staff_id = (SELECT public.my_staff_id()))$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Any tiered member sends as themselves; a recipient marks read (trigger: read_at only); manage may edit/delete.
SELECT public.provly_v13_writes('messages',
  $i$(SELECT public.access_tier()) IS NOT NULL AND sender_staff_id = (SELECT public.my_staff_id())$i$,
  $u$(SELECT public.access_tier()) = 'manage' OR recipient_staff_id = (SELECT public.my_staff_id())$u$,
  $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Money: manage only ---------------------------------------------------------
SELECT public.provly_v13_writes('claim_submissions',  $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('payments',           $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('payment_line_items', $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('contracts',          $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('billing_claims',     $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('subscription_events', NULL, NULL, NULL);               -- webhook (service role) only

-- Org structure ---------------------------------------------------------------
-- staff HR: manage, not compliance_director (§5). role / is_active / user_id
-- stay unwritable by any login (v20.0.11 column privileges + RPCs).
SELECT public.provly_v13_writes('staff',
  $i$(SELECT public.access_tier()) = 'manage' AND (SELECT public.member_role()) <> 'compliance_director'$i$,
  $u$(SELECT public.access_tier()) = 'manage' AND (SELECT public.member_role()) <> 'compliance_director'$u$,
  $d$(SELECT public.access_tier()) = 'manage' AND (SELECT public.member_role()) <> 'compliance_director'$d$);

SELECT public.provly_v13_writes('staff_assignments',                                    -- (b) r1: edges are sight
  $i$(SELECT public.access_tier()) IN ('manage','operate')$i$,
  $u$(SELECT public.access_tier()) IN ('manage','operate')$u$,
  $d$(SELECT public.access_tier()) IN ('manage','operate')$d$);

SELECT public.provly_v13_writes('org_sites',                 $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('org_units',                 $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('service_delivery_contexts', $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('org_service_codes',         $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('generated_documents',       $i$(SELECT public.access_tier()) IN ('manage','operate')$i$, $u$(SELECT public.access_tier()) IN ('manage','operate')$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('evacuation_drills',         $i$(SELECT public.access_tier()) IN ('manage','operate')$i$, $u$(SELECT public.access_tier()) IN ('manage','operate')$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Training content: manage. (deck codes: the (b) guard already binds the deck to the org.)
SELECT public.provly_v13_writes('training_decks',              $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('training_topic_definitions',  $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);
SELECT public.provly_v13_writes('training_deck_service_codes', $i$(SELECT public.access_tier()) = 'manage'$i$, $u$(SELECT public.access_tier()) = 'manage'$u$, $d$(SELECT public.access_tier()) = 'manage'$d$);

-- Org row: owner + admin update profile/brand/enforcement (subscription and
-- Stripe columns stay service-role only via the v20.0.11 column privileges).
SELECT public.provly_v13_writes('organizations', NULL,
  $u$(SELECT public.member_role()) IN ('owner','admin')$u$, NULL);

-- Membership, invites: RPC/trigger written only. Audit: append-only, any tiered member.
SELECT public.provly_v13_writes('org_members', NULL, NULL, NULL);
SELECT public.provly_v13_writes('invites',     NULL, NULL, NULL);
SELECT public.provly_v13_writes('audit_log',   $i$(SELECT public.access_tier()) IS NOT NULL$i$, NULL, NULL);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Triggers. Every one starts the same way: a write with no auth.uid() is the
--    service role or the SQL editor and passes untouched; otherwise the writer's
--    tier decides. All SECURITY DEFINER so the audit_log insert bypasses RLS.
-- ─────────────────────────────────────────────────────────────────────────────

-- C1 — service notes: approval stamped by the database; approved = locked;
-- reopen (approved → submitted) by operate/manage, audited; deliver never
-- approves and never moves a note to another author or client.
CREATE OR REPLACE FUNCTION public.trg_service_notes_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier text := public.access_tier();
  v_strip text[] := ARRAY['status', 'approved_by', 'approved_at', 'updated_at'];
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;              -- service role / SQL editor

  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'approved' THEN
      IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
        RAISE EXCEPTION 'Only a supervisor or manager can approve a service note';
      END IF;
      NEW.approved_by := public.my_staff_id();
      NEW.approved_at := now();
    ELSE
      NEW.approved_by := NULL; NEW.approved_at := NULL;
    END IF;
    RETURN NEW;
  END IF;

  IF v_tier = 'deliver' THEN
    IF NEW.staff_id IS DISTINCT FROM OLD.staff_id OR NEW.person_id IS DISTINCT FROM OLD.person_id THEN
      RAISE EXCEPTION 'A service note stays with its author and client';
    END IF;
    IF NEW.status = 'approved' THEN
      RAISE EXCEPTION 'Only a supervisor or manager can approve a service note';
    END IF;
  END IF;

  IF OLD.status = 'approved' THEN                               -- LOCKED
    IF NEW.status = 'approved' THEN
      IF (to_jsonb(NEW) - 'updated_at') <> (to_jsonb(OLD) - 'updated_at') THEN
        RAISE EXCEPTION 'This service note is approved and locked. Reopen it to make changes.';
      END IF;
      RETURN NEW;                                                -- no-op update
    END IF;
    IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' OR NEW.status <> 'submitted' THEN
      RAISE EXCEPTION 'An approved service note can only be reopened (to submitted) by a supervisor or manager';
    END IF;
    IF (to_jsonb(NEW) - v_strip) <> (to_jsonb(OLD) - v_strip) THEN
      RAISE EXCEPTION 'Reopen the note first; edit it in a second step';
    END IF;
    NEW.approved_by := NULL; NEW.approved_at := NULL;
    INSERT INTO public.audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (OLD.org_id, auth.uid(), 'note_reopened', 'service_notes', OLD.id,
            jsonb_build_object('status', OLD.status, 'approved_by', OLD.approved_by, 'approved_at', OLD.approved_at),
            jsonb_build_object('status', NEW.status, 'reopened_by_staff_id', public.my_staff_id()));
    RETURN NEW;
  END IF;

  IF NEW.status = 'approved' THEN                               -- approving now
    IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
      RAISE EXCEPTION 'Only a supervisor or manager can approve a service note';
    END IF;
    NEW.approved_by := public.my_staff_id();
    NEW.approved_at := now();
  ELSE
    NEW.approved_by := NULL; NEW.approved_at := NULL;            -- not approved: no stamp survives
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_service_notes_lock() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS service_notes_lock ON public.service_notes;
CREATE TRIGGER service_notes_lock
  BEFORE INSERT OR UPDATE ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_lock();

-- C2 — incidents: reviewed_at set by operate/manage stamps reviewed_by from the
-- database; reviewed = content locked (review layer — status, review_notes —
-- stays editable by operate/manage); reopen = reviewed_at cleared, audited.
-- deliver files and edits its own unreviewed reports, never reviews.
CREATE OR REPLACE FUNCTION public.trg_incidents_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier text := public.access_tier();
  v_review text[] := ARRAY['status', 'reviewed_by', 'reviewed_at', 'review_notes'];
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.reviewed_at IS NOT NULL OR NEW.reviewed_by IS NOT NULL THEN
      IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
        RAISE EXCEPTION 'Only a supervisor or manager can review an incident';
      END IF;
      NEW.reviewed_by := public.my_staff_id();
      NEW.reviewed_at := coalesce(NEW.reviewed_at, now());
    END IF;
    RETURN NEW;
  END IF;

  IF v_tier = 'deliver' THEN
    IF NEW.reported_by IS DISTINCT FROM OLD.reported_by OR NEW.person_id IS DISTINCT FROM OLD.person_id THEN
      RAISE EXCEPTION 'An incident report stays with its reporter and client';
    END IF;
    IF NEW.reviewed_at IS NOT NULL OR NEW.reviewed_by IS NOT NULL THEN
      RAISE EXCEPTION 'Only a supervisor or manager can review an incident';
    END IF;
  END IF;

  IF OLD.reviewed_at IS NOT NULL THEN                           -- LOCKED
    IF (to_jsonb(NEW) - v_review) <> (to_jsonb(OLD) - v_review) THEN
      RAISE EXCEPTION 'This incident has been reviewed and is locked. Reopen it to make changes.';
    END IF;
    IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
      RAISE EXCEPTION 'Only a supervisor or manager can change a reviewed incident';
    END IF;
    IF NEW.reviewed_at IS NULL THEN                              -- reopen
      NEW.reviewed_by := NULL;
      INSERT INTO public.audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
      VALUES (OLD.org_id, auth.uid(), 'incident_reopened', 'incidents', OLD.id,
              jsonb_build_object('status', OLD.status, 'reviewed_by', OLD.reviewed_by, 'reviewed_at', OLD.reviewed_at),
              jsonb_build_object('status', NEW.status, 'reopened_by_staff_id', public.my_staff_id()));
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.reviewed_at IS NOT NULL THEN                           -- reviewing now
    IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
      RAISE EXCEPTION 'Only a supervisor or manager can review an incident';
    END IF;
    NEW.reviewed_by := public.my_staff_id();
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_incidents_lock() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS incidents_lock ON public.incidents;
CREATE TRIGGER incidents_lock
  BEFORE INSERT OR UPDATE ON public.incidents
  FOR EACH ROW EXECUTE FUNCTION public.trg_incidents_lock();

-- C2 — quarterly summaries: submitted (status or submitted_to_sc_at) = locked;
-- reopen by operate/manage clears both, audited. (The app does not yet write
-- this table; the lock is in place for when it does.)
CREATE OR REPLACE FUNCTION public.trg_quarterly_summaries_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier text := public.access_tier();
  v_strip text[] := ARRAY['status', 'submitted_to_sc_at', 'updated_at'];
  v_old_locked boolean;
  v_new_locked boolean;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  v_old_locked := (OLD.submitted_to_sc_at IS NOT NULL OR OLD.status = 'submitted');
  v_new_locked := (NEW.submitted_to_sc_at IS NOT NULL OR NEW.status = 'submitted');
  IF v_old_locked THEN
    IF v_new_locked THEN
      IF (to_jsonb(NEW) - 'updated_at') <> (to_jsonb(OLD) - 'updated_at') THEN
        RAISE EXCEPTION 'This quarterly summary was submitted and is locked. Reopen it to make changes.';
      END IF;
      RETURN NEW;
    END IF;
    IF v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
      RAISE EXCEPTION 'Only a supervisor or manager can reopen a submitted quarterly summary';
    END IF;
    IF (to_jsonb(NEW) - v_strip) <> (to_jsonb(OLD) - v_strip) THEN
      RAISE EXCEPTION 'Reopen the summary first; edit it in a second step';
    END IF;
    NEW.submitted_to_sc_at := NULL;
    INSERT INTO public.audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
    VALUES (OLD.org_id, auth.uid(), 'summary_reopened', 'quarterly_summaries', OLD.id,
            jsonb_build_object('status', OLD.status, 'submitted_to_sc_at', OLD.submitted_to_sc_at),
            jsonb_build_object('status', NEW.status, 'reopened_by_staff_id', public.my_staff_id()));
    RETURN NEW;
  END IF;
  IF v_new_locked AND v_tier IS DISTINCT FROM 'manage' AND v_tier IS DISTINCT FROM 'operate' THEN
    RAISE EXCEPTION 'Only a supervisor or manager can submit a quarterly summary';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_quarterly_summaries_lock() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS quarterly_summaries_lock ON public.quarterly_summaries;
CREATE TRIGGER quarterly_summaries_lock
  BEFORE UPDATE ON public.quarterly_summaries
  FOR EACH ROW EXECUTE FUNCTION public.trg_quarterly_summaries_lock();

-- C3 — persons: identity columns change only under the manage tier.
CREATE OR REPLACE FUNCTION public.trg_persons_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier text := public.access_tier();
  v_col  text;
BEGIN
  IF auth.uid() IS NULL OR v_tier = 'manage' THEN RETURN NEW; END IF;
  FOREACH v_col IN ARRAY ARRAY['first_name', 'last_name', 'date_of_birth', 'medicaid_number', 'identification_number',
                               'admission_date', 'discharge_date', 'is_active'] LOOP
    IF (to_jsonb(NEW) -> v_col) IS DISTINCT FROM (to_jsonb(OLD) -> v_col) THEN
      RAISE EXCEPTION 'Only a manager can change a client''s %', replace(v_col, '_', ' ');
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_persons_identity_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS persons_identity_guard ON public.persons;
CREATE TRIGGER persons_identity_guard
  BEFORE UPDATE ON public.persons
  FOR EACH ROW EXECUTE FUNCTION public.trg_persons_identity_guard();

-- C4 — evv_sessions: a deliver login may only clock out, once. While the
-- session is open it may set clock_out_at / clock_out_lat / clock_out_lng and
-- nothing else; once clock_out_at is set the row is frozen for deliver in
-- every column (r1: geofence_valid and exceptions included — evidence, not
-- the worker's to touch). Corrections are operate/manage with the v20.0.10
-- reason + edit log.
CREATE OR REPLACE FUNCTION public.trg_evv_deliver_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier text := public.access_tier();
  -- original_* are derive-only (trg_evv_sessions_preserve_originals rewrites them
  -- after this trigger); excluded so the check does not depend on trigger order.
  v_derived  text[] := ARRAY['original_clock_in_at', 'original_clock_out_at'];
  v_clockout text[] := ARRAY['clock_out_at', 'clock_out_lat', 'clock_out_lng', 'original_clock_in_at', 'original_clock_out_at'];
BEGIN
  IF auth.uid() IS NULL OR v_tier IN ('manage', 'operate') THEN RETURN NEW; END IF;
  IF OLD.clock_out_at IS NOT NULL THEN                          -- completed: frozen for deliver
    IF (to_jsonb(NEW) - v_derived) <> (to_jsonb(OLD) - v_derived) THEN
      RAISE EXCEPTION 'This session is already clocked out. Ask a supervisor to correct it.';
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - v_clockout) <> (to_jsonb(OLD) - v_clockout) THEN   -- open: clock-out fields only
    RAISE EXCEPTION 'EVV time corrections are made by a supervisor, with a reason';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_evv_deliver_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS evv_deliver_guard ON public.evv_sessions;
CREATE TRIGGER evv_deliver_guard
  BEFORE UPDATE ON public.evv_sessions
  FOR EACH ROW EXECUTE FUNCTION public.trg_evv_deliver_guard();

-- R5 — shifts: a deliver login changes only its own shift's status.
CREATE OR REPLACE FUNCTION public.trg_shifts_deliver_status_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.access_tier() IN ('manage', 'operate') THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - 'status' - 'updated_at') <> (to_jsonb(OLD) - 'status' - 'updated_at') THEN
    RAISE EXCEPTION 'Only the status of your own shift can be changed here';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_shifts_deliver_status_only() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS shifts_deliver_status_only ON public.shifts;
CREATE TRIGGER shifts_deliver_status_only
  BEFORE UPDATE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.trg_shifts_deliver_status_only();

-- messages: below manage, an update may only set read_at.
CREATE OR REPLACE FUNCTION public.trg_messages_read_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.access_tier() = 'manage' THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - 'read_at') <> (to_jsonb(OLD) - 'read_at') THEN
    RAISE EXCEPTION 'A message cannot be edited after it is sent';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_messages_read_only() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS messages_read_only ON public.messages;
CREATE TRIGGER messages_read_only
  BEFORE UPDATE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.trg_messages_read_only();

NOTIFY pgrst, 'reload schema';

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification — one statement. Paste the whole result.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT check_name, value, want FROM (
  SELECT 1 AS ord, '(b) tenant guards still present' AS check_name,
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.policyname = p.tablename || '_tenant_guard' AND p.permissive = 'RESTRICTIVE') AS value,
         '44' AS want
  UNION ALL
  SELECT 2, 'permissive write policies on guarded tables NOT named <t>_insert/_update/_delete_tier (stragglers)',
         (SELECT coalesce(string_agg(p.tablename || '.' || p.policyname, '; ' ORDER BY p.tablename COLLATE "C"), 'none') FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('INSERT','UPDATE','DELETE','ALL')
             AND EXISTS (SELECT 1 FROM pg_policies g WHERE g.schemaname = 'public' AND g.tablename = p.tablename AND g.policyname = p.tablename || '_tenant_guard')
             AND p.policyname NOT IN (p.tablename || '_insert_tier', p.tablename || '_update_tier', p.tablename || '_delete_tier')),
         'none'
  UNION ALL
  SELECT 3, 'tier write policies in place (<t>_insert/_update/_delete_tier, TO authenticated)',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE' AND p.roles::text = '{authenticated}'
             AND p.policyname IN (p.tablename || '_insert_tier', p.tablename || '_update_tier', p.tablename || '_delete_tier')),
         '116'
  UNION ALL
  SELECT 4, 'write policies on guarded tables whose predicate does NOT bind a tier / role / own staff id (org-wide leftovers)',
         (SELECT coalesce(string_agg(p.tablename || '.' || p.policyname, '; ' ORDER BY p.tablename COLLATE "C"), 'none') FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('INSERT','UPDATE','DELETE','ALL')
             AND EXISTS (SELECT 1 FROM pg_policies g WHERE g.schemaname = 'public' AND g.tablename = p.tablename AND g.policyname = p.tablename || '_tenant_guard')
             AND coalesce(p.qual, '') NOT LIKE '%access_tier()%' AND coalesce(p.with_check, '') NOT LIKE '%access_tier()%'
             AND coalesce(p.qual, '') NOT LIKE '%member_role()%' AND coalesce(p.with_check, '') NOT LIKE '%member_role()%'),
         'none'
  UNION ALL
  SELECT 5, 'deliver-tier write policies (own records on visible people; shifts status; deck completions)',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('INSERT','UPDATE')
             AND p.policyname LIKE '%\_tier' AND coalesce(p.with_check, p.qual) LIKE '%''deliver''%'),
         '12'
  UNION ALL
  SELECT 6, 'append-only: UPDATE/DELETE policies on audit_log + evv_edit_log; DELETE on evv_sessions',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE'
             AND ((p.tablename IN ('audit_log','evv_edit_log') AND p.cmd IN ('UPDATE','DELETE','ALL'))
               OR (p.tablename = 'evv_sessions' AND p.cmd IN ('DELETE','ALL')))),
         '0'
  UNION ALL
  SELECT 7, 'no app writes at all: org_members / invites / subscription_events',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('INSERT','UPDATE','DELETE','ALL')
             AND p.tablename IN ('org_members','invites','subscription_events')),
         '0'
  UNION ALL
  SELECT 8, 'organizations: UPDATE bound to owner/admin, no INSERT/DELETE policy',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = 'organizations' AND p.permissive = 'PERMISSIVE' AND p.cmd = 'UPDATE'
             AND p.qual LIKE '%owner%' AND p.qual LIKE '%admin%' AND p.qual LIKE '%member_role()%'
             AND NOT EXISTS (SELECT 1 FROM pg_policies q WHERE q.schemaname = 'public' AND q.tablename = 'organizations'
                             AND q.permissive = 'PERMISSIVE' AND q.cmd IN ('INSERT','DELETE','ALL'))),
         '1'
  UNION ALL
  SELECT 9, 'compliance_director excluded: persons INSERT + staff INSERT/UPDATE/DELETE',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE'
             AND ((p.tablename = 'persons' AND p.cmd = 'INSERT') OR (p.tablename = 'staff' AND p.cmd IN ('INSERT','UPDATE','DELETE')))
             AND coalesce(p.with_check, p.qual) LIKE '%compliance_director%'),
         '4'
  UNION ALL
  SELECT 10, 'locked records undeletable: service_notes / incidents / quarterly_summaries DELETE excludes the locked state',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE' AND p.cmd = 'DELETE'
             AND ((p.tablename = 'service_notes' AND p.qual LIKE '%approved%')
               OR (p.tablename = 'incidents' AND p.qual LIKE '%reviewed_at%')
               OR (p.tablename = 'quarterly_summaries' AND p.qual LIKE '%submitted%'))),
         '3'
  UNION ALL
  SELECT 11, 'triggers: service_notes_lock, incidents_lock, quarterly_summaries_lock, persons_identity_guard, evv_deliver_guard, shifts_deliver_status_only, messages_read_only',
         (SELECT count(*)::text FROM pg_trigger t
           WHERE NOT t.tgisinternal
             AND (t.tgrelid, t.tgname) IN (('public.service_notes'::regclass, 'service_notes_lock'),
                                            ('public.incidents'::regclass, 'incidents_lock'),
                                            ('public.quarterly_summaries'::regclass, 'quarterly_summaries_lock'),
                                            ('public.persons'::regclass, 'persons_identity_guard'),
                                            ('public.evv_sessions'::regclass, 'evv_deliver_guard'),
                                            ('public.shifts'::regclass, 'shifts_deliver_status_only'),
                                            ('public.messages'::regclass, 'messages_read_only'))),
         '7'
  UNION ALL
  SELECT 12, 'reopen paths write audit_log (three lock triggers carry their audit action)',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace
             AND ((p.proname = 'trg_service_notes_lock' AND p.prosrc LIKE '%''note_reopened''%')
               OR (p.proname = 'trg_incidents_lock' AND p.prosrc LIKE '%''incident_reopened''%')
               OR (p.proname = 'trg_quarterly_summaries_lock' AND p.prosrc LIKE '%''summary_reopened''%'))),
         '3'
  UNION ALL
  SELECT 13, 'every trigger lets service-role / SQL-editor writes through (auth.uid() IS NULL check)',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace
             AND p.proname IN ('trg_service_notes_lock','trg_incidents_lock','trg_quarterly_summaries_lock','trg_persons_identity_guard',
                               'trg_evv_deliver_guard','trg_shifts_deliver_status_only','trg_messages_read_only')
             AND p.prosrc LIKE '%auth.uid() IS NULL%'),
         '7'
  UNION ALL
  SELECT 14, '(info) approved notes / reviewed incidents now under lock',
         (SELECT (SELECT count(*) FROM public.service_notes WHERE status = 'approved')::text || ' / ' ||
                 (SELECT count(*) FROM public.incidents WHERE reviewed_at IS NOT NULL)::text),
         'read'
  UNION ALL
  SELECT 15, '(info) approved notes with no approved_by stamp (approved before v20.0.13 — expected; stamps start now)',
         (SELECT count(*)::text FROM public.service_notes WHERE status = 'approved' AND approved_by IS NULL),
         'read'
  UNION ALL
  SELECT 16, 'r1: the three reopen actions fit audit_log.action (column max length shown)',
         (SELECT (greatest(length('note_reopened'), length('incident_reopened'), length('summary_reopened'))
                  <= coalesce(c.character_maximum_length, 1000000))::text || ' (max ' || coalesce(c.character_maximum_length::text, 'unbounded') || ')'
            FROM information_schema.columns c
           WHERE c.table_schema = 'public' AND c.table_name = 'audit_log' AND c.column_name = 'action'),
         'true (max 20)'
  UNION ALL
  SELECT 17, 'r1: EVV deliver guard freezes completed sessions entirely (geofence_valid / exceptions no longer writable below office tiers)',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_evv_deliver_guard'
             AND p.prosrc NOT LIKE '%''geofence_valid''%' AND p.prosrc NOT LIKE '%''exceptions''%'
             AND p.prosrc LIKE '%already clocked out%'),
         '1'
) v ORDER BY ord;
