# Provly — Roadmap Tracker

**How to read this:** ✅ merged and verified · 🔄 in progress (branch open) · ⬜ not started · 🧑 Tombé's task (no code).
**Rule:** the PR that completes an item flips its box in the same commit, so this file is only ever as stale as the last merge.
Updated: Sep 22 2026.

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
- ✅ Go-live dry run — first deliver-tier login (Test Operator, Orem home): one home / one resident, own notes, no sign-off, lock-out on termination proven (Sep 16–22)
- ✅ v20.0.13a — front-line UI pass: Schedule own-row, office-only EVV submission panel and write actions, single accept on join (Sep 16)
- ✅ v20.0.13b — service-note form: front-line author fixed to self; codes limited to the client's current authorizations (office override) (Sep 19)
- ✅ v20.0.13c / 13d — co-staff for front-line logins = only the people who share the client (`staff_sharing_person`), not the roster (Sep 19)
- ✅ v20.0.13e — dashboard shows the business name only; Staff / Clients keep inactive last; click-to-sort headers (Sep 22)
- ✅ v20.0.14 — business dates anchored to America/Denver; date windows as calendar arithmetic (the evening "tomorrow" bug, app-wide) (Sep 22)
- ✅ v20.0.15 — client profile: Add Medication / Add Goal / New Service Note / Log Incident in context, client pre-set (Sep 22)
- ✅ v20.0.16 — EVV corrections as one database transaction: `correct_evv_session` requires the reason, writes the edit log and the correction together; the only office-tier path to clock times; the edit log is written by nothing else (Sep 22)

## Tier 1 — finish Item 4 (security)
- 🔄 **Go live with identities.** Operator invites sent Sep 22 (Elena, Kujang, Ethan); Asunta once her email is on file; Siale and Asia held until they have someone to support (no assignment = empty login); assignments kept current as a security control. (The "retire the shared org login" step is void — no shared login ever existed.)

## Tier 2 — small debts surfaced this cycle
- ⬜ **AI drafting proxy.** Edge function holding the Anthropic key server-side; the AI page has never worked in production (browser-side calls, no key). Flips the landing row to shipped.
- ⬜ **Service-note delete (manage).** The database allows a manager to delete an unapproved note; the app has no button. Confirm dialog, unapproved only.
- ⬜ **Invite email wording.** Says "as hhs_operator" — use the role's label ("Host Home Operator").
- ⬜ **Deliver-tier service-note insert rule.** Server-side: a front-line note needs a current authorization for its code on its date (or a context that owns the code) — today the form enforces it.
- ⬜ **UPI, not PRISM.** Compliance-deadline D23 text + EVV export comment; begin "claims" → "payments" vocabulary.
- 🧑 **Stripe:** delete the orphan Hope Haven customer ($0.00, Aug 1 4:18 PM) — confirm it is not `cus_Uzn7znOlF1QMue` first.
- 🧑 **Staff data hygiene:** Asunta Lubanga still has no email (Elena's email and Ethan's role were fixed Sep 22; the two Kevin Halverson rows are inactive).

## Tier 3 — arcs Item 4 unlocks
- ⬜ **Email + team messaging.** Real outbound email and Slack-style team messaging; needs per-user identities (unblocked after (c)). Last two "coming soon" rows on the landing page.
- ⬜ **Billing: UPI e520 payment-file export.** Month-end file from approved notes + EVV units with the manual's validation rules pre-checked. First decision: confirm column order from a real UPI download. Also verify the app's 90-day / 30-day payment deadlines against the DSPD manual.
- ⬜ **HIPAA posture.** BAA inventory (Supabase, Vercel, Anthropic, email sender); close gaps; then restore the badge on the landing page with substance behind it.
- ⬜ **Landing page maintenance.** "Is Provly an EHR?" FAQ line; flip rows as features ship; pricing copy if tiers move.
- ⬜ **Schema chores.** Schema-wide `varchar → text` + form length caps (phone VARCHAR(20) is the live trap); `hr` role carve-out if a larger provider needs it.
- ⬜ **v21.0 — Next.js / performance migration.** Endorsed Aug 26; after the product is stable enough to move without dropping anything.

## Conventions (unchanged)
Design doc before code · invariants in the database, never the client · small PRs in order · decisions one at a time · SQL run on production before ship · one paste-able terminal block per ship · Greptile to 5/5 then merge then verify the badge.
