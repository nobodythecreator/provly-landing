-- ═══════════════════════════════════════════════════════════════════════
-- v20.0.23 — e520 arc, PR 1: the recording pieces (docs/e520-design.md §3)
--   D7  person_absences: from, to (NULL = ongoing), reason, required note
--       for Other; no two absences overlap for one client.
--   D6  service_notes.transport on DSG notes, preset 'to_and_from'.
-- Run on production in the Supabase SQL editor BEFORE the app ships.
-- Idempotent: safe to re-run. The last statement is the verification table.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- 0. btree_gist — lets the no-overlap rule be a constraint, not a trigger
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- 1. persons(id, org_id) must be unique for the tenant-bound FK below.
--    Discovery showed only persons_pkey as a constraint; an equivalent unique
--    INDEX may already exist (v20.0.4g's composite FKs need one), so create
--    one only if no unique index covers exactly {id, org_id}.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_index i
     WHERE i.indrelid = 'public.persons'::regclass
       AND i.indisunique AND i.indpred IS NULL AND i.indnkeyatts = 2
       AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text)
              FROM pg_attribute a
             WHERE a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)) = ARRAY['id', 'org_id']
  ) THEN
    CREATE UNIQUE INDEX persons_id_org_uq ON public.persons (id, org_id);
  END IF;
END $$;

-- 2. person_absences
CREATE TABLE IF NOT EXISTS public.person_absences (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  person_id   uuid NOT NULL,
  start_date  date NOT NULL,                 -- first full day away
  end_date    date,                          -- last full day away; NULL = ongoing
  reason      text NOT NULL,
  note        text,
  created_by  uuid REFERENCES public.staff (id) ON DELETE SET NULL,   -- set by trigger
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT person_absences_person_org_fk FOREIGN KEY (person_id, org_id)
    REFERENCES public.persons (id, org_id) ON DELETE CASCADE,
  CONSTRAINT person_absences_reason_chk
    CHECK (reason IN ('family', 'vacation', 'hospital', 'awol', 'jail', 'other')),
  CONSTRAINT person_absences_other_note_chk
    CHECK (reason <> 'other' OR length(btrim(coalesce(note, ''))) > 0),
  CONSTRAINT person_absences_dates_chk
    CHECK (end_date IS NULL OR end_date >= start_date),
  CONSTRAINT person_absences_no_overlap
    EXCLUDE USING gist (person_id WITH =, daterange(start_date, end_date, '[]') WITH &&)
);

CREATE INDEX IF NOT EXISTS person_absences_org_idx ON public.person_absences (org_id);

COMMENT ON TABLE public.person_absences IS
  'v20.0.23 (e520 D7): full days a client was away. Not billed; the e520 export splits every payment line around them. Office tiers write; anyone who can see the client reads.';

-- 2a. stamps: created_by = the signed-in staff record; an absence never moves client or org
CREATE OR REPLACE FUNCTION public.trg_person_absences_stamp()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF auth.uid() IS NOT NULL THEN NEW.created_by := public.my_staff_id(); END IF;
    NEW.created_at := now();
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  IF NEW.person_id IS DISTINCT FROM OLD.person_id OR NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'An absence stays with its client';
  END IF;
  NEW.created_by := OLD.created_by;
  NEW.created_at := OLD.created_at;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS person_absences_stamp ON public.person_absences;
CREATE TRIGGER person_absences_stamp
  BEFORE INSERT OR UPDATE ON public.person_absences
  FOR EACH ROW EXECUTE FUNCTION public.trg_person_absences_stamp();

-- 2b. audit: every change and delete of an absence (billing depends on them).
--     Writes with no auth.uid() (service role / SQL editor repair) pass unaudited,
--     as every Item 4 trigger does.
CREATE OR REPLACE FUNCTION public.trg_person_absences_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
  VALUES (OLD.org_id, auth.uid(),
          CASE TG_OP WHEN 'DELETE' THEN 'absence_deleted' ELSE 'absence_changed' END,
          'person_absences', OLD.id, to_jsonb(OLD),
          CASE TG_OP WHEN 'DELETE' THEN NULL ELSE to_jsonb(NEW) END);
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS person_absences_audit ON public.person_absences;
CREATE TRIGGER person_absences_audit
  AFTER UPDATE OR DELETE ON public.person_absences
  FOR EACH ROW EXECUTE FUNCTION public.trg_person_absences_audit();

-- 2c. RLS: the v20.0.12 tenant guard (claim + live membership) + tier policies
ALTER TABLE public.person_absences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.person_absences FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.person_absences TO authenticated;

DROP POLICY IF EXISTS person_absences_tenant_guard ON public.person_absences;
CREATE POLICY person_absences_tenant_guard ON public.person_absences
  AS RESTRICTIVE FOR ALL TO authenticated
  USING      (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT public.org_id()) AND (SELECT public.member_role()) IS NOT NULL);

DROP POLICY IF EXISTS person_absences_read_tier ON public.person_absences;
CREATE POLICY person_absences_read_tier ON public.person_absences
  FOR SELECT TO authenticated
  USING ((SELECT public.access_tier()) IN ('manage', 'operate') OR public.can_see_person(person_id));

DROP POLICY IF EXISTS person_absences_insert_tier ON public.person_absences;
CREATE POLICY person_absences_insert_tier ON public.person_absences
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.access_tier()) IN ('manage', 'operate'));

DROP POLICY IF EXISTS person_absences_update_tier ON public.person_absences;
CREATE POLICY person_absences_update_tier ON public.person_absences
  FOR UPDATE TO authenticated
  USING      ((SELECT public.access_tier()) IN ('manage', 'operate'))
  WITH CHECK ((SELECT public.access_tier()) IN ('manage', 'operate'));

DROP POLICY IF EXISTS person_absences_delete_tier ON public.person_absences;
CREATE POLICY person_absences_delete_tier ON public.person_absences
  FOR DELETE TO authenticated
  USING ((SELECT public.access_tier()) IN ('manage', 'operate'));

-- 3. service_notes.transport (D6). The approved-note lock compares whole rows
--    (to_jsonb(NEW) vs OLD), so transport is locked with the note automatically.
ALTER TABLE public.service_notes ADD COLUMN IF NOT EXISTS transport text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.service_notes'::regclass
                    AND conname = 'service_notes_transport_chk') THEN
    ALTER TABLE public.service_notes ADD CONSTRAINT service_notes_transport_chk
      CHECK (transport IN ('to_and_from', 'to', 'from', 'none'));
  END IF;
END $$;

COMMENT ON COLUMN public.service_notes.transport IS
  'v20.0.23 (e520 D6): DSG notes only — did our staff drive the client to/from the program. Preset to_and_from; the MTP line bills one day per approved DSG note with transport <> none. NULL on every other code.';

-- 3a. DSG notes get the preset when saved without a value; every other code is NULL.
--     Fires after service_notes_lock (triggers run in name order: l < t).
CREATE OR REPLACE FUNCTION public.trg_service_notes_transport()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_code text;
BEGIN
  SELECT code INTO v_code FROM public.service_code_definitions WHERE id = NEW.service_code_id;
  IF v_code = 'DSG' THEN
    IF NEW.transport IS NULL THEN NEW.transport := 'to_and_from'; END IF;
  ELSE
    NEW.transport := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS service_notes_transport ON public.service_notes;
CREATE TRIGGER service_notes_transport
  BEFORE INSERT OR UPDATE OF service_code_id, transport ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_transport();

-- 3b. Backfill (design §3.2). Discovery counted 0 DSG notes on production, so
--     this is a no-op today; it stays so a re-run or another tenant is covered.
UPDATE public.service_notes n
   SET transport = 'to_and_from'
  FROM public.service_code_definitions c
 WHERE c.id = n.service_code_id AND c.code = 'DSG' AND n.transport IS NULL;

-- 4. Self-test — proves the two absence rules on a real client, leaves nothing
--    behind (both inserts sit in a sub-transaction that is rolled back).
DO $$
DECLARE
  v_person uuid;
  v_org    uuid;
  v_overlap_refused boolean := false;
  v_other_refused   boolean := false;
BEGIN
  SELECT id, org_id INTO v_person, v_org FROM public.persons ORDER BY id LIMIT 1;
  IF v_person IS NULL THEN RETURN; END IF;
  BEGIN
    INSERT INTO public.person_absences (org_id, person_id, start_date, end_date, reason)
    VALUES (v_org, v_person, DATE '1900-01-01', DATE '1900-01-10', 'family');
    BEGIN
      INSERT INTO public.person_absences (org_id, person_id, start_date, end_date, reason)
      VALUES (v_org, v_person, DATE '1900-01-05', NULL, 'hospital');
    EXCEPTION WHEN exclusion_violation THEN v_overlap_refused := true;
    END;
    BEGIN
      INSERT INTO public.person_absences (org_id, person_id, start_date, end_date, reason, note)
      VALUES (v_org, v_person, DATE '1900-02-01', DATE '1900-02-02', 'other', '   ');
    EXCEPTION WHEN check_violation THEN v_other_refused := true;
    END;
    RAISE EXCEPTION 'v20023_selftest_rollback';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'v20023_selftest_rollback' THEN RAISE; END IF;
  END;
  IF NOT v_overlap_refused THEN RAISE EXCEPTION 'v20.0.23 self-test: overlapping absences were NOT refused'; END IF;
  IF NOT v_other_refused   THEN RAISE EXCEPTION 'v20.0.23 self-test: Other without a note was NOT refused'; END IF;
END $$;

COMMIT;

-- 5. Verification — paste this table into chat before the PR merges.
SELECT * FROM (
  SELECT 1 AS n, 'btree_gist installed' AS check_item,
    (SELECT coalesce(installed_version, 'NO') FROM pg_available_extensions WHERE name = 'btree_gist') AS value,
    'a version number' AS want
  UNION ALL
  SELECT 2, 'unique index on persons {id, org_id}',
    (SELECT count(*)::text FROM pg_index i
      WHERE i.indrelid = 'public.persons'::regclass AND i.indisunique AND i.indpred IS NULL AND i.indnkeyatts = 2
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text) FROM pg_attribute a
              WHERE a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)) = ARRAY['id', 'org_id']),
    '1 or more'
  UNION ALL
  SELECT 3, 'person_absences constraints (fk, reason, other note, dates, no overlap)',
    (SELECT count(*)::text FROM pg_constraint
      WHERE conrelid = 'public.person_absences'::regclass
        AND conname IN ('person_absences_person_org_fk', 'person_absences_reason_chk',
                        'person_absences_other_note_chk', 'person_absences_dates_chk',
                        'person_absences_no_overlap')),
    '5'
  UNION ALL
  SELECT 4, 'person_absences RLS enabled',
    (SELECT relrowsecurity::text FROM pg_class WHERE oid = 'public.person_absences'::regclass),
    'true'
  UNION ALL
  SELECT 5, 'person_absences policies',
    (SELECT string_agg(policyname || ' ' || cmd || ' ' || permissive, ', ' ORDER BY policyname)
       FROM pg_policies WHERE schemaname = 'public' AND tablename = 'person_absences'),
    'person_absences_delete_tier DELETE PERMISSIVE, person_absences_insert_tier INSERT PERMISSIVE, person_absences_read_tier SELECT PERMISSIVE, person_absences_tenant_guard ALL RESTRICTIVE, person_absences_update_tier UPDATE PERMISSIVE'
  UNION ALL
  SELECT 6, 'person_absences triggers',
    (SELECT string_agg(tgname, ', ' ORDER BY tgname) FROM pg_trigger
      WHERE tgrelid = 'public.person_absences'::regclass AND NOT tgisinternal),
    'person_absences_audit, person_absences_stamp'
  UNION ALL
  SELECT 7, 'anon privileges on person_absences',
    (SELECT count(*)::text FROM information_schema.role_table_grants
      WHERE table_schema = 'public' AND table_name = 'person_absences' AND grantee = 'anon'),
    '0'
  UNION ALL
  SELECT 8, 'service_notes.transport column',
    (SELECT count(*)::text FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'service_notes' AND column_name = 'transport'),
    '1'
  UNION ALL
  SELECT 9, 'transport check constraint',
    (SELECT count(*)::text FROM pg_constraint
      WHERE conrelid = 'public.service_notes'::regclass AND conname = 'service_notes_transport_chk'),
    '1'
  UNION ALL
  SELECT 10, 'service_notes triggers',
    (SELECT string_agg(tgname, ', ' ORDER BY tgname) FROM pg_trigger
      WHERE tgrelid = 'public.service_notes'::regclass AND NOT tgisinternal),
    'service_note_auth_update, service_notes_delete_audit, service_notes_deliver_auth, service_notes_lock, service_notes_transport, service_notes_updated_at'
  UNION ALL
  SELECT 11, 'DSG notes missing transport',
    (SELECT count(*)::text FROM public.service_notes n JOIN public.service_code_definitions c ON c.id = n.service_code_id
      WHERE c.code = 'DSG' AND n.transport IS NULL),
    '0'
  UNION ALL
  SELECT 12, 'non-DSG notes carrying transport',
    (SELECT count(*)::text FROM public.service_notes n JOIN public.service_code_definitions c ON c.id = n.service_code_id
      WHERE c.code <> 'DSG' AND n.transport IS NOT NULL),
    '0'
  UNION ALL
  SELECT 13, 'absences left behind by the self-test',
    (SELECT count(*)::text FROM public.person_absences WHERE start_date < DATE '1901-01-01'),
    '0'
) v ORDER BY n;
