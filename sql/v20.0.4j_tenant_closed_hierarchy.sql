-- v20.0.4j — the org tree becomes tenant-closed (Greptile app round 3,
-- finding accepted)
--
-- THE HOLE: save_site_unit's creation path wrote the caller-supplied
-- p_parent_id unchecked, so a caller could attach their own-org node beneath
-- ANOTHER org's unit. The row itself stays in the caller's org (RLS hides it
-- from the victim), but the cross-org edge is real — and it recreates the
-- g-class denial: the victim's later attempt to delete their unit fails on an
-- FK child they cannot see or diagnose. The same weakness exists on the
-- DIRECT insert path (RLS with_check validates the new row's org_id, never
-- parent_id's org), so an RPC-only patch would be half a fix.
--
-- THE FIX, both layers, every path:
--   LAYER 1 — schema truth: composite FK (parent_id, org_id) →
--   org_units (id, org_id). A cross-org parent becomes IMPOSSIBLE for the
--   RPC, the app's direct inserts, and any future code — and the journal now
--   carries the authoritative hierarchy constraint it previously lacked.
--   LAYER 2 — the RPC gates the parent explicitly for a friendly error
--   before the constraint's blunt one.
--
-- Adding the constraint validates existing rows: it should pass instantly
-- (the UI has only ever offered same-org parents). If it ever failed, that
-- failure would itself be the discovery of a real cross-org row to clean.

-- ── LAYER 1: tenant-closed hierarchy ─────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS org_units_id_org_uniq ON org_units (id, org_id);

ALTER TABLE org_units
  ADD CONSTRAINT org_units_parent_org_fk
  FOREIGN KEY (parent_id, org_id) REFERENCES org_units (id, org_id);
  -- parent_id is nullable; MATCH SIMPLE skips the check for root nodes.

-- ── LAYER 2: explicit parent ownership gate in the creation path ─────

CREATE OR REPLACE FUNCTION save_site_unit(
  p_unit_id            uuid,
  p_parent_id          uuid,
  p_name               text,
  p_address            text,
  p_city               text,
  p_site_type          site_type,
  p_credential         text,
  p_capacity           smallint,
  p_license_number     text,
  p_license_expiration date
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_site uuid;
  v_unit uuid;
  v_cap  smallint;
BEGIN
  IF p_name IS NULL OR p_name = '' THEN RAISE EXCEPTION 'Name is required'; END IF;
  IF p_address IS NULL OR p_address = '' THEN RAISE EXCEPTION 'Street address is required for a Site / Facility'; END IF;
  IF p_site_type IS NULL THEN RAISE EXCEPTION 'Choose the site type — RHS or Host Home (HHS)'; END IF;
  IF p_site_type = 'rhs' AND (p_credential IS NULL OR p_credential = '')
    THEN RAISE EXCEPTION 'Choose the RHS credential class — Certified or Licensed'; END IF;

  v_cap := CASE
    WHEN p_site_type = 'hhs' THEN 2
    WHEN p_credential = 'certified' THEN 3
    ELSE p_capacity
  END;
  IF p_site_type = 'rhs' AND p_credential = 'licensed' AND (v_cap IS NULL OR v_cap < 1)
    THEN RAISE EXCEPTION 'Enter the licensed capacity from the license itself (typically 4+)'; END IF;

  IF p_unit_id IS NULL THEN
    -- v20.0.4j — the parent must be the caller's own (a foreign parent id is
    -- indistinguishable from a missing one)
    IF p_parent_id IS NOT NULL THEN
      PERFORM 1 FROM org_units WHERE id = p_parent_id AND org_id = org_id();
      IF NOT FOUND THEN RAISE EXCEPTION 'Parent unit not found'; END IF;
    END IF;

    INSERT INTO org_sites (org_id, name, address, city, site_type, credential_type,
                           capacity, license_number, license_expiration, is_active)
    VALUES (org_id(), p_name, p_address, p_city, p_site_type, NULLIF(p_credential, ''),
            v_cap, NULLIF(p_license_number, ''), p_license_expiration, true)
    RETURNING id INTO v_site;

    INSERT INTO org_units (org_id, parent_id, name, unit_type, address, city, site_id)
    VALUES (org_id(), p_parent_id, p_name, 'site', p_address, p_city, v_site)
    RETURNING id INTO v_unit;
  ELSE
    SELECT site_id INTO v_site FROM org_units
     WHERE id = p_unit_id AND org_id = org_id();
    IF NOT FOUND THEN RAISE EXCEPTION 'Unit not found'; END IF;

    IF v_site IS NULL THEN
      INSERT INTO org_sites (org_id, name, address, city, site_type, credential_type,
                             capacity, license_number, license_expiration, is_active)
      VALUES (org_id(), p_name, p_address, p_city, p_site_type, NULLIF(p_credential, ''),
              v_cap, NULLIF(p_license_number, ''), p_license_expiration, true)
      RETURNING id INTO v_site;
    ELSE
      UPDATE org_sites
         SET name = p_name, address = p_address, city = p_city,
             site_type = p_site_type, credential_type = NULLIF(p_credential, ''),
             capacity = v_cap, license_number = NULLIF(p_license_number, ''),
             license_expiration = p_license_expiration
       WHERE id = v_site AND org_id = org_id();
    END IF;

    UPDATE org_units
       SET name = p_name, address = p_address, city = p_city, site_id = v_site
     WHERE id = p_unit_id AND org_id = org_id();
    v_unit := p_unit_id;
  END IF;

  RETURN v_unit;
END $$;
