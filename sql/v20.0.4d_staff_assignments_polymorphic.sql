-- v20.0.4d — assignments become polymorphic: site XOR person edges (D1 / D1-R)
--
-- GUARD before running: Ctrl+F the app file for 'person_staff_assignments'.
--   0 hits  -> run this whole file.
--   Any hit -> delete the RENAME line, run the rest, and tell Claude.
-- (A rename preserves the table's existing RLS policies, indexes, and FKs.)

ALTER TABLE person_staff_assignments RENAME TO staff_assignments;

ALTER TABLE staff_assignments
  ADD COLUMN site_id uuid REFERENCES org_sites(id),
  ALTER COLUMN person_id DROP NOT NULL,
  ALTER COLUMN is_primary SET DEFAULT false;

-- exactly one target per edge: a site OR a person, never both, never neither
ALTER TABLE staff_assignments
  ADD CONSTRAINT staff_assignments_target_xor
    CHECK (num_nonnulls(person_id, site_id) = 1);

-- no duplicate ACTIVE edges; history accumulates freely
CREATE UNIQUE INDEX IF NOT EXISTS staff_assignments_active_person_uniq
  ON staff_assignments (staff_id, person_id)
  WHERE end_date IS NULL AND person_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS staff_assignments_active_site_uniq
  ON staff_assignments (staff_id, site_id)
  WHERE end_date IS NULL AND site_id IS NOT NULL;
