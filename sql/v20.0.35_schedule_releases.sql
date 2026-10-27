-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.35_schedule_releases.sql
-- Provly pay engine — R1b part 3: schedule releases and release notices (pay-engine Decision 9;
-- SL policy §4 "off-duty gap")
--
-- A gap between two pieces of scheduled work is unpaid only when all three hold: the schedule released
-- the staff member for it, they were told at clock-out (a logged notice), and the gap is at least the
-- drive time plus 30 minutes. This migration records the first two; R1c applies the test.
--
--   1. schedule_releases — a release between two scheduled items (shifts or work blocks) for one staff
--      member on one day; its return time is the next item's start. Or an on-the-spot release a
--      supervisor issues (the Person cancelled, say) with a return time. Never deleted: revoked, with a
--      reason. One active release per "before" item.
--   2. release_notices — when the staff member was told: at clock-out in the app (they tap OK), or by
--      a supervisor issuing an on-the-spot release. One per release and channel.
--   3. RPCs: release_create, release_revoke, release_issue_now (manage/operate); release_for_clockout,
--      release_acknowledge (the staff member themself, for their own visit or punch).
--
-- Concurrency: creating a release locks both items (FOR SHARE), so an edit and a release can't pass
-- each other; revoke and acknowledge lock the release (FOR UPDATE), so they serialize.
-- R1c validity rule (recorded here, applied there): a scheduled release counts only if it is not revoked
-- and both its items still exist and are not cancelled or no-shows.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.34b. One transaction:
--   preflight → tables → functions → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

do $pre$
begin
  if to_regprocedure('public._time_match_schedule(uuid,uuid,text,uuid,uuid,timestamp without time zone)') is null then
    raise exception 'v20.0.35 preflight: v20.0.34b has not run';
  end if;
  if to_regclass('public.schedule_releases') is not null then
    raise exception 'v20.0.35 preflight: this migration has already run';
  end if;
end
$pre$;

-- Lets releases reference shifts within the same organization (shifts.id is already unique).
create unique index if not exists shifts_id_org_uniq on shifts (id, org_id);

-- -------------------------------------------------------------------------------------
-- 1. Tables
-- -------------------------------------------------------------------------------------
create table schedule_releases (
  id                   uuid primary key default gen_random_uuid(),
  org_id               uuid not null references organizations(id) on delete cascade,
  staff_id             uuid not null,
  kind                 text not null check (kind in ('scheduled','on_the_spot')),
  release_date         date not null,              -- the organization's local date
  before_shift_id      uuid,
  before_work_block_id uuid,
  after_shift_id       uuid,
  after_work_block_id  uuid,
  return_at            timestamptz not null,
  note                 text,
  created_by           uuid,
  created_at           timestamptz not null default now(),
  revoked_at           timestamptz,
  revoked_by           uuid,
  revoke_reason        text,
  unique (id, org_id),
  foreign key (staff_id, org_id)             references staff(id, org_id),
  foreign key (created_by, org_id)           references staff(id, org_id),
  foreign key (revoked_by, org_id)           references staff(id, org_id),
  -- an item that is deleted later leaves the release in place (and invalid for R1c); notices survive
  foreign key (before_shift_id, org_id)      references shifts(id, org_id)      on delete set null (before_shift_id),
  foreign key (after_shift_id, org_id)       references shifts(id, org_id)      on delete set null (after_shift_id),
  foreign key (before_work_block_id, org_id) references work_blocks(id, org_id) on delete set null (before_work_block_id),
  foreign key (after_work_block_id, org_id)  references work_blocks(id, org_id) on delete set null (after_work_block_id),
  check (num_nonnulls(before_shift_id, before_work_block_id) <= 1),
  check (num_nonnulls(after_shift_id, after_work_block_id) <= 1),
  check (kind = 'scheduled' or num_nonnulls(after_shift_id, after_work_block_id) = 0),
  check ((revoked_at is null) = (revoke_reason is null))
);

create unique index schedule_releases_one_per_before_shift on schedule_releases (before_shift_id)
  where revoked_at is null and before_shift_id is not null;
create unique index schedule_releases_one_per_before_block on schedule_releases (before_work_block_id)
  where revoked_at is null and before_work_block_id is not null;
create index schedule_releases_staff_date on schedule_releases (staff_id, release_date);
create index schedule_releases_org_date   on schedule_releases (org_id, release_date);

create table release_notices (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  release_id  uuid not null,
  staff_id    uuid not null,
  channel     text not null check (channel in ('clock_out','supervisor')),
  noticed_at  timestamptz not null,                -- server time
  recorded_by uuid,
  unique (release_id, channel),
  foreign key (release_id, org_id)  references schedule_releases(id, org_id) on delete cascade,
  foreign key (staff_id, org_id)    references staff(id, org_id),
  foreign key (recorded_by, org_id) references staff(id, org_id)
);

alter table schedule_releases enable row level security;
alter table release_notices   enable row level security;

do $rls$
declare
  t text;
begin
  foreach t in array array['schedule_releases','release_notices'] loop
    execute format('revoke all on table %I from anon, public', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on table %I from authenticated', t);
    execute format('grant select on table %I to authenticated', t);
    execute format($p$create policy %I on %I as restrictive for all to authenticated
                      using (org_id = (select org_id()) and (select member_role()) is not null)
                      with check (org_id = (select org_id()) and (select member_role()) is not null)$p$,
                   t || '_tenant_guard', t);
    execute format($p$create policy %I on %I for select to authenticated
                      using ((select access_tier()) in ('manage','operate') or staff_id = (select my_staff_id()))$p$,
                   t || '_read', t);
  end loop;
end
$rls$;

-- -------------------------------------------------------------------------------------
-- 2. Internal functions (take org and actor explicitly; the public wrappers derive them)
-- -------------------------------------------------------------------------------------

-- One scheduled item, locked FOR SHARE: its staff, local date, start and end (local), and whether it
-- still stands (not cancelled / no-show).
create function _release_item(p_org uuid, p_kind text, p_id uuid,
                              out o_staff uuid, out o_date date, out o_start timestamp, out o_end timestamp,
                              out o_active boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_kind = 'shift' then
    select sh.staff_id, sh.scheduled_date, sh.scheduled_date + sh.scheduled_start,
           sh.scheduled_date + sh.scheduled_end
                + case when sh.scheduled_end <= sh.scheduled_start then interval '1 day' else interval '0' end,
           sh.status not in ('cancelled','missed')
      into o_staff, o_date, o_start, o_end, o_active
      from shifts sh where sh.id = p_id and sh.org_id = p_org
      for share;
  elsif p_kind = 'work_block' then
    select w.staff_id, w.scheduled_date, w.scheduled_date + w.scheduled_start, w.scheduled_date + w.scheduled_end,
           w.status = 'scheduled'
      into o_staff, o_date, o_start, o_end, o_active
      from work_blocks w where w.id = p_id and w.org_id = p_org
      for share;
  else
    raise exception 'unknown item kind %', p_kind using errcode = '23514';
  end if;
  if o_staff is null then
    raise exception '% not found', replace(p_kind, '_', ' ') using errcode = 'P0002';
  end if;
end
$$;

create function _release_create(p_org uuid, p_actor uuid, p_before_kind text, p_before_id uuid,
                                p_after_kind text, p_after_id uuid, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b  record;
  a  record;
  v_id uuid;
begin
  select * into b from _release_item(p_org, p_before_kind, p_before_id);
  select * into a from _release_item(p_org, p_after_kind, p_after_id);
  if b.o_staff <> a.o_staff then
    raise exception 'both items must belong to the same staff member' using errcode = '23514';
  end if;
  if not b.o_active or not a.o_active then
    raise exception 'a cancelled or no-show item can''t be part of a release' using errcode = '23514';
  end if;
  if a.o_start < b.o_end then
    raise exception 'the next item must start after the first one ends' using errcode = '23514';
  end if;
  if a.o_start::date <> b.o_end::date then
    raise exception 'a release covers a gap within one day' using errcode = '23514';
  end if;
  begin
    insert into schedule_releases (org_id, staff_id, kind, release_date,
                                   before_shift_id, before_work_block_id, after_shift_id, after_work_block_id,
                                   return_at, note, created_by)
    values (p_org, b.o_staff, 'scheduled', b.o_end::date,
            case when p_before_kind = 'shift' then p_before_id end,
            case when p_before_kind = 'work_block' then p_before_id end,
            case when p_after_kind = 'shift' then p_after_id end,
            case when p_after_kind = 'work_block' then p_after_id end,
            a.o_start at time zone _time_org_tz(p_org),
            nullif(btrim(coalesce(p_note, '')), ''), p_actor)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'this item already has an active release — revoke it first' using errcode = '23505';
  end;
  perform _pay_audit(p_org, 'release_create', 'schedule_releases', v_id, null,
                     (select to_jsonb(r) from schedule_releases r where r.id = v_id), p_actor);
  return v_id;
end
$$;

create function _release_revoke(p_org uuid, p_actor uuid, p_release uuid, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb;
begin
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'a reason is required to revoke a release' using errcode = '23514';
  end if;
  select to_jsonb(r) into v_old from schedule_releases r where r.id = p_release and r.org_id = p_org for update;
  if v_old is null then
    raise exception 'release not found' using errcode = 'P0002';
  end if;
  if v_old->>'revoked_at' is not null then
    raise exception 'this release is already revoked' using errcode = '55000';
  end if;
  update schedule_releases
     set revoked_at = now(), revoked_by = p_actor, revoke_reason = btrim(p_reason)
   where id = p_release;
  perform _pay_audit(p_org, 'release_revoke', 'schedule_releases', p_release, v_old,
                     (select to_jsonb(r) from schedule_releases r where r.id = p_release), p_actor);
end
$$;

-- On-the-spot release (e.g., the Person cancelled mid-day): the supervisor tells the staff member and
-- records it; the notice counts from this moment. The return time is a local time today, converted on
-- the server with the organization's time zone (never the browser's).
create function _release_issue_now(p_org uuid, p_actor uuid, p_staff uuid, p_return_local time, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id     uuid;
  v_now    timestamptz := clock_timestamp();
  v_tz     text := _time_org_tz(p_org);
  v_today  date := (clock_timestamp() at time zone _time_org_tz(p_org))::date;
  v_return timestamptz;
begin
  if not exists (select 1 from staff where id = p_staff and org_id = p_org and is_active) then
    raise exception 'staff member not found or inactive' using errcode = 'P0002';
  end if;
  if p_return_local is null then
    raise exception 'a return time is required' using errcode = '23514';
  end if;
  v_return := (v_today + p_return_local) at time zone v_tz;
  if v_return <= v_now then
    raise exception 'the return time must be later today' using errcode = '23514';
  end if;
  insert into schedule_releases (org_id, staff_id, kind, release_date, return_at, note, created_by)
  values (p_org, p_staff, 'on_the_spot', v_today, v_return,
          nullif(btrim(coalesce(p_note, '')), ''), p_actor)
  returning id into v_id;
  insert into release_notices (org_id, release_id, staff_id, channel, noticed_at, recorded_by)
  values (p_org, v_id, p_staff, 'supervisor', v_now, p_actor);
  perform _pay_audit(p_org, 'release_issue_now', 'schedule_releases', v_id, null,
                     (select to_jsonb(r) from schedule_releases r where r.id = v_id), p_actor);
  return v_id;
end
$$;

-- The active release that starts when this visit or punch ends: the one whose "before" item is the
-- shift or work block the visit/punch is linked to. Only for the staff member's own records.
create function _release_for_clockout(p_org uuid, p_staff uuid, p_kind text, p_id uuid)
returns table (release_id uuid, return_at timestamptz, already_noticed boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_shift uuid;
  v_block uuid;
begin
  if p_kind = 'evv' then
    select e.shift_id into v_shift from evv_sessions e
     where e.id = p_id and e.org_id = p_org and e.staff_id = p_staff;
  elsif p_kind = 'punch' then
    select t.shift_id, t.work_block_id into v_shift, v_block from time_punches t
     where t.id = p_id and t.org_id = p_org and t.staff_id = p_staff;
  else
    raise exception 'unknown record kind %', p_kind using errcode = '23514';
  end if;
  if v_shift is null and v_block is null then
    return;
  end if;
  return query
    select r.id, r.return_at,
           exists (select 1 from release_notices n where n.release_id = r.id and n.channel = 'clock_out')
      from schedule_releases r
     where r.org_id = p_org and r.staff_id = p_staff and r.revoked_at is null
       and ((v_shift is not null and r.before_shift_id = v_shift)
            or (v_block is not null and r.before_work_block_id = v_block))
     limit 1;
end
$$;

-- The staff member taps OK on "You're off duty until …" — the notice is logged at that server moment.
-- Only before the return time, only for an active release, once.
create function _release_acknowledge(p_org uuid, p_staff uuid, p_release uuid)
returns timestamptz language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r     record;
  v_now timestamptz := clock_timestamp();
  v_at  timestamptz;
begin
  select * into r from schedule_releases where id = p_release and org_id = p_org for update;
  if not found or r.staff_id <> p_staff then
    raise exception 'release not found' using errcode = 'P0002';
  end if;
  if r.revoked_at is not null then
    raise exception 'this release was revoked' using errcode = '55000';
  end if;
  if v_now >= r.return_at then
    raise exception 'the release has already ended' using errcode = '55000';
  end if;
  insert into release_notices (org_id, release_id, staff_id, channel, noticed_at, recorded_by)
  values (p_org, p_release, p_staff, 'clock_out', v_now, p_staff)
  on conflict (release_id, channel) do nothing;
  select n.noticed_at into v_at from release_notices n where n.release_id = p_release and n.channel = 'clock_out';
  return v_at;
end
$$;

-- -------------------------------------------------------------------------------------
-- 3. Public RPCs
-- -------------------------------------------------------------------------------------
create function release_create(p_before_kind text, p_before_id uuid, p_after_kind text, p_after_id uuid,
                               p_note text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select access_tier()) is distinct from 'manage' and (select access_tier()) is distinct from 'operate' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return _release_create(org_id(), my_staff_id(), p_before_kind, p_before_id, p_after_kind, p_after_id, p_note);
end
$$;

create function release_revoke(p_release uuid, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select access_tier()) is distinct from 'manage' and (select access_tier()) is distinct from 'operate' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform _release_revoke(org_id(), my_staff_id(), p_release, p_reason);
end
$$;

create function release_issue_now(p_staff uuid, p_return_local time, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select access_tier()) is distinct from 'manage' and (select access_tier()) is distinct from 'operate' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return _release_issue_now(org_id(), my_staff_id(), p_staff, p_return_local, p_note);
end
$$;

create function release_for_clockout(p_kind text, p_id uuid)
returns table (release_id uuid, return_at timestamptz, already_noticed boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if my_staff_id() is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query select * from _release_for_clockout(org_id(), my_staff_id(), p_kind, p_id);
end
$$;

create function release_acknowledge(p_release uuid)
returns timestamptz language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if my_staff_id() is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return _release_acknowledge(org_id(), my_staff_id(), p_release);
end
$$;

do $fn$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('_release_item','_release_create','_release_revoke','_release_issue_now',
                        '_release_for_clockout','_release_acknowledge',
                        'release_create','release_revoke','release_issue_now','release_for_clockout','release_acknowledge')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname not like '\_%' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end
$fn$;

-- -------------------------------------------------------------------------------------
-- 4. Self-test — always rolled back, and independent of real schedules, real punches and the time of
--    day: scheduled items live on a far-future date (2099-07-01), the test punch is in 2099 on a staff
--    member with no overlapping or open punch, and the on-the-spot check (which must use "now") is
--    skipped — never failed — within 10 minutes of local midnight.
-- -------------------------------------------------------------------------------------
do $test$
declare
  v_org   constant uuid := '00000000-0000-0000-0000-000000000001';
  v_day   constant date := date '2099-07-01';
  v_owner uuid;
  v_staff uuid;
  v_b1    uuid;
  v_b2    uuid;
  v_b3    uuid;
  v_rel   uuid;
  v_p     uuid;
  v_at    timestamptz;
  v_now   timestamptz;
  v_tz    text;
  x       record;
begin
  v_tz := _time_org_tz(v_org);
  select s.id into v_owner
  from org_members m join staff s on s.user_id = m.user_id and s.org_id = m.org_id
  where m.org_id = v_org and m.role = 'owner'
  order by m.joined_at, s.id limit 1;
  select s.id into v_staff from staff s
  where s.org_id = v_org and s.is_active
    and not exists (select 1 from time_punches t
                    where t.staff_id = s.id
                      and tstzrange(t.clock_in_at, t.clock_out_at, '[)')
                          && tstzrange(timestamptz '2099-07-01 15:00:00+00', timestamptz '2099-07-01 16:00:00+00', '[)'))
  order by s.created_at, s.id limit 1;
  if v_owner is null or v_staff is null then
    raise exception 'SELFTEST FAIL 0: needs an owner and an active staff member with no open or overlapping punch';
  end if;

  begin
    v_b1 := _work_block_save(v_org, v_owner, null, v_staff, 'meeting',  v_day, '08:00', '09:00', 'self-test');
    v_b2 := _work_block_save(v_org, v_owner, null, v_staff, 'training', v_day, '13:00', '14:00', 'self-test');
    v_b3 := _work_block_save(v_org, v_owner, null, v_staff, 'admin',    v_day, '08:30', '10:00', 'self-test');

    -- 1. A release between two items returns at the next item's start (local time)
    v_rel := _release_create(v_org, v_owner, 'work_block', v_b1, 'work_block', v_b2, 'self-test');
    if not exists (select 1 from schedule_releases
                   where id = v_rel and kind = 'scheduled' and release_date = v_day
                     and return_at = (timestamp '2099-07-01 13:00:00' at time zone v_tz)) then
      raise exception 'SELFTEST FAIL 1: release return time or date wrong';
    end if;

    -- 2. One active release per "before" item
    begin
      perform _release_create(v_org, v_owner, 'work_block', v_b1, 'work_block', v_b2, 'self-test');
      raise exception 'SELFTEST FAIL 2: a second active release for the same item was accepted';
    exception when unique_violation then null;
    end;

    -- 3. The next item must start after the first one ends
    begin
      perform _release_create(v_org, v_owner, 'work_block', v_b3, 'work_block', v_b1, 'self-test');
      raise exception 'SELFTEST FAIL 3: a release with overlapping items was accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 4. A punch linked to the "before" block finds the release; acknowledging logs one notice
    insert into time_punches (org_id, staff_id, work_type, work_block_id, clock_in_at, clock_out_at, note)
    values (v_org, v_staff, 'meeting', v_b1, timestamptz '2099-07-01 15:00:00+00', timestamptz '2099-07-01 15:30:00+00', 'self-test')
    returning id into v_p;
    select * into x from _release_for_clockout(v_org, v_staff, 'punch', v_p);
    if not found or x.release_id is distinct from v_rel or x.already_noticed then
      raise exception 'SELFTEST FAIL 4: clock-out did not find its release';
    end if;
    v_at := _release_acknowledge(v_org, v_staff, v_rel);
    perform _release_acknowledge(v_org, v_staff, v_rel);
    if v_at is null or (select count(*) from release_notices where release_id = v_rel) <> 1 then
      raise exception 'SELFTEST FAIL 4b: acknowledging did not log exactly one notice';
    end if;
    select * into x from _release_for_clockout(v_org, v_staff, 'punch', v_p);
    if not found or not x.already_noticed then
      raise exception 'SELFTEST FAIL 4c: the notice was not reported as logged';
    end if;

    -- 5. Someone else's punch finds nothing
    if exists (select 1 from _release_for_clockout(v_org, v_owner, 'punch', v_p)) and v_owner <> v_staff then
      raise exception 'SELFTEST FAIL 5: another staff member saw this release';
    end if;

    -- 6. Revoking needs a reason; a revoked release can't be acknowledged; the item is free again
    begin
      perform _release_revoke(v_org, v_owner, v_rel, '');
      raise exception 'SELFTEST FAIL 6: revoke without a reason accepted';
    exception when sqlstate '23514' then null;
    end;
    perform _release_revoke(v_org, v_owner, v_rel, 'self-test');
    begin
      perform _release_acknowledge(v_org, v_staff, v_rel);
      raise exception 'SELFTEST FAIL 6b: a revoked release was acknowledged';
    exception when sqlstate '55000' then null;
    end;
    perform _release_create(v_org, v_owner, 'work_block', v_b1, 'work_block', v_b2, 'self-test');

    -- 7. A cancelled item can't be part of a release
    perform _work_block_cancel(v_org, v_owner, v_b3, 'no_fault', 'self-test');
    begin
      perform _release_create(v_org, v_owner, 'work_block', v_b3, 'work_block', v_b2, 'self-test');
      raise exception 'SELFTEST FAIL 7: a cancelled item was released';
    exception when sqlstate '23514' then null;
    end;

    -- 8. On-the-spot: logs a supervisor notice at once; the return time must be later today.
    --    (Skipped, never failed, within 10 minutes of local midnight — "today" is ambiguous there.)
    v_now := clock_timestamp();
    if ((v_now + interval '10 minutes') at time zone v_tz)::date = (v_now at time zone v_tz)::date
       and ((v_now - interval '10 minutes') at time zone v_tz)::date = (v_now at time zone v_tz)::date then
      v_rel := _release_issue_now(v_org, v_owner, v_staff, ((v_now + interval '5 minutes') at time zone v_tz)::time, 'self-test');
      if not exists (select 1 from release_notices where release_id = v_rel and channel = 'supervisor' and recorded_by = v_owner) then
        raise exception 'SELFTEST FAIL 8: on-the-spot release has no supervisor notice';
      end if;
      begin
        perform _release_issue_now(v_org, v_owner, v_staff, ((v_now - interval '5 minutes') at time zone v_tz)::time, 'self-test');
        raise exception 'SELFTEST FAIL 8b: a return time in the past was accepted';
      exception when sqlstate '23514' then null;
      end;
    end if;

    -- 9. Without a signed-in session the RPCs refuse
    begin
      perform release_create('work_block', v_b1, 'work_block', v_b2, 'self-test');
      raise exception 'SELFTEST FAIL 9: release_create ran without a session';
    exception when insufficient_privilege then null;
    end;
    begin
      perform release_acknowledge(v_rel);
      raise exception 'SELFTEST FAIL 9b: release_acknowledge ran without a session';
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
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok from (
  select 1 n, 'Release + notice tables with RLS' check_name,
    (select count(*) from pg_class where relname in ('schedule_releases','release_notices') and relrowsecurity)::text got, '2' want
  union all select 2, 'Policies on the two tables',
    (select count(*) from pg_policies where tablename in ('schedule_releases','release_notices'))::text, '4'
  union all select 3, 'Clients cannot write releases or notices directly',
    (has_table_privilege('authenticated', 'public.schedule_releases', 'INSERT')
     or has_table_privilege('authenticated', 'public.release_notices', 'INSERT')
     or has_table_privilege('authenticated', 'public.schedule_releases', 'UPDATE'))::text, 'false'
  union all select 4, 'One active release per item (unique indexes)',
    (select count(*) from pg_indexes where indexname in ('schedule_releases_one_per_before_shift','schedule_releases_one_per_before_block'))::text, '2'
  union all select 5, 'Public release RPCs for signed-in users (not anon)',
    (select count(*) from pg_proc where proname in ('release_create','release_revoke','release_issue_now','release_for_clockout','release_acknowledge')
     and has_function_privilege('authenticated', oid, 'EXECUTE') and not has_function_privilege('anon', oid, 'EXECUTE'))::text, '5'
  union all select 6, 'Internal release functions callable by clients',
    (select count(*) from pg_proc where proname in ('_release_item','_release_create','_release_revoke','_release_issue_now','_release_for_clockout','_release_acknowledge')
     and (has_function_privilege('authenticated', oid, 'EXECUTE') or has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  union all select 7, 'Self-test leftovers (releases/blocks/punches)',
    (select count(*) from schedule_releases where note = 'self-test')::text || '/' ||
    (select count(*) from work_blocks where note like 'self-test%')::text || '/' ||
    (select count(*) from time_punches where note = 'self-test')::text, '0/0/0'
) t
order by n;
