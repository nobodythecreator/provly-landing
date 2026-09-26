# Provly — UPI e520 payment file · design v1.2

Status: **approved** (v1.0 Sep 25; v1.1 Sep 26 records what the build settled; v1.2 Sep 26 records the contract answers and HAP) · Tier 3 arc "Billing: UPI e520 payment-file export" · `docs/e520-design.md`.

**v1.2 changes:** the four open contract questions are answered (§8); HAP has its own rule (§5.2); a rejected authorization never covers a day (§5.3); the authorization used-units counter follows D5 (§11).

**v1.1 changes:** October is the shadow run (§9); the RPCs are SECURITY DEFINER and the e520 tables are read-only to clients (§6–§7); how caps and reservations behave day by day (§5.4); authorization trims use any Provly authorization on file (§5.3, day by day, gaps are breaks); caps shared across lines of the same month (§5.4); HAP and unsupported unit types (§8); the author-only Submit and bulk approve from v20.0.23a (§2); known limits (§11).

## 1. What it does

At month end the office downloads the invoice from UPI, saves it from Excel as CSV exactly as today, and drops it into Provly. Provly matches every UPI line to the approved documentation for that person and code, fills the units, trims or splits date ranges around absences, removes lines with no service, runs UPI's validation rules before UPI does, and hands back the upload file together with a reconciliation of everything that did not line up. After uploading, the office marks the batch uploaded; the notes behind it become billed and lock. The state's budget stays the authority on what is payable; Provly is the authority on what was delivered.

## 2. Decisions (locked Sep 24–25)

| # | Decision | Locked |
|---|---|---|
| D1 | Where the lines come from | Provly fills UPI's download; it never writes a file from scratch |
| D2 | What Provly may change | Only units, date ranges, removed lines and split lines. Every UPI value passes through as written: the 13-column header (incl. `monthly_max_units`), line numbers, names, PIDs, codes, rates, SCE |
| D3 | Input | The Excel-saved CSV of the UPI download; refuse any PID that is not 9 digits with a leading 0 |
| D4 | What proves a unit | Approved notes only. EVV-required codes need the note and an EVV visit; the lesser count is billed |
| D5 | Quarter hours | Per person + code + day: add the minutes, round to the nearest quarter hour (8+ leftover minutes earn a unit). There is no written DSPD rule; this is Hope Haven's long-standing practice of billing to whatever is closest to a 15 (confirmed Sep 26) |
| D6 | MTP | Only on a DSG day, proven by a transport field on the DSG note preset "to and from". The DSG day is the whole record: no separate trip log, and a one-way ride bills the full day. Nothing else is MTP (groceries, doctor visits). Stand-alone MTP notes never bill, and the database refuses them (confirmed Sep 26) |
| D7 | Absences | Recorded on the client: from, to, reason (Family / Vacation / Hospital / AWOL / Jail / Other with required text). An absence splits every line that person has |
| D8 | When a note is billed | At "Mark uploaded". A batch is one uploaded file; supplementals allowed; status after upload lives on the line; a dead UPI status releases that line's notes |
| D9 | Signature | `provider_approver_email` passes through from the download; one email per file; Provly logs who marked the batch uploaded |
| — | Approval (v20.0.23a) | Only a note's author can Submit it (database-enforced, including no reassigning a note to yourself); office tiers bulk-approve submitted notes only. Office-entered notes for others are approved one at a time from the note |

## 3. Recording pieces (they must exist during the month they bill)

### 3.1 Absences

```sql
person_absences (
  id uuid pk, org_id uuid, person_id uuid,          -- tenant-bound composite FK to persons
  start_date date not null, end_date date,          -- NULL end = ongoing
  reason text not null check (reason in ('family','vacation','hospital','awol','jail','other')),
  note text,
  check (reason <> 'other' or length(btrim(note)) > 0),
  check (end_date is null or end_date >= start_date),
  created_by uuid, created_at timestamptz default now()
)
-- no two absences overlap for one person: EXCLUDE USING gist (person_id WITH =, daterange(start_date, coalesce(end_date,'infinity'), '[]') WITH &&)
```

An absence covers full days away. A note dated inside an absence is not refused (Provly mirrors reality, it does not block recording it); the export flags the conflict instead. Read: anyone who can see the person. Write: operate and manage tiers (see §8). Deleting an absence writes `absence_deleted` to the audit log. The client profile gains an Absences tab.

### 3.2 Transport on DSG notes

A note's extra fields are folded into its text today (`[Label] value`), not stored as data, so transport becomes a real column: `service_notes.transport text check (transport in ('to_and_from','to','from','none'))`. A trigger sets `'to_and_from'` on a DSG note saved without it and forces NULL on every other code; the value is part of the locked content once a note is approved. Existing DSG notes are backfilled with `'to_and_from'`, the same presumption the preset makes and the one every past MTP line already rested on. MTP leaves the new-note code picker; existing MTP notes stay readable.

## 4. Batches

```sql
e520_batches (
  id uuid pk, org_id uuid,
  service_month date,                 -- first of the month the download covers
  seq int,                            -- 1 = main file, 2+ = supplementals; unique (org_id, service_month, seq)
  status text check (status in ('draft','uploaded')),
  source_filename text, source_csv text, source_sha256 text, header text,
  approver_email text,
  export_filename text, export_csv text, export_sha256 text,
  upi_file_record_id int,             -- UPI's Payment File Record ID, may be filled after upload
  built_by uuid, built_at timestamptz, uploaded_by uuid, uploaded_at timestamptz
)
e520_lines (
  id uuid pk, batch_id uuid, org_id uuid,
  line_number int,                    -- as downloaded; split parts take new numbers
  source_line_number int,             -- the downloaded line a split part came from
  raw jsonb,                          -- all 13 values exactly as UPI wrote them
  person_id uuid, service_code text,
  start_date date, end_date date, units int,
  action text check (action in ('fill','split','remove')), remove_reason text, flags jsonb,
  upi_status text,                    -- one of UPI's 12 statuses, once known
  released_at timestamptz, released_by uuid, release_reason text
)
e520_line_notes (
  line_id uuid, note_id uuid, service_code text, service_date date,
  units int, evv_units int, released boolean default false
)
-- a note backs at most one live unit per code (a DSG note backs its DSG day and its MTP day):
-- UNIQUE (note_id, service_code) WHERE NOT released
```

Two invariants hold in the database, not the app. A note is reserved by at most one live line per code, draft or uploaded, so no second file can claim it. A note's status is `billed` exactly when a live line in an uploaded batch holds it. At most one draft exists per org and month.

## 5. The engine

### 5.1 Reading the file

`e520_build(p_filename, p_csv)` parses the file in the database. The whole file is refused, and nothing is stored, when a required header column is missing, a field is quoted, any PID is not 9 digits with a leading 0, more than one `provider_approver_email` appears, or a line's dates cross a month. Late lines for an earlier month are allowed, as the manual permits, and each is filled from its own month's documentation. The header is stored as UPI sent it; if it differs from the org's last uploaded header, the review says UPI changed its download.

People are matched by PID against `persons.identification_number` (falling back to `dspd_pid`), comparing after left-padding Provly's value to 9 digits, because Provly's own PIDs may have lost their zero (the May EVV lesson). Codes are matched on `service_code_definitions.code`.

### 5.2 Units per day

| Unit type | A day's units |
|---|---|
| Q (quarter hour) | Approved-note minutes for the person, code and day, rounded per D5. EVV-required codes also round the day's completed EVV minutes the same way and bill the lesser (D4) |
| D (daily) | 1 if an approved note for the code is dated that day (EVV-required codes: and an EVV visit that day) |
| D, MTP | 1 if an approved DSG note that day has transport other than `none` |
| M (monthly) | 1 per line if at least one approved note for the code is dated inside the line's span |
| HAP (rent) | 1 per month the client is in the provider's care: any day on the line with a placement on file and not after the discharge date. Absences never split or reduce it (a whole month in hospital or jail still bills); nothing once they are out of care or after discharge; a partial month is flagged to check proration. No notes: the placement is the documentation, and the database refuses a HAP service note (decision A, Sep 26) |

Every type is 0 on a day inside a recorded absence. Rounding is `floor(m/15) + (1 if m mod 15 >= 8)`. Note minutes are `duration_minutes` as saved. EVV minutes are clock-out minus clock-in for sessions with both set, dated by the clock-in day in America/Denver (the v20.0.14 anchoring).

### 5.3 Date ranges

The downloaded span passes through, and coverage is checked day by day. A day is a break (never billed) when it falls inside a recorded absence, outside every residential placement on file (RHS, HHS, PPS), or outside every Provly authorization on file for that client and code that isn't rejected (pending, approved and expired authorizations cover their dates; a rejected one never does). If the only authorization on file is rejected, no day is covered; only when there is no authorization on file at all does UPI's line stand as the authority. A gap between two placements or two authorizations is therefore a break too. With no placement or no authorization on file, that check is skipped and the line is flagged, because UPI's line is the authority. Each run of billable days between breaks becomes the line or one of its split parts. A split keeps the original line number on its first part; later parts take the next numbers after the file's highest. A part with 0 units is dropped. Dates Provly writes use UPI's own form, mm/dd/yyyy.

### 5.4 Caps and flags

| Condition | The file gets | The review shows |
|---|---|---|
| No approved documentation | line removed | no service notes for this line |
| PID not found in Provly | line removed | PID not found |
| Units above `monthly_max_units` | capped at the max | N more documented; ask the SC to raise the monthly max, then send a supplemental |
| Units above `remaining_units` | capped | same, against remaining units |
| UPI rate differs from Provly's authorization rate | UPI's rate kept | rate mismatch, both values |
| EVV and notes disagree | lesser billed | each day's gap and its reason |
| Note dated inside an absence | day not billed | conflict to resolve |
| Residential day with neither note nor absence | day not billed | document the day or record the absence |
| Approved notes with no UPI line | not in the file | delivered but not in the budget |

Lines are filled in order of their start dates, whatever order UPI lists them in (the upload file keeps UPI's order). The monthly max is shared by every live line for the same client, code and month, in this file and in files already uploaded; remaining units are shared by the lines of this file (a supplemental starts from its own fresh download). Caps are applied day by day in date order. A day that bills anything reserves all of its notes, so a note's minutes can never be counted again; days beyond the cap reserve nothing and stay free for a supplemental once the SC raises the max. A day that bills nothing (for example a missing EVV visit) reserves nothing, so a corrected EVV can bill it later. A note is eligible for a unit whenever no live line holds it for that code, even if it is billed for another code: when an MTP line is denied and released, a supplemental can bill that MTP day again from the DSG note that is still billed for DSG.

### 5.5 Writing the file

The database writes the export from the stored lines: UTF-8 BOM, CRLF, no newline after the last row (the byte shape of every accepted file), raw values verbatim, and new text only for units, changed dates and new line numbers. The filename is the month (YYYY-MM) plus the org name in letters and digits plus `.csv`, with `-2`, `-3` for supplementals. Export text and its SHA-256 are stored on the batch.

## 6. Lifecycle

| RPC | Effect |
|---|---|
| `e520_build(filename, csv)` | New draft for the month, replacing any existing draft. If the month's main file is already uploaded, it builds a supplemental from notes no live line holds |
| `e520_delete_draft(batch)` | Drafts only; frees the reservations; audit `e520_draft_deleted` |
| `e520_mark_uploaded(batch, export_sha256, upi_record_id?)` | Refused unless the hash matches the current export (a rebuild after download is caught). Freezes the batch; its notes move approved → billed; audit `e520_uploaded` |
| `e520_set_upi_record(batch, id)` | Records UPI's Payment File Record ID later |
| `e520_release_line(line, upi_status, reason)` | Only for dead statuses: Deleted, Denied by SC, Denied by DSPD, Error by CAPS, Rejected by CAPS. Each note returns to approved unless another live uploaded line still holds it; audit `e520_line_released` |

The billed lock extends the v20.0.13 lock: billed is locked like approved, has no Reopen, and cannot be deleted (v20.0.20 already refuses). Only `e520_mark_uploaded` moves a note into billed and only `e520_release_line` moves it out. Every RPC is one transaction and manage tier. They are SECURITY DEFINER with explicit tier and organization checks, and every query inside is scoped to the batch's organization; the e520 tables have no client write policies, so the RPCs are the only way in. Audit action names are 20 characters or fewer (`audit_log.action` is VARCHAR(20)): `e520_built`, `e520_uploaded`, `e520_line_released`, `e520_draft_deleted`, `e520_record_set`.

## 7. Access

Batches, lines and line-notes are readable by the manage tier only (owner, admin, compliance director), because they carry rates, PIDs and the state signature; nobody writes them except through the RPCs. Absences follow §3.1. Transport is set by whoever writes the DSG note.

## 8. Defaults to confirm

| Default | Why it is a default, not a decision yet |
|---|---|
| Absences are recorded by office tiers; host home operators see them but cannot record them | Operators often know first; opening it to them is a one-policy change |
| A one-way ride (to or from only) bills one MTP day | Confirmed Sep 26: the DSG day is enough |
| Units above the monthly max are capped and flagged rather than sent for UPI to error | Keeps the file clean; the flag carries the Notify-SC step |
| D5 rounding, and whether MTP needs a separate trip log | Answered Sep 26: nearest quarter hour (no written rule; long-standing practice); no trip log |
| HAP is in the code table as a monthly code (v20.0.24a) | Its name there is "Housing Assistance (rent)"; correct it if DSPD's official name differs |
| Unit types other than Q, D and M | Removed with "fill this line by hand" until a real file shows one |

## 9. Delivery

| PR | Version | Scope |
|---|---|---|
| 1 | v20.0.23 (SQL + app) ✅ | `person_absences` + client-profile Absences tab; `service_notes.transport` + DSG field (preset); MTP out of the note pickers; nearest-quarter-hour rounding, per day in the Billing estimate |
| 1a | v20.0.23a (SQL + app) ✅ | Save Draft / Submit; author-only Submit; Approve Submitted (bulk) |
| 2 | v20.0.24 (SQL only) | e520 tables, engine, RPCs, billed lock; a synthetic end-to-end self-test in the verification table |
| 2a | v20.0.24a (SQL) | HAP rule and code; rejected authorizations never cover; authorization used units follow D5 (§11) |
| 3 | v20.0.25 (app) | Billing → UPI e520: upload, review (flags, removed lines, not in budget), download, Mark uploaded, release a line; compliance deadline D23 text "PRISM" → UPI |

Recording ships first because absences and transport must be captured during the month they bill. Verification: **October is the shadow run and the gate** — September's notes are still in Google Drive. Provly builds October's file from the October download, it is compared line by line with the hand-made October file, and Provly's is uploaded (early November) only if every difference is explained. October needs every billable day documented, submitted and approved in Provly.

## 10. Later: payment reconciliation (Tier 3)

Import the E520 Payment File Report's detail XLSX per status to set `upi_status` on every line, joined on the batch's `upi_file_record_id`; then the payment reports and deposits give expected (rate × units) against received. Needs one masked "Paid by CAPS" detail XLSX. Finance → Import UPI stays until this replaces it.

## 11. Authorization used units (v20.0.24a)

The counter on each authorization counts the way the payment file does: each day's minutes rounded to the nearest quarter hour for quarter-hour codes, one per day for daily codes, one per DSG ride day for MTP, one per month billed for HAP (live HAP lines in files marked uploaded; HAP has no notes, so billing is when a month is used), one per note for per-session codes. A billed HAP month counts toward the one authorization covering the line's first day that is both in care (a placement on file, not after discharge) and authorized, the same days the engine bills on, since the line keeps UPI's start date, which can fall before care or the authorization. A rejected authorization uses 0. Notes are matched to an authorization by client, code and date, because the app has never linked a note to an authorization. It recounts on every note insert, update and delete (a Reopen takes a note back out), when an authorization's dates, client or code change, and, for HAP, when a file is marked uploaded, a line released, any of the client's authorizations is added, changed or removed, a placement changes (both clients, if it moves), or the discharge date changes; it runs regardless of who approves. It counts documentation (approved and billed notes), so EVV's lesser count applies to the payment file, not to this counter.

Known limit: the code table lists DSI as a quarter-hour code while UPI bills it daily, so a DSI authorization's counter would count quarter hours. Hope Haven doesn't bill DSI today; correct the code table before anyone does.
