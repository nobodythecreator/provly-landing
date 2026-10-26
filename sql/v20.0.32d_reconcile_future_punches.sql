-- =====================================================================================
-- sql/v20.0.32d_reconcile_future_punches.sql
-- Provly pay engine — v20.0.32 review round 4 (32, 32a, 32b and 32c have run; this is a new migration)
--
-- While v20.0.32b was live, a punch could end — or the next one start — up to 15 minutes ahead of
-- server time. v20.0.32c put clock-in back on server time, so such a row would block the worker's next
-- clock-in (the no-overlap rule) until its future time passed. This migration brings any such row back
-- to server time as a logged correction: originals kept (if not already captured), corrected_at set,
-- one time_punch_edit_log row per changed field.
--
-- In production this is expected to be a no-op: the time clock app hasn't shipped, so no real punches
-- exist yet. The verification table shows how many rows there are and that none are future-dated.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.32c. One transaction:
--   preflight → reconcile function → rolled-back self-test → reconcile for real → COMMIT → verification.
-- =====================================================================================

begin;

do $pre$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'evv_sessions' and column_name = 'server_clock_in_at') then
    raise exception 'v20.0.32d preflight: v20.0.32c has not run';
  end if;
  if to_regprocedure('public._time_reconcile_future()') is not null then
    raise exception 'v20.0.32d preflight: this migration has already run';
  end if;
end
$pre$;

-- Brings every punch with a start or end later than now back to now (never at or before its own start),
-- as a logged correction. Rows are processed per staff member in start order, so shrinking an earlier
-- punch always happens before a later one moves — the no-overlap rule is never broken mid-way.
create function _time_reconcile_future()
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r       time_punches;
  v_now   timestamptz;
  v_in    timestamptz;
  v_out   timestamptz;
  v_count integer := 0;
  v_note  constant text := 'v20.0.32d: reconciled a future-dated time from the v20.0.32b hand-off to server time';
begin
  for r in
    select * from time_punches
    where clock_in_at > clock_timestamp() or clock_out_at > clock_timestamp()
    order by staff_id, clock_in_at
    for update
  loop
    v_now := clock_timestamp();
    v_in  := least(r.clock_in_at, v_now);
    v_out := case when r.clock_out_at is null then null
                  else greatest(least(r.clock_out_at, v_now), v_in + interval '1 microsecond') end;

    update time_punches set
      original_clock_in_at  = case when corrected_at is null then clock_in_at  else original_clock_in_at  end,
      original_clock_out_at = case when corrected_at is null then clock_out_at else original_clock_out_at end,
      corrected_at          = coalesce(corrected_at, v_now),
      clock_in_at           = v_in,
      clock_out_at          = v_out
    where id = r.id;

    if v_in is distinct from r.clock_in_at then
      insert into time_punch_edit_log (org_id, punch_id, field, old_value, new_value, reason)
      values (r.org_id, r.id, 'clock_in_at', r.clock_in_at, v_in, v_note);
    end if;
    if v_out is distinct from r.clock_out_at then
      insert into time_punch_edit_log (org_id, punch_id, field, old_value, new_value, reason)
      values (r.org_id, r.id, 'clock_out_at', r.clock_out_at, v_out, v_note);
    end if;
    perform _pay_audit(r.org_id, 'time_punch_fix', 'time_punches', r.id, to_jsonb(r),
                       (select to_jsonb(t) || jsonb_build_object('reason', v_note)
                        from time_punches t where t.id = r.id), null);
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

revoke all on function _time_reconcile_future() from public, anon, authenticated;

-- Self-test — always rolled back: two back-to-back future-dated punches (the 32b pattern) are brought
-- to server time, logged, and the worker can clock in right after.
do $test$
declare
  v_org   constant uuid := '00000000-0000-0000-0000-000000000001';
  v_staff uuid;
  v_a     uuid;
  v_b     uuid;
  v_c     uuid;
  v_aend  timestamptz;
  v_n     integer;
begin
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from evv_sessions e where e.staff_id = s.id and e.clock_out_at is null)
    and not exists (select 1 from time_punches t where t.staff_id = s.id)
  order by s.created_at, s.id limit 1;
  if v_staff is null then
    raise exception 'SELFTEST FAIL 0: needs an active staff member with no punches and no open EVV visit';
  end if;

  begin
    -- A ends 10 minutes ahead (32b hand-off); B starts where A ended and ends just after (32b carry-forward)
    v_aend := clock_timestamp() + interval '10 minutes';
    insert into time_punches (org_id, staff_id, work_type, clock_in_at, clock_out_at, note)
    values (v_org, v_staff, 'training', clock_timestamp() - interval '1 hour', v_aend, 'self-test')
    returning id into v_a;
    insert into time_punches (org_id, staff_id, work_type, clock_in_at, clock_out_at, note)
    values (v_org, v_staff, 'meeting', v_aend, v_aend + interval '1 microsecond', 'self-test')
    returning id into v_b;

    v_n := _time_reconcile_future();
    if v_n < 2 then
      raise exception 'SELFTEST FAIL 1: expected both future-dated punches reconciled, got %', v_n;
    end if;
    if exists (select 1 from time_punches where id in (v_a, v_b)
               and (clock_in_at > clock_timestamp() or clock_out_at > clock_timestamp() + interval '1 second')) then
      raise exception 'SELFTEST FAIL 2: a punch is still future-dated';
    end if;
    if not exists (select 1 from time_punches where id = v_a and corrected_at is not null
                   and original_clock_out_at = v_aend)
       or not exists (select 1 from time_punch_edit_log where punch_id = v_a and field = 'clock_out_at') then
      raise exception 'SELFTEST FAIL 3: the correction was not kept or not logged';
    end if;

    -- The worker can clock in again straight away
    perform pg_sleep(0.01);
    v_c := _time_clock_in(v_org, v_staff, 'admin', null, null, null, null, null, 'self-test');
    if v_c is null then
      raise exception 'SELFTEST FAIL 4: clock-in still blocked after reconciling';
    end if;

    raise exception 'SELFTEST_ROLLBACK' using errcode = 'PRVOK';
  exception when sqlstate 'PRVOK' then
    null;  -- every self-test write above is rolled back here
  end;
end
$test$;

-- Reconcile for real (expected: 0 rows — no real punches exist yet)
select _time_reconcile_future() as reconciled_rows;

commit;

-- Verification table (paste this result into the PR and the chat)
with checks as (
  select 1 as n, 'Future-dated punches remaining' as check_name,
         (select count(*) from time_punches
          where clock_in_at > now() + interval '1 second' or clock_out_at > now() + interval '1 second')::text as got,
         '0' as want
  union all
  select 2, 'Time punches in production (expected 0 until the app ships)',
         (select count(*) from time_punches)::text, '0'
  union all
  select 3, 'Reconcile function callable by clients',
         (has_function_privilege('authenticated', '_time_reconcile_future()'::regprocedure, 'EXECUTE')
          or has_function_privilege('anon', '_time_reconcile_future()'::regprocedure, 'EXECUTE'))::text, 'false'
  union all
  select 4, 'Clock in starts at server time',
         (position('v_start' in pg_get_functiondef('_time_clock_in(uuid,uuid,text,uuid,text,uuid,numeric,numeric,text)'::regprocedure)) = 0)::text, 'true'
  union all
  select 5, 'Self-test leftovers (punches with note self-test)',
         (select count(*) from time_punches where note = 'self-test')::text, '0'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
