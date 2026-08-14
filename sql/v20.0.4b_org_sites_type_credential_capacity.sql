-- v20.0.4b — org_sites: service typology, credential class, capacity (D2/D3)
--
-- GUARD before running: Ctrl+F the app file for 'license_type'.
--   0 hits  -> run this whole file.
--   Any hit -> delete the RENAME line below, run the rest, and tell Claude
--              (the app pass will then keep the original column name).

CREATE TYPE site_type AS ENUM ('rhs', 'hhs');

ALTER TABLE org_sites
  ADD COLUMN site_type site_type,
  ADD COLUMN capacity  smallint;

-- repurpose the never-populated license_type varchar as the credential class
ALTER TABLE org_sites RENAME COLUMN license_type TO credential_type;

ALTER TABLE org_sites
  ADD CONSTRAINT org_sites_credential_values
    CHECK (credential_type IS NULL OR credential_type IN ('certified','licensed')),
  -- statute: a host home ceiling is 2, and an HHS site may never lack one
  ADD CONSTRAINT org_sites_hhs_capacity
    CHECK (site_type IS DISTINCT FROM 'hhs' OR (capacity IS NOT NULL AND capacity <= 2)),
  -- rule: a certified site's ceiling never exceeds 3
  ADD CONSTRAINT org_sites_certified_capacity
    CHECK (credential_type IS DISTINCT FROM 'certified' OR capacity <= 3);

-- backfill the one existing real site (G2): Cranstonhall = certified RHS, ceiling 3
UPDATE org_sites
   SET site_type = 'rhs',
       credential_type = 'certified',
       capacity = 3
 WHERE id = '8b7ef2ed-dfa1-47a2-b5e0-fc3d34195260';
