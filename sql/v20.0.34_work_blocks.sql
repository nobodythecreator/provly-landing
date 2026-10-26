-- =====================================================================================
-- sql/v20.0.34_work_blocks.sql
-- Provly pay engine — R1b part 2: scheduled non-service work, cancellation reasons, punch links
-- (pay-engine Decision 17; SL policy §1/§3.5; nursing policy §3.1)
--
--   1. shifts.cancellation_reason — 'no_fault' (Person, guardian or provider cancelled) or 'staff'.
--      No-fault cancellations leave scheduled hours (SL delivery qualifier); staff ones stay. A trigger
--      clears the reason whenever the shift is not cancelled, so it can never contradict the status.
--   2. work_blocks — scheduled training, meetings and admin, beside shifts (Decision 17). The live
--      schedule and EVV shift-matching are untouched. Written only through work_block_save /
--      work_block_cancel (manage/operate); front-line logins read their own.
--   3. time_punches.work_block_id — a time-clock punch links to the scheduled work it belongs to:
--      training/meeting/admin punches to a matching work block, service/indirect punches to a matching
--      shift (same staff, code and client; from 30 minutes before the start to the end). Linking is
--      what makes non-billable nursing time "assigned in advance" (nursing policy §3.1).
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction:
--   preflight → changes → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

do $pre$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'evv_sessions' and column_name = 'server_clock_in_at') then
    raise exception 'v20.0.34 preflight: v20.0.32c has not run';
  end if;
  if to_regclass('public.work_blocks') is not null
     or exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'shifts' and column_name = 'cancellation_reason') then
    raise exception 'v20.0.34 preflight: this migration has already run';
  end if;
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'v20.0.34 preflight: needs Postgres 15+ (ON DELETE SET NULL column list)';
  end if;
end
$pre$;

-- -------------------------------------------------------------------------------------
-- 1. Shift cancellation reasons
-- -------------------------------------------------------------------------------------
alter table shifts
  add column cancellation_reason text check (cancellation_reason in ('no_fault','staff'));

comment on column shifts.cancellation_reason is
  'For cancelled shifts: no_fault (Person, guardian or provider cancelled — leaves scheduled hours) or staff (stays in scheduled hours). Cleared automatically when the shift is not cancelled.';

create function trg_shift_cancellation_reason() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.status is distinct from 'cancelled' then
    new.cancellation_reason := null;
  end if;
  return new;
end
$$;

create trigger shifts_cancellation_reason
  before insert or update on shifts
  for each row execute function trg_shift_cancellation_reason();

-- The app writes shifts directly; make sure the new column is readable and writable wherever the
-- table's other columns are (a no-op when table-level privileges already cover it).
do $grant$
begin
  if not has_column_privilege('authenticated', 'public.shifts', 'cancellation_reason', 'SELECT') then
    execute 'grant select (cancellation_reason) on public.shifts to authenticated';
  end if;
  if not has_column_privilege('authenticated', 'public.shifts', 'cancellation_reason', 'INSERT') then
    execute 'grant insert (cancellation_reason) on public.shifts to authenticated';
  end if;
  if not has_column_privilege('authenticated', 'public.shifts', 'cancellation_reason', 'UPDATE') then
    execute 'grant update (cancellation_reason) on public.shifts to authenticated';
  end if;
end
$grant$;

-- -------------------------------------------------------------------------------------
-- 2. Work blocks (scheduled non-service work)
-- -------------------------------------------------------------------------------------
create table work_blocks (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references organizations(id) on delete cascade,
  staff_id            uuid not null,
  work_type           text not null check (work_type in ('training','meeting','admin')),
  scheduled_date      date not null,
  scheduled_start     time not null,
  scheduled_end       time not null,
  note                text,
  status              text not null default 'scheduled' check (status in ('scheduled','cancelled')),
  cancellation_reason text check (cancellation_reason in ('no_fault','staff')),
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (id, org_id),
  foreign key (staff_id, org_id)   references staff(id, org_id),
  foreign key (created_by, org_id) references staff(id, org_id),
  check (scheduled_end > scheduled_start),
  check ((status = 'cancelled') = (cancellation_reason is not null))
);

create index work_blocks_staff_date on work_blocks (staff_id, scheduled_date);
create index work_blocks_org_date   on work_blocks (org_id, scheduled_date);

alter table work_blocks enable row level security;

do $rls$
begin
  revoke all on table work_blocks from anon, public;
  revoke insert, update, delete, truncate, references, trigger on table work_blocks from authenticated;
  grant select on table work_blocks to authenticated;
  create policy work_blocks_tenant_guard on work_blocks as restrictive for all to authenticated
    using (org_id = (select org_id()) and (select member_role()) is not null)
    with check (org_id = (select org_id()) and (select member_role()) is not null);
  create policy work_blocks_read on work_blocks for select to authenticated
    using ((select access_tier()) in ('manage','operate') or staff_id = (select my_staff_id()));
end
$rls$;

create function _work_block_save(p_org uuid, p_actor uuid, p_id uuid, p_staff uuid, p_work_type text,
                                 p_date date, p_start time, p_end time, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id  uuid;
  v_old jsonb;
begin
  if not exists (select 1 from staff where id = p_staff and org_id = p_org and is_active) then
    raise exception 'staff member not found or inactive' using errcode = 'P0002';
  end if;
  if p_work_type is null or p_work_type not in ('training','meeting','admin') then
    raise exception 'unknown work type %', p_work_type using errcode = '23514';
  end if;
  if p_date is null or p_start is null or p_end is null or p_end <= p_start then
    raise exception 'a date and an end time after the start time are required' using errcode = '23514';
  end if;

  if p_id is null then
    insert into work_blocks (org_id, staff_id, work_type, scheduled_date, scheduled_start, scheduled_end, note, created_by)
    values (p_org, p_staff, p_work_type, p_date, p_start, p_end, nullif(btrim(coalesce(p_note, '')), ''), p_actor)
    returning id into v_id;
  else
    select to_jsonb(w) into v_old from work_blocks w where w.id = p_id and w.org_id = p_org for update;
    if v_old is null then
      raise exception 'work block not found' using errcode = 'P0002';
    end if;
    if v_old->>'status' <> 'scheduled' then
      raise exception 'a cancelled work block cannot be edited' using errcode = '55000';
    end if;
    update work_blocks
       set staff_id = p_staff, work_type = p_work_type, scheduled_date = p_date,
           scheduled_start = p_start, scheduled_end = p_end,
           note = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now()
     where id = p_id
    returning id into v_id;
  end if;

  perform _pay_audit(p_org, 'work_block_save', 'work_blocks', v_id, v_old,
                     (select to_jsonb(w) from work_blocks w where w.id = v_id), p_actor);
  return v_id;
end
$$;

create function _work_block_cancel(p_org uuid, p_actor uuid, p_id uuid, p_reason text, p_note text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb;
begin
  if p_reason is null or p_reason not in ('no_fault','staff') then
    raise exception 'a cancellation reason (no_fault or staff) is required' using errcode = '23514';
  end if;
  select to_jsonb(w) into v_old from work_blocks w where w.id = p_id and w.org_id = p_org for update;
  if v_old is null then
    raise exception 'work block not found' using errcode = 'P0002';
  end if;
  if v_old->>'status' <> 'scheduled' then
    raise exception 'this work block is already cancelled' using errcode = '55000';
  end if;
  update work_blocks
     set status = 'cancelled', cancellation_reason = p_reason,
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note), updated_at = now()
   where id = p_id;
  perform _pay_audit(p_org, 'work_block_cancel', 'work_blocks', p_id, v_old,
                     (select to_jsonb(w) from work_blocks w where w.id = p_id), p_actor);
end
$$;

create function work_block_save(p_id uuid, p_staff uuid, p_work_type text, p_date date, p_start time, p_end time,
                                p_note text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select access_tier()) is distinct from 'manage' and (select access_tier()) is distinct from 'operate' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return _work_block_save(org_id(), my_staff_id(), p_id, p_staff, p_work_type, p_date, p_start, p_end, p_note);
end
$$;

create function work_block_cancel(p_id uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select access_tier()) is distinct from 'manage' and (select access_tier()) is distinct from 'operate' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform _work_block_cancel(org_id(), my_staff_id(), p_id, p_reason, p_note);
end
$$;

-- -------------------------------------------------------------------------------------
-- 3. Punches link to the scheduled work they belong to
-- -------------------------------------------------------------------------------------
alter table time_punches add column work_block_id uuid;
alter table time_punches
  add constraint time_punches_work_block_fk
  foreign key (work_block_id, org_id) references work_blocks(id, org_id) on delete set null (work_block_id);

-- The organization's local time zone for matching punches to scheduled dates and times.
create function _time_org_tz(p_org uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select nullif(s.value #>> '{}', '') from org_settings s
                   where s.org_id = p_org and s.key = 'timezone'), 'America/Denver');
$$;

-- Clock in on the server clock (as v20.0.32c), now also linking the punch to matching scheduled work:
-- training/meeting/admin → a scheduled work block of the same type; service/indirect → a scheduled or
-- in-progress shift for the same code (and client, when given). The window runs from 30 minutes before
-- the scheduled start to the scheduled end, in the organization's local time; the nearest start wins.
create or replace function _time_clock_in(p_org uuid, p_staff uuid, p_work_type text, p_person uuid,
                                          p_service_code text, p_shift uuid, p_lat numeric, p_lng numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code  uuid;
  v_evv   boolean;
  v_id    uuid;
  v_local timestamp;
  v_shift uuid := p_shift;
  v_block uuid;
begin
  perform _time_staff_lock(p_staff);
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

  v_local := clock_timestamp() at time zone _time_org_tz(p_org);
  if p_work_type in ('training','meeting','admin') then
    select w.id into v_block from work_blocks w
    where w.org_id = p_org and w.staff_id = p_staff and w.status = 'scheduled' and w.work_type = p_work_type
      and v_local >= (w.scheduled_date + w.scheduled_start) - interval '30 minutes'
      and v_local <= (w.scheduled_date + w.scheduled_end)
    order by abs(extract(epoch from ((w.scheduled_date + w.scheduled_start) - v_local))), w.id
    limit 1;
  elsif v_shift is null then
    select sh.id into v_shift from shifts sh
    where sh.org_id = p_org and sh.staff_id = p_staff and sh.service_code_id = v_code
      and (p_person is null or sh.person_id = p_person)
      and sh.status in ('scheduled','in_progress')
      and v_local >= (sh.scheduled_date + sh.scheduled_start) - interval '30 minutes'
      and v_local <= (sh.scheduled_date + sh.scheduled_end)
    order by abs(extract(epoch from ((sh.scheduled_date + sh.scheduled_start) - v_local))), sh.id
    limit 1;
  end if;

  begin
    insert into time_punches (org_id, staff_id, work_type, person_id, service_code_id, shift_id, work_block_id,
                              clock_in_at, clock_in_lat, clock_in_lng, note)
    values (p_org, p_staff, p_work_type, p_person, v_code, v_shift, v_block,
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

-- Grants for every function this file creates or replaces
do $fn$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('trg_shift_cancellation_reason','_work_block_save','_work_block_cancel',
                        'work_block_save','work_block_cancel','_time_org_tz','_time_clock_in')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname in ('work_block_save','work_block_cancel') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end
$fn$;

-- -------------------------------------------------------------------------------------
-- 4. Self-test — always rolled back. Every write and its check are separate statements.
-- -------------------------------------------------------------------------------------
do $test$
declare
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_owner  uuid;
  v_staff  uuid;
  v_person uuid;
  v_code   text;
  v_code_id uuid;
  v_local  timestamp;
  v_wb     uuid;
  v_shift  uuid;
  v_p      uuid;
begin
  select s.id into v_owner
  from org_members m join staff s on s.user_id = m.user_id and s.org_id = m.org_id
  where m.org_id = v_org and m.role = 'owner'
  order by m.joined_at, s.id limit 1;
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from evv_sessions e where e.staff_id = s.id and e.clock_out_at is null)
    and not exists (select 1 from time_punches t where t.staff_id = s.id and t.clock_out_at is null)
  order by s.created_at, s.id limit 1;
  select id into v_person from persons where org_id = v_org and is_active order by created_at, id limit 1;
  select code, id into v_code, v_code_id from service_code_definitions where not evv_required order by code limit 1;
  if v_owner is null or v_staff is null or v_person is null or v_code is null then
    raise exception 'SELFTEST FAIL 0: needs an owner, a free active staff member, an active Person and a non-EVV code';
  end if;
  v_local := clock_timestamp() at time zone _time_org_tz(v_org);

  begin
    -- 1. A cancelled shift keeps its reason; un-cancelling clears it
    insert into shifts (org_id, staff_id, person_id, service_code_id, scheduled_date, scheduled_start, scheduled_end, status, cancellation_reason)
    values (v_org, v_staff, v_person, v_code_id, current_date + 30, '09:00', '10:00', 'cancelled', 'no_fault')
    returning id into v_shift;
    if not exists (select 1 from shifts where id = v_shift and cancellation_reason = 'no_fault') then
      raise exception 'SELFTEST FAIL 1: cancelled shift lost its reason';
    end if;
    update shifts set status = 'scheduled' where id = v_shift;
    if exists (select 1 from shifts where id = v_shift and cancellation_reason is not null) then
      raise exception 'SELFTEST FAIL 1b: un-cancelled shift kept a reason';
    end if;

    -- 2. A work block saves; cancelling needs a reason; a cancelled block can't be edited
    v_wb := _work_block_save(v_org, v_owner, null, v_staff, 'meeting', current_date + 30, '13:00', '14:00', 'self-test');
    begin
      perform _work_block_cancel(v_org, v_owner, v_wb, null, null);
      raise exception 'SELFTEST FAIL 2: cancel without a reason accepted';
    exception when sqlstate '23514' then null;
    end;
    perform _work_block_cancel(v_org, v_owner, v_wb, 'staff', 'self-test');
    if not exists (select 1 from work_blocks where id = v_wb and status = 'cancelled' and cancellation_reason = 'staff') then
      raise exception 'SELFTEST FAIL 2b: cancellation not recorded';
    end if;
    begin
      perform _work_block_save(v_org, v_owner, v_wb, v_staff, 'meeting', current_date + 30, '13:00', '15:00', 'self-test');
      raise exception 'SELFTEST FAIL 2c: a cancelled block was edited';
    exception when sqlstate '55000' then null;
    end;

    -- 3. A training punch links to the training block scheduled now (skipped within an hour of midnight)
    if (v_local + interval '50 minutes')::date = v_local::date and (v_local - interval '10 minutes')::date = v_local::date then
      v_wb := _work_block_save(v_org, v_owner, null, v_staff, 'training', v_local::date,
                               (v_local - interval '10 minutes')::time, (v_local + interval '50 minutes')::time, 'self-test');
      v_p := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
      if not exists (select 1 from time_punches where id = v_p and work_block_id = v_wb) then
        raise exception 'SELFTEST FAIL 3: training punch not linked to its work block';
      end if;
      perform _time_clock_out(v_org, v_staff, v_p, null, null);

      -- 4. A service punch links to the matching shift scheduled now
      insert into shifts (org_id, staff_id, person_id, service_code_id, scheduled_date, scheduled_start, scheduled_end, status)
      values (v_org, v_staff, v_person, v_code_id, v_local::date,
              (v_local - interval '10 minutes')::time, (v_local + interval '50 minutes')::time, 'scheduled')
      returning id into v_shift;
      v_p := _time_clock_in(v_org, v_staff, 'service', v_person, v_code, null, null, null, 'self-test');
      if not exists (select 1 from time_punches where id = v_p and shift_id = v_shift and work_block_id is null) then
        raise exception 'SELFTEST FAIL 4: service punch not linked to its shift';
      end if;
      perform _time_clock_out(v_org, v_staff, v_p, null, null);

      -- 5. A meeting punch with no meeting scheduled links to nothing
      v_p := _time_clock_in(v_org, v_staff, 'meeting', null, null, null, null, null, 'self-test');
      if not exists (select 1 from time_punches where id = v_p and work_block_id is null and shift_id is null) then
        raise exception 'SELFTEST FAIL 5: an unscheduled punch was linked to something';
      end if;
    end if;

    -- 6. Without a signed-in session the RPCs refuse
    begin
      perform work_block_save(null, v_staff, 'training', current_date, '09:00', '10:00', 'self-test');
      raise exception 'SELFTEST FAIL 6: work_block_save ran without a session';
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
-- 5. Verification table (paste this result into the PR and the chat)
-- -------------------------------------------------------------------------------------
with checks as (
  select 1 as n, 'Shift cancellation reason column + trigger' as check_name,
         ((select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'shifts' and column_name = 'cancellation_reason')::text || '/' ||
          (select count(*) from pg_trigger where tgrelid = 'public.shifts'::regclass
           and tgname = 'shifts_cancellation_reason' and not tgisinternal)::text) as got, '1/1' as want
  union all
  select 2, 'App can read and write shifts.cancellation_reason',
         (has_column_privilege('authenticated', 'public.shifts', 'cancellation_reason', 'SELECT')
          and has_column_privilege('authenticated', 'public.shifts', 'cancellation_reason', 'UPDATE'))::text, 'true'
  union all
  select 3, 'Work blocks table with RLS',
         (select count(*) from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
          where ns.nspname = 'public' and c.relname = 'work_blocks' and c.relrowsecurity)::text, '1'
  union all
  select 4, 'Policies on work_blocks', (select count(*) from pg_policies where schemaname = 'public' and tablename = 'work_blocks')::text, '2'
  union all
  select 5, 'Clients cannot write work blocks directly',
         (has_table_privilege('authenticated', 'public.work_blocks', 'INSERT')
          or has_table_privilege('authenticated', 'public.work_blocks', 'UPDATE'))::text, 'false'
  union all
  select 6, 'Work block RPCs callable by signed-in users (not anon)',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname in ('work_block_save','work_block_cancel')
            and has_function_privilege('authenticated', p.oid, 'EXECUTE')
            and not has_function_privilege('anon', p.oid, 'EXECUTE'))::text, '2'
  union all
  select 7, 'Internal functions callable by clients',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public'
            and p.proname in ('_work_block_save','_work_block_cancel','_time_org_tz','_time_clock_in','trg_shift_cancellation_reason')
            and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or has_function_privilege('anon', p.oid, 'EXECUTE')))::text, '0'
  union all
  select 8, 'Punches link to work blocks (column + FK)',
         ((select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'time_punches' and column_name = 'work_block_id')::text || '/' ||
          (select count(*) from pg_constraint where conname = 'time_punches_work_block_fk')::text), '1/1'
  union all
  select 9, 'Clock in matches scheduled work',
         (position('v_block' in pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)) > 0)::text, 'true'
  union all
  select 10, 'Self-test leftovers (work blocks / punches)',
         ((select count(*) from work_blocks where note = 'self-test')::text || '/' ||
          (select count(*) from time_punches where note = 'self-test')::text), '0/0'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
