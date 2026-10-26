-- =====================================================================================
-- sql/v20.0.32a_time_clock_handoff.sql
-- Provly pay engine — v20.0.32 review round 2 (v20.0.32 has already run; this is a new migration)
--
-- A live EVV clock-in now ALWAYS ends the staff member's open time punch. Before, the hand-off skipped
-- the punch when the EVV start time was at or before the punch's start. EVV start times come from the
-- device and punch times from the server, so a device clock running a little behind could leave a
-- newer punch open while the EVV visit ran — two clocks at once.
--
-- The punch now ends at the visit's start, but never later than now. If the device's visit start is at
-- or before the punch's own start, the punch ends now, keeping its real length. Any overlap with the
-- EVV visit is merged by the weekly calculation, so no time is lost or counted twice. Completed EVV
-- entries (already clocked out) still leave an open punch alone.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.32. One transaction:
--   preflight → replace _time_evv_handoff → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

do $pre$
begin
  if to_regprocedure('public._time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)') is null then
    raise exception 'v20.0.32a preflight: v20.0.32 has not run (_time_evv_handoff missing)';
  end if;
  if position('least(p_at, clock_timestamp())' in pg_get_functiondef(
       '_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure)) > 0 then
    raise exception 'v20.0.32a preflight: this migration has already run';
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
  -- A live EVV visit always ends the open punch: at the visit's start, never later than now. Device
  -- and server clocks can disagree; if the device's start is at or before the punch's start, the punch
  -- ends now (keeping its real length) — the weekly calculation merges the overlap.
  v_end := least(p_at, clock_timestamp());
  if v_end <= v_punch.clock_in_at then
    v_end := greatest(clock_timestamp(), v_punch.clock_in_at + interval '1 microsecond');
  end if;
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

-- Self-test — always rolled back. Every hand-off call and its check are separate statements.
do $test$
declare
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_staff  uuid;
  v_p      uuid;
  v_in     timestamptz;
  v_closed uuid;
begin
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from evv_sessions e where e.staff_id = s.id and e.clock_out_at is null)
    and not exists (select 1 from time_punches t where t.staff_id = s.id and t.clock_out_at is null)
  order by s.created_at, s.id limit 1;
  if v_staff is null then
    raise exception 'SELFTEST FAIL 0: needs an active staff member with no open EVV visit or punch';
  end if;

  begin
    -- 1. Normal case: the punch ends at the visit's start
    v_p := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
    v_closed := _time_evv_handoff(v_org, v_staff, clock_timestamp(), true, 40.730000, -111.860000);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p and clock_out_at is not null and clock_out_lat = 40.73) then
      raise exception 'SELFTEST FAIL 1: live EVV clock-in did not end the punch';
    end if;

    -- 2. Device clock behind: an EVV start before the punch's start still ends it — now
    v_p := _time_clock_in(v_org, v_staff, 'meeting', null, null, null, null, null, 'self-test');
    select clock_in_at into v_in from time_punches where id = v_p;
    v_closed := _time_evv_handoff(v_org, v_staff, v_in - interval '2 minutes', true, null, null);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p
                      and clock_out_at > v_in and clock_out_at <= clock_timestamp()) then
      raise exception 'SELFTEST FAIL 2: a live EVV clock-in with an earlier device time left the punch open';
    end if;

    -- 3. Device clock ahead: the punch never ends in the future
    v_p := _time_clock_in(v_org, v_staff, 'admin', null, null, null, null, null, 'self-test');
    v_closed := _time_evv_handoff(v_org, v_staff, clock_timestamp() + interval '1 hour', true, null, null);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p
                      and clock_out_at <= greatest(clock_timestamp(), clock_in_at + interval '1 microsecond')) then
      raise exception 'SELFTEST FAIL 3: the punch was ended in the future';
    end if;

    -- 4. A completed EVV entry still leaves an open punch alone
    v_p := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
    v_closed := _time_evv_handoff(v_org, v_staff, clock_timestamp(), false, null, null);
    if v_closed is not null
       or not exists (select 1 from time_punches where id = v_p and clock_out_at is null) then
      raise exception 'SELFTEST FAIL 4: a completed EVV entry ended the punch';
    end if;

    raise exception 'SELFTEST_ROLLBACK' using errcode = 'PRVOK';
  exception when sqlstate 'PRVOK' then
    null;  -- every self-test write above is rolled back here
  end;
end
$test$;

commit;

-- Verification table (paste this result into the PR and the chat)
with checks as (
  select 1 as n, 'Hand-off always ends the punch on a live EVV clock-in' as check_name,
         (position('least(p_at, clock_timestamp())' in pg_get_functiondef(
            '_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure)) > 0)::text as got,
         'true' as want
  union all
  select 2, 'Old "punch started later" skip removed',
         (position('p_at <= v_punch.clock_in_at' in pg_get_functiondef(
            '_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure)) = 0)::text, 'true'
  union all
  select 3, 'EVV hand-off trigger still on evv_sessions',
         (select count(*) from pg_trigger tg
          where tg.tgrelid = 'public.evv_sessions'::regclass and tg.tgname = 'evv_sessions_time_punch_handoff'
            and not tg.tgisinternal)::text, '1'
  union all
  select 4, 'Hand-off function callable by clients',
         (has_function_privilege('authenticated', '_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure, 'EXECUTE')
          or has_function_privilege('anon', '_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure, 'EXECUTE'))::text,
         'false'
  union all
  select 5, 'Self-test leftovers (punches with note self-test)',
         (select count(*) from time_punches where note = 'self-test')::text, '0'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
