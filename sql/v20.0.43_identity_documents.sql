-- ⚠ RUN ONLY AFTER THE PR'S REVIEW IS 5/5 ⚠
-- =====================================================================================
-- sql/v20.0.43_identity_documents.sql
-- ID documents locked like the SSN (PBA SSN design, decision 5)
--
-- A PBA file can be marked as an ID document — one that shows a full Social Security number, such as an
-- SSA letter or a copy of the card. Marked files:
--   • can be opened only by the roles allowed to see SSNs (ssn_viewer_roles), with a written reason and a
--     fresh authenticator code, at most 10 an hour; each opening is in the SSN access log first;
--   • are refused by storage itself: the pba bucket's read rule now also requires, for a marked file, an
--     opening granted to this person in the last 2 minutes (pba_object_open_ok) — so a link can't be
--     made for it any other way;
--   • stay listed for everyone who could see them before (they see that the file exists, not its contents).
-- Anyone who can see the Person's PBA record can mark a file (locking is always safe); only an SSN role,
-- with a fresh code and a reason, can unmark one. Every mark, unmark, opening and refusal is logged.
--
-- RUN IN SUPABASE (SQL editor), ONCE. One transaction: preflight → changes → rolled-back self-test on a
-- synthetic Person → COMMIT → verification table.
-- =====================================================================================

BEGIN;

SELECT set_config('request.jwt.claims', '{}', true);

DO $pre$
BEGIN
  IF to_regclass('public.ssn_access_log') IS NULL OR to_regprocedure('public._ssn_fresh_code()') IS NULL THEN
    RAISE EXCEPTION 'v20.0.43 preflight: v20.0.42 (encrypted SSN) has not run';
  END IF;
  IF to_regprocedure('public._pba_register_file(uuid, uuid, text, text, text, text, bigint, uuid, text)') IS NULL
     OR to_regprocedure('public.pba_path_person_ok(text)') IS NULL THEN
    RAISE EXCEPTION 'v20.0.43 preflight: the PBA file functions were not found';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pba_files' AND column_name = 'is_identity') THEN
    RAISE EXCEPTION 'v20.0.43 preflight: this migration has already run';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ssn_access_log_action_check') THEN
    RAISE EXCEPTION 'v20.0.43 preflight: the access log''s action rule was not found under its expected name';
  END IF;
END
$pre$;

-- ── 1. The mark, the openings, and the log's new entries ─────────────────────────────
ALTER TABLE public.pba_files
  ADD COLUMN is_identity        boolean NOT NULL DEFAULT false,
  ADD COLUMN identity_marked_by uuid,
  ADD COLUMN identity_marked_at timestamptz;

CREATE TABLE public.pba_identity_open_tickets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  file_id     uuid NOT NULL REFERENCES public.pba_files (id) ON DELETE CASCADE,
  staff_id    uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX pba_identity_open_tickets_lookup ON public.pba_identity_open_tickets (file_id, staff_id, created_at);

ALTER TABLE public.ssn_access_log ADD COLUMN file_id uuid;
ALTER TABLE public.ssn_access_log DROP CONSTRAINT ssn_access_log_action_check;
ALTER TABLE public.ssn_access_log ADD CONSTRAINT ssn_access_log_action_check
  CHECK (action IN ('enter', 'replace', 'reveal', 'denied', 'blocked', 'delete', 'purge', 'roles_changed',
                    'doc_open', 'doc_marked', 'doc_unmarked'));

CREATE FUNCTION public._ssn_log_file(p_org uuid, p_person uuid, p_file uuid, p_actor uuid, p_role text, p_action text, p_ok boolean, p_reason text, p_detail text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  INSERT INTO ssn_access_log (org_id, person_id, file_id, actor_staff_id, actor_role, action, ok, reason, detail)
  VALUES (p_org, p_person, p_file, p_actor, p_role, p_action, p_ok, nullif(btrim(coalesce(p_reason, '')), ''), p_detail)
$$;

-- ── 2. Storage refuses a marked file without a fresh opening ─────────────────────────
-- Runs as the signed-in person (it's part of the bucket's read rule). True for any unmarked file; for a
-- marked one, only when this person was granted an opening of it in the last 2 minutes.
CREATE FUNCTION public.pba_object_open_ok(p_name text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT NOT EXISTS (SELECT 1 FROM pba_files f WHERE f.storage_path = p_name AND f.is_identity)
      OR EXISTS (SELECT 1 FROM pba_files f JOIN pba_identity_open_tickets t ON t.file_id = f.id
                  WHERE f.storage_path = p_name AND f.is_identity
                    AND t.staff_id = public.my_staff_id()
                    AND t.created_at > clock_timestamp() - interval '2 minutes')
$$;

DROP POLICY IF EXISTS pba_objects_select ON storage.objects;
CREATE POLICY pba_objects_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'pba' AND public.pba_path_person_ok(name) AND public.pba_object_open_ok(name));

-- ── 3. Mark / unmark ────────────────────────────────────────────────────────────────
CREATE FUNCTION public._pba_mark_identity(p_file uuid, p_on boolean, p_reason text, p_actor uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  f      pba_files;
  a      record;
  v_read boolean := false;
BEGIN
  SELECT * INTO f FROM pba_files WHERE id = p_file FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'File not found'); END IF;
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = f.org_id AND s.is_active) THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'mark: not on this organization''s staff');
    RETURN jsonb_build_object('ok', false, 'error', 'Not permitted');
  END IF;
  IF p_on THEN
    -- locking: anyone who can see this Person's PBA record (or an SSN role)
    SELECT * INTO a FROM public._pba_access(f.person_id, p_actor, p_role);
    v_read := coalesce(a.o_read, false) OR public._ssn_is_viewer(f.org_id, p_role);
    IF NOT v_read THEN
      PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'mark: no access to this PBA record');
      RETURN jsonb_build_object('ok', false, 'error', 'Not permitted');
    END IF;
    IF NOT f.is_identity THEN
      UPDATE pba_files SET is_identity = true, identity_marked_by = p_actor, identity_marked_at = now() WHERE id = f.id;
      PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'doc_marked', true, p_reason, NULL);
    END IF;
    RETURN jsonb_build_object('ok', true, 'is_identity', true);
  END IF;
  -- unlocking: an SSN role, with a reason and a fresh code
  IF NOT public._ssn_is_viewer(f.org_id, p_role) THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'unmark: role not permitted');
    RETURN jsonb_build_object('ok', false, 'error', 'Only a role allowed to see SSNs can unlock an ID document');
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'unmark: no reason');
    RETURN jsonb_build_object('ok', false, 'error', 'Give a reason for unlocking it');
  END IF;
  IF NOT public._ssn_fresh_code() THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'unmark: no fresh authenticator code');
    RETURN jsonb_build_object('ok', false, 'needs_code', true, 'error', 'Enter a fresh code from your authenticator app');
  END IF;
  IF f.is_identity THEN
    UPDATE pba_files SET is_identity = false, identity_marked_by = p_actor, identity_marked_at = now() WHERE id = f.id;
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'doc_unmarked', true, p_reason, NULL);
  END IF;
  RETURN jsonb_build_object('ok', true, 'is_identity', false);
END;
$$;

-- Register an upload already marked (one transaction, so it's never unmarked in the record)
CREATE FUNCTION public._pba_register_identity_file(p_id uuid, p_person uuid, p_purpose text, p_path text, p_sha256 text,
                                                    p_mime text, p_bytes bigint, p_actor uuid, p_role text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_id uuid;
  f    pba_files;
BEGIN
  v_id := public._pba_register_file(p_id, p_person, p_purpose, p_path, p_sha256, p_mime, p_bytes, p_actor, p_role);
  SELECT * INTO f FROM pba_files WHERE id = v_id FOR UPDATE;
  IF NOT f.is_identity THEN
    UPDATE pba_files SET is_identity = true, identity_marked_by = p_actor, identity_marked_at = now() WHERE id = v_id;
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'doc_marked', true, NULL, 'marked at upload');
  END IF;
  RETURN v_id;
END;
$$;

-- ── 4. Open a marked file ───────────────────────────────────────────────────────────
CREATE FUNCTION public._pba_identity_open(p_file uuid, p_reason text, p_actor uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  f   pba_files;
  v_n integer;
BEGIN
  SELECT * INTO f FROM pba_files WHERE id = p_file;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'File not found'); END IF;
  IF NOT f.is_identity THEN RETURN jsonb_build_object('ok', true, 'path', f.storage_path); END IF;
  -- every refusal is logged and returned (never raised), so the log row is kept
  IF p_actor IS NULL OR NOT public._ssn_is_viewer(f.org_id, p_role)
     OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.id = p_actor AND s.org_id = f.org_id AND s.is_active) THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'open ID document: role not permitted');
    RETURN jsonb_build_object('ok', false, 'error', 'Only a role allowed to see SSNs can open ID documents');
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'open ID document: no reason');
    RETURN jsonb_build_object('ok', false, 'error', 'Give a reason for opening it');
  END IF;
  IF NOT public._ssn_fresh_code() THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'denied', false, p_reason, 'open ID document: no fresh authenticator code');
    RETURN jsonb_build_object('ok', false, 'needs_code', true, 'error', 'Enter a fresh code from your authenticator app');
  END IF;
  -- one at a time per person (shared with SSN views), through the log write
  PERFORM pg_advisory_xact_lock(hashtext('provly-ssn-reveal'), hashtext(p_actor::text));
  SELECT count(*) INTO v_n FROM ssn_access_log
   WHERE actor_staff_id = p_actor AND action = 'doc_open' AND ok AND at > clock_timestamp() - interval '1 hour';
  IF v_n >= 10 THEN
    PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'blocked', false, p_reason, 'open ID document: more than 10 in an hour');
    RETURN jsonb_build_object('ok', false, 'error', 'Too many ID documents opened in the last hour — this has been recorded for the Owner');
  END IF;
  PERFORM public._ssn_log_file(f.org_id, f.person_id, f.id, p_actor, p_role, 'doc_open', true, p_reason, NULL);   -- the log comes first
  DELETE FROM pba_identity_open_tickets WHERE created_at < clock_timestamp() - interval '1 day';
  INSERT INTO pba_identity_open_tickets (org_id, file_id, staff_id) VALUES (f.org_id, f.id, p_actor);
  RETURN jsonb_build_object('ok', true, 'path', f.storage_path);
END;
$$;

-- ── 5. Public functions (the caller must be able to see the Person) ─────────────────
CREATE FUNCTION public.pba_mark_identity(p_file uuid, p_on boolean, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_person uuid;
  v_hidden jsonb;
BEGIN
  SELECT person_id INTO v_person FROM pba_files WHERE id = p_file;
  IF v_person IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'File not found'); END IF;
  v_hidden := public._ssn_hidden(v_person, CASE WHEN p_on THEN 'mark' ELSE 'unmark' END);
  IF v_hidden IS NOT NULL THEN RETURN v_hidden; END IF;
  RETURN public._pba_mark_identity(p_file, p_on, p_reason, public.my_staff_id(), public.member_role()::text);
END;
$$;

CREATE FUNCTION public.pba_identity_open(p_file uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_person uuid;
  v_hidden jsonb;
BEGIN
  SELECT person_id INTO v_person FROM pba_files WHERE id = p_file;
  IF v_person IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'File not found'); END IF;
  v_hidden := public._ssn_hidden(v_person, 'open ID document');
  IF v_hidden IS NOT NULL THEN RETURN v_hidden; END IF;
  RETURN public._pba_identity_open(p_file, p_reason, public.my_staff_id(), public.member_role()::text);
END;
$$;

CREATE FUNCTION public.pba_register_identity_file(p_id uuid, p_person uuid, p_purpose text, p_path text, p_sha256 text, p_mime text, p_bytes bigint)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.can_see_person(p_person) THEN RAISE EXCEPTION 'Not permitted'; END IF;
  RETURN public._pba_register_identity_file(p_id, p_person, p_purpose, p_path, p_sha256, p_mime, p_bytes,
                                            public.my_staff_id(), public.member_role()::text);
END;
$$;

-- ── 6. Access and grants ────────────────────────────────────────────────────────────
DO $rls$
BEGIN
  ALTER TABLE public.pba_identity_open_tickets ENABLE ROW LEVEL SECURITY;      -- no policies: no client access
  REVOKE ALL ON public.pba_identity_open_tickets FROM PUBLIC, anon, authenticated;
END
$rls$;

DO $fn$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('_ssn_log_file', 'pba_object_open_ok', '_pba_mark_identity', '_pba_register_identity_file', '_pba_identity_open',
                         'pba_mark_identity', 'pba_identity_open', 'pba_register_identity_file')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    -- pba_object_open_ok is part of the bucket's read rule, which runs as the signed-in person
    IF f.proname IN ('pba_mark_identity', 'pba_identity_open', 'pba_register_identity_file', 'pba_object_open_ok') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
  END LOOP;
END
$fn$;

NOTIFY pgrst, 'reload schema';

-- ── 7. Self-test — a synthetic Person and file, rolled back ─────────────────────────
CREATE OR REPLACE FUNCTION pg_temp.v20043_test_insert(p_table text, p_given jsonb)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_rel  regclass := ('public.' || p_table)::regclass;
  v_cols text := '';
  v_vals text := '';
  k      text;
  v_typ  text;
  c      record;
  v_id   uuid;
BEGIN
  FOR k IN SELECT jsonb_object_keys(p_given) LOOP
    SELECT format_type(a.atttypid, a.atttypmod) INTO v_typ
      FROM pg_attribute a WHERE a.attrelid = v_rel AND a.attname = k AND NOT a.attisdropped;
    v_cols := v_cols || ', ' || quote_ident(k);
    v_vals := v_vals || ', ' || CASE WHEN jsonb_typeof(p_given->k) = 'null' THEN 'NULL'
                                     ELSE quote_literal(p_given->>k) END || '::' || v_typ;
  END LOOP;
  FOR c IN
    SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ, t.typtype, t.typcategory, a.atttypid
      FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
     WHERE a.attrelid = v_rel AND a.attnum > 0 AND NOT a.attisdropped AND a.attnotnull
       AND NOT a.atthasdef AND a.attidentity = '' AND a.attgenerated = ''
       AND NOT (p_given ? a.attname::text)
  LOOP
    v_cols := v_cols || ', ' || quote_ident(c.attname);
    v_vals := v_vals || ', ' || CASE
      WHEN c.typtype = 'e' THEN format('(SELECT e.enumlabel FROM pg_enum e WHERE e.enumtypid = %s ORDER BY e.enumsortorder LIMIT 1)::%s', c.atttypid, c.typ)
      WHEN c.typ = 'date' THEN '''1990-01-01''::date'
      WHEN c.typ LIKE 'timestamp%' THEN 'now()'
      WHEN c.typ LIKE 'time%' THEN '''00:00''::time'
      WHEN c.typ = 'boolean' THEN 'false'
      WHEN c.typcategory = 'N' THEN '0'
      WHEN c.typ IN ('jsonb', 'json') THEN '''{}''::' || c.typ
      WHEN c.typ = 'uuid' THEN 'gen_random_uuid()'
      WHEN c.typcategory = 'A' THEN '''{}''::' || c.typ
      ELSE quote_literal('v20.0.43 self-test') || '::' || c.typ END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s) RETURNING id', p_table, substr(v_cols, 3), substr(v_vals, 3))
    INTO v_id;
  RETURN v_id;
END;
$$;

DO $test$
DECLARE
  v_org    uuid;
  v_owner  uuid;
  v_ouser  uuid;
  v_person uuid;
  v_file   uuid := gen_random_uuid();
  v_path   text;
  r        jsonb;
  i        integer;
  v_ok     boolean;
  v_now    bigint := extract(epoch FROM clock_timestamp())::bigint;
BEGIN
  SELECT m.org_id, s.id, m.user_id INTO v_org, v_owner, v_ouser
    FROM org_members m JOIN staff s ON s.user_id = m.user_id AND s.org_id = m.org_id AND s.is_active
   WHERE m.role::text = 'owner' ORDER BY s.id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'SELFTEST FAIL 0: no active owner to test with'; END IF;

  BEGIN
    v_person := pg_temp.v20043_test_insert('persons', jsonb_build_object('org_id', v_org, 'first_name', 'V20043', 'last_name', 'Selftest',
                                                                            'identification_number', '099999943', 'is_active', true));
    v_path := v_org::text || '/' || v_person::text || '/documents/' || v_file::text || '.pdf';
    INSERT INTO pba_files (id, org_id, person_id, purpose, storage_path, sha256, mime, bytes, uploaded_by)
    VALUES (v_file, v_org, v_person, 'document', v_path, repeat('a', 64), 'application/pdf', 1, v_owner);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ouser, 'role', 'authenticated', 'aal', 'aal2', 'org_id', v_org,
      'app_metadata', json_build_object('org_id', v_org), 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', v_now)))::text, true);

    -- 1. an unmarked file opens as before
    v_ok := public.pba_object_open_ok(v_path);
    IF NOT v_ok THEN RAISE EXCEPTION 'SELFTEST FAIL 1: an ordinary file was refused'; END IF;

    -- 2. marking locks it: storage refuses it, even for the Owner, until an opening is granted
    r := public._pba_mark_identity(v_file, true, NULL, v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean OR NOT EXISTS (SELECT 1 FROM pba_files WHERE id = v_file AND is_identity) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 2: the file could not be marked: %', r;
    END IF;
    v_ok := public.pba_object_open_ok(v_path);
    IF v_ok THEN RAISE EXCEPTION 'SELFTEST FAIL 2b: a marked file opened without an opening'; END IF;
    IF NOT EXISTS (SELECT 1 FROM ssn_access_log WHERE file_id = v_file AND action = 'doc_marked' AND ok) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 2c: marking was not logged';
    END IF;

    -- 3. refused: no reason; a role that can't see SSNs; a stale code — each logged, none opens it
    r := public._pba_identity_open(v_file, '', v_owner, 'owner');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 3: opened without a reason'; END IF;
    r := public._pba_identity_open(v_file, 'self-test', v_owner, 'dsp');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 3b: opened for a role that can''t see SSNs'; END IF;
    r := public._pba_identity_open(v_file, 'self-test', gen_random_uuid(), 'owner');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 3c: opened for someone outside the organization'; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ouser, 'role', 'authenticated', 'aal', 'aal2', 'org_id', v_org,
      'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', v_now - 3600)))::text, true);
    r := public._pba_identity_open(v_file, 'self-test', v_owner, 'owner');
    IF (r ->> 'ok')::boolean OR NOT coalesce((r ->> 'needs_code')::boolean, false) THEN RAISE EXCEPTION 'SELFTEST FAIL 3d: opened with an hour-old code'; END IF;
    v_ok := public.pba_object_open_ok(v_path);
    IF v_ok THEN RAISE EXCEPTION 'SELFTEST FAIL 3e: a refused attempt still opened the file'; END IF;
    IF (SELECT count(*) FROM ssn_access_log WHERE file_id = v_file AND action = 'denied') < 4 THEN
      RAISE EXCEPTION 'SELFTEST FAIL 3f: refused attempts were not all logged';
    END IF;

    -- 4. a viewer with a reason and a fresh code opens it — for 2 minutes, for them only
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ouser, 'role', 'authenticated', 'aal', 'aal2', 'org_id', v_org,
      'app_metadata', json_build_object('org_id', v_org), 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', v_now)))::text, true);
    r := public._pba_identity_open(v_file, 'self-test', v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean OR r ->> 'path' <> v_path THEN RAISE EXCEPTION 'SELFTEST FAIL 4: a viewer could not open it: %', r; END IF;
    IF NOT EXISTS (SELECT 1 FROM ssn_access_log WHERE file_id = v_file AND action = 'doc_open' AND ok) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 4b: the opening was not logged';
    END IF;
    v_ok := public.pba_object_open_ok(v_path);
    IF NOT v_ok THEN RAISE EXCEPTION 'SELFTEST FAIL 4c: storage refused a granted opening'; END IF;
    UPDATE pba_identity_open_tickets SET created_at = clock_timestamp() - interval '3 minutes' WHERE file_id = v_file;
    v_ok := public.pba_object_open_ok(v_path);
    IF v_ok THEN RAISE EXCEPTION 'SELFTEST FAIL 4d: an opening lasted more than 2 minutes'; END IF;

    -- 5. more than 10 openings an hour is blocked (and logged)
    FOR i IN 1..9 LOOP
      r := public._pba_identity_open(v_file, 'self-test', v_owner, 'owner');
      IF NOT (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 5: opening % failed: %', i, r; END IF;
    END LOOP;
    r := public._pba_identity_open(v_file, 'self-test', v_owner, 'owner');
    IF (r ->> 'ok')::boolean OR NOT EXISTS (SELECT 1 FROM ssn_access_log WHERE file_id = v_file AND action = 'blocked') THEN
      RAISE EXCEPTION 'SELFTEST FAIL 5b: the 11th opening in an hour was not blocked and logged';
    END IF;

    -- 6. unlocking: refused for a role that can't see SSNs and without a reason; an SSN role can
    r := public._pba_mark_identity(v_file, false, 'self-test', v_owner, 'dsp');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 6: a role that can''t see SSNs unlocked an ID document'; END IF;
    r := public._pba_mark_identity(v_file, false, '', v_owner, 'owner');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 6b: unlocked without a reason'; END IF;
    r := public._pba_mark_identity(v_file, false, 'self-test', v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean OR EXISTS (SELECT 1 FROM pba_files WHERE id = v_file AND is_identity) THEN
      RAISE EXCEPTION 'SELFTEST FAIL 6c: an SSN role could not unlock it: %', r;
    END IF;
    UPDATE pba_identity_open_tickets SET created_at = clock_timestamp() - interval '3 minutes' WHERE file_id = v_file;
    v_ok := public.pba_object_open_ok(v_path);
    IF NOT v_ok THEN RAISE EXCEPTION 'SELFTEST FAIL 6d: an unlocked file stayed refused'; END IF;

    -- 7. a marked file can't be opened without a signed-in session, and storage refuses it too
    r := public._pba_mark_identity(v_file, true, NULL, v_owner, 'owner');
    IF NOT (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 7: the file could not be marked again: %', r; END IF;
    PERFORM set_config('request.jwt.claims', '{}', true);
    r := public.pba_identity_open(v_file, 'self-test');
    IF (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'SELFTEST FAIL 7b: opened without a session'; END IF;
    v_ok := public.pba_object_open_ok(v_path);
    IF v_ok THEN RAISE EXCEPTION 'SELFTEST FAIL 7c: storage let a marked file through without a session'; END IF;

    RAISE EXCEPTION 'SELFTEST_ROLLBACK' USING ERRCODE = 'PRVOK';
  EXCEPTION WHEN SQLSTATE 'PRVOK' THEN
    NULL;  -- every self-test write above is rolled back here
  END;
END
$test$;

SELECT set_config('request.jwt.claims', '{}', true);

COMMIT;

-- ── Verification table (paste this result into the PR and the chat) ─────────────────
SELECT n, check_name, got, want,
       CASE WHEN want = '(information)' THEN 'ℹ️' WHEN got = want THEN '✅' ELSE '❌' END AS ok FROM (
  SELECT 1 n, 'PBA files can be marked as ID documents' check_name,
    (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pba_files'
       AND column_name IN ('is_identity', 'identity_marked_by', 'identity_marked_at'))::text got, '3' want
  UNION ALL SELECT 2, 'Storage read rule refuses marked files without an opening',
    (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'pba_objects_select'
       AND qual LIKE '%pba_object_open_ok%' AND qual LIKE '%pba_path_person_ok%')::text, '1'
  UNION ALL SELECT 3, 'Openings table: RLS on, no client access',
    ((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pba_identity_open_tickets'::regclass)
     AND NOT has_table_privilege('authenticated', 'public.pba_identity_open_tickets', 'SELECT'))::text, 'true'
  UNION ALL SELECT 4, 'Public ID-document functions for signed-in users (not anon)',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('pba_mark_identity', 'pba_identity_open', 'pba_register_identity_file')
       AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE'))::text, '3'
  UNION ALL SELECT 5, 'Internal ID-document functions callable by clients',
    (SELECT count(*) FROM pg_proc WHERE proname IN ('_ssn_log_file', '_pba_mark_identity', '_pba_register_identity_file', '_pba_identity_open')
       AND (has_function_privilege('authenticated', oid, 'EXECUTE') OR has_function_privilege('anon', oid, 'EXECUTE')))::text, '0'
  UNION ALL SELECT 6, 'Storage rule check usable by signed-in users (not anon)',
    (has_function_privilege('authenticated', 'public.pba_object_open_ok(text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.pba_object_open_ok(text)', 'EXECUTE'))::text, 'true'
  UNION ALL SELECT 7, 'Access log records ID-document openings',
    (position('doc_open' IN (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ssn_access_log_action_check')) > 0)::text, 'true'
  UNION ALL SELECT 8, 'Self-test leftovers (synthetic Person)',
    (SELECT count(*) FROM persons WHERE identification_number = '099999943')::text, '0'
  UNION ALL SELECT 9, 'Files marked as ID documents so far',
    (SELECT count(*) FROM pba_files WHERE is_identity)::text, '(information)'
) t
ORDER BY n;
