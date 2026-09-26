# Provly — UPI e520 payment file · design v1.0

Status: **for approval** · Sep 25 2026 · Tier 3 arc "Billing: UPI e520 payment-file export" · commits as `docs/e520-design.md` with PR 1.

## 1. What it does

At month end the office downloads the invoice from UPI, saves it from Excel as CSV exactly as today, and drops it into Provly. Provly matches every UPI line to the approved documentation for that person and code, fills the units, trims or splits date ranges around absences, removes lines with no service, runs UPI's validation rules before UPI does, and hands back the upload file together with a reconciliation of everything that did not line up. After uploading, the office marks the batch uploaded; the notes behind it become billed and lock. The state's budget stays the authority on what is payable; Provly is the authority on what was delivered.

## 2. Decisions (locked Sep 24–25)

| # | Decision | Locked |
|---|---|---|
| D1 | Where the lines come from | Provly fills UPI's download; it never writes a file from scratch |
| D2 | What Provly may change | Only units, date ranges, removed lines and split lines. Every UPI value passes through as written: the 13-column header (incl. `monthly_max_units`), line numbers, names, PIDs, codes, rates, SCE |
| D3 | Input | The Excel-saved CSV of the UPI download; refuse any PID that is not 9 digits with a leading 0 |
| D4 | What proves a unit | Approved notes only. EVV-required codes need the note and an EVV visit; the lesser count is billed |
| D5 | Quarter hours | Per person + code + day: add the minutes, round to the nearest quarter hour (8+ leftover minutes earn a unit). Default until the contract says otherwise |
| D6 | MTP | Only on a DSG day, proven by a transport field on the DSG note preset "to and from". Stand-alone MTP notes never bill |
| D7 | Absences | Recorded on the client: from, to, reason (Family / Vacation / Hospital / AWOL / Jail / Other with required text). An absence splits every line that person has |
| D8 | When a note is billed | At "Mark uploaded". A batch is one uploaded file; supplementals allowed; status after upload lives on the line; a dead UPI status releases that line's notes |
| D9 | Signature | `provider_approver_email` passes through from the download; one email per file; Provly logs who marked the batch uploaded |

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

Every type is 0 on a day inside a recorded absence. Rounding is `floor(m/15) + (1 if m mod 15 >= 8)`. Note minutes are `duration_minutes` as saved. EVV minutes are clock-out minus clock-in for sessions with both set, dated by the clock-in day in America/Denver (the v20.0.14 anchoring).

### 5.3 Date ranges

The downloaded span passes through unless a residential placement starts or ends inside it (trim), the authorization starts or ends inside it (trim), or an absence falls inside it (split). A split keeps the original line number on its first part; later parts take the next numbers after the file's highest. A part with 0 units is dropped. Dates Provly writes use UPI's own form, mm/dd/yyyy.

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

The billed lock extends the v20.0.13 lock: billed is locked like approved, has no Reopen, and cannot be deleted (v20.0.20 already refuses). Only `e520_mark_uploaded` moves a note into billed and only `e520_release_line` moves it out. Every RPC is one transaction, manage tier, SECURITY INVOKER, and uses audit action names of 20 characters or fewer (`audit_log.action` is VARCHAR(20)).

## 7. Access

Batches, lines and line-notes are manage tier only (owner, admin, compliance director), because they carry rates, PIDs and the state signature. Absences follow §3.1. Transport is set by whoever writes the DSG note.

## 8. Defaults to confirm

| Default | Why it is a default, not a decision yet |
|---|---|
| Absences are recorded by office tiers; host home operators see them but cannot record them | Operators often know first; opening it to them is a one-policy change |
| A one-way ride (to or from only) bills one MTP day | Needs the contract's MTP wording |
| A monthly code (HAP) bills 1 unit if any approved note falls in the span | Depends on how HAP is documented |
| Units above the monthly max are capped and flagged rather than sent for UPI to error | Keeps the file clean; the flag carries the Notify-SC step |
| D5 rounding, and whether MTP needs a separate trip log | Siamon to confirm against the DSPD contract before the first real upload |

## 9. Delivery

| PR | Version | Scope |
|---|---|---|
| 1 | v20.0.23 (SQL + app) | `person_absences` + client-profile Absences tab; `service_notes.transport` + DSG field (preset) + backfill; MTP out of the new-note picker; the Billing page estimate moves to D5 (the round-up goes) |
| 2 | v20.0.24 (SQL only) | e520 tables, engine, RPCs, billed lock; verification table pasted in chat before merge |
| 3 | v20.0.25 (app) | Billing → UPI e520: upload, review (flags, removed lines, not in budget), download, Mark uploaded, release a line; compliance deadline D23 text "PRISM" → UPI |

Recording ships first because absences and transport must be captured during the month they bill. Verification: September runs as a shadow — Provly builds a file from the September download, and it is compared line by line with the hand-made September file before that one is uploaded; every difference gets explained (September predates absences and transport, so the comparison also shows what they change). October is the first Provly-built upload, early November.

## 10. Later: payment reconciliation (Tier 3)

Import the E520 Payment File Report's detail XLSX per status to set `upi_status` on every line, joined on the batch's `upi_file_record_id`; then the payment reports and deposits give expected (rate × units) against received. Needs one masked "Paid by CAPS" detail XLSX. Finance → Import UPI stays until this replaces it.
