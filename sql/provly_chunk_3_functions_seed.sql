-- ============================================================================
-- PROVLY MIGRATION - CHUNK 3 of 3: FUNCTIONS + SEED DATA
-- Triggers, billable unit calculator, 33 service codes, 27 training topics
-- Run this THIRD after Chunk 2 succeeds
-- ============================================================================

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
