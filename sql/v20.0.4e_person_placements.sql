-- v20.0.4e — person_placements: who lives where, as history (G1-R)
--
-- HARDENED IN v20.0.4g (post-review): the single-column FKs below were
-- replaced with tenant-bound composite FKs — (person_id, org_id),
-- (site_id, org_id), (created_by, org_id) — because Postgres FK checks
-- bypass RLS and could otherwise reference rows across orgs. This file is
-- the journal of what ran on Aug 10; g is the journal of the fix.
--
-- FINALIZED (Aug 10): the policies below match the app's existing org-tenancy
-- dialect observed via pg_policies — flat (org_id = org_id()) on all four
-- commands, identical to persons / staff / org_sites.

CREATE TABLE person_placements (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  person_id   uuid NOT NULL REFERENCES persons(id),
  site_id     uuid NOT NULL REFERENCES org_sites(id),
  start_date  date NOT NULL,
  end_date    date,          -- NULL = current residence
  reason      text,
  created_by  uuid REFERENCES staff(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT person_placements_dates CHECK (end_date IS NULL OR end_date >= start_date)
);

-- coherence (regime 2): one ACTIVE residence per person — two at once is
-- nonsense, not reality, so the database refuses it
CREATE UNIQUE INDEX person_placements_one_active
  ON person_placements (person_id) WHERE end_date IS NULL;

-- census reads: active placements per site
CREATE INDEX person_placements_active_site
  ON person_placements (site_id) WHERE end_date IS NULL;

ALTER TABLE person_placements ENABLE ROW LEVEL SECURITY;

-- house pattern: four commands, flat org tenancy, names {table}_{cmd}
CREATE POLICY person_placements_select ON person_placements
  FOR SELECT USING (org_id = org_id());

CREATE POLICY person_placements_insert ON person_placements
  FOR INSERT WITH CHECK (org_id = org_id());

CREATE POLICY person_placements_update ON person_placements
  FOR UPDATE USING (org_id = org_id());

-- delete exists for mistake-correction only (a fat-fingered placement never
-- happened — removing it is coherence, not history erasure); the UI will
-- expose end-placement, never delete
CREATE POLICY person_placements_delete ON person_placements
  FOR DELETE USING (org_id = org_id());
