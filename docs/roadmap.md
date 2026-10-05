# Provly — Roadmap Tracker

**How to read this:** ✅ merged and verified · 🔄 in progress (branch open) · ⬜ not started · 🧑 Tombé's task (no code).
**Rule:** the PR that completes an item flips its box in the same commit, so this file is only ever as stale as the last merge.
Updated: Oct 4 2026.

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
- ✅ v20.0.13 — Item 4 PR (c): write policies — one tier write policy per command on 44 tables; approved notes / reviewed incidents / submitted summaries locked with audited Reopen; client identity fields manage-only; EVV corrections supervisor-only; DSP shift status-only; audit + EVV edit logs append-only; front-line invite gate OFF; coworker names via `staff_directory_v` (merged Sep 16; **database half applied and verified Sep 23** — it had not been run on production until then)
- ✅ Go-live dry run — first deliver-tier login (Test Operator, Orem home): one home / one resident, own notes, no sign-off, lock-out on termination proven (Sep 16–22)
- ✅ v20.0.13a — front-line UI pass: Schedule own-row, office-only EVV submission panel and write actions, single accept on join (Sep 16)
- ✅ v20.0.13b — service-note form: front-line author fixed to self; codes limited to the client's current authorizations (office override) (Sep 19)
- ✅ v20.0.13c / 13d — co-staff for front-line logins = only the people who share the client (`staff_sharing_person`), not the roster (Sep 19)
- ✅ v20.0.13e — dashboard shows the business name only; Staff / Clients keep inactive last; click-to-sort headers (Sep 22)
- ✅ v20.0.14 — business dates anchored to America/Denver; date windows as calendar arithmetic (the evening "tomorrow" bug, app-wide) (Sep 22)
- ✅ v20.0.15 — client profile: Add Medication / Add Goal / New Service Note / Log Incident in context, client pre-set (Sep 22)
- ✅ v20.0.16 — EVV corrections as one database transaction: `correct_evv_session` requires the reason, writes the edit log and the correction together; the only office-tier path to clock times; open sessions allow only a live clock-out; a visit is never reopened; the edit log is written by nothing else (Sep 22; verified on production Sep 23)
- ✅ v20.0.17 — front door on the landing palette: ink, paper, care red; forest green for the completing action (Sep 22)
- ✅ v20.0.18 — the inside on the same palette: black sidebar with a red active bar, forest-green primary actions, flat surfaces; status colors keep their meaning (Sep 23)
- ✅ v20.0.19 — password reset: "Forgot password?" → Supabase recovery email through Provly's Resend SMTP → "Set a new password"; invite email in the new palette and naming the role ("Host Home Operator") (Sep 23)
- ✅ v20.0.20 — manager delete for draft / rejected service notes (submitted → reject first); database-enforced, every delete copied to the audit log; billed notes no longer deletable (Sep 24)
- ✅ v20.0.21 — front-line service notes need a current authorization (or an owning group-service context) on the service date — the note form's rule, now enforced by the database for deliver-tier logins (Sep 24)
- ✅ v20.0.22 — AI drafting proxy: `ai-draft` edge function holds the Anthropic key, owner / admin / compliance director only, reads notes under the caller's own access, sends only first name + codes + times + note text, audit row per draft. **Switched off until Provly's BAA with Anthropic is signed** (Sep 24)
- ✅ e520 design v1.0 approved — `docs/e520-design.md`, decisions D1–D9 (Sep 25)
- ✅ v20.0.23 — e520 PR 1, the recording pieces: client Absences tab (Family / Vacation / Hospital / AWOL / Jail / Other + required note; overlaps refused by the database; office tiers record); DSG notes carry "Transported (MTP)", preset to and from, and MTP leaves the new-note picker; quarter hours round to the nearest (8+ leftover minutes earn a unit) instead of always up (Sep 25)
- ✅ v20.0.23a — bulk approve: the new-note form saves as Save Draft or Submit (the author's statement the note is complete); only a note's author can Submit it (database-enforced, including no reassigning a note to yourself); office tiers approve submitted notes by client and month in one database call (`approve_service_notes`, one transaction, each note stamped by the approved-note lock) (Sep 26)
- ✅ v20.0.24 — e520 PR 2, the engine: `e520_build` fills UPI's download from approved notes (EVV lesser, nearest quarter hour per day, MTP from DSG rides, absences split lines, placement / authorization trims, monthly-max and remaining caps) and writes it back byte for byte; reservations stop a note being claimed twice; Mark uploaded / release a line / delete a draft; billed is locked like approved with no Reopen (Sep 26)
- ✅ v20.0.24a — HAP (rent) bills one unit per month in care per the placement, absences never reduce it; rejected authorizations never cover a day; the authorization used-units counter follows the payment file's rules and recounts on every note change; a billed HAP month stays with the authorization it was billed under (Sep 26)
- ✅ v20.0.25 — Finance → Payment Files (owners, admins, compliance directors): upload UPI's CSV, review lines / flags / removed lines / not-in-budget notes, download the file byte for byte, Mark uploaded with a recorded review of the flagged items (database-enforced) and UPI's record ID, release a line UPI closed (Sep 26)
- ✅ v20.0.25a — Payment Files: Compare with my file (client by client and code by code, with Provly's reasons beside each difference; in the browser, nothing stored); HAP and MTP out of the note pickers; compliance deadlines D23 / D24 say UPI payment files, not PRISM claims (Sep 26)
- ✅ v20.0.25b — the DSPD PID shows: Clients list column and profile; edits from the Clients list no longer erase the PID (the list didn't load it, so every edit saved it back blank); an edit now writes only the fields it loaded or changed; the form warns when a PID isn't 9 digits starting with 0 (Sep 28)
- ✅ v20.0.25c — DSI is a daily code in the code table; DSI authorizations recounted by the day (Sep 28)
- ✅ Authorizations design v1.0 approved — `docs/authorizations-design.md`, decisions A, D1–D4 (Sep 28)
- ✅ v20.0.26 — authorizations become 1056 rows: Approval ID, Kind (D / Q / S / M), max billable units per month, units for the period; the client profile's Authorizations tab is the one place rows are added and edited (Edit Client read-only; intake rows carry the same fields); every change audited; two counters per row in its Kind (this month, the period); D1 — a note during a budget lapse saves and managers see it flagged until the row is entered; PBA per session; the payment file fills S lines (Sep 30)
- ✅ v20.0.27 — renewals: a review list per client (Medicaid, DWS, PCSP meeting, Other; Mark Completed takes the next due date); the "Renewals & Budgets" card on the Dashboard and a Compliance tab, manage tier — budget ends, reviews due, and run-outs at the actual pace, 60 / 30 / 14 days (Oct 4)
- ✅ v20.0.28 — snappier: the Provly logo is a Home button; JSX-only compile (no ES5 down-compile), PDF/CSV libraries deferred, database preconnect; entrance animations 0.16s, no staggers (Oct 4)

## Tier 1 — finish Item 4 (security)
- 🔄 **Go live with identities.** Operator invites sent Sep 22 (Elena, Kujang, Ethan); Asunta once her email is on file; Siale and Asia held until they have someone to support (no assignment = empty login); assignments kept current as a security control.

## Tier 2 — small debts surfaced this cycle
- 🧑 **BAA with Anthropic.** Request a Business Associate Agreement for Provly's API account; compliance lead to review. Then set `ANTHROPIC_API_KEY` and `AI_BAA_CONFIRMED=true` in the Edge Function secrets and flip the landing row to shipped.
- ✅ **UPI, not PRISM.** Compliance deadlines D23 / D24 and the EVV export comment updated in v20.0.25a; "claims" → "payments" continues as screens are touched.
- 🧑 **Stripe:** delete the orphan Hope Haven customer ($0.00, Aug 1 4:18 PM) — confirm it is not `cus_Uzn7znOlF1QMue` first.
- 🧑 **Data hygiene:** Asunta Lubanga still has no email; delete the 4 old test draft notes; John Cena / John Berger → Inactive; 4 active clients have a PID that is not 9 digits — fix before the October shadow run (the e520 matcher keys on PID). (DSI daily: done in v20.0.25c.)

## Tier 3 — arcs Item 4 unlocks
- 🔄 **Billing: UPI e520 payment-file export.** Design v1.0 approved Sep 25 (`docs/e520-design.md`). PR 1 v20.0.23 recording pieces ✅ → v20.0.23a bulk approve ✅ → PR 2 v20.0.24 engine + billed lock ✅ → v20.0.24a HAP + used units ✅ → PR 3 v20.0.25 Payment Files tab ✅ → v20.0.25a Compare with my file ✅. Next: the October shadow run. October is the shadow run and the gate: Provly's October file is compared line by line with the hand-made one, and Provly's is uploaded (early November) only if every difference is explained — September's notes are still in Google Drive. October needs every billable day documented and approved in Provly: host home operators' daily notes, SLN notes with EVV, absences as they happen. The contract questions are answered (Sep 26): nearest quarter hour, no MTP trip log, a one-way ride bills the day, HAP per the placement.
- ✅ **Authorizations as 1056 rows.** Design v1.0 approved Sep 28 (`docs/authorizations-design.md`). v20.0.26 1056 rows + counters + lapse notes ✅ → v20.0.27 renewals ✅. The weekly email digest of the same card waits for the email arc.
- ✅ **Every active client's 1056 rows re-entered** on the Authorizations tab (Oct 4).
- ⬜ **Payment reconciliation.** Import the E520 Payment File Report's detail XLSX per status → UPI status on every batch line; then payment reports and deposits → expected (rate × units) vs received. Needs one masked "Paid by CAPS" detail XLSX.
- ⬜ **Email + team messaging.** Real outbound email and Slack-style team messaging; needs per-user identities (unblocked after (c)). Last two "coming soon" rows on the landing page.
- ⬜ **HIPAA posture.** BAA inventory (Supabase, Vercel, Anthropic, email sender); close gaps; then restore the badge on the landing page with substance behind it.
- ⬜ **Landing page maintenance.** "Is Provly an EHR?" FAQ line; flip rows as features ship; pricing copy if tiers move.
- ⬜ **Schema chores.** Schema-wide `varchar → text` + form length caps (phone VARCHAR(20) is the live trap); `hr` role carve-out if a larger provider needs it.
- ⬜ **v21.0 — Next.js / performance migration.** Endorsed Aug 26; after the product is stable enough to move without dropping anything.

## Conventions (unchanged)
Design doc before code · invariants in the database, never the client · small PRs in order · decisions one at a time · SQL run on production before ship · one paste-able terminal block per ship · Greptile to 5/5 then merge then verify the badge.
