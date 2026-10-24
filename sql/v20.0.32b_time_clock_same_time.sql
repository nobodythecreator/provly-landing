-- =====================================================================================
-- sql/v20.0.32b_time_clock_same_time.sql
-- Provly pay engine — v20.0.32 review round 3 (v20.0.32 and v20.0.32a have run; this is a new migration)
--
-- The EVV hand-off now uses the SAME time on both sides: the punch ends exactly when the EVV visit
-- starts (the visit's device time). v20.0.32a capped the punch's end at server time, so a device
-- running a few minutes ahead left minutes between the two records with no hours recorded. Worked
-- time must never go unrecorded; a small overlap (device behind) is fine because the weekly
-- calculation merges overlapping records, but a gap can't be filled.
--
--   · hand-off: the punch ends at the visit's start, or one microsecond after the punch's own start
--     if the device time is at or before it (the visit then overlaps; merged later). Device times more
--     than 15 minutes ahead of the server are treated as 15 minutes ahead — that's bad data, not a
--     clock difference.
--   · clock in: a new punch starts now, or where the staff member's last punch ended if that is later
--     (up to 15 minutes ahead), so records stay contiguous and a punch that ended slightly ahead
--     never blocks the next one.
--   · clock out: never at or before the punch's own start.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.32a. One transaction:
--   preflight → replace three functions → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

do $pre$
declare
  v_def text;
begin
  if to_regprocedure('public._time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)') is null then
    raise exception 'v20.0.32b preflight: v20.0.32 has not run';
  end if;
  v_def := pg_get_functiondef('_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure);
  if position('interval ''15 minutes''' in v_def) > 0 then
    raise exception 'v20.0.32b preflight: this migration has already run';
  end if;
  if position('least(p_at, clock_timestamp())' in v_def) = 0 then
    raise exception 'v20.0.32b preflight: v20.0.32a has not run';
  end if;
end
$pre$;

create or replace function _time_evv_handoff(p_org uuid, p_staff uuid, p_at timestamptz, p_live boolean,
                                             p_lat numeric, p_lng numeric)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_punch time_punches;
  v_end   timestamptz;
  v_ok    boolean := p_lat is not null and p_lng is not null
                     and p_lat between -90 and 90 and p_lng between -180 and 180;
begin
  if not p_live or p_at is null then
    return null;   -- completed EVV entries leave an open punch alone
  end if;
  perform _time_staff_lock(p_staff);
  select * into v_punch from time_punches
  where staff_id = p_staff and org_id = p_org and clock_out_at is null
  for update;
  if not found then
    return null;
  end if;
  -- Same time on both sides: the punch ends exactly when the visit starts (no gap). If the device time
  -- is at or before the punch's start, the punch ends just after its start and the visit overlaps it
  -- (merged by the weekly calculation). Device times more than 15 minutes ahead are capped there.
  v_end := greatest(least(p_at, clock_timestamp() + interval '15 minutes'),
                    v_punch.clock_in_at + interval '1 microsecond');
  update time_punches
     set clock_out_at  = v_end,
         clock_out_lat = case when v_ok then round(p_lat, 6) end,
         clock_out_lng = case when v_ok then round(p_lng, 6) end
   where id = v_punch.id;
  perform _pay_audit(p_org, 'time_punch_evv', 'time_punches', v_punch.id, to_jsonb(v_punch),
                     (select to_jsonb(t) from time_punches t where t.id = v_punch.id), p_staff);
  return v_punch.id;
end
$$;

create or replace function _time_clock_in(p_org uuid, p_staff uuid, p_work_type text, p_person uuid,
                               p_service_code text, p_shift uuid, p_lat numeric, p_lng numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code  uuid;
  v_evv   boolean;
  v_id    uuid;
  v_start timestamptz;
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

  -- A punch starts now, or where this staff member's last punch ended if that is later (an EVV
  -- hand-off can end a punch at a device time a little ahead of the server). Records stay contiguous:
  -- no gap, no overlap.
  -- (Only ends up to 15 minutes ahead count; anything further out is not a clock difference.)
  select greatest(clock_timestamp(),
                  coalesce(max(t.clock_out_at) filter (where t.clock_out_at <= clock_timestamp() + interval '15 minutes'),
                           '-infinity'::timestamptz))
    into v_start
  from time_punches t where t.staff_id = p_staff and t.org_id = p_org;

  begin
    insert into time_punches (org_id, staff_id, work_type, person_id, service_code_id, shift_id,
                              clock_in_at, clock_in_lat, clock_in_lng, note)
    values (p_org, p_staff, p_work_type, p_person, v_code, p_shift,
            v_start, p_lat, p_lng, nullif(btrim(coalesce(p_note, '')), ''))
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'you already have an open time punch — clock out of it first' using errcode = '23514';
  end;

  perform _pay_audit(p_org, 'time_punch_in', 'time_punches', v_id, null,
                     (select to_jsonb(t) from time_punches t where t.id = v_id), p_staff);
  return v_id;
end
$$;

create or replace function _time_clock_out(p_org uuid, p_staff uuid, p_punch uuid, p_lat numeric, p_lng numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb;
begin
  perform _time_staff_lock(p_staff);
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
     -- never at or before the punch's own start (a punch can start slightly ahead — see _time_clock_in)
     set clock_out_at  = greatest(clock_timestamp(), (v_old->>'clock_in_at')::timestamptz + interval '1 microsecond'),
         clock_out_lat = p_lat, clock_out_lng = p_lng
   where id = p_punch;
  perform _pay_audit(p_org, 'time_punch_out', 'time_punches', p_punch, v_old,
                     (select to_jsonb(t) from time_punches t where t.id = p_punch), p_staff);
end
$$;

-- Self-test — always rolled back. Every call and its check are separate statements.
do $test$
declare
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_staff  uuid;
  v_p      uuid;
  v_q      uuid;
  v_in     timestamptz;
  v_at     timestamptz;
  v_closed uuid;
begin
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from evv_sessions e where e.staff_id = s.id and e.clock_out_at is null)
    and not exists (select 1 from time_punches t where t.staff_id = s.id
                    and (t.clock_out_at is null or t.clock_out_at > clock_timestamp()))
  order by s.created_at, s.id limit 1;
  if v_staff is null then
    raise exception 'SELFTEST FAIL 0: needs an active staff member with no open EVV visit or punch';
  end if;

  begin
    -- 1. Normal: the punch ends exactly at the visit's start
    v_p := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
    v_at := clock_timestamp();
    v_closed := _time_evv_handoff(v_org, v_staff, v_at, true, 40.730000, -111.860000);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p and clock_out_at = v_at and clock_out_lat = 40.73) then
      raise exception 'SELFTEST FAIL 1: punch did not end exactly at the visit start';
    end if;

    -- 2. Device behind: the punch ends just after its start (the visit overlaps — no gap)
    v_p := _time_clock_in(v_org, v_staff, 'meeting', null, null, null, null, null, 'self-test');
    select clock_in_at into v_in from time_punches where id = v_p;
    v_closed := _time_evv_handoff(v_org, v_staff, v_in - interval '2 minutes', true, null, null);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p and clock_out_at = v_in + interval '1 microsecond') then
      raise exception 'SELFTEST FAIL 2: device-behind hand-off did not end the punch just after its start';
    end if;

    -- 3. A completed EVV entry leaves an open punch alone; a normal clock-out still works
    v_p := _time_clock_in(v_org, v_staff, 'admin', null, null, null, null, null, 'self-test');
    v_closed := _time_evv_handoff(v_org, v_staff, clock_timestamp(), false, null, null);
    if v_closed is not null
       or not exists (select 1 from time_punches where id = v_p and clock_out_at is null) then
      raise exception 'SELFTEST FAIL 3: a completed EVV entry ended the punch';
    end if;
    perform _time_clock_out(v_org, v_staff, v_p, null, null);

    -- 4. Device 5 minutes ahead: the punch ends at that same time — no gap before the visit
    v_p := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
    v_at := clock_timestamp() + interval '5 minutes';
    v_closed := _time_evv_handoff(v_org, v_staff, v_at, true, null, null);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p and clock_out_at = v_at) then
      raise exception 'SELFTEST FAIL 4: device-ahead hand-off left a gap';
    end if;

    -- 5. The next punch starts where that one ended (contiguous), and clocking out of it still works
    v_q := _time_clock_in(v_org, v_staff, 'meeting', null, null, null, null, null, 'self-test');
    if not exists (select 1 from time_punches where id = v_q and clock_in_at = v_at) then
      raise exception 'SELFTEST FAIL 5: next punch did not start where the last one ended';
    end if;
    perform _time_clock_out(v_org, v_staff, v_q, null, null);
    if not exists (select 1 from time_punches where id = v_q and clock_out_at > clock_in_at) then
      raise exception 'SELFTEST FAIL 5b: clock-out before a slightly-ahead start was not handled';
    end if;

    -- 6. A device time far ahead is capped at 15 minutes
    v_p := _time_clock_in(v_org, v_staff, 'admin', null, null, null, null, null, 'self-test');
    v_closed := _time_evv_handoff(v_org, v_staff, clock_timestamp() + interval '3 hours', true, null, null);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p
                      and clock_out_at <= clock_timestamp() + interval '15 minutes') then
      raise exception 'SELFTEST FAIL 6: a far-ahead device time was not capped';
    end if;

    raise exception 'SELFTEST_ROLLBACK' using errcode = 'PRVOK';
  exception when sqlstate 'PRVOK' then
    null;  -- every self-test write above is rolled back here
  end;
end
$test$;

commit;

-- Verification table (paste this result into the PR and the chat)
with defs as (
  select pg_get_functiondef('_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure) as handoff,
         pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)   as clock_in,
         pg_get_functiondef('_time_clock_out(uuid,uuid,uuid,numeric,numeric)'::regprocedure)                      as clock_out
),
checks as (
  select 1 as n, 'Hand-off ends the punch at the visit''s own start time' as check_name,
         (position('least(p_at, clock_timestamp() + interval ''15 minutes'')' in handoff) > 0
          and position('least(p_at, clock_timestamp())' in handoff) = 0)::text as got, 'true' as want
  from defs
  union all
  select 2, 'Clock in starts where the last punch ended (if later)',
         (position('v_start' in clock_in) > 0)::text, 'true' from defs
  union all
  select 3, 'Clock out never at or before the punch start',
         (position('interval ''1 microsecond''' in clock_out) > 0)::text, 'true' from defs
  union all
  select 4, 'EVV hand-off trigger still on evv_sessions',
         (select count(*) from pg_trigger tg
          where tg.tgrelid = 'public.evv_sessions'::regclass and tg.tgname = 'evv_sessions_time_punch_handoff'
            and not tg.tgisinternal)::text, '1'
  union all
  select 5, 'Internal time functions callable by clients',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public'
            and p.proname in ('_time_staff_lock','_time_clock_in','_time_clock_out','_time_correct_punch',
                              '_time_evv_handoff','trg_evv_time_punch_handoff')
            and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or has_function_privilege('anon', p.oid, 'EXECUTE')))::text, '0'
  union all
  select 6, 'Self-test leftovers (punches with note self-test)',
         (select count(*) from time_punches where note = 'self-test')::text, '0'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
