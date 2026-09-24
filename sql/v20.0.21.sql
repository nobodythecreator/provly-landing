-- ============================================================================
-- Provly v20.0.21 — front-line service notes need a current authorization
-- (small debt; D1 = A: refuse the save). Run in the Supabase SQL editor
-- (production) BEFORE merge. Idempotent. No app change.
--
-- The database now applies the SAME test the note form has applied since
-- v20.0.13b (r3), for deliver-tier logins only:
--   a note's service code is valid on its service date when
--   (1) the client has an authorization for that code whose status is not
--       expired / closed / terminated / denied / inactive / cancelled and whose
--       start–end dates cover the service date, OR
--   (2) the note is filed under a group-service context that locks that code
--       and the client is an active member of it (is_active not false, no end
--       date) — the context is the authorization for group service.
-- Checked on INSERT, and on UPDATE only when client, code, date or context
-- changes — editing or submitting an existing draft is never blocked by an
-- authorization that has since closed. Office tiers keep their override;
-- service-role / SQL-editor writes pass untouched.
-- r1 (Greptile r1): (a) the v19.2 note-context column is now installed here
-- (idempotent, exactly as v19.2 documents it), so a context-bearing note is
-- never saved without its context and then refused; the form's
-- missing-column retry can no longer fire. (b) the context itself must be
-- active (is_active = true, as the form loads it) — an archived context no
-- longer authorizes anything.
-- ============================================================================

-- 0. v19.2 prerequisite — service_notes.context_id (no-op where it exists)
ALTER TABLE public.service_notes ADD COLUMN IF NOT EXISTS context_id UUID
  REFERENCES public.service_delivery_contexts(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_notes_context ON public.service_notes(context_id);

CREATE OR REPLACE FUNCTION public.trg_service_notes_deliver_auth()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ctx uuid;
  v_ok  boolean;
BEGIN
  IF auth.uid() IS NULL OR public.access_tier() IS DISTINCT FROM 'deliver' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.person_id IS NOT DISTINCT FROM OLD.person_id
     AND NEW.service_code_id IS NOT DISTINCT FROM OLD.service_code_id
     AND NEW.service_date IS NOT DISTINCT FROM OLD.service_date
     AND NEW.context_id IS NOT DISTINCT FROM OLD.context_id THEN
    RETURN NEW;                                                  -- nothing the test depends on changed
  END IF;

  -- (1) a direct authorization, current on the service date
  SELECT EXISTS (
    SELECT 1 FROM public.person_service_authorizations a
     WHERE a.org_id = NEW.org_id AND a.person_id = NEW.person_id AND a.service_code_id = NEW.service_code_id
       AND lower(a.status::text) NOT IN ('expired', 'closed', 'terminated', 'denied', 'inactive', 'cancelled', 'canceled')
       AND a.start_date <= NEW.service_date AND a.end_date >= NEW.service_date
  ) INTO v_ok;

  -- (2) a group-service context that locks the code, the client an active member
  IF NOT v_ok THEN
    v_ctx := NEW.context_id;
    IF v_ctx IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM public.service_delivery_contexts c
          JOIN public.service_delivery_context_members m ON m.context_id = c.id
         WHERE c.id = v_ctx AND c.org_id = NEW.org_id AND c.is_active = true      -- r1: archived contexts authorize nothing
           AND c.service_code_id = NEW.service_code_id
           AND m.person_id = NEW.person_id AND m.is_active IS DISTINCT FROM false AND m.end_date IS NULL
      ) INTO v_ok;
    END IF;
  END IF;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'There is no current authorization for this service on this date. Ask your office.';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_service_notes_deliver_auth() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS service_notes_deliver_auth ON public.service_notes;
CREATE TRIGGER service_notes_deliver_auth
  BEFORE INSERT OR UPDATE ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_deliver_auth();

NOTIFY pgrst, 'reload schema';

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification — one statement. Paste the whole result.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT check_name, value, want FROM (
  SELECT 1 AS ord, 'trigger present: BEFORE INSERT OR UPDATE on service_notes' AS check_name,
         (SELECT count(*)::text FROM pg_trigger t
           WHERE t.tgrelid = 'public.service_notes'::regclass AND t.tgname = 'service_notes_deliver_auth' AND NOT t.tgisinternal
             AND (t.tgtype & 2) = 2 AND (t.tgtype & 4) = 4 AND (t.tgtype & 16) = 16) AS value,
         '1' AS want
  UNION ALL
  SELECT 2, 'front-line only; service role passes; office tiers keep the override',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_service_notes_deliver_auth'
             AND p.prosrc LIKE '%auth.uid() IS NULL%' AND p.prosrc LIKE '%IS DISTINCT FROM ''deliver''%'),
         '1'
  UNION ALL
  SELECT 3, 'same test as the form: closed statuses, date window, context membership',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_service_notes_deliver_auth'
             AND p.prosrc LIKE '%''terminated''%' AND p.prosrc LIKE '%''canceled''%'
             AND p.prosrc LIKE '%a.start_date <= NEW.service_date%' AND p.prosrc LIKE '%m.end_date IS NULL%'),
         '1'
  UNION ALL
  SELECT 6, 'r1: service_notes.context_id present (the v19.2 prerequisite), with its index',
         (SELECT (EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = 'public' AND table_name = 'service_notes' AND column_name = 'context_id')
                  AND EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_notes_context'))::text),
         'true'
  UNION ALL
  SELECT 7, 'r1: an archived context authorizes nothing (context must be is_active = true)',
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_service_notes_deliver_auth'
             AND p.prosrc LIKE '%c.is_active = true%' AND p.prosrc LIKE '%v_ctx := NEW.context_id%'),
         '1'
  UNION ALL
  SELECT 4, 'service-note triggers now: lock, delete audit, front-line authorization',
         (SELECT string_agg(t.tgname, ', ' ORDER BY t.tgname) FROM pg_trigger t
           WHERE t.tgrelid = 'public.service_notes'::regclass AND NOT t.tgisinternal
             AND t.tgname IN ('service_notes_lock', 'service_notes_delete_audit', 'service_notes_deliver_auth')),
         'service_notes_delete_audit, service_notes_deliver_auth, service_notes_lock'
  UNION ALL
  SELECT 5, '(info) notes already on file with no covering authorization or context (any author; not blocked unless client/code/date/context change)',
         (SELECT count(*)::text FROM public.service_notes n
           WHERE NOT EXISTS (SELECT 1 FROM public.person_service_authorizations a
                              WHERE a.org_id = n.org_id AND a.person_id = n.person_id AND a.service_code_id = n.service_code_id
                                AND lower(a.status::text) NOT IN ('expired','closed','terminated','denied','inactive','cancelled','canceled')
                                AND a.start_date <= n.service_date AND a.end_date >= n.service_date)
             AND NOT EXISTS (SELECT 1 FROM public.service_delivery_contexts c
                               JOIN public.service_delivery_context_members m ON m.context_id = c.id
                              WHERE c.id = n.context_id AND c.org_id = n.org_id AND c.is_active = true
                                AND c.service_code_id = n.service_code_id AND m.person_id = n.person_id
                                AND m.is_active IS DISTINCT FROM false AND m.end_date IS NULL)),
         'read'
) v ORDER BY ord;
