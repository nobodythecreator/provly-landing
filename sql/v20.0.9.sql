-- v20.0.9 — billing: checkout serialization + single open Checkout session per org
-- Additive and idempotent. Applied to production on Aug 26, 2026 via the SQL editor;
-- this file is the committed definition so the schema and
-- supabase/functions/create-checkout-session agree.

alter table public.organizations
  add column if not exists checkout_lock_at timestamptz,
  add column if not exists stripe_checkout_session_id text;

comment on column public.organizations.checkout_lock_at is
  'create-checkout-session: compare-and-set lock (30s stale expiry) that serializes checkout creation per org';
comment on column public.organizations.stripe_checkout_session_id is
  'create-checkout-session: the org''s single open Stripe Checkout session — reused while open for the same price, expired when the price differs';

-- ── v20.0.9r7 (Greptile) — owner membership: verify, never infer ────────────
-- create-checkout-session is fail-closed on an org_members owner row. A tenant
-- claim (JWT app_metadata.org_id) proves membership, not billing authority, so
-- this migration grants NOTHING automatically. It verifies instead: if any org
-- with signed-up users lacks an owner row, the migration fails loudly naming the
-- org, and a human inserts the owner row for the verified person by user id.
-- Verified Aug 26, 2026 against production: every org with users has an owner.
do $$
declare
  missing text;
begin
  select string_agg(coalesce(o.legal_name, o.name) || ' (' || o.id || ')', ', ')
    into missing
    from public.organizations o
   where exists (select 1 from auth.users u where u.raw_app_meta_data ->> 'org_id' = o.id::text)
     and not exists (select 1 from public.org_members m where m.org_id = o.id and m.role = 'owner');
  if missing is not null then
    raise exception 'v20.0.9: organizations with users but no org_members owner row — insert the verified owner by user id before deploying create-checkout-session: %', missing;
  end if;
end $$;

-- Manual path, run only by a human who has verified ownership (never automated):
-- insert into public.org_members (id, user_id, org_id, role, is_default_org, joined_at)
-- values (gen_random_uuid(), '<verified auth.users.id>', '<organizations.id>', 'owner', true, now());
