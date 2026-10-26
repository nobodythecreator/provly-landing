# Provly — Pay Engine Design v1.0 (mileage + per-company pay rules)

| | |
|---|---|
| **Status** | APPROVED v1.1 — October 26, 2026 (v1.0 + Decisions 15–17, found while building R1b) |
| **Suggested repo path** | `docs/pay-engine-design.md` |
| **Policy sources** | `docs/pay-policy-sl-v1.1.md`, `docs/pay-policy-nursing-v1.1.md`, `dspd-service-code-reference-v1.md` |
| **Origin** | `provly-pay-and-mileage-handoff.md` (pay rules configuration + gaps 1–15) |

> **This file contains no SQL. Nothing in it is run in Supabase.** It is the design the R1 SQL and app
> changes are built from. Every SQL file in the delivery plan (§13) follows the usual conventions:
> preflight, a rolled-back self-test that pins any provider setting it depends on, a verification table,
> and executed migrations are never rewritten.

---

## v1.1 amendments (Decisions 15–17)

- **Hours worked come from two records:** EVV sessions (EVV codes) and time-clock punches (everything
  else). The weekly calculation (R1c) takes the union of each employee's records for the workweek, so an
  overlap is counted once and never twice.
- **Server clock for pay (Decision 16):** a live EVV session's pay hours use `server_clock_in_at` /
  `server_clock_out_at`. A corrected EVV session (rows in `evv_edit_log`) uses its corrected times.
  EVV rows from before v20.0.32c and completed or back-dated entries (no server times) use their
  recorded times. Punches are always server time; corrected punches use their corrected times.
- **Assigned in advance (nursing §3.1):** a non-billable punch counts as assigned when it is linked to
  a work block of the same type; an unlinked one is still paid and flagged.
- **Scheduled hours (SL §1, §3.5):** shifts cancelled with reason `no_fault` leave scheduled hours;
  `staff` cancellations and no-shows stay in.

## 1. Principles

1. **Three rule layers.** (1) Employment law — enforced, never editable; where law allows options, only
   compliant ones are offered. (2) Contract/SOW — locked per state and division; decides *what makes a
   unit count*. (3) Company pay policy — editable per tenant; decides *what a unit is worth*.
2. **Hope Haven is configuration, not code.** Its SL and nursing policies are tenant #1's data.
3. **Model everything, compute narrowly.** The schema holds both locked policies in full, including
   dormant parts; R1 computes only what pays people now.
4. **The database is the source of truth.** Invariants live in constraints, triggers and SECURITY
   DEFINER RPCs; clients never write pay tables directly.
5. **Mirror, never block recording reality.** Work is always recorded; problems become flags or holds.
6. **Every minute worked is paid.** Approval is a flag, never a condition of pay.
7. **Wages never wait on paperwork.** Hours recorded by EVV are paid on payday. Reimbursements can wait
   for the employee's confirmation.
8. **Provly calculates, payroll pays.** The export sends amounts; the payroll system never recalculates.
9. **No PHI leaves Provly through payroll.** Pay run lines carry no Person, visit or trip location.

---

## 2. Decision log

| # | Decision | Locked choice |
|---|---|---|
| 1 | Scope of R1 | **C** — general engine structure; R1 runs Hope Haven's payroll. In/out list in §3. |
| 2 | Nursing mileage | **A** — same as SL. The engine also models *IRS rate / fixed rate ≤ IRS / none*, with a minimum-wage check on unreimbursed cost and a state rule blocking *none* where reimbursement is required; **R1 accepts the IRS rate only**. |
| 3 | Trip distance source | **C** — straight-line distance between the two points × 1.3 road factor, computed in the database; staff confirm or correct. Long term: self-hosted routing inside Provly's BAA boundary (with the v21 servers, or sooner if a provider's volume demands it). Google Maps Platform is excluded by its own Acceptable Use Policy. |
| 4 | When a menu unit is payable | **B** — when billable under the e520 billing rules; paid with its date of service; reversed if not in the uploaded file or later denied. |
| 5 | Policy storage | **C** — typed tables grouped by shape; versions frozen once approved; all writes through RPCs. |
| 6 | Staff ↔ policies | **B** — many assignments per staff member; one combined weekly calculation per employee; no overlapping assignments; unassigned work holds the run; default assignment by role; worker type recorded. |
| 7 | Export | System-neutral pay run frozen at **Mark exported**; one configurable export for any payroll system that imports a file; Provly calculates, payroll pays; named systems are saved presets; printable fallback; API connections later. |
| 8 | Pay schedules | **A** — weekly, biweekly, semimonthly; split weeks pay straight time by date, overtime and make-up in the period where the week ends; schedule validated against state rules. |
| 9 | Off-duty gap | **B** — off duty only with a release on the schedule, a release notice logged at clock-out, and a gap ≥ drive time + 30 min; otherwise the whole gap is paid and long gaps are flagged. |
| 10 | Transport during a visit | **B** — Start/End transport taps (one GPS point and time each); estimate; staff confirm; typed miles as fallback. |
| 11 | Documentation time | **B** — actual time, timed from note open to submit; all paid; 15 min is a flag threshold. |
| 12 | Pay run approval | **B** (for now) — staff confirm trips → reviewer clears flags and holds → owner approves and exports. Steps are a company setting. |
| 13 | Pay data access | **B** (for now) — role-scoped, built as named permissions so a future HR/back-office role is a settings change. |
| 14 | Rollout | **B** — two shadow runs, then live. |
| 15 | Clocking work EVV doesn't cover | **A** — a staff-level time clock (punch in/out; one optional GPS point each end; hours recorded without location) for non-EVV service, indirect service, training, meetings and admin. EVV unchanged; one clock at a time, enforced in the database (v20.0.32). |
| 16 | Which clock pay hours use | **A** — the server's. EVV sessions carry database-set `server_clock_in_at` / `server_clock_out_at`; the time-clock hand-off ends a punch at the exact server moment the EVV clock-in arrives. Device EVV times stay the EVV and billing record (v20.0.32c). |
| 17 | Where scheduled non-service work lives | **B** — its own table, `work_blocks`, beside `shifts`; the live schedule and EVV shift-matching are untouched. Punches link to the block or shift they belong to (v20.0.34). |
| — | Nursing policy v1.1 | Non-billable nursing work at $30/hour (RN); payable-unit rule; reversal floor and authorization. |
| — | Host PN1 reversals (set in the Training Docs chat, Oct 12) | A host keeps the $10 PN1 add-on unless the denial was host-caused. Reversals record their cause (PN1 is not computed in R1). |

---

## 3. R1 scope

| In R1 | Later |
|---|---|
| Shift types + cancellation reason (Gap 1); overrun flag (Gap 3) | Tier review + qualifiers (R2, after one full month of R1 data) |
| Per-staff assignments, rates and per-unit pay items with effective dates (Gaps 4, 6) | Nursing monthly items: points/capacity, conversion check, salary records (Gap 9), true-up |
| Weekly calculation: hours by job, weighted-average OT, minimum-wage check and make-up, per-unit pay | PN2/PN1 records and pay (Gaps 7–8) — at the first PN2 Person |
| Nursing: PM2 pay path + non-billable nursing pay (v1.1) | Lead RN fee, LPN pay — at the first LPN |
| Plain hourly-by-code rate for codes without a policy (DSG today) | Director of Nursing bonus (needs employer payroll taxes + claim status) |
| Mileage: trips from EVV points, transport taps, estimate, classification, IRS rate table (Gaps 11–13 + Decision 10) | Claim status per unit (Gap 10) |
| Off-duty gap rule (Decision 9); documentation timer (Decision 11) | Driver/vehicle compliance (Gap 15) — small item right after R1 |
| Pay schedules, pay runs, approval workflow, holds/flags, reversals, adjustments | MTP billing documentation output (Gap 14) — waits on the Article 13 check |
| Configurable export + printable summary; Mark exported | Policy editor UI, margin preview, staff rate notices, templates, onboarding mapping, pay-off mode |
| Named pay permissions; access log | Routing service; payroll API adapters; embedded payroll |
| Shadow-run support | Other mileage modes (fixed, none) |

---

## 4. Data model

Names are working names; the build chat maps them to the existing schema (`staff`, `persons`, `shifts`,
`evv_sessions`, service notes, authorizations) and never creates a parallel table where one exists.
Every tenant table carries `org_id`, and every reference is tenant-closed with composite foreign keys.

### 4.1 Law layer (global, not tenant data)
| Table | Key fields | Seed |
|---|---|---|
| `law_min_wage` | jurisdiction, effective_from, hourly | US $7.25; UT $7.25 |
| `law_irs_mileage` | effective_from, rate | 2026-01-01 $0.725; 2026-07-01 $0.76 |
| `law_state_rules` | state, effective_from, max_pay_interval, max_payday_lag_days, mileage_reimbursement_required, deduction_needs_written_auth | UT: semimonthly, 10 (confirm), false, true |
| `law_federal` | ot_weekly_threshold, exempt_salary_weekly_min | 40; $684 |

### 4.2 Policy layer (Decision 5)
| Table | Key fields | Notes |
|---|---|---|
| `pay_policies` | id, name, division | Hope Haven: SL, Nursing, Hourly-by-code |
| `pay_policy_versions` | policy, label, effective_from, status (`draft`/`approved`), approved_by, approved_at, reason | Frozen once approved; one version per policy per effective date |
| `pay_items` | version, basis, service_code, pay_job, role, amount, earning_type | basis: `hour`, `billable_quarter_hour`, `visit`, `session`, `person_month`, `day`, `supervised_visit`, `nonbillable_hour` |
| `pay_policy_settings` | version, mileage_mode, mileage_fixed_rate, off_duty_buffer_min, documentation_expect_min | R1: mileage_mode must be `irs` |
| `pay_tiers`, `pay_tier_thresholds`, `pay_qualifiers`, `pay_counting_rules` | per version | Modeled in R1; computed in R2 |
| `pay_salary_rules`, `pay_bonus_rules` | per version | Modeled in R1 |
| `earning_types` | code, tax_class (`wages` / `nontaxable_reimbursement`), in_regular_rate | Global list |

### 4.3 Company settings
| Table | Key fields | Hope Haven |
|---|---|---|
| `pay_company_settings` | road_factor, assumed_speed_mph, overclaim_pct, documentation_idle_stop_min, approval_steps, reviewer_role | 1.30; 30; 25; set in build; staff→reviewer→owner; Compliance Director |
| `pay_schedules` | frequency, anchor_date, payday_offset_days, effective_from | Hope Haven's choice when payroll is set up (biweekly avoids split weeks) |

### 4.4 Staff layer (Decision 6)
| Table | Key fields | Notes |
|---|---|---|
| `staff_pay_assignments` | staff, policy, pay_job, worker_type (`w2`/`contractor`), override_amount, override_reason, approved_by, effective range | No two assignments for the same staff + pay job may overlap in time |
| `pay_role_defaults` | role, policy, pay_job | New hires get a starting assignment by role |
| `staff_payroll_ids` | staff, export_setup, external_id | Per payroll system |
| `staff_deduction_authorizations` | staff, signed_on, document_ref, revoked_on | Required before any wage deduction |

### 4.5 Time and trips
| Table | Key fields | Decision |
|---|---|---|
| `shifts` (extend) | shift_type, nullable person/code for non-service types, cancellation_reason | Gap 1 |
| `schedule_releases` | staff, segment_before, segment_after, return_at | 9 |
| `release_notices` | release, shown_at, acknowledged_at, issued_by (`system`/`supervisor`) | 9 |
| `documentation_segments` | staff, note, started_at, ended_at, source (`timer`/`corrected`), reason | 11 |
| `trips` | staff, kind (`between_visits`/`transport`), from point + time, to point + time, est_miles, est_drive_min, confirmed_miles, miles_source (`estimate`/`staff_corrected`/`staff_entered`/`route`), classification (`between_persons`/`transport_person`/`post_gap`), correction_reason, confirmed_at, pay_run | 3, 9, 10 |
| `overrun_approvals` | evv_session, minutes_over, approved_by, reason | Gap 3 |

Commute legs are never created: there is no EVV point at a staff member's home.

### 4.6 Pay runs (Decisions 7, 12, 14)
| Table | Key fields | Notes |
|---|---|---|
| `pay_runs` | period_start, period_end, payday, mode (`shadow`/`live`), status (`open`→`confirming`→`in_review`→`approved`→`exported`) | Frozen at `exported` |
| `pay_run_lines` | run, staff, pay_job, earning_type, workweek_start, hours, amount | **No Person column** |
| `pay_line_sources` | line, source_kind, source_id | Detail behind each line (visits, trips) for the earnings breakdown; never exported |
| `pay_holds_flags` | run, kind, severity (`hold`/`flag`), ref, status, note, cleared_by | Holds block approval; flags need a note |
| `pay_reversals` | unit_ref, original_workweek, amount_due, amount_after_floor, cause, authorization_ok, applied_run | Cause includes host-caused / other |
| `pay_adjustments` | run, staff, workweek_start, amount, reason, approved_by | Prior-week corrections |
| `shadow_comparisons` | run, staff, provly_amount, actual_amount, difference, explanation | Decision 14 |

### 4.7 Export (Decision 7)
| Table | Key fields | Notes |
|---|---|---|
| `export_setups` | name, preset, layout (`row_per_employee`/`row_per_job`), columns, date_format, effective_from, approved_by | Owner-only, versioned |
| `export_code_map` | setup, earning_type, target_code, tax_class_confirmed | Owner confirms tax class per mapping |
| `pay_run_exports` | run, setup, file_hash, generated_at, test_only | Shadow runs export `test_only` |

### 4.8 Permissions (Decision 13)
| Table | Key fields | Hope Haven R1 |
|---|---|---|
| `pay_role_permissions` | role, permission | Owner: all. Compliance Director: `pay.view_all`, `pay.review_run`. Staff and hosts: `pay.view_own`. |
| `pay_access_log` | viewer, subject_staff, viewed_at, rpc | Every read of another person's pay |

Permissions: `pay.view_own`, `pay.view_all`, `pay.review_run`, `pay.approve_run`, `pay.manage_rates`,
`pay.manage_policies`, `pay.manage_export`.

---

## 5. Invariants (enforced in the database)

1. An approved policy version cannot be changed; a change is a new version with a later effective date.
2. No overlapping assignments for one staff member and pay job.
3. `mileage_mode` other than `irs` is rejected in R1.
4. A pay schedule that breaks a state rule is rejected (interval longer than semimonthly in Utah; payday
   later than the state lag); weekly and biweekly periods must start on a Sunday.
5. A pay run cannot be approved while any hold is open; flags need a note before approval.
6. An exported pay run cannot change; later corrections are adjustment lines in a later run.
7. A reversal never takes back the minimum-wage floor of its original week, and is deducted from wages
   only when a deduction authorization is on file.
8. `pay_run_lines` has no Person column; the export is generated only from pay run lines.
9. Only the owner (`pay.manage_rates`, `pay.manage_policies`, `pay.manage_export`) changes rates,
   policies or export setups.
10. All writes go through SECURITY DEFINER RPCs; reads are RLS-scoped by permission and logged when they
    cover another person's pay.

---

## 6. Time and trip capture

**Off-duty test** (Decision 9; 29 CFR 785.16):
```
drive_time(gap) = scheduled travel block if one exists, else est_miles ÷ assumed_speed_mph × 60
off_duty(gap)   = schedule_release exists
                  AND release_notice logged at (or before) clock-out
                  AND (next clock_in − clock_out) ≥ drive_time + off_duty_buffer_min (30)
paid gap        = whole gap, unless off_duty — at the next segment's rate (SL)
flag            = "long gap, no release" when gap > drive_time + 30 and no release
```
Reconciliation note: SL v1 used "scheduled travel"; Decision 9 used Provly's estimate. The design uses
the scheduled travel block where one exists and the estimate otherwise.

**Trips** (Gap 11, Decisions 3, 10):
```
est_miles = haversine(from_point, to_point) × road_factor (1.30)
between_visits trip: from EVV clock-out point to next EVV clock-in point
transport trip:      from Start-transport tap to End-transport tap (inside a visit)
classification: post_gap if off_duty(gap); transport_person if kind = transport; else between_persons
over-estimate flag:  confirmed_miles > est_miles × (1 + overclaim_pct)
```
No location is ever captured outside EVV clock points and transport taps.

**Documentation** (Decision 11): opening a note after clock-out starts a documentation segment;
submitting ends it; inactivity stops it; staff may correct with a reason. Over
`documentation_expect_min` (15) is flagged. For nurses the segment counts as hours worked but is not paid
separately (menu rates include it).

---

## 7. Weekly calculation (per employee, all assignments combined)

```
for each employee, workweek (Sunday–Saturday):
  hourly_pay     = Σ minutes × rate(staff, pay_job, date) / 60
                   over service, paid gaps, documentation, training, meetings, overruns
                   (SL gap/travel → next segment's job; training/meeting → SLN)
  unit_pay       = Σ payable units with service date in the week × pay_item amount
                   payable(unit) = billable under the e520 rules (approved note; EVV where the code
                   requires it; current authorization with units remaining; no conflict flags)
  nonbillable    = nurse non-billable hours × nonbillable_hour rate
  weekly_pay     = hourly_pay + unit_pay + nonbillable + add-ons
  hours_worked   = all recorded working time (incl. nurse travel and documentation, paid gaps)
  makeup         = max(0, hours_worked × min_wage(state, date) − weekly_pay)
  regular_rate   = (weekly_pay + makeup) ÷ hours_worked
  ot_premium     = 0.5 × regular_rate × max(0, hours_worked − 40)
  mileage        = Σ confirmed trips (between_persons, transport_person) × irs_rate(trip date)
```
- **Split weeks** (semimonthly): straight time goes to the period containing each date; `makeup` and
  `ot_premium` go to the period where the workweek ends.
- **Late approvals:** a unit approved after cutoff is paid in the next run as a prior-week adjustment,
  recalculated in its own workweek.
- **Reversals:** `reversal = max(0, paid_for_week − recompute_week_without(unit))` — the recompute applies
  the floor and overtime again. Deducted only with an authorization on file; otherwise flagged.
- **Salaried exempt staff** (later): no minimum-wage or overtime check; instead salary ≥ $684/week and no
  reduction for volume.

---

## 8. Pay runs

**Schedule** (Decision 8): company setting; validated against `law_state_rules`.

**Workflow** (Decision 12):
1. `confirming` — staff confirm trips (required for reimbursement) and may confirm hours or raise a
   correction. Unconfirmed trips move to the next run; unconfirmed hours are paid as EVV recorded them.
2. `in_review` — the reviewer clears holds and annotates flags.
3. `approved` → `exported` — the owner approves (blocked while holds are open), generates the file,
   uploads it, and marks it exported. The run freezes.

**Holds** (block approval): unassigned work; billed exceeds paid.
**Flags** (need a note): unapproved non-billable time; long gap, no release; documentation over 15 min;
trip over estimate; mileage with no adjacent EVV points; overrun; minimum-wage make-up; reversal capped;
reversal without authorization.

---

## 9. Export (Decision 7)

- Lines are rendered through the active `export_setup`: layout, column names, date format, earning-code
  map, employee IDs. Named systems (Gusto, ADP, Paychex, QuickBooks Payroll) are saved presets.
- **Amounts, not math:** every earning type is sent as a dollar amount; hours travel along for the paystub.
- Each earning type carries a tax class; mileage must map to a non-taxable reimbursement code, and the
  owner confirms each mapping's tax class.
- W-2 lines and contractor lines are exported separately (worker type).
- A printable per-employee summary is always available for manual entry.
- Past runs can be re-exported under a new setup (switching payroll systems mid-year).
- Edits made inside the payroll system after import are not seen by Provly; corrections go through Provly
  adjustments. Importing the payroll system's pay register for comparison is a later item.

---

## 10. Permissions (Decision 13)

As in §4.8. Staff see their own earnings breakdown, trips and confirmations; the reviewer sees pay runs
(open and past) and the records behind each flag, clears flags and approves adjustments with a reason,
and cannot change rates or policies; the owner has everything; hosts see their own contractor payments.
A future HR role receives `pay.view_all` (and later, perhaps, `pay.manage_rates` with owner approval).

---

## 11. Employment-law checks (layer 1)

| Check | Rule | Where |
|---|---|---|
| Hours worked | All recorded working time; off duty only under 29 CFR 785.16 | §6 |
| Minimum wage | Weekly; make-up when short; never taken back by a reversal | §7 |
| Overtime | Over 40 per workweek; weighted-average regular rate across all pay | §7 |
| Split weeks | Overtime and make-up in the period where the week ends (29 CFR 778.106) | §7 |
| Pay frequency | Utah: no longer than semimonthly; payday within the state lag | §8 |
| Deductions | Written authorization required (Utah Code 34-28-3(6)(b)) | §7 |
| Mileage | Non-taxable up to the IRS rate; employee confirmation required; *none* blocked where state law requires reimbursement (later modes) | §6, §9 |
| Exempt salary | ≥ $684/week; no reductions for volume (later) | §7 |

---

## 12. Rollout (Decision 14)

- **Two shadow runs.** Runs are created with `mode = shadow`: Provly calculates the whole run, the export
  is generated as `test_only`, and staff are paid the current way. If no current payroll exists, the
  reviewer's hand calculation is the comparison.
- The export file is **test-imported** into a draft payroll in the chosen payroll system and discarded.
- Every difference is recorded in `shadow_comparisons` and either fixed or explained.
- **Exit:** two consecutive shadow runs with every difference explained → switch to `live`.
- **Before the first live run:** payroll system chosen and set up; export setup saved; payroll IDs entered;
  written pay agreements signed (nursing guide + deduction authorization); pay schedule saved.

---

## 13. Delivery plan

Version numbers are assigned at ship time (next free after v20.0.30). Each PR is reviewed to Greptile 5/5.

| PR | Contents | Runs in Supabase? |
|---|---|---|
| **R1a — Policy schema + seed** | Law tables; policies, versions (freeze), pay items, settings, modeled tier/salary/bonus tables; earning types; assignments (overlap constraint), role defaults, payroll IDs, deduction authorizations; permissions + access log; Hope Haven seed (SL v1.1, nursing v1.1, hourly-by-code for DSG) | **Yes** — SQL migration |
| **R1b — Time and trip capture** (split into PRs) | v20.0.32 ✅ time clock + server clock (Decisions 15–16) · v20.0.33 ✅ front-line EVV hotfix · v20.0.34 work blocks, shift cancellation reasons, punch ↔ schedule links (Decision 17) · v20.0.35 schedule releases + release notices (Decision 9) · v20.0.36 transport taps, trips with estimate and classification, trip confirmation screen · v20.0.37 documentation timer, overrun approvals | **Yes** — SQL migration + app file per PR |
| **R1c — Weekly calculation** | Weekly engine (§7) incl. per-unit payable check via the e520 rules, non-billable nursing pay, minimum-wage make-up, overtime, split weeks, mileage, reversals; fixtures T1–T29, N1–N26, E1–E12 as rolled-back self-tests | **Yes** — SQL migration |
| **R1d — Pay runs + export** | Pay schedules; pay runs + workflow; holds/flags; adjustments; export setups + code map; export file + printable summary; Mark exported; shadow mode + comparisons; reviewer and owner screens | **Yes** — SQL migration + app file |
| Shadow run 1, shadow run 2 → live | Operational | No |
| **R2** | Tier review + qualifiers; nursing monthly items | Yes (later) |

R1c preflight confirms the e520 per-unit billability rules are callable from SQL; if they are not, R1c
exposes them first rather than copying them.

---

## 14. Engine test cases (in addition to SL T1–T29 and nursing N1–N26)

| # | Input | Expected |
|---|---|---|
| E1 | DSP clocks an SLN visit with no matching assignment | Unassigned-work hold; approval blocked until an assignment exists; hours still recorded |
| E2 | Second assignment for the same staff + pay job overlapping an existing one | Rejected by constraint |
| E3 | One week: 30 SLN hrs at $18 (SL policy) + 15 DSG hrs at $17 (hourly-by-code; fixture rate) | Straight $795.00; regular rate $17.6667; OT premium $44.17; gross $839.17 |
| E4 | Update an approved policy version's pay item | Rejected; new version required |
| E5 | Export setup maps mileage to a taxable earning code | Owner must confirm the tax class; warning stored with the setup |
| E6 | Run exported; a note for that week is approved afterward | Prior-week adjustment line in the next run, recalculated in its original workweek |
| E7 | Staff A requests staff B's earnings | Denied |
| E8 | Reviewer opens staff B's earnings | Allowed; row in `pay_access_log` |
| E9 | Biweekly schedule anchored on a Wednesday | Rejected |
| E10 | Monthly pay schedule for Utah hourly staff | Rejected (longer than semimonthly) |
| E11 | Policy setting `mileage_mode = none` in R1 | Rejected |
| E12 | Shadow run exported | File marked `test_only`; run cannot be marked exported as live |

---

## 15. Open items and dependencies

| Item | Owner | Blocks |
|---|---|---|
| Choose and set up a payroll system; send its import template (becomes the first preset) | Tombé (this week) | Export preset; shadow test-import |
| Choose Hope Haven's pay schedule (biweekly recommended) | Tombé | Pay schedule seed |
| Written pay agreements + deduction authorizations (nursing guide update in the Training Docs chat) | Tombé | First live run |
| Article 13 check: does MTP require the TRIP template (pickup/drop-off locations and times)? | Compliance | Gap 14; e520 MTP lines |
| Supabase BAA | Tombé | — (standing) |
| Utah payday lag: confirm 10 days | Build chat (verify) | `law_state_rules` seed |
| SL staff guide update after this design is approved (Training Docs chat) | Tombé | — |
| DSG/DSP pay policy (census premium) | Next pay-policy item | Replaces hourly-by-code for DSG |
| LPN non-billable rate | At first LPN hire | — |
