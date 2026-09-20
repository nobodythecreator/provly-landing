-- ============================================================================
-- Provly v20.0.13c — co-staff on a service note without the roster
-- Run in the Supabase SQL editor (production) BEFORE the app ships. Idempotent.
--
-- Dry-run finding (Sep 19): the service-note form's "Additional staff on
-- shift" picker listed every active name for a front-line login. B3's
-- directory view is for names ON records; a picker that enumerates the org
-- is a roster. A DSP's legitimate co-staff are the people who share this
-- client with them (an open person edge, or a site edge to the home the
-- client is placed in) plus office-tier staff, who may cover any shift.
--
-- staff_sharing_person(p_person_id): SECURITY DEFINER, callable by any
-- member; returns nothing unless the CALLER can see the person; excludes the
-- caller's own row. Office tiers keep using staff_directory_v in the app.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.staff_sharing_person(p_person_id uuid)
RETURNS TABLE (id uuid, first_name text, last_name text, role public.user_role)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.first_name, s.last_name, s.role
  FROM public.staff s
  WHERE s.org_id = public.org_id()
    AND public.member_role() IS NOT NULL
    AND public.can_see_person(p_person_id)                       -- the caller must see the person
    AND s.is_active
    AND s.id IS DISTINCT FROM public.my_staff_id()
    AND (public.role_tier(s.role) IN ('manage', 'operate')       -- office staff may cover any shift
         OR public.staff_sees_person(s.id, s.org_id, p_person_id))  -- front-line coworkers on this client
  ORDER BY s.last_name, s.first_name
$$;
REVOKE ALL ON FUNCTION public.staff_sharing_person(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_sharing_person(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.staff_sharing_person(uuid) IS
  'v20.0.13c — co-staff candidates for a service note: active staff who share sight of the person (edges) plus office tiers; empty unless the caller can see the person; excludes the caller.';

NOTIFY pgrst, 'reload schema';

-- Verification
SELECT check_name, value, want FROM (
  SELECT 1 AS ord, 'staff_sharing_person exists, SECURITY DEFINER, gated on can_see_person + excludes caller' AS check_name,
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'staff_sharing_person' AND p.prosecdef
             AND p.prosrc LIKE '%can_see_person(p_person_id)%' AND p.prosrc LIKE '%IS DISTINCT FROM public.my_staff_id()%'
             AND p.prosrc LIKE '%staff_sees_person(s.id, s.org_id, p_person_id)%') AS value,
         '1' AS want
  UNION ALL
  SELECT 2, 'grants: authenticated may execute, anon may not',
         (SELECT (has_function_privilege('authenticated', 'public.staff_sharing_person(uuid)', 'EXECUTE')
                  AND NOT has_function_privilege('anon', 'public.staff_sharing_person(uuid)', 'EXECUTE'))::text),
         'true'
  UNION ALL
  SELECT 3, '(info) run as the SQL editor (no login) the function returns no rows',
         (SELECT count(*)::text FROM public.staff_sharing_person((SELECT id FROM public.persons WHERE is_active LIMIT 1))),
         '0'
) v ORDER BY ord;
