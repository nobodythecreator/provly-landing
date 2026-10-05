# Provly — PBA Module Spec v1
### Personal Budget Assistance: the Person's money, tracked dollar by dollar

| | |
|---|---|
| **Source policy** | Hope Haven Policy PBA-001 (SOW Article 15 + SOW 1.28) |
| **Related docs** | `docs/dspd-service-code-reference-v1.md` (Part D: personal funds + emergency loans) |
| **Suggested repo path** | `docs/pba-module-spec-v1.md` |
| **Gap numbering** | Continues pay-policy and driving gaps 1–15 → PBA is **Gaps 16–24** |

> **For the Provly build chat:** PBA is the module where Provly holds a Person's financial record — the
> record DSPD, the Support Coordinator, the guardian, and auditors can inspect at any time (SOW 15.3(6)).
> SOW rules in this file are the locked layer (same for every provider). Thresholds marked
> **[tenant setting]** are company policy and editable per provider; Hope Haven's values are shown.
> **This file contains no SQL. Nothing in it is run in Supabase.**

---

## 1. The use case that defines the module

**Tony asks to buy medication for his girlfriend. It costs $63.40.**

What Provly must do, in order:

1. **Recipient check.** The expense is entered with `beneficiary = other person` (girlfriend). Provly requires:
   - the **Person's stated choice** in their own words ("Tony asked to buy cold medicine for his girlfriend"),
   - confirmation that **this month's current needs are already met** — food, shelter (room & board paid), clothing, medical care (SOW 15.2(4)),
   - **PBA Manager approval** before or at the time of purchase.
2. **Receipt rule.** $63.40 is over $50 → **receipt image required** (SOW 15.3(6)). The month cannot close until the receipt is attached or a Lost Receipt Affidavit is filed.
3. **Pattern watch.** Provly counts spending on any one non-Person recipient. At **3 transactions or $150 in a rolling 90 days** **[tenant setting]**, it flags the Compliance Director to review for possible exploitation. The flag is a review, not a block — it's Tony's money and his choice, but a repeating pattern for one person is exactly what exploitation looks like from the inside.
4. **Review trail.** The transaction appears on Tony's monthly review with him (Form C), the Administrative Reviewer's checklist (Form D), and the Support Coordinator report (Form G).

Why it matters: the SOW requires that funds be used for their intended purpose and never contrary to the Person's best interest (SOW 15.2(3), 15.4(3)). A gift is the Person's right once their needs are met — but it must be visibly *his* choice, after his needs were covered, with a receipt.

---

## 2. Gaps

### GAP 16 — PBA enrollment + eligibility gate
Per Person: fiduciary type (`ssa_payee` | `conservator` | `voluntary`) + proof document; **Natural Support Determination (Form A)** with reason each natural support/guardian isn't payee (SOW 15.4(1)). PBA ledger cannot activate until both are on file.
**Hard rule:** an HHS host or host family member for this Person can never be assigned a PBA role or payee status (SOW 11.4(1)).

### GAP 17 — Accounts
Per Person: one or more accounts (bank, last 4, titling, type `individual` | `collective`). Collective accounts track each Person's sub-balance. **No account may be linked to the provider's operating funds** (SOW 15.2(8), 15.4(5)). Pay cards record the supervising financial institution (SOW 15.3(2)).

### GAP 18 — Ledger + receipts
Transaction fields: date · type (`deposit` | `withdrawal` | `transfer` | `interest` | `fee` | `cash_out`) · amount · payee/vendor · category · **beneficiary** (`person` | `other` + name + relationship) · purchased by (staff/host/Person) · receipt image · notes.
- **Receipt required when amount > $50.00**, and when **multiple items in one purchase total > $50.00** (SOW 15.3(6)).
- Bank statement lines are imported or entered and **reconciled** to ledger entries; every expenditure links to a receipt **or** a statement line.
- Receipts are **immutable** after upload (SOW 15.4(4) — never alter a receipt). Corrections are new entries, never edits.
- **Lost Receipt Affidavit (Form F):** purchase, amount, date, store, matching statement line, reason; signed by the purchasing staff member + Compliance Director. **3 affidavits by one staff member in 90 days** → corrective-action flag **[tenant setting]**.
- **Cash log:** every cash withdrawal and every hand-off (to Person, staff, or host) with recipient and purpose.

### GAP 19 — Spending allowance for hosts/direct staff
Per Person: allowance amount + period, who may spend it. Hosts and direct staff spend **only** from the allowance, never with the Person's cards or PINs. Purchases logged with receipt/change returned within **48 hours** **[tenant setting]**; overdue → flag.

### GAP 20 — Roles + separation of duties
Per Person, three distinct assignments:

| Role | Can | Cannot |
|---|---|---|
| **PBA Manager** | Create/edit transactions, reconcile, run monthly Person review, prepare SC report | Sign the administrative review or quarterly audit for that Person |
| **Administrative Reviewer** | Read full record, complete Form D, record findings | Create, approve, or edit any transaction for that Person (SOW 15.3(7)) |
| **Quarterly Auditor** | Read full record, complete Form E | Hold either other role for that Person |

Enforced in the database, not just the UI — this sits naturally on the relationship-scoped access model (assignments drive permissions, never role alone). Provly must **refuse** to save an assignment that puts the same user in two roles for one Person.

### GAP 21 — Monthly cycle + deadlines
| Due | Step | Form | Owner |
|---|---|---|---|
| Day 5 | Reconcile ledger to statement; asset check; spend-down confirmed | B | PBA Manager |
| Day 10 | Review with the Person (virtual allowed) — deposits, expenses, savings (SOW 15.2(10)) | C | PBA Manager + Person |
| Day 15 | Administrative review (SOW 15.3(7)) | D | Administrative Reviewer |
| Day 30 | SC financial report with copies of C and D (SOW 15.3(7)–(8)); guardian copy within 30 days of a request | G | PBA Manager |

Each step locks on completion; later steps can't start until earlier ones are done. Dashboard shows red/amber/green per Person per step. **Month cannot close** with an unreceipted >$50 expense, an unreconciled line, or a missing signature.

### GAP 22 — Quarterly audit
Each quarter: random sample of **≥ 10% of Persons who received PBA that quarter, minimum 1** **[minimum is a tenant setting; 10% is SOW]**. Provly performs and **records the random draw** (seed + timestamp) so the selection is provably random. Form E captures findings; findings route to the Compliance Director within 5 business days; a copy rides along with that Person's next SC report.

### GAP 23 — Benefits + asset monitoring
- Countable-asset total recalculated on every reconciliation.
- **Alert at $1,500** **[tenant setting]** against the **$2,000 SSI individual resource limit** → written notice to the Person, residential provider team, and SC (SOW 15.2(6)), with a plan field (planned purchase / ABLE account / other).
- Track ABLE account balance separately (SSI disregards up to $100,000).
- Medicaid spend-down: amount + due date; overdue = flag (SOW 15.2(5)). Hope Haven pays late fees it caused (SOW 15.3(3)(C)).
- SSA representative-payee accounting reminder when SSA requests it.

### GAP 24 — Special transactions
- **Room & board:** amount + due date pulled from the Person's executed Room & Board Agreement. Payment differing from the agreement → **blocked** pending Compliance Director override with reason. Increases require the agreement's 30-day notice date on file.
- **Life insurance / burial plan:** requires current-needs check, no staff beneficiary (conflict check against staff list), Person named as owner (SOW 15.2(7)).
- **Emergency loans:** link to the loan record from SOW 1.28(7) (see reference doc Part D) — never entered as an ordinary transfer.
- **Restrictions on the Person's access/spending:** require Human Rights Committee + SC written approval attachments before they take effect (SOW 1.28(6)).
- **Durable goods split between Persons:** blocked by default (SOW 1.28(8)); override documents it per SOW 15.3(6).
- **Change of provider/payee:** generate a complete current accounting for the new provider/payee (SOW 15.3(9)).
- **Death:** 90-day countdown to transfer remaining funds and the full accounting to the estate's legal representative; unused SSA funds returned per SSA policy (SOW 15.3(10)).

---

## 3. Billing PBA (separate from the financial record)
PBA bills by quarter hour or session (SOW 15.6). The **financial record proves the money; billing notes prove the service.** Each billed unit uses the default T6 documentation (name, date, start/end, code, staff, activities) — e.g., "reconciled September statement, paid phone bill, reviewed savings with Tony" (SOW 15.3(11), 1.10(7)). Time spent by the Administrative Reviewer or Quarterly Auditor is internal control and **not billable**.

## 4. Exports
- **Form G — SC monthly financial report** (PDF): balances, transactions, enclosed Forms B/C/D (+E when audited), asset alert status.
- **External review package:** full financial record for any date range, for DSPD/OSR/SC/guardian (SOW 15.2(9), 15.3(6)).
- **Annual outcome data:** "financial obligations met on time" (SOW 15.5) — share of bills/spend-downs/R&B paid by due date.

## 5. Flags (consolidated)
| Flag | Trigger |
|---|---|
| Missing receipt | Expense > $50 (or multi-item purchase > $50) with no receipt and no affidavit |
| Third-party pattern | 3 transactions or $150 to one non-Person recipient in 90 days |
| Current needs not met | Savings, debt repayment, or gift entered while that month's needs are unmet |
| Role conflict | Same user in two PBA roles for one Person |
| Host as payee | PBA role or payee status assigned to the Person's host or host family member |
| R&B mismatch | Room & board payment ≠ executed agreement |
| Asset alert | Countable assets ≥ $1,500 |
| Step overdue | Any monthly-cycle step past its due day |
| Allowance overdue | Host/staff receipt or change not returned within 48 hours |
| Affidavit pattern | 3 lost-receipt affidavits by one staff member in 90 days |

## 6. Acceptance tests
| # | Input | Expected |
|---|---|---|
| P1 | $63.40 medication for Tony's girlfriend, no receipt | Saved as pending; month can't close; receipt task created |
| P2 | Same, receipt attached, choice + current-needs confirmed, PBA Manager approved | Accepted; appears on Forms C, D, G |
| P3 | Same purchase entered with current needs unmet (R&B unpaid) | Blocked: current-needs flag |
| P4 | 3rd purchase for the same girlfriend within 90 days | Third-party pattern flag to Compliance Director |
| P5 | Purchase of $48.00 | No receipt required (statement line still reconciles it) |
| P6 | Three items in one purchase: $20 + $18 + $15 = $53 | Receipt required |
| P7 | Admin Reviewer attempts to edit a transaction for a Person they review | Refused |
| P8 | Assign Ethan (Tony's host) as Tony's PBA Manager | Refused (SOW 11.4(1)) |
| P9 | R&B payment of $500 when agreement says $450 | Blocked pending override with reason |
| P10 | Countable assets reach $1,520 | Asset alert; notices to Person, residential team, SC |
| P11 | Quarter with 2 PBA Persons | Sample size 1; draw recorded |
| P12 | Day 16 with no Form D | Step-overdue flag |
