-- ════════════════════════════════════════════════════════════════════
-- v20.0.47 — sign-up capture: alerts, "How did you hear about Provly?",
-- where visitors came from, and the welcome email.
--
-- RUN IN SUPABASE (SQL editor) after Greptile 5/5, BEFORE merging.
-- Safe to run twice: every object is created-if-missing and the settings
-- rows are inserted only if absent (re-running never resets them).
--
-- What it adds
--  1. pg_cron (the minute job) and pg_net (Supabase's built-in web-request
--     extension, so the database can call the signup-notify edge function).
--     r1 (Greptile r1): both are enabled here rather than assumed. Production
--     already has pg_cron 1.6.4 (checked Nov 2026), so for it that line is a
--     no-op; if either extension can't be enabled, the whole migration rolls
--     back with nothing changed, and the app's sign-up still works (it falls
--     back to the existing signup_create_organization when v2 is missing).
--  2. platform_settings — Provly-wide settings, service-role only. Holds the
--     alert address (change it with one UPDATE, no release), the welcome
--     email's reply-to address and on/off switch, and the edge function's
--     URL and shared secret.
--  3. org_signup_source — one row per organization: how they heard about
--     Provly and their first visit / sign-up visit. Service-role only:
--     customers never read it.
--  4. signup_events — the outbox. One row per new organization and per
--     stuck sign-up; the edge function claims rows, sends the emails and
--     reports back. Sends retry with backoff; an email is never sent twice
--     for the same row (claims are leased, and Resend is given a stable
--     idempotency key per row and email).
--  5. signup_create_organization_v2 — what the sign-up page calls now: the
--     existing signup_create_organization (unchanged) plus the source row.
--     A bad or missing source never blocks a sign-up.
--  6. signup_notify_tick, run every minute by pg_cron: queues new
--     organizations and stuck sign-ups (a login at least 15 minutes old
--     with no organization), then calls the edge function only when
--     something is waiting.
--
-- Only organizations and logins created AFTER this runs produce emails
-- (alerts_installed_at), so installing it never emails about the past.
-- ════════════════════════════════════════════════════════════════════

begin;

-- 1 ── pg_cron + pg_net ──────────────────────────────────────────────
-- pg_cron's jobs live in schema "cron" (Supabase installs it in pg_catalog);
-- pg_net's functions live in "net" (Supabase keeps the extension in "extensions").
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- 2 ── platform_settings ─────────────────────────────────────────────
create table if not exists public.platform_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table public.platform_settings enable row level security;
revoke all on table public.platform_settings from anon, authenticated;

insert into public.platform_settings (key, value) values
  ('signup_alert_to',     'tombe@hopehavenservices.org'),
  ('welcome_reply_to',    'tombe@getprovly.com'),
  ('welcome_enabled',     'true'),
  ('notify_url',          'https://zsrnqbmzgypldraifjho.supabase.co/functions/v1/signup-notify'),
  ('notify_secret',       replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')),
  ('alerts_installed_at', now()::text)
on conflict (key) do nothing;

-- 3 ── org_signup_source ─────────────────────────────────────────────
create table if not exists public.org_signup_source (
  org_id       uuid primary key references public.organizations(id) on delete cascade,
  heard_via    text check (heard_via in ('google', 'ai_assistant', 'provider_referral', 'support_coordinator',
                                         'provly_outreach', 'event', 'social', 'other')),
  heard_detail text check (char_length(heard_detail) <= 200),
  first_touch  jsonb,
  signup_touch jsonb,
  created_at   timestamptz not null default now()
);
alter table public.org_signup_source enable row level security;
revoke all on table public.org_signup_source from anon, authenticated;

-- 4 ── signup_events (outbox) ────────────────────────────────────────
create table if not exists public.signup_events (
  id              bigserial primary key,
  kind            text not null check (kind in ('new_org', 'stuck_signup')),
  org_id          uuid references public.organizations(id) on delete cascade,
  user_id         uuid,
  email           text,                    -- stuck sign-ups: the login's email, captured when queued
  user_created_at timestamptz,
  signup_kind     text,                    -- 'provider' | 'invite' | 'unknown'
  invited_by      text,                    -- invite sign-ups: the inviting organization's name
  alert_status    text not null default 'pending'
                  check (alert_status in ('pending', 'sent', 'failed')),
  welcome_status  text not null default 'n/a'
                  check (welcome_status in ('n/a', 'pending', 'sent', 'skipped', 'failed')),
  attempts        integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  claimed_until   timestamptz,
  last_error      text,
  sent_at         timestamptz,
  created_at      timestamptz not null default now(),
  constraint signup_events_target check (
    (kind = 'new_org'      and org_id is not null and user_id is null) or
    (kind = 'stuck_signup' and user_id is not null and org_id is null))
);
create unique index if not exists uq_signup_events_org  on public.signup_events (org_id)  where kind = 'new_org';
create unique index if not exists uq_signup_events_user on public.signup_events (user_id) where kind = 'stuck_signup';
create index if not exists ix_signup_events_due on public.signup_events (next_attempt_at)
  where alert_status = 'pending' or welcome_status = 'pending';
alter table public.signup_events enable row level security;
revoke all on table public.signup_events from anon, authenticated;
revoke all on sequence public.signup_events_id_seq from anon, authenticated;

-- 5 ── sign-up: source capture ───────────────────────────────────────
-- Keeps only the fields Provly records about a visit, each length-capped:
-- the referring site (host + path, never its query string), the Provly page
-- (host + path), campaign tags, and the time. Anything else is dropped.
create or replace function public.signup_clean_touch(p jsonb)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then null
    else nullif(jsonb_strip_nulls(jsonb_build_object(
      'ref',          left(p->>'ref', 300),
      'page',         left(p->>'page', 300),
      'utm_source',   left(p->>'utm_source', 100),
      'utm_medium',   left(p->>'utm_medium', 100),
      'utm_campaign', left(p->>'utm_campaign', 100),
      'utm_term',     left(p->>'utm_term', 100),
      'utm_content',  left(p->>'utm_content', 100),
      'at', case when (p->>'at') ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then p->>'at' end
    )), '{}'::jsonb)
  end
$$;

create or replace function public.signup_create_organization_v2(
  p_legal_name      text,
  p_address         text,
  p_phone           text,
  p_email           text,
  p_contract_number text,
  p_first_name      text,
  p_last_name       text,
  p_user_id         uuid,
  p_heard_via       text  default null,
  p_heard_detail    text  default null,
  p_first_touch     jsonb default null,
  p_signup_touch    jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org_id uuid;
  v_heard  text;
begin
  -- A signed-in caller sets up only its own login.
  if auth.uid() is not null and p_user_id is not null and p_user_id <> auth.uid() then
    raise exception 'Signed-in user does not match the account being set up'
      using errcode = '42501';
  end if;

  -- The organization, owner staff row and login link: unchanged logic.
  v_org_id := public.signup_create_organization(
    p_legal_name, p_address, p_phone, p_email, p_contract_number,
    p_first_name, p_last_name, p_user_id);

  -- How they heard + where they came from. Cleaned, never blocking.
  v_heard := case when p_heard_via in ('google', 'ai_assistant', 'provider_referral', 'support_coordinator',
                                       'provly_outreach', 'event', 'social', 'other')
                  then p_heard_via end;
  begin
    insert into public.org_signup_source (org_id, heard_via, heard_detail, first_touch, signup_touch)
    values (
      v_org_id,
      v_heard,
      case when v_heard in ('google', 'ai_assistant', 'provider_referral', 'provly_outreach', 'other')
           then nullif(left(btrim(p_heard_detail), 200), '') end,
      public.signup_clean_touch(p_first_touch),
      public.signup_clean_touch(p_signup_touch))
    on conflict (org_id) do nothing;
  exception when others then
    raise warning 'v20.0.47: sign-up source not saved for organization %: %', v_org_id, sqlerrm;
  end;

  return v_org_id;
end;
$$;

-- 6 ── outbox: claim / report / authorize ────────────────────────────
-- Claims up to p_limit due rows for 2 minutes and returns everything the
-- emails need, plus the settings the edge function uses. r1: the edge function
-- claims ONE row at a time, immediately before sending it, and bounds every
-- request at 10 s (≤ ~30 s per row), so a row is never still being worked when
-- its 2-minute claim lapses, and only rows actually worked count an attempt.
create or replace function public.signup_outbox_claim(p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_events jsonb;
begin
  with picked as (
    select e.id
    from public.signup_events e
    where (e.alert_status = 'pending' or e.welcome_status = 'pending')
      and e.next_attempt_at <= now()
      and (e.claimed_until is null or e.claimed_until < now())
    order by e.id
    limit greatest(1, least(coalesce(p_limit, 10), 50))
    for update skip locked
  ), claimed as (
    update public.signup_events e
    set claimed_until = now() + interval '2 minutes',
        attempts      = e.attempts + 1
    from picked
    where e.id = picked.id
    returning e.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id',             c.id,
      'kind',           c.kind,
      'alert_status',   c.alert_status,
      'welcome_status', c.welcome_status,
      'attempts',       c.attempts,
      'org', case when c.kind = 'new_org' then (
          select jsonb_build_object(
            'name',            coalesce(nullif(o.legal_name, ''), o.name),
            'address',         o.address,
            'phone',           o.phone,
            'email',           o.email,
            'contract_number', o.contract_number,
            'trial_ends_at',   o.trial_ends_at,
            'created_at',      o.created_at)
          from public.organizations o where o.id = c.org_id) end,
      'owner', case when c.kind = 'new_org' then (
          select jsonb_build_object(
            'first_name', s.first_name,
            'last_name',  s.last_name,
            'email',      coalesce(u.email, s.email))
          from public.staff s
          left join auth.users u on u.id = s.user_id
          where s.org_id = c.org_id and s.role::text = 'owner'
          order by s.hire_date nulls last, s.id
          limit 1) end,
      'source', case when c.kind = 'new_org' then (
          select jsonb_build_object(
            'heard_via',    x.heard_via,
            'heard_detail', x.heard_detail,
            'first_touch',  x.first_touch,
            'signup_touch', x.signup_touch)
          from public.org_signup_source x where x.org_id = c.org_id) end,
      'login', case when c.kind = 'stuck_signup' then jsonb_build_object(
            'email',       c.email,
            'created_at',  c.user_created_at,
            'signup_kind', c.signup_kind,
            'invited_by',  c.invited_by) end
    ) order by c.id), '[]'::jsonb)
  into v_events
  from claimed c;

  return jsonb_build_object(
    'settings', (select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb)
                 from public.platform_settings s
                 where s.key in ('signup_alert_to', 'welcome_reply_to', 'welcome_enabled')),
    'events', v_events);
end;
$$;

-- Records what happened to each email of a claimed row:
--   'sent' | 'skipped' (welcome only) | 'failed' (give up) | 'retry' / null.
-- A retry waits 2, 4, 8 … up to 60 minutes; after 8 attempts it is failed.
create or replace function public.signup_outbox_report(
  p_id      bigint,
  p_alert   text default null,
  p_welcome text default null,
  p_error   text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.signup_events e
  set alert_status = case
        when e.alert_status <> 'pending' or p_alert is null then e.alert_status
        when p_alert = 'sent' then 'sent'
        when p_alert = 'failed' or e.attempts >= 8 then 'failed'
        else 'pending' end,
      welcome_status = case
        when e.welcome_status <> 'pending' or p_welcome is null then e.welcome_status
        when p_welcome in ('sent', 'skipped') then p_welcome
        when p_welcome = 'failed' or e.attempts >= 8 then 'failed'
        else 'pending' end,
      sent_at = case when e.alert_status = 'pending' and p_alert = 'sent' then now() else e.sent_at end,
      last_error = coalesce(left(p_error, 500), e.last_error),
      claimed_until = null,
      next_attempt_at = now() + make_interval(mins => least(60, power(2, least(e.attempts, 6))::int))
  where e.id = p_id;
end;
$$;

create or replace function public.signup_notify_authorized(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(char_length(p_secret) >= 32 and exists (
    select 1 from public.platform_settings s
    where s.key = 'notify_secret' and s.value = p_secret), false)
$$;

-- 7 ── the minute tick ───────────────────────────────────────────────
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

-- 8 ── who may call what ─────────────────────────────────────────────
revoke execute on function public.signup_create_organization_v2(text, text, text, text, text, text, text, uuid, text, text, jsonb, jsonb) from public;
grant  execute on function public.signup_create_organization_v2(text, text, text, text, text, text, text, uuid, text, text, jsonb, jsonb) to anon, authenticated, service_role;

revoke execute on function public.signup_clean_touch(jsonb)                          from public, anon, authenticated;
revoke execute on function public.signup_outbox_claim(integer)                       from public, anon, authenticated;
revoke execute on function public.signup_outbox_report(bigint, text, text, text)     from public, anon, authenticated;
revoke execute on function public.signup_notify_authorized(text)                     from public, anon, authenticated;
revoke execute on function public.signup_notify_tick()                               from public, anon, authenticated;
grant  execute on function public.signup_outbox_claim(integer)                       to service_role;
grant  execute on function public.signup_outbox_report(bigint, text, text, text)     to service_role;
grant  execute on function public.signup_notify_authorized(text)                     to service_role;

-- 9 ── every minute ──────────────────────────────────────────────────
select cron.schedule('provly-signup-notify', '* * * * *', 'select public.signup_notify_tick()');

commit;
