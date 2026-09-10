# Provly Item 4 — Operator Logins + Relationship-Scoped RLS
**Design v1.1 · Sep 10 2026 · approved Sep 9; v1.1 corrects the role inventory and one table name found while building PR (a).** Decisions R1–R7 + drift D1–D3 locked.

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
1. **Tenant guard — RESTRICTIVE, FOR ALL**: `org_id = (SELECT org_id())` in USING and WITH CHECK. No permissive policy can ever widen beyond the org.
2. **Tier policies — PERMISSIVE, one per command**, shaped by the table's class below.
3. **Column privileges** (`REVOKE UPDATE (col…) ON t FROM authenticated`) for columns only RPCs / service role may set.

## 4. Read (PR b)
| Class | Tables | `manage` | `operate` | `deliver` |
|---|---|---|---|---|
| **Person-scoped** | persons, person_placements, service_notes, evv_sessions, evv_edit_log, incidents, medications, medication_logs, pcsp_goals, pcsp_progress_notes, support_strategies, documents, quarterly_summaries, belongings_inventory, evacuation_drills, day_activity_absence_days, compliance_alerts | all | all | rows where `can_see_person(person_id)` |
| **Authorizations (R3)** | `person_service_authorizations` **base table** | all, with rate | none | none |
| | `person_service_authorizations_v` (security-barrier view, owner-privileged, same helpers) | all, with rate | rows visible, `rate_per_unit` = NULL | `can_see_person`, rate NULL |
| **Staff-scoped** | shifts, staff_trainings, staff_deck_completions, messages | all | all | own rows (`staff_id = my_staff_id()`; messages: sender or recipient) |
| **Money** | claim_submissions, payments, contracts, billing_claims | all | none | none |
| **Org structure** | staff, staff_assignments, org_sites, org_units, service_delivery_contexts(+members), org_service_codes, training_decks(+codes), training_topic_definitions | all | all | own staff row; sites/units/contexts they're assigned to |
| **Org row** | organizations | own org | own org | own org (brand, enforcement) |
| **Membership** | org_members | all in org | own row | own row |
| **Reference** | service_code_definitions, compliance_deadline_definitions | any authenticated | | |
| **Audit** | audit_log | all | none | none |

Cross-org tables (org_partnerships, person_collaborations, collaboration_messages) keep their existing policies — out of Item 4 scope. PR (b) opens with a discovery UNION over `information_schema.tables` × `pg_policies`; any table not listed above is assigned by its columns (`person_id` → person-scoped, `staff_id` → staff-scoped) and named in the PR.

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
- **Schedule → assignment**: AFTER INSERT on `shifts` — if the shift's staff is `deliver` tier and `can_see_person` is false for that person, open a person edge in `staff_assignments` (visible and endable in Staff → Assignments, which gains a person-edge list). Host-home residents are already visible via placement; no redundant edge.
- **Invite** (`send-invite` edge fn): requested role checked against the caller's ceiling via `member_role()`. Existing staff rows get **Invite to app** (invite carries `staff_id`).
- **Accept** (`accept_invite` RPC): the single binding point — sets `staff.user_id = auth.uid()` (creating the staff row if the invite carried none) → trigger creates the `org_members` row → `app_metadata.org_id` written. **Nothing is ever bound by email match.**
- `person_staff_assignments` (March schema) is **the same table** as `staff_assignments` — renamed by v20.0.4d, not dead. Annotated as such in PR (a).
- External reference: DSPD's own provider system (UPI) enforces the same shape — employees see only the people they are associated with in the provider's org structure; Provider Administrators see everyone (DSPD Help Manual, "Navigating Around UPI").

## 7. Delivery plan
| PR | Version | Contents | App impact |
|---|---|---|---|
| **(a)** identity | v20.0.11 | Drift D1–D3 (`DROP city/state/zip IF EXISTS`; `max_clients` default 10 + realign + trigger; annotations). Helpers §2. `org_members` trigger + last-owner guard. Column privileges §5 (table-level UPDATE replaced by an explicit per-column grant that omits the protected set). `set_staff_role` / `terminate_staff` / `reactivate_staff` RPCs. `send-invite` ceiling + `staffId`. `accept_invite` binding. `signup_create_organization` stops inserting `org_members` (trigger does). Existing tenant RLS **unchanged**. | Invite modal honours ceiling; **Invite to app** on staff rows; Staff role/terminate call RPCs. |
| **(b)** read | v20.0.12 | RESTRICTIVE tenant guards; read policies §4; `person_service_authorizations_v`; schedule→edge trigger. Owner fallback retired. | 5 auth read sites → view; Assignments person-edge list; nav derived from `access_tier()`. |
| **(c)** write | v20.0.13 | Write policies §5; sign-off lock; shift status trigger. | Buttons/forms reflect DB allowances; error toasts for refused writes. |

Each PR: discovery+verification as one UNION statement; SQL additive and idempotent; run on production before ship. Prerequisite: `chore/v20.0.10b-enterprise-cap-500` merged first.
Needed for (a): `supabase/functions/send-invite/index.ts`; the `sql/` file defining `get_invite` / `accept_invite`; landing `index.html` for v20.0.10b.
