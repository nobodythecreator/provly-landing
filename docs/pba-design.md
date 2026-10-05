# Provly — PBA (Personal Budget Assistance) Design v1.2

**v1.0 decided Oct 4, 2026; v1.1 = cross-check against the spec (Oct 5) · approved by Tombé · v1.2 adds Release 2 (decided Oct 5) · requirements: `docs/pba-module-spec-v1.md` (Hope Haven Policy PBA-001, SOW Article 15 + 1.28) · this doc covers Release 1, built as v20.0.29**

## Decisions (locked one at a time, Oct 4)

| # | Decision | Choice |
|---|---|---|
| 1 | How PBA ships | **Three releases.** R1 the record (Gaps 16, 17, 18, 20) → R2 the monthly close (21, 23, Form G) → R3 the rest (19, 22, 24, external package, annual outcome) |
| 2 | Block or flag | **Block at the request, never at the record.** Planned spending goes through approval, where the spec's blocks apply. A transaction that already happened always saves, is flagged, and holds its month open until the Compliance Director resolves it with a reason |
| 3 | Receipt images | **Private Supabase Storage bucket, add-only, fingerprinted.** Files can be added, never replaced or deleted; each file's SHA-256 is stored with its record |
| 4 | Bank statement lines | **Statement file import + manual fallback** (built in R2 with reconciliation; the source file is kept add-only) |
| 5 | Who reads a Person's PBA record | **The Person's assigned PBA Manager, Administrative Reviewer and Quarterly Auditor + the Compliance Director + the owner.** Nobody else. The owner and Compliance Director read; only the assigned PBA Manager writes |
| 6 | Editing ledger entries | **Editable until the month closes, sealed after.** Every edit audited with before/after + required reason; void replaces delete; after close only reversing entries |
| 7 | Signatures | **Signed in Provly.** Staff attest as themselves (typed name + account + time + fingerprint of the exact content); the Person/guardian signs on screen, witnessed; a wet-signed scan is the backup. A signature locks the form; changes need a new signed version |
| 8 | Ledger before enrollment papers | **The ledger starts as "Pending enrollment."** Entries record from day one; a red banner and a Compliance Director flag until the fiduciary proof and Form A are filed; no month can close until then. Host-as-payee stays a hard refusal |

## Principles carried in

- **Invariants live in the database.** Every write goes through a SECURITY DEFINER RPC that checks the caller's PBA role for that Person; clients get no direct INSERT/UPDATE/DELETE on PBA tables.
- **Relationship, not role.** PBA access comes from per-Person assignments (Decision 5), on the Item 4 model; a staff title grants nothing.
- **The mirror.** Reality always records (Decision 2); hard refusals are reserved for the software's own conduct: who may hold a role, who may write, files that may never change.
- **Thresholds per provider.** Spec values marked [tenant setting] live in a new per-provider settings table (shared later with pay rules). SOW values (the $50 receipt rule, 10% audit sample, $2,000 SSI limit) are constants, not settings.

## Release 1 — the record

### Data (new tables; all tenant-bound by (person_id, org_id) composite FKs, RLS on)

**`org_settings`** — `org_id`, `key`, `value jsonb`, `updated_by`, `updated_at`; PK (org_id, key). `provly_setting(org, key)` returns the provider's value or the built-in default. R1 keys and Hope Haven defaults: `pba.third_party_count` 3, `pba.third_party_amount` 150, `pba.third_party_days` 90, `pba.affidavit_count` 3, `pba.affidavit_days` 90. Written by owner / compliance director; audited.

**`pba_enrollments`** — one per Person: `fiduciary_type` (`ssa_payee` | `conservator` | `voluntary`), `proof_file_id`, `started_on`, `ended_on`. Status is computed: **enrolled** when the proof file and a signed Form A exist, else **pending**.

**`pba_natural_support_determinations`** (Form A) — `person_id`, `entries jsonb` ([{name, relationship, reason they are not payee}]), `version`; signed through `signatures`.

**`pba_role_assignments`** — `person_id`, `staff_id`, `role` (`manager` | `reviewer` | `auditor`), `start_date`, `end_date`.
- One staff member holds at most one PBA role per Person at a time (exclusion constraint) — the spec's separation of duties (P7's premise).
- **Host refusal (SOW 11.4(1)):** an assignment is refused when the staff member is assigned (`staff_assignments`) to the HHS site where the Person currently lives, or to the Person as their host. If a PBA role-holder *later* becomes the Person's host, the assignment can't be undone retroactively — it raises the **host conflict** flag instead.

**`pba_accounts`** — `person_id` (NULL only for a collective account), `kind` (`bank` | `pay_card` | `cash` | `able`), `institution`, `last4`, `titling` (required — the name the account is held in), `holding` (`individual` | `collective`), `supervising_institution` (pay cards, SOW 15.3(2)), `opening_balance` + `opening_date` (from the first statement), `opened_on`, `closed_on`, and `not_provider_funds_attested` (required true — SOW 15.2(8), 15.4(5)). Collective accounts: each entry carries its Person, so every Person's sub-balance is the sum of their entries. ABLE balances are tracked separately (they matter for the SSI resource test in R2).

**`pba_transactions`** — `person_id`, `account_id`, `entry_date`, `type` (`deposit` | `withdrawal` | `transfer` | `interest` | `fee` | `cash_out`), `amount` (> 0, sign comes from the type), `to_account_id` (transfers), `payee`, `category`, `beneficiary` (`person` | `other`) + `beneficiary_name` + `beneficiary_relationship`, `purchased_by` (`staff` | `host` | `person`) + `purchased_by_staff_id`, `handed_to` (`person` | `staff` | `host` + who) + `purpose` — required on every `cash_out` and on every withdrawal from a `cash` account, so each withdrawal **and each later hand-off** of cash is logged with recipient and purpose (the spec's cash log), `request_id`, `reverses_id`, `status` (`active` | `voided`) + `void_reason`, `notes`.
- **Edits (Decision 6):** `pba_edit_transaction(id, changes, reason)` — refused once the entry's month is closed (the close table arrives in R2; the seal check is installed now). Every edit writes before/after + reason to `audit_log`. `pba_void_transaction(id, reason)` replaces delete. After close: `pba_reverse_transaction(id, reason)` creates the linked reversing entry.
- **Receipt rule (SOW 15.3(6)):** an expense over **$50.00** needs a receipt or a Lost Receipt Affidavit. A multi-item purchase is entered as one transaction at its total, so $20 + $18 + $15 = $53 needs one (P6); $48 doesn't (P5).

**`pba_receipts`** — `transaction_id`, `storage_path`, `sha256`, `mime`, `bytes`, `uploaded_by`, `uploaded_at`. Insert-only: no UPDATE/DELETE grant or policy. A corrected receipt is a new row on a new (reversing/corrected) entry; the old one stays.

**`pba_lost_receipt_affidavits`** (Form F) — `transaction_id`, `store`, `purchase_date`, `amount`, `statement_line_ref` (text in R1; links to imported statement lines in R2), `reason`; needs two signatures: the purchasing staff member and the Compliance Director. **The countersigner is never the purchaser:** if the Compliance Director made the purchase, the owner countersigns.

**`pba_purchase_requests`** (Decision 2) — `person_id`, `amount`, `payee`, `beneficiary` + name + relationship, `category`, `person_choice` (the Person's own words), `needs_met` (attested: food, shelter / room & board, clothing, medical — SOW 15.2(4)), `status` (`requested` | `approved` | `declined` | `spent` | `cancelled`), `decided_by`, `decided_at`, `decline_reason`.
- Approval is **refused** when the beneficiary is another person, or the category is savings, debt repayment or a gift, and needs-met isn't attested (P3 — blocked at the request). R3 adds the automatic room & board and durable-goods checks at this same step.
- **Approved by the Person's PBA Manager** (the use case: "PBA Manager approval before or at the time of purchase").
- The transaction that records the actual spend links back with `request_id`; the request becomes `spent`.

**`signatures`** (generic, insert-only) — `form_type`, `form_id`, `signer_kind` (`staff` | `person` | `guardian`), `signer_staff_id`, `signer_name` (typed), `attestation`, `content_sha256` (computed **server-side** from the form's stored content at the moment of signing), `drawn_image_path` (Person/guardian, on screen), `witnessed_by_staff_id`, `scan_path` (wet-signed backup), `signed_at`. A signed form is locked; changing it creates a new version that must be signed again.

### Storage (Decision 3)

One private bucket, **`pba`**. Paths `{org_id}/{person_id}/{receipts|documents|signatures}/{uuid}.{ext}`; R2 adds `statements/`.
- Storage policies: **insert** for the Person's PBA Manager (signatures: the signing staff member); **select** per Decision 5; **no update or delete** policy exists, so nothing can be replaced or removed.
- The app computes the SHA-256 before upload and the RPC stores it. Honest limit: a hash supplied at upload proves the file never changed *afterwards*; a server-side re-hash (edge function) is a later hardening.
- On phones, "Add receipt" opens the camera directly.

### Access (Decision 5)

`pba_can_read(person)` = an active PBA role for that Person, or the caller's membership is `owner` or `compliance_director`. `pba_can_write(person)` = an active **manager** role for that Person. Compliance Director actions (Form F countersign, flag resolution with reason) check `compliance_director` membership, and are refused for a Person the Compliance Director is the PBA Manager of (they'd be reviewing their own work) — the owner acts instead. All reads go through RLS on these functions; all writes through RPCs.

### Flags (computed on read; nothing is stored, so each clears itself)

`pba_flags(person)` returns R1's flags:

| Flag | Trigger |
|---|---|
| Pending enrollment | Fiduciary proof or signed Form A missing (Decision 8) |
| Missing receipt | Active expense > $50 with no receipt and no fully signed affidavit |
| Third-party pattern | ≥ 3 transactions or ≥ $150 to one non-Person beneficiary in 90 days [tenant] |
| Affidavit pattern | ≥ 3 affidavits for one purchasing staff member in 90 days [tenant] |
| Roles incomplete | No active manager, reviewer or auditor for an enrolled Person |
| Host conflict | A current PBA role-holder is now the Person's host |
| Recorded over a block | A transaction recorded without an approved request where approval would have been refused (Decision 2) — resolved by the Compliance Director with a reason |

### App (Release 1)

- **Client profile → PBA tab** (shown only when `pba_can_read`): Enrollment (fiduciary type, proof upload, Form A with signing), Roles (assign / end; refusals explained), Accounts, Ledger (month selector, running balance per account, add / edit-with-reason / void, receipt camera upload, affidavit), Requests (new, approve / decline), Flags.
- **Compliance → PBA** (Compliance Director, owner): every Person's open flags, affidavits awaiting countersign, overrides awaiting a reason.
- **Signing:** staff "I attest…" with typed name; Person / guardian draw on screen on the staff device, witnessed; "Attach signed scan" as a backup on every form.

### Acceptance tests that land in R1

P1 (saved as pending, receipt task) · P2 (accepted; Forms C/D/G arrive in R2) · P3 (blocked **at the request**; recorded-anyway → flag) · P4 (third-party flag) · P5 · P6 · P7 (reviewer edit refused) · P8 (host as manager refused). P9–P12 land in R2/R3.


## Release 2 — the monthly close (decided Oct 5; built as v20.0.30)

### Decisions

| # | Decision | Choice |
|---|---|---|
| R2-1 | When a month is sealed | **When the reconciliation (Form B) is signed.** Signing requires every statement line matched, every purchase over $50 with a receipt or fully signed affidavit, every unmatched entry resolved, and enrollment complete. Forms C, D and G then work from the same fixed numbers; a later correction is a reversing entry in an open month |
| R2-2 | Reading a bank's statement file | **Map the columns once per account.** First import: pick the date, description and amount (or debit + credit) columns and the date format; Provly remembers it per account and asks again if the headers change. Manual lines are the fallback |
| R2-3 | Matching statement lines to entries | **Provly suggests, the PBA Manager confirms.** Suggestions by amount and date (± 3 days), exact ones marked; one "Accept all exact matches" button; an unmatched bank line becomes an entry in one click (pre-filled); an unmatched entry is corrected, voided or explained (e.g. an uncleared check) before Form B |
| R2-4 | The review with the Person (Form C) | **The Person signs, with a recorded exception.** Date, in person / virtual, who attended, the Person's comments in their own words; signed on screen by the Person or guardian (or a scan); if they can't or won't sign, the reason is recorded, the step completes, and it is flagged for the reviewer |
| R2-5 | Administrative review findings (Form D) | **Recorded, routed to the Compliance Director, the cycle continues.** A pre-checked checklist the reviewer confirms; each finding is an open item the CD answers; money errors are corrected in the next open month; Form G goes out on time with Form D and its findings |
| R2-6 | Getting Form G to the SC | **Provly builds the PDF; the PBA Manager sends it and records how.** Date, recipient (pre-filled from the client's SC), method; that completes the step. Direct email / secure links come with the email and HIPAA arcs |
| R2-7 | Counting assets | **The official check at each reconciliation, plus a live early warning.** Countable = bank + pay card + cash on hand (ABLE excluded); checked against the $1,500 setting when Form B is signed (the month-end balance is the next month's first-moment figure SSI counts) and warned live between closes. Crossing it requires the notices recorded (Person, residential team, SC) and a plan (planned purchase / ABLE / other + target date), recorded for that close. A breach at the close stays flagged until then, even if the balance later drops back under (r4: the SOW's notice is due once the threshold is reached) |

### The cycle (Gap 21)

For month M, due in month M+1: **Form B day 5 · Form C day 10 · Form D day 15 · Form G day 30.** Each step locks when signed; a step can't start before the one before it is complete. Status per Person per step: green (done), amber (due within 3 days), red (overdue). Dashboard and Compliance → PBA show every Person's cycle.

### Readings (stated in the PR)

- **Cash on hand** has no statement: its reconciliation is a counted amount the PBA Manager records each month; a difference from the ledger must be zero or explained by an entry.
- **Opening balance** for a first close comes from the account's opening balance (Release 1); each later month opens at the previous sealed close.
- **Spend-down**: Medicaid spend-down amount + due date per month; unpaid by the due date → flag. **SSA payee accounting**: a reminder record with a due date when SSA requests it.
- **Billing check**: a PBA service note written by the Person's Administrative Reviewer or Quarterly Auditor is flagged (their time is internal control, not billable — spec §3).

### Acceptance tests that land in R2

P9 (room & board) stays R3. **P10** countable assets $1,520 → alert, notices + plan required. **P12** day 16 with no Form D → step overdue. Plus: Form B refused while a line is unmatched or a receipt is missing; signing B seals the month; C with a recorded exception completes and flags; a D finding opens a CD item and G still completes; the column mapping is reused on the second import and re-asked when headers change.

## Not in Release 1 (decided when each release starts)

- **R2:** statement import + matching, Form B reconciliation (opening balance anchored to the first statement), the month close and seal, Forms C / D / G and their deadlines, asset and benefits monitoring ($1,500 alert, ABLE, spend-down), the Form G export, and a flag when the Person's Administrative Reviewer or Quarterly Auditor bills PBA time for that Person (their time is internal control, not billable — spec §3).
- **R3:** host/staff spending allowance (48-hour return), quarterly audit with a recorded random draw, special transactions (room & board agreement, life insurance / burial, emergency loans, restrictions with HRC + SC approval, durable goods, change of provider, death), the external review package, annual outcome data.
- **Before live receipts:** the Supabase BAA (paid tier) on the HIPAA-posture list.

## Cross-check against the spec (v1.1)

- **Gap 16** — kept, with Decision 8 changing "cannot activate" to "starts pending; no month closes". Host refusal kept as written.
- **Gap 17** — kept. "Not linked to provider funds" can't be detected from data, so it is a required titling field plus a required attestation.
- **Gap 18** — kept. SOW 15.4(4)'s "never alter a receipt" holds absolutely (Decision 3); Decision 6's edits apply to ledger entries, never to receipts. Statement lines and "every expenditure links to a receipt or a statement line" land with reconciliation in R2. Cash log now covers hand-offs from cash on hand, not just withdrawals.
- **Gap 20** — kept, enforced in the database. Added: approvals come from the PBA Manager; a countersign or flag resolution is never done by the person whose work it checks.
- **Use case + P1–P8** — covered in R1; P3 blocks at the request (Decision 2). P9–P12 in R2/R3.
- **Billing (§3)** — unchanged: PBA bills Q or S through its 1056 row's Kind (v20.0.26); notes prove the service, the ledger proves the money.

## Delivery

**v20.0.29 — PBA Release 1:** `sql/v20.0.29.sql` (tables, RLS, RPCs, storage bucket + policies, flags, self-test, verification table — 🟢 run in Supabase) + app (PBA tab, Compliance → PBA) + `docs/pba-module-spec-v1.md` and this doc committed (repo only).
