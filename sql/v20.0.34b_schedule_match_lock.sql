-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.34b_schedule_match_lock.sql
-- Provly pay engine — v20.0.34 review round 2 (v20.0.34 and v20.0.34a have run; this is a new migration)
--
--   1. Matching a punch to the schedule moves into _time_match_schedule, which takes the local time as
--      an input and locks the work block it matches (FOR SHARE) until the clock-in's transaction ends.
--      v20.0.34a's edit and cancel already lock the block (FOR UPDATE) before checking for linked punches,
--      so an edit and a clock-in can never pass each other: whichever arrives second waits, then sees the
--      other's result.
--   2. The self-test is independent of real schedules and the time of day: every match runs against test
--      records on a far-future date (2099-06-15).
--   Same-client shift links and frozen used work blocks (v20.0.34a) are unchanged.
-- r1 (Greptile round 3, before this file ran): the self-test picks a staff member with no punch that
--   overlaps its 2099 test punch — an open punch (no clock-out) counts as overlapping everything after it.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.34a — and only after this PR's review is 5/5.
-- One transaction: preflight → replace functions → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

do $pre$
declare
  v_def text;
begin
  if to_regclass('public.work_blocks') is null then
    raise exception 'v20.0.34b preflight: v20.0.34 has not run';
  end if;
  v_def := pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure);
  if position('p_person is null or sh.person_id' in v_def) > 0 then
    raise exception 'v20.0.34b preflight: v20.0.34a has not run';
  end if;
  if to_regprocedure('public._time_match_schedule(uuid,uuid,text,uuid,uuid,timestamp without time zone)') is not null then
    raise exception 'v20.0.34b preflight: this migration has already run';
  end if;
end
$pre$;

-- The schedule match for a punch at local time p_local: training/meeting/admin → a scheduled work block of
-- that type; service/indirect with a client → a scheduled or in-progress shift for the same client and code.
-- Window: 30 minutes before the scheduled start to the scheduled end; the nearest start wins. The matched
-- work block is locked FOR SHARE until the punch's transaction ends, so a concurrent edit or cancel waits
-- and then sees the linked punch.
create function _time_match_schedule(p_org uuid, p_staff uuid, p_work_type text, p_person uuid, p_code uuid,
                                     p_local timestamp, out o_shift uuid, out o_block uuid)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_work_type in ('training','meeting','admin') then
    select w.id into o_block from work_blocks w
    where w.org_id = p_org and w.staff_id = p_staff and w.status = 'scheduled' and w.work_type = p_work_type
      and p_local >= (w.scheduled_date + w.scheduled_start) - interval '30 minutes'
      and p_local <= (w.scheduled_date + w.scheduled_end)
    order by abs(extract(epoch from ((w.scheduled_date + w.scheduled_start) - p_local))), w.id
    limit 1
    for share;
  elsif p_work_type in ('service','indirect') and p_person is not null and p_code is not null then
    select sh.id into o_shift from shifts sh
    where sh.org_id = p_org and sh.staff_id = p_staff and sh.service_code_id = p_code
      and sh.person_id = p_person
      and sh.status in ('scheduled','in_progress')
      and p_local >= (sh.scheduled_date + sh.scheduled_start) - interval '30 minutes'
      and p_local <= (sh.scheduled_date + sh.scheduled_end)
    order by abs(extract(epoch from ((sh.scheduled_date + sh.scheduled_start) - p_local))), sh.id
    limit 1;
  end if;
end
$$;

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
  v_match uuid;
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

  -- v20.0.34a: schedule match via _time_match_schedule (same client only for shifts; the matched work
  -- block is locked FOR SHARE). An explicitly given shift is kept as is.
  v_local := clock_timestamp() at time zone _time_org_tz(p_org);
  select m.o_shift, m.o_block into v_match, v_block
  from _time_match_schedule(p_org, p_staff, p_work_type, p_person, v_code, v_local) m;
  v_shift := coalesce(p_shift, v_match);

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

do $fn$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('_time_match_schedule','_time_clock_in')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end
$fn$;

-- Self-test — always rolled back, and independent of real schedules: every match runs against test
-- records on a far-future date (2099-06-15), so nothing already scheduled can compete with them.
do $test$
declare
  v_org     constant uuid := '00000000-0000-0000-0000-000000000001';
  v_day     constant date := date '2099-06-15';
  v_at      constant timestamp := timestamp '2099-06-15 10:00:00';
  v_owner   uuid;
  v_staff   uuid;
  v_person  uuid;
  v_code_id uuid;
  v_shift   uuid;
  v_wb      uuid;
  m         record;
begin
  select s.id into v_owner
  from org_members m2 join staff s on s.user_id = m2.user_id and s.org_id = m2.org_id
  where m2.org_id = v_org and m2.role = 'owner'
  order by m2.joined_at, s.id limit 1;
  -- a staff member none of whose punches overlap the test punch below (an open punch overlaps it too)
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from time_punches t
                    where t.staff_id = s.id
                      and tstzrange(t.clock_in_at, t.clock_out_at, '[)')
                          && tstzrange(timestamptz '2099-06-15 16:00:00+00', timestamptz '2099-06-15 17:00:00+00', '[)'))
  order by s.created_at, s.id limit 1;
  select id into v_person from persons where org_id = v_org and is_active order by created_at, id limit 1;
  select id into v_code_id from service_code_definitions where not evv_required order by code limit 1;
  if v_owner is null or v_staff is null or v_person is null or v_code_id is null then
    raise exception 'SELFTEST FAIL 0: needs an owner, an active staff member with no open or overlapping punch, an active Person and a non-EVV code';
  end if;

  begin
    insert into shifts (org_id, staff_id, person_id, service_code_id, scheduled_date, scheduled_start, scheduled_end, status)
    values (v_org, v_staff, v_person, v_code_id, v_day, '09:50', '10:50', 'scheduled')
    returning id into v_shift;

    -- 1. No client on the punch: never matched to a client's shift
    select * into m from _time_match_schedule(v_org, v_staff, 'service', null, v_code_id, v_at);
    if m.o_shift is not null then
      raise exception 'SELFTEST FAIL 1: a punch with no client matched a client''s shift';
    end if;

    -- 2. Same client and code: matched
    select * into m from _time_match_schedule(v_org, v_staff, 'service', v_person, v_code_id, v_at);
    if m.o_shift is distinct from v_shift then
      raise exception 'SELFTEST FAIL 2: the same client''s shift was not matched';
    end if;

    -- 3. A work block matches only its own work type
    v_wb := _work_block_save(v_org, v_owner, null, v_staff, 'training', v_day, '09:50', '10:50', 'self-test');
    select * into m from _time_match_schedule(v_org, v_staff, 'training', null, null, v_at);
    if m.o_block is distinct from v_wb then
      raise exception 'SELFTEST FAIL 3: the training block was not matched';
    end if;
    select * into m from _time_match_schedule(v_org, v_staff, 'meeting', null, null, v_at);
    if m.o_block is not null then
      raise exception 'SELFTEST FAIL 3b: a meeting punch matched a training block';
    end if;

    -- 4. With a punch linked, only the note can change and the block can't be cancelled
    insert into time_punches (org_id, staff_id, work_type, work_block_id, clock_in_at, clock_out_at, note)
    values (v_org, v_staff, 'training', v_wb, timestamptz '2099-06-15 16:00:00+00', timestamptz '2099-06-15 17:00:00+00', 'self-test');
    begin
      perform _work_block_save(v_org, v_owner, v_wb, v_staff, 'admin', v_day, '09:50', '10:50', 'self-test');
      raise exception 'SELFTEST FAIL 4: the work type of a used block was changed';
    exception when sqlstate '55000' then null;
    end;
    perform _work_block_save(v_org, v_owner, v_wb, v_staff, 'training', v_day, '09:50', '10:50', 'self-test: note only');
    if not exists (select 1 from work_blocks where id = v_wb and note = 'self-test: note only') then
      raise exception 'SELFTEST FAIL 4b: a note-only edit of a used block was refused';
    end if;
    begin
      perform _work_block_cancel(v_org, v_owner, v_wb, 'staff', 'self-test');
      raise exception 'SELFTEST FAIL 4c: a used block was cancelled';
    exception when sqlstate '55000' then null;
    end;

    -- 5. Without a signed-in session the RPC refuses
    begin
      perform work_block_save(null, v_staff, 'training', v_day, '09:00', '10:00', 'self-test');
      raise exception 'SELFTEST FAIL 5: work_block_save ran without a session';
    exception when insufficient_privilege then null;
    end;

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
    (position('and sh.person_id = p_person' in pg_get_functiondef('_time_match_schedule(uuid,uuid,text,uuid,uuid,timestamp without time zone)'::regprocedure)) > 0
     and position('p_person is null or sh.person_id' in pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)) = 0)::text got,
    'true' want
  union all select 2, 'Used work blocks: only the note can change',
    (position('only its note can change' in pg_get_functiondef('_work_block_save(uuid,uuid,uuid,uuid,text,date,time without time zone,time without time zone,text)'::regprocedure)) > 0)::text, 'true'
  union all select 3, 'Used work blocks can''t be cancelled',
    (position('linked to it and can' in pg_get_functiondef('_work_block_cancel(uuid,uuid,uuid,text,text)'::regprocedure)) > 0)::text, 'true'
  union all select 4, 'Internal functions callable by clients',
    (select count(*) from pg_proc where proname in ('_time_match_schedule','_time_clock_in','_work_block_save','_work_block_cancel')
     and (has_function_privilege('authenticated', oid, 'EXECUTE') or has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  union all select 6, 'Matched work block locked against concurrent edits (FOR SHARE)',
    (position('for share' in pg_get_functiondef('_time_match_schedule(uuid,uuid,text,uuid,uuid,timestamp without time zone)'::regprocedure)) > 0
     and position('_time_match_schedule' in pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)) > 0)::text, 'true'
  union all select 5, 'Self-test leftovers (blocks/punches)',
    (select count(*) from work_blocks where note like 'self-test%')::text || '/' ||
    (select count(*) from time_punches where note = 'self-test')::text, '0/0'
) t
order by n;
