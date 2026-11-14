-- ════════════════════════════════════════════════════════════════════
-- v20.0.49a — console: mark test accounts.
--
-- RUN IN SUPABASE (SQL editor) after Greptile 5/5, BEFORE merging. Safe to run twice.
--
--  1. platform_customer_meta.is_test (default false).
--  2. platform_customer_set_test(org, true/false): any active Provly team member with two-factor;
--     logged in platform_audit_log as test_flag_set. A new meta row starts at stage "paying" for a paid
--     account, "trial" otherwise.
--  3. platform_console_data: meta now includes is_test (otherwise unchanged).
-- Nothing is deleted: a test account only drops out of the console's numbers and filters.
-- ════════════════════════════════════════════════════════════════════

begin;

alter table public.platform_customer_meta add column if not exists is_test boolean not null default false;

-- Everything the console shows. Counts and business contact details only — never client records.
create or replace function public.platform_console_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.platform_staff;
begin
  v_me := public.platform_require(null);
  return jsonb_build_object(
    'me', jsonb_build_object('user_id', v_me.user_id, 'email', v_me.email, 'role', v_me.role,
                             'display_name', coalesce(v_me.display_name, v_me.email)),
    'team', (select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id,
                                         'name', coalesce(s.display_name, s.email), 'role', s.role)
                                       order by s.created_at), '[]'::jsonb)
             from public.platform_staff s where s.active),
    'customers', (select coalesce(jsonb_agg(c.item order by c.created_at desc), '[]'::jsonb) from (
      select o.created_at, jsonb_build_object(
        'id',            o.id,
        'name',          coalesce(nullif(o.legal_name, ''), o.name),
        'created_at',    o.created_at,
        'status',        o.subscription_status::text,
        'tier',          o.subscription_tier::text,
        'trial_ends_at', o.trial_ends_at,
        'phone',         o.phone,
        'email',         o.email,
        'owner', (select jsonb_build_object(
                    'name',  btrim(coalesce(s.first_name, '') || ' ' || coalesce(s.last_name, '')),
                    'email', coalesce(u.email, s.email))
                  from public.staff s left join auth.users u on u.id = s.user_id
                  where s.org_id = o.id and s.role::text = 'owner'
                  order by s.hire_date nulls last, s.id
                  limit 1),
        'source', (select jsonb_build_object('heard_via', x.heard_via, 'heard_detail', x.heard_detail,
                                             'first_touch', x.first_touch, 'signup_touch', x.signup_touch)
                   from public.org_signup_source x where x.org_id = o.id),
        'last_sign_in', (select max(u.last_sign_in_at)
                         from public.staff s join auth.users u on u.id = s.user_id
                         where s.org_id = o.id),
        'counts', jsonb_build_object(
          'staff',       (select count(*) from public.staff s         where s.org_id = o.id and s.is_active),
          'clients',     (select count(*) from public.persons p       where p.org_id = o.id and p.is_active),
          'notes_30d',   (select count(*) from public.service_notes n where n.org_id = o.id
                            and n.service_date >= current_date - 30),
          'notes_total', (select count(*) from public.service_notes n where n.org_id = o.id),
          'evv_30d',     (select count(*) from public.evv_sessions e  where e.org_id = o.id
                            and e.clock_in_at >= now() - interval '30 days')),
        'meta', (select jsonb_build_object('stage', m.stage, 'next_follow_up', m.next_follow_up,
                                           'account_owner', m.account_owner, 'is_test', m.is_test)
                 from public.platform_customer_meta m where m.org_id = o.id),
        'notes_count', (select count(*) from public.platform_customer_notes pn where pn.org_id = o.id)
      ) as item
      from public.organizations o) c));
end;
$$;

create or replace function public.platform_customer_set_test(p_org_id uuid, p_is_test boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.platform_staff;
  v_status text;
begin
  v_me := public.platform_require(null);
  if p_is_test is null then
    raise exception 'Say whether this is a test account' using errcode = '22023';
  end if;
  select o.subscription_status::text into v_status from public.organizations o where o.id = p_org_id;
  if not found then
    raise exception 'No such customer' using errcode = '22023';
  end if;
  insert into public.platform_customer_meta (org_id, stage, is_test, updated_at, updated_by)
  values (p_org_id, case when v_status = 'active' then 'paying' else 'trial' end, p_is_test, now(), v_me.user_id)
  on conflict (org_id) do update
    set is_test = excluded.is_test, updated_at = now(), updated_by = v_me.user_id;
  insert into public.platform_audit_log (actor, action, org_id, detail)
  values (v_me.user_id, 'test_flag_set', p_org_id, jsonb_build_object('is_test', p_is_test));
end;
$$;

revoke execute on function public.platform_customer_set_test(uuid, boolean) from public;
revoke execute on function public.platform_customer_set_test(uuid, boolean) from anon;
grant  execute on function public.platform_customer_set_test(uuid, boolean) to authenticated;

commit;
