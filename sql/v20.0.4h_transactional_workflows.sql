-- v20.0.4h — transactional workflows (Greptile app review, round 1 — all
-- three findings accepted)
--
-- ROOT CAUSE, shared by all three: multi-write workflows executed as separate
-- client round-trips. A failure between writes stranded records in
-- operationally invalid states: an unplaced client (move), an orphan active
-- facility (site-node create), an unmanageable active facility (node delete).
-- CURE: each workflow becomes one PL/pgSQL function = one transaction.
--
-- SECURITY MODEL: all three are SECURITY INVOKER (the default) — they run AS
-- the caller, so the existing org-tenancy RLS applies unchanged to every
-- statement inside. No definer-rights bypass is introduced. Inserts stamp
-- org_id() (the house tenancy function), matching the RLS with_check.
--
-- Server-side coherence checks live INSIDE the transactions (children present,
-- residents present) — the UI's friendly pre-checks remain, but the database
-- is the enforcer. Refusing to delete a node with residents is a REGIME-2
-- coherence rule (an active home with no management surface is nonsense), not
-- a mirror-doctrine compliance block.

-- ── 1. place_person: end current placement + start new one, atomically ──
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
  -- End the current placement (if any) on the move date. If the move date
  -- precedes the current start, the dates CHECK aborts the whole transaction —
  -- a coherent refusal, not a partial write.
  UPDATE person_placements
     SET end_date = p_start
   WHERE person_id = p_person_id
     AND end_date IS NULL;

  INSERT INTO person_placements (org_id, person_id, site_id, start_date, reason)
  VALUES (org_id(), p_person_id, p_site_id, p_start, p_reason)
  RETURNING id INTO v_new;

  RETURN v_new;
END $$;

-- ── 2. save_site_unit: facility record + tree node, one transaction ──
--    p_unit_id NULL  -> create facility + node together
--    p_unit_id given -> update node; update its facility, or create + link
--                       one if the node predates the facility model
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

  -- D2 ceiling provenance, enforced server-side (constraints backstop it):
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
    SELECT site_id INTO v_unit FROM org_units WHERE id = p_unit_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unit not found'; END IF;
    v_site := v_unit;  -- (site_id of the node; may be NULL for legacy nodes)

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
       WHERE id = v_site;
    END IF;

    UPDATE org_units
       SET name = p_name, address = p_address, city = p_city, site_id = v_site
     WHERE id = p_unit_id;
    v_unit := p_unit_id;
  END IF;

  RETURN v_unit;
END $$;

-- ── 3. delete_site_unit: node delete + facility deactivation, one transaction ──
CREATE OR REPLACE FUNCTION delete_site_unit(p_unit_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_site uuid;
  v_residents int;
BEGIN
  SELECT site_id INTO v_site FROM org_units WHERE id = p_unit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unit not found'; END IF;

  IF EXISTS (SELECT 1 FROM org_units WHERE parent_id = p_unit_id)
    THEN RAISE EXCEPTION 'Remove child units first'; END IF;

  IF v_site IS NOT NULL THEN
    SELECT count(*) INTO v_residents
      FROM person_placements
     WHERE site_id = v_site AND end_date IS NULL;
    IF v_residents > 0 THEN
      RAISE EXCEPTION '% resident(s) are still placed at this site — move them first', v_residents;
    END IF;
    -- Deactivate, never delete: placement history references this facility.
    UPDATE org_sites SET is_active = false WHERE id = v_site;
  END IF;

  DELETE FROM org_units WHERE id = p_unit_id;
END $$;
