# Provly money layer — from ledger to bank

*Started November 2026. Revisit at every major version (1.5, 2.0) and whenever a trigger below is hit.*

## The ambition

Provly should one day be a bank: the bank for care providers and the people they support. Holding the money
alongside the care record would make Provly a company the industry cannot ignore. No I/DD software company we
know of has a real money layer.

## Why it matters

The people Provly's customers serve live lives "in motion": day programs, work, shopping, time with friends.
Their money has to be usable, safe and documented every day. Today a representative payee has bad options:
cash runs, a personal credit card paid off afterward, or a house manager holding cards. Each is a risk and a
bookkeeping burden. The organizations with this problem go well beyond DSPD: foster care, juvenile justice,
aging, behavioral health, and organizational payees nationally.

## Where we stand (November 2026)

Posture: **ledger and controls only.** Provly never holds or moves a dollar. Banks and card partners do. Provly
is the record, the controls and the audit trail on top of whatever banks the money is already in.

- **Ledger:** every dollar per person (in, out, why, who, receipt), matched to the bank every month (Form B).
- **Controls:** who may spend and how much, second-person review (Form D), asset-limit alerts, sealed months,
  void-never-delete.
- **Audit trail:** every action, who and when, provable to SSA, DSPD and auditors.

## The path (each step only after the one before it is proven)

| Step | What | Who holds the money | Weight |
|---|---|---|---|
| 1. Ledger of record | Built (PBA R1–R2). Next: annual SSA-6234 report; "open an ABLE account" when the asset alert fires | Each person's bank | Software |
| 2. Read-only bank feeds | Daily transactions from any bank; reconciliation becomes daily | Each person's bank | Low |
| 3. Card partner (around 1.5) | A True Link–style payee card; purchases land on the ledger with the DSP's receipt photo and that day's note | Partner's bank | Low for Provly |
| 4. Provly-branded program | Provly accounts and cards at a sponsor bank, titled to each person, ledgered by the bank (never a pooled sub-ledger) | Sponsor bank | High: compliance officer, BSA/AML, KYC, bank oversight |
| 5. Provly bank | A charter: national bank (OCC) or a Utah industrial bank | Provly Bank | Company-sized |

The deposit base for step 5 is not only SSI balances. It is also **providers' own operating accounts and
payroll**, which flow through Provly's pay engine. "The bank for care providers" is a much larger deposit base
than client funds alone.

## What Mercury and Erebor show (as of mid-2026)

- **Mercury** launched in 2019 on FDIC-insured partner banks (Choice Financial Group, Column). It applied for
  an OCC national bank charter in December 2025 and received conditional approval in April 2026. It reported
  about $650M in annualized revenue, roughly 300,000 customers and several years of profitability, and hired a
  banking chief who had led SoFi's charter. Mercury Bank, N.A. is to be headquartered in **Utah**. The lesson:
  **partner first, charter at scale**. Mercury is that playbook working.
- **Erebor** (Palmer Luckey, Joe Lonsdale, Founders Fund) applied in June 2025. It received OCC conditional
  approval in October 2025 and FDIC deposit insurance in December 2025, and its final charter was issued in
  February 2026. It raised hundreds of millions ($350M at a $4.35B valuation in December 2025) and assembled a
  founding team with deep compliance, legal and regulatory experience before applying. Luckey's argument for
  owning the charter: not depending on someone else's banking infrastructure. The lesson: **a de novo charter
  takes serious capital and a regulatory-grade team from day one.**

## Triggers to revisit

- **Step 2:** the first outside provider runs a PBA month in Provly.
- **Step 3:** about 10 providers run PBA in Provly, or one provider asks for a card.
- **Step 4:** hundreds of PBA customers, a full-time compliance officer, and a sponsor bank willing to title
  accounts per person.
- **Step 5:** Provly is profitable, the program has proven scale, and there is capital plus a leader who has
  taken a bank through a charter before.

## Never compromise

- SSA representative-payee rules: each person's funds are titled to them, with the payee as fiduciary. No
  pooling without SSA approval.
- No commingling with any provider's operating money.
- One ledger per real account, reconciled against the bank's own records. This is the Synapse lesson.
- The people this serves are the most vulnerable depositors there are. A ledger break means someone can't
  buy groceries.
