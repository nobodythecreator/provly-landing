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

-- ── v20.0.9r6 (Greptile) — owner backfill, strict ───────────────────────────
-- org_id() resolves membership from the JWT's app_metadata.org_id, so an org can
-- be fully usable with no org_members row — but create-checkout-session is
-- fail-closed on an org_members owner row. Promote, per org lacking an owner, the
-- auth user carrying that org in app_metadata — ONLY when that user is the sole
-- one (r6: no email tie-breaker; a contact-address match is not ownership).
-- Orgs with several such users are left for a human. Idempotent.
insert into public.org_members (id, user_id, org_id, role, is_default_org, joined_at)
select gen_random_uuid(), c.user_id, c.org_id, 'owner', true, now()
from (
  select o.id as org_id, min(u.id::text)::uuid as user_id, count(*) as candidates
    from public.organizations o
    join auth.users u on u.raw_app_meta_data ->> 'org_id' = o.id::text
   where not exists (select 1 from public.org_members m where m.org_id = o.id and m.role = 'owner')
   group by o.id
) c
where c.candidates = 1
  and not exists (select 1 from public.org_members m where m.org_id = c.org_id and m.user_id = c.user_id);
