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
