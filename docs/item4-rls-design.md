# Provly Item 4 — Operator Logins + Relationship-Scoped RLS
**Design v1.2 · Sep 16 2026 · approved Sep 9; v1.1 (Sep 10) corrected the role inventory and one table name found while building PR (a); v1.2 records the five PR (b) decisions B1–B5 locked Sep 16.** Decisions R1–R7 + drift D1–D3 + B1–B5 locked.

## 1. Principle
The database decides who may see and write what. The app only reflects it. Every rule below is an RLS policy, a trigger, a column privilege, or a SECURITY DEFINER RPC. No rule lives in `index.html`.

## 2. Identity (R1) and tiers (R2)
| Helper | Reads | Returns |
|---|---|---|
| `org_id()` | JWT `app_metadata.org_id` (existing) | caller's org |
| `member_role()` | `org_members` by `(auth.uid(), org_id())` | one of 7 roles, or NULL = **no access** |
| `access_tier()` | `member_role()` via `role_tier(role)` | `manage` (owner, admin, compliance_director) · `operate` (residential_director, day_program_director, house_manager, supervisor, rn, bcba) · `deliver` (dsp, hhs_operator) · any other enum label (billing, readonly) → NULL = no tier. These are the labels the app's STAFF_ROLES dropdown and ROLE_PERMISSIONS actually use. |
| `my_staff_id()` | `staff` by `(user_id = auth.uid(), org_id())`, `is_active` | caller's staff row or NULL |
| `can_see_person(p)` | tier + edges | `manage`/`operate` → true; `deliver` → open **person edge** in `staff_assignments`, OR open **site edge** + open `person_placements` at that site |

All helpers: `STABLE SECURITY DEFINER SET search_path = public`, `REVOKE EXECUTE FROM anon`; policies call them as `(SELECT fn())` so Postgres evaluates once per query.

**`org_members` is derived from `staff`** — trigger on `staff`: `user_id` linked or `role` changed → upsert member row; `is_active = false` or `termination_date` set → delete member row. Last-owner guard: an org can never lose its final owner. `authenticated` has **no direct INSERT/UPDATE/DELETE on `org_members`**; only the trigger and the RPCs below write it. The app's "no staff row → owner" fallback is retired in PR (b).

## 3. Policy structure (every tenant table)
1. **Tenant guard — RESTRICTIVE, FOR ALL** (B1, v1.2): `org_id = (SELECT org_id()) AND (SELECT member_role()) IS NOT NULL` in USING and WITH CHECK (`id = …` on `organizations`; via the deck FK on `training_deck_service_codes`). Tenancy is the JWT claim **and** a live membership row: the moment the staff trigger deletes someone's `org_members` row (termination, unlink, org move) their database access ends, whatever their token still says. No permissive policy can ever widen beyond the org. Cross-org tables (`org_partnerships`, `person_collaborations`, `collaboration_messages`, `person_transfers`) have no `org_id` and get only the membership half. Reference tables (`service_code_definitions`, `compliance_deadline_definitions`) and `waitlist` are unguarded by design.
2. **Tier policies — PERMISSIVE, one per command**, shaped by the table's class below.
3. **Column privileges** (`REVOKE UPDATE (col…) ON t FROM authenticated`) for columns only RPCs / service role may set.

## 4. Read (PR b)
| Class | Tables | `manage` | `operate` | `deliver` |
|---|---|---|---|---|
| **Person-scoped** | persons, person_placements, service_notes, evv_sessions, evv_edit_log, incidents, medications, medication_logs, pcsp_goals, pcsp_progress_notes, support_strategies, documents, quarterly_summaries, belongings_inventory, evacuation_drills, day_activity_absence_days, compliance_alerts | all | all | rows where `can_see_person(person_id)` |
| **Authorizations (R3)** | `person_service_authorizations` **base table** | all, with rate | none | none |
| | `person_service_authorizations_v` (security-barrier view, owner-privileged, same helpers) | all, with rate | rows visible, `rate_per_unit` = NULL | `can_see_person`, rate NULL |
| **Staff-scoped** | shifts, staff_trainings, staff_deck_completions, messages | all | all | own rows (`staff_id = my_staff_id()`; messages: sender or recipient) |
| **Staff directory (B3)** | `staff_directory_v` (security-barrier view: id, org_id, first_name, last_name, role of **active** staff) | all | all | all — names for record display only; no contact, HR, pay or W-9 fields |
| **Money** | claim_submissions, payments, contracts, billing_claims | all | none | none |
| **Org structure** | staff, staff_assignments, org_sites, org_units, service_delivery_contexts | all | all | own staff row; own edges; sites they hold an open site edge to or where a visible person is placed; the unit on their own staff row; contexts with a currently-visible member |
| **Org structure, office only** | org_service_codes (carries `custom_rate`), generated_documents (polymorphic scope), evacuation_drills (free-text site, nothing to scope on) | all | all | none |
| **Training** | training_decks(+codes), training_topic_definitions | any tiered member — staff must see what trainings exist to complete them | | |
| **Org row** | organizations | own org | own org | own org (brand, enforcement) |
| **Membership** | org_members | all in org | own row | own row |
| **Reference** | service_code_definitions, compliance_deadline_definitions | any authenticated (the latter gained its read policy in (b) — the only widening) | | |
| **Audit** | audit_log | all | none | none |

Cross-org tables (org_partnerships, person_collaborations, collaboration_messages, person_transfers) keep their existing policies — out of Item 4 scope. **B2 (v1.2, confirmed Sep 16 from the production inventory: 51 tables, no views):** tables the columns overruled — `compliance_alerts` has no person_id (polymorphic `related_entity_type/id`: deliver sees person alerts they can see and their own staff alerts); `evacuation_drills` has only a free-text site name (deliver none); `evv_edit_log` keys on `session_id` (rows whose session they can see); `service_delivery_context_members` carries person_id and is person-scoped. Tables never named here, assigned by column: `payment_line_items`, `subscription_events` → Money; `medication_administrations` (legacy twin of medication_logs) → person-scoped; `generated_documents` → office only; `person_transfers` → cross-org. `invites` keeps 0 permissive policies (RPC-only); `waitlist` stays service-role only. The app reads a `person_contacts` table that does not exist on production — dead read, filed. Every pre-existing permissive SELECT/ALL policy is dropped (21 `[ALL]` policies and two duplicate SELECTs would OR straight past the tier read); writes stay org-wide until (c).

## 5. Write (PR c)
| Tier | May write |
|---|---|
| **`deliver`** (R5) | INSERT on service_notes, evv_sessions, evv_edit_log, incidents, medication_logs, pcsp_progress_notes, messages — WITH CHECK `staff_id = my_staff_id() AND can_see_person(person_id)`. UPDATE own rows only while **not signed off** (`status` not in reviewed/approved; trigger keeps `staff_id` immutable). shifts: UPDATE own row, **status column only** (trigger). **No DELETE.** |
| **`operate`** | all of `deliver` without the ownership limit, plus: shifts INSERT/UPDATE/DELETE; service_notes sign-off transitions; incidents review; medications; pcsp_goals; persons UPDATE (operational fields); staff_trainings; documents. |
| **`manage`** | all of `operate`, plus: persons INSERT/archive (intake — **not compliance_director**), person_service_authorizations incl. rate, person_placements, org_sites/org_units/contexts, training decks, money tables, staff HR fields (**not compliance_director**). DELETE on org tables **except** audit_log, evv_edit_log, evv_sessions, signed service_notes. |
| **owner + admin** | organizations UPDATE — profile/brand/enforcement columns only. |
| **owner only** | subscription (existing `create-checkout-session` guard). |

**Staff lifecycle (R6) — RPC only, ceiling rule.** `set_staff_role(staff_id, role)`, `terminate_staff(staff_id)`, `reactivate_staff(staff_id)`, and invite creation succeed only when the target's current *and* new role are strictly below the caller's tier; owner may do anything; last-owner guard applies. `REVOKE UPDATE (role, is_active, user_id) ON staff FROM authenticated` — the app cannot write these columns at all.
**Service-role columns.** `REVOKE UPDATE (subscription_tier, subscription_status, trial_ends_at, stripe_customer_id, stripe_subscription_id, stripe_checkout_session_id, checkout_lock_at, max_clients) ON organizations FROM authenticated`. Webhook/checkout use service role. `max_clients` is trigger-derived from tier (10/50/250/500).

## 6. Sight edges (R4) and onboarding (R7)
- **Schedule → assignment (B4, v1.2)**: AFTER INSERT (or reassignment / reschedule: UPDATE OF staff_id, person_id, scheduled_date) on `shifts` — if the shift's staff is `deliver` tier and has no sight of that person, open a **time-boxed** person edge in `staff_assignments`: `origin = 'schedule'`, shift date → **+7 days**, `service_code_id NULL`. A later shift for the same pair extends the edge; a manual edge is never touched; a one-off coverage shift lapses on its own. Managers make sight permanent by assigning the person in Staff → Assignments (person-edge list with origin badge, endable). Host-home residents are already visible via placement; no redundant edge. Sight for a given staff row is `staff_sees_person(staff, org, person)`; `can_see_person(p)` delegates to it for the caller. **r1 (Greptile r1, Sep 16):** the trigger mints an edge only when the *writer* is office tier and can see the person — service-role or SQL-editor shift writes save the shift and open no sight.
- **Invite** (`send-invite` edge fn): requested role checked against the caller's ceiling via `member_role()`. Existing staff rows get **Invite to app** (invite carries `staff_id`).
- **Accept** (`accept_invite` RPC): the single binding point — sets `staff.user_id = auth.uid()` (creating the staff row if the invite carried none) → trigger creates the `org_members` row → `app_metadata.org_id` written. **Nothing is ever bound by email match.**
- `person_staff_assignments` (March schema) is **the same table** as `staff_assignments` — renamed by v20.0.4d, not dead. Annotated as such in PR (a).
- External reference: DSPD's own provider system (UPI) enforces the same shape — employees see only the people they are associated with in the provider's org structure; Provider Administrators see everyone (DSPD Help Manual, "Navigating Around UPI").

## 7. Delivery plan
| PR | Version | Contents | App impact |
|---|---|---|---|
| **(a)** identity | v20.0.11 | Drift D1–D3 (`DROP city/state/zip IF EXISTS`; `max_clients` default 10 + realign + trigger; annotations). Helpers §2. `org_members` trigger + last-owner guard. Column privileges §5 (table-level UPDATE replaced by an explicit per-column grant that omits the protected set). `set_staff_role` / `terminate_staff` / `reactivate_staff` RPCs. `send-invite` ceiling + `staffId`. `accept_invite` binding. `signup_create_organization` stops inserting `org_members` (trigger does). Existing tenant RLS **unchanged**. | Invite modal honours ceiling; **Invite to app** on staff rows; Staff role/terminate call RPCs. |
| **(b)** read | v20.0.12 | RESTRICTIVE tenant guards (B1: claim + membership); read policies §4 (B2); `person_service_authorizations_v` + `staff_directory_v` (B3); schedule→edge trigger with 7-day window + `origin` column (B4); `org_members` write policies and the `person_staff_assignments_*` duplicate set removed. **r1:** writes that *confer sight* are restricted in (b), not (c) — `staff_assignments` and `shifts` INSERT/UPDATE/DELETE = manage or operate, `person_placements` = manage — because an org-wide write on any of them is a self-grant path once open edges and shifts grant reads. Owner fallback retired. | Identity from `member_role()` / `access_tier()` / `my_staff_id()` — no membership = no-access screen; nav falls back by tier (B5: manage → owner set, operate → supervisor set, deliver → dsp set **+ training**); 9 direct authorization reads + 2 `persons` embeds → the view (write path stays on the base table); Assignments person-edge list. Front-line invite gate **stays on** until (c) (all other writes are still org-wide between (b) and (c)). |
| **(c)** write | v20.0.13 | Write policies §5; sign-off lock; shift status trigger. Front-line invite gate comes off. | Buttons/forms reflect DB allowances; error toasts for refused writes; staff name resolution (9 name-only lookups + 16 `staff(first_name, last_name)` embeds) → `staff_directory_v`. |

Each PR: discovery+verification as one UNION statement; SQL additive and idempotent; run on production before ship. Prerequisite: `chore/v20.0.10b-enterprise-cap-500` merged first.
Needed for (a): `supabase/functions/send-invite/index.ts`; the `sql/` file defining `get_invite` / `accept_invite`; landing `index.html` for v20.0.10b.
