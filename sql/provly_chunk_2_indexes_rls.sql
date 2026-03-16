-- ============================================================================
-- PROVLY MIGRATION - CHUNK 2 of 3: INDEXES + ROW LEVEL SECURITY
-- Performance indexes, RLS policies, auth.org_id() helper
-- Run this SECOND after Chunk 1 succeeds
-- ============================================================================

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

