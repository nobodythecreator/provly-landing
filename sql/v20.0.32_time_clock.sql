-- =====================================================================================
-- sql/v20.0.32_time_clock.sql
-- Provly pay engine — R1b part 1: the time clock (pay-engine Decision 15)
--
-- A staff-level clock for work EVV doesn't cover: nursing visits and other non-EVV service, indirect
-- service, training, meetings and admin. One GPS point at punch in and one at punch out — never
-- continuous tracking — and location is optional: hours are recorded even when the device can't
-- give a location. EVV sessions are untouched and count as worked time on their own; a punch can't
-- start while the staff member has an open EVV visit (the app closes an open punch when an EVV visit
-- starts). The weekly calculation (R1c) merges punches and EVV sessions so time is never counted twice.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction:
--   preflight → tables → functions → RLS + grants → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

-- -------------------------------------------------------------------------------------
-- 0. Preflight
-- -------------------------------------------------------------------------------------
do $pre$
begin
  if to_regclass('public.pay_policies') is null then
    raise exception 'v20.0.32 preflight: the pay engine (v20.0.31) has not run';
  end if;
  if to_regclass('public.time_punches') is not null then
    raise exception 'v20.0.32 preflight: time_punches already exists — this migration has already run';
  end if;
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then
    raise exception 'v20.0.32 preflight: btree_gist extension missing';
  end if;
  if not exists (
    select 1 from pg_index i
    where i.indrelid = 'public.persons'::regclass and i.indisunique and i.indpred is null
      and (select array_agg(a.attname::text order by a.attname)
           from unnest(i.indkey::int2[]) as k(attnum)
           join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum) = array['id','org_id']
  ) then
    raise exception 'v20.0.32 preflight: persons needs a unique index on (id, org_id)';
  end if;
  if to_regprocedure('public.can_see_person(uuid)') is null
     or to_regprocedure('public._pay_audit(uuid,text,text,uuid,jsonb,jsonb,uuid)') is null then
    raise exception 'v20.0.32 preflight: expected can_see_person(uuid) and _pay_audit(...)';
  end if;
end
$pre$;

-- -------------------------------------------------------------------------------------
-- 1. Tables
-- -------------------------------------------------------------------------------------
create table time_punches (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references organizations(id) on delete cascade,
  staff_id              uuid not null,
  work_type             text not null check (work_type in ('service','indirect','training','meeting','admin')),
  person_id             uuid,
  service_code_id       uuid references service_code_definitions(id),
  shift_id              uuid references shifts(id) on delete set null,
  clock_in_at           timestamptz not null,
  clock_out_at          timestamptz,
  clock_in_lat          numeric(9,6) check (clock_in_lat between -90 and 90),
  clock_in_lng          numeric(9,6) check (clock_in_lng between -180 and 180),
  clock_out_lat         numeric(9,6) check (clock_out_lat between -90 and 90),
  clock_out_lng         numeric(9,6) check (clock_out_lng between -180 and 180),
  original_clock_in_at  timestamptz,
  original_clock_out_at timestamptz,
  note                  text,
  created_at            timestamptz not null default now(),
  foreign key (staff_id, org_id)  references staff(id, org_id),
  foreign key (person_id, org_id) references persons(id, org_id),
  check (clock_out_at is null or clock_out_at > clock_in_at),
  check (work_type not in ('service','indirect') or service_code_id is not null),
  check (work_type in ('service','indirect') or (person_id is null and service_code_id is null)),
  check ((clock_in_lat is null) = (clock_in_lng is null)),
  check ((clock_out_lat is null) = (clock_out_lng is null)),
  -- One stretch of time per staff member: punches never overlap, and an open punch
  -- (no clock-out yet) blocks a second one.
  constraint time_punches_no_overlap
    exclude using gist (staff_id with =, tstzrange(clock_in_at, clock_out_at, '[)') with &&)
);

create index time_punches_org_clock_in on time_punches (org_id, clock_in_at desc);

create table time_punch_edit_log (
  id                 uuid primary key default gen_random_uuid(),
  org_id             uuid not null references organizations(id) on delete cascade,
  punch_id           uuid not null references time_punches(id) on delete cascade,
  field              text not null check (field in ('clock_in_at','clock_out_at')),
  old_value          timestamptz,
  new_value          timestamptz,
  reason             text not null check (length(btrim(reason)) > 0),
  edited_by_user_id  uuid,
  edited_by_staff_id uuid,
  edited_at          timestamptz not null default now(),
  foreign key (edited_by_staff_id, org_id) references staff(id, org_id)
);

-- -------------------------------------------------------------------------------------
-- 2. Internal functions (explicit org + staff; never callable by clients)
-- -------------------------------------------------------------------------------------
create function _time_clock_in(p_org uuid, p_staff uuid, p_work_type text, p_person uuid,
                               p_service_code text, p_shift uuid, p_lat numeric, p_lng numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code uuid;
  v_evv  boolean;
  v_id   uuid;
begin
  if not exists (select 1 from staff where id = p_staff and org_id = p_org and is_active) then
    raise exception 'staff member not found or inactive' using errcode = 'P0002';
  end if;
  if p_work_type is null or p_work_type not in ('service','indirect','training','meeting','admin') then
    raise exception 'unknown work type %', p_work_type using errcode = '23514';
  end if;
  if exists (select 1 from evv_sessions e
             where e.staff_id = p_staff and e.org_id = p_org and e.clock_out_at is null) then
    raise exception 'clock out of your open EVV visit before starting other work' using errcode = '23514';
  end if;
  if p_work_type in ('service','indirect') then
    if p_service_code is null then
      raise exception 'a service code is required for % work', p_work_type using errcode = '23514';
    end if;
    select id, evv_required into v_code, v_evv from service_code_definitions where code = p_service_code;
    if v_code is null then
      raise exception 'unknown service code %', p_service_code using errcode = '23514';
    end if;
    if p_work_type = 'service' and v_evv then
      raise exception '% is an EVV code — use the EVV clock for it', p_service_code using errcode = '23514';
    end if;
  elsif p_person is not null or p_service_code is not null then
    raise exception '% work has no client or service code', p_work_type using errcode = '23514';
  end if;
  if p_shift is not null and not exists (
    select 1 from shifts where id = p_shift and org_id = p_org and staff_id = p_staff
  ) then
    raise exception 'shift not found for this staff member' using errcode = 'P0002';
  end if;
  if (p_lat is null) <> (p_lng is null) then
    raise exception 'a location needs both latitude and longitude' using errcode = '23514';
  end if;

  begin
    insert into time_punches (org_id, staff_id, work_type, person_id, service_code_id, shift_id,
                              clock_in_at, clock_in_lat, clock_in_lng, note)
    values (p_org, p_staff, p_work_type, p_person, v_code, p_shift,
            clock_timestamp(), p_lat, p_lng, nullif(btrim(coalesce(p_note, '')), ''))
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'you already have an open time punch — clock out of it first' using errcode = '23514';
  end;

  perform _pay_audit(p_org, 'time_punch_in', 'time_punches', v_id, null,
                     (select to_jsonb(t) from time_punches t where t.id = v_id), p_staff);
  return v_id;
end
$$;

create function _time_clock_out(p_org uuid, p_staff uuid, p_punch uuid, p_lat numeric, p_lng numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb;
begin
  select to_jsonb(t) into v_old from time_punches t
  where t.id = p_punch and t.org_id = p_org and t.staff_id = p_staff and t.clock_out_at is null
  for update;
  if v_old is null then
    raise exception 'open time punch not found' using errcode = 'P0002';
  end if;
  if (p_lat is null) <> (p_lng is null) then
    raise exception 'a location needs both latitude and longitude' using errcode = '23514';
  end if;
  update time_punches
     set clock_out_at = clock_timestamp(), clock_out_lat = p_lat, clock_out_lng = p_lng
   where id = p_punch;
  perform _pay_audit(p_org, 'time_punch_out', 'time_punches', p_punch, v_old,
                     (select to_jsonb(t) from time_punches t where t.id = p_punch), p_staff);
end
$$;

create function _time_correct_punch(p_org uuid, p_actor_staff uuid, p_actor_user uuid, p_punch uuid,
                                    p_clock_in timestamptz, p_clock_out timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r        time_punches;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then
    raise exception 'a reason is required' using errcode = '23514';
  end if;
  if p_clock_in is null and p_clock_out is null then
    raise exception 'nothing to change' using errcode = '23514';
  end if;
  select * into r from time_punches where id = p_punch and org_id = p_org for update;
  if not found then
    raise exception 'time punch not found' using errcode = 'P0002';
  end if;

  begin
    update time_punches set
      original_clock_in_at  = coalesce(original_clock_in_at,  case when p_clock_in  is not null then clock_in_at  end),
      original_clock_out_at = coalesce(original_clock_out_at, case when p_clock_out is not null then clock_out_at end),
      clock_in_at  = coalesce(p_clock_in,  clock_in_at),
      clock_out_at = coalesce(p_clock_out, clock_out_at)
    where id = p_punch;
  exception when exclusion_violation then
    raise exception 'the corrected times overlap another punch for this staff member' using errcode = '23514';
  end;

  if p_clock_in is not null and p_clock_in is distinct from r.clock_in_at then
    insert into time_punch_edit_log (org_id, punch_id, field, old_value, new_value, reason,
                                     edited_by_user_id, edited_by_staff_id)
    values (p_org, p_punch, 'clock_in_at', r.clock_in_at, p_clock_in, v_reason, p_actor_user, p_actor_staff);
  end if;
  if p_clock_out is not null and p_clock_out is distinct from r.clock_out_at then
    insert into time_punch_edit_log (org_id, punch_id, field, old_value, new_value, reason,
                                     edited_by_user_id, edited_by_staff_id)
    values (p_org, p_punch, 'clock_out_at', r.clock_out_at, p_clock_out, v_reason, p_actor_user, p_actor_staff);
  end if;

  perform _pay_audit(p_org, 'time_punch_fix', 'time_punches', p_punch, to_jsonb(r),
                     (select to_jsonb(t) || jsonb_build_object('reason', v_reason)
                      from time_punches t where t.id = p_punch), p_actor_staff);
end
$$;

-- -------------------------------------------------------------------------------------
-- 3. Client-facing RPCs
-- -------------------------------------------------------------------------------------
-- Any member with a staff record clocks themselves in and out.
create function time_clock_in(p_work_type text, p_person uuid default null, p_service_code text default null,
                              p_shift uuid default null, p_lat numeric default null, p_lng numeric default null,
                              p_note text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_staff uuid := my_staff_id();
begin
  if (select member_role()) is null or v_staff is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_person is not null
     and not ((select access_tier()) in ('manage','operate') or can_see_person(p_person)) then
    raise exception 'not permitted for this client' using errcode = '42501';
  end if;
  return _time_clock_in(org_id(), v_staff, p_work_type, p_person, p_service_code, p_shift, p_lat, p_lng, p_note);
end
$$;

create function time_clock_out(p_punch uuid, p_lat numeric default null, p_lng numeric default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_staff uuid := my_staff_id();
begin
  if (select member_role()) is null or v_staff is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform _time_clock_out(org_id(), v_staff, p_punch, p_lat, p_lng);
end
$$;

-- Managers and supervisors correct punches (e.g., a forgotten clock-out). Nobody corrects their own
-- punch except the owner; every change keeps the original time and a reason.
create function time_correct_punch(p_punch uuid, p_clock_in timestamptz default null,
                                   p_clock_out timestamptz default null, p_reason text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if (select access_tier()) is distinct from 'manage' and (select access_tier()) is distinct from 'operate' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if (select member_role()) is distinct from 'owner' and exists (
    select 1 from time_punches t where t.id = p_punch and t.staff_id = v_actor
  ) then
    raise exception 'another manager must correct your own time punch' using errcode = '42501';
  end if;
  perform _time_correct_punch(org_id(), v_actor, auth.uid(), p_punch, p_clock_in, p_clock_out, p_reason);
end
$$;

-- -------------------------------------------------------------------------------------
-- 4. RLS + grants
-- -------------------------------------------------------------------------------------
alter table time_punches enable row level security;
alter table time_punch_edit_log enable row level security;

do $rls$
declare
  t text;
  f record;
begin
  foreach t in array array['time_punches','time_punch_edit_log'] loop
    execute format('revoke all on table %I from anon, public', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on table %I from authenticated', t);
    execute format('grant select on table %I to authenticated', t);
    execute format(
      'create policy %I on %I as restrictive for all to authenticated '
      'using (org_id = (select org_id()) and (select member_role()) is not null) '
      'with check (org_id = (select org_id()) and (select member_role()) is not null)',
      t || '_tenant_guard', t);
  end loop;

  create policy time_punches_read on time_punches for select to authenticated
    using ((select access_tier()) in ('manage','operate') or staff_id = (select my_staff_id()));
  create policy time_punch_edit_log_read on time_punch_edit_log for select to authenticated
    using ((select access_tier()) in ('manage','operate')
           or exists (select 1 from time_punches p
                      where p.id = time_punch_edit_log.punch_id and p.staff_id = (select my_staff_id())));

  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('_time_clock_in','_time_clock_out','_time_correct_punch',
                        'time_clock_in','time_clock_out','time_correct_punch')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if left(f.proname, 1) <> '_' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end
$rls$;

-- -------------------------------------------------------------------------------------
-- 5. Self-test — always rolled back; a failed check raises 'SELFTEST FAIL' and aborts everything
-- -------------------------------------------------------------------------------------
do $test$
declare
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_owner  uuid;
  v_staff  uuid;
  v_person uuid;
  v_a      uuid;
  v_b      uuid;
  v_in     timestamptz;
  v_evv    text;
  v_nonevv text;
begin
  select s.id into v_owner
  from org_members m join staff s on s.user_id = m.user_id and s.org_id = m.org_id
  where m.org_id = v_org and m.role = 'owner'
  order by m.joined_at, s.id limit 1;
  -- a staff member with no open EVV visit right now
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from evv_sessions e where e.staff_id = s.id and e.clock_out_at is null)
  order by s.created_at, s.id limit 1;
  select id into v_person from persons where org_id = v_org and is_active order by created_at, id limit 1;
  select code into v_evv    from service_code_definitions where evv_required     order by code limit 1;
  select code into v_nonevv from service_code_definitions where not evv_required order by code limit 1;
  if v_staff is null or v_person is null or v_evv is null or v_nonevv is null then
    raise exception 'SELFTEST FAIL 0: needs an active staff member without an open EVV visit, an active Person, and EVV + non-EVV codes';
  end if;

  begin
    -- 1. Training punch with no location: hours are recorded without GPS
    v_a := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
    if not exists (select 1 from time_punches where id = v_a and clock_out_at is null and clock_in_lat is null) then
      raise exception 'SELFTEST FAIL 1: training punch not open';
    end if;

    -- 2. A second punch while one is open is refused
    begin
      perform _time_clock_in(v_org, v_staff, 'meeting', null, null, null, null, null, 'self-test');
      raise exception 'SELFTEST FAIL 2: second open punch accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 3. Clock out closes it, after the clock-in
    perform _time_clock_out(v_org, v_staff, v_a, 40.700000, -111.900000);
    if not exists (select 1 from time_punches where id = v_a and clock_out_at > clock_in_at and clock_out_lat = 40.7) then
      raise exception 'SELFTEST FAIL 3: clock-out not recorded';
    end if;

    -- 4. An EVV code can't be punched as service
    begin
      perform _time_clock_in(v_org, v_staff, 'service', v_person, v_evv, null, null, null, 'self-test');
      raise exception 'SELFTEST FAIL 4: EVV code accepted on the time clock';
    exception when sqlstate '23514' then null;
    end;

    -- 5. A non-EVV service visit with a Person and a location works
    v_b := _time_clock_in(v_org, v_staff, 'service', v_person, v_nonevv, null, 40.710000, -111.880000, 'self-test');
    perform _time_clock_out(v_org, v_staff, v_b, 40.720000, -111.870000);

    -- 6. Training can't carry a client
    begin
      perform _time_clock_in(v_org, v_staff, 'training', v_person, null, null, null, null, 'self-test');
      raise exception 'SELFTEST FAIL 6: training punch with a client accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 7. Half a location is refused
    begin
      perform _time_clock_in(v_org, v_staff, 'admin', null, null, null, 40.7, null, 'self-test');
      raise exception 'SELFTEST FAIL 7: latitude without longitude accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 8. A correction keeps the original time and logs the change
    select clock_in_at into v_in from time_punches where id = v_a;
    perform _time_correct_punch(v_org, v_owner, null, v_a, v_in - interval '1 hour', null, 'self-test: started earlier');
    if not exists (select 1 from time_punches where id = v_a and original_clock_in_at = v_in
                   and clock_in_at = v_in - interval '1 hour')
       or not exists (select 1 from time_punch_edit_log where punch_id = v_a and field = 'clock_in_at') then
      raise exception 'SELFTEST FAIL 8: correction not preserved or not logged';
    end if;

    -- 9. A correction needs a reason
    begin
      perform _time_correct_punch(v_org, v_owner, null, v_a, v_in, null, '  ');
      raise exception 'SELFTEST FAIL 9: correction without a reason accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 10. A correction that overlaps another punch is refused
    begin
      perform _time_correct_punch(v_org, v_owner, null, v_b, v_in - interval '30 minutes', null, 'self-test: overlap');
      raise exception 'SELFTEST FAIL 10: overlapping correction accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 11. Without a signed-in session the client RPCs refuse
    begin
      perform time_clock_in('training');
      raise exception 'SELFTEST FAIL 11: time_clock_in ran without a session';
    exception when insufficient_privilege then null;
    end;
    begin
      perform time_correct_punch(v_a, now(), null, 'self-test');
      raise exception 'SELFTEST FAIL 11b: time_correct_punch ran without a session';
    exception when insufficient_privilege then null;
    end;

    raise exception 'SELFTEST_ROLLBACK' using errcode = 'PRVOK';
  exception when sqlstate 'PRVOK' then
    null;  -- every self-test write above is rolled back here
  end;
end
$test$;

commit;

-- -------------------------------------------------------------------------------------
-- 6. Verification table (paste this result into the PR and the chat)
-- -------------------------------------------------------------------------------------
with checks as (
  select 1 as n, 'Time clock tables' as check_name,
         (select count(*) from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
          where ns.nspname = 'public' and c.relname in ('time_punches','time_punch_edit_log'))::text as got, '2' as want
  union all
  select 2, 'No-overlap constraint on punches',
         (select count(*) from pg_constraint where conname = 'time_punches_no_overlap')::text, '1'
  union all
  select 3, 'RLS enabled on both tables',
         (select count(*) from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
          where ns.nspname = 'public' and c.relname in ('time_punches','time_punch_edit_log') and c.relrowsecurity)::text, '2'
  union all
  select 4, 'Policies on time clock tables',
         (select count(*) from pg_policies where schemaname = 'public'
          and tablename in ('time_punches','time_punch_edit_log'))::text, '4'
  union all
  select 5, 'Internal time functions callable by clients',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname in ('_time_clock_in','_time_clock_out','_time_correct_punch')
            and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or has_function_privilege('anon', p.oid, 'EXECUTE')))::text, '0'
  union all
  select 6, 'Time clock RPCs callable by signed-in users (not anon)',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname in ('time_clock_in','time_clock_out','time_correct_punch')
            and has_function_privilege('authenticated', p.oid, 'EXECUTE')
            and not has_function_privilege('anon', p.oid, 'EXECUTE'))::text, '3'
  union all
  select 7, 'Clients cannot write punches directly',
         (has_table_privilege('authenticated', 'public.time_punches', 'INSERT')
          or has_table_privilege('authenticated', 'public.time_punches', 'UPDATE'))::text, 'false'
  union all
  select 8, 'Anon can read punches', (has_table_privilege('anon', 'public.time_punches', 'SELECT'))::text, 'false'
  union all
  select 9, 'Self-test leftovers (punches)', (select count(*) from time_punches)::text, '0'
  union all
  select 10, 'EVV sessions untouched (no new triggers on evv_sessions)',
         (select count(*) from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
          where tg.tgrelid = 'public.evv_sessions'::regclass and not tg.tgisinternal
            and p.proname like '%time%')::text, '0'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
