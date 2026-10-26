-- =====================================================================================
-- sql/v20.0.32c_server_clock.sql
-- Provly pay engine — one clock for pay hours (pay-engine Decision 16).
--
-- v20.0.32, v20.0.32a and the round-3 draft v20.0.32b_time_clock_same_time.sql have run; this is a new
-- migration that supersedes 32b. It defines the hand-off, clock-in and clock-out functions outright,
-- so the result is the same whether or not 32b ran: clock-in starts at server time again (32b's
-- "start where the last punch ended" rule is removed) and the hand-off uses server time with no
-- device-time caps.
--
-- Pay hours are counted from the SERVER's clock. Time-clock punches already are. EVV sessions now get
-- two timestamps the database sets itself — when the live clock-in arrived and when the live clock-out
-- arrived. The phone's EVV times (clock_in_at / clock_out_at) are untouched and stay the EVV and
-- billing record. Both sides of the EVV hand-off now use the same clock, so it is exact: the open
-- punch ends at the same server moment the EVV clock-in arrives, in the same transaction — no gap,
-- no overlap, no future times.
--
--   · evv_sessions.server_clock_in_at / server_clock_out_at — set only by the database; any value a
--     client sends is ignored. Set for live clock-ins and their clock-outs. Completed or back-dated
--     entries get none (pay uses their recorded times, like any manual entry).
--   · Corrected EVV sessions (rows in evv_edit_log) use their corrected times for pay; the weekly
--     calculation (R1c) applies that rule. A server clock-out stamped by a correction is ignored there.
--   · Existing EVV rows keep null server times; R1c uses their recorded times.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.32b (or v20.0.32a). One transaction:
--   preflight → columns → functions + triggers → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

do $pre$
declare
  v_def text;
begin
  if to_regprocedure('public._time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)') is null then
    raise exception 'v20.0.32c preflight: v20.0.32 has not run';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'evv_sessions' and column_name = 'server_clock_in_at') then
    raise exception 'v20.0.32c preflight: this migration has already run';
  end if;
  -- 32a's hand-off has least(p_at, clock_timestamp()); 32b's has least(p_at, clock_timestamp() + …)
  v_def := pg_get_functiondef('_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure);
  if position('least(p_at, clock_timestamp()' in v_def) = 0 then
    raise exception 'v20.0.32c preflight: unexpected hand-off definition — v20.0.32a has not run';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.evv_sessions'::regclass
                 and tgname = 'evv_sessions_time_punch_handoff' and not tgisinternal) then
    raise exception 'v20.0.32c preflight: the EVV hand-off trigger is missing';
  end if;
end
$pre$;

-- -------------------------------------------------------------------------------------
-- 1. Server timestamps on EVV sessions (nullable; existing rows stay null)
-- -------------------------------------------------------------------------------------
alter table evv_sessions
  add column server_clock_in_at  timestamptz,
  add column server_clock_out_at timestamptz;

alter table evv_sessions
  add constraint evv_sessions_server_times_order
  check (server_clock_out_at is null or server_clock_in_at is null or server_clock_out_at >= server_clock_in_at);

comment on column evv_sessions.server_clock_in_at is
  'Set by the database when a live EVV clock-in arrives (pay-engine Decision 16). Pay hours use server times; clock_in_at stays the device time EVV recorded.';
comment on column evv_sessions.server_clock_out_at is
  'Set by the database when the live EVV clock-out arrives (pay-engine Decision 16). Pay hours use server times; clock_out_at stays the device time EVV recorded.';

-- -------------------------------------------------------------------------------------
-- 2. Time clock on the server clock
-- -------------------------------------------------------------------------------------
-- Clock in starts at the server time (restores v20.0.32; removes 32b's carry-forward start).
create or replace function _time_clock_in(p_org uuid, p_staff uuid, p_work_type text, p_person uuid,
                                          p_service_code text, p_shift uuid, p_lat numeric, p_lng numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code uuid;
  v_evv  boolean;
  v_id   uuid;
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

-- Clock out at the server time, never at or before the punch's own start.
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
     set clock_out_at  = greatest(clock_timestamp(), (v_old->>'clock_in_at')::timestamptz + interval '1 microsecond'),
         clock_out_lat = p_lat,
         clock_out_lng = p_lng
   where id = p_punch;
  perform _pay_audit(p_org, 'time_punch_out', 'time_punches', p_punch, v_old,
                     (select to_jsonb(t) from time_punches t where t.id = p_punch), p_staff);
end
$$;

-- p_at is the server time the EVV clock-in arrived — the same clock as the punch — so the punch ends
-- exactly then. (The one-microsecond floor only guards the impossible case of an equal start.)
create or replace function _time_evv_handoff(p_org uuid, p_staff uuid, p_at timestamptz, p_live boolean,
                                             p_lat numeric, p_lng numeric)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_punch time_punches;
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
  update time_punches
     set clock_out_at  = greatest(p_at, v_punch.clock_in_at + interval '1 microsecond'),
         clock_out_lat = case when v_ok then round(p_lat, 6) end,
         clock_out_lng = case when v_ok then round(p_lng, 6) end
   where id = v_punch.id;
  perform _pay_audit(p_org, 'time_punch_evv', 'time_punches', v_punch.id, to_jsonb(v_punch),
                     (select to_jsonb(t) from time_punches t where t.id = v_punch.id), p_staff);
  return v_punch.id;
end
$$;

-- -------------------------------------------------------------------------------------
-- 3. EVV triggers
-- -------------------------------------------------------------------------------------
-- BEFORE INSERT (existing trigger evv_sessions_time_punch_handoff): stamp the server clock-in time and
-- hand off the open punch at that same moment.
create or replace function trg_evv_time_punch_handoff() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_now timestamptz := clock_timestamp();
begin
  if new.clock_out_at is null then
    new.server_clock_in_at  := v_now;
    new.server_clock_out_at := null;
    perform _time_evv_handoff(new.org_id, new.staff_id, v_now, true, new.clock_in_lat, new.clock_in_lng);
  else
    -- a completed or back-dated entry: no server times (pay uses its recorded times), no hand-off
    new.server_clock_in_at  := null;
    new.server_clock_out_at := null;
  end if;
  return new;
end
$$;

-- BEFORE UPDATE: the server times are the database's alone. The clock-in time never changes after
-- insert; the clock-out time is stamped when a live session's clock-out arrives.
create function trg_evv_server_times() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.server_clock_in_at := old.server_clock_in_at;
  if new.clock_out_at is null then
    new.server_clock_out_at := null;
  elsif old.clock_out_at is null and old.server_clock_in_at is not null then
    new.server_clock_out_at := clock_timestamp();
  else
    new.server_clock_out_at := old.server_clock_out_at;
  end if;
  return new;
end
$$;

create trigger evv_sessions_server_times
  before update on evv_sessions
  for each row execute function trg_evv_server_times();

revoke all on function _time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text) from public, anon, authenticated;
revoke all on function _time_clock_out(uuid,uuid,uuid,numeric,numeric) from public, anon, authenticated;
revoke all on function _time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric) from public, anon, authenticated;
revoke all on function trg_evv_time_punch_handoff() from public, anon, authenticated;
revoke all on function trg_evv_server_times() from public, anon, authenticated;

-- -------------------------------------------------------------------------------------
-- 4. Self-test — always rolled back. Every write and its check are separate statements.
-- -------------------------------------------------------------------------------------
do $test$
declare
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_staff  uuid;
  v_person uuid;
  v_code   uuid;
  v_p      uuid;
  v_sess   uuid;
  v_done   uuid;
  v_srv    timestamptz;
  v_closed uuid;
begin
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from evv_sessions e where e.staff_id = s.id and e.clock_out_at is null)
    and not exists (select 1 from time_punches t where t.staff_id = s.id
                    and (t.clock_out_at is null or t.clock_out_at > clock_timestamp()))
  order by s.created_at, s.id limit 1;
  select id into v_person from persons where org_id = v_org and is_active order by created_at, id limit 1;
  select id into v_code from service_code_definitions where evv_required order by code limit 1;
  if v_staff is null or v_person is null or v_code is null then
    raise exception 'SELFTEST FAIL 0: needs an active staff member with nothing open, an active Person and an EVV code';
  end if;

  begin
    -- 1. Clock in starts at server time; the hand-off ends the punch exactly at the server time given
    v_srv := clock_timestamp();
    v_p := _time_clock_in(v_org, v_staff, 'training', null, null, null, null, null, 'self-test');
    if not exists (select 1 from time_punches where id = v_p
                   and clock_in_at >= v_srv and clock_in_at <= clock_timestamp()) then
      raise exception 'SELFTEST FAIL 1: clock-in did not start at server time';
    end if;
    v_srv := clock_timestamp();
    v_closed := _time_evv_handoff(v_org, v_staff, v_srv, true, null, null);
    if v_closed is distinct from v_p
       or not exists (select 1 from time_punches where id = v_p
                      and clock_out_at = greatest(v_srv, clock_in_at + interval '1 microsecond')) then
      raise exception 'SELFTEST FAIL 1b: hand-off did not end the punch at the given server time';
    end if;

    -- 2. A live EVV clock-in from a phone 10 minutes ahead: the database stamps its own time, and the
    --    open punch ends at exactly that moment (no gap, whatever the phone says)
    v_p := _time_clock_in(v_org, v_staff, 'admin', null, null, null, null, null, 'self-test');
    insert into evv_sessions (org_id, staff_id, person_id, service_code_id, clock_in_at, exceptions)
    values (v_org, v_staff, v_person, v_code, now() + interval '10 minutes', '[]'::jsonb)
    returning id into v_sess;
    if not exists (select 1 from evv_sessions e join time_punches t on t.id = v_p
                   where e.id = v_sess and e.server_clock_in_at is not null
                     and t.clock_out_at = e.server_clock_in_at) then
      raise exception 'SELFTEST FAIL 2: live EVV clock-in did not stamp server time or hand off at it';
    end if;

    -- 3. A client can't set the server clock-in time
    update evv_sessions set server_clock_in_at = now() - interval '1 day' where id = v_sess;
    if exists (select 1 from evv_sessions where id = v_sess and server_clock_in_at < now() - interval '1 hour') then
      raise exception 'SELFTEST FAIL 3: a client-sent server_clock_in_at was kept';
    end if;

    -- 4. The live clock-out stamps the server clock-out time; a client value is ignored
    update evv_sessions set clock_out_at = now() + interval '25 minutes',
                            server_clock_out_at = now() - interval '1 day'
    where id = v_sess;
    if not exists (select 1 from evv_sessions where id = v_sess
                   and server_clock_out_at is not null and server_clock_out_at >= server_clock_in_at
                   and server_clock_out_at > now() - interval '1 hour') then
      raise exception 'SELFTEST FAIL 4: live clock-out did not stamp the server time';
    end if;

    -- 5. A completed entry gets no server times and leaves an open punch alone
    v_p := _time_clock_in(v_org, v_staff, 'meeting', null, null, null, null, null, 'self-test');
    insert into evv_sessions (org_id, staff_id, person_id, service_code_id, clock_in_at, clock_out_at, exceptions)
    values (v_org, v_staff, v_person, v_code, now() - interval '3 hours', now() - interval '2 hours', '[]'::jsonb)
    returning id into v_done;
    if not exists (select 1 from evv_sessions where id = v_done
                   and server_clock_in_at is null and server_clock_out_at is null)
       or not exists (select 1 from time_punches where id = v_p and clock_out_at is null) then
      raise exception 'SELFTEST FAIL 5: a completed EVV entry got server times or ended the punch';
    end if;

    -- 6. Clock out of that punch lands at server time, after its start
    perform _time_clock_out(v_org, v_staff, v_p, null, null);
    if not exists (select 1 from time_punches where id = v_p
                   and clock_out_at > clock_in_at and clock_out_at <= clock_timestamp()) then
      raise exception 'SELFTEST FAIL 6: clock-out not at server time';
    end if;

    raise exception 'SELFTEST_ROLLBACK' using errcode = 'PRVOK';
  exception when sqlstate 'PRVOK' then
    null;  -- every self-test write above (punches and EVV rows) is rolled back here
  end;
end
$test$;

commit;

-- -------------------------------------------------------------------------------------
-- 5. Verification table (paste this result into the PR and the chat)
-- -------------------------------------------------------------------------------------
with checks as (
  select 1 as n, 'Server timestamp columns on evv_sessions' as check_name,
         (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'evv_sessions'
            and column_name in ('server_clock_in_at','server_clock_out_at'))::text as got, '2' as want
  union all
  select 2, 'EVV clock-in stamps server time and hands off at it',
         (position('new.server_clock_in_at  := v_now' in pg_get_functiondef('trg_evv_time_punch_handoff()'::regprocedure)) > 0)::text, 'true'
  union all
  select 3, 'Hand-off uses the server time exactly (no device-time caps)',
         (position('least(' in pg_get_functiondef('_time_evv_handoff(uuid,uuid,timestamptz,boolean,numeric,numeric)'::regprocedure)) = 0)::text, 'true'
  union all
  select 4, 'Clock in starts at server time (no carry-forward from 32b)',
         (position('v_start' in pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)) = 0)::text, 'true'
  union all
  select 5, 'EVV triggers: hand-off (insert) + server times (update)',
         (select count(*) from pg_trigger
          where tgrelid = 'public.evv_sessions'::regclass and not tgisinternal
            and tgname in ('evv_sessions_time_punch_handoff','evv_sessions_server_times'))::text, '2'
  union all
  select 6, 'Server-times order constraint',
         (select count(*) from pg_constraint where conname = 'evv_sessions_server_times_order')::text, '1'
  union all
  select 7, 'Time/EVV internal functions callable by clients',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public'
            and p.proname in ('_time_staff_lock','_time_clock_in','_time_clock_out','_time_correct_punch',
                              '_time_evv_handoff','trg_evv_time_punch_handoff','trg_evv_server_times')
            and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or has_function_privilege('anon', p.oid, 'EXECUTE')))::text, '0'
  union all
  select 8, 'Self-test leftovers (punches with note self-test)',
         (select count(*) from time_punches where note = 'self-test')::text, '0'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
