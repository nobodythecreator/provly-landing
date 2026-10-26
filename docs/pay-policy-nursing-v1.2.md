# Hope Haven — Nursing Pay Policy v1.1 (LOCKED)
### Policy + Provly payroll specification

| | |
|---|---|
| **Status** | LOCKED — v1.2, October 26, 2026 (supersedes v1.1) |
| **Effective** | October 12, 2026 |
| **Owner** | Tombé (CEO), Hope Haven Services Inc. |
| **Applies to** | RN, LPN, Lead RN, Director of Nursing; PN1 caregivers (DSPs and HHS hosts) |
| **Codes** | PM2, PN2 (daily + session), PN1 — all awarded. PM1 not awarded; not offered. |
| **Companion doc** | `docs/pay-policy-sl-v1.md` (Supported Living) — same EVV and workweek conventions |
| **Suggested repo path** | `docs/pay-policy-nursing-v1.1.md` (v1 stays in the repo as the record of the prior version) |

> **For the Provly build chat:** this file is the source of truth for nursing pay. Sections 1–9 are
> the policy; Section 10 is the implementation spec (continues the gap numbering from the SL policy
> and the pay-and-mileage handoff); Sections 11–12 are worked examples and test cases with exact
> expected answers.
> **This file contains no SQL. Nothing in it is run in Supabase.**

---

## Changes from v1

| # | Change | Section |
|---|---|---|
| 1 | Pay for non-billable nursing work: RN $30.00/hour for orientation, required training, staff meetings, assigned admin/setup work, and initial PN1 caregiver training | §3.1 |
| 2 | Defines when a menu unit is payable: billable under the billing rules, paid with its date of service, reversed if not uploaded or later denied | §3.2 |
| 3 | Nursing mileage decided: same rule as SL | §9 |
| 4 | Reversals require a signed deduction authorization and never take back the minimum-wage floor | §9 |
| 5 | Provly calculates overtime and minimum wage and exports the amounts to whichever payroll system is used; split-week rule for semimonthly schedules | §9 |
| 6 | Written pay agreement before the first pay period | §9 |
| 7 | New data, calculations and flags | §10 |
| 8 | New worked example D; new test cases N20–N26; N17 clarified | §11–12 |
| 9 | v1.2: non-billable work is clocked on the time clock; "assigned in advance" means a matching work block on the schedule; hours come from the server clock | §3.1, §9 |

---

## 1. Revenue reference (DHHS91172, effective 7/1/2026)

| Code | Rate | Billing rules that affect pay |
|---|---|---|
| PM2 | $12.22 / quarter hour ($48.88/hr) | RN only. No residential-provider requirement. |
| PN2 daily | $119.49 / Person / day | RN, or LPN under RN delegation and supervision (SOW 19.5(b)). Max 3 days/week per Person unless the Medical Care Plan documents why tasks can't be delegated to PN1 (SOW 19.4(2)). Initial Medical Care Plan approved by DSPD nurse (SOW 19.2(7)). |
| PN2 session | $29.87 / session | Only on days the daily rate is not billed, only for RN telehealth coordination of delegated care; a day's sessions may not exceed the daily rate → **max 4 sessions per Person per day** (SOW 19.7). Daily + session never on the same day (SOW 19.4(3)). |
| PN1 | $42.35 / Person / day | Only when Hope Haven is the residential provider (RHS, HHS, PPS, SLH), under Hope Haven's own PN2 RN, and only after the caregiver is trained by that RN (SOW 18.2, 18.4, 18.5). |

---

## 2. Roles

| Role | Bills | Pay type |
|---|---|---|
| **Staff RN** | PM2, PN2 visits, PN2 sessions, PN1 oversight | Hourly — menu + non-billable rate (building stage) → salary + quarterly bonus |
| **LPN** | PN2 visits under RN supervision only | Hourly, paid per visit (+ non-billable rate, set at the first LPN hire) |
| **Lead RN** | Staff RN work + supervising LPN PN2 visits | Staff RN pay + supervision fee |
| **Director of Nursing** | Runs the division | Salary + quarterly division bonus |
| **PN1 caregiver** | Performs delegated PN1 tasks (HHS host or DSP) | Daily add-on to their existing pay |

LPNs may not: bill PM1 (not awarded), bill PN2 sessions (RN only), or delegate to PN1 staff (SOW 19.4(4)).

---

## 3. The RN pay menu (building stage)

| Work | Pay | Earned when |
|---|---|---|
| **PM2** | **$42.00 per billable hour** (pro-rated per quarter hour = $10.50) | Unit payable under §3.2. Travel time is built into the rate. |
| **PN2 visit** | **$65.00 per visit** | PN2 daily rate payable under §3.2 for that Person/day with a daily note. Includes drive and documentation. |
| **PN2 telehealth session** | **$18.00 per session** | Session payable under §3.2 (non-visit day), situation and outcome documented (SOW 19.2(9)). |
| **PN1 oversight** | **$150.00 per delegated Person per month** | ≥1 PN1 day billed that month for the Person **and** caregiver training on file **and** the RN's monthly meeting with the caregiver and monthly report review documented (SOW 19.2(7)(D)–(E)). |
| **Non-billable nursing work** | **$30.00 per hour** | Hours recorded as a training, meeting or admin shift (§3.1). |

During the building stage the RN is a non-exempt hourly employee: **record every hour worked** in Provly.
Menu pay and non-billable pay are the compensation. Menu rates include drive time and documentation for
billable work; non-billable work is paid separately under §3.1. Recorded hours are used to confirm minimum
wage and overtime compliance each workweek (Sunday–Saturday).

### 3.1 Non-billable nursing work (added in v1.1)

- **Covered:** orientation; required trainings; staff meetings; admin or setup work assigned by the owner
  (or the Director of Nursing once in place), such as writing nursing procedures or building Medical Care
  Plan templates; and **initial training of PN1 caregivers**, which is required before PN1 can bill and is
  not covered by the PN1 oversight stipend.
- **Not covered (built into the menu):** drive time and documentation for billable PM2, PN2 visits and
  sessions; the monthly PN1 caregiver meeting and report review (covered by the $150 stipend).
- **Rate:** RN **$30.00/hour**. The LPN rate is set when the first LPN is hired.
- **Recording:** on the time clock as training, meeting or admin (hours on the server clock).
- **Approval:** assigned in advance — a matching work block on the schedule — or approved. Unapproved time is **still paid** — all hours worked are
  paid — and is flagged for review.
- **Excluded** from the salary-conversion test (§5) and the quarterly true-up (§6), which measure the
  billable caseload.
- **Ends at salary conversion:** an exempt salary covers all hours.
- **Startup period:** the founding RN's setup work for the nursing division is paid under this section.

### 3.2 When a menu unit is payable (added in v1.1)

A unit is payable when it is **billable under Provly's billing rules**: approved note, EVV where the code
requires it, a current authorization with units remaining, and no billing-conflict flags. It is paid with
the pay period containing its **date of service**. A note approved after the payroll cutoff is paid in the
next run as a prior-week adjustment, still counted in its own workweek for overtime and minimum wage. If
the unit is not in the uploaded billing file, or is later denied or recouped, it is reversed under §9.

---

## 4. Other roles

| Role | Pay |
|---|---|
| **LPN** | **$45.00 per PN2 visit.** Hourly non-exempt; all hours recorded. Non-billable LPN rate set at the first LPN hire (§3.1). |
| **Lead RN** | Existing RN pay (menu or salary + bonus) **+ $10.00 per LPN PN2 visit supervised.** Effective when the first LPN is hired. |
| **PN1 caregiver** | **$10.00 per PN1 day** billed and documented, only after RN training on the tasks and the Medical Care Plan. For HHS hosts this is paid under the PN1 Rider to the Host Home Provider Agreement. |

---

## 5. Salary conversion (Staff RN)

Convert the RN from the menu to salary when **both** are true:
1. Menu pay averages **≥ $3,300/month over 3 consecutive months**, and
2. **≥ 3 of the RN's Persons are PN2 or PN1** at the time of conversion.

Menu pay in this section means the §3 menu items only; non-billable pay (§3.1) is excluded.

```
salary_monthly = average monthly menu pay over the 3 qualifying months
salary_weekly  = salary_monthly × 12 ÷ 52      (must be ≥ $684/week for exempt salary basis)
```

## 6. Salaried RN — quarterly true-up

- Salary is paid every pay period regardless of volume (the floor).
- Each calendar quarter, calculate **menu pay** for the quarter exactly as in Section 3 (menu items only;
  §3.1 excluded).
- **Quarterly bonus = max(0, menu pay for the quarter − salary paid for the quarter).**
- Salary changes **only at the annual review**, re-based on trailing earnings. Never adjusted month to month for volume (protects exempt salary basis).
- Claim denials for a salaried RN reduce the **quarterly menu calculation only**, never the salary.

## 7. Director of Nursing

- **Trigger:** the division reaches **3 nurses** (any mix of RN/LPN, including the Director).
- **Salary at promotion:** trailing 12-month total earnings × 1.10.
- **Quarterly division bonus:** **5% of nursing division margin**, paid only if **all four** standards are met for the quarter:

| Standard | Target | Source |
|---|---|---|
| Monthly PN2 summaries submitted by the 10th | ≥ 95% | SOW 19.2(10) |
| Medical Care Plans updated within 3 business days of a substantial medical change | 100% | SOW 19.2(8)(A) |
| Medication errors documented + Support Coordinator notified in writing within 1 business day | 100% | SOW 17.2(7) |
| Nursing findings in DSPD or OSR reviews | None | — |

```
division_margin = nursing revenue (PM2 + PN2 daily + PN2 sessions + PN1)
                − all nursing staff pay (wages incl. non-billable pay, fees, salaries; excluding this bonus)
                − employer payroll taxes on that pay
                − PN1 caregiver add-ons
                − nursing mileage reimbursements
```

## 8. Capacity and hiring (points)

Points measure workload; they set capacity and hiring triggers. **Pay comes from the menu, not points.**

| Person on caseload | Points | Earned for the month only when… |
|---|---|---|
| PM2 | 1 | PM2 authorized to Hope Haven; required face-to-face assessment done and written; ≥ 90% of scheduled PM2 time delivered |
| PN2 | 1.5 × actual weekly visits | Medical Care Plan on file (initial DSPD-nurse approved); visits billed with notes; monthly summary submitted by the 10th |
| PN1 | 0.5 | ≥1 PN1 day billed; caregiver training on file; monthly meeting + report review documented |

```
actual_weekly_visits = PN2 days billed in month ÷ (days in month ÷ 7)
```
- **Full-time capacity ≈ 28 points per RN.** Past 28 → hire the next nurse.
- **No billing, no points. No billing, no pay.** Points and menu pay never exceed billed, documented work.
- **Capacity reserve:** keep about one-third of the RN's capacity available for PN2 until PN2 is on the caseload.

## 9. Common rules

- **Reversals (clawback):** if DSPD denies or recoups a claim, or a paid unit is not in the uploaded billing
  file, the matching pay item is reversed — deducted from the next payment (hourly/menu stage) or from the
  quarterly menu calculation (salaried). Two limits apply:
  1. A deduction from wages requires the nurse's **signed written deduction authorization** (Utah Code
     34-28-3(6)(b)). Without one on file, nothing is deducted and the reversal is flagged.
  2. The original workweek is recalculated without the unit, and a reversal **never takes back the
     minimum-wage floor** for that week's hours worked.
- **Calculated, not claimed:** all pay items are computed from Provly records. Manual adjustments require the Compliance Director's approval and a written reason.
- **Monthly spot check:** Compliance Director samples 2 Persons per nurse against records before pay is final.
- **Workweek and overtime:** Sunday–Saturday. For non-exempt staff, overtime uses the weighted-average
  regular rate across **all** pay in the workweek (hourly, menu, non-billable, add-ons). Provly calculates
  overtime and the weekly minimum-wage check and exports the resulting amounts; the payroll system pays them
  without recalculating. On a semimonthly schedule, a workweek that spans two pay periods is paid
  straight-time by date, with overtime and any minimum-wage make-up paid in the period where the week ends.
- **Mileage (decided October 2026):** same as SL — miles × the IRS standard rate in effect on the trip date,
  for trips between back-to-back Persons and when transporting a Person. Commute (home → first Person,
  last Person → home) and trips after an off-duty gap are never reimbursed. Paid as a non-taxable
  reimbursement, separate from wages. Travel time stays built into the PM2/PN2 rates and is recorded as
  hours worked.
- **Written pay agreement:** before the first pay period, each nurse signs a pay agreement stating the menu
  and non-billable rates, that menu rates include drive time and documentation for billable work, the
  mileage rule, and the written deduction authorization for reversals.

---

## 10. Provly implementation spec (continues SL gaps 1–5)

### 10.1 Data needed
| Data | Purpose | Status |
|---|---|---|
| Pay items per staff: `pm2_billable_hour`, `pn2_visit`, `pn2_session`, `pn1_oversight_person_month`, `pn1_caregiver_day`, `lpn_pn2_visit`, `lead_supervised_visit`, `nonbillable_hour` — each with amount + effective date | Menu pay, non-billable pay | **Gap 6:** extend the SL pay-rate model (Gap 4) to per-unit pay items |
| Nurse shift types training / meeting / admin, with an approved-in-advance marker | Non-billable pay, approval flag | **Gap 1** |
| Deduction authorization per staff: signed date | Reversal gate | **New in v1.1** |
| PN2 visit record: Person, date, performing nurse, nurse license type (RN/LPN), supervising RN | Visit fees, Lead RN fee, LPN fee | **Gap 7** |
| PN2 session record: Person, date, RN, situation + outcome note | Session pay + 4/day cap + no-session-on-visit-day check | **Gap 7** |
| Medical Care Plan: Person, version, DSPD-nurse approval date (initial), last update, substantial-change date | Points, Director standard | **Gap 8** |
| PN1 delegation: Person, caregiver, training date by RN, monthly meeting dates, monthly report review dates | PN1 stipend, caregiver add-on eligibility | **Gap 8** |
| PN2 monthly summary: month, submitted date, recipients (SC; + DSPD nurse in year 1) | Points, Director standard | **Gap 8** |
| Medication error: discovered at, SC written notice at | Director standard | **Gap 8** |
| Salary record: staff, monthly salary, effective date, exempt flag | True-up, conversion | **Gap 9** |
| Claim status per billed unit: billed / paid / denied | Clawback | **Gap 10** (ties to the UPI e520 export arc) |

### 10.2 Calculations
```
monthly_menu_pay(rn) =
    pm2_billed_quarter_hours × 10.50
  + pn2_visits_billed × 65.00
  + pn2_sessions_billed × 18.00
  + count(pn1_persons_qualifying) × 150.00
  + lead_supervised_lpn_visits × 10.00            # if Lead RN
  − clawbacks
  # menu items only — non-billable pay is never included

nonbillable_pay(rn, week) = nonbillable_hours(week) × nonbillable_rate(date)

weekly_pay(staff, week)   = menu pay for units with service dates in the week
                          + nonbillable_pay + add-ons + any hourly pay
min_wage_makeup(week)     = max(0, hours_worked(week) × min_wage(date) − weekly_pay(week))   # $7.25 in Utah
regular_rate(week)        = (weekly_pay + min_wage_makeup) ÷ hours_worked(week)
ot_premium(week)          = 0.5 × regular_rate(week) × max(0, hours_worked(week) − 40)

reversal(unit) = max(0, paid_for_week − recompute_week_without(unit))
  # the recompute applies the minimum-wage floor and overtime again, so the floor is never taken back;
  # deducted only if a deduction authorization is on file

conversion_check(rn): last 3 months avg(monthly_menu_pay) ≥ 3300 AND pn_persons ≥ 3
quarterly_bonus(rn, salaried) = max(0, Σ monthly_menu_pay(quarter) − Σ salary_paid(quarter))
director_bonus(quarter) = 0.05 × division_margin(quarter)  if all 4 standards met else 0
```

### 10.3 Flags
| Flag | Trigger |
|---|---|
| PN2 over 3 days/week | > 3 PN2 days in a workweek for a Person without documented justification |
| Session conflict | PN2 session and daily rate billed same Person/day |
| Session cap | > 4 sessions for one Person in one day |
| PN1 not eligible | PN1 day where Hope Haven isn't the residential provider, no RN training on file, or no PN2 oversight that week |
| LPN delegation | LPN recorded as delegating to PN1 staff |
| Summary late | PN2 monthly summary not submitted by the 10th |
| MCP overdue | Substantial medical change with no MCP update in 3 business days |
| Capacity | RN caseload > 28 points |
| Unapproved non-billable time | Training/meeting/admin shift with no advance assignment or approval (still paid) |
| Minimum-wage make-up | Make-up pay added for a workweek |
| Reversal without authorization | Reversal due with no deduction authorization on file — not deducted |
| Reversal capped | Reversal reduced so the original week stays at the minimum-wage floor |

---

## 11. Worked examples

**A — Building stage (Jacob + Tony, PM2 only).** Jacob authorized 8 hrs/month, Tony 4. 12 billable hours × $42 = **$504** for the month. Revenue $586.56. Points: 1 + 1 = 2.

**B — "Built" RN caseload.** 12 PM2 (4 hrs each), 6 PN2 (1 visit/week), 6 PN1. RN menu pay ≈ **$4,606/month** (~$42.65 per hour worked); Hope Haven revenue ≈ $13,183; margin ≈ $6,656 (50%). Points: 24.

**C — Salary conversion.** Menu pay $3,250, $3,400, $3,500 in three consecutive months (avg $3,383.33) with 3 PN Persons → convert. Salary $3,383.33/month = $40,600/year = $780.77/week (≥ $684 ✓).

**D — Onboarding / startup week (v1.1).** A new RN's first week: 20 hours of assigned orientation and setup work, no billable units. Pay 20 × $30 = **$600**, not counted toward the conversion test. Without the v1.1 rate, the same week would have paid only the minimum-wage floor, $145.

---

## 12. Test cases

| # | Input | Expected |
|---|---|---|
| N1 | RN bills 48 PM2 quarter hours (12 hrs) in a month | $504.00 |
| N2 | 4 PN2 visits billed in a 30-day month for one Person | Pay $260.00; avg weekly visits 0.9333; points 1.40 |
| N3 | 2 PN2 sessions on a non-visit day | $36.00 |
| N4 | PN2 session on a day the daily rate is billed | Session conflict flag; session not billable; $0 |
| N5 | 5 sessions for one Person in one day | Cap flag; only 4 billable/payable |
| N6 | PN1 billed 30 days; training on file; meeting + report documented | Caregiver $300.00; RN $150.00 |
| N7 | Same as N6 but monthly meeting not documented | RN stipend $0 for that Person; compliance flag |
| N8 | PN1 day for a Person whose residential provider is another company | PN1 not eligible flag; $0 |
| N9 | Menu $3,250 / $3,400 / $3,500, 3 PN Persons | Convert; salary $3,383.33/mo ($780.77/wk) |
| N10 | Menu avg $3,400 but only 2 PN Persons | Do not convert |
| N11 | Salaried RN: quarter salary $9,900, quarter menu $11,400 | Bonus $1,500.00 |
| N12 | Salaried RN: quarter salary $9,900, quarter menu $9,500 | Bonus $0; salary unchanged |
| N13 | Lead RN supervises 20 LPN PN2 visits | +$200.00; LPN earns $900.00 |
| N14 | LPN visit margin check | $119.49 − 49.50 − 11.00 = $58.99 (49%) |
| N15 | Director: quarterly division margin $60,000, all 4 standards met | Bonus $3,000.00 |
| N16 | Director: same, one summary submitted on the 12th → 94% | Bonus $0 |
| N17 | Hourly RN: PN2 visit later denied (deduction authorization on file; week well above the floor) | −$65.00 on next payment |
| N18 | Salaried RN: PN2 visit later denied | −$65.00 from quarterly menu calc; salary unchanged |
| N19 | Caseload 12 PM2 + 6 PN2 (1/wk) + 6 PN1 | 24 points (under 28 capacity) |
| N20 | RN records 8 hours of assigned orientation, no billable units | $240.00 |
| N21 | Same as N20, not assigned or approved in advance | $240.00 paid; unapproved non-billable flag |
| N22 | Menu $3,250 / $3,400 / $3,500 plus $300/month non-billable pay; 3 PN Persons | Convert; salary $3,383.33/mo (non-billable excluded) |
| N23 | RN works 6 hours on PM2 segments in a week; the authorization had lapsed, 0 units billable | Menu $0; minimum-wage make-up $43.50 |
| N24 | Week: 6 hours worked, 6 PM2 quarter hours billed ($63.00); 4 quarter hours later denied | Recomputed week $21.00 < floor $43.50 → reversal $19.50 (not $42.00) |
| N25 | Reversal of $65.00 due; no deduction authorization on file | Nothing deducted; reversal-without-authorization flag |
| N26 | Semimonthly, period ends Thursday. Sun–Thu: 6 hours worked, 4 PM2 quarter hours billed ($42.00). Fri–Sat: 4 hours assigned orientation ($120.00) | $42.00 in period 1; $120.00 in period 2; week check $162.00 ÷ 10 hrs = $16.20 ≥ floor → no make-up |
