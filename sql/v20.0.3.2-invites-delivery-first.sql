-- ============================================================================
-- Provly v20.0.3.2 — delivery-first supersede (Greptile round 5)
-- Run in the Supabase SQL editor for project zsrnqbmzgypldraifjho.
--
-- The pending-unique index forced revoke-BEFORE-insert in send-invite, which
-- made cleanup load-bearing: if replacement creation/delivery (or the
-- cleanup itself) failed, the recipient could be stranded linkless. The
-- function now creates + DELIVERS the new invite first and revokes older
-- pendings only after confirmed delivery — every failure residue leaves the
-- recipient with a usable link.
--
-- That ordering requires allowing >1 pending invite per (org, email)
-- transiently, so the index comes off. Duplicate pendings are harmless:
-- tokens are unguessable, acceptance enforces the invited email and
-- single-org membership (first accept wins; later tokens die at accept),
-- and expiry ages strays out. The send function still supersedes older
-- pendings on every successful delivery.
-- ============================================================================

DROP INDEX IF EXISTS idx_invites_pending_unique;

-- Verify after running:
--   SELECT indexname FROM pg_indexes WHERE tablename = 'invites';
--   -- expect: invites_pkey, idx_invites_org  (no idx_invites_pending_unique)
