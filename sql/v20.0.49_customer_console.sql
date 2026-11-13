-- ════════════════════════════════════════════════════════════════════
-- v20.0.49 — the Provly customer console (Provly team only).
--
-- RUN IN SUPABASE (SQL editor) after Greptile 5/5, BEFORE merging. Safe to run twice.
-- Then, after the merge, the one-line owner seed at the bottom of the release notes (separate step).
--
-- What it adds
--  0. A guard: stops with a clear message if any column the console counts from is missing.
--  1. platform_staff — Provly's own team (not customers). Roles: owner, support, implementation, sales.
--     Every console action needs an active team member signed in WITH TWO-FACTOR (aal2), checked here
--     in the database, not only in the browser.
--  2. platform_customer_meta — per customer: stage, next follow-up date, account owner.
--  3. platform_customer_notes — the team's private notes on a customer.
--  4. platform_audit_log — every console action: who, what, which customer, when.
--  5. Functions the console calls (all SECURITY DEFINER, search_path pinned, team + two-factor checked):
--     platform_whoami, platform_console_data (COUNTS and contact details only — never client records),
--     platform_customer_update, platform_customer_add_note, platform_customer_history, platform_extend_trial.
--  6. signup_notify_tick: a Provly team login (no organization by design) is never a "stuck sign-up".
--
-- None of these tables is readable by customers: RLS on, no policies, anon/authenticated revoked.
-- ════════════════════════════════════════════════════════════════════

begin;

-- 0 ── the columns the console counts from must exist ─────────────────
do $$
declare
  v_missing text;
begin
  select string_agg(format('%s.%s', t, c), ', ') into v_missing
  from (values
    ('organizations','name'), ('organizations','legal_name'), ('organizations','phone'), ('organizations','email'),
    ('organizations','created_at'), ('organizations','trial_ends_at'), ('organizations','subscription_status'),
    ('organizations','subscription_tier'),
    ('staff','id'), ('staff','org_id'), ('staff','user_id'), ('staff','first_name'), ('staff','last_name'),
    ('staff','email'), ('staff','role'), ('staff','is_active'), ('staff','hire_date'),
    ('persons','org_id'), ('persons','is_active'),
    ('service_notes','org_id'), ('service_notes','service_date'),
    ('evv_sessions','org_id'), ('evv_sessions','clock_in_at')
  ) need(t, c)
  where not exists (select 1 from information_schema.columns ic
                    where ic.table_schema = 'public' and ic.table_name = need.t and ic.column_name = need.c);
  if v_missing is not null then
    raise exception 'v20.0.49: these columns are missing, nothing was changed: %', v_missing;
  end if;
end $$;

-- 1 ── the Provly team ─────────────────────────────────────────────────
create table if not exists public.platform_staff (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  display_name text,
  role         text not null check (role in ('owner', 'support', 'implementation', 'sales')),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

-- 2 ── per-customer sales fields ───────────────────────────────────────
create table if not exists public.platform_customer_meta (
  org_id         uuid primary key references public.organizations(id) on delete cascade,
  stage          text not null default 'trial'
                 check (stage in ('trial', 'talked', 'demo_booked', 'paying', 'lost')),
  next_follow_up date,
  account_owner  uuid references public.platform_staff(user_id) on delete set null,
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

-- 3 ── private notes ───────────────────────────────────────────────────
create table if not exists public.platform_customer_notes (
  id         bigserial primary key,
  org_id     uuid not null references public.organizations(id) on delete cascade,
  author     uuid references public.platform_staff(user_id) on delete set null,
  body       text not null check (char_length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists ix_platform_customer_notes_org on public.platform_customer_notes (org_id, created_at desc);

-- 4 ── audit log ───────────────────────────────────────────────────────
create table if not exists public.platform_audit_log (
  id     bigserial primary key,
  actor  uuid,
  action text not null,
  org_id uuid,
  detail jsonb,
  at     timestamptz not null default now()
);
create index if not exists ix_platform_audit_log_org on public.platform_audit_log (org_id, at desc);

alter table public.platform_staff          enable row level security;
alter table public.platform_customer_meta  enable row level security;
alter table public.platform_customer_notes enable row level security;
alter table public.platform_audit_log      enable row level security;
revoke all on table public.platform_staff, public.platform_customer_meta,
                    public.platform_customer_notes, public.platform_audit_log from anon, authenticated;
revoke all on sequence public.platform_customer_notes_id_seq, public.platform_audit_log_id_seq from anon, authenticated;

-- 5 ── functions ───────────────────────────────────────────────────────
-- The caller must be an active Provly team member, signed in with two-factor; optionally in one of p_roles.
create or replace function public.platform_require(p_roles text[] default null)
returns public.platform_staff
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v public.platform_staff;
begin
  if auth.uid() is null then
    raise exception 'Sign in first' using errcode = '28000';
  end if;
  if coalesce(auth.jwt()->>'aal', '') <> 'aal2' then
    raise exception 'Two-factor sign-in is required for the Provly console' using errcode = '42501';
  end if;
  select * into v from public.platform_staff s where s.user_id = auth.uid() and s.active;
  if not found then
    raise exception 'This login is not on the Provly team' using errcode = '42501';
  end if;
  if p_roles is not null and not (v.role = any (p_roles)) then
    raise exception 'Your Provly role can''t do that' using errcode = '42501';
  end if;
  return v;
end;
$$;

-- Who am I? Safe for any signed-in user: reveals nothing about anyone else.
create or replace function public.platform_whoami()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v public.platform_staff;
begin
  if auth.uid() is null then return jsonb_build_object('signed_in', false); end if;
  select * into v from public.platform_staff s where s.user_id = auth.uid() and s.active;
  return jsonb_build_object(
    'signed_in',    true,
    'aal',          coalesce(auth.jwt()->>'aal', ''),
    'staff',        v.user_id is not null,
    'role',         v.role,
    'display_name', v.display_name,
    'email',        v.email);
end;
$$;

-- Everything the console shows. Counts and business contact details only — never client records.
create or replace function public.platform_console_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.platform_staff;
begin
  v_me := public.platform_require(null);
  return jsonb_build_object(
    'me', jsonb_build_object('user_id', v_me.user_id, 'email', v_me.email, 'role', v_me.role,
                             'display_name', coalesce(v_me.display_name, v_me.email)),
    'team', (select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id,
                                         'name', coalesce(s.display_name, s.email), 'role', s.role)
                                       order by s.created_at), '[]'::jsonb)
             from public.platform_staff s where s.active),
    'customers', (select coalesce(jsonb_agg(c.item order by c.created_at desc), '[]'::jsonb) from (
      select o.created_at, jsonb_build_object(
        'id',            o.id,
        'name',          coalesce(nullif(o.legal_name, ''), o.name),
        'created_at',    o.created_at,
        'status',        o.subscription_status::text,
        'tier',          o.subscription_tier::text,
        'trial_ends_at', o.trial_ends_at,
        'phone',         o.phone,
        'email',         o.email,
        'owner', (select jsonb_build_object(
                    'name',  btrim(coalesce(s.first_name, '') || ' ' || coalesce(s.last_name, '')),
                    'email', coalesce(u.email, s.email))
                  from public.staff s left join auth.users u on u.id = s.user_id
                  where s.org_id = o.id and s.role::text = 'owner'
                  order by s.hire_date nulls last, s.id
                  limit 1),
        'source', (select jsonb_build_object('heard_via', x.heard_via, 'heard_detail', x.heard_detail,
                                             'first_touch', x.first_touch, 'signup_touch', x.signup_touch)
                   from public.org_signup_source x where x.org_id = o.id),
        'last_sign_in', (select max(u.last_sign_in_at)
                         from public.staff s join auth.users u on u.id = s.user_id
                         where s.org_id = o.id),
        'counts', jsonb_build_object(
          'staff',       (select count(*) from public.staff s         where s.org_id = o.id and s.is_active),
          'clients',     (select count(*) from public.persons p       where p.org_id = o.id and p.is_active),
          'notes_30d',   (select count(*) from public.service_notes n where n.org_id = o.id
                            and n.service_date >= current_date - 30),
          'notes_total', (select count(*) from public.service_notes n where n.org_id = o.id),
          'evv_30d',     (select count(*) from public.evv_sessions e  where e.org_id = o.id
                            and e.clock_in_at >= now() - interval '30 days')),
        'meta', (select jsonb_build_object('stage', m.stage, 'next_follow_up', m.next_follow_up,
                                           'account_owner', m.account_owner)
                 from public.platform_customer_meta m where m.org_id = o.id),
        'notes_count', (select count(*) from public.platform_customer_notes pn where pn.org_id = o.id)
      ) as item
      from public.organizations o) c));
end;
$$;

create or replace function public.platform_customer_update(
  p_org_id uuid, p_stage text, p_next_follow_up date, p_account_owner uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.platform_staff;
begin
  v_me := public.platform_require(null);
  if not exists (select 1 from public.organizations o where o.id = p_org_id) then
    raise exception 'No such customer' using errcode = '22023';
  end if;
  if p_stage is null or p_stage not in ('trial', 'talked', 'demo_booked', 'paying', 'lost') then
    raise exception 'Unknown stage' using errcode = '22023';
  end if;
  if p_account_owner is not null
     and not exists (select 1 from public.platform_staff s where s.user_id = p_account_owner and s.active) then
    raise exception 'The account owner must be on the Provly team' using errcode = '22023';
  end if;
  insert into public.platform_customer_meta (org_id, stage, next_follow_up, account_owner, updated_at, updated_by)
  values (p_org_id, p_stage, p_next_follow_up, p_account_owner, now(), v_me.user_id)
  on conflict (org_id) do update
    set stage = excluded.stage, next_follow_up = excluded.next_follow_up,
        account_owner = excluded.account_owner, updated_at = now(), updated_by = v_me.user_id;
  insert into public.platform_audit_log (actor, action, org_id, detail)
  values (v_me.user_id, 'customer_updated', p_org_id,
          jsonb_build_object('stage', p_stage, 'next_follow_up', p_next_follow_up, 'account_owner', p_account_owner));
end;
$$;

create or replace function public.platform_customer_add_note(p_org_id uuid, p_body text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.platform_staff;
begin
  v_me := public.platform_require(null);
  if not exists (select 1 from public.organizations o where o.id = p_org_id) then
    raise exception 'No such customer' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) not between 1 and 4000 then
    raise exception 'A note needs 1 to 4,000 characters' using errcode = '22023';
  end if;
  insert into public.platform_customer_notes (org_id, author, body) values (p_org_id, v_me.user_id, btrim(p_body));
  insert into public.platform_audit_log (actor, action, org_id) values (v_me.user_id, 'note_added', p_org_id);
end;
$$;

-- A customer's notes and console activity, newest first.
create or replace function public.platform_customer_history(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.platform_require(null);
  return jsonb_build_object(
    'notes', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', n.id, 'body', n.body, 'created_at', n.created_at,
                  'author', coalesce(s.display_name, s.email, 'Former team member')) order by n.created_at desc), '[]'::jsonb)
              from public.platform_customer_notes n left join public.platform_staff s on s.user_id = n.author
              where n.org_id = p_org_id),
    'activity', (select coalesce(jsonb_agg(jsonb_build_object(
                     'action', a.action, 'detail', a.detail, 'at', a.at,
                     'actor', coalesce(s.display_name, s.email, 'Former team member')) order by a.at desc), '[]'::jsonb)
                 from (select * from public.platform_audit_log where org_id = p_org_id order by at desc limit 50) a
                 left join public.platform_staff s on s.user_id = a.actor));
end;
$$;

-- Extend a trial by 7, 14 or 30 days, with a reason. Owner role only; never for a paying account.
create or replace function public.platform_extend_trial(p_org_id uuid, p_days integer, p_reason text)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.platform_staff;
  v_status text;
  v_old    timestamptz;
  v_new    timestamptz;
begin
  v_me := public.platform_require(array['owner']);
  -- r1 (Greptile r1): NULL NOT IN (...) is NULL, which would skip this check and clear the end date
  if p_days is null or p_days not in (7, 14, 30) then
    raise exception 'A trial can be extended by 7, 14 or 30 days' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'Say why (3 to 500 characters)' using errcode = '22023';
  end if;
  select o.subscription_status::text, o.trial_ends_at into v_status, v_old
  from public.organizations o where o.id = p_org_id for update;
  if not found then raise exception 'No such customer' using errcode = '22023'; end if;
  if v_status not in ('trial', 'expired') then
    raise exception 'Only a trial (or an expired trial) can be extended; this account is %', v_status using errcode = '22023';
  end if;
  v_new := greatest(coalesce(v_old, now()), now()) + make_interval(days => p_days);
  update public.organizations
  set trial_ends_at = v_new,
      subscription_status = case when v_status = 'expired' then 'trial' else subscription_status end
  where id = p_org_id;
  insert into public.platform_audit_log (actor, action, org_id, detail)
  values (v_me.user_id, 'trial_extended', p_org_id,
          jsonb_build_object('days', p_days, 'reason', btrim(p_reason), 'from', v_old, 'to', v_new, 'status_was', v_status));
  return v_new;
end;
$$;

-- 6 ── a Provly team login is never a "stuck sign-up" ────────────────────
create or replace function public.signup_notify_tick()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_since  timestamptz;
  v_url    text;
  v_secret text;
begin
  select s.value::timestamptz into v_since
  from public.platform_settings s where s.key = 'alerts_installed_at';
  if v_since is null then return; end if;

  -- New organizations (any path that creates one).
  insert into public.signup_events (kind, org_id, welcome_status)
  select 'new_org', o.id, 'pending'
  from public.organizations o
  where o.created_at >= v_since
    and not exists (select 1 from public.signup_events e where e.kind = 'new_org' and e.org_id = o.id)
  on conflict do nothing;

  -- Stuck sign-ups: a login at least 15 minutes old with no organization.
  insert into public.signup_events (kind, user_id, email, user_created_at, signup_kind, invited_by)
  select 'stuck_signup', u.id, u.email, u.created_at,
         case when u.raw_user_meta_data->>'provly_signup' in ('provider', 'invite')
              then u.raw_user_meta_data->>'provly_signup' else 'unknown' end,
         left(u.raw_user_meta_data->>'provly_invited_by', 200)
  from auth.users u
  where u.created_at >= v_since
    and u.created_at <= now() - interval '15 minutes'
    and not exists (select 1 from public.staff s       where s.user_id = u.id)
    and not exists (select 1 from public.org_members m where m.user_id = u.id)
    and not exists (select 1 from public.platform_staff p where p.user_id = u.id)   -- v20.0.49: Provly team logins belong to no organization
    and not exists (select 1 from public.signup_events e where e.kind = 'stuck_signup' and e.user_id = u.id)
  on conflict do nothing;

  -- Call the sender only when something is due.
  if exists (
    select 1 from public.signup_events e
    where (e.alert_status = 'pending' or e.welcome_status = 'pending')
      and e.next_attempt_at <= now()
      and (e.claimed_until is null or e.claimed_until < now())
  ) then
    select s.value into v_url    from public.platform_settings s where s.key = 'notify_url';
    select s.value into v_secret from public.platform_settings s where s.key = 'notify_secret';
    if v_url is not null and v_secret is not null then
      perform net.http_post(
        url     := v_url,
        body    := '{}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-provly-notify', v_secret),
        timeout_milliseconds := 10000);
    end if;
  end if;
end;
$$;

-- 7 ── who may call what ─────────────────────────────────────────────────
revoke execute on function public.platform_require(text[]) from public, anon, authenticated;
revoke execute on function public.platform_whoami()                          from public;
revoke execute on function public.platform_console_data()                    from public;
revoke execute on function public.platform_customer_update(uuid, text, date, uuid) from public;
revoke execute on function public.platform_customer_add_note(uuid, text)     from public;
revoke execute on function public.platform_customer_history(uuid)            from public;
revoke execute on function public.platform_extend_trial(uuid, integer, text) from public;
revoke execute on function public.platform_whoami()                          from anon;
revoke execute on function public.platform_console_data()                    from anon;
revoke execute on function public.platform_customer_update(uuid, text, date, uuid) from anon;
revoke execute on function public.platform_customer_add_note(uuid, text)     from anon;
revoke execute on function public.platform_customer_history(uuid)            from anon;
revoke execute on function public.platform_extend_trial(uuid, integer, text) from anon;
-- signed-in users may call these; each one checks for an active Provly team member with two-factor
grant execute on function public.platform_whoami()                          to authenticated;
grant execute on function public.platform_console_data()                    to authenticated;
grant execute on function public.platform_customer_update(uuid, text, date, uuid) to authenticated;
grant execute on function public.platform_customer_add_note(uuid, text)     to authenticated;
grant execute on function public.platform_customer_history(uuid)            to authenticated;
grant execute on function public.platform_extend_trial(uuid, integer, text) to authenticated;

commit;
