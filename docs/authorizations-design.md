# Provly — Authorizations as 1056 rows, lapses, reviews, renewals

**Design v1.0 · decided Sep 28, 2026 · delivery v20.0.26 → v20.0.27**

Status: v20.0.26 merged Sep 30, 2026 (with r1–r3). v20.0.27 built Oct 4, 2026 (`sql/v20.0.27.sql` + app). The weekly email digest waits for the email arc.

## Why

DSPD authorizes services on the **Person Centered Plan and 1056 Budget Approval** (the "1056"), which the provider accepts in UPI. Each service row carries:

| 1056 column | Meaning |
|---|---|
| Service | DSPD code (HHS, DSG, MTP, SLN, PBA, HAP, RHS, …) |
| Approval ID | DSPD's service/rate approval number — shared across clients, not a per-client ID |
| Start / End Date | the row's own date range (a new row starts when DSPD rates change on July 1) |
| Eligibility | e.g. SM |
| Kind | unit: **D** daily · **Q** quarter-hour · **S** per session · **M** monthly |
| Rate | per unit of that Kind |
| Max Billable Units | cap **per month** |
| Annual Units | total units **for that row's date range** (not a calendar or plan year) |
| Total $ · Daily Hours | informational |

Provly's authorization held one number. It was entered as the monthly max, but the used-units counter treats it as the total for the date range, so authorizations would read "all units used" within a month or two. Provly also had no unit per authorization (PBA is S on the 1056 but quarter-hour in the code table), couldn't edit an authorization's units or dates, and the payment-file engine fills only D, Q and M lines.

## Decisions

**A — an authorization is one 1056 row.** Fields: service, Approval ID, start, end, Kind (D/Q/S/M), rate, max billable units per month, units for the period (the 1056's "Annual Units"). Every field editable by manage tier (owner, admin, compliance director); every change audited. Two counters, both in the row's own Kind:
- **this month**: used vs max billable units
- **period**: used vs units for the period (the existing counter's meaning: used across the row's dates)

**D1 = B — notes during a lapse save, flagged.** A note whose date no authorization covers still saves when the client has had that code before (the budget lapsed, or the SC hasn't entered the new one yet). It is marked "no current authorization", visible to managers; the mark clears on its own once rows covering the date are entered, and the note then bills normally (that month's file, or a supplemental if already uploaded). A code the client never had is still refused for front-line staff. Rationale: care that happened must be documentable; SCs often enter budget updates late and the service is still funded.

**D2 = C — a review list per client.** Entries: type (Medicaid · DWS · PCSP meeting · Other with a name), due date, last completed date, note. Completing one records the date and takes the next due date.

**D3 = A now, B later — warnings live in Provly.** A "Renewals & budgets" card on the Dashboard and a section in Compliance, manage tier only. Thresholds 60 / 30 / 14 days. A weekly email digest (the same card) comes with the email arc.

**D4 = B — run-out by actual pace.** For each authorization row, after 30 days of history, project usage at the actual pace to the row's end date; warn when units run out before it, with the projected date ("at this pace, runs out around <date> — N days before the period ends"). The 100% "all units used" alert stays as a backstop. Absences lower the pace naturally (absence days don't bill), so budgets sized for expected absences don't false-alarm.

## Decided while building v20.0.26 (Sep 30)

**E = A — one editor.** The client profile's Authorizations tab is the one place 1056 rows are added, edited and deleted (manage tier). Edit Client shows the rows read-only with a link to the tab; its Add Auth row and client-side retry keys are retired — the database's identical-row guard (now comparing the 1056 fields too) and a client-generated id per open form carry that safety. The intake wizard keeps its step for a brand-new client, with the same fields and rules.

Implementation readings, stated in the PR:
- **Coverage** means the same thing in the note rule and the payment file: a row that isn't rejected (or closed) and whose dates include the day. An `expired` row covers its own dates (the status only records that the end date passed); v20.0.21 had excluded it.
- **"Had the code before"** (D1) = a row that isn't rejected, starting on or before the note's date. A code whose only row starts later is still refused for front-line staff.
- **The D1 check**: the note-authorization rule *was* enforced in the database (v20.0.21 trigger); v20.0.26 relaxes it there. The flag is computed on read (`notes_without_authorization`), so it clears on its own.
- **Existing rows**: max billable units per month is copied from the old units value on the first run (those values were entered as monthly maxes); units for the period stay as they are until re-entered.

## Decided while building v20.0.27 (Oct 4)

Implementation readings, stated in the PR:
- **One source.** `renewal_warnings()` in the database computes every warning; the Dashboard card, the Compliance tab and (later) the email digest all read it. Manage tier only; a signed-in caller can't choose the org or move "today".
- **Budget ends** also lists a client + code whose latest row ended within the last 60 days with no renewal entered. After 60 days the service is treated as ended; a longer lapse with ongoing service still shows through the D1 note flags.
- **Run-outs**: a row inside its dates with 30+ days of history; pace = used ÷ days elapsed; projected run-out = today + remaining ÷ pace; listed when it lands before the row's end, at any distance (beyond 60 days it shows as "later"). A row whose units are all used is listed too, as the backstop.
- **Review list** is read and written by the manage tier only, one entry per review type per client (Other: one per name). Completing one is a single write of the completion date and the next due date; the completion can't be in the future and the next due must follow it.
- Only active, not-discharged clients produce warnings.

## Warnings (v20.0.27)

1. **Budget ends** — a client + code whose latest row ends within 60/30/14 days and no later row is entered.
2. **Reviews due** — review-list entries due within 60/30/14 days, or overdue.
3. **Run-outs** — D4 projections.

## Delivery

**v20.0.26 — authorizations become 1056 rows** (needed before the early-November payment file):
- person_service_authorizations: Approval ID, Kind, max billable units per month; authorized_units = units for the period. Existing rows keep their values until re-entered from the 1056s.
- Full editing of authorizations (client profile), in the 1056's column order.
- Used-units counter uses the row's Kind (falling back to the code table); "this month" counter.
- D1 lapse rule (check whether the note-auth rule is also enforced in the database, not only the app).
- Payment-file engine: **S** lines — one unit per approved note (session), capped by the month's max / remaining units like other kinds. Code table: PBA → per session (check the billing_unit enum label).

**v20.0.27 — renewals**: review list per client (D2); the three warnings (D3, D4).

## Data to re-enter after v20.0.26

Every active client's current 1056 rows (the current authorizations were entered as monthly maxes with approximate rates and dates). Known before build: one client's code is SLN, not SLH; one client needs PBA and HAP rows; one client's budget period ends Sep 30, 2026, and its renewal must be entered when approved.
