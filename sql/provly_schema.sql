-- ============================================================================
-- PROVLY - Supabase PostgreSQL Schema
-- Version 2.0 - March 2026 (with cross-org collaboration)
-- Hope Haven Services Inc.
-- 
-- Deploy order: Run this file in a single transaction against your
-- Supabase project's SQL editor.
-- ============================================================================

-- ============================================================================
-- 0. EXTENSIONS
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. ENUMS
-- ============================================================================
CREATE TYPE billing_unit_type AS ENUM (
  'quarter_hour', 'daily', 'per_trip', 'per_session', 'hourly'
);

CREATE TYPE user_role AS ENUM (
  'owner', 'admin', 'supervisor', 'dsp', 'billing', 'readonly'
);

CREATE TYPE subscription_tier AS ENUM (
  'starter', 'growth', 'professional', 'enterprise'
);

CREATE TYPE subscription_status AS ENUM (
  'trial', 'active', 'past_due', 'canceled'
);

CREATE TYPE background_check_status AS ENUM (
  'pending', 'cleared', 'flagged', 'expired'
);

CREATE TYPE training_category AS ENUM (
  '30_day', '90_day', '180_day', 'abi', 'annual'
);

CREATE TYPE training_type AS ENUM (
  'classroom', 'on_the_job', 'online', 'certification'
);

CREATE TYPE authorization_status AS ENUM (
  'pending', 'approved', 'rejected', 'expired'
);

CREATE TYPE service_note_status AS ENUM (
  'draft', 'submitted', 'approved', 'rejected', 'billed'
);

CREATE TYPE incident_type AS ENUM (
  'injury', 'medication_error', 'behavioral', 'abuse', 'neglect',
  'exploitation', 'elopement', 'property_damage', 'death', 'other'
);

CREATE TYPE incident_severity AS ENUM (
  'low', 'medium', 'high', 'critical'
);

CREATE TYPE incident_status AS ENUM (
  'initiated', 'detailed_pending', 'completed', 'under_investigation', 'closed'
);

CREATE TYPE notification_method AS ENUM (
  'phone', 'email', 'face_to_face'
);

CREATE TYPE alert_status AS ENUM (
  'pending', 'acknowledged', 'resolved', 'overdue'
);

CREATE TYPE claim_status AS ENUM (
  'draft', 'submitted', 'accepted', 'denied', 'paid', 'appealed'
);

CREATE TYPE trigger_event_type AS ENUM (
  'incident_created', 'staff_hired', 'staff_terminated', 'quarter_end',
  'fiscal_year_end', 'pcsp_activated', 'fba_completed', 'bsp_completed',
  'person_death', 'person_admitted', 'person_discharged',
  'authorization_created', 'contract_executed', 'annual'
);

-- ============================================================================
-- 2. SYSTEM REFERENCE TABLES (No org_id - shared across all tenants)
-- ============================================================================

-- 2.1 Service Code Definitions (33 DSPD codes from DHHS91172 SOW)
CREATE TABLE service_code_definitions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code VARCHAR(6) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL,
  sow_article INTEGER NOT NULL,
  billing_unit billing_unit_type NOT NULL,
  evv_required BOOLEAN NOT NULL DEFAULT false,
  daily_rate_threshold_hours NUMERIC(4,1),  -- e.g., 6 for COM/PAC
  max_units_per_day INTEGER,                -- e.g., 24 for ELS
  max_weekly_hours NUMERIC(5,1),            -- e.g., 40 for CMP/CMS
  requires_support_strategy BOOLEAN NOT NULL DEFAULT true,
  requires_quarterly_summary BOOLEAN NOT NULL DEFAULT true,
  description TEXT NOT NULL,
  staff_qualifications JSONB NOT NULL DEFAULT '[]',
  service_limitations JSONB NOT NULL DEFAULT '[]',
  documentation_requirements JSONB NOT NULL DEFAULT '{}',
  outcome_measure TEXT NOT NULL,
  licensing_requirements JSONB NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2.2 Training Topic Definitions (SOW 1.8)
CREATE TABLE training_topic_definitions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sow_reference VARCHAR(20) NOT NULL,
  topic_name VARCHAR(200) NOT NULL,
  category training_category NOT NULL,
  deadline_days INTEGER,            -- Days from hire. NULL for annual.
  requires_certification BOOLEAN NOT NULL DEFAULT false,
  renewal_months INTEGER,           -- Months between renewals. NULL if one-time.
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2.3 Compliance Deadline Definitions (38 deadlines from DSPD Standard)
CREATE TABLE compliance_deadline_definitions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sow_reference VARCHAR(30) NOT NULL,
  deadline_text VARCHAR(50) NOT NULL,
  deadline_hours INTEGER NOT NULL,  -- Normalized to hours
  requirement TEXT NOT NULL,
  applies_to_codes TEXT[],          -- NULL = universal
  trigger_event trigger_event_type NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- 3. TENANT-SCOPED TABLES (All have org_id + RLS)
-- ============================================================================

-- 3.1 Organizations (tenants)
CREATE TABLE organizations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(200) NOT NULL,
  contract_number VARCHAR(50),
  medicaid_provider_id VARCHAR(50),
  address VARCHAR(200),
  city VARCHAR(100),
  state VARCHAR(2) DEFAULT 'UT',
  zip VARCHAR(10),
  phone VARCHAR(20),
  email VARCHAR(200),
  subscription_tier subscription_tier NOT NULL DEFAULT 'starter',
  subscription_status subscription_status NOT NULL DEFAULT 'trial',
  trial_ends_at TIMESTAMPTZ,
  stripe_customer_id VARCHAR(100),
  stripe_subscription_id VARCHAR(100),
  max_clients INTEGER NOT NULL DEFAULT 10,  -- Based on tier
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.2 Org Service Codes (which codes does this org deliver)
CREATE TABLE org_service_codes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  service_code_id UUID NOT NULL REFERENCES service_code_definitions(id),
  is_active BOOLEAN NOT NULL DEFAULT true,
  custom_rate NUMERIC(10,2),
  activated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(org_id, service_code_id)
);

-- 3.3 Staff
CREATE TABLE staff (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id),  -- NULL if no app login
  first_name VARCHAR(100) NOT NULL,
  last_name VARCHAR(100) NOT NULL,
  email VARCHAR(200),
  phone VARCHAR(20),
  address VARCHAR(200),
  city VARCHAR(100),
  state VARCHAR(2) DEFAULT 'UT',
  zip VARCHAR(10),
  role user_role NOT NULL DEFAULT 'dsp',
  hire_date DATE NOT NULL,
  termination_date DATE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  date_of_birth DATE NOT NULL,
  background_check_date DATE,
  background_check_status background_check_status DEFAULT 'pending',
  medicaid_disclosure_date DATE,
  oig_exclusion_check_date DATE,
  qualifications JSONB NOT NULL DEFAULT '[]',
  can_provide_codes TEXT[] NOT NULL DEFAULT '{}',
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.4 Staff Trainings
CREATE TABLE staff_trainings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  staff_id UUID NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  training_topic_id UUID NOT NULL REFERENCES training_topic_definitions(id),
  completed_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ,
  certificate_url TEXT,
  trainer_name VARCHAR(200),
  training_type training_type NOT NULL DEFAULT 'classroom',
  hours NUMERIC(4,1) NOT NULL DEFAULT 1.0,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.5 Persons (Clients)
CREATE TABLE persons (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  first_name VARCHAR(100) NOT NULL,
  last_name VARCHAR(100) NOT NULL,
  date_of_birth DATE NOT NULL,
  medicaid_number VARCHAR(50),
  identification_number VARCHAR(50),  -- DSPD client ID
  address VARCHAR(200),
  city VARCHAR(100),
  state VARCHAR(2) DEFAULT 'UT',
  zip VARCHAR(10),
  phone VARCHAR(20),
  photo_url TEXT,
  -- Guardian / Representative (SOW 1.10(4))
  guardian_name VARCHAR(200),
  guardian_phone VARCHAR(20),
  guardian_address VARCHAR(300),
  emergency_contacts JSONB NOT NULL DEFAULT '[]',
  -- Support Coordinator (SOW 1.10(2))
  support_coordinator_name VARCHAR(200),
  sc_email VARCHAR(200),
  sc_phone VARCHAR(20),
  -- Medical (SOW 1.10(5) + 1.23)
  primary_physician JSONB,
  medical_specialists JSONB NOT NULL DEFAULT '[]',
  medical_insurance_info JSONB,
  medical_info JSONB NOT NULL DEFAULT '{}',  -- allergies, conditions, swallow reflex, advanced directives
  diagnosis_codes TEXT[] NOT NULL DEFAULT '{}',
  -- Service dates
  admission_date DATE,
  discharge_date DATE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  -- Compliance
  grievance_policy_signed_at TIMESTAMPTZ,
  -- Metadata
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.6 Person Service Authorizations (Form 1056)
CREATE TABLE person_service_authorizations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  service_code_id UUID NOT NULL REFERENCES service_code_definitions(id),
  authorized_units INTEGER NOT NULL,
  used_units INTEGER NOT NULL DEFAULT 0,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  status authorization_status NOT NULL DEFAULT 'pending',
  upi_approved_at TIMESTAMPTZ,
  rate_per_unit NUMERIC(10,2),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.7 PCSP Goals
CREATE TABLE pcsp_goals (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  goal_text TEXT NOT NULL,
  target_date DATE,
  status VARCHAR(20) NOT NULL DEFAULT 'active',  -- active, achieved, modified, discontinued
  progress_notes TEXT,
  pcsp_date DATE NOT NULL,  -- Date of the PCSP this goal belongs to
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.8 Support Strategies (SOW 1.24(5))
CREATE TABLE support_strategies (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  pcsp_goal_id UUID REFERENCES pcsp_goals(id),
  service_code_id UUID NOT NULL REFERENCES service_code_definitions(id),
  strategy_text TEXT NOT NULL,
  submitted_to_sc_at TIMESTAMPTZ,  -- Must be within 30 days of PCSP activation
  pcsp_activated_at DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.9 EVV Sessions
CREATE TABLE evv_sessions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  staff_id UUID NOT NULL REFERENCES staff(id),
  person_id UUID NOT NULL REFERENCES persons(id),
  service_code_id UUID NOT NULL REFERENCES service_code_definitions(id),
  clock_in_at TIMESTAMPTZ NOT NULL,
  clock_out_at TIMESTAMPTZ,
  clock_in_lat NUMERIC(9,6),
  clock_in_lng NUMERIC(9,6),
  clock_out_lat NUMERIC(9,6),
  clock_out_lng NUMERIC(9,6),
  geofence_valid BOOLEAN,
  exceptions JSONB NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.10 Service Notes (Core documentation table)
CREATE TABLE service_notes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id),
  staff_id UUID NOT NULL REFERENCES staff(id),
  service_code_id UUID NOT NULL REFERENCES service_code_definitions(id),
  authorization_id UUID REFERENCES person_service_authorizations(id),
  service_date DATE NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME NOT NULL,
  duration_minutes INTEGER NOT NULL,
  billable_units NUMERIC(6,2) NOT NULL,
  summary_note TEXT NOT NULL,
  service_specific_data JSONB NOT NULL DEFAULT '{}',
  pcsp_goals_addressed UUID[] NOT NULL DEFAULT '{}',
  evv_session_id UUID REFERENCES evv_sessions(id),
  status service_note_status NOT NULL DEFAULT 'draft',
  approved_by UUID REFERENCES staff(id),
  approved_at TIMESTAMPTZ,
  rejected_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.11 Incidents (SOW 1.27)
CREATE TABLE incidents (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id),
  reported_by_staff_id UUID NOT NULL REFERENCES staff(id),
  discovered_at TIMESTAMPTZ NOT NULL,
  upi_initiated_at TIMESTAMPTZ,
  guardian_notified_at TIMESTAMPTZ,
  guardian_notification_method notification_method,
  detailed_report_completed_at TIMESTAMPTZ,
  incident_type incident_type NOT NULL,
  severity incident_severity NOT NULL DEFAULT 'medium',
  description TEXT NOT NULL,
  detailed_report TEXT,
  prevention_strategies TEXT,
  follow_up_actions TEXT,
  status incident_status NOT NULL DEFAULT 'initiated',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.12 Compliance Alerts (generated by deadline engine)
CREATE TABLE compliance_alerts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  deadline_definition_id UUID REFERENCES compliance_deadline_definitions(id),
  related_entity_type VARCHAR(50),  -- 'staff', 'person', 'incident', etc.
  related_entity_id UUID,
  title VARCHAR(300) NOT NULL,
  description TEXT,
  due_at TIMESTAMPTZ NOT NULL,
  status alert_status NOT NULL DEFAULT 'pending',
  acknowledged_by UUID REFERENCES staff(id),
  acknowledged_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.13 Medications
CREATE TABLE medications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  medication_name VARCHAR(200) NOT NULL,
  purpose TEXT,
  dosage VARCHAR(100) NOT NULL,
  route VARCHAR(50) NOT NULL,
  schedule VARCHAR(200) NOT NULL,
  is_prn BOOLEAN NOT NULL DEFAULT false,
  is_controlled BOOLEAN NOT NULL DEFAULT false,  -- Schedule II-IV
  controlled_schedule VARCHAR(10),  -- II, III, IV
  prescriber_name VARCHAR(200),
  prescriber_phone VARCHAR(20),
  side_effects TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  start_date DATE,
  end_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.14 Medication Administrations (MAR entries)
CREATE TABLE medication_administrations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id),
  medication_id UUID NOT NULL REFERENCES medications(id),
  staff_id UUID NOT NULL REFERENCES staff(id),
  administered_at TIMESTAMPTZ NOT NULL,
  route VARCHAR(50) NOT NULL,
  prn_reason TEXT,  -- Required if medication.is_prn = true
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.15 Quarterly Summaries (SOW 1.25)
CREATE TABLE quarterly_summaries (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id),
  quarter_start DATE NOT NULL,
  quarter_end DATE NOT NULL,
  services_provided TEXT[] NOT NULL DEFAULT '{}',
  general_summary TEXT NOT NULL,
  goal_progress JSONB NOT NULL DEFAULT '[]',  -- [{goal_id, progress_text}]
  notable_events TEXT,
  author_staff_id UUID NOT NULL REFERENCES staff(id),
  submitted_to_sc_at TIMESTAMPTZ,
  ai_draft TEXT,  -- Claude-generated draft
  status VARCHAR(20) NOT NULL DEFAULT 'draft',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.16 Billing Claims
CREATE TABLE billing_claims (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id),
  service_code_id UUID NOT NULL REFERENCES service_code_definitions(id),
  authorization_id UUID REFERENCES person_service_authorizations(id),
  service_note_ids UUID[] NOT NULL DEFAULT '{}',
  claim_date DATE NOT NULL,
  total_units NUMERIC(8,2) NOT NULL,
  total_amount NUMERIC(10,2) NOT NULL,
  status claim_status NOT NULL DEFAULT 'draft',
  submitted_at TIMESTAMPTZ,
  response_at TIMESTAMPTZ,
  denial_reason TEXT,
  payment_amount NUMERIC(10,2),
  payment_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.17 Documents (uploaded files)
CREATE TABLE documents (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID REFERENCES persons(id),  -- NULL if org-level document
  document_type VARCHAR(50) NOT NULL,  -- pcsp, fba, bsp, legal, hrc_minutes, policy, etc.
  title VARCHAR(300) NOT NULL,
  storage_path TEXT NOT NULL,  -- Supabase Storage path
  file_size_bytes INTEGER,
  mime_type VARCHAR(100),
  uploaded_by UUID NOT NULL REFERENCES staff(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.18 Belongings Inventory (SOW 21.3(7), 31.3(3))
CREATE TABLE belongings_inventory (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  item_description VARCHAR(300) NOT NULL,
  estimated_value NUMERIC(10,2),
  is_significant_value BOOLEAN NOT NULL DEFAULT false,
  added_at DATE NOT NULL,
  discarded_at DATE,
  discard_reason TEXT,
  discard_signed_by VARCHAR(200),  -- Person or guardian signature
  inventoried_by UUID NOT NULL REFERENCES staff(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.19 Evacuation Drills (SOW 21.3(6))
CREATE TABLE evacuation_drills (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  site_name VARCHAR(200) NOT NULL,
  site_address VARCHAR(300),
  drill_date DATE NOT NULL,
  persons_present UUID[] NOT NULL DEFAULT '{}',
  staff_present UUID[] NOT NULL DEFAULT '{}',
  results TEXT,
  issues_noted TEXT,
  conducted_by UUID NOT NULL REFERENCES staff(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.20 Day Activity Absence Days (SOW 21.3(3))
CREATE TABLE day_activity_absence_days (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id),
  absence_date DATE NOT NULL,
  reason TEXT NOT NULL,
  els_billed BOOLEAN NOT NULL DEFAULT false,
  documented_by UUID NOT NULL REFERENCES staff(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.21 Person Staff Assignments
CREATE TABLE person_staff_assignments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  staff_id UUID NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  service_code_id UUID REFERENCES service_code_definitions(id),
  is_primary BOOLEAN NOT NULL DEFAULT false,
  start_date DATE NOT NULL DEFAULT CURRENT_DATE,
  end_date DATE,
  UNIQUE(org_id, person_id, staff_id, service_code_id)
);

-- 3.22 Org Sites (physical locations)
CREATE TABLE org_sites (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name VARCHAR(200) NOT NULL,
  address VARCHAR(300) NOT NULL,
  city VARCHAR(100),
  state VARCHAR(2) DEFAULT 'UT',
  zip VARCHAR(10),
  latitude NUMERIC(9,6),
  longitude NUMERIC(9,6),
  geofence_radius_meters INTEGER DEFAULT 150,  -- For EVV validation
  license_type VARCHAR(100),
  license_number VARCHAR(100),
  license_expiration DATE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.23 Audit Log (immutable)
CREATE TABLE audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id UUID NOT NULL,
  user_id UUID,
  action VARCHAR(20) NOT NULL,  -- INSERT, UPDATE, DELETE
  table_name VARCHAR(100) NOT NULL,
  record_id UUID NOT NULL,
  old_data JSONB,
  new_data JSONB,
  ip_address INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- 3B. CROSS-ORGANIZATION COLLABORATION
-- The Person is the center of the data model. Organizations are lenses.
-- A BC2 provider and an RHS provider can collaborate on a shared Person.
-- ============================================================================

-- 3.24 Org Partnerships (two orgs agree to collaborate)
CREATE TABLE org_partnerships (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  requesting_org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  receiving_org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending, active, revoked
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES staff(id),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(requesting_org_id, receiving_org_id),
  CHECK(requesting_org_id != receiving_org_id)
);

-- 3.25 Person Collaboration Links (scoped sharing per-Person, per-org-pair)
CREATE TABLE person_collaborations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  partnership_id UUID NOT NULL REFERENCES org_partnerships(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  -- Which org "owns" this person (has the primary service relationship)
  owner_org_id UUID NOT NULL REFERENCES organizations(id),
  -- Which org is being granted access
  collaborator_org_id UUID NOT NULL REFERENCES organizations(id),
  -- Granular permissions: what can the collaborator see?
  can_view_profile BOOLEAN NOT NULL DEFAULT true,
  can_view_service_notes BOOLEAN NOT NULL DEFAULT false,
  can_view_incidents BOOLEAN NOT NULL DEFAULT true,
  can_view_medications BOOLEAN NOT NULL DEFAULT true,
  can_view_bsp BOOLEAN NOT NULL DEFAULT true,      -- Behavior Support Plan
  can_view_pcsp_goals BOOLEAN NOT NULL DEFAULT true,
  can_view_quarterly_summaries BOOLEAN NOT NULL DEFAULT false,
  can_message BOOLEAN NOT NULL DEFAULT true,        -- Shared messaging channel
  -- Status
  is_active BOOLEAN NOT NULL DEFAULT true,
  activated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deactivated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(partnership_id, person_id, collaborator_org_id)
);

-- 3.26 Cross-Org Messages (shared channel scoped to a Person)
CREATE TABLE collaboration_messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  collaboration_id UUID NOT NULL REFERENCES person_collaborations(id) ON DELETE CASCADE,
  sender_org_id UUID NOT NULL REFERENCES organizations(id),
  sender_staff_id UUID NOT NULL REFERENCES staff(id),
  message_text TEXT NOT NULL,
  attachment_path TEXT,           -- Supabase Storage path
  is_urgent BOOLEAN NOT NULL DEFAULT false,
  read_by JSONB NOT NULL DEFAULT '[]',  -- [{staff_id, read_at}]
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3.27 Org Members (links auth.users to organizations with roles)
-- Supports multi-org: one user can belong to multiple orgs
CREATE TABLE org_members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  role user_role NOT NULL DEFAULT 'dsp',
  is_default_org BOOLEAN NOT NULL DEFAULT false,  -- Which org loads on login
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, org_id)
);

CREATE INDEX idx_org_members_user ON org_members(user_id);
CREATE INDEX idx_org_members_org ON org_members(org_id);

-- ============================================================================
-- 4. INDEXES (Performance)
-- ============================================================================
CREATE INDEX idx_staff_org ON staff(org_id);
CREATE INDEX idx_staff_active ON staff(org_id, is_active);
CREATE INDEX idx_staff_user ON staff(user_id);

CREATE INDEX idx_persons_org ON persons(org_id);
CREATE INDEX idx_persons_active ON persons(org_id, is_active);

CREATE INDEX idx_service_notes_org ON service_notes(org_id);
CREATE INDEX idx_service_notes_person ON service_notes(person_id, service_date);
CREATE INDEX idx_service_notes_staff ON service_notes(staff_id, service_date);
CREATE INDEX idx_service_notes_status ON service_notes(org_id, status);
CREATE INDEX idx_service_notes_date ON service_notes(org_id, service_date);

CREATE INDEX idx_evv_sessions_org ON evv_sessions(org_id);
CREATE INDEX idx_evv_sessions_staff ON evv_sessions(staff_id, clock_in_at);

CREATE INDEX idx_incidents_org ON incidents(org_id);
CREATE INDEX idx_incidents_status ON incidents(org_id, status);
CREATE INDEX idx_incidents_person ON incidents(person_id);

CREATE INDEX idx_staff_trainings_staff ON staff_trainings(staff_id);
CREATE INDEX idx_staff_trainings_expires ON staff_trainings(expires_at);

CREATE INDEX idx_authorizations_person ON person_service_authorizations(person_id);
CREATE INDEX idx_authorizations_status ON person_service_authorizations(org_id, status);

CREATE INDEX idx_compliance_alerts_org ON compliance_alerts(org_id, status);
CREATE INDEX idx_compliance_alerts_due ON compliance_alerts(due_at);

CREATE INDEX idx_medications_person ON medications(person_id, is_active);
CREATE INDEX idx_med_admin_person ON medication_administrations(person_id, administered_at);

CREATE INDEX idx_billing_claims_org ON billing_claims(org_id, status);
CREATE INDEX idx_audit_log_org ON audit_log(org_id, created_at);
CREATE INDEX idx_audit_log_record ON audit_log(table_name, record_id);

-- Cross-org collaboration indexes
CREATE INDEX idx_partnerships_requesting ON org_partnerships(requesting_org_id, status);
CREATE INDEX idx_partnerships_receiving ON org_partnerships(receiving_org_id, status);
CREATE INDEX idx_person_collabs_person ON person_collaborations(person_id);
CREATE INDEX idx_person_collabs_owner ON person_collaborations(owner_org_id);
CREATE INDEX idx_person_collabs_collaborator ON person_collaborations(collaborator_org_id);
CREATE INDEX idx_collab_messages_collab ON collaboration_messages(collaboration_id, created_at);
CREATE INDEX idx_collab_messages_sender ON collaboration_messages(sender_org_id);

-- ============================================================================
-- 5. ROW LEVEL SECURITY (Multi-tenant isolation)
-- ============================================================================

-- Enable RLS on all tenant-scoped tables
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_service_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_trainings ENABLE ROW LEVEL SECURITY;
ALTER TABLE persons ENABLE ROW LEVEL SECURITY;
ALTER TABLE person_service_authorizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE pcsp_goals ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_strategies ENABLE ROW LEVEL SECURITY;
ALTER TABLE evv_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE service_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE medication_administrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE quarterly_summaries ENABLE ROW LEVEL SECURITY;
ALTER TABLE billing_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE belongings_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE evacuation_drills ENABLE ROW LEVEL SECURITY;
ALTER TABLE day_activity_absence_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE person_staff_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_sites ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- Cross-org collaboration tables
ALTER TABLE org_partnerships ENABLE ROW LEVEL SECURITY;
ALTER TABLE person_collaborations ENABLE ROW LEVEL SECURITY;
ALTER TABLE collaboration_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_members ENABLE ROW LEVEL SECURITY;

-- Helper function: extract org_id from JWT
CREATE OR REPLACE FUNCTION auth.org_id()
RETURNS UUID AS $$
  SELECT COALESCE(
    (current_setting('request.jwt.claims', true)::jsonb ->> 'org_id')::uuid,
    (current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'org_id')::uuid
  );
$$ LANGUAGE sql STABLE;

-- RLS Policies: Each tenant can only see their own data
-- Pattern: SELECT/INSERT/UPDATE/DELETE where org_id = auth.org_id()

-- Organizations: users can only see their own org
CREATE POLICY "org_select" ON organizations FOR SELECT USING (id = auth.org_id());
CREATE POLICY "org_update" ON organizations FOR UPDATE USING (id = auth.org_id());

-- Generic tenant isolation policy for all other tables
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'org_service_codes', 'staff', 'staff_trainings', 'persons',
    'person_service_authorizations', 'pcsp_goals', 'support_strategies',
    'evv_sessions', 'service_notes', 'incidents', 'compliance_alerts',
    'medications', 'medication_administrations', 'quarterly_summaries',
    'billing_claims', 'documents', 'belongings_inventory',
    'evacuation_drills', 'day_activity_absence_days',
    'person_staff_assignments', 'org_sites', 'audit_log'
  ]
  LOOP
    EXECUTE format('CREATE POLICY "%s_select" ON %I FOR SELECT USING (org_id = auth.org_id())', t, t);
    EXECUTE format('CREATE POLICY "%s_insert" ON %I FOR INSERT WITH CHECK (org_id = auth.org_id())', t, t);
    EXECUTE format('CREATE POLICY "%s_update" ON %I FOR UPDATE USING (org_id = auth.org_id())', t, t);
    EXECUTE format('CREATE POLICY "%s_delete" ON %I FOR DELETE USING (org_id = auth.org_id())', t, t);
  END LOOP;
END $$;

-- System reference tables are readable by everyone (no RLS needed, or public SELECT)
-- service_code_definitions, training_topic_definitions, compliance_deadline_definitions
-- are NOT RLS-enabled, so they're readable by all authenticated users.

-- Cross-org collaboration RLS (both partner orgs need access)

-- Org Partnerships: both requesting and receiving org can see
CREATE POLICY "partnerships_select" ON org_partnerships FOR SELECT
  USING (requesting_org_id = auth.org_id() OR receiving_org_id = auth.org_id());
CREATE POLICY "partnerships_insert" ON org_partnerships FOR INSERT
  WITH CHECK (requesting_org_id = auth.org_id());
CREATE POLICY "partnerships_update" ON org_partnerships FOR UPDATE
  USING (requesting_org_id = auth.org_id() OR receiving_org_id = auth.org_id());

-- Person Collaborations: owner and collaborator can see
CREATE POLICY "person_collabs_select" ON person_collaborations FOR SELECT
  USING (owner_org_id = auth.org_id() OR collaborator_org_id = auth.org_id());
CREATE POLICY "person_collabs_insert" ON person_collaborations FOR INSERT
  WITH CHECK (owner_org_id = auth.org_id());
CREATE POLICY "person_collabs_update" ON person_collaborations FOR UPDATE
  USING (owner_org_id = auth.org_id());

-- Collaboration Messages: both partner orgs can read and send
CREATE POLICY "collab_messages_select" ON collaboration_messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM person_collaborations pc
      WHERE pc.id = collaboration_messages.collaboration_id
        AND (pc.owner_org_id = auth.org_id() OR pc.collaborator_org_id = auth.org_id())
        AND pc.is_active = true
    )
  );
CREATE POLICY "collab_messages_insert" ON collaboration_messages FOR INSERT
  WITH CHECK (sender_org_id = auth.org_id());

-- Org Members: users can see their own memberships
CREATE POLICY "org_members_select" ON org_members FOR SELECT
  USING (user_id = auth.uid() OR org_id = auth.org_id());
CREATE POLICY "org_members_insert" ON org_members FOR INSERT
  WITH CHECK (org_id = auth.org_id());
CREATE POLICY "org_members_update" ON org_members FOR UPDATE
  USING (org_id = auth.org_id());
CREATE POLICY "org_members_delete" ON org_members FOR DELETE
  USING (org_id = auth.org_id());

-- ============================================================================
-- 6. FUNCTIONS & TRIGGERS
-- ============================================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all tables with updated_at
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'organizations', 'staff', 'persons', 'person_service_authorizations',
    'pcsp_goals', 'support_strategies', 'service_notes', 'incidents',
    'quarterly_summaries', 'billing_claims', 'medications',
    'belongings_inventory', 'org_sites',
    'org_partnerships', 'person_collaborations'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER %s_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION update_updated_at()',
      t, t
    );
  END LOOP;
END $$;

-- Calculate billable units from duration
CREATE OR REPLACE FUNCTION calculate_billable_units(
  p_service_code VARCHAR(6),
  p_duration_minutes INTEGER
) RETURNS NUMERIC(6,2) AS $$
DECLARE
  v_unit billing_unit_type;
  v_threshold NUMERIC;
BEGIN
  SELECT billing_unit, daily_rate_threshold_hours
  INTO v_unit, v_threshold
  FROM service_code_definitions
  WHERE code = p_service_code;

  CASE v_unit
    WHEN 'quarter_hour' THEN
      RETURN CEIL(p_duration_minutes / 15.0);
    WHEN 'daily' THEN
      -- Check threshold (e.g., COM: daily rate if > 6 hours)
      IF v_threshold IS NOT NULL AND p_duration_minutes > (v_threshold * 60) THEN
        RETURN 1;  -- Daily rate
      ELSE
        RETURN CEIL(p_duration_minutes / 15.0);  -- Quarter hour fallback
      END IF;
    WHEN 'per_trip' THEN
      RETURN 1;
    WHEN 'per_session' THEN
      RETURN 1;
    WHEN 'hourly' THEN
      RETURN CEIL(p_duration_minutes / 60.0);
    ELSE
      RETURN CEIL(p_duration_minutes / 15.0);
  END CASE;
END;
$$ LANGUAGE plpgsql STABLE;

-- Update used_units on authorization when service note is approved
CREATE OR REPLACE FUNCTION update_authorization_units()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'approved' AND NEW.authorization_id IS NOT NULL THEN
    UPDATE person_service_authorizations
    SET used_units = (
      SELECT COALESCE(SUM(billable_units), 0)
      FROM service_notes
      WHERE authorization_id = NEW.authorization_id
        AND status IN ('approved', 'billed')
    )
    WHERE id = NEW.authorization_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER service_note_auth_update
  AFTER INSERT OR UPDATE ON service_notes
  FOR EACH ROW EXECUTE FUNCTION update_authorization_units();

-- ============================================================================
-- 7. SEED DATA: Service Code Definitions (33 DSPD codes)
-- ============================================================================
INSERT INTO service_code_definitions (code, name, sow_article, billing_unit, evv_required, daily_rate_threshold_hours, max_units_per_day, max_weekly_hours, requires_support_strategy, requires_quarterly_summary, description, outcome_measure) VALUES
('BC1', 'Behavior Consultation I', 3, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Support for Persons with mild behavior problems. Develops behavior interventions to increase community integration.', '% of Persons with decrease in target problem behaviors'),
('BC2', 'Behavior Consultation II', 4, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Support for Persons with serious, non-life-threatening behavior.', '% of Persons with decrease in target problem behaviors'),
('BC3', 'Behavior Consultation III', 5, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Support for Persons with extremely complex or dangerous behavior.', '% of Persons with decrease in target problem behaviors'),
('COM', 'Companion Service', 6, 'quarter_hour', true, 6, NULL, NULL, true, true, 'One-on-one non-medical care, support, socialization, and supervision.', '% of Persons who remained in HCBS'),
('DSG', 'Day Support - Group', 7, 'daily', false, NULL, NULL, NULL, true, true, 'Safe, non-residential habilitation group services.', '% engaged in social opportunities; % skills maintained/improved; % satisfied'),
('DSP', 'Day Support - Partial', 7, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Partial-day non-residential habilitation services.', '% engaged in social opportunities; % skills maintained/improved; % satisfied'),
('DSI', 'Day Support - Individual', 8, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Individual non-residential habilitation services.', '% engaged in social opportunities; % skills maintained/improved; % satisfied'),
('EPR', 'Employment Preparation Services', 9, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Pre-employment skills training for competitive integrated employment.', '% worked on pre-employment skills; % moved to Competitive Integrated Employment'),
('ELS', 'Extended Living Supports', 10, 'quarter_hour', false, NULL, 24, NULL, false, true, 'Additional support when Person does not attend normal day activities.', '% of times Person needing ELS was able to use it; % of incident reports during ELS'),
('HHS', 'Host Home Supports', 11, 'daily', false, NULL, NULL, NULL, true, true, 'Community-integrated shared living with trained host family.', '% of Persons who remained in community-based living setting'),
('HSQ', 'Homemaker', 12, 'quarter_hour', true, NULL, NULL, NULL, true, true, 'Assistance with household tasks.', '% of Persons satisfied with homemaker activities'),
('MTP', 'Motor Transportation Payment', 13, 'per_trip', false, NULL, NULL, NULL, false, true, 'Transportation for Persons to/from activities.', '% transported safely, on time, to correct destinations'),
('PAC', 'Personal Assistance Services', 14, 'quarter_hour', true, 6, NULL, NULL, true, true, 'Support for ADL specific to assessed needs.', '% who remained living in community setting'),
('PBA', 'Personal Budget Assistance', 15, 'quarter_hour', false, NULL, NULL, NULL, true, false, 'Support with personal finances and budgeting.', 'Monthly financial statements replace quarterly summaries'),
('PM1', 'Professional Medication Monitoring (LPN)', 16, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Medication management by Licensed Practical Nurse.', '% of Persons without medication errors'),
('PM2', 'Professional Medication Monitoring (RN)', 17, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Medication management by Registered Nurse.', '% of Persons without medication errors'),
('PN1', 'Professional Nursing Services I', 18, 'daily', false, NULL, NULL, NULL, true, false, 'Medical care plan oversight. Develops Medical Care Plans.', '% who remained in community-based setting'),
('PN2', 'Professional Nursing Services II', 19, 'daily', false, NULL, NULL, NULL, true, false, 'Hands-on skilled nursing services.', '% who remained in community-based setting'),
('PPS', 'Professional Parent Supports', 20, 'daily', false, NULL, NULL, NULL, true, true, 'Family-based living for Persons under 22.', '% who remained in community-based living setting'),
('RHS', 'Residential Habilitation Supports', 21, 'daily', false, NULL, NULL, NULL, true, true, 'Skilled residential assistance in community settings.', '% who remained in community-based living setting'),
('RP2', 'Routine Respite (No Room & Board)', 22, 'quarter_hour', true, 6, NULL, NULL, false, false, 'Temporary caregiver relief. No room and board.', 'Respite outcome measures per annual report'),
('RP3', 'Exceptional Care Respite (No Room & Board)', 23, 'quarter_hour', true, 6, NULL, NULL, false, false, 'Exceptional care temporary relief. No room and board.', 'Respite outcome measures per annual report'),
('RP4', 'Routine Respite (With Room & Board)', 24, 'daily', false, NULL, NULL, NULL, false, false, 'Overnight temporary relief with room and board.', 'Respite outcome measures per annual report'),
('RP5', 'Exceptional Care Respite (With Room & Board)', 25, 'daily', false, NULL, NULL, NULL, false, false, 'Overnight exceptional care with room and board.', 'Respite outcome measures per annual report'),
('RPS', 'Respite Camp Session', 26, 'per_session', false, NULL, NULL, NULL, false, false, 'Camp program providing temporary relief.', 'Respite outcome measures per annual report'),
('SEC', 'Supported Employment - Co-Worker', 27, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Support in competitive integrated employment with co-worker.', '% in competitive integrated employment; % with job retention'),
('SED', 'Supported Employment - Group', 28, 'daily', false, NULL, NULL, NULL, true, true, 'Support for workgroups in community employment.', '% in competitive integrated employment; % with job retention'),
('SEE', 'Supported Employment Enterprise', 29, 'daily', false, NULL, NULL, NULL, true, true, 'Contractor-operated employment enterprise.', '% in competitive integrated employment; % with job retention'),
('SEI', 'Supported Employment - Individual', 30, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Individual support in competitive integrated employment.', '% in competitive integrated employment; % with wage progression'),
('SLH', 'Supported Living - Quarter Hour', 31, 'quarter_hour', true, NULL, NULL, NULL, true, true, 'One-on-one support. Contractor primarily responsible for health/safety.', '% who remained in community-based living setting'),
('SLN', 'Supported Living - Natural', 32, 'quarter_hour', true, NULL, NULL, NULL, true, true, 'One-on-one support. Contractor NOT primarily responsible for health/safety.', '% who remained in community-based living setting'),
('CMP', 'Supported Living - Parent/Guardian', 31, 'quarter_hour', true, NULL, NULL, 40, true, true, 'Supported Living by parent, step-parent, or legal guardian.', '% who remained in community-based living setting'),
('CMS', 'Supported Living - Spouse', 31, 'quarter_hour', true, NULL, NULL, 40, true, true, 'Supported Living by spouse.', '% who remained in community-based living setting'),
('TFB', 'Family & Individual Training and Preparation', 33, 'quarter_hour', false, NULL, NULL, NULL, true, true, 'Coaching for Persons and Immediate Relatives.', '% who remained in community-based living setting');

-- ============================================================================
-- 8. SEED DATA: Training Topic Definitions (SOW 1.8)
-- ============================================================================
INSERT INTO training_topic_definitions (sow_reference, topic_name, category, deadline_days, requires_certification, renewal_months) VALUES
-- 30-day topics (SOW 1.8(4))
('1.8(4)(A)', 'When to call 911', '30_day', 30, false, NULL),
('1.8(4)(B)', 'When to call a medical professional', '30_day', 30, false, NULL),
('1.8(4)(C)', 'Incident reporting', '30_day', 30, false, NULL),
('1.8(4)(D)', 'Seizure disorders - basic orientation', '30_day', 30, false, NULL),
('1.8(4)(E)', 'Missing person notification procedures', '30_day', 30, false, NULL),
('1.8(4)(F)', 'Choking rescue maneuvers (Heimlich)', '30_day', 30, false, NULL),
('1.8(4)(G)', 'Choking prevention', '30_day', 30, false, NULL),
('1.8(4)(H)', 'Positive behavior supports per R539-4', '30_day', 30, false, NULL),
('1.8(4)(I)', 'Legal rights of Persons and ADA', '30_day', 30, false, NULL),
('1.8(4)(J)', 'Abuse, neglect, exploitation prevention and reporting', '30_day', 30, false, NULL),
('1.8(4)(K)', 'Confidentiality and HIPAA', '30_day', 30, false, NULL),
('1.8(4)(L)', 'Orientation to ID.RC and ABI', '30_day', 30, false, NULL),
('1.8(4)(M)', 'Prevention of communicable diseases', '30_day', 30, false, NULL),
('1.8(4)(N)', 'Person-specific training', '30_day', 30, false, NULL),
('1.8(4)(O)', 'Contractor policies and procedures', '30_day', 30, false, NULL),
('1.8(4)(P)', 'DSPD philosophy, mission, and beliefs', '30_day', 30, false, NULL),
('1.8(4)(Q)', 'DHHS Medicaid 101 training (applicable portions)', '30_day', 30, false, NULL),
-- 90-day topics (SOW 1.8(5))
('1.8(5)(A)', 'First Aid certification', '90_day', 90, true, 24),
('1.8(5)(B)', 'CPR certification', '90_day', 90, true, 24),
('1.8(5)(C)', 'Person-Centered thinking and practices', '90_day', 90, false, NULL),
-- 180-day topics (SOW 1.8(6))
('1.8(6)', 'Crisis intervention (SOAR/MANDT/PART/CPI/Safety Care)', '180_day', 180, true, 12),
-- ABI-specific (SOW 1.8(8))
('1.8(8)(A)', 'Effects of brain injuries on behavior', 'abi', NULL, false, NULL),
('1.8(8)(B)', 'Transitioning from hospitals to community programs', 'abi', NULL, false, NULL),
('1.8(8)(C)', 'Functional impact of brain injury', 'abi', NULL, false, NULL),
('1.8(8)(D)', 'Health and medication effects for ABI', 'abi', NULL, false, NULL),
('1.8(8)(E)', 'Role of direct-care Staff in treatment/rehabilitation', 'abi', NULL, false, NULL),
('1.8(8)(F)', 'Family perspective on brain injury', 'abi', NULL, false, NULL);

-- ============================================================================
-- SCHEMA COMPLETE
-- Provly v2.0 - With cross-org collaboration layer
-- 30 tables | 33 service codes | 27 training topics | Full RLS
-- Ready for deployment to Supabase
-- ============================================================================
