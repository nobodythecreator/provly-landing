-- =====================================================================================
-- sql/v20.0.31_pay_r1a_policy_schema.sql
-- Provly pay engine — R1a: policy schema + Hope Haven seed
-- r1 (Oct 12, 2026): first run rolled back on audit_log.action varchar(20) ('pay_assignment_create' = 21 chars).
--   Nothing was applied. Audit action names shortened to ≤ 20; preflight now checks audit_log column limits.
-- Design: docs/pay-engine-design.md v1.0 (§4.1 law, §4.2 policy, §4.4 staff, §4.8 permissions, §5 invariants)
-- Policies seeded: docs/pay-policy-sl-v1.1.md, docs/pay-policy-nursing-v1.1.md
--
-- RUN IN SUPABASE (SQL editor), ONCE. The whole file is one transaction:
--   preflight → schema → triggers → functions → RLS + grants → seed → rolled-back self-test → COMMIT
--   → verification table (the last statement; its result is what the editor shows).
-- Any failure aborts everything; nothing is half-applied.
--
-- Not in this file (later PRs, per the delivery plan):
--   company pay settings (R1b, where first used) · payroll IDs (R1d, needs export setups) · pay runs (R1d)
--   · weekly calculation (R1c) · assignment screens (app).
-- Note: approved policy versions cannot be deleted (freeze trigger), so deleting an organization that has
--   approved pay versions needs a deliberate migration.
-- =====================================================================================

begin;

-- -------------------------------------------------------------------------------------
-- 0. Preflight
-- -------------------------------------------------------------------------------------
do $pre$
declare
  v_org     constant uuid := '00000000-0000-0000-0000-000000000001';  -- Hope Haven
  v_missing text;
  v_len     integer;
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'R1a preflight: needs Postgres 15+ (UNIQUE NULLS NOT DISTINCT); found %',
      current_setting('server_version');
  end if;
  if to_regclass('public.pay_policies') is not null then
    raise exception 'R1a preflight: pay_policies already exists — this migration has already run';
  end if;
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then
    raise exception 'R1a preflight: btree_gist extension missing (needed for the assignment overlap constraint)';
  end if;
  if not exists (
    select 1 from pg_index i
    where i.indrelid = 'public.staff'::regclass and i.indisunique and i.indpred is null
      and (select array_agg(a.attname::text order by a.attname)
           from unnest(i.indkey::int2[]) as k(attnum)
           join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum) = array['id','org_id']
  ) then
    raise exception 'R1a preflight: staff needs a unique index on (id, org_id) for tenant-closed foreign keys';
  end if;
  if not exists (select 1 from organizations where id = v_org) then
    raise exception 'R1a preflight: Hope Haven org % not found', v_org;
  end if;
  select string_agg(c, ', ') into v_missing
  from unnest(array['SLN','SLH','PM2','PN2','PN1','DSG']) as c
  where not exists (select 1 from service_code_definitions s where s.code = c);
  if v_missing is not null then
    raise exception 'R1a preflight: service codes missing: %', v_missing;
  end if;
  if not exists (
    select 1 from org_members m
    join staff s on s.user_id = m.user_id and s.org_id = m.org_id
    where m.org_id = v_org and m.role = 'owner'
  ) then
    raise exception 'R1a preflight: no owner staff row for Hope Haven (approvals need a staff id)';
  end if;
  -- audit_log column limits must fit what this file writes: longest action = 19 chars
  -- ('pay_version_approve'), longest table name = 30 chars ('staff_deduction_authorizations').
  select c.character_maximum_length into v_len from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'audit_log' and c.column_name = 'action';
  if v_len is not null and v_len < 19 then
    raise exception 'R1a preflight: audit_log.action is varchar(%) — needs at least 19', v_len;
  end if;
  select c.character_maximum_length into v_len from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'audit_log' and c.column_name = 'table_name';
  if v_len is not null and v_len < 30 then
    raise exception 'R1a preflight: audit_log.table_name is varchar(%) — needs at least 30', v_len;
  end if;
  if to_regprocedure('public.org_id()') is null
     or to_regprocedure('public.member_role()') is null
     or to_regprocedure('public.my_staff_id()') is null
     or to_regprocedure('public.access_tier()') is null then
    raise exception 'R1a preflight: expected helpers org_id(), member_role(), my_staff_id(), access_tier()';
  end if;
end
$pre$;

-- -------------------------------------------------------------------------------------
-- 1. Law layer (global — not tenant data; read-only to clients; changed only by migrations)
-- -------------------------------------------------------------------------------------
create table law_min_wage (
  jurisdiction   text not null check (jurisdiction ~ '^[A-Z]{2}$'),   -- 'US' = federal; otherwise a state
  effective_from date not null,
  hourly         numeric(6,2) not null check (hourly > 0),
  source         text not null,
  primary key (jurisdiction, effective_from)
);

create table law_irs_mileage (
  effective_from date primary key,
  rate           numeric(6,4) not null check (rate > 0 and rate < 5),
  source         text not null
);

create table law_state_rules (
  state                          text not null check (state ~ '^[A-Z]{2}$'),
  effective_from                 date not null,
  max_pay_interval               text not null check (max_pay_interval in ('weekly','biweekly','semimonthly','monthly')),
  max_payday_lag_days            integer not null check (max_payday_lag_days between 0 and 31),
  mileage_reimbursement_required boolean not null,
  deduction_needs_written_auth   boolean not null,
  source                         text not null,
  primary key (state, effective_from)
);

create table law_federal_rules (
  effective_from            date primary key,
  ot_weekly_threshold_hours numeric(5,2) not null check (ot_weekly_threshold_hours > 0),
  exempt_salary_weekly_min  numeric(10,2) not null check (exempt_salary_weekly_min > 0),
  source                    text not null
);

create table earning_types (
  code            text primary key check (code ~ '^[a-z_]+$'),
  label           text not null,
  tax_class       text not null check (tax_class in ('wages','nontaxable_reimbursement','contractor')),
  in_regular_rate boolean not null,
  check (tax_class = 'wages' or not in_regular_rate)
);

-- -------------------------------------------------------------------------------------
-- 2. Policy layer (Decision 5: typed tables grouped by shape; versions frozen once approved)
-- -------------------------------------------------------------------------------------
create table pay_policies (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references organizations(id) on delete cascade,
  name       text not null check (length(btrim(name)) between 1 and 80),
  division   text not null check (length(btrim(division)) between 1 and 80),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, name)
);

create table pay_jobs (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  code            text not null check (code ~ '^[A-Z0-9_]{2,24}$'),
  name            text not null check (length(btrim(name)) between 1 and 80),
  service_code_id uuid references service_code_definitions(id),
  created_at      timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, code)
);

create table pay_policy_versions (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null,
  policy_id      uuid not null,
  label          text not null check (length(btrim(label)) between 1 and 40),
  effective_from date not null,
  status         text not null default 'draft' check (status in ('draft','approved')),
  reason         text not null check (length(btrim(reason)) > 0),
  created_by     uuid,
  created_at     timestamptz not null default now(),
  approved_by    uuid,
  approved_at    timestamptz,
  unique (id, org_id),
  unique (policy_id, effective_from),
  foreign key (policy_id, org_id)   references pay_policies(id, org_id) on delete cascade,
  foreign key (created_by, org_id)  references staff(id, org_id),
  foreign key (approved_by, org_id) references staff(id, org_id),
  check ((status = 'approved') = (approved_by is not null and approved_at is not null))
);

create table pay_tiers (
  id                            uuid primary key default gen_random_uuid(),
  org_id                        uuid not null,
  version_id                    uuid not null,
  rank                          smallint not null check (rank between 0 and 20),
  name                          text not null check (length(btrim(name)) between 1 and 40),
  min_counted_persons           smallint check (min_counted_persons >= 0),
  max_counted_persons           smallint check (max_counted_persons >= 0),
  min_avg_weekly_billable_hours numeric(5,2) check (min_avg_weekly_billable_hours >= 0),
  check (max_counted_persons is null or min_counted_persons is null or max_counted_persons >= min_counted_persons),
  unique (id, version_id),
  unique (version_id, rank),
  foreign key (version_id, org_id) references pay_policy_versions(id, org_id) on delete cascade
);

-- Every "amount per something" primitive in one table. The earning type is derived at calculation
-- time from basis + the assignment's worker type (e.g., a 'day' add-on is wages for a W-2 DSP and a
-- contractor payment for a host), so it is not stored here.
create table pay_items (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null,
  version_id      uuid not null,
  pay_job_id      uuid not null,
  basis           text not null check (basis in ('hour','billable_quarter_hour','visit','session',
                                                 'person_month','day','supervised_visit','nonbillable_hour')),
  service_code_id uuid references service_code_definitions(id),   -- null = any code of the pay job
  tier_id         uuid,
  amount          numeric(10,2) not null check (amount > 0),
  foreign key (version_id, org_id) references pay_policy_versions(id, org_id) on delete cascade,
  foreign key (pay_job_id, org_id) references pay_jobs(id, org_id),
  foreign key (tier_id, version_id) references pay_tiers(id, version_id) on delete cascade,
  constraint pay_items_natural_key unique nulls not distinct (version_id, pay_job_id, basis, service_code_id, tier_id)
);

create table pay_qualifiers (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null,
  version_id uuid not null,
  metric     text not null check (metric in ('billable_share','delivery_pct_each_counted_person','notes_on_time')),
  min_value  numeric(5,4) not null check (min_value > 0 and min_value <= 1),
  unique (version_id, metric),
  foreign key (version_id, org_id) references pay_policy_versions(id, org_id) on delete cascade
);

create table pay_policy_settings (
  version_id               uuid primary key,
  org_id                   uuid not null,
  mileage_mode             text not null default 'irs' check (mileage_mode in ('irs','fixed','none')),
  mileage_fixed_rate       numeric(6,4) check (mileage_fixed_rate > 0),
  off_duty_buffer_min      smallint not null default 30 check (off_duty_buffer_min between 0 and 240),
  documentation_expect_min smallint check (documentation_expect_min between 1 and 240),
  nonservice_pay_job_id    uuid,      -- pay job for training/meetings (SL: SLN)
  tier_review_cycle        text check (tier_review_cycle in ('monthly')),
  tier_count_share_min     numeric(4,3) check (tier_count_share_min > 0 and tier_count_share_min <= 1),
  tier_max_counted_persons smallint check (tier_max_counted_persons > 0),
  tier_grace_months        smallint check (tier_grace_months between 0 and 12),
  foreign key (version_id, org_id) references pay_policy_versions(id, org_id) on delete cascade,
  foreign key (nonservice_pay_job_id, org_id) references pay_jobs(id, org_id),
  check ((mileage_mode = 'fixed') = (mileage_fixed_rate is not null)),
  -- Decision 2: R1 accepts the IRS rate only. A later migration drops this constraint when the
  -- fixed/none paths (assumed-cost minimum-wage check + state rule) are built.
  constraint pay_policy_settings_r1_irs_only check (mileage_mode = 'irs')
);

create table pay_salary_rules (
  version_id                 uuid primary key,
  org_id                     uuid not null,
  pay_job_id                 uuid not null,
  conversion_min_avg_monthly numeric(10,2) not null check (conversion_min_avg_monthly > 0),
  conversion_months          smallint not null check (conversion_months between 1 and 12),
  conversion_min_persons     smallint not null check (conversion_min_persons >= 0),
  conversion_person_codes    text[] not null check (cardinality(conversion_person_codes) > 0),
  true_up_period             text not null check (true_up_period in ('quarter')),
  salary_change              text not null check (salary_change in ('annual_review')),
  foreign key (version_id, org_id) references pay_policy_versions(id, org_id) on delete cascade,
  foreign key (pay_job_id, org_id) references pay_jobs(id, org_id)
);

create table pay_bonus_rules (
  version_id                  uuid primary key,
  org_id                      uuid not null,
  pay_job_id                  uuid not null,
  kind                        text not null check (kind in ('division_margin')),
  pct                         numeric(5,4) not null check (pct > 0 and pct <= 1),
  period                      text not null check (period in ('quarter')),
  trigger_headcount           smallint check (trigger_headcount > 0),
  promotion_salary_multiplier numeric(4,3) check (promotion_salary_multiplier > 0),
  foreign key (version_id, org_id) references pay_policy_versions(id, org_id) on delete cascade,
  foreign key (pay_job_id, org_id) references pay_jobs(id, org_id)
);

-- -------------------------------------------------------------------------------------
-- 3. Staff layer (Decision 6)
-- -------------------------------------------------------------------------------------
create table staff_pay_assignments (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  staff_id        uuid not null,
  policy_id       uuid not null,
  pay_job_id      uuid not null,
  worker_type     text not null check (worker_type in ('w2','contractor_1099')),  -- staff.employment_type vocabulary
  start_date      date not null,
  end_date        date,
  override_amount numeric(10,2) check (override_amount > 0),
  override_reason text,
  approved_by     uuid not null,
  created_at      timestamptz not null default now(),
  foreign key (staff_id, org_id)    references staff(id, org_id),
  foreign key (policy_id, org_id)   references pay_policies(id, org_id),
  foreign key (pay_job_id, org_id)  references pay_jobs(id, org_id),
  foreign key (approved_by, org_id) references staff(id, org_id),
  check (end_date is null or end_date >= start_date),
  check ((override_amount is null) = (override_reason is null)),
  check (override_reason is null or length(btrim(override_reason)) > 0),
  constraint staff_pay_assignments_no_overlap
    exclude using gist (staff_id with =, pay_job_id with =, daterange(start_date, end_date, '[]') with &&)
);

-- Default assignment for a new hire, keyed to the service codes they can provide
-- (user_role is a permission role, not a pay job).
create table pay_code_defaults (
  org_id          uuid not null references organizations(id) on delete cascade,
  service_code_id uuid not null references service_code_definitions(id),
  policy_id       uuid not null,
  pay_job_id      uuid not null,
  primary key (org_id, service_code_id),
  foreign key (policy_id, org_id)  references pay_policies(id, org_id),
  foreign key (pay_job_id, org_id) references pay_jobs(id, org_id)
);

create table staff_deduction_authorizations (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  staff_id    uuid not null,
  signed_on   date not null,
  evidence    text not null check (length(btrim(evidence)) > 0),   -- where the signed copy is filed
  recorded_by uuid not null,
  recorded_at timestamptz not null default now(),
  revoked_on  date,
  revoked_by  uuid,
  foreign key (staff_id, org_id)    references staff(id, org_id),
  foreign key (recorded_by, org_id) references staff(id, org_id),
  foreign key (revoked_by, org_id)  references staff(id, org_id),
  check (revoked_on is null or revoked_on >= signed_on),
  check ((revoked_on is null) = (revoked_by is null))
);
create unique index staff_deduction_authorizations_one_active
  on staff_deduction_authorizations (staff_id) where revoked_on is null;

-- -------------------------------------------------------------------------------------
-- 4. Permissions (Decision 13). The owner always holds every pay permission (in code, so an owner
--    can never be locked out); this table grants permissions to other roles.
-- -------------------------------------------------------------------------------------
create table pay_role_permissions (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references organizations(id) on delete cascade,
  role       user_role not null check (role <> 'owner'),
  permission text not null check (permission in ('pay.view_all','pay.review_run','pay.approve_run',
                                                 'pay.manage_rates','pay.manage_policies','pay.manage_export')),
  granted_by uuid,
  granted_at timestamptz not null default now(),
  unique (org_id, role, permission),
  foreign key (granted_by, org_id) references staff(id, org_id)
);

create table pay_access_log (
  id               bigint generated always as identity primary key,
  org_id           uuid not null references organizations(id) on delete cascade,
  viewer_user_id   uuid,
  viewer_staff_id  uuid,
  subject_staff_id uuid not null,
  rpc              text not null,
  viewed_at        timestamptz not null default now(),
  foreign key (subject_staff_id, org_id) references staff(id, org_id),
  foreign key (viewer_staff_id, org_id)  references staff(id, org_id)
);

-- -------------------------------------------------------------------------------------
-- 5. Freeze triggers (invariant 1: an approved version never changes)
-- -------------------------------------------------------------------------------------
create function trg_pay_version_freeze() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.approved_by is not null or new.approved_at is not null then
      raise exception 'a pay policy version must be created as a draft' using errcode = '55000';
    end if;
    return new;
  end if;
  if old.status = 'approved' then
    raise exception 'pay policy version % is approved and cannot be changed or deleted; create a new version', old.id
      using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  if new.id <> old.id or new.org_id <> old.org_id or new.policy_id <> old.policy_id then
    raise exception 'pay policy version identity cannot change' using errcode = '55000';
  end if;
  return new;
end
$$;

create trigger pay_policy_versions_freeze
  before insert or update or delete on pay_policy_versions
  for each row execute function trg_pay_version_freeze();

-- Children of an approved version are frozen too. FOR SHARE on the parent row serializes a child
-- write against a concurrent approval (approval takes FOR UPDATE on the same row).
create function trg_pay_version_child_freeze() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare
  v_status text;
begin
  if tg_op in ('UPDATE','DELETE') then
    select v.status into v_status from pay_policy_versions v where v.id = old.version_id for share;
    if v_status = 'approved' then
      raise exception '% belongs to an approved pay policy version and cannot change', tg_table_name
        using errcode = '55000';
    end if;
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select v.status into v_status from pay_policy_versions v where v.id = new.version_id for share;
    if v_status = 'approved' then
      raise exception '% cannot be added to an approved pay policy version', tg_table_name
        using errcode = '55000';
    end if;
    return new;
  end if;
  return old;
end
$$;

create trigger pay_tiers_freeze           before insert or update or delete on pay_tiers           for each row execute function trg_pay_version_child_freeze();
create trigger pay_items_freeze           before insert or update or delete on pay_items           for each row execute function trg_pay_version_child_freeze();
create trigger pay_qualifiers_freeze      before insert or update or delete on pay_qualifiers      for each row execute function trg_pay_version_child_freeze();
create trigger pay_policy_settings_freeze before insert or update or delete on pay_policy_settings for each row execute function trg_pay_version_child_freeze();
create trigger pay_salary_rules_freeze    before insert or update or delete on pay_salary_rules    for each row execute function trg_pay_version_child_freeze();
create trigger pay_bonus_rules_freeze     before insert or update or delete on pay_bonus_rules     for each row execute function trg_pay_version_child_freeze();

-- -------------------------------------------------------------------------------------
-- 6. Internal functions (explicit org + actor; never callable by clients — revoked in §8)
-- -------------------------------------------------------------------------------------
create function _pay_audit(p_org uuid, p_action text, p_table text, p_record uuid,
                           p_old jsonb, p_new jsonb, p_actor uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into audit_log (id, org_id, user_id, action, table_name, record_id, old_data, new_data, created_at)
  values (gen_random_uuid(), p_org, auth.uid(), p_action, p_table, p_record, p_old,
          case when p_new is null then null else p_new || jsonb_build_object('_actor_staff_id', p_actor) end,
          now());
$$;

-- Highest minimum wage that applies to the org on a date: federal, plus any state where it has an active site.
create function _pay_min_wage(p_org uuid, p_on date)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(max(w.hourly), 0)
  from law_min_wage w
  where w.effective_from = (select max(w2.effective_from) from law_min_wage w2
                            where w2.jurisdiction = w.jurisdiction and w2.effective_from <= p_on)
    and (w.jurisdiction = 'US'
         or w.jurisdiction in (select upper(btrim(s.state)) from org_sites s
                               where s.org_id = p_org and s.is_active and s.state is not null));
$$;

create function _pay_validate_version(p_version uuid)
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
    for r in
      select j.code,
             count(i.tier_id)                           as tiered,
             count(*) filter (where i.tier_id is null)  as untiered
      from pay_items i join pay_jobs j on j.id = i.pay_job_id
      where i.version_id = p_version and i.basis = 'hour'
      group by j.code
    loop
      if r.tiered > 0 and (r.untiered > 0 or r.tiered <> v_tiers) then
        v_p := array_append(v_p, format('pay job %s needs exactly one hourly rate per tier', r.code));
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

create function _pay_create_version(p_org uuid, p_actor uuid, p_policy uuid, p_label text,
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

  perform _pay_audit(p_org, 'pay_version_create', 'pay_policy_versions', v_id, null,
                     (select to_jsonb(v) || jsonb_build_object('cloned_from', p_clone_from)
                      from pay_policy_versions v where v.id = v_id), p_actor);
  return v_id;
end
$$;

create function _pay_set_item(p_org uuid, p_actor uuid, p_version uuid, p_pay_job text, p_basis text,
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

create function _pay_delete_item(p_org uuid, p_actor uuid, p_item uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_version uuid;
  v_old     jsonb;
  v_status  text;
begin
  select i.version_id, to_jsonb(i) into v_version, v_old from pay_items i where i.id = p_item and i.org_id = p_org;
  if v_version is null then
    raise exception 'pay item not found' using errcode = 'P0002';
  end if;
  select status into v_status from pay_policy_versions where id = v_version for update;
  if v_status <> 'draft' then
    raise exception 'only a draft version can be edited' using errcode = '55000';
  end if;
  delete from pay_items where id = p_item;
  perform _pay_audit(p_org, 'pay_item_delete', 'pay_items', p_item, v_old, null, p_actor);
end
$$;

create function _pay_approve_version(p_org uuid, p_actor uuid, p_version uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_policy   uuid;
  v_status   text;
  v_problems text[];
begin
  if p_actor is null then
    raise exception 'approval needs a staff record' using errcode = '23514';
  end if;
  select policy_id into v_policy from pay_policy_versions where id = p_version and org_id = p_org;
  if v_policy is null then
    raise exception 'pay policy version not found' using errcode = 'P0002';
  end if;
  -- lock order: policy, then version (serializes approvals of the same policy)
  perform 1 from pay_policies where id = v_policy for update;
  select status into v_status from pay_policy_versions where id = p_version for update;
  if v_status <> 'draft' then
    raise exception 'pay policy version is already approved' using errcode = '55000';
  end if;
  v_problems := _pay_validate_version(p_version);
  if cardinality(v_problems) > 0 then
    raise exception 'cannot approve: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;
  update pay_policy_versions
     set status = 'approved', approved_by = p_actor, approved_at = now()
   where id = p_version;
  perform _pay_audit(p_org, 'pay_version_approve', 'pay_policy_versions', p_version,
                     jsonb_build_object('status', 'draft'), jsonb_build_object('status', 'approved'), p_actor);
end
$$;

create function _pay_set_assignment(p_org uuid, p_actor uuid, p_staff uuid, p_pay_job text, p_policy uuid,
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
  if not exists (select 1 from pay_items i join pay_policy_versions v on v.id = i.version_id
                 where v.policy_id = p_policy and i.pay_job_id = v_job)
     and not exists (select 1 from pay_policy_settings s join pay_policy_versions v on v.id = s.version_id
                     where v.policy_id = p_policy and s.nonservice_pay_job_id = v_job) then
    raise exception 'pay job % is not part of this policy', p_pay_job using errcode = '23514';
  end if;
  if p_override_amount is not null then
    if v_reason is null then
      raise exception 'an override needs a reason' using errcode = '23514';
    end if;
    if exists (select 1 from pay_items i join pay_policy_versions v on v.id = i.version_id
               where v.policy_id = p_policy and i.pay_job_id = v_job and i.basis <> 'hour') then
      raise exception 'overrides apply to hourly pay jobs only' using errcode = '23514';
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

create function _pay_end_assignment(p_org uuid, p_actor uuid, p_assignment uuid, p_end date)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb;
begin
  select to_jsonb(a) into v_old from staff_pay_assignments a
  where a.id = p_assignment and a.org_id = p_org for update;
  if v_old is null then
    raise exception 'pay assignment not found' using errcode = 'P0002';
  end if;
  if p_end is null or p_end < (v_old->>'start_date')::date then
    raise exception 'end date must be on or after the start date' using errcode = '23514';
  end if;
  update staff_pay_assignments set end_date = p_end where id = p_assignment;
  perform _pay_audit(p_org, 'pay_assign_end', 'staff_pay_assignments', p_assignment, v_old,
                     (select to_jsonb(a) from staff_pay_assignments a where a.id = p_assignment), p_actor);
end
$$;

create function _pay_record_deduction_auth(p_org uuid, p_actor uuid, p_staff uuid, p_signed_on date, p_evidence text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid;
begin
  if p_actor is null then
    raise exception 'a recorder is required' using errcode = '23514';
  end if;
  if not exists (select 1 from staff where id = p_staff and org_id = p_org) then
    raise exception 'staff member not found' using errcode = 'P0002';
  end if;
  insert into staff_deduction_authorizations (org_id, staff_id, signed_on, evidence, recorded_by)
  values (p_org, p_staff, p_signed_on, btrim(p_evidence), p_actor)
  returning id into v_id;
  perform _pay_audit(p_org, 'pay_deduct_auth_add', 'staff_deduction_authorizations', v_id, null,
                     (select to_jsonb(d) from staff_deduction_authorizations d where d.id = v_id), p_actor);
  return v_id;
end
$$;

create function _pay_revoke_deduction_auth(p_org uuid, p_actor uuid, p_authorization uuid, p_revoked_on date)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb;
begin
  if p_actor is null then
    raise exception 'a recorder is required' using errcode = '23514';
  end if;
  select to_jsonb(d) into v_old from staff_deduction_authorizations d
  where d.id = p_authorization and d.org_id = p_org and d.revoked_on is null for update;
  if v_old is null then
    raise exception 'active deduction authorization not found' using errcode = 'P0002';
  end if;
  update staff_deduction_authorizations set revoked_on = p_revoked_on, revoked_by = p_actor
   where id = p_authorization;
  perform _pay_audit(p_org, 'pay_deduct_auth_end', 'staff_deduction_authorizations', p_authorization, v_old,
                     (select to_jsonb(d) from staff_deduction_authorizations d where d.id = p_authorization), p_actor);
end
$$;

create function _pay_grant(p_org uuid, p_actor uuid, p_role user_role, p_permission text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid;
begin
  insert into pay_role_permissions (org_id, role, permission, granted_by)
  values (p_org, p_role, p_permission, p_actor)
  on conflict (org_id, role, permission) do nothing
  returning id into v_id;
  if v_id is not null then
    perform _pay_audit(p_org, 'pay_perm_grant', 'pay_role_permissions', v_id, null,
                       jsonb_build_object('role', p_role, 'permission', p_permission), p_actor);
  end if;
end
$$;

create function _pay_revoke(p_org uuid, p_actor uuid, p_role user_role, p_permission text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid;
begin
  delete from pay_role_permissions
   where org_id = p_org and role = p_role and permission = p_permission
  returning id into v_id;
  if v_id is not null then
    perform _pay_audit(p_org, 'pay_perm_revoke', 'pay_role_permissions', v_id,
                       jsonb_build_object('role', p_role, 'permission', p_permission), null, p_actor);
  end if;
end
$$;

-- -------------------------------------------------------------------------------------
-- 7. Client-facing RPCs (derive org + actor from the session; permission-gated)
-- -------------------------------------------------------------------------------------
create function pay_has(p_permission text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when (select org_id()) is null or (select member_role()) is null then false
    when (select member_role()) = 'owner' then true
    else exists (select 1 from pay_role_permissions r
                 where r.org_id = (select org_id())
                   and r.role = (select member_role())
                   and r.permission = p_permission)
  end;
$$;

create function pay_create_version(p_policy uuid, p_label text, p_effective_from date, p_reason text,
                                   p_clone_from uuid default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_policies') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  return _pay_create_version(org_id(), v_actor, p_policy, p_label, p_effective_from, p_reason, p_clone_from);
end
$$;

create function pay_set_item(p_version uuid, p_pay_job text, p_basis text, p_amount numeric,
                             p_service_code text default null, p_tier_rank integer default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_policies') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  return _pay_set_item(org_id(), v_actor, p_version, p_pay_job, p_basis, p_amount, p_service_code, p_tier_rank);
end
$$;

create function pay_delete_item(p_item uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_policies') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  perform _pay_delete_item(org_id(), v_actor, p_item);
end
$$;

create function pay_approve_version(p_version uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_policies') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  perform _pay_approve_version(org_id(), v_actor, p_version);
end
$$;

create function pay_set_assignment(p_staff uuid, p_pay_job text, p_policy uuid, p_start date,
                                   p_end date default null, p_worker_type text default null,
                                   p_override_amount numeric default null, p_override_reason text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_rates') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  return _pay_set_assignment(org_id(), v_actor, p_staff, p_pay_job, p_policy, p_start, p_end,
                             p_worker_type, p_override_amount, p_override_reason);
end
$$;

create function pay_end_assignment(p_assignment uuid, p_end date)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_rates') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  perform _pay_end_assignment(org_id(), v_actor, p_assignment, p_end);
end
$$;

create function pay_record_deduction_authorization(p_staff uuid, p_signed_on date, p_evidence text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_rates') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  return _pay_record_deduction_auth(org_id(), v_actor, p_staff, p_signed_on, p_evidence);
end
$$;

create function pay_revoke_deduction_authorization(p_authorization uuid, p_revoked_on date)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor uuid := my_staff_id();
begin
  if not pay_has('pay.manage_rates') then raise exception 'not permitted' using errcode = '42501'; end if;
  if v_actor is null then raise exception 'no staff record for this user' using errcode = '42501'; end if;
  perform _pay_revoke_deduction_auth(org_id(), v_actor, p_authorization, p_revoked_on);
end
$$;

create function pay_grant(p_role user_role, p_permission text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select member_role()) is distinct from 'owner' then raise exception 'not permitted' using errcode = '42501'; end if;
  perform _pay_grant(org_id(), my_staff_id(), p_role, p_permission);
end
$$;

create function pay_revoke(p_role user_role, p_permission text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select member_role()) is distinct from 'owner' then raise exception 'not permitted' using errcode = '42501'; end if;
  perform _pay_revoke(org_id(), my_staff_id(), p_role, p_permission);
end
$$;

-- -------------------------------------------------------------------------------------
-- 8. RLS + grants (clients read through RLS; every write goes through the RPCs above)
-- -------------------------------------------------------------------------------------
do $rls$
declare
  t text;
  v_global text[] := array['law_min_wage','law_irs_mileage','law_state_rules','law_federal_rules','earning_types'];
  v_tenant text[] := array['pay_policies','pay_jobs','pay_policy_versions','pay_tiers','pay_items','pay_qualifiers',
                           'pay_policy_settings','pay_salary_rules','pay_bonus_rules','staff_pay_assignments',
                           'pay_code_defaults','staff_deduction_authorizations','pay_role_permissions','pay_access_log'];
  v_view_all text[] := array['pay_policies','pay_jobs','pay_policy_versions','pay_tiers','pay_items','pay_qualifiers',
                             'pay_policy_settings','pay_salary_rules','pay_bonus_rules','pay_code_defaults'];
  f record;
begin
  foreach t in array v_global || v_tenant loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from anon, public', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on table %I from authenticated', t);
    execute format('grant select on table %I to authenticated', t);
  end loop;

  foreach t in array v_global loop
    execute format('create policy %I on %I for select to authenticated using (true)', t || '_read_all', t);
  end loop;

  foreach t in array v_tenant loop
    execute format(
      'create policy %I on %I as restrictive for all to authenticated '
      'using (org_id = (select org_id()) and (select member_role()) is not null) '
      'with check (org_id = (select org_id()) and (select member_role()) is not null)',
      t || '_tenant_guard', t);
  end loop;

  foreach t in array v_view_all loop
    execute format('create policy %I on %I for select to authenticated using ((select pay_has(''pay.view_all'')))',
                   t || '_read', t);
  end loop;

  create policy staff_pay_assignments_read on staff_pay_assignments for select to authenticated
    using ((select pay_has('pay.view_all')) or staff_id = (select my_staff_id()));
  create policy staff_deduction_authorizations_read on staff_deduction_authorizations for select to authenticated
    using ((select pay_has('pay.view_all')) or staff_id = (select my_staff_id()));
  create policy pay_role_permissions_read on pay_role_permissions for select to authenticated
    using ((select access_tier()) = 'manage');
  create policy pay_access_log_read on pay_access_log for select to authenticated
    using ((select member_role()) = 'owner');

  -- Functions: internal and trigger functions are never callable by clients; RPCs are callable by
  -- signed-in users only (each checks its own permission).
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (left(p.proname, 5) = '_pay_' or left(p.proname, 8) = 'trg_pay_'
           or p.proname in ('pay_has','pay_create_version','pay_set_item','pay_delete_item','pay_approve_version',
                            'pay_set_assignment','pay_end_assignment','pay_record_deduction_authorization',
                            'pay_revoke_deduction_authorization','pay_grant','pay_revoke'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if left(f.proname, 1) <> '_' and left(f.proname, 8) <> 'trg_pay_' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end
$rls$;

-- -------------------------------------------------------------------------------------
-- 9. Seed — law rows (global) and Hope Haven as tenant #1
-- -------------------------------------------------------------------------------------
insert into law_min_wage (jurisdiction, effective_from, hourly, source) values
  ('US', date '2009-07-24', 7.25, 'FLSA 29 USC 206(a)(1)'),
  ('UT', date '2009-07-24', 7.25, 'Utah Minimum Wage Act (tracks the federal rate)');

insert into law_irs_mileage (effective_from, rate, source) values
  (date '2026-01-01', 0.7250, 'IRS IR-2025-128'),
  (date '2026-07-01', 0.7600, 'IRS mid-year increase effective 2026-07-01');

insert into law_state_rules (state, effective_from, max_pay_interval, max_payday_lag_days,
                             mileage_reimbursement_required, deduction_needs_written_auth, source) values
  ('UT', date '2026-01-01', 'semimonthly', 10, false, true,
   'Utah Code 34-28-3 (interval; written authorization for deductions (6)(b)); payday lag of 10 days to be verified');

insert into law_federal_rules (effective_from, ot_weekly_threshold_hours, exempt_salary_weekly_min, source) values
  (date '2020-01-01', 40, 684.00, 'FLSA 29 USC 207; 29 CFR 541.600');

insert into earning_types (code, label, tax_class, in_regular_rate) values
  ('hourly_pay',            'Hourly pay',                  'wages',                    true),
  ('unit_pay',              'Per-unit pay',                'wages',                    true),
  ('nonbillable_pay',       'Non-billable work',           'wages',                    true),
  ('addon_pay',             'Daily add-on',                'wages',                    true),
  ('min_wage_makeup',       'Minimum-wage make-up',        'wages',                    true),
  ('overtime_premium',      'Overtime premium',            'wages',                    false),
  ('prior_week_adjustment', 'Prior-week adjustment',       'wages',                    false),
  ('mileage_reimbursement', 'Mileage reimbursement',       'nontaxable_reimbursement', false),
  ('contractor_payment',    'Contractor payment',          'contractor',               false);

do $seed$
declare
  v_org     constant uuid := '00000000-0000-0000-0000-000000000001';
  v_eff     constant date := date '2026-10-12';
  v_owner   uuid;
  v_sl      uuid;
  v_nu      uuid;
  v_hr      uuid;
  v_sl_v    uuid;
  v_nu_v    uuid;
  v_hr_v    uuid;
  v_job_sln uuid;
  v_job_rn  uuid;
  v_job_don uuid;
  v_job_dsg uuid;
begin
  select s.id into v_owner
  from org_members m join staff s on s.user_id = m.user_id and s.org_id = m.org_id
  where m.org_id = v_org and m.role = 'owner'
  order by m.joined_at, s.id
  limit 1;

  insert into pay_jobs (org_id, code, name, service_code_id)
  select v_org, j.code, j.name, sc.id
  from (values ('SLN',           'SLN',                 'SLN'),
               ('SLH',           'SLH',                 'SLH'),
               ('RN',            'Staff RN',            null),
               ('LPN',           'LPN',                 null),
               ('LEAD_RN',       'Lead RN',             null),
               ('DON',           'Director of Nursing', null),
               ('PN1_CAREGIVER', 'PN1 caregiver',       'PN1'),
               ('DSG',           'DSG',                 'DSG')) as j(code, name, svc)
  left join service_code_definitions sc on sc.code = j.svc;

  select id into v_job_sln from pay_jobs where org_id = v_org and code = 'SLN';
  select id into v_job_rn  from pay_jobs where org_id = v_org and code = 'RN';
  select id into v_job_don from pay_jobs where org_id = v_org and code = 'DON';
  select id into v_job_dsg from pay_jobs where org_id = v_org and code = 'DSG';

  insert into pay_policies (org_id, name, division) values (v_org, 'Supported Living', 'Supported Living') returning id into v_sl;
  insert into pay_policies (org_id, name, division) values (v_org, 'Nursing',          'Nursing')          returning id into v_nu;
  insert into pay_policies (org_id, name, division) values (v_org, 'Hourly by code',   'General')          returning id into v_hr;

  -- Supported Living v1.1 ------------------------------------------------------------
  v_sl_v := _pay_create_version(v_org, v_owner, v_sl, 'v1.1', v_eff, 'Seed: docs/pay-policy-sl-v1.1.md', null);

  insert into pay_tiers (org_id, version_id, rank, name, min_counted_persons, max_counted_persons, min_avg_weekly_billable_hours)
  values (v_org, v_sl_v, 0, 'Base',   null, null, null),
         (v_org, v_sl_v, 1, 'Tier 1', 3,    4,    25.00),
         (v_org, v_sl_v, 2, 'Tier 2', 5,    6,    32.00);

  perform _pay_set_item(v_org, v_owner, v_sl_v, 'SLN', 'hour', 18.00, null, 0);
  perform _pay_set_item(v_org, v_owner, v_sl_v, 'SLN', 'hour', 19.00, null, 1);
  perform _pay_set_item(v_org, v_owner, v_sl_v, 'SLN', 'hour', 20.00, null, 2);
  perform _pay_set_item(v_org, v_owner, v_sl_v, 'SLH', 'hour', 21.00, null, 0);
  perform _pay_set_item(v_org, v_owner, v_sl_v, 'SLH', 'hour', 22.00, null, 1);
  perform _pay_set_item(v_org, v_owner, v_sl_v, 'SLH', 'hour', 23.00, null, 2);

  insert into pay_qualifiers (org_id, version_id, metric, min_value)
  values (v_org, v_sl_v, 'billable_share',                   0.80),
         (v_org, v_sl_v, 'delivery_pct_each_counted_person', 0.90),
         (v_org, v_sl_v, 'notes_on_time',                    0.95);

  insert into pay_policy_settings (version_id, org_id, mileage_mode, mileage_fixed_rate, off_duty_buffer_min,
                                   documentation_expect_min, nonservice_pay_job_id, tier_review_cycle,
                                   tier_count_share_min, tier_max_counted_persons, tier_grace_months)
  values (v_sl_v, v_org, 'irs', null, 30, 15, v_job_sln, 'monthly', 0.25, 6, 1);

  perform _pay_approve_version(v_org, v_owner, v_sl_v);

  -- Nursing v1.1 ---------------------------------------------------------------------
  v_nu_v := _pay_create_version(v_org, v_owner, v_nu, 'v1.1', v_eff, 'Seed: docs/pay-policy-nursing-v1.1.md', null);

  perform _pay_set_item(v_org, v_owner, v_nu_v, 'RN',            'billable_quarter_hour', 10.50,  'PM2', null);
  perform _pay_set_item(v_org, v_owner, v_nu_v, 'RN',            'visit',                 65.00,  'PN2', null);
  perform _pay_set_item(v_org, v_owner, v_nu_v, 'RN',            'session',               18.00,  'PN2', null);
  perform _pay_set_item(v_org, v_owner, v_nu_v, 'RN',            'person_month',          150.00, 'PN1', null);
  perform _pay_set_item(v_org, v_owner, v_nu_v, 'RN',            'nonbillable_hour',      30.00,  null,  null);
  perform _pay_set_item(v_org, v_owner, v_nu_v, 'LPN',           'visit',                 45.00,  'PN2', null);
  perform _pay_set_item(v_org, v_owner, v_nu_v, 'LEAD_RN',       'supervised_visit',      10.00,  'PN2', null);
  perform _pay_set_item(v_org, v_owner, v_nu_v, 'PN1_CAREGIVER', 'day',                   10.00,  'PN1', null);

  insert into pay_policy_settings (version_id, org_id, mileage_mode, mileage_fixed_rate, off_duty_buffer_min,
                                   documentation_expect_min, nonservice_pay_job_id, tier_review_cycle,
                                   tier_count_share_min, tier_max_counted_persons, tier_grace_months)
  values (v_nu_v, v_org, 'irs', null, 30, null, null, null, null, null, null);

  insert into pay_salary_rules (version_id, org_id, pay_job_id, conversion_min_avg_monthly, conversion_months,
                                conversion_min_persons, conversion_person_codes, true_up_period, salary_change)
  values (v_nu_v, v_org, v_job_rn, 3300.00, 3, 3, array['PN2','PN1'], 'quarter', 'annual_review');

  insert into pay_bonus_rules (version_id, org_id, pay_job_id, kind, pct, period,
                               trigger_headcount, promotion_salary_multiplier)
  values (v_nu_v, v_org, v_job_don, 'division_margin', 0.0500, 'quarter', 3, 1.100);

  perform _pay_approve_version(v_org, v_owner, v_nu_v);

  -- Hourly by code v1.0 — stays a DRAFT until Hope Haven's DSG rate is set ----------
  v_hr_v := _pay_create_version(v_org, v_owner, v_hr, 'v1.0', v_eff,
                                'Seed: plain hourly rate for codes without a pay policy (DSG); rate to be set', null);

  insert into pay_policy_settings (version_id, org_id, mileage_mode, mileage_fixed_rate, off_duty_buffer_min,
                                   documentation_expect_min, nonservice_pay_job_id, tier_review_cycle,
                                   tier_count_share_min, tier_max_counted_persons, tier_grace_months)
  values (v_hr_v, v_org, 'irs', null, 30, 15, v_job_dsg, null, null, null, null);

  -- Defaults and permissions ---------------------------------------------------------
  insert into pay_code_defaults (org_id, service_code_id, policy_id, pay_job_id)
  select v_org, sc.id, d.policy_id, j.id
  from (values ('SLN', v_sl, 'SLN'),
               ('SLH', v_sl, 'SLH'),
               ('PM2', v_nu, 'RN'),
               ('DSG', v_hr, 'DSG')) as d(code, policy_id, job)
  join service_code_definitions sc on sc.code = d.code
  join pay_jobs j on j.org_id = v_org and j.code = d.job;

  insert into pay_role_permissions (org_id, role, permission, granted_by)
  values (v_org, 'compliance_director', 'pay.view_all',   v_owner),
         (v_org, 'compliance_director', 'pay.review_run', v_owner);
end
$seed$;

-- -------------------------------------------------------------------------------------
-- 10. Self-test — runs inside a subtransaction that is always rolled back.
--     A failed check raises 'SELFTEST FAIL', aborting the whole migration.
-- -------------------------------------------------------------------------------------
do $test$
declare
  v_org    constant uuid := '00000000-0000-0000-0000-000000000001';
  v_owner  uuid;
  v_staff  uuid;
  v_sl     uuid;
  v_sl_v   uuid;
  v_draft  uuid;
  v_id     uuid;
begin
  select s.id into v_owner
  from org_members m join staff s on s.user_id = m.user_id and s.org_id = m.org_id
  where m.org_id = v_org and m.role = 'owner'
  order by m.joined_at, s.id limit 1;
  select id into v_staff from staff where org_id = v_org and is_active order by created_at, id limit 1;
  select id into v_sl from pay_policies where org_id = v_org and name = 'Supported Living';
  select id into v_sl_v from pay_policy_versions where policy_id = v_sl and status = 'approved';

  begin
    -- 1. An approved version cannot be updated
    begin
      update pay_policy_versions set label = 'tamper' where id = v_sl_v;
      raise exception 'SELFTEST FAIL 1: approved version was updated';
    exception when sqlstate '55000' then null;
    end;

    -- 2. Items of an approved version cannot be updated
    begin
      update pay_items set amount = amount + 1 where version_id = v_sl_v;
      raise exception 'SELFTEST FAIL 2: approved version item was updated';
    exception when sqlstate '55000' then null;
    end;

    -- 3. A version cannot be inserted already approved
    begin
      insert into pay_policy_versions (org_id, policy_id, label, effective_from, status, reason, approved_by, approved_at)
      values (v_org, v_sl, 'direct', date '2099-12-31', 'approved', 'self-test', v_owner, now());
      raise exception 'SELFTEST FAIL 3: version inserted as approved';
    exception when sqlstate '55000' then null;
    end;

    -- 4. Clone copies everything
    v_draft := _pay_create_version(v_org, v_owner, v_sl, 'selftest', date '2099-01-01', 'self-test', v_sl_v);
    if (select count(*) from pay_items      where version_id = v_draft) <> 6
    or (select count(*) from pay_tiers      where version_id = v_draft) <> 3
    or (select count(*) from pay_qualifiers where version_id = v_draft) <> 3
    or not exists (select 1 from pay_policy_settings where version_id = v_draft) then
      raise exception 'SELFTEST FAIL 4: clone incomplete';
    end if;

    -- 5. Editing a draft item works (upsert by natural key, no duplicate)
    perform _pay_set_item(v_org, v_owner, v_draft, 'SLN', 'hour', 18.50, null, 0);
    if (select count(*) from pay_items where version_id = v_draft) <> 6
    or (select i.amount from pay_items i
        join pay_tiers t on t.id = i.tier_id
        join pay_jobs  j on j.id = i.pay_job_id
        where i.version_id = v_draft and j.code = 'SLN' and t.rank = 0) <> 18.50 then
      raise exception 'SELFTEST FAIL 5: draft item edit';
    end if;

    -- 6. A rate below the minimum wage blocks approval
    perform _pay_set_item(v_org, v_owner, v_draft, 'SLH', 'hour', 7.00, null, 1);
    begin
      perform _pay_approve_version(v_org, v_owner, v_draft);
      raise exception 'SELFTEST FAIL 6: sub-minimum rate approved';
    exception when sqlstate '23514' then null;
    end;

    -- 7. Fixed, the draft approves
    perform _pay_set_item(v_org, v_owner, v_draft, 'SLH', 'hour', 22.00, null, 1);
    perform _pay_approve_version(v_org, v_owner, v_draft);
    if (select status from pay_policy_versions where id = v_draft) <> 'approved' then
      raise exception 'SELFTEST FAIL 7: valid draft not approved';
    end if;

    -- 8. A version effective before the current approved one cannot be approved
    v_id := _pay_create_version(v_org, v_owner, v_sl, 'selftest-early', date '2098-01-01', 'self-test', v_sl_v);
    begin
      perform _pay_approve_version(v_org, v_owner, v_id);
      raise exception 'SELFTEST FAIL 8: back-dated version approved';
    exception when sqlstate '23514' then null;
    end;

    -- 9. Overlapping assignments for the same pay job are refused
    perform _pay_set_assignment(v_org, v_owner, v_staff, 'SLN', v_sl, date '2099-02-01', null, 'w2', null, null);
    begin
      perform _pay_set_assignment(v_org, v_owner, v_staff, 'SLN', v_sl, date '2099-03-01', null, 'w2', null, null);
      raise exception 'SELFTEST FAIL 9: overlapping assignment accepted';
    exception when exclusion_violation then null;
    end;

    -- 10. An override needs a reason
    begin
      perform _pay_set_assignment(v_org, v_owner, v_staff, 'SLH', v_sl, date '2099-02-01', null, 'w2', 25.00, null);
      raise exception 'SELFTEST FAIL 10: override without reason accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 11. An override below the minimum wage is refused
    begin
      perform _pay_set_assignment(v_org, v_owner, v_staff, 'SLH', v_sl, date '2099-02-01', null, 'w2', 7.00, 'self-test');
      raise exception 'SELFTEST FAIL 11: sub-minimum override accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 12. A pay job outside the policy is refused
    begin
      perform _pay_set_assignment(v_org, v_owner, v_staff, 'RN', v_sl, date '2099-02-01', null, 'w2', null, null);
      raise exception 'SELFTEST FAIL 12: pay job outside the policy accepted';
    exception when sqlstate '23514' then null;
    end;

    -- 13. Only one active deduction authorization per staff member
    perform _pay_record_deduction_auth(v_org, v_owner, v_staff, date '2099-01-01', 'self-test');
    begin
      perform _pay_record_deduction_auth(v_org, v_owner, v_staff, date '2099-01-02', 'self-test');
      raise exception 'SELFTEST FAIL 13: second active authorization accepted';
    exception when unique_violation then null;
    end;

    -- 14. The owner role cannot be stored in the permission table
    begin
      insert into pay_role_permissions (org_id, role, permission) values (v_org, 'owner', 'pay.view_all');
      raise exception 'SELFTEST FAIL 14: owner row stored';
    exception when check_violation then null;
    end;

    -- 15. A function call for another org is refused (tenant gate)
    begin
      perform _pay_set_item(gen_random_uuid(), v_owner, v_draft, 'SLN', 'hour', 19.00, null, 0);
      raise exception 'SELFTEST FAIL 15: cross-tenant edit accepted';
    exception when sqlstate 'P0002' then null;
    end;

    -- 16. Without a signed-in session: no permissions, RPCs refuse
    if pay_has('pay.view_all') then
      raise exception 'SELFTEST FAIL 16: pay_has true without a session';
    end if;
    begin
      perform pay_create_version(v_sl, 'x', date '2099-06-01', 'self-test', null);
      raise exception 'SELFTEST FAIL 16b: RPC ran without a session';
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
-- 11. Verification table (paste this result into the chat)
-- -------------------------------------------------------------------------------------
with hh as (select '00000000-0000-0000-0000-000000000001'::uuid as org),
pay_tables as (
  select unnest(array['law_min_wage','law_irs_mileage','law_state_rules','law_federal_rules','earning_types',
                      'pay_policies','pay_jobs','pay_policy_versions','pay_tiers','pay_items','pay_qualifiers',
                      'pay_policy_settings','pay_salary_rules','pay_bonus_rules','staff_pay_assignments',
                      'pay_code_defaults','staff_deduction_authorizations','pay_role_permissions','pay_access_log']) as t
),
checks as (
  select 1 as n, 'Law: IRS mileage rows (72.5¢ from Jan 1, 76¢ from Jul 1, 2026)' as check_name,
         (select count(*) from law_irs_mileage)::text as got, '2' as want
  union all
  select 2, 'Law: Utah payday lag in days (verify against Utah Code 34-28-3)',
         (select max_payday_lag_days::text from law_state_rules where state = 'UT'), '10'
  union all
  select 3, 'Earning types', (select count(*) from earning_types)::text, '9'
  union all
  select 4, 'Hope Haven pay jobs', (select count(*) from pay_jobs, hh where org_id = hh.org)::text, '8'
  union all
  select 5, 'Hope Haven pay policies', (select count(*) from pay_policies, hh where org_id = hh.org)::text, '3'
  union all
  select 6, 'Supported Living v1.1 status',
         (select v.status from pay_policy_versions v join pay_policies p on p.id = v.policy_id, hh
          where p.org_id = hh.org and p.name = 'Supported Living' and v.label = 'v1.1'), 'approved'
  union all
  select 7, 'SL hourly rates by tier (Base, Tier 1, Tier 2)',
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
  select 8, 'SL tiers / qualifiers',
         (select (select count(*) from pay_tiers t where t.version_id = v.id)::text || '/' ||
                 (select count(*) from pay_qualifiers q where q.version_id = v.id)::text
          from pay_policy_versions v join pay_policies p on p.id = v.policy_id, hh
          where p.org_id = hh.org and p.name = 'Supported Living' and v.status = 'approved'), '3/3'
  union all
  select 9, 'Nursing v1.1 status',
         (select v.status from pay_policy_versions v join pay_policies p on p.id = v.policy_id, hh
          where p.org_id = hh.org and p.name = 'Nursing' and v.label = 'v1.1'), 'approved'
  union all
  select 10, 'Nursing pay items',
         (select count(*) from pay_items i join pay_policy_versions v on v.id = i.version_id
          join pay_policies p on p.id = v.policy_id, hh
          where p.org_id = hh.org and p.name = 'Nursing' and v.status = 'approved')::text, '8'
  union all
  select 11, 'RN non-billable hourly rate',
         (select to_char(i.amount, 'FM990.00') from pay_items i join pay_jobs j on j.id = i.pay_job_id
          join pay_policy_versions v on v.id = i.version_id join pay_policies p on p.id = v.policy_id, hh
          where p.org_id = hh.org and p.name = 'Nursing' and v.status = 'approved'
            and j.code = 'RN' and i.basis = 'nonbillable_hour'), '30.00'
  union all
  select 12, 'Hourly by code v1.0 status (draft until the DSG rate is set)',
         (select v.status from pay_policy_versions v join pay_policies p on p.id = v.policy_id, hh
          where p.org_id = hh.org and p.name = 'Hourly by code'), 'draft'
  union all
  select 13, 'Default assignments by service code', (select count(*) from pay_code_defaults, hh where org_id = hh.org)::text, '4'
  union all
  select 14, 'Compliance Director pay permissions',
         (select count(*) from pay_role_permissions, hh where org_id = hh.org and role = 'compliance_director')::text, '2'
  union all
  select 15, 'Pay assignments (none yet — entered later)', (select count(*) from staff_pay_assignments)::text, '0'
  union all
  select 16, 'Self-test leftovers',
         (select count(*) from pay_policy_versions where reason = 'self-test')::text, '0'
  union all
  select 17, 'RLS enabled on pay tables',
         (select count(*) from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
          where ns.nspname = 'public' and c.relname in (select t from pay_tables) and c.relrowsecurity)::text, '19'
  union all
  select 18, 'Policies on pay tables',
         (select count(*) from pg_policies where schemaname = 'public' and tablename in (select t from pay_tables))::text, '33'
  union all
  select 19, 'Internal pay functions callable by clients',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public'
            and (left(p.proname, 5) = '_pay_' or left(p.proname, 8) = 'trg_pay_')
            and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or has_function_privilege('anon', p.oid, 'EXECUTE')))::text, '0'
  union all
  select 20, 'Pay RPCs callable by signed-in users (not anon)',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public'
            and p.proname in ('pay_has','pay_create_version','pay_set_item','pay_delete_item','pay_approve_version',
                              'pay_set_assignment','pay_end_assignment','pay_record_deduction_authorization',
                              'pay_revoke_deduction_authorization','pay_grant','pay_revoke')
            and has_function_privilege('authenticated', p.oid, 'EXECUTE')
            and not has_function_privilege('anon', p.oid, 'EXECUTE'))::text, '11'
  union all
  select 21, 'Anon can read pay items', (has_table_privilege('anon', 'public.pay_items', 'SELECT'))::text, 'false'
)
select n, check_name, got, want, case when got = want then '✅' else '❌' end as ok
from checks
order by n;
