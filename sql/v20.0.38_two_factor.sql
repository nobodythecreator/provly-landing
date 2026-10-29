-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 — AND AFTER THE APP (v20.0.38) IS MERGED AND DEPLOYED ⚠
-- =====================================================================================
-- sql/v20.0.38_two_factor.sql
-- Two-factor sign-in, enforced by the database (PBA SSN design, two-factor decisions A / A / B)
--
-- The Owner and the Compliance Director must sign in with an authenticator code. The app asks for
-- it, but the app is not the lock: this file makes the database itself refuse them until the
-- session carries the verified level (aal2) in its signed token.
--
-- How: every access rule in Provly runs through four helpers — org_id(), member_role(),
-- access_tier(), my_staff_id(). Each keeps its name (so every existing rule keeps using it) and its
-- original logic moves, unchanged, to a _base copy. The public helper now returns the base value
-- only when two-factor is satisfied, and NULL otherwise — and NULL means no access everywhere.
-- Two-factor is satisfied when: there is no signed-in user (server-side work, unchanged), or the
-- session is aal2, or the user holds none of the roles that require it.
--
-- mfa_required() tells the app whether to ask for a code (it reads only the caller's own roles).
-- Lost phone, backup lost too: reset in the Supabase dashboard (decision B) — Authentication →
-- Users → the person → remove their authenticator factors. Provly has no reset button.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction: preflight → wrap the helpers →
-- self-test (no writes) → COMMIT → verification table.
-- Emergency only: sql/v20.0.38-undo.sql puts the helpers back exactly as they were.
-- =====================================================================================

begin;

do $pre$
declare
  f text;
begin
  foreach f in array array['org_id','member_role','access_tier','my_staff_id'] loop
    if to_regprocedure(format('public.%I()', f)) is null then
      raise exception 'v20.0.38 preflight: public.%() not found', f;
    end if;
  end loop;
  if to_regprocedure('public._mfa_satisfied()') is not null then
    raise exception 'v20.0.38 preflight: this migration has already run';
  end if;
end
$pre$;

-- The roles that must use two-factor. (v20.0.39 can read these from the "who can see SSNs" setting.)
create function public._mfa_roles()
returns text[] language sql immutable as $$
  select array['owner', 'compliance_director']::text[]
$$;

create function public._mfa_required_for(p_user uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from org_members m
                 where m.user_id = p_user and m.role::text = any (public._mfa_roles()))
$$;

-- true when two-factor doesn't stand in the way: no signed-in user, a verified (aal2) session, or a
-- user whose roles don't require it. The aal claim is checked first, so verified sessions cost nothing.
-- One narrow allowance: the very transaction that creates the user's own membership (signing up a new
-- organization, accepting an invite) may finish its work — it compares the membership row's creating
-- transaction with the current one, without assigning a transaction id, so it is false everywhere else.
-- The next request already needs the code.
create function public._mfa_satisfied()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is null
      or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      or not public._mfa_required_for(auth.uid())
      or exists (select 1 from org_members m
                 where m.user_id = auth.uid()
                   and m.xmin::text = (pg_current_xact_id_if_assigned()::xid)::text)
$$;

-- For the app: does the signed-in user need to give a code? (Their own roles only.)
create function public.mfa_required()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and public._mfa_required_for(auth.uid())
$$;

-- Wrap the four helpers. Each original body is copied, unchanged, to <name>_base; the public name keeps
-- its identity (every access rule refers to it) and now passes the base value through only when
-- two-factor is satisfied.
do $wrap$
declare
  f      text;
  v_proc regprocedure;
  v_def  text;
  v_ret  text;
  v_base text;
begin
  foreach f in array array['org_id','member_role','access_tier','my_staff_id'] loop
    v_proc := format('public.%I()', f)::regprocedure;
    v_def  := pg_get_functiondef(v_proc);
    v_ret  := pg_get_function_result(v_proc);
    v_base := '_' || f || '_base';
    if position(format('FUNCTION public.%s()', f) in v_def) = 0 then
      raise exception 'v20.0.38: unexpected definition header for %()', f;
    end if;
    execute replace(v_def, format('FUNCTION public.%s()', f), format('FUNCTION public.%s()', v_base));
    execute format('revoke all on function public.%I() from public, anon, authenticated', v_base);
    execute format($fn$
      create or replace function public.%I()
      returns %s language sql stable security definer set search_path = public, pg_temp as $body$
        select case when public._mfa_satisfied() then public.%I() end
      $body$ $fn$, f, v_ret, v_base);
  end loop;
end
$wrap$;

do $grant$
begin
  revoke all on function public._mfa_roles() from public, anon, authenticated;
  revoke all on function public._mfa_required_for(uuid) from public, anon, authenticated;
  revoke all on function public._mfa_satisfied() from public, anon, authenticated;
  revoke all on function public.mfa_required() from public, anon;
  grant execute on function public.mfa_required() to authenticated;
end
$grant$;

-- -------------------------------------------------------------------------------------
-- Self-test — reads only (no writes). Plays a signed-in Owner at aal1 and aal2, a member whose role
-- doesn't require two-factor, and no session, and checks each helper's answer.
-- -------------------------------------------------------------------------------------
do $test$
declare
  v_org   constant uuid := '00000000-0000-0000-0000-000000000001';
  v_owner uuid;
  v_other uuid;
begin
  select m.user_id into v_owner from org_members m where m.org_id = v_org and m.role::text = 'owner' order by m.joined_at limit 1;
  select m.user_id into v_other from org_members m
   where m.org_id = v_org and not (m.role::text = any (public._mfa_roles())) order by m.joined_at limit 1;
  if v_owner is null then
    raise exception 'SELFTEST FAIL 0: no owner membership to test with';
  end if;

  -- 1. Owner, password only (aal1): every helper answers NULL — no access anywhere
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  if public.org_id() is not null or public.member_role() is not null or public.access_tier() is not null or public.my_staff_id() is not null then
    raise exception 'SELFTEST FAIL 1: an Owner without two-factor still got an answer';
  end if;
  if not public.mfa_required() then
    raise exception 'SELFTEST FAIL 1b: mfa_required() is false for an Owner';
  end if;

  -- 2. Owner, verified (aal2): every helper answers exactly as before
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if public.org_id() is distinct from public._org_id_base()
     or public.member_role()::text is distinct from public._member_role_base()::text or public.member_role() is null
     or public.access_tier()::text is distinct from public._access_tier_base()::text
     or public.my_staff_id() is distinct from public._my_staff_id_base() then
    raise exception 'SELFTEST FAIL 2: a verified Owner did not get the same answers as before';
  end if;

  -- 3. A member whose role doesn't require two-factor, password only: unchanged (skipped if none exists)
  if v_other is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_other, 'role', 'authenticated', 'aal', 'aal1')::text, true);
    if public.member_role()::text is distinct from public._member_role_base()::text
       or public.access_tier()::text is distinct from public._access_tier_base()::text
       or public.org_id() is distinct from public._org_id_base()
       or public.my_staff_id() is distinct from public._my_staff_id_base() then
      raise exception 'SELFTEST FAIL 3: a member who needs no two-factor lost access';
    end if;
    if public.mfa_required() then
      raise exception 'SELFTEST FAIL 3b: mfa_required() is true for a role that does not need it';
    end if;
  end if;

  -- 4. No signed-in user (server-side work): two-factor never stands in the way
  perform set_config('request.jwt.claims', '{}', true);
  if not public._mfa_satisfied() then
    raise exception 'SELFTEST FAIL 4: server-side work was blocked';
  end if;
end
$test$;

select set_config('request.jwt.claims', '{}', true);

commit;

-- -------------------------------------------------------------------------------------
-- Verification table (paste this result into the PR and the chat)
-- -------------------------------------------------------------------------------------
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok from (
  select 1 n, 'The four helpers check two-factor first' check_name,
    (select count(*) from unnest(array['org_id','member_role','access_tier','my_staff_id']) f
      where position('_mfa_satisfied' in pg_get_functiondef(format('public.%I()', f)::regprocedure)) > 0)::text got, '4' want
  union all select 2, 'Original logic kept in _base copies',
    (select count(*) from pg_proc where proname in ('_org_id_base','_member_role_base','_access_tier_base','_my_staff_id_base'))::text, '4'
  union all select 3, '_base copies and internals not callable by clients',
    (select count(*) from pg_proc where proname in ('_org_id_base','_member_role_base','_access_tier_base','_my_staff_id_base',
                                                     '_mfa_roles','_mfa_required_for','_mfa_satisfied')
       and (has_function_privilege('authenticated', oid, 'EXECUTE') or has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  union all select 4, 'mfa_required() for signed-in users (not anon)',
    (has_function_privilege('authenticated', 'public.mfa_required()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.mfa_required()', 'EXECUTE'))::text, 'true'
  union all select 5, 'Roles that require two-factor',
    array_to_string(public._mfa_roles(), ', '), 'owner, compliance_director'
) t
order by n;
