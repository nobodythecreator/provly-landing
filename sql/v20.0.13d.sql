-- ============================================================================
-- Provly v20.0.13d — co-staff = only the people who share the client
-- Run in the Supabase SQL editor (production). Idempotent (CREATE OR REPLACE).
--
-- Dry run, Sep 19: v20.0.13c also listed office-tier staff as co-staff
-- candidates for a front-line login (a supervisor may cover a shift). The
-- provider's rule is narrower and it is the right one: a front-line login sees
-- the people who share its client — an open person edge, or a site edge to
-- the home the client is placed in — and no one else. Office tiers never call
-- this function (the app gives them the directory).
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
    AND public.can_see_person(p_person_id)                        -- the caller must see the person
    AND s.is_active
    AND s.id IS DISTINCT FROM public.my_staff_id()
    AND public.staff_sees_person(s.id, s.org_id, p_person_id)     -- shares the client: person edge, or site edge + placement
  ORDER BY s.last_name, s.first_name
$$;
COMMENT ON FUNCTION public.staff_sharing_person(uuid) IS
  'v20.0.13d — co-staff candidates for a service note: active staff who share sight of the person through an edge (person edge, or site edge to the home the person is placed in); empty unless the caller can see the person; excludes the caller. No office-tier branch.';

NOTIFY pgrst, 'reload schema';

SELECT check_name, value, want FROM (
  SELECT 1 AS ord, 'staff_sharing_person: edge-sharing only (no office-tier branch), gated on can_see_person, excludes caller' AS check_name,
         (SELECT count(*)::text FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'staff_sharing_person' AND p.prosecdef
             AND p.prosrc LIKE '%staff_sees_person(s.id, s.org_id, p_person_id)%'
             AND p.prosrc NOT LIKE '%role_tier(s.role)%'
             AND p.prosrc LIKE '%can_see_person(p_person_id)%'
             AND p.prosrc LIKE '%IS DISTINCT FROM public.my_staff_id()%') AS value,
         '1' AS want
  UNION ALL
  SELECT 2, 'grants unchanged: authenticated may execute, anon may not',
         (SELECT (has_function_privilege('authenticated', 'public.staff_sharing_person(uuid)', 'EXECUTE')
                  AND NOT has_function_privilege('anon', 'public.staff_sharing_person(uuid)', 'EXECUTE'))::text),
         'true'
) v ORDER BY ord;
