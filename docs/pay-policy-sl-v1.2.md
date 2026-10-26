# Hope Haven — Supported Living Pay Policy v1.1 (LOCKED)
### Policy + Provly payroll specification

| | |
|---|---|
| **Status** | LOCKED — v1.2, October 26, 2026 (supersedes v1.1) |
| **Effective** | October 12, 2026 |
| **Owner** | Tombé (CEO), Hope Haven Services Inc. |
| **Applies to** | Staff delivering SLN and SLH |
| **Out of scope (v1.1)** | CMP/CMS (family caregivers), PM1/PM2, PN1/PN2 (see `docs/pay-policy-nursing-v1.1.md`), BC1–BC3, career-ladder steps |
| **Payroll system** | Any payroll system that imports a file. Provly calculates; the payroll system pays (pay-engine Decision 7). None set up yet as of Oct 12, 2026. |
| **Suggested repo path** | `docs/pay-policy-sl-v1.1.md` (v1 stays in the repo as the record of the prior version) |

> **For the Provly build chat:** this file is the source of truth for how Supported Living
> staff are paid. Sections 1–8 are the policy. Section 9 is the implementation spec. Sections
> 10–11 are worked examples and test cases with exact expected answers. Map the entities in
> Section 9 to the existing schema (`staff`, `persons`, authorizations, `shifts`,
> `evv_sessions`, service notes) — do not create parallel tables where one already exists.
> The engine design is `docs/pay-engine-design.md`.
> **This file contains no SQL. Nothing in it is run in Supabase.**

---

## Changes from v1

| # | Change | Section | Pay-engine decision |
|---|---|---|---|
| 1 | Off-duty gap requires a release on the schedule, a release notice logged at clock-out, and a gap of at least drive time + 30 min; any other gap is paid in full | §4 | 9 |
| 2 | Documentation paid on actual time (timed from note open to submit); 15 min is an expectation, and time over it is flagged, never unpaid | §4 | 11 |
| 3 | Transport during a visit captured with Start/End transport taps; typed miles as fallback | §6 | 10 |
| 4 | Mileage needs staff confirmation; unconfirmed trips move to the next pay run; IRS rate table | §6 | 3, 12 |
| 5 | Gusto-specific rules removed: Provly calculates overtime and exports amounts to any payroll system | §5, §8 | 7 |
| 6 | Pay schedule is a company setting; split-week rule for semimonthly schedules | §5 | 8 |
| 7 | Overpayment recovery by deduction requires written authorization | §5 | 4 |
| 8 | Data, outputs and flags updated; examples A and B updated; T3 updated; new tests T18–T29 | §9–11 | — |
| 9 | v1.2: pay hours use the server-recorded times of the EVV clock-in and clock-out; EVV's own times stay the EVV and billing record | §4 | 16 |
| 10 | v1.2: training, meetings and other non-EVV work are clocked on the time clock and can be scheduled in advance as work blocks | §4 | 15, 17 |
| 11 | v1.2: a cancelled shift records who cancelled it (no-fault or staff) | §1, §9 | 17 |

---

## 1. Definitions

| Term | Definition |
|---|---|
| **Workweek** | Sunday 12:00 AM through Saturday 11:59 PM. Matches SOW 31.4(4) (CMP/CMS 40-hour week). Overtime is always calculated per workweek. |
| **Pay job** | A pay category with its own rate: `SLN`, `SLH`. Training and meetings are paid at the staff member's SLN rate. |
| **Service segment** | A block of time delivering SLN or SLH to one Person, recorded by EVV. |
| **Non-service block** | Paid time with no billable service: travel, documentation, training, meeting. Indirect services (SOW 31.2(2)) are a service segment — billable and tied to a Person. |
| **Billable hours** | Hours of service segments (including indirect services) that are billed to DSPD. |
| **Paid hours** | All compensable time: service segments + travel + paid gaps + documentation + training + meetings + overruns. |
| **Scheduled hours** | Hours on the published schedule, excluding shifts cancelled by the Person, guardian, or Hope Haven ("no-fault cancellations"). Staff no-shows and staff-initiated cancellations stay in scheduled hours. |
| **Counted Person** | A Person who counts toward a staff member's headcount for the month (see 3.2). |
| **Tier** | Base, Tier 1, or Tier 2. Sets the staff member's SLN and SLH rates for the month. |
| **Release** | A break between two scheduled segments, marked on the schedule, with the next segment's start as the set return time. |
| **Drive time** | The scheduled travel block between two segments if one exists; otherwise Provly's estimate (estimated miles at the company's assumed average speed, 30 mph to start). |

---

## 2. Rates

| Tier | Qualifies with (either path) | SLN rate | SLH rate |
|---|---|---|---|
| **Base** | Default | **$18.00** | **$21.00** |
| **Tier 1** | 3–4 counted Persons **or** 25+ avg weekly billable hours | **$19.00** | **$22.00** |
| **Tier 2 (cap)** | 5–6 counted Persons **or** 32+ avg weekly billable hours | **$20.00** | **$23.00** |

- SLH pays more than SLN because SLH carries primary responsibility for the Person's health and safety.
- A staff member's tier applies to **both** of their pay jobs.
- The tier premium is built into the rate itself (not a separate bonus line), so it is automatically included in the regular rate for overtime.

---

## 3. Tier qualification

### 3.1 Two paths, whichever is reached first
A staff member's tier is the **higher** of:
- **Persons path:** number of counted Persons in the review month.
- **Hours path:** average weekly billable hours in the review month.

### 3.2 The 25% counting rule
A Person is a **counted Person** for a staff member only if that staff member **delivered at least 25%** of the Person's total scheduled SL hours in the month (across all staff).

```
share = hours delivered to Person by this staff member in month
        ÷ Person's total scheduled SL hours in month (all staff)
counted if share ≥ 0.25
```
- A Person with zero scheduled hours in the month is not counted.
- Hours delivered to a non-counted Person still count fully toward the **hours path**.
- Purpose: prevents backup or fill-in coverage from inflating headcount tiers.

### 3.3 Average weekly billable hours
```
avg_weekly_billable = total billable hours in month ÷ (days in month ÷ 7)
```

### 3.4 Cap
- Maximum of **6 counted SL Persons** per staff member. Tier 2 is the top tier.
- Assigning a 7th counted Person must be blocked or flagged at scheduling.

### 3.5 Qualifiers — all three required to hold or gain a tier
| Qualifier | Definition | Threshold |
|---|---|---|
| **Billable share** | billable hours ÷ (service + travel + paid gap + documentation hours). Training and meetings excluded from the denominator. | ≥ 80% |
| **Delivery** | For each counted Person: hours delivered ÷ this staff member's scheduled hours with that Person. No-fault cancellations excluded. | ≥ 90% for every counted Person |
| **Notes on time** | Service notes submitted by 11:59 PM on the service date ÷ all service notes due | ≥ 95% |

### 3.6 Review cycle and effective dates
- Tiers are reviewed monthly, using the prior calendar month's data.
- **Moving up:** if the staff member qualifies for a higher tier and meets all three qualifiers, the new rate takes effect on the **1st of the next month**.
- **Grace:** if a qualifier is missed in month M, the rate stays the same for month M+1 and the staff member is flagged.
- **Moving down:** if a qualifier is missed again in month M+1, the rate drops to the tier the data supports on the **1st of month M+2**.
- **New staff:** Base rate until their first full calendar month is reviewed.

---

## 4. Paid time rules

| Time | Paid? | Rate | Notes |
|---|---|---|---|
| **Service segment** | Yes, to the minute | SLN or SLH rate | EVV records the visit. Pay hours use the server-recorded times of the EVV clock-in and clock-out (pay-engine Decision 16); EVV's own times stay the EVV and billing record. |
| **Gap between back-to-back segments** (not off duty) | Yes, in full | Rate of the Person being driven **to** | Covers the drive and any waiting. A gap longer than drive time + 30 min with no release is flagged so the schedule gets fixed — still paid. |
| **Commute** to first Person / home from last | No | — | Ordinary commute. |
| **Off-duty gap** between segments | No | — | Only when **all three** hold: (1) the schedule marks a release between the two segments, with the next segment's start as the return time; (2) Provly showed and logged the release at clock-out ("You're off duty until 3:00 PM"); (3) the actual gap is at least drive time + 30 min. The trip after an off-duty gap is treated as a commute. A supervisor can issue a release in the app on the spot (e.g., a Person cancels); it counts from the moment it is given. Source: 29 CFR 785.16. |
| **Documentation** | Yes, actual time | Rate of the visit it belongs to | Timed from opening the note after clock-out to submitting it; stops after inactivity; staff may correct with a reason. **15 minutes is the expectation**; time over 15 minutes is flagged for review, never unpaid. |
| **Indirect services** (SOW 31.2(2)) | Yes, and billable | Rate of that Person's code | Must be documented in writing. |
| **Training and meetings** | Yes | Staff member's current SLN rate | Required by Hope Haven. Clocked on the time clock; usually scheduled in advance as a work block. |
| **Overrun** past scheduled end | Yes, always | Rate of that segment | Flags for supervisor approval; repeated unapproved overruns are a performance issue, never a pay deduction. |

- **Pay is calculated to the minute. Billing is in 15-minute units of time actually delivered.** Rounding must never systematically favor Hope Haven.
- **Approval is a flag, never a condition of pay.** Every minute actually worked is paid.

---

## 5. Overtime, pay schedule and recovery

- Overtime applies to paid hours over **40 in a workweek** (Sunday–Saturday). Never averaged across a pay period.
- If all hours in the week are at one rate: overtime = 1.5 × that rate.
- If hours are at more than one rate — including work under another pay policy (e.g., DSG) — federal law requires the **weighted-average regular rate** across all pay in the workweek.

```
straight_time = Σ (hours × rate) for every pay job in the workweek
regular_rate  = straight_time ÷ total paid hours
ot_premium    = 0.5 × regular_rate × (total paid hours − 40)
gross         = straight_time + ot_premium
```

- **Provly calculates, payroll pays.** Provly computes straight time per pay job, the overtime premium and the weekly minimum-wage check, and exports the amounts. The payroll system pays them without recalculating. (The v1 "Gusto highest-rate job" entry rule is retired.)
- **Pay schedule** is a company setting (weekly, biweekly or semimonthly). Weekly and biweekly periods start on a Sunday. On a semimonthly schedule, a workweek that spans two pay periods is paid straight-time by date, with overtime paid in the period where the workweek ends (29 CFR 778.106).
- **Recovering an overpayment** by deduction from wages requires the staff member's signed written authorization (Utah Code 34-28-3(6)(b)).

---

## 6. Mileage

- Reimbursed at the **IRS standard mileage rate** in effect on the date driven: **72.5¢** from Jan 1, 2026; **76¢** from Jul 1, 2026. The rate table carries effective dates.
- Covers driving between back-to-back Persons (gaps that are not off duty) and transporting a Person. Commute miles and trips after an off-duty gap are not reimbursed.
- **Between visits:** Provly builds the trip from the EVV clock-out point to the next clock-in point and estimates the miles; staff confirm or correct with a reason.
- **During a visit (Person in the car):** staff tap **Start transport** and **End transport**; each tap records one GPS point and the time (no continuous tracking). Provly estimates the miles; staff confirm or correct. If the taps were missed, staff enter the miles with a reason.
- **Staff confirmation is required** — it is the employee's substantiation for a non-taxable reimbursement. Unconfirmed trips move to the next pay run; wages are never held.
- Paid as a **non-taxable reimbursement**, separate from wages.

---

## 7. Billing constraints the schedule must respect

These limit what can be **billed**. Staff are still paid for time actually worked.

| Rule | Source |
|---|---|
| No billing SL at the same time as another service (e.g., day program, school-funded services), except BC, PM1/PM2, PBA, PN1/PN2 | SOW General Limitations |
| No billing time when the Person is asleep | SOW 31.4(6) |
| Max 4 hours of SL in a 24-hour period that includes overnight respite (documented need required) | SOW 31.4(3) |
| Max 40 hours CMP/CMS per Sunday–Saturday week | SOW 31.4(4) |
| SL is one-on-one: only one staff member bills a Person at any moment. Handoff overlap is paid but not billable. 2:1 staffing only if authorized on the DSPD Worksheet. | SOW Art. 31/32 |
| All staff serving a Person draw from the same authorized units — combined scheduled hours must not exceed the authorization | PCSP / 1056 budget |

---

## 8. Payroll system setup (replaces the v1 Gusto setup)

1. Rates live in Provly (per staff, per pay job, with effective dates). The payroll system receives **amounts**, not rates to multiply.
2. In Provly's export setup, map each Provly earning type to the payroll system's earning code: SLN pay, SLH pay, training/meeting pay, overtime premium, and mileage (to a **non-taxable reimbursement** code).
3. Record each staff member's employee ID in that payroll system.
4. Each pay run: staff confirm trips → the Compliance Director clears flags and holds → the owner approves and exports → upload the file → **Mark exported** in Provly.
5. Corrections after export are adjustment lines in the next run, tied to their original workweek.

---

## 9. Provly implementation spec

### 9.1 Data Provly needs
| Entity | Key fields | Status |
|---|---|---|
| Staff | id, name, hire date | Exists |
| Payroll ID | staff, export setup, employee ID in that payroll system | **New** (replaces "Gusto employee identifier") |
| Person | id, name, DSPD PID | Exists |
| Authorization | person, service code, authorized units, period | Exists (authorizations redesign) |
| Shift | staff, person, service code, date, start, end, status, cancellation reason (`no_fault` / `staff`) | **Done (v20.0.34):** cancellation reason. Non-service work is scheduled as work blocks instead of shift types (Decision 17) |
| Work block | staff, work type (training / meeting / admin), date, start, end, status, cancellation reason | **Done (v20.0.34)** |
| Time punch | staff, work type, client + code (service/indirect), in/out times (server), optional GPS each end, linked shift or work block | **Done (v20.0.32, v20.0.34)** |
| Schedule release | staff, date, segment before, segment after (return time) | **New** (Decision 9) |
| Release notice | staff, release, shown at, acknowledged | **New** (Decision 9) |
| EVV session | staff, person, code, clock-in/out (to the minute), GPS, linked shift | Exists |
| Service note | session/shift, opened_at, submitted_at | Exists — `submitted_at` for notes-on-time; documentation segment timed from open to submit |
| Documentation segment | staff, note, start, end, source (timer / corrected), correction reason | **New** (Decision 11) |
| Pay rate | staff, pay job (`SLN`/`SLH`), rate, effective_from | **Gap 4** (pay assignments in the engine) |
| Tier review | staff, month, counted Persons, avg weekly billable, 3 qualifier results, tier supported, tier applied, grace flag, effective month | **Gap 5** (R2) |
| Trip | staff, date, from point/time, to point/time, kind (`between_visits` / `transport`), classification, estimated miles, confirmed miles, miles source, correction reason, confirmed_at | **Gaps 11–12** (replaces v1 "Mileage entry") |
| Overrun approval | EVV session, minutes over, approved_by, reason | **Gap 3** |

`shift_type` values: `service` | `travel` | `documentation` | `indirect` | `training` | `meeting`.
Person + code **required** for `service` and `indirect`; optional for the rest.

### 9.2 Calculations
```
workweek_start(date)        = most recent Sunday on or before date
paid_minutes(service)       = EVV clock_out − clock_in   (to the minute)
paid_minutes(documentation) = timer end − timer start    (actual; corrected with reason)
paid_minutes(gap)           = next clock_in − clock_out, unless off_duty(gap)
off_duty(gap)               = schedule_release AND release_notice_logged
                              AND gap ≥ drive_time + 30 min
rate(staff, job, date)      = pay rate where effective_from ≤ date, latest wins
gap / travel pay job        = pay job of the next service segment
training/meeting pay job    = SLN

weekly: hours_by_job, straight_time, overtime per Section 5 (all pay policies combined)
mileage = Σ confirmed miles (between_visits not off duty, transport) × IRS rate on trip date
monthly tier review per Section 3 (R2):
    counted_persons      = Persons where staff share ≥ 0.25
    avg_weekly_billable  = billable_hours ÷ (days_in_month ÷ 7)
    tier_supported       = max(tier_by_persons, tier_by_hours)
    qualifiers           = billable_share ≥ 0.80
                           AND every counted Person delivery ≥ 0.90
                           AND notes_on_time ≥ 0.95
    tier_applied         = apply grace / up / down rules (3.6)
```

### 9.3 Outputs
**Pay run lines (Gap 2)** — one line per staff × pay job × earning type per pay run, each tied to its workweek:
`staff, pay_job, earning_type, workweek_start, hours, amount`
Earning types: `sln_pay`, `slh_pay`, `training_meeting_pay`, `overtime_premium`, `mileage_reimbursement`, `prior_week_adjustment`.
No Person names, visits or trip addresses appear in pay run lines or the export. The export file is produced from these lines through the company's export setup (pay-engine Decision 7).

**Monthly tier report** (R2) — one row per staff:
`counted_persons, avg_weekly_billable, billable_share, min_delivery_pct, notes_on_time_pct, tier_supported, tier_applied, grace_flag, new_rates_effective`.

### 9.4 Flags and validations
| Flag | Trigger | When |
|---|---|---|
| **Billed exceeds paid** (hold) | Billed service hours > paid service hours, any staff, any workweek | Before pay run approval |
| **Overlapping billing** | Two staff billing the same Person at the same time | Scheduling + billing |
| **Authorization exceeded** | Combined scheduled hours for a Person > authorized units | Scheduling |
| **Overlap with another service** | SL scheduled during the Person's day program/school/other non-exempt service | Scheduling |
| **Over cap** | 7th counted SL Person assigned to one staff member | Scheduling |
| **Overrun** | EVV clock-out after scheduled end | Clock-out → supervisor queue |
| **Overtime approaching** | Staff projected over 40 paid hours in the workweek | Scheduling |
| **Long gap, no release** | Gap > drive time + 30 min with no release (paid) | Pay run review |
| **Documentation over 15 min** | Documentation segment > 15 min (paid) | Pay run review |
| **Trip over estimate** | Confirmed miles > 25% over the estimate | Pay run review |
| **Mileage with no adjacent EVV sessions** | Trip not bracketed by EVV points or transport taps | Pay run review |
| **Unconfirmed trips** | Trip not confirmed by cutoff (moves to next run) | Pay run cutoff |
| **Qualifier miss** | Any qualifier below threshold | Monthly review (R2) |

---

## 10. Worked examples

**A — Single rate, under 40 (Rao + John pattern).** One staff member: John 6:00 AM–12:00 PM and Rao 2:00–6:00 PM. The schedule marks a release between the two visits, Provly logged the release at the 12:00 PM clock-out, and the 2-hour gap is longer than the drive time + 30 minutes — so the gap is off duty. 16 billable hours this week across 2 Persons, all SLN, Base tier → 16 × $18 = **$288.00**. The off-duty gap and the trip after it are unpaid. Without the release on the schedule, the 2-hour gap would be paid at Rao's SLN rate and flagged.

**B — Mixed rates with overtime.** Tier 1 staff member, one workweek: 30 SLH hours at $22 and 15 SLN hours at $19 (45 total).
- Straight time = 30 × 22 + 15 × 19 = **$945.00**
- Regular rate = 945 ÷ 45 = **$21.00**
- OT premium = 0.5 × 21.00 × 5 = **$52.50** → gross **$997.50**
- Export lines: SLH pay $660.00, SLN pay $285.00, overtime premium $52.50. The payroll system pays these amounts as sent.

**C — Shared Persons and the 25% rule.** One staff member in a 30-day month:

| Person | Person's scheduled SL hrs/wk (all staff) | This staff delivers/wk | Share | Counted? |
|---|---|---|---|---|
| P1 (SLH) | 40 | 20 | 50% | Yes |
| P2 (SLN) | 12 | 2 | 16.7% | No |
| P3 (SLN) | 6 | 6 | 100% | Yes |
| P4 (SLN) | 8 | 8 | 100% | Yes |

Persons path: 3 counted → Tier 1. Hours path: 20 + 2 + 6 + 8 = 36 hrs/wk → Tier 2. **Tier supported = Tier 2**, applied only if all three qualifiers pass.

---

## 11. Test cases

| # | Input | Expected |
|---|---|---|
| T1 | 38 SLN hrs at $19 in one workweek | No overtime; gross $722.00 |
| T2 | 44 SLN hrs at $19 | Regular rate $19.00; OT premium $38.00; gross $874.00 |
| T3 | 30 SLH at $22 + 15 SLN at $19 | Regular rate $21.00; premium $52.50; gross $997.50; export lines SLH $660.00, SLN $285.00, OT premium $52.50 |
| T4 | Staff delivers 3 of a Person's 12 scheduled hrs | Share 25.0% → counted |
| T5 | Staff delivers 2.9 of 12 | Share 24.2% → not counted (hours still count toward hours path) |
| T6 | 30-day month, 141 billable hrs, 2 counted Persons | Avg 32.90 hrs/wk → Tier 2 by hours |
| T7 | 30-day month, 105 billable hrs, 4 counted Persons | Avg 24.50 hrs/wk → Tier 1 by Persons |
| T8 | 31-day month, 100 billable hrs, 2 counted Persons | Avg 22.58 hrs/wk → Base |
| T9 | Billable 128, travel 12, documentation 8, training 4 | Billable share 128 ÷ 148 = 86.5% → passes (training excluded) |
| T10 | Qualifies for Tier 2 in Sept, all qualifiers pass | Tier 2 rates effective Oct 1 |
| T11 | Billable share 76% in Sept (other qualifiers pass) | Oct: rate unchanged, grace flag. If Oct also fails → rate drops Nov 1 |
| T12 | Person cancels a 4-hr shift (no-fault) | Excluded from scheduled hours; delivery % unaffected |
| T13 | Staff no-show on a 4-hr shift | Stays in scheduled hours; delivery % drops |
| T14 | Assign 7th counted SL Person to a staff member | Blocked or flagged at scheduling |
| T15 | Two staff EVV-clocked to the same Person, overlapping 15 min | Overlap flag; only one may bill the overlap; both paid |
| T16 | Staff billed 30 service hrs, paid 28 service hrs in a workweek | Billed-exceeds-paid hold; pay run approval blocked until resolved |
| T17 | EVV clock-out 25 min past scheduled end | Overrun flag; 25 min paid at segment rate; supervisor queue |
| T18 | Base staff; release on schedule, notice logged; 2-hr gap; drive time 20 min | Off duty: gap and trip after it unpaid; no mileage |
| T19 | Same 2-hr gap, no release on schedule; next Person SLN | 2 hrs paid at $18 = $36.00; mileage reimbursed; long-gap-no-release flag |
| T20 | Release on schedule, notice logged; 40-min gap; drive time 20 min (< 50) | Not off duty: 40 min paid at $18 = $12.00; mileage reimbursed |
| T21 | Base staff; documentation timer 9 min after an SLN visit | $2.70; no flag |
| T22 | Documentation timer 25 min after an SLN visit | $7.50 paid; documentation-over-15 flag; no approval needed for pay |
| T23 | Between-visits trip on Oct 13, 2026; estimate 6.0 mi; staff confirms 6.0 | $4.56 (6.0 × $0.76) |
| T24 | Same trip; staff corrects to 8.0 mi with a reason (> 7.5) | $6.08; trip-over-estimate flag (reviewer note required) |
| T25 | Trip on Jun 15, 2026; 6.0 mi confirmed | $4.35 (6.0 × $0.725) |
| T26 | Trip not confirmed by the pay-run cutoff | Reimbursement moves to the next run; wages unaffected |
| T27 | Transport during a visit; Start/End taps; estimate 5.0 mi confirmed (Oct 2026) | $3.80 |
| T28 | Transport taps missed; staff types 4.0 mi with a reason (Oct 2026) | $3.04; miles source = staff-entered |
| T29 | Semimonthly, period ends Thu Oct 15. Base staff, week of Oct 11: Sun–Thu 34 SLN hrs, Fri–Sat 10 SLN hrs | Period 1: $612.00. Period 2: $180.00 + OT premium $36.00 (0.5 × $18 × 4) |

---

## 12. Not in v1.1 (planned)
- **Career-ladder steps** (DSP I → DSP II → Lead DSP → Program Lead) layered on top of these rates.
- **Nursing:** covered by `docs/pay-policy-nursing-v1.1.md`.
- **BC1–BC3:** per-billable-unit structure.
- **CMP/CMS** family-caregiver pay.
- **DSG/DSP:** pay policy next (census premium); until then DSG staff are paid a plain hourly rate by code.
