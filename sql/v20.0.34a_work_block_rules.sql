-- =====================================================================================
-- sql/v20.0.34a_work_block_rules.sql
-- Provly pay engine — v20.0.34 review round 1 (v20.0.34 has run; this is a new migration)
--
--   1. A service or indirect punch links to a shift only when the punch names the same client. A punch
--      with no client (group or non-client work) is never attached to some client's shift.
--   2. Once a time-clock punch is linked to a work block, the block is the record of what was assigned:
--      only its note can change — staff, work type, date and times are frozen — and it can't be cancelled.
--   3. The self-test uses a staff member with nothing else scheduled today, so existing shifts can never
--      compete with its test records.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.34. One transaction:
--   preflight → replace three functions → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

do $pre$
declare
  v_def text;
begin
  if to_regclass('public.work_blocks') is null then
    raise exception 'v20.0.34a preflight: v20.0.34 has not run';
  end if;
  v_def := pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure);
  if position('p_person is null or sh.person_id' in v_def) = 0 then
    raise exception 'v20.0.34a preflight: this migration has already run';
  end if;
end
$pre$;

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
  elsif v_shift is null and p_person is not null then
    -- v20.0.34a: a service punch links to a shift only for the same client. Group or non-client work
    -- (no client given) is never attached to some client's shift.
    select sh.id into v_shift from shifts sh
    where sh.org_id = p_org and sh.staff_id = p_staff and sh.service_code_id = v_code
      and sh.person_id = p_person
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

create or replace function _work_block_save(p_org uuid, p_actor uuid, p_id uuid, p_staff uuid, p_work_type text,
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
    -- v20.0.34a: once a time-clock punch is linked, the block is the record of what was assigned —
    -- only its note can change (staff, work type, date and times are frozen).
    if exists (select 1 from time_punches t where t.work_block_id = p_id)
       and ((v_old->>'staff_id')::uuid is distinct from p_staff
            or v_old->>'work_type' is distinct from p_work_type
            or (v_old->>'scheduled_date')::date is distinct from p_date
            or (v_old->>'scheduled_start')::time is distinct from p_start
            or (v_old->>'scheduled_end')::time is distinct from p_end) then
      raise exception 'this work block already has clock-ins linked to it — only its note can change' using errcode = '55000';
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

create or replace function _work_block_cancel(p_org uuid, p_actor uuid, p_id uuid, p_reason text, p_note text)
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
  -- v20.0.34a: work that was clocked can't be cancelled after the fact
  if exists (select 1 from time_punches t where t.work_block_id = p_id) then
    raise exception 'this work block already has clock-ins linked to it and can''t be cancelled' using errcode = '55000';
  end if;
  update work_blocks
     set status = 'cancelled', cancellation_reason = p_reason,
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note), updated_at = now()
   where id = p_id;
  perform _pay_audit(p_org, 'work_block_cancel', 'work_blocks', p_id, v_old,
                     (select to_jsonb(w) from work_blocks w where w.id = p_id), p_actor);
end
$$;

do $fn$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('_time_clock_in','_work_block_save','_work_block_cancel')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end
$fn$;

-- Self-test — always rolled back. Uses a staff member with no shifts, work blocks or open clocks today,
-- so nothing already scheduled can compete with the test records.
do $test$
declare
  v_org     constant uuid := '00000000-0000-0000-0000-000000000001';
  v_owner   uuid;
  v_staff   uuid;
  v_person  uuid;
  v_code    text;
  v_code_id uuid;
  v_local   timestamp;
  v_today   date;
  v_shift   uuid;
  v_wb      uuid;
  v_p       uuid;
begin
  v_local := clock_timestamp() at time zone _time_org_tz(v_org);
  v_today := v_local::date;
  select s.id into v_owner
  from org_members m join staff s on s.user_id = m.user_id and s.org_id = m.org_id
  where m.org_id = v_org and m.role = 'owner'
  order by m.joined_at, s.id limit 1;
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from evv_sessions e where e.staff_id = s.id and e.clock_out_at is null)
    and not exists (select 1 from time_punches t where t.staff_id = s.id and t.clock_out_at is null)
    and not exists (select 1 from shifts sh where sh.staff_id = s.id and sh.scheduled_date between v_today - 1 and v_today + 1)
    and not exists (select 1 from work_blocks w where w.staff_id = s.id and w.scheduled_date between v_today - 1 and v_today + 1)
  order by s.created_at, s.id limit 1;
  select id into v_person from persons where org_id = v_org and is_active order by created_at, id limit 1;
  select code, id into v_code, v_code_id from service_code_definitions where not evv_required order by code limit 1;
  if v_owner is null or v_staff is null or v_person is null or v_code is null then
    raise exception 'SELFTEST FAIL 0: needs an owner, a staff member with nothing scheduled around today, an active Person and a non-EVV code';
  end if;

  begin
    if (v_local + interval '50 minutes')::date = v_today and (v_local - interval '10 minutes')::date = v_today then
      insert into shifts (org_id, staff_id, person_id, service_code_id, scheduled_date, scheduled_start, scheduled_end, status)
      values (v_org, v_staff, v_person, v_code_id, v_today,
              (v_local - interval '10 minutes')::time, (v_local + interval '50 minutes')::time, 'scheduled')
      returning id into v_shift;

      -- 1. No client on the punch: never attached to a client's shift
      v_p := _time_clock_in(v_org, v_staff, 'service', null, v_code, null, null, null, 'self-test');
      if not exists (select 1 from time_punches where id = v_p and shift_id is null) then
        raise exception 'SELFTEST FAIL 1: a punch with no client was linked to a client''s shift';
      end if;
      perform _time_clock_out(v_org, v_staff, v_p, null, null);

      -- 2. Same client: linked
      v_p := _time_clock_in(v_org, v_staff, 'service', v_person, v_code, null, null, null, 'self-test');
      if not exists (select 1 from time_punches where id = v_p and shift_id = v_shift) then
        raise exception 'SELFTEST FAIL 2: a punch for the shift''s client was not linked';
      end if;
      perform _time_clock_out(v_org, v_staff, v_p, null, null);

      -- 3. A work block with a linked punch: only the note can change, and it can't be cancelled
      v_wb := _work_block_save(v_org, v_owner, null, v_staff, 'training', v_today,
                               (v_local - interval '10 minutes')::time, (v_local + interval '50 minutes')::time, 'self-test');
      v_p := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
      if not exists (select 1 from time_punches where id = v_p and work_block_id = v_wb) then
        raise exception 'SELFTEST FAIL 3: training punch not linked to its block';
      end if;
      begin
        perform _work_block_save(v_org, v_owner, v_wb, v_staff, 'admin', v_today,
                                 (v_local - interval '10 minutes')::time, (v_local + interval '50 minutes')::time, 'self-test');
        raise exception 'SELFTEST FAIL 3b: the work type of a used block was changed';
      exception when sqlstate '55000' then null;
      end;
      perform _work_block_save(v_org, v_owner, v_wb, v_staff, 'training', v_today,
                               (v_local - interval '10 minutes')::time, (v_local + interval '50 minutes')::time, 'self-test: note only');
      if not exists (select 1 from work_blocks where id = v_wb and note = 'self-test: note only') then
        raise exception 'SELFTEST FAIL 3c: a note-only edit of a used block was refused';
      end if;
      begin
        perform _work_block_cancel(v_org, v_owner, v_wb, 'staff', 'self-test');
        raise exception 'SELFTEST FAIL 3d: a used block was cancelled';
      exception when sqlstate '55000' then null;
      end;
      perform _time_clock_out(v_org, v_staff, v_p, null, null);
    end if;

    raise exception 'SELFTEST_ROLLBACK' using errcode = 'PRVOK';
  exception when sqlstate 'PRVOK' then
    null;  -- every self-test write above is rolled back here
  end;
end
$test$;

commit;

-- Verification table (paste this result into the PR and the chat)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok from (
  select 1 n, 'Service punch links only to the same client''s shift' check_name,
    (position('and sh.person_id = p_person' in pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)) > 0
     and position('p_person is null or sh.person_id' in pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)) = 0)::text got,
    'true' want
  union all select 2, 'Used work blocks: only the note can change',
    (position('only its note can change' in pg_get_functiondef('_work_block_save(uuid,uuid,uuid,uuid,text,date,time without time zone,time without time zone,text)'::regprocedure)) > 0)::text, 'true'
  union all select 3, 'Used work blocks can''t be cancelled',
    (position('linked to it and can' in pg_get_functiondef('_work_block_cancel(uuid,uuid,uuid,text,text)'::regprocedure)) > 0)::text, 'true'
  union all select 4, 'Internal functions callable by clients',
    (select count(*) from pg_proc where proname in ('_time_clock_in','_work_block_save','_work_block_cancel')
     and (has_function_privilege('authenticated', oid, 'EXECUTE') or has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  union all select 5, 'Self-test leftovers (blocks/punches)',
    (select count(*) from work_blocks where note like 'self-test%')::text || '/' ||
    (select count(*) from time_punches where note = 'self-test')::text, '0/0'
) t
order by n;
