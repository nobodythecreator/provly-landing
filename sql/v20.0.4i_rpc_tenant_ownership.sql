-- v20.0.4i — tenant ownership enforced INSIDE the workflow RPCs + RLS
-- convergence for the two never-verified tables (Greptile app round 2,
-- finding accepted)
--
-- WHY: the h functions relied on table RLS for tenant scoping. That guard is
-- only real where RLS is enabled with org policies — a property this journal
-- never established for org_units (pre-v20.0.4 scaffold) or staff_assignments
-- (the renamed scaffold table). Two-layer fix, safe in every world:
--
--   LAYER 1 — both tables converge on the house RLS pattern (idempotent:
--   enable + drop-if-exists/create the standard four org policies).
--
--   LAYER 2 — the three RPCs now enforce ownership EXPLICITLY: every lookup
--   and every write predicates on org_id = org_id(), so a foreign unit, site,
--   or person id fails with 'not found' BEFORE any write — independent of
--   table RLS. Signatures unchanged; no app change required.

-- ── LAYER 1: RLS convergence ─────────────────────────────────────────

ALTER TABLE org_units ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_units_select ON org_units;
CREATE POLICY org_units_select ON org_units FOR SELECT USING (org_id = org_id());
DROP POLICY IF EXISTS org_units_insert ON org_units;
CREATE POLICY org_units_insert ON org_units FOR INSERT WITH CHECK (org_id = org_id());
DROP POLICY IF EXISTS org_units_update ON org_units;
CREATE POLICY org_units_update ON org_units FOR UPDATE USING (org_id = org_id());
DROP POLICY IF EXISTS org_units_delete ON org_units;
CREATE POLICY org_units_delete ON org_units FOR DELETE USING (org_id = org_id());

ALTER TABLE staff_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_assignments_select ON staff_assignments;
CREATE POLICY staff_assignments_select ON staff_assignments FOR SELECT USING (org_id = org_id());
DROP POLICY IF EXISTS staff_assignments_insert ON staff_assignments;
CREATE POLICY staff_assignments_insert ON staff_assignments FOR INSERT WITH CHECK (org_id = org_id());
DROP POLICY IF EXISTS staff_assignments_update ON staff_assignments;
CREATE POLICY staff_assignments_update ON staff_assignments FOR UPDATE USING (org_id = org_id());
DROP POLICY IF EXISTS staff_assignments_delete ON staff_assignments;
CREATE POLICY staff_assignments_delete ON staff_assignments FOR DELETE USING (org_id = org_id());

-- ── LAYER 2: self-defending functions (CREATE OR REPLACE, same signatures) ──

CREATE OR REPLACE FUNCTION place_person(
  p_person_id uuid,
  p_site_id   uuid,
  p_start     date,
  p_reason    text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_new uuid;
BEGIN
  PERFORM 1 FROM persons   WHERE id = p_person_id AND org_id = org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Person not found'; END IF;
  PERFORM 1 FROM org_sites WHERE id = p_site_id AND org_id = org_id() AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Site not found or inactive'; END IF;

  UPDATE person_placements
     SET end_date = p_start
   WHERE person_id = p_person_id
     AND org_id = org_id()
     AND end_date IS NULL;

  INSERT INTO person_placements (org_id, person_id, site_id, start_date, reason)
  VALUES (org_id(), p_person_id, p_site_id, p_start, p_reason)
  RETURNING id INTO v_new;

  RETURN v_new;
END $$;

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
    INSERT INTO org_sites (org_id, name, address, city, site_type, credential_type,
                           capacity, license_number, license_expiration, is_active)
    VALUES (org_id(), p_name, p_address, p_city, p_site_type, NULLIF(p_credential, ''),
            v_cap, NULLIF(p_license_number, ''), p_license_expiration, true)
    RETURNING id INTO v_site;

    INSERT INTO org_units (org_id, parent_id, name, unit_type, address, city, site_id)
    VALUES (org_id(), p_parent_id, p_name, 'site', p_address, p_city, v_site)
    RETURNING id INTO v_unit;
  ELSE
    -- ownership gate: a foreign unit id is indistinguishable from a missing one
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

CREATE OR REPLACE FUNCTION delete_site_unit(p_unit_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_site uuid;
  v_residents int;
BEGIN
  -- ownership gate first: foreign ids die here, before any write
  SELECT site_id INTO v_site FROM org_units
   WHERE id = p_unit_id AND org_id = org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Unit not found'; END IF;

  IF EXISTS (SELECT 1 FROM org_units WHERE parent_id = p_unit_id AND org_id = org_id())
    THEN RAISE EXCEPTION 'Remove child units first'; END IF;

  IF v_site IS NOT NULL THEN
    SELECT count(*) INTO v_residents
      FROM person_placements
     WHERE site_id = v_site AND org_id = org_id() AND end_date IS NULL;
    IF v_residents > 0 THEN
      RAISE EXCEPTION '% resident(s) are still placed at this site — move them first', v_residents;
    END IF;
    UPDATE org_sites SET is_active = false
     WHERE id = v_site AND org_id = org_id();
  END IF;

  DELETE FROM org_units WHERE id = p_unit_id AND org_id = org_id();
END $$;
