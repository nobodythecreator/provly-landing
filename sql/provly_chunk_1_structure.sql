-- ============================================================================
-- PROVLY MIGRATION - CHUNK 1 of 3: STRUCTURE
-- Extensions, Enums, All 27 Tables (system + tenant + cross-org)
-- Run this FIRST in Supabase SQL Editor
-- ============================================================================

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

