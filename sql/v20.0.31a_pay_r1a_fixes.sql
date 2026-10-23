-- =====================================================================================
-- sql/v20.0.31a_pay_r1a_fixes.sql
-- Provly pay engine — R1a fixes (Greptile review of PR v20.0.31, round 1). v20.0.31 has already
-- run, so these land as a new migration; v20.0.31 itself is never edited.
--
--   1. Assignments: a pay job belongs to a policy when any version references it in pay items,
--      settings (non-service job), salary rules or bonus rules. DON was wrongly rejected.
--      Overrides now apply only to pay jobs paid purely by the hour.
--   2. Approval: tier coverage is checked per pay job AND service code, so each rate set covers
--      every tier exactly once. New constraint: tiers are allowed on hourly items only.
--   3. Drafts: a draft created without a clone source gets a default settings row. The client RPC
--      pay_create_version now requires a clone source; policies built from scratch come through a
--      reviewed migration until the policy editor ships.
--
-- RUN IN SUPABASE (SQL editor), ONCE, after v20.0.31. One transaction:
--   preflight → changes → rolled-back self-test → COMMIT → verification table.
-- =====================================================================================

begin;

-- -------------------------------------------------------------------------------------
-- 0. Preflight
-- -------------------------------------------------------------------------------------
do $pre$
begin
  if to_regclass('public.pay_policies') is null then
    raise exception 'R1a fixes preflight: v20.0.31 has not run (pay_policies missing)';
  end if;
  if exists (select 1 from pg_constraint where conname = 'pay_items_tier_hour_only') then
    raise exception 'R1a fixes preflight: this migration has already run';
  end if;
  if exists (select 1 from pay_items where tier_id is not null and basis <> 'hour') then
    raise exception 'R1a fixes preflight: tiered non-hourly pay items exist — review before adding the constraint';
  end if;
end
$pre$;

-- -------------------------------------------------------------------------------------
-- 1. Tiers apply to hourly items only
-- -------------------------------------------------------------------------------------
alter table pay_items
  add constraint pay_items_tier_hour_only check (tier_id is null or basis = 'hour');

-- -------------------------------------------------------------------------------------
-- 2. Policy ↔ pay job membership (items, non-service job, salary rules, bonus rules)
-- -------------------------------------------------------------------------------------
create function _pay_policy_has_job(p_policy uuid, p_job uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from pay_items i join pay_policy_versions v on v.id = i.version_id
                 where v.policy_id = p_policy and i.pay_job_id = p_job)
      or exists (select 1 from pay_policy_settings s join pay_policy_versions v on v.id = s.version_id
                 where v.policy_id = p_policy and s.nonservice_pay_job_id = p_job)
      or exists (select 1 from pay_salary_rules r join pay_policy_versions v on v.id = r.version_id
                 where v.policy_id = p_policy and r.pay_job_id = p_job)
      or exists (select 1 from pay_bonus_rules b join pay_policy_versions v on v.id = b.version_id
                 where v.policy_id = p_policy and b.pay_job_id = p_job);
$$;

revoke all on function _pay_policy_has_job(uuid, uuid) from public, anon, authenticated;

-- -------------------------------------------------------------------------------------
-- 3. Approval validation — tier coverage per pay job and service code
-- -------------------------------------------------------------------------------------
create or replace function _pay_validate_version(p_version uuid)
returns text[] language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v        pay_policy_versions;
  v_p      text[] := '{}';
  v_min    numeric;
  v_tiers  integer;
  v_latest date;
  r        record;
begin
  select * into v from pay_policy_versions where id = p_version;
  if not exists (select 1 from pay_policy_settings where version_id = p_version) then
    v_p := array_append(v_p, 'settings row missing');
  end if;
  if not exists (select 1 from pay_items where version_id = p_version) then
    v_p := array_append(v_p, 'no pay items');
  end if;
  v_min := _pay_min_wage(v.org_id, v.effective_from);
  if exists (select 1 from pay_items
             where version_id = p_version and basis in ('hour','nonbillable_hour') and amount < v_min) then
    v_p := array_append(v_p, format('an hourly rate is below the minimum wage (%s) on %s', v_min, v.effective_from));
  end if;
  select count(*) into v_tiers from pay_tiers where version_id = p_version;
  if v_tiers > 0 then
    if not exists (select 1 from pay_tiers where version_id = p_version and rank = 0) then
      v_p := array_append(v_p, 'tiers must include rank 0 (base)');
    end if;
    -- Each (pay job, service code) hourly rate set is either flat (untiered only) or covers every
    -- tier exactly once. The natural key makes each tier appear at most once per set, so
    -- tiered = v_tiers means full coverage.
    for r in
      select j.code,
             coalesce(sc.code::text, 'any code')       as svc,
             count(i.tier_id)                           as tiered,
             count(*) filter (where i.tier_id is null)  as untiered
      from pay_items i
      join pay_jobs j on j.id = i.pay_job_id
      left join service_code_definitions sc on sc.id = i.service_code_id
      where i.version_id = p_version and i.basis = 'hour'
      group by j.code, i.service_code_id, sc.code
    loop
      if r.tiered > 0 and (r.untiered > 0 or r.tiered <> v_tiers) then
        v_p := array_append(v_p, format('pay job %s (%s) needs exactly one hourly rate per tier', r.code, r.svc));
      end if;
    end loop;
  end if;
  select max(effective_from) into v_latest
  from pay_policy_versions where policy_id = v.policy_id and status = 'approved';
  if v_latest is not null and v.effective_from <= v_latest then
    v_p := array_append(v_p, format('effective date must be after the current approved version (%s)', v_latest));
  end if;
  return v_p;
end
$$;

-- -------------------------------------------------------------------------------------
-- 4. Draft creation — every draft has a settings row
-- -------------------------------------------------------------------------------------
create or replace function _pay_create_version(p_org uuid, p_actor uuid, p_policy uuid, p_label text,
                                               p_effective_from date, p_reason text, p_clone_from uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid;
begin
  if not exists (select 1 from pay_policies where id = p_policy and org_id = p_org) then
    raise exception 'pay policy not found' using errcode = 'P0002';
  end if;
  if p_clone_from is not null and not exists (
    select 1 from pay_policy_versions where id = p_clone_from and policy_id = p_policy and org_id = p_org
  ) then
    raise exception 'clone source must be a version of the same policy' using errcode = '23514';
  end if;

  insert into pay_policy_versions (org_id, policy_id, label, effective_from, reason, created_by)
  values (p_org, p_policy, btrim(p_label), p_effective_from, btrim(p_reason), p_actor)
  returning id into v_id;

  if p_clone_from is not null then
    insert into pay_tiers (org_id, version_id, rank, name,
                           min_counted_persons, max_counted_persons, min_avg_weekly_billable_hours)
    select t.org_id, v_id, t.rank, t.name,
           t.min_counted_persons, t.max_counted_persons, t.min_avg_weekly_billable_hours
    from pay_tiers t where t.version_id = p_clone_from;

    insert into pay_items (org_id, version_id, pay_job_id, basis, service_code_id, tier_id, amount)
    select i.org_id, v_id, i.pay_job_id, i.basis, i.service_code_id, nt.id, i.amount
    from pay_items i
    left join pay_tiers ot on ot.id = i.tier_id
    left join pay_tiers nt on nt.version_id = v_id and nt.rank = ot.rank
    where i.version_id = p_clone_from;

    insert into pay_qualifiers (org_id, version_id, metric, min_value)
    select q.org_id, v_id, q.metric, q.min_value
    from pay_qualifiers q where q.version_id = p_clone_from;

    insert into pay_policy_settings (version_id, org_id, mileage_mode, mileage_fixed_rate, off_duty_buffer_min,
                                     documentation_expect_min, nonservice_pay_job_id, tier_review_cycle,
                                     tier_count_share_min, tier_max_counted_persons, tier_grace_months)
    select v_id, s.org_id, s.mileage_mode, s.mileage_fixed_rate, s.off_duty_buffer_min,
           s.documentation_expect_min, s.nonservice_pay_job_id, s.tier_review_cycle,
           s.tier_count_share_min, s.tier_max_counted_persons, s.tier_grace_months
    from pay_policy_settings s where s.version_id = p_clone_from;

    insert into pay_salary_rules (version_id, org_id, pay_job_id, conversion_min_avg_monthly, conversion_months,
                                  conversion_min_persons, conversion_person_codes, true_up_period, salary_change)
    select v_id, r.org_id, r.pay_job_id, r.conversion_min_avg_monthly, r.conversion_months,
           r.conversion_min_persons, r.conversion_person_codes, r.true_up_period, r.salary_change
    from pay_salary_rules r where r.version_id = p_clone_from;

    insert into pay_bonus_rules (version_id, org_id, pay_job_id, kind, pct, period,
                                 trigger_headcount, promotion_salary_multiplier)
    select v_id, b.org_id, b.pay_job_id, b.kind, b.pct, b.period,
           b.trigger_headcount, b.promotion_salary_multiplier
    from pay_bonus_rules b where b.version_id = p_clone_from;
  end if;

  -- Every draft can be finished: a non-cloned draft (or a clone of a source without settings)
  -- gets the default settings row (IRS mileage, 30-minute off-duty buffer).
  if not exists (select 1 from pay_policy_settings where version_id = v_id) then
    insert into pay_policy_settings (version_id, org_id) values (v_id, p_org);
  end if;

  perform _pay_audit(p_org, 'pay_version_create', 'pay_policy_versions', v_id, null,
                     (select to_jsonb(v) || jsonb_build_object('cloned_from', p_clone_from)
                      from pay_policy_versions v where v.id = v_id), p_actor);
  return v_id;
end
$$;

-- -------------------------------------------------------------------------------------
-- 5. Item editing — tiers on hourly items only (clear message ahead of the constraint)
-- -------------------------------------------------------------------------------------
create or replace function _pay_set_item(p_org uuid, p_actor uuid, p_version uuid, p_pay_job text, p_basis text,
                                         p_amount numeric, p_service_code text, p_tier_rank integer)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text;
  v_job    uuid;
  v_code   uuid;
  v_tier   uuid;
  v_id     uuid;
  v_old    jsonb;
begin
  select status into v_status from pay_policy_versions where id = p_version and org_id = p_org for update;
  if not found then
    raise exception 'pay policy version not found' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'only a draft version can be edited' using errcode = '55000';
  end if;
  if p_tier_rank is not null and p_basis <> 'hour' then
    raise exception 'tiers apply to hourly pay items only' using errcode = '23514';
  end if;
  select id into v_job from pay_jobs where org_id = p_org and code = p_pay_job;
  if v_job is null then
    raise exception 'unknown pay job %', p_pay_job using errcode = '23514';
  end if;
  if p_service_code is not null then
    select id into v_code from service_code_definitions where code = p_service_code;
    if v_code is null then
      raise exception 'unknown service code %', p_service_code using errcode = '23514';
    end if;
  end if;
  if p_tier_rank is not null then
    select id into v_tier from pay_tiers where version_id = p_version and rank = p_tier_rank;
    if v_tier is null then
      raise exception 'no tier with rank % in this version', p_tier_rank using errcode = '23514';
    end if;
  end if;

  select to_jsonb(i) into v_old from pay_items i
  where i.version_id = p_version and i.pay_job_id = v_job and i.basis = p_basis
    and i.service_code_id is not distinct from v_code and i.tier_id is not distinct from v_tier;

  insert into pay_items (org_id, version_id, pay_job_id, basis, service_code_id, tier_id, amount)
  values (p_org, p_version, v_job, p_basis, v_code, v_tier, p_amount)
  on conflict on constraint pay_items_natural_key do update set amount = excluded.amount
  returning id into v_id;

  perform _pay_audit(p_org, case when v_old is null then 'pay_item_create' else 'pay_item_update' end,
                     'pay_items', v_id, v_old,
                     (select to_jsonb(i) from pay_items i where i.id = v_id), p_actor);
  return v_id;
end
$$;

-- -------------------------------------------------------------------------------------
-- 6. Assignments — full membership check; overrides for hourly-only jobs
-- -------------------------------------------------------------------------------------
create or replace function _pay_set_assignment(p_org uuid, p_actor uuid, p_staff uuid, p_pay_job text, p_policy uuid,
                                               p_start date, p_end date, p_worker_type text,
                                               p_override_amount numeric, p_override_reason text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_emp    text;
  v_active boolean;
  v_job    uuid;
  v_reason text := nullif(btrim(coalesce(p_override_reason, '')), '');
  v_id     uuid;
begin
  if p_actor is null then
    raise exception 'an approver is required' using errcode = '23514';
  end if;
  select s.employment_type, s.is_active into v_emp, v_active from staff s where s.id = p_staff and s.org_id = p_org;
  if v_active is null then
    raise exception 'staff member not found' using errcode = 'P0002';
  end if;
  if not v_active then
    raise exception 'staff member is not active' using errcode = '23514';
  end if;
  if not exists (select 1 from pay_policies where id = p_policy and org_id = p_org and is_active) then
    raise exception 'pay policy not found or inactive' using errcode = 'P0002';
  end if;
  select id into v_job from pay_jobs where org_id = p_org and code = p_pay_job;
  if v_job is null then
    raise exception 'unknown pay job %', p_pay_job using errcode = '23514';
  end if;
  if not _pay_policy_has_job(p_policy, v_job) then
    raise exception 'pay job % is not part of this policy', p_pay_job using errcode = '23514';
  end if;
  if p_override_amount is not null then
    if v_reason is null then
      raise exception 'an override needs a reason' using errcode = '23514';
    end if;
    if not exists (select 1 from pay_items i join pay_policy_versions v on v.id = i.version_id
                   where v.policy_id = p_policy and i.pay_job_id = v_job and i.basis = 'hour')
       or exists (select 1 from pay_items i join pay_policy_versions v on v.id = i.version_id
                  where v.policy_id = p_policy and i.pay_job_id = v_job and i.basis <> 'hour') then
      raise exception 'overrides apply only to pay jobs paid by the hour' using errcode = '23514';
    end if;
    if p_override_amount < _pay_min_wage(p_org, p_start) then
      raise exception 'override is below the minimum wage on %', p_start using errcode = '23514';
    end if;
  elsif v_reason is not null then
    raise exception 'a reason was given without an override amount' using errcode = '23514';
  end if;

  insert into staff_pay_assignments (org_id, staff_id, policy_id, pay_job_id, worker_type, start_date, end_date,
                                     override_amount, override_reason, approved_by)
  values (p_org, p_staff, p_policy, v_job, coalesce(p_worker_type, v_emp), p_start, p_end,
          p_override_amount, v_reason, p_actor)
  returning id into v_id;

  perform _pay_audit(p_org, 'pay_assign_create', 'staff_pay_assignments', v_id, null,
                     (select to_jsonb(a) from staff_pay_assignments a where a.id = v_id), p_actor);
  return v_id;
end
$$;

-- -------------------------------------------------------------------------------------
-- 7. Client RPC — a new version starts from an existing one
-- -------------------------------------------------------------------------------------
create or replace function pay_create_version(p_policy uuid, p_label text, p_effective_from date, p_reason text,
                                              p_clone_from uuid default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_policies') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  if p_clone_from is null then
    raise exception 'start a new version from an existing one (p_clone_from); policies built from scratch come through a reviewed migration until the policy editor ships'
      using errcode = '23514';
  end if;
  return _pay_create_version(org_id(), v_actor, p_policy, p_label, p_effective_from, p_reason, p_clone_from);
end
$$;

-- -------------------------------------------------------------------------------------
-- 8. Self-test — always rolled back; a failed check raises 'SELFTEST FAIL' and aborts everything
-- -------------------------------------------------------------------------------------
do $test$
declare
  v_org   constant uuid := '00000000-0000-0000-0000-000000000001';
  v_owner uuid;
  v_staff uuid;
  v_sl    uuid;
  v_nu    uuid;
  v_sl_v  uuid;
  v_d     uuid;
  v_id    uuid;
begin
  select s.id into v_owner
  from org_members m join staff s on s.user_id = m.user_id and s.org_id = m.org_id
  where m.org_id = v_org and m.role = 'owner'
  order by m.joined_at, s.id limit 1;
  select id into v_staff from staff where org_id = v_org and is_active order by created_at, id limit 1;
  select id into v_sl from pay_policies where org_id = v_org and name = 'Supported Living';
  select id into v_nu from pay_policies where org_id = v_org and name = 'Nursing';
  select id into v_sl_v from pay_policy_versions where policy_id = v_sl and status = 'approved';

  begin
    -- 1. DON is part of the Nursing policy (bonus rules) and can be assigned
    perform _pay_set_assignment(v_org, v_owner, v_staff, 'DON', v_nu, date '2099-02-01', null, 'w2', null, null);

    -- 2. Overrides are refused on jobs not paid by the hour (RN is paid per unit)
    begin
      perform _pay_set_assignment(v_org, v_owner, v_staff, 'RN', v_nu, date '2099-02-01', null, 'w2', 40.00, 'self-test');
      raise exception 'SELFTEST FAIL 2: override on a non-hourly job accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 3. Incomplete tier coverage is refused: drop SLN rank 2, add a code-specific SLN rank 0
    v_d := _pay_create_version(v_org, v_owner, v_sl, 'selftest-a', date '2099-01-01', 'self-test', v_sl_v);
    select i.id into v_id
    from pay_items i
    join pay_tiers t on t.id = i.tier_id
    join pay_jobs j on j.id = i.pay_job_id
    where i.version_id = v_d and j.code = 'SLN' and t.rank = 2 and i.service_code_id is null;
    perform _pay_delete_item(v_org, v_owner, v_id);
    perform _pay_set_item(v_org, v_owner, v_d, 'SLN', 'hour', 18.00, 'SLN', 0);
    begin
      perform _pay_approve_version(v_org, v_owner, v_d);
      raise exception 'SELFTEST FAIL 3: incomplete tier coverage approved';
    exception when sqlstate '23514' then null;
    end;

    -- 4. Two complete rate sets for the same job (general + code-specific) approve
    perform _pay_set_item(v_org, v_owner, v_d, 'SLN', 'hour', 20.00, null,  2);
    perform _pay_set_item(v_org, v_owner, v_d, 'SLN', 'hour', 19.00, 'SLN', 1);
    perform _pay_set_item(v_org, v_owner, v_d, 'SLN', 'hour', 20.00, 'SLN', 2);
    perform _pay_approve_version(v_org, v_owner, v_d);
    if (select status from pay_policy_versions where id = v_d) <> 'approved' then
      raise exception 'SELFTEST FAIL 4: complete code-specific rate sets not approved';
    end if;

    -- 5. Tiers on non-hourly items are refused
    v_d := _pay_create_version(v_org, v_owner, v_sl, 'selftest-b', date '2099-06-01', 'self-test', v_sl_v);
    begin
      perform _pay_set_item(v_org, v_owner, v_d, 'SLN', 'visit', 50.00, null, 0);
      raise exception 'SELFTEST FAIL 5: tier on a non-hourly item accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 6. A draft created without a clone source gets the default settings row
    v_d := _pay_create_version(v_org, v_owner, v_nu, 'selftest-c', date '2099-07-01', 'self-test', null);
    if not exists (select 1 from pay_policy_settings
                   where version_id = v_d and mileage_mode = 'irs' and off_duty_buffer_min = 30) then
      raise exception 'SELFTEST FAIL 6: non-cloned draft has no default settings';
    end if;

    -- 7. Without a signed-in session the client RPC still refuses
    begin
      perform pay_create_version(v_sl, 'x', date '2099-08-01', 'self-test', v_sl_v);
      raise exception 'SELFTEST FAIL 7: RPC ran without a session';
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
-- 9. Verification table (paste this result into the PR and the chat)
-- -------------------------------------------------------------------------------------
with hh as (select '00000000-0000-0000-0000-000000000001'::uuid as org),
checks as (
  select 1 as n, 'Constraint: tiers on hourly items only' as check_name,
         (select count(*) from pg_constraint where conname = 'pay_items_tier_hour_only')::text as got, '1' as want
  union all
  select 2, 'Assignments use the full job-membership check (DON)',
         (position('_pay_policy_has_job' in pg_get_functiondef(
            '_pay_set_assignment(uuid,uuid,uuid,text,uuid,date,date,text,numeric,text)'::regprocedure)) > 0)::text, 'true'
  union all
  select 3, 'Approval checks tiers per pay job and service code',
         (position('group by j.code, i.service_code_id' in pg_get_functiondef('_pay_validate_version(uuid)'::regprocedure)) > 0)::text, 'true'
  union all
  select 4, 'Every new draft gets a settings row',
         (position('insert into pay_policy_settings (version_id, org_id) values (v_id, p_org)' in
            pg_get_functiondef('_pay_create_version(uuid,uuid,uuid,text,date,text,uuid)'::regprocedure)) > 0)::text, 'true'
  union all
  select 5, 'Client RPC requires a clone source',
         (position('p_clone_from is null' in pg_get_functiondef('pay_create_version(uuid,text,date,text,uuid)'::regprocedure)) > 0)::text, 'true'
  union all
  select 6, 'Internal pay functions callable by clients',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public'
            and (left(p.proname, 5) = '_pay_' or left(p.proname, 8) = 'trg_pay_')
            and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or has_function_privilege('anon', p.oid, 'EXECUTE')))::text, '0'
  union all
  select 7, 'Pay RPCs callable by signed-in users (not anon)',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public'
            and p.proname in ('pay_has','pay_create_version','pay_set_item','pay_delete_item','pay_approve_version',
                              'pay_set_assignment','pay_end_assignment','pay_record_deduction_authorization',
                              'pay_revoke_deduction_authorization','pay_grant','pay_revoke')
            and has_function_privilege('authenticated', p.oid, 'EXECUTE')
            and not has_function_privilege('anon', p.oid, 'EXECUTE'))::text, '11'
  union all
  select 8, 'Approved Hope Haven versions (SL + Nursing, unchanged)',
         (select count(*) from pay_policy_versions, hh where org_id = hh.org and status = 'approved')::text, '2'
  union all
  select 9, 'SL hourly rates by tier (unchanged)',
         (select string_agg(x, ' ' order by x desc) from (
            select j.code || ':' || string_agg(to_char(i.amount, 'FM990.00'), ',' order by t.rank) as x
            from pay_items i
            join pay_tiers t on t.id = i.tier_id
            join pay_jobs j on j.id = i.pay_job_id
            join pay_policy_versions v on v.id = i.version_id
            join pay_policies p on p.id = v.policy_id, hh
            where p.org_id = hh.org and p.name = 'Supported Living' and v.status = 'approved'
            group by j.code) s),
         'SLN:18.00,19.00,20.00 SLH:21.00,22.00,23.00'
  union all
  select 10, 'Self-test leftovers', (select count(*) from pay_policy_versions where reason = 'self-test')::text, '0'
  union all
  select 11, 'Pay assignments (none yet)', (select count(*) from staff_pay_assignments)::text, '0'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
