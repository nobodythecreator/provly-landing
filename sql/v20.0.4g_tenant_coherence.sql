-- v20.0.4g — tenant coherence: composite FKs + exact facility-link pin
-- (Greptile round 1, both findings accepted)
--
-- WHY: Postgres validates foreign keys as the table owner — RLS does NOT
-- apply to FK integrity checks. A single-column FK therefore lets a row in
-- org A reference a person/site/staff belonging to org B. Worse than the
-- data smell: person_placements_one_active is a GLOBAL partial unique on
-- (person_id), so a cross-org row referencing org B's person would occupy
-- that person's one-active slot and block org B from placing their own
-- individual — a cross-tenant denial they cannot even see under RLS.
-- The declarative cure: bind every reference to (id, org_id) pairs.
--
-- Both affected tables are empty (no placement/assignment UI has shipped),
-- so these constraints validate instantly.

-- Parent targets: (id, org_id) unique indexes. id alone is already the PK,
-- so these are cheap and always true — they exist to satisfy the FK targets.
CREATE UNIQUE INDEX IF NOT EXISTS persons_id_org_uniq   ON persons (id, org_id);
CREATE UNIQUE INDEX IF NOT EXISTS org_sites_id_org_uniq ON org_sites (id, org_id);
CREATE UNIQUE INDEX IF NOT EXISTS staff_id_org_uniq     ON staff (id, org_id);

-- person_placements: replace this release's single-column FKs with
-- tenant-bound composites (constraint names are v20.0.4e's defaults).
ALTER TABLE person_placements
  DROP CONSTRAINT IF EXISTS person_placements_person_id_fkey,
  DROP CONSTRAINT IF EXISTS person_placements_site_id_fkey,
  DROP CONSTRAINT IF EXISTS person_placements_created_by_fkey;

ALTER TABLE person_placements
  ADD CONSTRAINT person_placements_person_org_fk
    FOREIGN KEY (person_id, org_id)  REFERENCES persons (id, org_id),
  ADD CONSTRAINT person_placements_site_org_fk
    FOREIGN KEY (site_id, org_id)    REFERENCES org_sites (id, org_id),
  -- created_by is nullable; MATCH SIMPLE skips the check when it's NULL
  ADD CONSTRAINT person_placements_creator_org_fk
    FOREIGN KEY (created_by, org_id) REFERENCES staff (id, org_id);

-- staff_assignments: same class of hole (scaffold-era single-column FKs plus
-- v20.0.4d's site_id FK). Legacy constraint names are unverified, so this is
-- ADDITIVE — composites enforce tenant binding alongside whatever exists;
-- redundant FKs are harmless.
ALTER TABLE staff_assignments
  ADD CONSTRAINT staff_assignments_staff_org_fk
    FOREIGN KEY (staff_id, org_id)  REFERENCES staff (id, org_id),
  ADD CONSTRAINT staff_assignments_person_org_fk
    FOREIGN KEY (person_id, org_id) REFERENCES persons (id, org_id),
  ADD CONSTRAINT staff_assignments_site_org_fk
    FOREIGN KEY (site_id, org_id)   REFERENCES org_sites (id, org_id);

-- Facility-link pin (Greptile finding 2): v20.0.4f's ILIKE predicate was
-- broad. It matched exactly one node when run (verified by its preceding
-- SELECT), so live state is correct — this makes it provably exact and
-- clears any hypothetical stray link, keyed to the known node id.
UPDATE org_units SET site_id = NULL
 WHERE site_id = '8b7ef2ed-dfa1-47a2-b5e0-fc3d34195260'
   AND id <> '19556359-2c83-4a5b-af3a-73ac6601fc8d';

UPDATE org_units SET site_id = '8b7ef2ed-dfa1-47a2-b5e0-fc3d34195260'
 WHERE id = '19556359-2c83-4a5b-af3a-73ac6601fc8d'
   AND unit_type = 'site';
