-- ============================================================================
-- Provly v20.0.20 — manager delete for unapproved service notes (D1 = A)
-- Run in the Supabase SQL editor (production) BEFORE the app ships. Idempotent.
--
--   • service_notes DELETE: manage tier, and only a DRAFT or REJECTED note.
--     A submitted note is rejected first, so the review is on record before
--     anything is removed. Approved stay locked (C1); billed are never deleted
--     (the v20.0.13 predicate — status IS DISTINCT FROM 'approved' — allowed
--     billed; this closes that).
--   • Every delete writes audit_log ('note_deleted') with the whole note as
--     old_data — from the database, so it cannot be skipped. Service-role /
--     SQL-editor deletes are logged too (user_id NULL).
-- ============================================================================

DROP POLICY IF EXISTS service_notes_delete_tier ON public.service_notes;
CREATE POLICY service_notes_delete_tier ON public.service_notes
  AS PERMISSIVE FOR DELETE TO authenticated
  USING ((SELECT public.access_tier()) = 'manage' AND status IN ('draft', 'rejected'));

CREATE OR REPLACE FUNCTION public.trg_service_notes_delete_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.audit_log (org_id, user_id, action, table_name, record_id, old_data, new_data)
  VALUES (OLD.org_id, auth.uid(), 'note_deleted', 'service_notes', OLD.id, to_jsonb(OLD),
          jsonb_build_object('deleted_by_staff_id', public.my_staff_id()));
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_service_notes_delete_audit() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS service_notes_delete_audit ON public.service_notes;
CREATE TRIGGER service_notes_delete_audit
  AFTER DELETE ON public.service_notes
  FOR EACH ROW EXECUTE FUNCTION public.trg_service_notes_delete_audit();

NOTIFY pgrst, 'reload schema';

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification — one statement. Paste the whole result.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT check_name, value, want FROM (
  SELECT 1 AS ord, 'service_notes DELETE: one policy, manage + draft/rejected only' AS check_name,
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = 'service_notes' AND p.permissive = 'PERMISSIVE' AND p.cmd = 'DELETE'
             AND p.qual LIKE '%''manage''%' AND p.qual LIKE '%draft%' AND p.qual LIKE '%rejected%'
             AND p.qual NOT LIKE '%approved%' AND p.qual NOT LIKE '%submitted%') || ' of ' ||
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = 'service_notes' AND p.permissive = 'PERMISSIVE' AND p.cmd IN ('DELETE', 'ALL')) AS value,
         '1 of 1' AS want
  UNION ALL
  SELECT 2, 'delete audit trigger present (AFTER DELETE on service_notes)',
         (SELECT count(*)::text FROM pg_trigger t
           WHERE t.tgrelid = 'public.service_notes'::regclass AND t.tgname = 'service_notes_delete_audit' AND NOT t.tgisinternal),
         '1'
  UNION ALL
  SELECT 3, 'trigger writes note_deleted with the whole note (fits audit_log.action)',
         (SELECT (count(*) = 1 AND length('note_deleted') <= 20)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_service_notes_delete_audit'
             AND p.prosrc LIKE '%''note_deleted''%' AND p.prosrc LIKE '%to_jsonb(OLD)%'),
         'true'
  UNION ALL
  SELECT 4, 'v20.0.13 tier write policies still in place',
         (SELECT count(*)::text FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE' AND p.roles::text = '{authenticated}'
             AND p.policyname IN (p.tablename || '_insert_tier', p.tablename || '_update_tier', p.tablename || '_delete_tier')),
         '116'
  UNION ALL
  SELECT 5, '(info) notes a manager may delete today: draft / rejected',
         (SELECT (SELECT count(*) FROM public.service_notes WHERE status = 'draft')::text || ' / ' ||
                 (SELECT count(*) FROM public.service_notes WHERE status = 'rejected')::text),
         'read'
) v ORDER BY ord;
