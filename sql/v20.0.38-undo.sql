-- ⚠ EMERGENCY ONLY — run this ONLY if two-factor has locked the Owner or Compliance Director out and
-- the Supabase-dashboard reset (Authentication → Users → remove their factors) hasn't fixed it. ⚠
-- =====================================================================================
-- sql/v20.0.38-undo.sql
-- Puts the four access helpers back exactly as they were before v20.0.38: each public helper again
-- returns its original logic (kept in the _base copy) with no two-factor check. The _base copies and
-- mfa_required() stay, so v20.0.38's wrapping can be re-applied later by a new migration.
-- Run in the Supabase SQL editor (it runs as the database owner, so it is never locked out).
-- =====================================================================================
begin;

do $undo$
declare
  f     text;
  v_ret text;
begin
  foreach f in array array['org_id','member_role','access_tier','my_staff_id'] loop
    if to_regprocedure(format('public._%s_base()', f)) is null then
      raise exception 'undo: public._%_base() not found — v20.0.38 never ran', f;
    end if;
    v_ret := pg_get_function_result(format('public.%I()', f)::regprocedure);
    execute format($fn$
      create or replace function public.%I()
      returns %s language sql stable security definer set search_path = public, pg_temp as $body$
        select public.%I()
      $body$ $fn$, f, v_ret, '_' || f || '_base');
  end loop;
end
$undo$;

commit;

select f as helper, position('_mfa_satisfied' in pg_get_functiondef(format('public.%I()', f)::regprocedure)) = 0 as two_factor_check_removed
from unnest(array['org_id','member_role','access_tier','my_staff_id']) f;
