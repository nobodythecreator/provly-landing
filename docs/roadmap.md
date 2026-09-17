# Provly — Roadmap Tracker

**How to read this:** ✅ merged and verified · 🔄 in progress (branch open) · ⬜ not started · 🧑 Tombé's task (no code).
**Rule:** the PR that completes an item flips its box in the same commit, so this file is only ever as stale as the last merge.
Updated: Sep 16 2026.

## Done this cycle
- ✅ v20.0.10 — client-form integrity + EVV edit-with-reason (Sep 7)
- ✅ v20.0.10a — organizations schema drift (forward) (Sep 9)
- ✅ v20.0.10b — Enterprise cap 500; tiers 10 / 50 / 250 / 500 (Sep 10)
- ✅ v20.0.10c — root → /app temporary redirect (getprovly.com was a 404) (Sep 10)
- ✅ v20.0.10d — landing page: black and white, red accent, self-serve trial; replaces the redirect (Sep 10)
- ✅ Item 4 design doc v1.1 approved — role model, tiers, sight edges, ceiling rule, invite binding (Sep 9–10)
- ✅ v20.0.11 — Item 4 PR (a): identity + membership + reverse drift (Sep 11)
- ✅ v20.0.11a — tenant-isolation hotfix: seven tables had USING(true) policies (Sep 12)
- ✅ v20.0.12 — Item 4 PR (b): read policies — tenant guard = org claim + live membership on 44 tables; one tier read policy per table (manage / operate / deliver); `person_service_authorizations_v` (rate hidden below manage) and `staff_directory_v`; schedule → 7-day sight edge; owner fallback retired (no membership = no access); nav by tier; Assignments person-edge list (Sep 16)
- ✅ v20.0.12a — Staff → Assignments lists visible again (two FKs since v20.0.4g; embeds name the composite FK; failed loads show an error, never an empty list) (Sep 16)
- ✅ v20.0.13 — Item 4 PR (c): write policies — one tier write policy per command on 44 tables; approved notes / reviewed incidents / submitted summaries locked with audited Reopen; client identity fields manage-only; EVV corrections supervisor-only; DSP shift status-only; audit + EVV edit logs append-only; front-line invite gate OFF; coworker names via `staff_directory_v` (Sep 16)

## Tier 1 — finish Item 4 (security)
- ⬜ **Go live with identities.** Invite the seven unlinked Hope Haven records (front line included); retire the shared org login; assignments kept current as a security control.

## Tier 2 — small debts surfaced this cycle
- ⬜ **AI drafting proxy.** Edge function holding the Anthropic key server-side; the AI page has never worked in production (browser-side calls, no key). Flips the landing row to shipped.
- ⬜ **EVV correction RPC.** `correct_evv_session(session_id, patch, reason)` — edit-log row + session update in one transaction; becomes the only office-tier write path to clock times, so a reason and a log entry are database guarantees rather than app behavior (today: two client requests, audit first).
- ⬜ **UPI, not PRISM.** Compliance-deadline D23 text + EVV export comment; begin "claims" → "payments" vocabulary.
- 🧑 **Stripe:** delete the orphan Hope Haven customer ($0.00, Aug 1 4:18 PM) — confirm it is not `cus_Uzn7znOlF1QMue` first.
- 🧑 **Staff data hygiene before go-live:** Elena Felix email has a stray `<`; Asunta Lubanga has no email; Kevin Halverson is in twice; Ethan Fox is roled DSP (operator?).

## Tier 3 — arcs Item 4 unlocks
- ⬜ **Email + team messaging.** Real outbound email and Slack-style team messaging; needs per-user identities (unblocked after (c)). Last two "coming soon" rows on the landing page.
- ⬜ **Billing: UPI e520 payment-file export.** Month-end file from approved notes + EVV units with the manual's validation rules pre-checked. First decision: confirm column order from a real UPI download. Also verify the app's 90-day / 30-day payment deadlines against the DSPD manual.
- ⬜ **HIPAA posture.** BAA inventory (Supabase, Vercel, Anthropic, email sender); close gaps; then restore the badge on the landing page with substance behind it.
- ⬜ **Landing page maintenance.** "Is Provly an EHR?" FAQ line; flip rows as features ship; pricing copy if tiers move.
- ⬜ **Schema chores.** Schema-wide `varchar → text` + form length caps (phone VARCHAR(20) is the live trap); `hr` role carve-out if a larger provider needs it.
- ⬜ **v21.0 — Next.js / performance migration.** Endorsed Aug 26; after the product is stable enough to move without dropping anything.

## Conventions (unchanged)
Design doc before code · invariants in the database, never the client · small PRs in order · decisions one at a time · SQL run on production before ship · one paste-able terminal block per ship · Greptile to 5/5 then merge then verify the badge.
