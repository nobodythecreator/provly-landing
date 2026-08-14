-- v20.0.4f — org_units: Site/Facility tree nodes REFERENCE the facility
-- source of truth instead of rivaling it (G1-R, option B)
--
-- PREDICATE NOTE (post-review): the ILIKE below is broader than it should
-- have been. At run time it matched exactly one node — verified by the
-- SELECT that precedes it — so live state is correct; v20.0.4g pins the
-- link to the exact node id and clears any hypothetical stray match.

ALTER TABLE org_units ADD COLUMN site_id uuid REFERENCES org_sites(id);

-- eyeball the node first:
SELECT id, name, unit_type FROM org_units WHERE name ILIKE '%cranston%';

-- then link the Cranstonhall tree node to the real West Jordan site row:
UPDATE org_units
   SET site_id = '8b7ef2ed-dfa1-47a2-b5e0-fc3d34195260'
 WHERE name ILIKE '%cranston%';
