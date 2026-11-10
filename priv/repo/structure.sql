--
-- PostgreSQL database dump
--

\restrict eZy04iMxcqdUFFYiduGPfhnmrMZvGv0Ri6mmBRvIEqWhgMSoFTixBnMC1ohM8JB

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: enforce_cable_assertion_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_cable_assertion_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'cable assertions are immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: enforce_cable_assertion_retention(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_cable_assertion_retention() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Organization teardown removes the organization row before cascading,
  -- so only deletes that outlive the organization are allowed. A deleted
  -- source or endpoint would otherwise cascade a confirmed claim away
  -- without a removal event, so retire the cable with retract_cable/2
  -- before deleting one.
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'cable assertions are append-only and cannot be deleted while the organization exists'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: enforce_cable_endpoint_termination(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_cable_endpoint_termination() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  checked_cable_id uuid;
  checked_organization_id uuid;
BEGIN
  IF TG_OP IN ('DELETE', 'UPDATE') THEN
    checked_cable_id := OLD.cable_id;
    checked_organization_id := OLD.organization_id;

    IF EXISTS (
      SELECT 1
      FROM cables cable
      WHERE cable.id = checked_cable_id
        AND cable.organization_id = checked_organization_id
        AND (
          (SELECT count(*)
           FROM cable_endpoint_terminations termination
           WHERE termination.cable_id = cable.id
             AND termination.organization_id = cable.organization_id) <> 2
          OR NOT EXISTS (
            SELECT 1 FROM cable_endpoint_terminations termination
            WHERE termination.cable_id = cable.id
              AND termination.organization_id = cable.organization_id
              AND termination.interface_id = cable.interface_a_id
          )
          OR NOT EXISTS (
            SELECT 1 FROM cable_endpoint_terminations termination
            WHERE termination.cable_id = cable.id
              AND termination.organization_id = cable.organization_id
              AND termination.interface_id = cable.interface_b_id
          )
        )
    ) THEN
      RAISE EXCEPTION 'cable endpoint termination is inconsistent'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    checked_cable_id := NEW.cable_id;
    checked_organization_id := NEW.organization_id;

    IF EXISTS (
      SELECT 1
      FROM cables cable
      WHERE cable.id = checked_cable_id
        AND cable.organization_id = checked_organization_id
        AND (
          (SELECT count(*)
           FROM cable_endpoint_terminations termination
           WHERE termination.cable_id = cable.id
             AND termination.organization_id = cable.organization_id) <> 2
          OR NOT EXISTS (
            SELECT 1 FROM cable_endpoint_terminations termination
            WHERE termination.cable_id = cable.id
              AND termination.organization_id = cable.organization_id
              AND termination.interface_id = cable.interface_a_id
          )
          OR NOT EXISTS (
            SELECT 1 FROM cable_endpoint_terminations termination
            WHERE termination.cable_id = cable.id
              AND termination.organization_id = cable.organization_id
              AND termination.interface_id = cable.interface_b_id
          )
        )
    ) THEN
      RAISE EXCEPTION 'cable endpoint termination is inconsistent'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  RETURN NULL;
END;
$$;


--
-- Name: enforce_cable_endpoints_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_cable_endpoints_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.organization_id = OLD.organization_id AND
     NEW.cable_kind = OLD.cable_kind AND
     NEW.interface_a_id IS NOT DISTINCT FROM OLD.interface_a_id AND
     NEW.interface_b_id IS NOT DISTINCT FROM OLD.interface_b_id AND
     NEW.power_port_id IS NOT DISTINCT FROM OLD.power_port_id AND
     NEW.power_outlet_id IS NOT DISTINCT FROM OLD.power_outlet_id AND
     NEW.power_feed_id IS NOT DISTINCT FROM OLD.power_feed_id THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'cable endpoints are immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: enforce_cable_primary_assertion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_cable_primary_assertion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  claim record;
BEGIN
  SELECT kind, action, cable_kind, interface_a_id, interface_b_id,
         power_port_id, power_outlet_id, power_feed_id
    INTO claim
    FROM cable_assertions
   WHERE id = NEW.primary_assertion_id
     AND organization_id = NEW.organization_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cable primary assertion does not exist in this organization'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- The projection boundary is a database invariant, not only a
  -- reconciliation policy: a current cable must be backed by a confirmed
  -- claim for exactly these endpoints, never by a proposal, a retraction,
  -- or a claim about different endpoints.
  IF claim.kind NOT IN ('operator', 'import') OR claim.action <> 'assert' THEN
    RAISE EXCEPTION 'cable primary assertion must be a confirmed cable claim'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF claim.cable_kind IS DISTINCT FROM NEW.cable_kind OR
     claim.interface_a_id IS DISTINCT FROM NEW.interface_a_id OR
     claim.interface_b_id IS DISTINCT FROM NEW.interface_b_id OR
     claim.power_port_id IS DISTINCT FROM NEW.power_port_id OR
     claim.power_outlet_id IS DISTINCT FROM NEW.power_outlet_id OR
     claim.power_feed_id IS DISTINCT FROM NEW.power_feed_id THEN
    RAISE EXCEPTION 'cable endpoints must match its primary assertion'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_catalog_type_revision_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_catalog_type_revision_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.finalized_at IS NULL
       OR NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
      RETURN OLD;
    END IF;
  ELSIF OLD.finalized_at IS NULL
        AND NEW.organization_id = OLD.organization_id
        AND NEW.hardware_type_id IS NOT DISTINCT FROM OLD.hardware_type_id
        AND NEW.module_type_id IS NOT DISTINCT FROM OLD.module_type_id THEN
    -- A draft may change freely; publishing changes nothing but finalized_at.
    IF NEW.finalized_at IS NULL
       OR (to_jsonb(NEW) - 'finalized_at') = (to_jsonb(OLD) - 'finalized_at') THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'catalog revisions are immutable'
    USING ERRCODE = '23514', CONSTRAINT = 'catalog_type_revisions_immutable';
END;
$$;


--
-- Name: enforce_component_template_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_component_template_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_finalized_at timestamp;
  new_finalized_at timestamp;
BEGIN
  IF TG_OP = 'DELETE'
     AND NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
    RETURN OLD;
  END IF;

  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    SELECT finalized_at INTO old_finalized_at
    FROM catalog_type_revisions
    WHERE id = OLD.catalog_type_revision_id
      AND organization_id = OLD.organization_id;
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    SELECT finalized_at INTO new_finalized_at
    FROM catalog_type_revisions
    WHERE id = NEW.catalog_type_revision_id
      AND organization_id = NEW.organization_id;
  END IF;

  IF old_finalized_at IS NOT NULL OR new_finalized_at IS NOT NULL THEN
    RAISE EXCEPTION 'component templates are immutable after revision finalization'
      USING ERRCODE = '23514', CONSTRAINT = 'component_templates_revision_finalized';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- Name: enforce_current_interface_adjacency_endpoints_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_current_interface_adjacency_endpoints_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.organization_id = OLD.organization_id AND
     NEW.interface_a_id = OLD.interface_a_id AND
     NEW.interface_b_id = OLD.interface_b_id THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'current interface adjacency endpoints are immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: enforce_current_interface_adjacency_occupancy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_current_interface_adjacency_occupancy() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  checked_adjacency_id uuid;
  checked_organization_id uuid;
BEGIN
  IF TG_OP IN ('DELETE', 'UPDATE') THEN
    checked_adjacency_id := OLD.adjacency_id;
    checked_organization_id := OLD.organization_id;

    IF EXISTS (
      SELECT 1
      FROM current_interface_adjacencies adjacency
      WHERE adjacency.id = checked_adjacency_id
        AND adjacency.organization_id = checked_organization_id
        AND (
          (SELECT count(*)
           FROM current_interface_adjacency_endpoints endpoint
           WHERE endpoint.adjacency_id = adjacency.id
             AND endpoint.organization_id = adjacency.organization_id) <> 2
          OR NOT EXISTS (
            SELECT 1 FROM current_interface_adjacency_endpoints endpoint
            WHERE endpoint.adjacency_id = adjacency.id
              AND endpoint.organization_id = adjacency.organization_id
              AND endpoint.interface_id = adjacency.interface_a_id
          )
          OR NOT EXISTS (
            SELECT 1 FROM current_interface_adjacency_endpoints endpoint
            WHERE endpoint.adjacency_id = adjacency.id
              AND endpoint.organization_id = adjacency.organization_id
              AND endpoint.interface_id = adjacency.interface_b_id
          )
        )
    ) THEN
      RAISE EXCEPTION 'current interface adjacency occupancy is inconsistent'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    checked_adjacency_id := NEW.adjacency_id;
    checked_organization_id := NEW.organization_id;

    IF EXISTS (
      SELECT 1
      FROM current_interface_adjacencies adjacency
      WHERE adjacency.id = checked_adjacency_id
        AND adjacency.organization_id = checked_organization_id
        AND (
          (SELECT count(*)
           FROM current_interface_adjacency_endpoints endpoint
           WHERE endpoint.adjacency_id = adjacency.id
             AND endpoint.organization_id = adjacency.organization_id) <> 2
          OR NOT EXISTS (
            SELECT 1 FROM current_interface_adjacency_endpoints endpoint
            WHERE endpoint.adjacency_id = adjacency.id
              AND endpoint.organization_id = adjacency.organization_id
              AND endpoint.interface_id = adjacency.interface_a_id
          )
          OR NOT EXISTS (
            SELECT 1 FROM current_interface_adjacency_endpoints endpoint
            WHERE endpoint.adjacency_id = adjacency.id
              AND endpoint.organization_id = adjacency.organization_id
              AND endpoint.interface_id = adjacency.interface_b_id
          )
        )
    ) THEN
      RAISE EXCEPTION 'current interface adjacency occupancy is inconsistent'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  RETURN NULL;
END;
$$;


--
-- Name: enforce_interface_neighbor_evidence_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_interface_neighbor_evidence_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (to_jsonb(NEW) - ARRAY['stale_at', 'stale_reason']) =
     (to_jsonb(OLD) - ARRAY['stale_at', 'stale_reason']) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'interface neighbor evidence facts are immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: enforce_interface_vlan_evidence_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_interface_vlan_evidence_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.organization_id IS NOT DISTINCT FROM OLD.organization_id
     AND NEW.interface_id IS NOT DISTINCT FROM OLD.interface_id
     AND NEW.vlan_id IS NOT DISTINCT FROM OLD.vlan_id
     AND NEW.source_id IS NOT DISTINCT FROM OLD.source_id
     AND NEW.observation_id IS NOT DISTINCT FROM OLD.observation_id
     AND NEW.source_local_key IS NOT DISTINCT FROM OLD.source_local_key
     AND NEW.source_local_scope IS NOT DISTINCT FROM OLD.source_local_scope
     AND NEW.vid IS NOT DISTINCT FROM OLD.vid
     AND NEW.tagging_mode IS NOT DISTINCT FROM OLD.tagging_mode
     AND NEW.metadata IS NOT DISTINCT FROM OLD.metadata
     AND NEW.observed_at IS NOT DISTINCT FROM OLD.observed_at
     AND NEW.inserted_at IS NOT DISTINCT FROM OLD.inserted_at THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'interface VLAN evidence facts are immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: enforce_resource_kind_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_resource_kind_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.kind IS DISTINCT FROM OLD.kind THEN
    RAISE EXCEPTION 'resource kind is immutable'
      USING ERRCODE = '23514', CONSTRAINT = 'resources_kind_immutable';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: guard_reconciliation_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_reconciliation_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
      RAISE EXCEPTION 'retained reconciliation history requires its organization'
        USING ERRCODE = '23514', CONSTRAINT = 'reconciliation_history_retained';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_TABLE_NAME = 'reconciliation_lanes' THEN
    IF NEW.organization_id <> OLD.organization_id OR NEW.position < OLD.position
       OR NEW.version < OLD.version
       OR (OLD.last_turn_at IS NOT NULL AND
           (NEW.last_turn_at IS NULL OR NEW.last_turn_at < OLD.last_turn_at)) THEN
      RAISE EXCEPTION 'lane identity and scheduling history cannot regress'
        USING ERRCODE = '23514', CONSTRAINT = 'reconciliation_lane_history';
    END IF;
  ELSE
    IF (to_jsonb(NEW) - '{status,checkpoint,generation,run_after,quarantine_kind,error}'::text[])
         <> (to_jsonb(OLD) - '{status,checkpoint,generation,run_after,quarantine_kind,error}'::text[])
       OR NEW.generation < OLD.generation OR NEW.checkpoint < OLD.checkpoint
       OR (OLD.status = 'succeeded' AND NEW IS DISTINCT FROM OLD) THEN
      RAISE EXCEPTION 'work identity, provenance and terminal history are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'reconciliation_work_history';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: materialize_neighbor_generation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.materialize_neighbor_generation(org uuid) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE gen uuid; clock timestamptz; relation text; columns text; BEGIN
  IF current_setting('renga.neighbor_materializing', true) = 'true' THEN RETURN; END IF;
  PERFORM 1 FROM organizations WHERE id = org FOR NO KEY UPDATE NOWAIT;
  IF NOT FOUND THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(org::text), hashtext('cable-state'));
  SELECT h.current_generation_id, g.as_of INTO gen, clock FROM neighbor_generation_heads h
    LEFT JOIN neighbor_generations g ON g.id = h.current_generation_id
    WHERE h.organization_id = org FOR UPDATE OF h;
  IF gen IS NULL THEN RETURN; END IF;
  PERFORM set_config('renga.neighbor_materializing', 'true', true);
  UPDATE interface_neighbor_evidence_neighbor_storage SET stale_at = expires_at, stale_reason = 'expired'
    WHERE organization_id = org AND stale_at IS NULL AND expires_at <= clock;
  DELETE FROM current_interface_adjacencies_neighbor_storage WHERE organization_id = org;
  FOREACH relation IN ARRAY ARRAY['interface_neighbor_matches','current_interface_adjacencies','topology_findings'] LOOP
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO columns FROM pg_attribute a
      WHERE a.attrelid = (relation || '_neighbor_storage')::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    EXECUTE 'DELETE FROM ' || relation || '_neighbor_storage b USING neighbor_generation_rows r WHERE r.generation_id = $1 AND r.kind = $2 AND r.deleted AND b.id::text = r.key' USING gen, relation;
    EXECUTE 'INSERT INTO ' || relation || '_neighbor_storage SELECT (jsonb_populate_record(NULL::' || relation || '_neighbor_storage, r.payload)).* FROM neighbor_generation_rows r WHERE r.generation_id = $1 AND r.kind = $2 AND NOT r.deleted ON CONFLICT (id) DO UPDATE SET (' || columns || ') = (SELECT ' || columns || ' FROM jsonb_populate_record(NULL::' || relation || '_neighbor_storage, to_jsonb(EXCLUDED)))' USING gen, relation;
  END LOOP;
  UPDATE neighbor_generation_heads SET current_generation_id = NULL WHERE organization_id = org;
  UPDATE neighbor_generations SET status = 'obsolete' WHERE id = gen;
  PERFORM set_config('renga.neighbor_materializing', 'false', true);
END $_$;


--
-- Name: neighbor_input_changed(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.neighbor_input_changed() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE org uuid; fields text[]; before_value jsonb; after_value jsonb; BEGIN
  IF current_setting('renga.neighbor_materializing', true) = 'true' THEN RETURN COALESCE(NEW, OLD); END IF;
  -- An unused source cannot affect topology; its first evidence will
  -- invalidate the version. Do not serialize first check-ins with builds.
  IF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'sources' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'updated_at' - 'inserted_at') IS NOT DISTINCT FROM (to_jsonb(OLD) - 'updated_at' - 'inserted_at') THEN RETURN NEW; END IF;
  -- Inventory presence timestamps are not topology input. Counting them
  -- would invalidate a large expiry run on every unrelated host check-in.
  fields := CASE TG_TABLE_NAME
    WHEN 'resources' THEN ARRAY['id','organization_id','kind','name','display_name']
    WHEN 'hosts' THEN ARRAY['id','organization_id','resource_id','hostname','fqdn']
    WHEN 'interfaces' THEN ARRAY['id','organization_id','resource_id','name','mac_address','kind','status']
    WHEN 'resource_identifiers' THEN ARRAY['id','organization_id','resource_id','kind','value','normalized_value']
    ELSE NULL END;
  IF TG_OP = 'UPDATE' AND fields IS NOT NULL THEN
    SELECT jsonb_object_agg(key,value) INTO before_value FROM jsonb_each(to_jsonb(OLD)) WHERE key = ANY(fields);
    SELECT jsonb_object_agg(key,value) INTO after_value FROM jsonb_each(to_jsonb(NEW)) WHERE key = ANY(fields);
    IF before_value IS NOT DISTINCT FROM after_value THEN RETURN NEW; END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'sources' THEN
    IF jsonb_build_array(NEW.id,NEW.organization_id,NEW.kind,NEW.status,NEW.metadata->'interface_neighbor_snapshot_policy') IS NOT DISTINCT FROM
      jsonb_build_array(OLD.id,OLD.organization_id,OLD.kind,OLD.status,OLD.metadata->'interface_neighbor_snapshot_policy') THEN RETURN NEW; END IF;
  END IF;
  org := COALESCE(NEW.organization_id, OLD.organization_id);
  PERFORM materialize_neighbor_generation(org);
  IF EXISTS (SELECT 1 FROM organizations WHERE id = org) THEN
    INSERT INTO neighbor_generation_heads(organization_id, version) VALUES(org, 1)
    ON CONFLICT (organization_id) DO UPDATE SET version = neighbor_generation_heads.version + 1;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;


--
-- Name: neighbor_read_generation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.neighbor_read_generation(org uuid) RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT CASE WHEN current_setting('renga.neighbor_materializing', true) = 'true' THEN NULL
         ELSE COALESCE(NULLIF(current_setting('renga.neighbor_generation', true), '')::uuid,
                       (SELECT current_generation_id FROM neighbor_generation_heads WHERE organization_id = org)) END
$$;


--
-- Name: occupy_cable_endpoints(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.occupy_cable_endpoints() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Power endpoints are held by the partial unique indexes on cables.
  IF NEW.cable_kind = 'power' THEN
    RETURN NEW;
  END IF;

  INSERT INTO cable_endpoint_terminations
    (organization_id, interface_id, cable_id)
  VALUES
    (NEW.organization_id, NEW.interface_a_id, NEW.id),
    (NEW.organization_id, NEW.interface_b_id, NEW.id);

  RETURN NEW;
END;
$$;


--
-- Name: occupy_current_interface_adjacency_endpoints(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.occupy_current_interface_adjacency_endpoints() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO current_interface_adjacency_endpoints
    (organization_id, interface_id, adjacency_id)
  VALUES
    (NEW.organization_id, NEW.interface_a_id, NEW.id),
    (NEW.organization_id, NEW.interface_b_id, NEW.id);

  RETURN NEW;
END;
$$;


--
-- Name: reject_imported_job_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_imported_job_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (to_jsonb(NEW) - '{resource_id,target_binding_id,requested_by_user_id}'::text[])
       = (to_jsonb(OLD) - '{resource_id,target_binding_id,requested_by_user_id}'::text[])
     AND (NEW.resource_id IS NULL OR NEW.resource_id = OLD.resource_id)
     AND (NEW.target_binding_id IS NULL OR NEW.target_binding_id = OLD.target_binding_id)
     AND (NEW.requested_by_user_id IS NULL
          OR NEW.requested_by_user_id = OLD.requested_by_user_id) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'imported jobs are history and cannot change'
    USING ERRCODE = '23514', CONSTRAINT = 'jobs_imported_immutable';
END;
$$;


--
-- Name: reject_interface_vlan_mode_evidence_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_interface_vlan_mode_evidence_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'interface VLAN mode evidence is immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: reject_job_event_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_job_event_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Retention removes a finished job and organization teardown removes the
  -- organization; both delete the parent row before cascading here, so a
  -- delete that outlives its job or organization is the only one allowed.
  IF TG_OP = 'DELETE' AND (
    NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) OR
    NOT EXISTS (SELECT 1 FROM jobs WHERE id = OLD.job_id)
  ) THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'job events are append-only'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: reject_observation_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_observation_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.intake_api_key_id IS DISTINCT FROM OLD.intake_api_key_id THEN
    IF NEW.intake_api_key_id IS NULL AND OLD.intake_api_key_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM intake_api_keys
         WHERE id = OLD.intake_api_key_id AND organization_id = OLD.organization_id)
       AND (to_jsonb(NEW) - 'intake_api_key_id') = (to_jsonb(OLD) - 'intake_api_key_id') THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'observations are immutable'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF NEW.sync_run_id IS NULL
   AND OLD.sync_run_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sync_runs WHERE id = OLD.sync_run_id)
   AND NEW.id IS NOT DISTINCT FROM OLD.id
   AND NEW.organization_id IS NOT DISTINCT FROM OLD.organization_id
   AND NEW.source_id IS NOT DISTINCT FROM OLD.source_id
   AND NEW.idempotency_key IS NOT DISTINCT FROM OLD.idempotency_key
   AND NEW.observed_at IS NOT DISTINCT FROM OLD.observed_at
   AND NEW.payload_digest IS NOT DISTINCT FROM OLD.payload_digest
   AND NEW.payload IS NOT DISTINCT FROM OLD.payload
   AND NEW.inserted_at IS NOT DISTINCT FROM OLD.inserted_at THEN
  RETURN NEW;
END IF;

  RAISE EXCEPTION 'observations are immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: reject_topology_snapshot_event_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_topology_snapshot_event_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'topology snapshot events are immutable'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: write_neighbor_view(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.write_neighbor_view() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE relation text := TG_TABLE_NAME || '_neighbor_storage'; columns text; BEGIN
  PERFORM materialize_neighbor_generation(COALESCE(NEW.organization_id, OLD.organization_id));
  IF TG_OP = 'DELETE' THEN EXECUTE 'DELETE FROM ' || relation || ' WHERE id = $1' USING OLD.id; RETURN OLD; END IF;
  IF TG_OP = 'INSERT' THEN
    EXECUTE 'INSERT INTO ' || relation || ' SELECT (jsonb_populate_record(NULL::' || relation || ', $1)).*' USING to_jsonb(NEW);
  ELSE
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO columns FROM pg_attribute a
      WHERE a.attrelid = relation::regclass AND a.attnum > 0 AND NOT a.attisdropped;
    EXECUTE 'UPDATE ' || relation || ' SET (' || columns || ') = (SELECT ' || columns || ' FROM jsonb_populate_record(NULL::' || relation || ', $1)) WHERE id = $2' USING to_jsonb(NEW), OLD.id;
  END IF;
  RETURN NEW;
END $_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_authorizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_authorizations (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    session_token_id uuid NOT NULL,
    purpose character varying(255) NOT NULL,
    expires_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT account_authorizations_valid_purpose CHECK (((purpose)::text = ANY ((ARRAY['recheck'::character varying, 'bootstrap'::character varying, 'recovery'::character varying])::text[])))
);


--
-- Name: account_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_challenges (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    session_token_id uuid NOT NULL,
    purpose character varying(255) NOT NULL,
    code_hash bytea NOT NULL,
    sent_to public.citext NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    expires_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: account_security_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_security_events (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: actual_component_evidence_matches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.actual_component_evidence_matches (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    owner_resource_id uuid NOT NULL,
    actual_component_id uuid NOT NULL,
    component_evidence_id uuid CONSTRAINT actual_component_evidence_matche_component_evidence_id_not_null NOT NULL,
    match_strategy character varying(255) NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT actual_component_evidence_matches_valid_strategy CHECK (((match_strategy)::text = ANY ((ARRAY['discovered'::character varying, 'serial_number'::character varying, 'provider_id'::character varying, 'position_part_number'::character varying])::text[])))
);


--
-- Name: actual_components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.actual_components (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    owner_resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'present'::character varying NOT NULL,
    name character varying(255),
    model character varying(255),
    slot character varying(255),
    path character varying(255),
    serial_number character varying(255),
    part_number character varying(255),
    attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    first_observed_at timestamp(3) without time zone NOT NULL,
    last_observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT actual_components_observation_order CHECK ((first_observed_at <= last_observed_at)),
    CONSTRAINT actual_components_valid_kind CHECK (((kind)::text = ANY ((ARRAY['cpu'::character varying, 'memory'::character varying, 'disk'::character varying])::text[]))),
    CONSTRAINT actual_components_valid_status CHECK (((status)::text = ANY ((ARRAY['present'::character varying, 'missing'::character varying, 'unknown'::character varying])::text[])))
);


--
-- Name: address_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.address_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    address_id uuid NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    address inet NOT NULL,
    scope character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: address_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.address_findings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    resolution_key text NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    message text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_observed_at timestamp(3) without time zone NOT NULL,
    resolved_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT address_findings_resolution_state CHECK (((((status)::text = 'open'::text) AND (resolved_at IS NULL)) OR (((status)::text = 'resolved'::text) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT address_findings_valid_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'resolved'::character varying])::text[])))
);


--
-- Name: addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.addresses (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    address inet NOT NULL,
    scope character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: addressing_plan_levels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.addressing_plan_levels (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    family character varying(255) NOT NULL,
    prefix_length integer NOT NULL,
    name character varying(255) NOT NULL,
    created_by_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT addressing_plan_levels_valid_length CHECK (((((family)::text = 'ipv4'::text) AND ((prefix_length >= 1) AND (prefix_length <= 31))) OR (((family)::text = 'ipv6'::text) AND ((prefix_length >= 1) AND (prefix_length <= 127)))))
);


--
-- Name: agent_leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_leases (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    renewed_at timestamp(3) without time zone NOT NULL,
    expires_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT agent_leases_expiry_after_renewal CHECK ((expires_at > renewed_at))
);


--
-- Name: agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agents (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    version character varying(255),
    capabilities character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    registered_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    installation_id uuid,
    last_contacted_at timestamp without time zone,
    CONSTRAINT agents_metadata_size CHECK ((octet_length((metadata)::text) <= 16000))
);


--
-- Name: background_cursors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.background_cursors (
    worker text NOT NULL,
    last_organization_id uuid
);


--
-- Name: cable_assertions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cable_assertions (
    id uuid NOT NULL,
    sequence bigint NOT NULL,
    organization_id uuid NOT NULL,
    interface_a_id uuid,
    interface_b_id uuid,
    kind character varying(255) NOT NULL,
    action character varying(255) NOT NULL,
    confirmation character varying(255) NOT NULL,
    actor_user_id uuid,
    source_id uuid,
    interface_neighbor_evidence_id uuid,
    asserted_at timestamp(3) without time zone NOT NULL,
    cable_type character varying(255),
    status character varying(255),
    label character varying(255),
    color character varying(255),
    length_value numeric(12,3),
    length_unit character varying(255),
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    cable_kind character varying(255) DEFAULT 'data'::character varying NOT NULL,
    power_port_id uuid,
    power_outlet_id uuid,
    power_feed_id uuid,
    actor_principal_id uuid,
    CONSTRAINT cable_assertions_attribution_shape CHECK ((((((kind)::text = 'operator'::text) AND ((actor_user_id IS NOT NULL) OR (actor_principal_id IS NOT NULL)) AND (source_id IS NULL) AND (interface_neighbor_evidence_id IS NULL)) OR (((kind)::text = 'import'::text) AND (actor_user_id IS NULL) AND (source_id IS NOT NULL) AND (interface_neighbor_evidence_id IS NULL)) OR (((kind)::text = 'neighbor_evidence'::text) AND (actor_user_id IS NULL) AND (source_id IS NULL) AND (interface_neighbor_evidence_id IS NOT NULL))) IS TRUE)),
    CONSTRAINT cable_assertions_canonical_order CHECK ((interface_a_id < interface_b_id)),
    CONSTRAINT cable_assertions_color_format CHECK (((color IS NULL) OR ((color)::text ~ '^#[0-9a-fA-F]{6}$'::text))),
    CONSTRAINT cable_assertions_confirmation_shape CHECK (((((kind)::text = 'neighbor_evidence'::text) AND ((confirmation)::text = 'proposed'::text)) OR (((kind)::text <> 'neighbor_evidence'::text) AND ((confirmation)::text = 'confirmed'::text)))),
    CONSTRAINT cable_assertions_endpoint_shape CHECK (((((cable_kind)::text = 'data'::text) AND (interface_a_id IS NOT NULL) AND (interface_b_id IS NOT NULL) AND (power_port_id IS NULL) AND (power_outlet_id IS NULL) AND (power_feed_id IS NULL)) OR (((cable_kind)::text = 'power'::text) AND (interface_a_id IS NULL) AND (interface_b_id IS NULL) AND (power_port_id IS NOT NULL) AND (num_nonnulls(power_outlet_id, power_feed_id) = 1)))),
    CONSTRAINT cable_assertions_evidence_is_data CHECK ((((kind)::text <> 'neighbor_evidence'::text) OR ((cable_kind)::text = 'data'::text))),
    CONSTRAINT cable_assertions_length_pair CHECK (((length_value IS NULL) = (length_unit IS NULL))),
    CONSTRAINT cable_assertions_positive_length CHECK (((length_value IS NULL) OR (length_value > (0)::numeric))),
    CONSTRAINT cable_assertions_retract_shape CHECK ((((action)::text = 'assert'::text) OR ((cable_type IS NULL) AND (status IS NULL) AND (label IS NULL) AND (color IS NULL) AND (length_value IS NULL) AND (length_unit IS NULL) AND (description IS NULL) AND (metadata = '{}'::jsonb)))),
    CONSTRAINT cable_assertions_valid_action CHECK (((action)::text = ANY ((ARRAY['assert'::character varying, 'retract'::character varying])::text[]))),
    CONSTRAINT cable_assertions_valid_confirmation CHECK (((confirmation)::text = ANY ((ARRAY['confirmed'::character varying, 'proposed'::character varying])::text[]))),
    CONSTRAINT cable_assertions_valid_kind CHECK (((kind)::text = ANY ((ARRAY['operator'::character varying, 'import'::character varying, 'neighbor_evidence'::character varying])::text[]))),
    CONSTRAINT cable_assertions_valid_length_unit CHECK (((length_unit IS NULL) OR ((length_unit)::text = ANY ((ARRAY['m'::character varying, 'cm'::character varying, 'ft'::character varying, 'in'::character varying])::text[])))),
    CONSTRAINT cable_assertions_valid_status CHECK (((status IS NULL) OR ((status)::text = ANY ((ARRAY['planned'::character varying, 'connected'::character varying, 'decommissioning'::character varying])::text[]))))
);


--
-- Name: cable_assertions_sequence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cable_assertions_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cable_assertions_sequence_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cable_assertions_sequence_seq OWNED BY public.cable_assertions.sequence;


--
-- Name: cable_change_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cable_change_events (
    id uuid NOT NULL,
    sequence bigint NOT NULL,
    organization_id uuid NOT NULL,
    cable_id uuid NOT NULL,
    assertion_id uuid,
    interface_a_id uuid,
    interface_b_id uuid,
    source_id uuid,
    action character varying(255) NOT NULL,
    changes jsonb DEFAULT '{}'::jsonb NOT NULL,
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp(3) without time zone NOT NULL,
    actor_user_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    cable_kind character varying(255) DEFAULT 'data'::character varying NOT NULL,
    power_port_id uuid,
    power_outlet_id uuid,
    power_feed_id uuid,
    CONSTRAINT cable_change_events_valid_action CHECK (((action)::text = ANY ((ARRAY['created'::character varying, 'updated'::character varying, 'removed'::character varying])::text[])))
);


--
-- Name: cable_change_events_sequence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cable_change_events_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cable_change_events_sequence_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cable_change_events_sequence_seq OWNED BY public.cable_change_events.sequence;


--
-- Name: cable_endpoint_terminations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cable_endpoint_terminations (
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    cable_id uuid NOT NULL
);


--
-- Name: cable_import_contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cable_import_contracts (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    granted_by_id uuid,
    granted_at timestamp(3) without time zone NOT NULL,
    revoked_by_id uuid,
    revoked_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: cable_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cable_plans (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_a_id uuid,
    interface_b_id uuid,
    cable_type character varying(255),
    status character varying(255) DEFAULT 'planned'::character varying NOT NULL,
    label character varying(255),
    color character varying(255),
    length_value numeric(12,3),
    length_unit character varying(255),
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    cable_kind character varying(255) DEFAULT 'data'::character varying NOT NULL,
    power_port_id uuid,
    power_outlet_id uuid,
    power_feed_id uuid,
    CONSTRAINT cable_plans_canonical_order CHECK ((interface_a_id < interface_b_id)),
    CONSTRAINT cable_plans_color_format CHECK (((color IS NULL) OR ((color)::text ~ '^#[0-9a-fA-F]{6}$'::text))),
    CONSTRAINT cable_plans_endpoint_shape CHECK (((((cable_kind)::text = 'data'::text) AND (interface_a_id IS NOT NULL) AND (interface_b_id IS NOT NULL) AND (power_port_id IS NULL) AND (power_outlet_id IS NULL) AND (power_feed_id IS NULL)) OR (((cable_kind)::text = 'power'::text) AND (interface_a_id IS NULL) AND (interface_b_id IS NULL) AND (power_port_id IS NOT NULL) AND (num_nonnulls(power_outlet_id, power_feed_id) = 1)))),
    CONSTRAINT cable_plans_length_pair CHECK (((length_value IS NULL) = (length_unit IS NULL))),
    CONSTRAINT cable_plans_positive_length CHECK (((length_value IS NULL) OR (length_value > (0)::numeric))),
    CONSTRAINT cable_plans_valid_length_unit CHECK (((length_unit IS NULL) OR ((length_unit)::text = ANY ((ARRAY['m'::character varying, 'cm'::character varying, 'ft'::character varying, 'in'::character varying])::text[])))),
    CONSTRAINT cable_plans_valid_status CHECK (((status)::text = ANY ((ARRAY['planned'::character varying, 'connected'::character varying, 'decommissioning'::character varying])::text[])))
);


--
-- Name: cables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cables (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_a_id uuid,
    interface_b_id uuid,
    primary_assertion_id uuid NOT NULL,
    cable_type character varying(255),
    status character varying(255) DEFAULT 'connected'::character varying NOT NULL,
    label character varying(255),
    color character varying(255),
    length_value numeric(12,3),
    length_unit character varying(255),
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_asserted_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    cable_kind character varying(255) DEFAULT 'data'::character varying NOT NULL,
    power_port_id uuid,
    power_outlet_id uuid,
    power_feed_id uuid,
    CONSTRAINT cables_canonical_order CHECK ((interface_a_id < interface_b_id)),
    CONSTRAINT cables_color_format CHECK (((color IS NULL) OR ((color)::text ~ '^#[0-9a-fA-F]{6}$'::text))),
    CONSTRAINT cables_endpoint_shape CHECK (((((cable_kind)::text = 'data'::text) AND (interface_a_id IS NOT NULL) AND (interface_b_id IS NOT NULL) AND (power_port_id IS NULL) AND (power_outlet_id IS NULL) AND (power_feed_id IS NULL)) OR (((cable_kind)::text = 'power'::text) AND (interface_a_id IS NULL) AND (interface_b_id IS NULL) AND (power_port_id IS NOT NULL) AND (num_nonnulls(power_outlet_id, power_feed_id) = 1)))),
    CONSTRAINT cables_length_pair CHECK (((length_value IS NULL) = (length_unit IS NULL))),
    CONSTRAINT cables_positive_length CHECK (((length_value IS NULL) OR (length_value > (0)::numeric))),
    CONSTRAINT cables_valid_length_unit CHECK (((length_unit IS NULL) OR ((length_unit)::text = ANY ((ARRAY['m'::character varying, 'cm'::character varying, 'ft'::character varying, 'in'::character varying])::text[])))),
    CONSTRAINT cables_valid_status CHECK (((status)::text = ANY ((ARRAY['planned'::character varying, 'connected'::character varying, 'decommissioning'::character varying])::text[])))
);


--
-- Name: catalog_type_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_type_revisions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    hardware_type_id uuid,
    module_type_id uuid,
    revision integer NOT NULL,
    part_number character varying(255),
    height_units integer,
    width_mm numeric(10,2),
    depth_mm numeric(10,2),
    weight_kg numeric(10,3),
    airflow character varying(255),
    specifications jsonb DEFAULT '{}'::jsonb NOT NULL,
    finalized_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT catalog_type_revisions_one_owner CHECK ((((hardware_type_id IS NOT NULL) AND (module_type_id IS NULL)) OR ((hardware_type_id IS NULL) AND (module_type_id IS NOT NULL)))),
    CONSTRAINT catalog_type_revisions_valid_dimensions CHECK (((revision > 0) AND ((height_units IS NULL) OR (height_units > 0)) AND ((width_mm IS NULL) OR (width_mm > (0)::numeric)) AND ((depth_mm IS NULL) OR (depth_mm > (0)::numeric)) AND ((weight_kg IS NULL) OR (weight_kg > (0)::numeric))))
);


--
-- Name: change_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.change_events (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid,
    source_id uuid,
    sync_run_id uuid,
    observation_id uuid,
    kind character varying(255) NOT NULL,
    field character varying(255),
    old_value jsonb,
    new_value jsonb,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    actor_user_id uuid,
    finding_workflow_id uuid
);


--
-- Name: change_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.change_requests (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    field character varying(255) DEFAULT ''::character varying NOT NULL,
    before_value jsonb,
    after_value jsonb NOT NULL,
    reason text NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    requested_by_user_id uuid,
    decided_by_user_id uuid,
    decided_at timestamp without time zone,
    decision_note text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT change_requests_decision_state CHECK (((((status)::text = 'open'::text) AND (decided_at IS NULL)) OR (((status)::text <> 'open'::text) AND (decided_at IS NOT NULL)))),
    CONSTRAINT change_requests_valid_kind CHECK (((kind)::text = ANY ((ARRAY['lifecycle'::character varying, 'field_override'::character varying, 'owner'::character varying, 'expectation'::character varying, 'adoption'::character varying])::text[]))),
    CONSTRAINT change_requests_valid_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'approved'::character varying, 'rejected'::character varying, 'withdrawn'::character varying])::text[])))
);


--
-- Name: collector_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collector_findings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    agent_id uuid,
    kind character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    message text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_observed_at timestamp(3) without time zone NOT NULL,
    resolved_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    target_id uuid,
    CONSTRAINT collector_findings_valid CHECK ((((status)::text = ANY ((ARRAY['open'::character varying, 'resolved'::character varying])::text[])) AND (((status)::text = 'resolved'::text) = (resolved_at IS NOT NULL)) AND ((kind)::text = ANY ((ARRAY['installation_key_changed'::character varying, 'possible_same_machine'::character varying, 'target_unreachable'::character varying, 'vm_active_on_two_hypervisors'::character varying, 'guest_without_vm'::character varying])::text[])) AND (((kind)::text = 'target_unreachable'::text) = (target_id IS NOT NULL)) AND (((kind)::text = 'vm_active_on_two_hypervisors'::text) = (agent_id IS NULL))))
);


--
-- Name: collector_target_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collector_target_resources (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    target_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    first_reported_at timestamp(3) without time zone NOT NULL,
    last_reported_at timestamp(3) without time zone NOT NULL,
    withdrawn_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    domain jsonb,
    domain_reported_at timestamp(3) without time zone,
    active_since timestamp(3) without time zone
);


--
-- Name: collector_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collector_targets (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    key character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    error character varying(255),
    last_reported_at timestamp(3) without time zone NOT NULL,
    last_reachable_at timestamp(3) without time zone,
    last_complete_at timestamp(3) without time zone,
    last_observation_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT collector_targets_status CHECK (((status)::text = ANY ((ARRAY['reachable'::character varying, 'unreachable'::character varying])::text[])))
);


--
-- Name: component_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.component_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    source_local_id character varying(255) NOT NULL,
    name character varying(255),
    model character varying(255),
    slot character varying(255),
    path character varying(255),
    serial_number character varying(255),
    part_number character varying(255),
    attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT component_evidence_module_position CHECK ((((kind)::text <> 'module'::text) OR (NULLIF(btrim((slot)::text), ''::text) IS NOT NULL) OR (NULLIF(btrim((path)::text), ''::text) IS NOT NULL))),
    CONSTRAINT component_evidence_valid_kind CHECK (((kind)::text = ANY ((ARRAY['cpu'::character varying, 'memory'::character varying, 'disk'::character varying, 'module'::character varying])::text[])))
);


--
-- Name: component_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.component_findings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    resolution_key character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    message text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    resolved_at timestamp(3) without time zone,
    last_observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT component_findings_resolution_state CHECK (((((status)::text = 'open'::text) AND (resolved_at IS NULL)) OR (((status)::text = 'resolved'::text) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT component_findings_valid_kind CHECK (((kind)::text = ANY ((ARRAY['ambiguous_component_identity'::character varying, 'ambiguous_expected_component'::character varying, 'unexpected_actual_component'::character varying, 'component_drift'::character varying, 'missing_expected_component'::character varying, 'module_bay_not_found'::character varying, 'ambiguous_module_bay'::character varying, 'module_type_not_found'::character varying, 'ambiguous_module_type'::character varying, 'incompatible_module_type'::character varying])::text[]))),
    CONSTRAINT component_findings_valid_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'resolved'::character varying])::text[])))
);


--
-- Name: component_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.component_templates (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    catalog_type_revision_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    label character varying(255),
    "position" character varying(255),
    description text,
    required boolean DEFAULT true NOT NULL,
    attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: confirmed_components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.confirmed_components (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    hardware_assignment_id uuid NOT NULL,
    component_template_id uuid,
    exception_id uuid,
    part_number character varying(255),
    serial_number character varying(255),
    model character varying(255),
    note text,
    confirmed_by_user_id uuid,
    confirmed_at timestamp without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT confirmed_components_identifies_part CHECK ((num_nonnulls(part_number, serial_number, model) > 0)),
    CONSTRAINT confirmed_components_one_expectation CHECK ((num_nonnulls(component_template_id, exception_id) = 1))
);


--
-- Name: current_interface_adjacencies_neighbor_storage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.current_interface_adjacencies_neighbor_storage (
    id uuid CONSTRAINT current_interface_adjacencies_id_not_null NOT NULL,
    organization_id uuid CONSTRAINT current_interface_adjacencies_organization_id_not_null NOT NULL,
    interface_a_id uuid CONSTRAINT current_interface_adjacencies_interface_a_id_not_null NOT NULL,
    interface_b_id uuid CONSTRAINT current_interface_adjacencies_interface_b_id_not_null NOT NULL,
    primary_evidence_id uuid CONSTRAINT current_interface_adjacencies_primary_evidence_id_not_null NOT NULL,
    confidence character varying(255) CONSTRAINT current_interface_adjacencies_confidence_not_null NOT NULL,
    last_observed_at timestamp(3) without time zone CONSTRAINT current_interface_adjacencies_last_observed_at_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT current_interface_adjacencies_metadata_not_null NOT NULL,
    inserted_at timestamp(3) without time zone CONSTRAINT current_interface_adjacencies_inserted_at_not_null NOT NULL,
    updated_at timestamp(3) without time zone CONSTRAINT current_interface_adjacencies_updated_at_not_null NOT NULL,
    CONSTRAINT current_interface_adjacencies_canonical_order CHECK ((interface_a_id < interface_b_id)),
    CONSTRAINT current_interface_adjacencies_valid_confidence CHECK (((confidence)::text = ANY ((ARRAY['reported'::character varying, 'reciprocal'::character varying])::text[])))
);


--
-- Name: neighbor_generation_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.neighbor_generation_rows (
    generation_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    kind text NOT NULL,
    key text NOT NULL,
    payload jsonb NOT NULL,
    deleted boolean DEFAULT false NOT NULL,
    processed boolean DEFAULT false NOT NULL,
    reciprocal boolean DEFAULT false NOT NULL,
    observed_at timestamp without time zone,
    observation_id uuid,
    endpoint_a uuid,
    endpoint_b uuid
);


--
-- Name: neighbor_generations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.neighbor_generations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    watermark bigint NOT NULL,
    as_of timestamp without time zone NOT NULL,
    phase text DEFAULT 'matches'::text NOT NULL,
    cursor uuid,
    status text DEFAULT 'building'::text NOT NULL
);


--
-- Name: current_interface_adjacencies; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.current_interface_adjacencies AS
 SELECT b.id,
    b.organization_id,
    b.interface_a_id,
    b.interface_b_id,
    b.primary_evidence_id,
    b.confidence,
    b.last_observed_at,
    b.metadata,
    b.inserted_at,
    b.updated_at
   FROM public.current_interface_adjacencies_neighbor_storage b
  WHERE (NOT (EXISTS ( SELECT 1
           FROM public.neighbor_generations g
          WHERE ((g.id = public.neighbor_read_generation(b.organization_id)) AND (g.organization_id = b.organization_id) AND true))))
UNION ALL
 SELECT ((r.payload ->> 'id'::text))::uuid AS id,
    r.organization_id,
    ((r.payload ->> 'interface_a_id'::text))::uuid AS interface_a_id,
    ((r.payload ->> 'interface_b_id'::text))::uuid AS interface_b_id,
    ((r.payload ->> 'primary_evidence_id'::text))::uuid AS primary_evidence_id,
    typed.confidence,
    typed.last_observed_at,
    typed.metadata,
    typed.inserted_at,
    typed.updated_at
   FROM ((public.neighbor_generation_rows r
     JOIN public.neighbor_generations g ON ((g.id = r.generation_id)))
     CROSS JOIN LATERAL jsonb_populate_record(NULL::public.current_interface_adjacencies_neighbor_storage, r.payload) typed(id, organization_id, interface_a_id, interface_b_id, primary_evidence_id, confidence, last_observed_at, metadata, inserted_at, updated_at))
  WHERE ((r.kind = 'current_interface_adjacencies'::text) AND (NOT r.deleted) AND (g.organization_id = r.organization_id) AND (g.id = public.neighbor_read_generation(r.organization_id)));


--
-- Name: current_interface_adjacency_endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.current_interface_adjacency_endpoints (
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    adjacency_id uuid NOT NULL
);


--
-- Name: current_interface_vlan_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.current_interface_vlan_memberships (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    vlan_id uuid NOT NULL,
    tagging_mode character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    interface_vlan_evidence_id uuid CONSTRAINT current_interface_vlan_memb_interface_vlan_evidence_id_not_null NOT NULL,
    CONSTRAINT current_interface_vlan_memberships_valid_tagging_mode CHECK (((tagging_mode)::text = ANY ((ARRAY['tagged'::character varying, 'untagged'::character varying])::text[])))
);


--
-- Name: current_interface_vlan_modes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.current_interface_vlan_modes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    mode character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    interface_vlan_mode_evidence_id uuid CONSTRAINT current_interface_vlan_mode_interface_vlan_mode_eviden_not_null NOT NULL,
    CONSTRAINT current_interface_vlan_modes_valid_mode CHECK (((mode)::text = ANY ((ARRAY['access'::character varying, 'trunk'::character varying, 'tagged_all'::character varying])::text[])))
);


--
-- Name: current_module_installations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.current_module_installations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    module_bay_id uuid NOT NULL,
    module_id uuid NOT NULL,
    module_type_id uuid NOT NULL,
    installed_at timestamp(3) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: current_placements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.current_placements (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_id uuid NOT NULL,
    location_id uuid,
    rack_id uuid,
    "position" integer,
    height_units integer,
    face character varying(255),
    confirmed boolean DEFAULT false NOT NULL,
    provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT current_placements_valid_rack_position CHECK ((((rack_id IS NULL) AND ("position" IS NULL) AND (height_units IS NULL) AND (face IS NULL)) OR ((rack_id IS NOT NULL) AND ((("position" IS NULL) AND (height_units IS NULL) AND (face IS NULL)) OR (("position" > 0) AND (height_units > 0) AND ((face)::text = ANY ((ARRAY['front'::character varying, 'rear'::character varying, 'full'::character varying])::text[])))))))
);


--
-- Name: deployment_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deployment_audit_events (
    id uuid NOT NULL,
    operation character varying(255) NOT NULL,
    outcome character varying(255) NOT NULL,
    actor text NOT NULL,
    actor_token_id uuid,
    invocation_id character varying(255) NOT NULL,
    target_id character varying(255),
    organization_id uuid,
    organization_name text,
    changed character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    reason character varying(255),
    inserted_at timestamp(3) without time zone NOT NULL,
    actor_user_id uuid
);


--
-- Name: desired_interface_vlan_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.desired_interface_vlan_assignments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    vlan_id uuid NOT NULL,
    tagging_mode character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT desired_interface_vlan_assignments_valid_tagging_mode CHECK (((tagging_mode)::text = ANY ((ARRAY['tagged'::character varying, 'untagged'::character varying])::text[])))
);


--
-- Name: desired_interface_vlan_modes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.desired_interface_vlan_modes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    mode character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT desired_interface_vlan_modes_valid_mode CHECK (((mode)::text = ANY ((ARRAY['access'::character varying, 'trunk'::character varying, 'tagged_all'::character varying])::text[])))
);


--
-- Name: desired_module_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.desired_module_assignments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    module_bay_id uuid NOT NULL,
    module_type_id uuid NOT NULL,
    confirmed_by_user_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    confirmed_by_principal_id uuid,
    CONSTRAINT confirmed_by_someone CHECK (((confirmed_by_user_id IS NOT NULL) OR (confirmed_by_principal_id IS NOT NULL)))
);


--
-- Name: desired_placements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.desired_placements (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_id uuid NOT NULL,
    location_id uuid,
    rack_id uuid,
    "position" integer,
    height_units integer,
    face character varying(255),
    confirmed boolean DEFAULT false NOT NULL,
    provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT desired_placements_valid_rack_position CHECK ((((rack_id IS NULL) AND ("position" IS NULL) AND (height_units IS NULL) AND (face IS NULL)) OR ((rack_id IS NOT NULL) AND ((("position" IS NULL) AND (height_units IS NULL) AND (face IS NULL)) OR (("position" > 0) AND (height_units > 0) AND ((face)::text = ANY ((ARRAY['front'::character varying, 'rear'::character varying, 'full'::character varying])::text[])))))))
);


--
-- Name: expected_component_exceptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expected_component_exceptions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    hardware_assignment_id uuid NOT NULL,
    catalog_type_revision_id uuid NOT NULL,
    component_template_id uuid,
    action character varying(255) NOT NULL,
    kind character varying(255),
    name character varying(255),
    changes jsonb DEFAULT '{}'::jsonb NOT NULL,
    confirmed_by_user_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    confirmed_by_principal_id uuid,
    CONSTRAINT confirmed_by_someone CHECK (((confirmed_by_user_id IS NOT NULL) OR (confirmed_by_principal_id IS NOT NULL))),
    CONSTRAINT expected_component_exceptions_valid_shape CHECK (((((action)::text = 'add'::text) AND (component_template_id IS NULL) AND (kind IS NOT NULL) AND (name IS NOT NULL)) OR (((action)::text = ANY ((ARRAY['suppress'::character varying, 'alter'::character varying])::text[])) AND (component_template_id IS NOT NULL))))
);


--
-- Name: expected_components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expected_components (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    hardware_assignment_id uuid NOT NULL,
    catalog_type_revision_id uuid NOT NULL,
    component_template_id uuid,
    exception_id uuid,
    kind character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    label character varying(255),
    "position" character varying(255),
    description text,
    required boolean NOT NULL,
    suppressed boolean DEFAULT false NOT NULL,
    attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: finding_workflows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finding_workflows (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    domain character varying(255) NOT NULL,
    subject_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    resolution_key text DEFAULT ''::character varying NOT NULL,
    assignee_user_id uuid,
    snoozed_until timestamp without time zone,
    exception_reason text,
    exception_expires_at timestamp without time zone,
    exception_at timestamp without time zone,
    exception_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT finding_workflows_exception_state CHECK ((((exception_reason IS NULL) AND (exception_at IS NULL) AND (exception_expires_at IS NULL)) OR ((exception_reason IS NOT NULL) AND (exception_at IS NOT NULL)))),
    CONSTRAINT finding_workflows_valid_domain CHECK (((domain)::text = ANY ((ARRAY['component'::character varying, 'hardware_match'::character varying, 'placement'::character varying, 'topology'::character varying, 'address'::character varying, 'collector'::character varying, 'power'::character varying])::text[])))
);


--
-- Name: hardware_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hardware_assignments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    hardware_type_id uuid NOT NULL,
    catalog_type_revision_id uuid NOT NULL,
    origin character varying(255) NOT NULL,
    provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT hardware_assignments_valid_origin CHECK (((origin)::text = ANY ((ARRAY['operator'::character varying, 'reconciled'::character varying])::text[])))
);


--
-- Name: hardware_match_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hardware_match_findings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    message text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    resolved_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: hardware_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hardware_types (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    manufacturer_id uuid NOT NULL,
    model character varying(255) NOT NULL,
    device_class character varying(255) NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    auto_move boolean DEFAULT false NOT NULL
);


--
-- Name: hosts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hosts (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    hostname character varying(255),
    fqdn character varying(255),
    vendor character varying(255),
    model character varying(255),
    asset_tag character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: identity_provider_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_provider_attempts (
    id uuid NOT NULL,
    provider_id character varying(255) NOT NULL,
    revision integer NOT NULL,
    state_hash bytea NOT NULL,
    expires_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    purpose character varying(255) DEFAULT 'sign_in'::character varying NOT NULL,
    user_id uuid,
    session_token_id uuid,
    CONSTRAINT purpose_binding CHECK (((((purpose)::text = 'sign_in'::text) AND (user_id IS NULL) AND (session_token_id IS NULL)) OR (((purpose)::text = ANY ((ARRAY['link'::character varying, 'recheck'::character varying])::text[])) AND (user_id IS NOT NULL) AND (session_token_id IS NOT NULL))))
);


--
-- Name: identity_provider_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_provider_events (
    id uuid NOT NULL,
    provider_id character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    revision integer,
    changed character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    actor character varying(255) NOT NULL,
    actor_user_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: identity_provider_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_provider_revisions (
    id uuid NOT NULL,
    provider_id character varying(255) NOT NULL,
    number integer NOT NULL,
    client_id character varying(255) NOT NULL,
    client_secret_ciphertext bytea,
    client_secret_key_id character varying(255),
    client_secret_set_at timestamp(3) without time zone,
    scopes character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    email_domains character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    allow_sign_up boolean DEFAULT false NOT NULL,
    session_lifetime_seconds integer NOT NULL,
    created_by character varying(255) NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: identity_provider_tests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_provider_tests (
    id uuid NOT NULL,
    provider_id character varying(255) NOT NULL,
    revision integer NOT NULL,
    token_hash bytea NOT NULL,
    state_hash bytea,
    nonce character varying(255),
    verifier character varying(255),
    actor character varying(255) NOT NULL,
    actor_user_id uuid,
    expires_at timestamp(3) without time zone NOT NULL,
    started_at timestamp(3) without time zone,
    completed_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: identity_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_providers (
    id character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    issuer character varying(255),
    organization_id uuid,
    display_name character varying(255) NOT NULL,
    icon character varying(255),
    hidden boolean DEFAULT false NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    active_revision integer,
    pending_revision integer,
    version bigint DEFAULT 1 NOT NULL,
    removed_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    enforces_mfa boolean DEFAULT false NOT NULL,
    mfa_amr_combinations character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    CONSTRAINT github_never_enforces_mfa CHECK ((((kind)::text <> 'github'::text) OR (NOT enforces_mfa))),
    CONSTRAINT kind_issuer CHECK (((((kind)::text = 'oidc'::text) AND (issuer IS NOT NULL)) OR (((kind)::text = 'github'::text) AND (issuer IS NULL))))
);


--
-- Name: imported_attributions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.imported_attributions (
    organization_id uuid NOT NULL,
    record_type character varying(255) NOT NULL,
    record_id uuid NOT NULL,
    field character varying(255) NOT NULL,
    principal_id uuid NOT NULL
);


--
-- Name: imported_held_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.imported_held_records (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    principal_id uuid NOT NULL,
    record_type character varying(255) NOT NULL,
    record jsonb NOT NULL
);


--
-- Name: imported_principals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.imported_principals (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    organization_import_id uuid NOT NULL,
    source_id uuid NOT NULL,
    email public.citext,
    user_id uuid,
    linked_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: installation_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.installation_keys (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    algorithm character varying(255) NOT NULL,
    public_key bytea NOT NULL,
    fingerprint character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    first_presented_at timestamp(3) without time zone NOT NULL,
    last_presented_at timestamp(3) without time zone NOT NULL,
    approved_at timestamp(3) without time zone,
    approved_by_user_id uuid,
    replaced_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT installation_keys_valid CHECK ((((algorithm)::text = 'ed25519'::text) AND (octet_length(public_key) = 32) AND ((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'replaced'::character varying])::text[])) AND (((status)::text = 'approved'::text) = ((approved_at IS NOT NULL) AND (replaced_at IS NULL))) AND (((status)::text = 'replaced'::text) = (replaced_at IS NOT NULL))))
);


--
-- Name: intake_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intake_api_keys (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    token_hash bytea NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    deployment_id character varying(255),
    CONSTRAINT intake_api_keys_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'revoked'::character varying])::text[])))
);


--
-- Name: interface_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    mac_address macaddr,
    kind character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    mtu integer,
    speed_mbps integer,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    component_template_id uuid,
    catalog_match_status character varying(255),
    catalog_match_strategy character varying(255),
    CONSTRAINT interface_evidence_catalog_match_shape CHECK (((((catalog_match_status IS NULL) AND (component_template_id IS NULL) AND (catalog_match_strategy IS NULL)) OR (((catalog_match_status)::text = 'matched'::text) AND (component_template_id IS NOT NULL) AND ((catalog_match_strategy)::text = ANY ((ARRAY['mac_address'::character varying, 'name'::character varying])::text[]))) OR (((catalog_match_status)::text = ANY ((ARRAY['unmatched'::character varying, 'ambiguous'::character varying])::text[])) AND (component_template_id IS NULL) AND (catalog_match_strategy IS NULL))) IS TRUE)),
    CONSTRAINT interface_evidence_mtu_speed_positive CHECK ((((mtu IS NULL) OR (mtu > 0)) AND ((speed_mbps IS NULL) OR (speed_mbps > 0))))
);


--
-- Name: interface_neighbor_evidence_neighbor_storage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_neighbor_evidence_neighbor_storage (
    id uuid CONSTRAINT interface_neighbor_evidence_id_not_null NOT NULL,
    organization_id uuid CONSTRAINT interface_neighbor_evidence_organization_id_not_null NOT NULL,
    local_interface_id uuid CONSTRAINT interface_neighbor_evidence_local_interface_id_not_null NOT NULL,
    source_id uuid CONSTRAINT interface_neighbor_evidence_source_id_not_null NOT NULL,
    observation_id uuid CONSTRAINT interface_neighbor_evidence_observation_id_not_null NOT NULL,
    protocol character varying(255) CONSTRAINT interface_neighbor_evidence_protocol_not_null NOT NULL,
    remote_chassis_id character varying(255) CONSTRAINT interface_neighbor_evidence_remote_chassis_id_not_null NOT NULL,
    remote_chassis_id_kind character varying(255),
    remote_chassis_id_normalized character varying(255) CONSTRAINT interface_neighbor_evidence_remote_chassis_id_normaliz_not_null NOT NULL,
    remote_system_name character varying(255),
    remote_port_id character varying(255) CONSTRAINT interface_neighbor_evidence_remote_port_id_not_null NOT NULL,
    remote_port_id_kind character varying(255),
    remote_port_id_normalized character varying(255) CONSTRAINT interface_neighbor_evidence_remote_port_id_normalized_not_null NOT NULL,
    remote_port_description character varying(255),
    ttl_seconds integer CONSTRAINT interface_neighbor_evidence_ttl_seconds_not_null NOT NULL,
    observed_at timestamp(3) without time zone CONSTRAINT interface_neighbor_evidence_observed_at_not_null NOT NULL,
    expires_at timestamp(3) without time zone CONSTRAINT interface_neighbor_evidence_expires_at_not_null NOT NULL,
    stale_at timestamp(3) without time zone,
    stale_reason character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT interface_neighbor_evidence_metadata_not_null NOT NULL,
    inserted_at timestamp(3) without time zone CONSTRAINT interface_neighbor_evidence_inserted_at_not_null NOT NULL,
    CONSTRAINT interface_neighbor_evidence_stale_shape CHECK ((((stale_at IS NULL) AND (stale_reason IS NULL)) OR ((stale_at IS NOT NULL) AND (stale_reason IS NOT NULL) AND ((stale_reason)::text = ANY ((ARRAY['expired'::character varying, 'superseded'::character varying, 'withdrawn'::character varying])::text[]))))),
    CONSTRAINT interface_neighbor_evidence_valid_id_kinds CHECK ((((remote_chassis_id_kind IS NULL) OR ((remote_chassis_id_kind)::text = ANY ((ARRAY['mac_address'::character varying, 'network_address'::character varying, 'local'::character varying, 'name'::character varying])::text[]))) AND ((remote_port_id_kind IS NULL) OR ((remote_port_id_kind)::text = ANY ((ARRAY['mac_address'::character varying, 'local'::character varying, 'name'::character varying])::text[]))))),
    CONSTRAINT interface_neighbor_evidence_valid_protocol CHECK (((protocol)::text = ANY ((ARRAY['lldp'::character varying, 'cdp'::character varying])::text[]))),
    CONSTRAINT interface_neighbor_evidence_valid_ttl CHECK ((((ttl_seconds >= 1) AND (ttl_seconds <= 65535)) AND (expires_at > observed_at)))
);


--
-- Name: interface_neighbor_evidence; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.interface_neighbor_evidence AS
 SELECT b.id,
    b.organization_id,
    b.local_interface_id,
    b.source_id,
    b.observation_id,
    b.protocol,
    b.remote_chassis_id,
    b.remote_chassis_id_kind,
    b.remote_chassis_id_normalized,
    b.remote_system_name,
    b.remote_port_id,
    b.remote_port_id_kind,
    b.remote_port_id_normalized,
    b.remote_port_description,
    b.ttl_seconds,
    b.observed_at,
    b.expires_at,
        CASE
            WHEN ((b.stale_at IS NULL) AND (b.expires_at <= g.as_of)) THEN b.expires_at
            ELSE b.stale_at
        END AS stale_at,
        CASE
            WHEN ((b.stale_at IS NULL) AND (b.expires_at <= g.as_of)) THEN 'expired'::character varying
            ELSE b.stale_reason
        END AS stale_reason,
    b.metadata,
    b.inserted_at
   FROM (public.interface_neighbor_evidence_neighbor_storage b
     LEFT JOIN public.neighbor_generations g ON (((g.id = public.neighbor_read_generation(b.organization_id)) AND (g.organization_id = b.organization_id))));


--
-- Name: interface_neighbor_matches_neighbor_storage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_neighbor_matches_neighbor_storage (
    id uuid CONSTRAINT interface_neighbor_matches_id_not_null NOT NULL,
    organization_id uuid CONSTRAINT interface_neighbor_matches_organization_id_not_null NOT NULL,
    interface_neighbor_evidence_id uuid CONSTRAINT interface_neighbor_matches_interface_neighbor_evidence_not_null NOT NULL,
    remote_interface_id uuid,
    status character varying(255) CONSTRAINT interface_neighbor_matches_status_not_null NOT NULL,
    strategy character varying(255),
    candidate_count integer DEFAULT 0 CONSTRAINT interface_neighbor_matches_candidate_count_not_null NOT NULL,
    inserted_at timestamp(3) without time zone CONSTRAINT interface_neighbor_matches_inserted_at_not_null NOT NULL,
    updated_at timestamp(3) without time zone CONSTRAINT interface_neighbor_matches_updated_at_not_null NOT NULL,
    CONSTRAINT interface_neighbor_matches_status_shape CHECK (((((status)::text = 'matched'::text) AND (remote_interface_id IS NOT NULL) AND (strategy IS NOT NULL) AND (candidate_count = 1)) OR (((status)::text = ANY ((ARRAY['unresolved'::character varying, 'ambiguous'::character varying])::text[])) AND (remote_interface_id IS NULL) AND (strategy IS NULL) AND (candidate_count >= 0)))),
    CONSTRAINT interface_neighbor_matches_valid_strategy CHECK (((strategy IS NULL) OR ((strategy)::text = ANY ((ARRAY['stable_identifiers'::character varying, 'name_fallback'::character varying])::text[]))))
);


--
-- Name: interface_neighbor_matches; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.interface_neighbor_matches AS
 SELECT b.id,
    b.organization_id,
    b.interface_neighbor_evidence_id,
    b.remote_interface_id,
    b.status,
    b.strategy,
    b.candidate_count,
    b.inserted_at,
    b.updated_at
   FROM public.interface_neighbor_matches_neighbor_storage b
  WHERE (NOT (EXISTS ( SELECT 1
           FROM public.neighbor_generations g
          WHERE ((g.id = public.neighbor_read_generation(b.organization_id)) AND (g.organization_id = b.organization_id) AND (EXISTS ( SELECT 1
                   FROM public.neighbor_generation_rows r
                  WHERE ((r.generation_id = g.id) AND (r.kind = 'interface_neighbor_matches'::text) AND (r.key = (b.id)::text))))))))
UNION ALL
 SELECT ((r.payload ->> 'id'::text))::uuid AS id,
    r.organization_id,
    ((r.payload ->> 'interface_neighbor_evidence_id'::text))::uuid AS interface_neighbor_evidence_id,
    ((r.payload ->> 'remote_interface_id'::text))::uuid AS remote_interface_id,
    ((r.payload ->> 'status'::text))::character varying(255) AS status,
    typed.strategy,
    typed.candidate_count,
    typed.inserted_at,
    typed.updated_at
   FROM ((public.neighbor_generation_rows r
     JOIN public.neighbor_generations g ON ((g.id = r.generation_id)))
     CROSS JOIN LATERAL jsonb_populate_record(NULL::public.interface_neighbor_matches_neighbor_storage, r.payload) typed(id, organization_id, interface_neighbor_evidence_id, remote_interface_id, status, strategy, candidate_count, inserted_at, updated_at))
  WHERE ((r.kind = 'interface_neighbor_matches'::text) AND (NOT r.deleted) AND (g.organization_id = r.organization_id) AND (g.id = public.neighbor_read_generation(r.organization_id)));


--
-- Name: interface_relationship_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_relationship_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_relationship_id uuid CONSTRAINT interface_relationship_evide_interface_relationship_id_not_null NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    stale_at timestamp(3) without time zone
);


--
-- Name: interface_relationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_relationships (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_interface_id uuid NOT NULL,
    target_interface_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT interface_relationships_distinct_endpoints CHECK ((source_interface_id <> target_interface_id))
);


--
-- Name: interface_routing_domain_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_routing_domain_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    source_local_key character varying(255),
    route_distinguisher character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    stale_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT interface_routing_domain_evidence_withdrawal_inactive CHECK (((source_local_key IS NOT NULL) OR (stale_at IS NOT NULL)))
);


--
-- Name: interface_routing_domains; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_routing_domains (
    interface_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    evidence_id uuid NOT NULL,
    source_id uuid NOT NULL,
    source_local_key character varying(255) NOT NULL,
    route_distinguisher character varying(255),
    authoritative boolean NOT NULL,
    resolution character varying(255) NOT NULL,
    vrf_id uuid,
    observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT interface_routing_domains_valid_resolution CHECK ((((resolution)::text = ANY ((ARRAY['mapping'::character varying, 'route_distinguisher'::character varying, 'name'::character varying, 'default'::character varying, 'unmapped'::character varying])::text[])) AND (((resolution)::text <> 'unmapped'::text) OR (vrf_id IS NULL))))
);


--
-- Name: interface_vlan_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_vlan_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    vlan_id uuid,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    source_local_key text NOT NULL,
    source_local_scope character varying(255),
    vid integer NOT NULL,
    tagging_mode character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    stale_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT interface_vlan_evidence_valid_tagging_mode CHECK (((tagging_mode)::text = ANY ((ARRAY['tagged'::character varying, 'untagged'::character varying])::text[]))),
    CONSTRAINT interface_vlan_evidence_valid_vid CHECK (((vid >= 1) AND (vid <= 4094)))
);


--
-- Name: interface_vlan_mode_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_vlan_mode_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    mode character varying(255),
    observed_at timestamp(3) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT interface_vlan_mode_evidence_valid_mode CHECK (((mode IS NULL) OR ((mode)::text = ANY ((ARRAY['access'::character varying, 'trunk'::character varying, 'tagged_all'::character varying])::text[]))))
);


--
-- Name: interfaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interfaces (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    mac_address macaddr,
    kind character varying(255) DEFAULT 'ethernet'::character varying NOT NULL,
    status character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    mtu integer,
    speed_mbps integer,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT interfaces_mtu_speed_positive CHECK ((((mtu IS NULL) OR (mtu > 0)) AND ((speed_mbps IS NULL) OR (speed_mbps > 0))))
);


--
-- Name: inventory_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_items (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    owner_resource_id uuid NOT NULL,
    parent_id uuid,
    name character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    "position" character varying(255),
    serial_number character varying(255),
    part_number character varying(255),
    asset_tag character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    promoted_module_id uuid,
    CONSTRAINT inventory_items_not_self_parent CHECK (((parent_id IS NULL) OR (parent_id <> id)))
);


--
-- Name: ip_address_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ip_address_assignments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    ip_address_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    assigned_by_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: ip_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ip_addresses (
    id uuid CONSTRAINT managed_addresses_id_not_null NOT NULL,
    organization_id uuid CONSTRAINT managed_addresses_organization_id_not_null NOT NULL,
    address inet CONSTRAINT managed_addresses_address_not_null NOT NULL,
    description character varying(255),
    adopted_by_id uuid,
    inserted_at timestamp(3) without time zone CONSTRAINT managed_addresses_inserted_at_not_null NOT NULL,
    updated_at timestamp(3) without time zone CONSTRAINT managed_addresses_updated_at_not_null NOT NULL,
    resource_id uuid NOT NULL,
    vrf_id uuid,
    allocation_state character varying(255) DEFAULT 'allocated'::character varying NOT NULL,
    management_mode character varying(255),
    role character varying(255) DEFAULT 'ordinary'::character varying NOT NULL,
    dns_name character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT ip_addresses_valid_allocation_state CHECK (((allocation_state)::text = ANY ((ARRAY['allocated'::character varying, 'reserved'::character varying])::text[]))),
    CONSTRAINT ip_addresses_valid_management_mode CHECK (((management_mode IS NULL) OR ((management_mode)::text = ANY ((ARRAY['static'::character varying, 'dhcp'::character varying, 'slaac'::character varying])::text[])))),
    CONSTRAINT ip_addresses_valid_role CHECK (((role)::text = ANY ((ARRAY['ordinary'::character varying, 'loopback'::character varying, 'secondary'::character varying, 'vip'::character varying, 'anycast'::character varying, 'vrrp'::character varying, 'hsrp'::character varying, 'glbp'::character varying, 'carp'::character varying])::text[])))
);


--
-- Name: job_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_events (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    job_id uuid NOT NULL,
    sequence integer NOT NULL,
    attempt integer NOT NULL,
    type character varying(255) NOT NULL,
    actor_type character varying(255) NOT NULL,
    actor_id uuid,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    report_sequence integer,
    CONSTRAINT job_events_payload_size CHECK ((octet_length((payload)::text) <= 65536)),
    CONSTRAINT job_events_valid_actor CHECK (((((actor_type)::text = 'system'::text) AND (actor_id IS NULL)) OR (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'agent'::character varying])::text[])) AND (actor_id IS NOT NULL)))),
    CONSTRAINT job_events_valid_position CHECK (((sequence > 0) AND (attempt >= 0))),
    CONSTRAINT job_events_valid_report_sequence CHECK (((report_sequence IS NULL) OR ((report_sequence > 0) AND ((actor_type)::text = 'agent'::text)))),
    CONSTRAINT job_events_valid_type CHECK (((type)::text = ANY ((ARRAY['created'::character varying, 'leased'::character varying, 'started'::character varying, 'progress'::character varying, 'output'::character varying, 'succeeded'::character varying, 'failed'::character varying, 'cancel_requested'::character varying, 'cancelled'::character varying, 'lease_lost'::character varying, 'expired'::character varying, 'uncertain'::character varying, 'resolved'::character varying])::text[])))
);


--
-- Name: jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    batch_id uuid,
    capability character varying(255) NOT NULL,
    capability_version integer NOT NULL,
    risk_class character varying(255) NOT NULL,
    retry_class character varying(255) NOT NULL,
    parameters jsonb DEFAULT '{}'::jsonb NOT NULL,
    requested_by_type character varying(255) NOT NULL,
    requested_by_user_id uuid,
    idempotency_key character varying(255),
    state character varying(255) NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    max_attempts integer NOT NULL,
    not_after timestamp(3) without time zone NOT NULL,
    lease_token_hash bytea,
    leased_at timestamp(3) without time zone,
    lease_expires_at timestamp(3) without time zone,
    started_at timestamp(3) without time zone,
    cancel_requested_at timestamp(3) without time zone,
    finished_at timestamp(3) without time zone,
    result jsonb,
    failure_reason character varying(255),
    output_bytes integer DEFAULT 0 NOT NULL,
    output_limit_bytes integer NOT NULL,
    timeout_ms integer NOT NULL,
    last_sequence integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    report_token_hash bytea,
    resource_id uuid,
    target_binding_id uuid,
    target_binding_version integer,
    offer_token_hash bytea,
    offer_nonce character varying(255),
    offer_expires_at timestamp(3) without time zone,
    imported_at timestamp(3) without time zone,
    CONSTRAINT jobs_finished_shape CHECK ((((state)::text = ANY ((ARRAY['succeeded'::character varying, 'failed'::character varying, 'cancelled'::character varying, 'expired'::character varying])::text[])) = (finished_at IS NOT NULL))),
    CONSTRAINT jobs_lease_shape CHECK ((((state)::text = ANY ((ARRAY['leased'::character varying, 'running'::character varying])::text[])) = ((lease_token_hash IS NOT NULL) AND (leased_at IS NOT NULL) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT jobs_privileged_binding CHECK (((((risk_class)::text = 'observe'::text) = (target_binding_version IS NULL)) AND ((offer_token_hash IS NULL) = (offer_nonce IS NULL)) AND ((offer_token_hash IS NULL) = (offer_expires_at IS NULL)))),
    CONSTRAINT jobs_started_shape CHECK ((((state)::text <> 'running'::text) OR (started_at IS NOT NULL))),
    CONSTRAINT jobs_uncertain_only_imperative CHECK ((((state)::text <> 'uncertain'::text) OR ((retry_class)::text = 'imperative'::text))),
    CONSTRAINT jobs_valid_attempts CHECK (((max_attempts >= 1) AND ((attempts >= 0) AND (attempts <= max_attempts)))),
    CONSTRAINT jobs_valid_capability CHECK ((((capability)::text <> ''::text) AND (capability_version > 0) AND ((idempotency_key IS NULL) OR ((idempotency_key)::text <> ''::text)))),
    CONSTRAINT jobs_valid_classes CHECK ((((risk_class)::text = ANY ((ARRAY['observe'::character varying, 'operate'::character varying, 'interactive'::character varying])::text[])) AND ((retry_class)::text = ANY ((ARRAY['idempotent'::character varying, 'convergent'::character varying, 'imperative'::character varying])::text[])))),
    CONSTRAINT jobs_valid_limits CHECK (((timeout_ms > 0) AND (output_limit_bytes > 0) AND ((output_bytes >= 0) AND (output_bytes <= output_limit_bytes)) AND (last_sequence >= 0))),
    CONSTRAINT jobs_valid_requester CHECK ((((requested_by_type)::text = ANY ((ARRAY['user'::character varying, 'system'::character varying])::text[])) AND (((requested_by_type)::text = 'user'::text) OR (requested_by_user_id IS NULL)))),
    CONSTRAINT jobs_valid_state CHECK (((state)::text = ANY ((ARRAY['queued'::character varying, 'leased'::character varying, 'running'::character varying, 'succeeded'::character varying, 'failed'::character varying, 'cancelled'::character varying, 'expired'::character varying, 'uncertain'::character varying])::text[])))
);


--
-- Name: local_sign_in_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_sign_in_overrides (
    id uuid NOT NULL,
    expires_at timestamp(3) without time zone NOT NULL,
    created_by character varying(255) NOT NULL,
    revoked_at timestamp(3) without time zone,
    revoked_by character varying(255),
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.locations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_id uuid NOT NULL,
    parent_id uuid,
    kind character varying(255),
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT locations_not_self_parent CHECK (((parent_id IS NULL) OR (parent_id <> id)))
);


--
-- Name: manufacturers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.manufacturers (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    slug character varying(255) NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: module_bay_compatible_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.module_bay_compatible_types (
    organization_id uuid NOT NULL,
    module_bay_id uuid NOT NULL,
    module_type_id uuid NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: module_bays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.module_bays (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    owner_resource_id uuid NOT NULL,
    owner_kind character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    label character varying(255),
    "position" character varying(255),
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT module_bays_valid_owner_kind CHECK (((owner_kind)::text = ANY ((ARRAY['server'::character varying, 'switch'::character varying, 'pdu'::character varying, 'storage'::character varying, 'module'::character varying])::text[])))
);


--
-- Name: module_installation_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.module_installation_events (
    id uuid NOT NULL,
    sequence bigint NOT NULL,
    organization_id uuid NOT NULL,
    module_bay_id uuid NOT NULL,
    module_id uuid NOT NULL,
    action character varying(255) NOT NULL,
    occurred_at timestamp(3) without time zone NOT NULL,
    actor_user_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: module_installation_events_sequence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.module_installation_events_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: module_installation_events_sequence_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.module_installation_events_sequence_seq OWNED BY public.module_installation_events.sequence;


--
-- Name: module_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.module_types (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    manufacturer_id uuid NOT NULL,
    model character varying(255) NOT NULL,
    module_class character varying(255) NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modules (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    module_type_id uuid NOT NULL,
    catalog_type_revision_id uuid NOT NULL,
    status character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    serial_number character varying(255),
    part_number character varying(255),
    asset_tag character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: neighbor_generation_heads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.neighbor_generation_heads (
    organization_id uuid NOT NULL,
    version bigint DEFAULT 0 NOT NULL,
    current_generation_id uuid
);


--
-- Name: observation_reconciliations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.observation_reconciliations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    matched_resource_id uuid,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    attempt integer NOT NULL,
    errors jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_at timestamp(3) without time zone,
    completed_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT observation_reconciliations_attempt_positive CHECK ((attempt > 0)),
    CONSTRAINT observation_reconciliations_completion_state CHECK ((((((status)::text = ANY ((ARRAY['pending'::character varying, 'running'::character varying])::text[])) AND (completed_at IS NULL)) OR (((status)::text = ANY ((ARRAY['succeeded'::character varying, 'failed'::character varying])::text[])) AND (completed_at IS NOT NULL))) AND ((started_at IS NULL) OR (completed_at IS NULL) OR (completed_at >= started_at))))
);


--
-- Name: observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.observations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    sync_run_id uuid,
    idempotency_key character varying(255) NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    payload_digest bytea NOT NULL,
    payload jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    reported_from inet,
    intake_api_key_id uuid,
    parent_observation_id uuid,
    resource_index integer,
    CONSTRAINT observations_derived_resource CHECK ((((parent_observation_id IS NULL) = (resource_index IS NULL)) AND ((resource_index IS NULL) OR (resource_index >= 0))))
);


--
-- Name: operator_idempotency_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operator_idempotency_keys (
    id uuid NOT NULL,
    operator_token_id uuid NOT NULL,
    method character varying(255) NOT NULL,
    route character varying(255) NOT NULL,
    key character varying(255) NOT NULL,
    request_digest bytea NOT NULL,
    response_status integer NOT NULL,
    response_body jsonb NOT NULL,
    expires_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: operator_invitation_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operator_invitation_deliveries (
    id uuid NOT NULL,
    invitation_id uuid NOT NULL,
    url_ciphertext bytea NOT NULL,
    url_key_id character varying(255) NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    available_at timestamp(3) without time zone NOT NULL,
    lease_id uuid,
    lease_expires_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT operator_invitation_deliveries_attempts CHECK ((attempts >= 0)),
    CONSTRAINT operator_invitation_deliveries_lease CHECK ((((lease_id IS NULL) AND (lease_expires_at IS NULL)) OR ((lease_id IS NOT NULL) AND (lease_expires_at IS NOT NULL))))
);


--
-- Name: operator_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operator_tokens (
    id uuid NOT NULL,
    name public.citext NOT NULL,
    token_hash bytea NOT NULL,
    scopes character varying(255)[] NOT NULL,
    allowed_sources cidr[] DEFAULT ARRAY[]::cidr[] NOT NULL,
    expires_at timestamp(3) without time zone,
    revoked_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: organization_domains; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_domains (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    domain public.citext NOT NULL,
    token character varying(255) NOT NULL,
    verified_at timestamp without time zone,
    checked_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: organization_export_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_export_chunks (
    export_id uuid NOT NULL,
    "position" integer NOT NULL,
    data bytea NOT NULL
);


--
-- Name: organization_exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_exports (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    requested_by_user_id uuid,
    parts character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    readable_payloads character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    status character varying(255) NOT NULL,
    snapshot_at timestamp(3) without time zone,
    records bigint,
    bytes bigint,
    sha256 character varying(255),
    finished_at timestamp(3) without time zone,
    expires_at timestamp(3) without time zone,
    revoked_at timestamp(3) without time zone,
    revoked_by_user_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    notification_url text,
    processing_deadline timestamp without time zone,
    CONSTRAINT valid_status CHECK (((status)::text = ANY ((ARRAY['running'::character varying, 'ready'::character varying, 'failed'::character varying, 'revoked'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: organization_imports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_imports (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_organization_id uuid NOT NULL,
    source_slug character varying(255) NOT NULL,
    source_name character varying(255) NOT NULL,
    format_version integer NOT NULL,
    renga_version character varying(255) NOT NULL,
    snapshot_at timestamp(3) without time zone NOT NULL,
    parts character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    records bigint NOT NULL,
    sha256 character varying(255) NOT NULL,
    source_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    held_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    imported_by_user_id uuid,
    operator character varying(255),
    inserted_at timestamp(3) without time zone NOT NULL,
    copy boolean DEFAULT false NOT NULL
);


--
-- Name: organization_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_invitations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    email public.citext NOT NULL,
    role character varying(255) NOT NULL,
    token_hash bytea NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    invited_by_user_id uuid,
    accepted_at timestamp without time zone,
    accepted_by_user_id uuid,
    revoked_at timestamp without time zone,
    revoked_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    invited_by_operator text,
    invited_by_operator_token_id uuid,
    imported_principal_id uuid,
    CONSTRAINT organization_invitations_role_check CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'member'::character varying, 'viewer'::character varying])::text[])))
);


--
-- Name: organization_lifecycle_notices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_lifecycle_notices (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    recipient character varying(255) NOT NULL,
    organization_name character varying(255) NOT NULL,
    operation character varying(255) NOT NULL,
    deadline timestamp without time zone,
    delivered_at timestamp without time zone
);


--
-- Name: organization_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_limits (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    value bigint NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT value_not_negative CHECK ((value >= 0))
);


--
-- Name: organization_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_memberships (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(255) DEFAULT 'member'::character varying NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    scim_connection_id uuid
);


--
-- Name: organization_security_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_security_settings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    value jsonb NOT NULL,
    changed_by_user_id uuid,
    changed_by character varying(255) NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    default_accent text DEFAULT 'copper'::text NOT NULL,
    default_power_factor numeric(4,3),
    guest_without_vm_findings boolean DEFAULT false NOT NULL,
    deletion_scheduled_at timestamp without time zone,
    deletion_due_at timestamp without time zone,
    CONSTRAINT organization_deletion_deadline CHECK ((((status)::text = ANY ((ARRAY['deletion_pending'::character varying, 'purging'::character varying])::text[])) = ((deletion_due_at IS NOT NULL) AND (deletion_scheduled_at IS NOT NULL)))),
    CONSTRAINT organizations_default_power_factor CHECK (((default_power_factor IS NULL) OR ((default_power_factor > (0)::numeric) AND (default_power_factor <= (1)::numeric)))),
    CONSTRAINT organizations_valid_default_accent CHECK ((default_accent = ANY (ARRAY['copper'::text, 'petrol'::text, 'cobalt'::text, 'iris'::text, 'mono'::text])))
);


--
-- Name: placement_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.placement_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_identifier character varying(255),
    location_identifier character varying(255),
    rack_identifier character varying(255),
    "position" integer,
    height_units integer,
    face character varying(255),
    confidence integer DEFAULT 50 NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    stale_at timestamp(3) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: placement_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.placement_findings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    message text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    resolved_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: power_correlation_samples; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.power_correlation_samples (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    target character varying(255),
    sensor character varying(255) NOT NULL,
    boundary character varying(255) NOT NULL,
    quantity character varying(255) NOT NULL,
    component_kind character varying(255),
    component_name character varying(255),
    minute timestamp(0) without time zone NOT NULL,
    event_at timestamp(3) without time zone NOT NULL,
    value numeric,
    state character varying(255),
    CONSTRAINT power_correlation_samples_kind CHECK (((((boundary)::text = 'outlet'::text) AND ((component_kind)::text = 'power_outlet'::text) AND ((quantity)::text = ANY ((ARRAY['real_power'::character varying, 'current'::character varying, 'state'::character varying])::text[]))) OR (((boundary)::text = 'supply_input'::text) AND ((quantity)::text = ANY ((ARRAY['real_power'::character varying, 'state'::character varying])::text[]))))),
    CONSTRAINT power_correlation_samples_value CHECK ((((quantity)::text = 'state'::text) = ((state IS NOT NULL) AND (value IS NULL))))
);


--
-- Name: power_feeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.power_feeds (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_id uuid NOT NULL,
    panel_id uuid NOT NULL,
    rack_id uuid,
    name character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    supply character varying(255) NOT NULL,
    phase character varying(255),
    voltage numeric NOT NULL,
    amperage numeric NOT NULL,
    max_utilization integer DEFAULT 80 NOT NULL,
    side character varying(255),
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT power_feeds_electrical CHECK ((((supply)::text = ANY ((ARRAY['ac'::character varying, 'dc'::character varying])::text[])) AND ((((supply)::text = 'ac'::text) AND (phase IS NOT NULL) AND ((phase)::text = ANY ((ARRAY['single'::character varying, 'three'::character varying])::text[]))) OR (((supply)::text = 'dc'::text) AND (phase IS NULL))) AND (voltage > (0)::numeric) AND (amperage > (0)::numeric) AND ((max_utilization >= 1) AND (max_utilization <= 100)) AND ((side IS NULL) OR ((side)::text = ANY ((ARRAY['a'::character varying, 'b'::character varying])::text[]))) AND ((status)::text = ANY ((ARRAY['planned'::character varying, 'active'::character varying, 'offline'::character varying, 'decommissioning'::character varying])::text[]))))
);


--
-- Name: power_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.power_findings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    resolution_key character varying(255) DEFAULT ''::character varying NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    message text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_observed_at timestamp(3) without time zone NOT NULL,
    resolved_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT power_findings_valid CHECK ((((status)::text = ANY ((ARRAY['open'::character varying, 'resolved'::character varying])::text[])) AND (((status)::text = 'resolved'::text) = (resolved_at IS NOT NULL)) AND ((kind)::text = ANY ((ARRAY['not_redundant'::character varying, 'feed_near_capacity'::character varying, 'supply_failed'::character varying, 'unexpected_draw'::character varying, 'path_incomplete'::character varying, 'suggested_connection'::character varying])::text[]))))
);


--
-- Name: power_outlets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.power_outlets (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    inlet_port_id uuid,
    name character varying(255) NOT NULL,
    label character varying(255),
    connector text,
    feed_leg character varying(255),
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    retired_at timestamp(3) without time zone,
    CONSTRAINT power_outlets_feed_leg CHECK (((feed_leg IS NULL) OR ((feed_leg)::text = ANY ((ARRAY['a'::character varying, 'b'::character varying, 'c'::character varying])::text[]))))
);


--
-- Name: power_panels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.power_panels (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_id uuid NOT NULL,
    location_id uuid,
    name character varying(255) NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: power_ports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.power_ports (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    label character varying(255),
    connector text,
    maximum_draw_w integer,
    default_allocated_draw_w integer,
    allocated_draw_w integer,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    retired_at timestamp(3) without time zone,
    default_power_factor numeric(4,3),
    power_factor numeric(4,3),
    CONSTRAINT power_ports_draws CHECK ((((maximum_draw_w IS NULL) OR (maximum_draw_w > 0)) AND ((default_allocated_draw_w IS NULL) OR (default_allocated_draw_w > 0)) AND ((allocated_draw_w IS NULL) OR (allocated_draw_w > 0)))),
    CONSTRAINT power_ports_power_factors CHECK ((((default_power_factor IS NULL) OR ((default_power_factor > (0)::numeric) AND (default_power_factor <= (1)::numeric))) AND ((power_factor IS NULL) OR ((power_factor > (0)::numeric) AND (power_factor <= (1)::numeric)))))
);


--
-- Name: power_readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.power_readings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    target character varying(255),
    sensor character varying(255) NOT NULL,
    boundary character varying(255) NOT NULL,
    quantity character varying(255) NOT NULL,
    unit character varying(255),
    window_ms integer NOT NULL,
    leg character varying(255),
    component_kind character varying(255),
    component_name character varying(255),
    coverage character varying(255),
    origin character varying(255) NOT NULL,
    mapping_name character varying(255) NOT NULL,
    mapping_version integer NOT NULL,
    value numeric,
    state character varying(255),
    validity character varying(255) NOT NULL,
    window_start timestamp(3) without time zone NOT NULL,
    window_end timestamp(3) without time zone NOT NULL,
    event_at timestamp(3) without time zone NOT NULL,
    fresh_until timestamp(3) without time zone NOT NULL,
    received_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT power_readings_value CHECK (((((validity)::text = 'valid'::text) = ((value IS NOT NULL) OR (state IS NOT NULL))) AND ((value IS NULL) OR ((quantity)::text <> 'state'::text)) AND ((state IS NULL) OR ((quantity)::text = 'state'::text)))),
    CONSTRAINT power_readings_vocabulary CHECK ((((boundary)::text = ANY ((ARRAY['host_input'::character varying, 'supply_input'::character varying, 'supply_output'::character varying, 'outlet'::character varying, 'feed'::character varying, 'leg'::character varying])::text[])) AND ((quantity)::text = ANY ((ARRAY['real_power'::character varying, 'apparent_power'::character varying, 'current'::character varying, 'voltage'::character varying, 'power_factor'::character varying, 'state'::character varying])::text[])) AND ((validity)::text = ANY ((ARRAY['valid'::character varying, 'missing'::character varying, 'failed'::character varying, 'invalid'::character varying])::text[])) AND ((origin)::text = ANY ((ARRAY['native'::character varying, 'exporter'::character varying])::text[])) AND ((coverage IS NULL) OR ((coverage)::text = ANY ((ARRAY['complete'::character varying, 'partial'::character varying])::text[]))) AND ((leg IS NULL) OR ((leg)::text = ANY ((ARRAY['a'::character varying, 'b'::character varying, 'c'::character varying])::text[]))) AND ((component_kind IS NULL) OR ((component_kind)::text = ANY ((ARRAY['power_port'::character varying, 'power_outlet'::character varying])::text[]))) AND ((component_kind IS NULL) = (component_name IS NULL)))),
    CONSTRAINT power_readings_window CHECK (((window_start <= window_end) AND (window_ms >= 0) AND (fresh_until > event_at)))
);


--
-- Name: prefix_vlan_relationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prefix_vlan_relationships (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    prefix_id uuid NOT NULL,
    vlan_id uuid NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: prefixes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prefixes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    prefix cidr NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    vrf_id uuid,
    strict boolean DEFAULT false NOT NULL,
    CONSTRAINT prefixes_valid_status CHECK (((status)::text = ANY ((ARRAY['container'::character varying, 'active'::character varying, 'reserved'::character varying, 'deprecated'::character varying])::text[])))
);


--
-- Name: rack_occupancies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rack_occupancies (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    current_placement_id uuid NOT NULL,
    rack_id uuid NOT NULL,
    face character varying(255) NOT NULL,
    units int4range NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: racks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.racks (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_id uuid NOT NULL,
    location_id uuid,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    facility_id character varying(255),
    height_units integer DEFAULT 42 NOT NULL,
    width character varying(255) DEFAULT '19_inch'::character varying NOT NULL,
    starting_unit character varying(255) DEFAULT 'bottom'::character varying NOT NULL,
    outer_width numeric,
    outer_depth numeric,
    dimension_unit character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT racks_valid_geometry CHECK (((height_units > 0) AND ((outer_width IS NULL) OR (outer_width > (0)::numeric)) AND ((outer_depth IS NULL) OR (outer_depth > (0)::numeric))))
);


--
-- Name: reconciliation_lanes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliation_lanes (
    organization_id uuid NOT NULL,
    "position" bigint DEFAULT 0 NOT NULL,
    pending_units bigint DEFAULT 0 NOT NULL,
    pending_bytes bigint DEFAULT 0 NOT NULL,
    last_turn_at timestamp without time zone,
    token uuid,
    work_id uuid,
    version bigint DEFAULT 0 NOT NULL,
    expires_at timestamp without time zone,
    CONSTRAINT reconciliation_lane_lease CHECK ((((token IS NULL) AND (work_id IS NULL) AND (expires_at IS NULL)) OR ((token IS NOT NULL) AND (work_id IS NOT NULL) AND (expires_at IS NOT NULL)))),
    CONSTRAINT reconciliation_lane_values CHECK ((("position" >= 0) AND (pending_units >= 0) AND (pending_bytes >= 0) AND (version >= 0)))
);


--
-- Name: reconciliation_work; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliation_work (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    source_id uuid NOT NULL,
    "position" bigint NOT NULL,
    units bigint NOT NULL,
    bytes bigint NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    checkpoint bigint DEFAULT 0 NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    original_key_id uuid NOT NULL,
    installation_agent_id uuid NOT NULL,
    installation_id uuid NOT NULL,
    run_after timestamp without time zone NOT NULL,
    quarantine_kind character varying(255),
    error jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT reconciliation_work_status CHECK (((((status)::text = ANY ((ARRAY['pending'::character varying, 'succeeded'::character varying])::text[])) AND (quarantine_kind IS NULL)) OR (((status)::text = 'quarantined'::text) AND ((quarantine_kind)::text = 'domain'::text)))),
    CONSTRAINT reconciliation_work_values CHECK ((("position" > 0) AND (units > 0) AND (bytes >= 0) AND (generation >= 0) AND (checkpoint >= 0)))
);


--
-- Name: resource_conditions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_conditions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    type character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    reason character varying(255),
    message text,
    observed_generation bigint,
    last_transition_at timestamp(3) without time zone NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: resource_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_group_members (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    group_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    added_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: resource_group_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_group_memberships (
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    view character varying(255) NOT NULL,
    group_id uuid NOT NULL,
    group_set_id uuid,
    CONSTRAINT resource_group_memberships_view CHECK (((view)::text = ANY ((ARRAY['inventory'::character varying, 'trusted'::character varying])::text[])))
);


--
-- Name: resource_group_sets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_group_sets (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    exclusive boolean DEFAULT false NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: resource_group_suggestion_dismissals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_group_suggestion_dismissals (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    suggestion_id uuid NOT NULL,
    rule_id uuid NOT NULL,
    rule_updated_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: resource_group_suggestions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_group_suggestions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    group_id uuid NOT NULL,
    rule_id uuid,
    rule_name character varying(255) NOT NULL,
    rule_updated_at timestamp without time zone NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    decided_by_user_id uuid,
    decided_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT resource_group_suggestions_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'accepted'::character varying, 'dismissed'::character varying])::text[])))
);


--
-- Name: resource_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_groups (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    group_set_id uuid,
    name character varying(255) NOT NULL,
    description text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: resource_identifier_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_identifier_claims (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_identifier_id uuid,
    resource_id uuid,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    value character varying(255) NOT NULL,
    normalized_value character varying(255) NOT NULL,
    confidence integer DEFAULT 100 NOT NULL,
    first_seen_at timestamp(3) without time zone NOT NULL,
    last_seen_at timestamp(3) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT resource_identifier_claims_canonical_requires_resource CHECK (((resource_identifier_id IS NULL) OR (resource_id IS NOT NULL))),
    CONSTRAINT resource_identifier_claims_confidence_range CHECK (((confidence >= 0) AND (confidence <= 100))),
    CONSTRAINT resource_identifier_claims_seen_order CHECK ((last_seen_at >= first_seen_at))
);


--
-- Name: resource_identifiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_identifiers (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    value character varying(255) NOT NULL,
    normalized_value character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: resource_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_overrides (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    field character varying(255) NOT NULL,
    value jsonb NOT NULL,
    reason character varying(255),
    created_by_user_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: resource_owners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_owners (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    owner_resource_id uuid NOT NULL,
    child_resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    controller boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT resource_owners_distinct_endpoints CHECK ((owner_resource_id <> child_resource_id))
);


--
-- Name: resource_relationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_relationships (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_resource_id uuid NOT NULL,
    target_resource_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT resource_relationships_distinct_endpoints CHECK ((source_resource_id <> target_resource_id))
);


--
-- Name: resource_revision_sequence; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resource_revision_sequence
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resource_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_revisions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    revision bigint NOT NULL,
    action character varying(255) NOT NULL,
    generation bigint NOT NULL,
    snapshot jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resources (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    display_name character varying(255),
    lifecycle_state character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    spec jsonb DEFAULT '{}'::jsonb NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    resource_version bigint NOT NULL,
    labels jsonb DEFAULT '{}'::jsonb NOT NULL,
    annotations jsonb DEFAULT '{}'::jsonb NOT NULL,
    deletion_requested_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    owner_team_id uuid,
    owner_source character varying(255),
    owner_set_at timestamp without time zone,
    owner_rule_id uuid,
    CONSTRAINT resources_owner_rule_state CHECK (((owner_rule_id IS NULL) OR ((owner_source)::text = 'rule'::text))),
    CONSTRAINT resources_owner_source_state CHECK ((((owner_team_id IS NULL) AND (owner_source IS NULL)) OR ((owner_team_id IS NOT NULL) AND ((owner_source)::text = ANY ((ARRAY['person'::character varying, 'rule'::character varying])::text[])))))
);


--
-- Name: role_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_assignments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    membership_id uuid NOT NULL,
    built_in_role character varying(255),
    role_id uuid,
    valid_until timestamp without time zone,
    expired_at timestamp without time zone,
    source character varying(255) DEFAULT 'manual'::character varying NOT NULL,
    reason text,
    created_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT role_assignments_built_in_role CHECK (((built_in_role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'member'::character varying, 'viewer'::character varying])::text[]))),
    CONSTRAINT role_assignments_one_role CHECK ((num_nonnulls(built_in_role, role_id) = 1))
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    permissions character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: saved_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saved_views (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid,
    created_by_id uuid,
    area character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    pinned boolean DEFAULT false NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: scim_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scim_connections (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    provider_id character varying(255) NOT NULL,
    correlation_claim character varying(255) NOT NULL,
    default_role character varying(255),
    disabled_at timestamp without time zone,
    created_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT scim_connections_default_role CHECK (((default_role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'member'::character varying, 'viewer'::character varying])::text[])))
);


--
-- Name: scim_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scim_group_members (
    connection_id uuid NOT NULL,
    group_id uuid NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: scim_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scim_groups (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    display_name character varying(255) NOT NULL,
    external_id character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    role character varying(255),
    CONSTRAINT scim_groups_role CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'member'::character varying, 'viewer'::character varying])::text[])))
);


--
-- Name: scim_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scim_tokens (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    token_hash bytea NOT NULL,
    last_used_at timestamp without time zone,
    revoked_at timestamp without time zone,
    created_by_user_id uuid,
    revoked_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: scim_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scim_users (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    user_name public.citext NOT NULL,
    external_id character varying(255),
    display_name character varying(255),
    formatted_name character varying(255),
    given_name character varying(255),
    family_name character varying(255),
    email character varying(255),
    active boolean DEFAULT true NOT NULL,
    user_identity_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: site_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_groups (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    parent_id uuid,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT site_groups_not_self_parent CHECK (((parent_id IS NULL) OR (parent_id <> id)))
);


--
-- Name: sites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sites (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    site_group_id uuid,
    slug character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    description text,
    physical_address text,
    time_zone character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: source_routing_domain_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_routing_domain_mappings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    source_local_key character varying(255) NOT NULL,
    vrf_id uuid,
    created_by_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: source_vlan_group_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_vlan_group_mappings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    vlan_group_id uuid,
    source_local_scope character varying(255) DEFAULT 'default'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    authoritative_routing_domains boolean DEFAULT false NOT NULL,
    agent_id uuid,
    collector_id character varying(255),
    CONSTRAINT sources_collector_stream CHECK ((((collector_id IS NULL) AND (agent_id IS NULL)) OR ((collector_id IS NOT NULL) AND (agent_id IS NOT NULL) AND ((kind)::text = ANY ((ARRAY['switch_poller'::character varying, 'vm_provider'::character varying, 'power_poller'::character varying, 'bmc_power'::character varying])::text[])))))
);


--
-- Name: sync_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_runs (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid,
    status character varying(255) DEFAULT 'running'::character varying NOT NULL,
    started_at timestamp(3) without time zone NOT NULL,
    completed_at timestamp(3) without time zone,
    resource_count integer DEFAULT 0 NOT NULL,
    error_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT sync_runs_completion_state CHECK (((((status)::text = 'running'::text) AND (completed_at IS NULL)) OR (((status)::text = ANY ((ARRAY['succeeded'::character varying, 'failed'::character varying, 'partial'::character varying])::text[])) AND (completed_at IS NOT NULL) AND (completed_at >= started_at))))
);


--
-- Name: target_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.target_bindings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    installation_key_id uuid NOT NULL,
    version integer NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    approved_by_user_id uuid,
    approved_at timestamp(3) without time zone NOT NULL,
    revoked_at timestamp(3) without time zone,
    revoked_reason character varying(255),
    revoked_by_user_id uuid,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT target_bindings_valid CHECK (((version > 0) AND ((status)::text = ANY ((ARRAY['active'::character varying, 'revoked'::character varying])::text[])) AND (((status)::text = 'revoked'::text) = ((revoked_at IS NOT NULL) AND (revoked_reason IS NOT NULL))) AND ((revoked_reason IS NULL) OR ((revoked_reason)::text = ANY ((ARRAY['replaced'::character varying, 'revoked'::character varying, 'key_replaced'::character varying, 'imported'::character varying])::text[])))))
);


--
-- Name: team_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_memberships (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    team_id uuid NOT NULL,
    membership_id uuid NOT NULL,
    added_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teams (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: telemetry_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telemetry_batches (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    replay_id character varying(255) NOT NULL,
    version integer NOT NULL,
    payload_digest character varying(255) NOT NULL,
    sample_count integer NOT NULL,
    received_at timestamp(3) without time zone NOT NULL
);


--
-- Name: telemetry_buckets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telemetry_buckets (
    organization_id uuid NOT NULL,
    series character varying(255) NOT NULL,
    bucket_start timestamp(0) without time zone NOT NULL,
    count integer NOT NULL,
    sum double precision NOT NULL,
    minimum double precision NOT NULL,
    maximum double precision NOT NULL,
    last_value double precision NOT NULL,
    last_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT telemetry_buckets_aligned CHECK ((mod((EXTRACT(epoch FROM bucket_start))::bigint, (300)::bigint) = 0)),
    CONSTRAINT telemetry_buckets_count CHECK ((count > 0))
);


--
-- Name: telemetry_marks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telemetry_marks (
    organization_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    recorded_at timestamp(0) without time zone NOT NULL
);


--
-- Name: topology_findings_neighbor_storage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topology_findings_neighbor_storage (
    id uuid CONSTRAINT topology_findings_id_not_null NOT NULL,
    organization_id uuid CONSTRAINT topology_findings_organization_id_not_null NOT NULL,
    interface_id uuid CONSTRAINT topology_findings_interface_id_not_null NOT NULL,
    kind character varying(255) CONSTRAINT topology_findings_kind_not_null NOT NULL,
    resolution_key text CONSTRAINT topology_findings_resolution_key_not_null NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying CONSTRAINT topology_findings_status_not_null NOT NULL,
    message text CONSTRAINT topology_findings_message_not_null NOT NULL,
    details jsonb DEFAULT '{}'::jsonb CONSTRAINT topology_findings_details_not_null NOT NULL,
    last_observed_at timestamp(3) without time zone CONSTRAINT topology_findings_last_observed_at_not_null NOT NULL,
    resolved_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone CONSTRAINT topology_findings_inserted_at_not_null NOT NULL,
    updated_at timestamp(3) without time zone CONSTRAINT topology_findings_updated_at_not_null NOT NULL,
    CONSTRAINT topology_findings_resolution_state CHECK (((((status)::text = 'open'::text) AND (resolved_at IS NULL)) OR (((status)::text = 'resolved'::text) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT topology_findings_valid_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'resolved'::character varying])::text[])))
);


--
-- Name: topology_findings; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.topology_findings AS
 SELECT b.id,
    b.organization_id,
    b.interface_id,
    b.kind,
    b.resolution_key,
    b.status,
    b.message,
    b.details,
    b.last_observed_at,
    b.resolved_at,
    b.inserted_at,
    b.updated_at
   FROM public.topology_findings_neighbor_storage b
  WHERE (NOT (EXISTS ( SELECT 1
           FROM public.neighbor_generations g
          WHERE ((g.id = public.neighbor_read_generation(b.organization_id)) AND (g.organization_id = b.organization_id) AND (EXISTS ( SELECT 1
                   FROM public.neighbor_generation_rows r
                  WHERE ((r.generation_id = g.id) AND (r.kind = 'topology_findings'::text) AND (r.key = (b.id)::text))))))))
UNION ALL
 SELECT ((r.payload ->> 'id'::text))::uuid AS id,
    r.organization_id,
    ((r.payload ->> 'interface_id'::text))::uuid AS interface_id,
    ((r.payload ->> 'kind'::text))::character varying(255) AS kind,
    typed.resolution_key,
    ((r.payload ->> 'status'::text))::character varying(255) AS status,
    typed.message,
    typed.details,
    typed.last_observed_at,
    typed.resolved_at,
    typed.inserted_at,
    typed.updated_at
   FROM ((public.neighbor_generation_rows r
     JOIN public.neighbor_generations g ON ((g.id = r.generation_id)))
     CROSS JOIN LATERAL jsonb_populate_record(NULL::public.topology_findings_neighbor_storage, r.payload) typed(id, organization_id, interface_id, kind, resolution_key, status, message, details, last_observed_at, resolved_at, inserted_at, updated_at))
  WHERE ((r.kind = 'topology_findings'::text) AND (NOT r.deleted) AND (g.organization_id = r.organization_id) AND (g.id = public.neighbor_read_generation(r.organization_id)));


--
-- Name: topology_snapshot_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topology_snapshot_events (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    source_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    section character varying(255) NOT NULL,
    observed_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT topology_snapshot_events_valid_section CHECK (((section)::text = ANY ((ARRAY['interface_vlans'::character varying, 'interface_neighbors'::character varying, 'interface_relationships'::character varying])::text[])))
);


--
-- Name: triage_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.triage_rules (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    subnet inet,
    intake_api_key_id uuid,
    hostname_pattern character varying(255),
    label_key character varying(255),
    label_value character varying(255),
    site_id uuid,
    location_id uuid,
    team_id uuid,
    created_by_user_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    resource_group_id uuid,
    CONSTRAINT triage_rules_valid_shape CHECK (((((kind)::text <> 'group'::text) AND (resource_group_id IS NULL) AND ((((kind)::text = 'network_location'::text) AND (site_id IS NOT NULL) AND (team_id IS NULL) AND (hostname_pattern IS NULL) AND (label_key IS NULL) AND (label_value IS NULL) AND ((subnet IS NOT NULL) <> (intake_api_key_id IS NOT NULL))) OR (((kind)::text = 'top_of_rack'::text) AND (site_id IS NULL) AND (location_id IS NULL) AND (team_id IS NULL) AND (subnet IS NULL) AND (intake_api_key_id IS NULL) AND (hostname_pattern IS NULL) AND (label_key IS NULL) AND (label_value IS NULL)) OR (((kind)::text = 'ownership'::text) AND (team_id IS NOT NULL) AND (site_id IS NULL) AND (location_id IS NULL) AND (subnet IS NULL) AND (intake_api_key_id IS NULL) AND ((hostname_pattern IS NOT NULL) <> (label_key IS NOT NULL)) AND ((label_key IS NULL) = (label_value IS NULL))))) OR (((kind)::text = 'group'::text) AND (resource_group_id IS NOT NULL) AND (team_id IS NULL) AND (site_id IS NULL) AND (location_id IS NULL) AND (subnet IS NULL) AND (intake_api_key_id IS NULL) AND ((hostname_pattern IS NOT NULL) <> (label_key IS NOT NULL)) AND ((label_key IS NULL) = (label_value IS NULL)))))
);


--
-- Name: user_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_identities (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    provider_id character varying(255) NOT NULL,
    subject character varying(255) NOT NULL,
    email character varying(255),
    last_signed_in_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    email_verified boolean DEFAULT false NOT NULL
);


--
-- Name: user_passkeys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_passkeys (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    credential_id bytea NOT NULL,
    public_key bytea NOT NULL,
    sign_count bigint DEFAULT 0 NOT NULL,
    transports character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    backup_eligible boolean DEFAULT false NOT NULL,
    backed_up boolean DEFAULT false NOT NULL,
    name character varying(255) NOT NULL,
    last_used_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: user_recovery_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_recovery_codes (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    code_hash bytea NOT NULL,
    used_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: user_totps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_totps (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    secret_ciphertext bytea NOT NULL,
    secret_key_id character varying(255) NOT NULL,
    last_used_step bigint,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email public.citext,
    hashed_password character varying(255),
    confirmed_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    theme text DEFAULT 'system'::text NOT NULL,
    accent text,
    density text DEFAULT 'comfortable'::text NOT NULL,
    CONSTRAINT users_valid_accent CHECK (((accent IS NULL) OR (accent = ANY (ARRAY['copper'::text, 'petrol'::text, 'cobalt'::text, 'iris'::text, 'mono'::text])))),
    CONSTRAINT users_valid_density CHECK ((density = ANY (ARRAY['comfortable'::text, 'compact'::text]))),
    CONSTRAINT users_valid_theme CHECK ((theme = ANY (ARRAY['system'::text, 'light'::text, 'dark'::text])))
);


--
-- Name: users_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token bytea NOT NULL,
    context character varying(255) NOT NULL,
    sent_to character varying(255),
    authenticated_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    browser_session_id uuid,
    expires_at timestamp(3) without time zone,
    second_factor_at timestamp(3) without time zone,
    provider_id character varying(255),
    provider_organization_id uuid,
    provider_amr character varying(255)[],
    scoped_organization_id uuid
);


--
-- Name: vlan_group_vid_ranges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vlan_group_vid_ranges (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    vlan_group_id uuid NOT NULL,
    start_vid integer NOT NULL,
    end_vid integer NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT vlan_group_vid_ranges_valid_bounds CHECK ((((start_vid >= 1) AND (start_vid <= 4094)) AND ((end_vid >= 1) AND (end_vid <= 4094)) AND (start_vid <= end_vid)))
);


--
-- Name: vlan_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vlan_groups (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    slug character varying(255) NOT NULL,
    scope_kind character varying(255) DEFAULT 'global'::character varying NOT NULL,
    site_id uuid,
    location_id uuid,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT vlan_groups_valid_scope CHECK (((((scope_kind)::text = 'global'::text) AND (site_id IS NULL) AND (location_id IS NULL)) OR (((scope_kind)::text = 'site'::text) AND (site_id IS NOT NULL) AND (location_id IS NULL)) OR (((scope_kind)::text = 'location'::text) AND (site_id IS NULL) AND (location_id IS NOT NULL))))
);


--
-- Name: vlans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vlans (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    vlan_group_id uuid,
    vid integer NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    role character varying(255),
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT vlans_valid_vid CHECK (((vid >= 1) AND (vid <= 4094)))
);


--
-- Name: vrfs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vrfs (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    route_distinguisher character varying(255),
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    CONSTRAINT vrfs_valid_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'deprecated'::character varying])::text[])))
);


--
-- Name: webauthn_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webauthn_challenges (
    id uuid NOT NULL,
    bytes bytea NOT NULL,
    purpose character varying(255) NOT NULL,
    user_id uuid,
    expires_at timestamp(3) without time zone NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: cable_assertions sequence; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions ALTER COLUMN sequence SET DEFAULT nextval('public.cable_assertions_sequence_seq'::regclass);


--
-- Name: cable_change_events sequence; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_change_events ALTER COLUMN sequence SET DEFAULT nextval('public.cable_change_events_sequence_seq'::regclass);


--
-- Name: current_interface_adjacencies metadata; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacencies ALTER COLUMN metadata SET DEFAULT '{}'::jsonb;


--
-- Name: interface_neighbor_evidence metadata; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_evidence ALTER COLUMN metadata SET DEFAULT '{}'::jsonb;


--
-- Name: interface_neighbor_matches candidate_count; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_matches ALTER COLUMN candidate_count SET DEFAULT 0;


--
-- Name: module_installation_events sequence; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_installation_events ALTER COLUMN sequence SET DEFAULT nextval('public.module_installation_events_sequence_seq'::regclass);


--
-- Name: topology_findings status; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_findings ALTER COLUMN status SET DEFAULT 'open'::character varying;


--
-- Name: topology_findings details; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_findings ALTER COLUMN details SET DEFAULT '{}'::jsonb;


--
-- Name: account_authorizations account_authorizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_authorizations
    ADD CONSTRAINT account_authorizations_pkey PRIMARY KEY (id);


--
-- Name: account_challenges account_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_challenges
    ADD CONSTRAINT account_challenges_pkey PRIMARY KEY (id);


--
-- Name: account_security_events account_security_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_security_events
    ADD CONSTRAINT account_security_events_pkey PRIMARY KEY (id);


--
-- Name: actual_component_evidence_matches actual_component_evidence_matches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actual_component_evidence_matches
    ADD CONSTRAINT actual_component_evidence_matches_pkey PRIMARY KEY (id);


--
-- Name: actual_components actual_components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actual_components
    ADD CONSTRAINT actual_components_pkey PRIMARY KEY (id);


--
-- Name: address_evidence address_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_evidence
    ADD CONSTRAINT address_evidence_pkey PRIMARY KEY (id);


--
-- Name: address_findings address_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_findings
    ADD CONSTRAINT address_findings_pkey PRIMARY KEY (id);


--
-- Name: addresses addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_pkey PRIMARY KEY (id);


--
-- Name: addressing_plan_levels addressing_plan_levels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addressing_plan_levels
    ADD CONSTRAINT addressing_plan_levels_pkey PRIMARY KEY (id);


--
-- Name: agent_leases agent_leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_leases
    ADD CONSTRAINT agent_leases_pkey PRIMARY KEY (id);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: background_cursors background_cursors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_cursors
    ADD CONSTRAINT background_cursors_pkey PRIMARY KEY (worker);


--
-- Name: cable_assertions cable_assertions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_pkey PRIMARY KEY (id);


--
-- Name: cable_change_events cable_change_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_change_events
    ADD CONSTRAINT cable_change_events_pkey PRIMARY KEY (id);


--
-- Name: cable_endpoint_terminations cable_endpoint_terminations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_endpoint_terminations
    ADD CONSTRAINT cable_endpoint_terminations_pkey PRIMARY KEY (organization_id, interface_id);


--
-- Name: cable_import_contracts cable_import_contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_import_contracts
    ADD CONSTRAINT cable_import_contracts_pkey PRIMARY KEY (id);


--
-- Name: cable_plans cable_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_plans
    ADD CONSTRAINT cable_plans_pkey PRIMARY KEY (id);


--
-- Name: cables cables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_pkey PRIMARY KEY (id);


--
-- Name: catalog_type_revisions catalog_type_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_type_revisions
    ADD CONSTRAINT catalog_type_revisions_pkey PRIMARY KEY (id);


--
-- Name: change_events change_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_pkey PRIMARY KEY (id);


--
-- Name: change_requests change_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_requests
    ADD CONSTRAINT change_requests_pkey PRIMARY KEY (id);


--
-- Name: collector_findings collector_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_findings
    ADD CONSTRAINT collector_findings_pkey PRIMARY KEY (id);


--
-- Name: collector_target_resources collector_target_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_target_resources
    ADD CONSTRAINT collector_target_resources_pkey PRIMARY KEY (id);


--
-- Name: collector_targets collector_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_targets
    ADD CONSTRAINT collector_targets_pkey PRIMARY KEY (id);


--
-- Name: component_evidence component_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_evidence
    ADD CONSTRAINT component_evidence_pkey PRIMARY KEY (id);


--
-- Name: component_findings component_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_findings
    ADD CONSTRAINT component_findings_pkey PRIMARY KEY (id);


--
-- Name: component_templates component_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_templates
    ADD CONSTRAINT component_templates_pkey PRIMARY KEY (id);


--
-- Name: confirmed_components confirmed_components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmed_components
    ADD CONSTRAINT confirmed_components_pkey PRIMARY KEY (id);


--
-- Name: current_interface_adjacencies_neighbor_storage current_interface_adjacencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacencies_neighbor_storage
    ADD CONSTRAINT current_interface_adjacencies_pkey PRIMARY KEY (id);


--
-- Name: current_interface_adjacency_endpoints current_interface_adjacency_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacency_endpoints
    ADD CONSTRAINT current_interface_adjacency_endpoints_pkey PRIMARY KEY (organization_id, interface_id);


--
-- Name: current_interface_vlan_memberships current_interface_vlan_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_memberships
    ADD CONSTRAINT current_interface_vlan_memberships_pkey PRIMARY KEY (id);


--
-- Name: current_interface_vlan_modes current_interface_vlan_modes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_modes
    ADD CONSTRAINT current_interface_vlan_modes_pkey PRIMARY KEY (id);


--
-- Name: current_module_installations current_module_installations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_module_installations
    ADD CONSTRAINT current_module_installations_pkey PRIMARY KEY (id);


--
-- Name: current_placements current_placements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_placements
    ADD CONSTRAINT current_placements_pkey PRIMARY KEY (id);


--
-- Name: deployment_audit_events deployment_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deployment_audit_events
    ADD CONSTRAINT deployment_audit_events_pkey PRIMARY KEY (id);


--
-- Name: desired_interface_vlan_assignments desired_interface_vlan_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_interface_vlan_assignments
    ADD CONSTRAINT desired_interface_vlan_assignments_pkey PRIMARY KEY (id);


--
-- Name: desired_interface_vlan_modes desired_interface_vlan_modes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_interface_vlan_modes
    ADD CONSTRAINT desired_interface_vlan_modes_pkey PRIMARY KEY (id);


--
-- Name: desired_module_assignments desired_module_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_module_assignments
    ADD CONSTRAINT desired_module_assignments_pkey PRIMARY KEY (id);


--
-- Name: desired_placements desired_placements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_placements
    ADD CONSTRAINT desired_placements_pkey PRIMARY KEY (id);


--
-- Name: expected_component_exceptions expected_component_exceptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_component_exceptions
    ADD CONSTRAINT expected_component_exceptions_pkey PRIMARY KEY (id);


--
-- Name: expected_components expected_components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_components
    ADD CONSTRAINT expected_components_pkey PRIMARY KEY (id);


--
-- Name: finding_workflows finding_workflows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finding_workflows
    ADD CONSTRAINT finding_workflows_pkey PRIMARY KEY (id);


--
-- Name: hardware_assignments hardware_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_assignments
    ADD CONSTRAINT hardware_assignments_pkey PRIMARY KEY (id);


--
-- Name: hardware_match_findings hardware_match_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_match_findings
    ADD CONSTRAINT hardware_match_findings_pkey PRIMARY KEY (id);


--
-- Name: hardware_types hardware_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_types
    ADD CONSTRAINT hardware_types_pkey PRIMARY KEY (id);


--
-- Name: hosts hosts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hosts
    ADD CONSTRAINT hosts_pkey PRIMARY KEY (id);


--
-- Name: identity_provider_attempts identity_provider_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_attempts
    ADD CONSTRAINT identity_provider_attempts_pkey PRIMARY KEY (id);


--
-- Name: identity_provider_events identity_provider_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_events
    ADD CONSTRAINT identity_provider_events_pkey PRIMARY KEY (id);


--
-- Name: identity_provider_revisions identity_provider_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_revisions
    ADD CONSTRAINT identity_provider_revisions_pkey PRIMARY KEY (id);


--
-- Name: identity_provider_tests identity_provider_tests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_tests
    ADD CONSTRAINT identity_provider_tests_pkey PRIMARY KEY (id);


--
-- Name: identity_providers identity_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_providers
    ADD CONSTRAINT identity_providers_pkey PRIMARY KEY (id);


--
-- Name: imported_attributions imported_attributions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_attributions
    ADD CONSTRAINT imported_attributions_pkey PRIMARY KEY (record_type, record_id, field);


--
-- Name: imported_held_records imported_held_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_held_records
    ADD CONSTRAINT imported_held_records_pkey PRIMARY KEY (id);


--
-- Name: imported_principals imported_principals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_principals
    ADD CONSTRAINT imported_principals_pkey PRIMARY KEY (id);


--
-- Name: installation_keys installation_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_keys
    ADD CONSTRAINT installation_keys_pkey PRIMARY KEY (id);


--
-- Name: intake_api_keys intake_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intake_api_keys
    ADD CONSTRAINT intake_api_keys_pkey PRIMARY KEY (id);


--
-- Name: interface_evidence interface_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_evidence
    ADD CONSTRAINT interface_evidence_pkey PRIMARY KEY (id);


--
-- Name: interface_neighbor_evidence_neighbor_storage interface_neighbor_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_evidence_neighbor_storage
    ADD CONSTRAINT interface_neighbor_evidence_pkey PRIMARY KEY (id);


--
-- Name: interface_neighbor_matches_neighbor_storage interface_neighbor_matches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_matches_neighbor_storage
    ADD CONSTRAINT interface_neighbor_matches_pkey PRIMARY KEY (id);


--
-- Name: interface_relationship_evidence interface_relationship_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationship_evidence
    ADD CONSTRAINT interface_relationship_evidence_pkey PRIMARY KEY (id);


--
-- Name: interface_relationships interface_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationships
    ADD CONSTRAINT interface_relationships_pkey PRIMARY KEY (id);


--
-- Name: interface_routing_domain_evidence interface_routing_domain_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domain_evidence
    ADD CONSTRAINT interface_routing_domain_evidence_pkey PRIMARY KEY (id);


--
-- Name: interface_routing_domains interface_routing_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domains
    ADD CONSTRAINT interface_routing_domains_pkey PRIMARY KEY (interface_id);


--
-- Name: interface_vlan_evidence interface_vlan_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_evidence
    ADD CONSTRAINT interface_vlan_evidence_pkey PRIMARY KEY (id);


--
-- Name: interface_vlan_mode_evidence interface_vlan_mode_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_mode_evidence
    ADD CONSTRAINT interface_vlan_mode_evidence_pkey PRIMARY KEY (id);


--
-- Name: interfaces interfaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interfaces
    ADD CONSTRAINT interfaces_pkey PRIMARY KEY (id);


--
-- Name: inventory_items inventory_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT inventory_items_pkey PRIMARY KEY (id);


--
-- Name: ip_address_assignments ip_address_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_address_assignments
    ADD CONSTRAINT ip_address_assignments_pkey PRIMARY KEY (id);


--
-- Name: ip_addresses ip_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_addresses
    ADD CONSTRAINT ip_addresses_pkey PRIMARY KEY (id);


--
-- Name: job_events job_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_events
    ADD CONSTRAINT job_events_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: local_sign_in_overrides local_sign_in_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_sign_in_overrides
    ADD CONSTRAINT local_sign_in_overrides_pkey PRIMARY KEY (id);


--
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id);


--
-- Name: manufacturers manufacturers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manufacturers
    ADD CONSTRAINT manufacturers_pkey PRIMARY KEY (id);


--
-- Name: module_bay_compatible_types module_bay_compatible_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_bay_compatible_types
    ADD CONSTRAINT module_bay_compatible_types_pkey PRIMARY KEY (module_bay_id, module_type_id);


--
-- Name: module_bays module_bays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_bays
    ADD CONSTRAINT module_bays_pkey PRIMARY KEY (id);


--
-- Name: module_installation_events module_installation_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_installation_events
    ADD CONSTRAINT module_installation_events_pkey PRIMARY KEY (id);


--
-- Name: module_types module_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_types
    ADD CONSTRAINT module_types_pkey PRIMARY KEY (id);


--
-- Name: modules modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_pkey PRIMARY KEY (id);


--
-- Name: neighbor_generation_heads neighbor_generation_heads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generation_heads
    ADD CONSTRAINT neighbor_generation_heads_pkey PRIMARY KEY (organization_id);


--
-- Name: neighbor_generation_rows neighbor_generation_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generation_rows
    ADD CONSTRAINT neighbor_generation_rows_pkey PRIMARY KEY (generation_id, kind, key);


--
-- Name: neighbor_generations neighbor_generations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generations
    ADD CONSTRAINT neighbor_generations_pkey PRIMARY KEY (id);


--
-- Name: observation_reconciliations observation_reconciliations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observation_reconciliations
    ADD CONSTRAINT observation_reconciliations_pkey PRIMARY KEY (id);


--
-- Name: observations observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_pkey PRIMARY KEY (id);


--
-- Name: operator_idempotency_keys operator_idempotency_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operator_idempotency_keys
    ADD CONSTRAINT operator_idempotency_keys_pkey PRIMARY KEY (id);


--
-- Name: operator_invitation_deliveries operator_invitation_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operator_invitation_deliveries
    ADD CONSTRAINT operator_invitation_deliveries_pkey PRIMARY KEY (id);


--
-- Name: operator_tokens operator_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operator_tokens
    ADD CONSTRAINT operator_tokens_pkey PRIMARY KEY (id);


--
-- Name: organization_domains organization_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_domains
    ADD CONSTRAINT organization_domains_pkey PRIMARY KEY (id);


--
-- Name: organization_export_chunks organization_export_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_export_chunks
    ADD CONSTRAINT organization_export_chunks_pkey PRIMARY KEY (export_id, "position");


--
-- Name: organization_exports organization_exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_exports
    ADD CONSTRAINT organization_exports_pkey PRIMARY KEY (id);


--
-- Name: organization_imports organization_imports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_imports
    ADD CONSTRAINT organization_imports_pkey PRIMARY KEY (id);


--
-- Name: organization_invitations organization_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_pkey PRIMARY KEY (id);


--
-- Name: organization_lifecycle_notices organization_lifecycle_notices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_lifecycle_notices
    ADD CONSTRAINT organization_lifecycle_notices_pkey PRIMARY KEY (id);


--
-- Name: organization_limits organization_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_limits
    ADD CONSTRAINT organization_limits_pkey PRIMARY KEY (id);


--
-- Name: organization_memberships organization_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_pkey PRIMARY KEY (id);


--
-- Name: organization_security_settings organization_security_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_security_settings
    ADD CONSTRAINT organization_security_settings_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: placement_evidence placement_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placement_evidence
    ADD CONSTRAINT placement_evidence_pkey PRIMARY KEY (id);


--
-- Name: placement_findings placement_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placement_findings
    ADD CONSTRAINT placement_findings_pkey PRIMARY KEY (id);


--
-- Name: power_correlation_samples power_correlation_samples_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_correlation_samples
    ADD CONSTRAINT power_correlation_samples_pkey PRIMARY KEY (id);


--
-- Name: power_feeds power_feeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_feeds
    ADD CONSTRAINT power_feeds_pkey PRIMARY KEY (id);


--
-- Name: power_findings power_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_findings
    ADD CONSTRAINT power_findings_pkey PRIMARY KEY (id);


--
-- Name: power_outlets power_outlets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_outlets
    ADD CONSTRAINT power_outlets_pkey PRIMARY KEY (id);


--
-- Name: power_panels power_panels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_panels
    ADD CONSTRAINT power_panels_pkey PRIMARY KEY (id);


--
-- Name: power_ports power_ports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_ports
    ADD CONSTRAINT power_ports_pkey PRIMARY KEY (id);


--
-- Name: power_readings power_readings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_readings
    ADD CONSTRAINT power_readings_pkey PRIMARY KEY (id);


--
-- Name: prefix_vlan_relationships prefix_vlan_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefix_vlan_relationships
    ADD CONSTRAINT prefix_vlan_relationships_pkey PRIMARY KEY (id);


--
-- Name: prefixes prefixes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefixes
    ADD CONSTRAINT prefixes_pkey PRIMARY KEY (id);


--
-- Name: rack_occupancies rack_occupancies_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rack_occupancies
    ADD CONSTRAINT rack_occupancies_no_overlap EXCLUDE USING gist (rack_id WITH =, face WITH =, units WITH &&);


--
-- Name: rack_occupancies rack_occupancies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rack_occupancies
    ADD CONSTRAINT rack_occupancies_pkey PRIMARY KEY (id);


--
-- Name: racks racks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.racks
    ADD CONSTRAINT racks_pkey PRIMARY KEY (id);


--
-- Name: reconciliation_lanes reconciliation_lanes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_lanes
    ADD CONSTRAINT reconciliation_lanes_pkey PRIMARY KEY (organization_id);


--
-- Name: reconciliation_work reconciliation_work_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_work
    ADD CONSTRAINT reconciliation_work_pkey PRIMARY KEY (id);


--
-- Name: resource_conditions resource_conditions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_conditions
    ADD CONSTRAINT resource_conditions_pkey PRIMARY KEY (id);


--
-- Name: resource_group_members resource_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_members
    ADD CONSTRAINT resource_group_members_pkey PRIMARY KEY (id);


--
-- Name: resource_group_memberships resource_group_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_memberships
    ADD CONSTRAINT resource_group_memberships_pkey PRIMARY KEY (organization_id, resource_id, view, group_id);


--
-- Name: resource_group_sets resource_group_sets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_sets
    ADD CONSTRAINT resource_group_sets_pkey PRIMARY KEY (id);


--
-- Name: resource_group_suggestion_dismissals resource_group_suggestion_dismissals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestion_dismissals
    ADD CONSTRAINT resource_group_suggestion_dismissals_pkey PRIMARY KEY (id);


--
-- Name: resource_group_suggestions resource_group_suggestions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestions
    ADD CONSTRAINT resource_group_suggestions_pkey PRIMARY KEY (id);


--
-- Name: resource_groups resource_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_groups
    ADD CONSTRAINT resource_groups_pkey PRIMARY KEY (id);


--
-- Name: resource_identifier_claims resource_identifier_claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifier_claims
    ADD CONSTRAINT resource_identifier_claims_pkey PRIMARY KEY (id);


--
-- Name: resource_identifiers resource_identifiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifiers
    ADD CONSTRAINT resource_identifiers_pkey PRIMARY KEY (id);


--
-- Name: resource_overrides resource_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_overrides
    ADD CONSTRAINT resource_overrides_pkey PRIMARY KEY (id);


--
-- Name: resource_owners resource_owners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_owners
    ADD CONSTRAINT resource_owners_pkey PRIMARY KEY (id);


--
-- Name: resource_relationships resource_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_relationships
    ADD CONSTRAINT resource_relationships_pkey PRIMARY KEY (id);


--
-- Name: resource_revisions resource_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_revisions
    ADD CONSTRAINT resource_revisions_pkey PRIMARY KEY (id);


--
-- Name: resources resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_pkey PRIMARY KEY (id);


--
-- Name: role_assignments role_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments
    ADD CONSTRAINT role_assignments_pkey PRIMARY KEY (id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: saved_views saved_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_views
    ADD CONSTRAINT saved_views_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: scim_connections scim_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_connections
    ADD CONSTRAINT scim_connections_pkey PRIMARY KEY (id);


--
-- Name: scim_group_members scim_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_group_members
    ADD CONSTRAINT scim_group_members_pkey PRIMARY KEY (group_id, user_id);


--
-- Name: scim_groups scim_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_groups
    ADD CONSTRAINT scim_groups_pkey PRIMARY KEY (id);


--
-- Name: scim_tokens scim_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT scim_tokens_pkey PRIMARY KEY (id);


--
-- Name: scim_users scim_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_users
    ADD CONSTRAINT scim_users_pkey PRIMARY KEY (id);


--
-- Name: site_groups site_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_groups
    ADD CONSTRAINT site_groups_pkey PRIMARY KEY (id);


--
-- Name: sites sites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_pkey PRIMARY KEY (id);


--
-- Name: source_routing_domain_mappings source_routing_domain_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_routing_domain_mappings
    ADD CONSTRAINT source_routing_domain_mappings_pkey PRIMARY KEY (id);


--
-- Name: source_vlan_group_mappings source_vlan_group_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_vlan_group_mappings
    ADD CONSTRAINT source_vlan_group_mappings_pkey PRIMARY KEY (id);


--
-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (id);


--
-- Name: sync_runs sync_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT sync_runs_pkey PRIMARY KEY (id);


--
-- Name: target_bindings target_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.target_bindings
    ADD CONSTRAINT target_bindings_pkey PRIMARY KEY (id);


--
-- Name: team_memberships team_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT team_memberships_pkey PRIMARY KEY (id);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id);


--
-- Name: telemetry_batches telemetry_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_batches
    ADD CONSTRAINT telemetry_batches_pkey PRIMARY KEY (id);


--
-- Name: telemetry_buckets telemetry_buckets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_buckets
    ADD CONSTRAINT telemetry_buckets_pkey PRIMARY KEY (organization_id, series, bucket_start);


--
-- Name: telemetry_marks telemetry_marks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_marks
    ADD CONSTRAINT telemetry_marks_pkey PRIMARY KEY (organization_id, name);


--
-- Name: topology_findings_neighbor_storage topology_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_findings_neighbor_storage
    ADD CONSTRAINT topology_findings_pkey PRIMARY KEY (id);


--
-- Name: topology_snapshot_events topology_snapshot_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_snapshot_events
    ADD CONSTRAINT topology_snapshot_events_pkey PRIMARY KEY (id);


--
-- Name: triage_rules triage_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_pkey PRIMARY KEY (id);


--
-- Name: user_identities user_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_identities
    ADD CONSTRAINT user_identities_pkey PRIMARY KEY (id);


--
-- Name: user_passkeys user_passkeys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_passkeys
    ADD CONSTRAINT user_passkeys_pkey PRIMARY KEY (id);


--
-- Name: user_recovery_codes user_recovery_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_recovery_codes
    ADD CONSTRAINT user_recovery_codes_pkey PRIMARY KEY (id);


--
-- Name: user_totps user_totps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_totps
    ADD CONSTRAINT user_totps_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users_tokens users_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_pkey PRIMARY KEY (id);


--
-- Name: vlan_group_vid_ranges vlan_group_vid_ranges_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlan_group_vid_ranges
    ADD CONSTRAINT vlan_group_vid_ranges_no_overlap EXCLUDE USING gist (vlan_group_id WITH =, int4range(start_vid, end_vid, '[]'::text) WITH &&);


--
-- Name: vlan_group_vid_ranges vlan_group_vid_ranges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlan_group_vid_ranges
    ADD CONSTRAINT vlan_group_vid_ranges_pkey PRIMARY KEY (id);


--
-- Name: vlan_groups vlan_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlan_groups
    ADD CONSTRAINT vlan_groups_pkey PRIMARY KEY (id);


--
-- Name: vlans vlans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlans
    ADD CONSTRAINT vlans_pkey PRIMARY KEY (id);


--
-- Name: vrfs vrfs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vrfs
    ADD CONSTRAINT vrfs_pkey PRIMARY KEY (id);


--
-- Name: webauthn_challenges webauthn_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webauthn_challenges
    ADD CONSTRAINT webauthn_challenges_pkey PRIMARY KEY (id);


--
-- Name: account_authorizations_session_token_id_purpose_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX account_authorizations_session_token_id_purpose_index ON public.account_authorizations USING btree (session_token_id, purpose);


--
-- Name: account_authorizations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_authorizations_user_id_index ON public.account_authorizations USING btree (user_id);


--
-- Name: account_challenges_session_token_id_purpose_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX account_challenges_session_token_id_purpose_index ON public.account_challenges USING btree (session_token_id, purpose);


--
-- Name: account_challenges_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_challenges_user_id_index ON public.account_challenges USING btree (user_id);


--
-- Name: account_security_events_user_id_kind_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_security_events_user_id_kind_inserted_at_index ON public.account_security_events USING btree (user_id, kind, inserted_at);


--
-- Name: actual_component_evidence_matches_component_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX actual_component_evidence_matches_component_index ON public.actual_component_evidence_matches USING btree (organization_id, owner_resource_id, actual_component_id);


--
-- Name: actual_component_evidence_matches_evidence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX actual_component_evidence_matches_evidence_index ON public.actual_component_evidence_matches USING btree (component_evidence_id);


--
-- Name: actual_component_evidence_matches_finding_scope_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX actual_component_evidence_matches_finding_scope_index ON public.actual_component_evidence_matches USING btree (organization_id, owner_resource_id) INCLUDE (component_evidence_id);


--
-- Name: actual_components_evidence_owner_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX actual_components_evidence_owner_index ON public.actual_components USING btree (id, organization_id, owner_resource_id);


--
-- Name: actual_components_owner_kind_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX actual_components_owner_kind_path_index ON public.actual_components USING btree (organization_id, owner_resource_id, kind, path);


--
-- Name: actual_components_owner_kind_slot_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX actual_components_owner_kind_slot_index ON public.actual_components USING btree (organization_id, owner_resource_id, kind, slot);


--
-- Name: actual_components_serial_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX actual_components_serial_identity_index ON public.actual_components USING btree (organization_id, owner_resource_id, kind, lower((serial_number)::text)) WHERE (serial_number IS NOT NULL);


--
-- Name: address_evidence_observation_link_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX address_evidence_observation_link_index ON public.address_evidence USING btree (organization_id, observation_id, address_id, address);


--
-- Name: address_evidence_organization_id_source_id_address_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX address_evidence_organization_id_source_id_address_id_index ON public.address_evidence USING btree (organization_id, source_id, address_id);


--
-- Name: address_findings_open_resolution_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX address_findings_open_resolution_index ON public.address_findings USING btree (organization_id, interface_id, kind, resolution_key) WHERE ((status)::text = 'open'::text);


--
-- Name: address_findings_organization_id_interface_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX address_findings_organization_id_interface_id_index ON public.address_findings USING btree (organization_id, interface_id);


--
-- Name: address_findings_organization_id_status_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX address_findings_organization_id_status_kind_index ON public.address_findings USING btree (organization_id, status, kind);


--
-- Name: addresses_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX addresses_id_organization_id_index ON public.addresses USING btree (id, organization_id);


--
-- Name: addresses_interface_host_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX addresses_interface_host_index ON public.addresses USING btree (organization_id, interface_id, ((host(address))::inet));


--
-- Name: addresses_organization_id_interface_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX addresses_organization_id_interface_id_index ON public.addresses USING btree (organization_id, interface_id);


--
-- Name: addresses_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX addresses_organization_id_resource_id_index ON public.addresses USING btree (organization_id, resource_id);


--
-- Name: addressing_plan_levels_family_length_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX addressing_plan_levels_family_length_index ON public.addressing_plan_levels USING btree (organization_id, family, prefix_length);


--
-- Name: agent_leases_organization_id_agent_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_leases_organization_id_agent_id_index ON public.agent_leases USING btree (organization_id, agent_id);


--
-- Name: agent_leases_organization_id_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_leases_organization_id_expires_at_index ON public.agent_leases USING btree (organization_id, expires_at);


--
-- Name: agents_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agents_id_organization_id_index ON public.agents USING btree (id, organization_id);


--
-- Name: agents_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agents_organization_id_source_id_index ON public.agents USING btree (organization_id, source_id);


--
-- Name: agents_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agents_organization_id_status_index ON public.agents USING btree (organization_id, status);


--
-- Name: agents_organization_installation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agents_organization_installation_id_index ON public.agents USING btree (organization_id, installation_id) WHERE (installation_id IS NOT NULL);


--
-- Name: cable_assertions_a_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_assertions_a_index ON public.cable_assertions USING btree (organization_id, interface_a_id, asserted_at);


--
-- Name: cable_assertions_b_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_assertions_b_index ON public.cable_assertions USING btree (organization_id, interface_b_id, asserted_at);


--
-- Name: cable_assertions_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cable_assertions_id_organization_id_index ON public.cable_assertions USING btree (id, organization_id);


--
-- Name: cable_assertions_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_assertions_kind_index ON public.cable_assertions USING btree (organization_id, kind, asserted_at);


--
-- Name: cable_assertions_organization_id_power_port_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_assertions_organization_id_power_port_id_index ON public.cable_assertions USING btree (organization_id, power_port_id) WHERE (power_port_id IS NOT NULL);


--
-- Name: cable_change_events_cable_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_change_events_cable_sequence_index ON public.cable_change_events USING btree (organization_id, cable_id, sequence);


--
-- Name: cable_endpoint_terminations_cable_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_endpoint_terminations_cable_index ON public.cable_endpoint_terminations USING btree (cable_id, organization_id);


--
-- Name: cable_import_contracts_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cable_import_contracts_id_organization_id_index ON public.cable_import_contracts USING btree (id, organization_id);


--
-- Name: cable_import_contracts_source_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cable_import_contracts_source_index ON public.cable_import_contracts USING btree (organization_id, source_id);


--
-- Name: cable_plans_a_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_plans_a_index ON public.cable_plans USING btree (organization_id, interface_a_id);


--
-- Name: cable_plans_b_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cable_plans_b_index ON public.cable_plans USING btree (organization_id, interface_b_id);


--
-- Name: cable_plans_endpoints_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cable_plans_endpoints_index ON public.cable_plans USING btree (organization_id, interface_a_id, interface_b_id);


--
-- Name: cable_plans_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cable_plans_id_organization_id_index ON public.cable_plans USING btree (id, organization_id);


--
-- Name: cable_plans_power_feed_pair_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cable_plans_power_feed_pair_index ON public.cable_plans USING btree (organization_id, power_port_id, power_feed_id) WHERE (power_feed_id IS NOT NULL);


--
-- Name: cable_plans_power_outlet_pair_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cable_plans_power_outlet_pair_index ON public.cable_plans USING btree (organization_id, power_port_id, power_outlet_id) WHERE (power_outlet_id IS NOT NULL);


--
-- Name: cables_a_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cables_a_index ON public.cables USING btree (organization_id, interface_a_id);


--
-- Name: cables_b_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cables_b_index ON public.cables USING btree (organization_id, interface_b_id);


--
-- Name: cables_endpoints_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cables_endpoints_index ON public.cables USING btree (organization_id, interface_a_id, interface_b_id);


--
-- Name: cables_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cables_id_organization_id_index ON public.cables USING btree (id, organization_id);


--
-- Name: cables_power_feed_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cables_power_feed_index ON public.cables USING btree (organization_id, power_feed_id) WHERE (power_feed_id IS NOT NULL);


--
-- Name: cables_power_outlet_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cables_power_outlet_index ON public.cables USING btree (organization_id, power_outlet_id) WHERE (power_outlet_id IS NOT NULL);


--
-- Name: cables_power_port_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cables_power_port_index ON public.cables USING btree (organization_id, power_port_id) WHERE (power_port_id IS NOT NULL);


--
-- Name: catalog_type_revisions_hardware_assignment_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_type_revisions_hardware_assignment_index ON public.catalog_type_revisions USING btree (id, organization_id, hardware_type_id);


--
-- Name: catalog_type_revisions_hardware_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_type_revisions_hardware_revision_index ON public.catalog_type_revisions USING btree (organization_id, hardware_type_id, revision) WHERE (hardware_type_id IS NOT NULL);


--
-- Name: catalog_type_revisions_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_type_revisions_id_organization_id_index ON public.catalog_type_revisions USING btree (id, organization_id);


--
-- Name: catalog_type_revisions_module_assignment_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_type_revisions_module_assignment_index ON public.catalog_type_revisions USING btree (id, organization_id, module_type_id);


--
-- Name: catalog_type_revisions_module_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_type_revisions_module_revision_index ON public.catalog_type_revisions USING btree (organization_id, module_type_id, revision) WHERE (module_type_id IS NOT NULL);


--
-- Name: catalog_type_revisions_one_hardware_draft_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_type_revisions_one_hardware_draft_index ON public.catalog_type_revisions USING btree (organization_id, hardware_type_id) WHERE ((hardware_type_id IS NOT NULL) AND (finalized_at IS NULL));


--
-- Name: catalog_type_revisions_one_module_draft_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_type_revisions_one_module_draft_index ON public.catalog_type_revisions USING btree (organization_id, module_type_id) WHERE ((module_type_id IS NOT NULL) AND (finalized_at IS NULL));


--
-- Name: change_events_finding_workflow_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_events_finding_workflow_id_index ON public.change_events USING btree (finding_workflow_id);


--
-- Name: change_events_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_events_organization_id_kind_index ON public.change_events USING btree (organization_id, kind);


--
-- Name: change_events_organization_id_occurred_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_events_organization_id_occurred_at_index ON public.change_events USING btree (organization_id, occurred_at);


--
-- Name: change_events_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_events_organization_id_resource_id_index ON public.change_events USING btree (organization_id, resource_id);


--
-- Name: change_events_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_events_organization_id_source_id_index ON public.change_events USING btree (organization_id, source_id);


--
-- Name: change_events_organization_id_sync_run_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_events_organization_id_sync_run_id_index ON public.change_events USING btree (organization_id, sync_run_id);


--
-- Name: change_requests_open_change_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX change_requests_open_change_index ON public.change_requests USING btree (organization_id, resource_id, kind, field) WHERE ((status)::text = 'open'::text);


--
-- Name: change_requests_organization_id_kind_field_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_requests_organization_id_kind_field_status_index ON public.change_requests USING btree (organization_id, kind, field, status);


--
-- Name: change_requests_organization_id_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX change_requests_organization_id_status_inserted_at_index ON public.change_requests USING btree (organization_id, status, inserted_at);


--
-- Name: collector_findings_open_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX collector_findings_open_index ON public.collector_findings USING btree (organization_id, resource_id, agent_id, kind, target_id) NULLS NOT DISTINCT WHERE ((status)::text = 'open'::text);


--
-- Name: collector_findings_organization_id_agent_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX collector_findings_organization_id_agent_id_status_index ON public.collector_findings USING btree (organization_id, agent_id, status);


--
-- Name: collector_findings_organization_id_status_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX collector_findings_organization_id_status_kind_index ON public.collector_findings USING btree (organization_id, status, kind);


--
-- Name: collector_target_resources_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX collector_target_resources_organization_id_resource_id_index ON public.collector_target_resources USING btree (organization_id, resource_id);


--
-- Name: collector_target_resources_organization_id_target_id_resource_i; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX collector_target_resources_organization_id_target_id_resource_i ON public.collector_target_resources USING btree (organization_id, target_id, resource_id);


--
-- Name: collector_targets_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX collector_targets_id_organization_id_index ON public.collector_targets USING btree (id, organization_id);


--
-- Name: collector_targets_id_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX collector_targets_id_organization_id_source_id_index ON public.collector_targets USING btree (id, organization_id, source_id);


--
-- Name: collector_targets_organization_id_source_id_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX collector_targets_organization_id_source_id_key_index ON public.collector_targets USING btree (organization_id, source_id, key);


--
-- Name: component_evidence_actual_component_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_evidence_actual_component_index ON public.component_evidence USING btree (id, organization_id, resource_id);


--
-- Name: component_evidence_observation_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_evidence_observation_identity_index ON public.component_evidence USING btree (organization_id, observation_id, kind, source_local_id);


--
-- Name: component_evidence_resource_source_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_evidence_resource_source_kind_index ON public.component_evidence USING btree (organization_id, resource_id, source_id, kind, observed_at);


--
-- Name: component_findings_open_resolution_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_findings_open_resolution_index ON public.component_findings USING btree (organization_id, resource_id, kind, resolution_key) WHERE ((status)::text = 'open'::text);


--
-- Name: component_findings_resource_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_findings_resource_status_index ON public.component_findings USING btree (organization_id, resource_id, status);


--
-- Name: component_templates_expectation_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_templates_expectation_index ON public.component_templates USING btree (id, organization_id, catalog_type_revision_id);


--
-- Name: component_templates_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_templates_id_organization_id_index ON public.component_templates USING btree (id, organization_id);


--
-- Name: component_templates_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_templates_identity_index ON public.component_templates USING btree (organization_id, catalog_type_revision_id, kind, lower((name)::text));


--
-- Name: component_templates_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_templates_organization_id_kind_index ON public.component_templates USING btree (organization_id, kind);


--
-- Name: confirmed_components_exception_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX confirmed_components_exception_index ON public.confirmed_components USING btree (hardware_assignment_id, exception_id) WHERE (exception_id IS NOT NULL);


--
-- Name: confirmed_components_template_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX confirmed_components_template_index ON public.confirmed_components USING btree (hardware_assignment_id, component_template_id) WHERE (component_template_id IS NOT NULL);


--
-- Name: current_interface_adjacencies_a_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX current_interface_adjacencies_a_index ON public.current_interface_adjacencies_neighbor_storage USING btree (organization_id, interface_a_id);


--
-- Name: current_interface_adjacencies_b_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX current_interface_adjacencies_b_index ON public.current_interface_adjacencies_neighbor_storage USING btree (organization_id, interface_b_id);


--
-- Name: current_interface_adjacencies_endpoints_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_interface_adjacencies_endpoints_index ON public.current_interface_adjacencies_neighbor_storage USING btree (organization_id, interface_a_id, interface_b_id);


--
-- Name: current_interface_adjacencies_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_interface_adjacencies_id_organization_id_index ON public.current_interface_adjacencies_neighbor_storage USING btree (id, organization_id);


--
-- Name: current_interface_adjacency_endpoints_adjacency_id_organization; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX current_interface_adjacency_endpoints_adjacency_id_organization ON public.current_interface_adjacency_endpoints USING btree (adjacency_id, organization_id);


--
-- Name: current_interface_vlan_memberships_effective_untagged_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_interface_vlan_memberships_effective_untagged_index ON public.current_interface_vlan_memberships USING btree (organization_id, interface_id) WHERE ((tagging_mode)::text = 'untagged'::text);


--
-- Name: current_interface_vlan_memberships_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_interface_vlan_memberships_id_organization_id_index ON public.current_interface_vlan_memberships USING btree (id, organization_id);


--
-- Name: current_interface_vlan_memberships_interface_vlan_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_interface_vlan_memberships_interface_vlan_index ON public.current_interface_vlan_memberships USING btree (organization_id, interface_id, vlan_id);


--
-- Name: current_interface_vlan_modes_organization_id_interface_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_interface_vlan_modes_organization_id_interface_id_index ON public.current_interface_vlan_modes USING btree (organization_id, interface_id);


--
-- Name: current_module_installations_bay_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_module_installations_bay_index ON public.current_module_installations USING btree (organization_id, module_bay_id);


--
-- Name: current_module_installations_module_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_module_installations_module_index ON public.current_module_installations USING btree (organization_id, module_id);


--
-- Name: current_placements_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_placements_id_organization_id_index ON public.current_placements USING btree (id, organization_id);


--
-- Name: current_placements_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX current_placements_organization_id_resource_id_index ON public.current_placements USING btree (organization_id, resource_id);


--
-- Name: deployment_audit_events_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX deployment_audit_events_inserted_at_index ON public.deployment_audit_events USING btree (inserted_at);


--
-- Name: deployment_audit_events_organization_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX deployment_audit_events_organization_id_inserted_at_index ON public.deployment_audit_events USING btree (organization_id, inserted_at);


--
-- Name: desired_interface_vlan_assignments_effective_untagged_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX desired_interface_vlan_assignments_effective_untagged_index ON public.desired_interface_vlan_assignments USING btree (organization_id, interface_id) WHERE ((tagging_mode)::text = 'untagged'::text);


--
-- Name: desired_interface_vlan_assignments_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX desired_interface_vlan_assignments_id_organization_id_index ON public.desired_interface_vlan_assignments USING btree (id, organization_id);


--
-- Name: desired_interface_vlan_assignments_interface_vlan_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX desired_interface_vlan_assignments_interface_vlan_index ON public.desired_interface_vlan_assignments USING btree (organization_id, interface_id, vlan_id);


--
-- Name: desired_interface_vlan_modes_organization_id_interface_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX desired_interface_vlan_modes_organization_id_interface_id_index ON public.desired_interface_vlan_modes USING btree (organization_id, interface_id);


--
-- Name: desired_module_assignments_bay_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX desired_module_assignments_bay_index ON public.desired_module_assignments USING btree (organization_id, module_bay_id);


--
-- Name: desired_placements_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX desired_placements_id_organization_id_index ON public.desired_placements USING btree (id, organization_id);


--
-- Name: desired_placements_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX desired_placements_organization_id_resource_id_index ON public.desired_placements USING btree (organization_id, resource_id);


--
-- Name: expected_component_exceptions_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX expected_component_exceptions_id_organization_id_index ON public.expected_component_exceptions USING btree (id, organization_id);


--
-- Name: expected_component_exceptions_template_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX expected_component_exceptions_template_index ON public.expected_component_exceptions USING btree (organization_id, hardware_assignment_id, component_template_id) WHERE (component_template_id IS NOT NULL);


--
-- Name: expected_components_assignment_kind_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX expected_components_assignment_kind_name_index ON public.expected_components USING btree (organization_id, hardware_assignment_id, kind, name);


--
-- Name: expected_components_assignment_suppressed_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX expected_components_assignment_suppressed_index ON public.expected_components USING btree (organization_id, hardware_assignment_id, suppressed);


--
-- Name: finding_workflows_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX finding_workflows_identity_index ON public.finding_workflows USING btree (organization_id, domain, subject_id, kind, resolution_key);


--
-- Name: finding_workflows_organization_id_assignee_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finding_workflows_organization_id_assignee_user_id_index ON public.finding_workflows USING btree (organization_id, assignee_user_id);


--
-- Name: finding_workflows_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finding_workflows_organization_id_resource_id_index ON public.finding_workflows USING btree (organization_id, resource_id);


--
-- Name: hardware_assignments_expectation_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hardware_assignments_expectation_index ON public.hardware_assignments USING btree (id, organization_id, catalog_type_revision_id);


--
-- Name: hardware_assignments_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hardware_assignments_id_organization_id_index ON public.hardware_assignments USING btree (id, organization_id);


--
-- Name: hardware_assignments_organization_id_hardware_type_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hardware_assignments_organization_id_hardware_type_id_index ON public.hardware_assignments USING btree (organization_id, hardware_type_id);


--
-- Name: hardware_assignments_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hardware_assignments_organization_id_resource_id_index ON public.hardware_assignments USING btree (organization_id, resource_id);


--
-- Name: hardware_match_findings_open_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hardware_match_findings_open_kind_index ON public.hardware_match_findings USING btree (organization_id, resource_id, kind) WHERE ((status)::text = 'open'::text);


--
-- Name: hardware_match_findings_organization_id_status_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hardware_match_findings_organization_id_status_kind_index ON public.hardware_match_findings USING btree (organization_id, status, kind);


--
-- Name: hardware_types_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hardware_types_id_organization_id_index ON public.hardware_types USING btree (id, organization_id);


--
-- Name: hardware_types_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hardware_types_organization_id_resource_id_index ON public.hardware_types USING btree (organization_id, resource_id);


--
-- Name: hardware_types_organization_manufacturer_model_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hardware_types_organization_manufacturer_model_index ON public.hardware_types USING btree (organization_id, manufacturer_id, lower((model)::text));


--
-- Name: hosts_organization_id_asset_tag_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hosts_organization_id_asset_tag_index ON public.hosts USING btree (organization_id, asset_tag);


--
-- Name: hosts_organization_id_fqdn_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hosts_organization_id_fqdn_index ON public.hosts USING btree (organization_id, fqdn);


--
-- Name: hosts_organization_id_hostname_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hosts_organization_id_hostname_index ON public.hosts USING btree (organization_id, hostname);


--
-- Name: hosts_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hosts_organization_id_resource_id_index ON public.hosts USING btree (organization_id, resource_id);


--
-- Name: identity_provider_attempts_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX identity_provider_attempts_expires_at_index ON public.identity_provider_attempts USING btree (expires_at);


--
-- Name: identity_provider_attempts_state_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX identity_provider_attempts_state_hash_index ON public.identity_provider_attempts USING btree (state_hash);


--
-- Name: identity_provider_events_provider_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX identity_provider_events_provider_id_inserted_at_index ON public.identity_provider_events USING btree (provider_id, inserted_at);


--
-- Name: identity_provider_revisions_provider_id_number_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX identity_provider_revisions_provider_id_number_index ON public.identity_provider_revisions USING btree (provider_id, number);


--
-- Name: identity_provider_tests_provider_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX identity_provider_tests_provider_id_index ON public.identity_provider_tests USING btree (provider_id);


--
-- Name: identity_provider_tests_state_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX identity_provider_tests_state_hash_index ON public.identity_provider_tests USING btree (state_hash);


--
-- Name: identity_provider_tests_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX identity_provider_tests_token_hash_index ON public.identity_provider_tests USING btree (token_hash);


--
-- Name: identity_providers_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX identity_providers_organization_id_index ON public.identity_providers USING btree (organization_id);


--
-- Name: imported_attributions_principal_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX imported_attributions_principal_id_index ON public.imported_attributions USING btree (principal_id);


--
-- Name: imported_held_records_principal_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX imported_held_records_principal_id_index ON public.imported_held_records USING btree (principal_id);


--
-- Name: imported_principals_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX imported_principals_id_organization_id_index ON public.imported_principals USING btree (id, organization_id);


--
-- Name: imported_principals_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX imported_principals_organization_id_source_id_index ON public.imported_principals USING btree (organization_id, source_id);


--
-- Name: installation_keys_current_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX installation_keys_current_index ON public.installation_keys USING btree (organization_id, agent_id) WHERE ((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying])::text[]));


--
-- Name: installation_keys_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX installation_keys_id_organization_id_index ON public.installation_keys USING btree (id, organization_id);


--
-- Name: installation_keys_organization_id_agent_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX installation_keys_organization_id_agent_id_inserted_at_index ON public.installation_keys USING btree (organization_id, agent_id, inserted_at);


--
-- Name: intake_api_keys_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX intake_api_keys_id_organization_id_index ON public.intake_api_keys USING btree (id, organization_id);


--
-- Name: intake_api_keys_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX intake_api_keys_organization_id_status_index ON public.intake_api_keys USING btree (organization_id, status);


--
-- Name: intake_api_keys_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX intake_api_keys_token_hash_index ON public.intake_api_keys USING btree (token_hash);


--
-- Name: interface_evidence_component_template_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_evidence_component_template_index ON public.interface_evidence USING btree (organization_id, component_template_id);


--
-- Name: interface_evidence_observation_link_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_evidence_observation_link_index ON public.interface_evidence USING btree (organization_id, observation_id, interface_id);


--
-- Name: interface_evidence_organization_id_source_id_interface_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_evidence_organization_id_source_id_interface_id_index ON public.interface_evidence USING btree (organization_id, source_id, interface_id);


--
-- Name: interface_neighbor_evidence_active_expiry_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_neighbor_evidence_active_expiry_index ON public.interface_neighbor_evidence_neighbor_storage USING btree (expires_at, organization_id) WHERE (stale_at IS NULL);


--
-- Name: interface_neighbor_evidence_active_local_source_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_neighbor_evidence_active_local_source_index ON public.interface_neighbor_evidence_neighbor_storage USING btree (organization_id, local_interface_id, source_id, observed_at) WHERE (stale_at IS NULL);


--
-- Name: interface_neighbor_evidence_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_neighbor_evidence_id_organization_id_index ON public.interface_neighbor_evidence_neighbor_storage USING btree (id, organization_id);


--
-- Name: interface_neighbor_evidence_identity_order_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_neighbor_evidence_identity_order_index ON public.interface_neighbor_evidence_neighbor_storage USING btree (organization_id, local_interface_id, source_id, protocol, remote_chassis_id_kind, remote_chassis_id_normalized, remote_port_id_kind, remote_port_id_normalized, observed_at DESC, observation_id DESC);


--
-- Name: interface_neighbor_evidence_observation_endpoint_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_neighbor_evidence_observation_endpoint_index ON public.interface_neighbor_evidence_neighbor_storage USING btree (organization_id, observation_id, local_interface_id, protocol, remote_chassis_id_kind, remote_chassis_id_normalized, remote_port_id_kind, remote_port_id_normalized) NULLS NOT DISTINCT;


--
-- Name: interface_neighbor_matches_evidence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_neighbor_matches_evidence_index ON public.interface_neighbor_matches_neighbor_storage USING btree (organization_id, interface_neighbor_evidence_id);


--
-- Name: interface_relationship_evidence_active_relationship_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_relationship_evidence_active_relationship_index ON public.interface_relationship_evidence USING btree (organization_id, interface_relationship_id, source_id, observed_at) WHERE (stale_at IS NULL);


--
-- Name: interface_relationship_evidence_observation_link_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_relationship_evidence_observation_link_index ON public.interface_relationship_evidence USING btree (organization_id, observation_id, interface_relationship_id);


--
-- Name: interface_relationship_evidence_source_link_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_relationship_evidence_source_link_index ON public.interface_relationship_evidence USING btree (organization_id, source_id, interface_relationship_id);


--
-- Name: interface_relationships_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_relationships_id_organization_id_index ON public.interface_relationships USING btree (id, organization_id);


--
-- Name: interface_relationships_org_source_interface_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_relationships_org_source_interface_index ON public.interface_relationships USING btree (organization_id, source_interface_id);


--
-- Name: interface_relationships_org_target_interface_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_relationships_org_target_interface_index ON public.interface_relationships USING btree (organization_id, target_interface_id);


--
-- Name: interface_relationships_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_relationships_organization_id_kind_index ON public.interface_relationships USING btree (organization_id, kind);


--
-- Name: interface_relationships_source_target_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_relationships_source_target_kind_index ON public.interface_relationships USING btree (organization_id, source_interface_id, target_interface_id, kind);


--
-- Name: interface_routing_domain_evidence_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_routing_domain_evidence_active_index ON public.interface_routing_domain_evidence USING btree (organization_id, interface_id) WHERE (stale_at IS NULL);


--
-- Name: interface_routing_domain_evidence_observation_link_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_routing_domain_evidence_observation_link_index ON public.interface_routing_domain_evidence USING btree (organization_id, observation_id, interface_id);


--
-- Name: interface_routing_domains_organization_id_resolution_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_routing_domains_organization_id_resolution_index ON public.interface_routing_domains USING btree (organization_id, resolution);


--
-- Name: interface_vlan_evidence_active_interface_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_vlan_evidence_active_interface_index ON public.interface_vlan_evidence USING btree (organization_id, interface_id) WHERE (stale_at IS NULL);


--
-- Name: interface_vlan_evidence_active_source_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_vlan_evidence_active_source_key_index ON public.interface_vlan_evidence USING btree (organization_id, source_id, interface_id, source_local_key, observed_at) WHERE (stale_at IS NULL);


--
-- Name: interface_vlan_evidence_active_vlan_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_vlan_evidence_active_vlan_index ON public.interface_vlan_evidence USING btree (organization_id, vlan_id) WHERE ((stale_at IS NULL) AND (vlan_id IS NOT NULL));


--
-- Name: interface_vlan_evidence_membership_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_vlan_evidence_membership_identity_index ON public.interface_vlan_evidence USING btree (id, organization_id, interface_id, vlan_id);


--
-- Name: interface_vlan_evidence_observation_link_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_vlan_evidence_observation_link_index ON public.interface_vlan_evidence USING btree (organization_id, observation_id, interface_id, source_local_key);


--
-- Name: interface_vlan_evidence_source_interface_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_vlan_evidence_source_interface_index ON public.interface_vlan_evidence USING btree (organization_id, source_id, interface_id);


--
-- Name: interface_vlan_mode_evidence_observation_link_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_vlan_mode_evidence_observation_link_index ON public.interface_vlan_mode_evidence USING btree (organization_id, observation_id, interface_id);


--
-- Name: interface_vlan_mode_evidence_projection_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interface_vlan_mode_evidence_projection_identity_index ON public.interface_vlan_mode_evidence USING btree (id, organization_id, interface_id);


--
-- Name: interface_vlan_mode_evidence_source_interface_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interface_vlan_mode_evidence_source_interface_index ON public.interface_vlan_mode_evidence USING btree (organization_id, interface_id, source_id, observed_at DESC, observation_id DESC);


--
-- Name: interfaces_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interfaces_id_organization_id_index ON public.interfaces USING btree (id, organization_id);


--
-- Name: interfaces_id_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interfaces_id_organization_id_resource_id_index ON public.interfaces USING btree (id, organization_id, resource_id);


--
-- Name: interfaces_organization_id_mac_address_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interfaces_organization_id_mac_address_index ON public.interfaces USING btree (organization_id, mac_address);


--
-- Name: interfaces_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interfaces_organization_id_resource_id_index ON public.interfaces USING btree (organization_id, resource_id);


--
-- Name: interfaces_organization_id_resource_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX interfaces_organization_id_resource_id_name_index ON public.interfaces USING btree (organization_id, resource_id, name);


--
-- Name: inventory_items_id_organization_id_owner_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX inventory_items_id_organization_id_owner_resource_id_index ON public.inventory_items USING btree (id, organization_id, owner_resource_id);


--
-- Name: inventory_items_organization_id_serial_number_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX inventory_items_organization_id_serial_number_index ON public.inventory_items USING btree (organization_id, serial_number);


--
-- Name: inventory_items_owner_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX inventory_items_owner_name_index ON public.inventory_items USING btree (organization_id, owner_resource_id, lower((name)::text));


--
-- Name: inventory_items_owner_parent_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX inventory_items_owner_parent_index ON public.inventory_items USING btree (organization_id, owner_resource_id, parent_id);


--
-- Name: inventory_items_promoted_module_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX inventory_items_promoted_module_index ON public.inventory_items USING btree (organization_id, promoted_module_id) WHERE (promoted_module_id IS NOT NULL);


--
-- Name: ip_address_assignments_address_interface_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ip_address_assignments_address_interface_index ON public.ip_address_assignments USING btree (ip_address_id, interface_id);


--
-- Name: ip_address_assignments_organization_id_interface_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ip_address_assignments_organization_id_interface_id_index ON public.ip_address_assignments USING btree (organization_id, interface_id);


--
-- Name: ip_addresses_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ip_addresses_id_organization_id_index ON public.ip_addresses USING btree (id, organization_id);


--
-- Name: ip_addresses_namespace_host_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ip_addresses_namespace_host_index ON public.ip_addresses USING btree (organization_id, vrf_id, ((host(address))::inet)) NULLS NOT DISTINCT;


--
-- Name: ip_addresses_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ip_addresses_organization_id_resource_id_index ON public.ip_addresses USING btree (organization_id, resource_id);


--
-- Name: job_events_job_id_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX job_events_job_id_sequence_index ON public.job_events USING btree (job_id, sequence);


--
-- Name: job_events_organization_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_events_organization_id_inserted_at_index ON public.job_events USING btree (organization_id, inserted_at);


--
-- Name: job_events_report_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX job_events_report_sequence_index ON public.job_events USING btree (job_id, attempt, report_sequence) WHERE (report_sequence IS NOT NULL);


--
-- Name: jobs_active_lease_expiry_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_active_lease_expiry_index ON public.jobs USING btree (lease_expires_at) WHERE ((state)::text = ANY ((ARRAY['leased'::character varying, 'running'::character varying])::text[]));


--
-- Name: jobs_finished_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_finished_index ON public.jobs USING btree (organization_id, finished_at) WHERE (finished_at IS NOT NULL);


--
-- Name: jobs_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX jobs_id_organization_id_index ON public.jobs USING btree (id, organization_id);


--
-- Name: jobs_organization_deadline_sweep; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_organization_deadline_sweep ON public.jobs USING btree (organization_id, not_after) WHERE (((state)::text = 'queued'::text) AND (imported_at IS NULL));


--
-- Name: jobs_organization_id_batch_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_organization_id_batch_id_index ON public.jobs USING btree (organization_id, batch_id) WHERE (batch_id IS NOT NULL);


--
-- Name: jobs_organization_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_organization_id_inserted_at_index ON public.jobs USING btree (organization_id, inserted_at);


--
-- Name: jobs_organization_idempotency_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX jobs_organization_idempotency_key_index ON public.jobs USING btree (organization_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: jobs_organization_lease_sweep; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_organization_lease_sweep ON public.jobs USING btree (organization_id, lease_expires_at) WHERE (((state)::text = ANY ((ARRAY['leased'::character varying, 'running'::character varying])::text[])) AND (imported_at IS NULL));


--
-- Name: jobs_queued_agent_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_queued_agent_index ON public.jobs USING btree (organization_id, agent_id, inserted_at) WHERE ((state)::text = 'queued'::text);


--
-- Name: jobs_queued_deadline_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_queued_deadline_index ON public.jobs USING btree (not_after) WHERE ((state)::text = 'queued'::text);


--
-- Name: jobs_resource_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_resource_index ON public.jobs USING btree (organization_id, resource_id, inserted_at) WHERE (resource_id IS NOT NULL);


--
-- Name: local_sign_in_overrides_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX local_sign_in_overrides_expires_at_index ON public.local_sign_in_overrides USING btree (expires_at);


--
-- Name: locations_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX locations_id_organization_id_index ON public.locations USING btree (id, organization_id);


--
-- Name: locations_id_organization_id_site_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX locations_id_organization_id_site_id_index ON public.locations USING btree (id, organization_id, site_id);


--
-- Name: locations_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX locations_organization_id_resource_id_index ON public.locations USING btree (organization_id, resource_id);


--
-- Name: locations_organization_id_site_id_parent_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX locations_organization_id_site_id_parent_id_index ON public.locations USING btree (organization_id, site_id, parent_id);


--
-- Name: manufacturers_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX manufacturers_id_organization_id_index ON public.manufacturers USING btree (id, organization_id);


--
-- Name: manufacturers_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX manufacturers_organization_id_resource_id_index ON public.manufacturers USING btree (organization_id, resource_id);


--
-- Name: manufacturers_organization_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX manufacturers_organization_id_slug_index ON public.manufacturers USING btree (organization_id, slug);


--
-- Name: module_bay_compatible_types_assignment_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX module_bay_compatible_types_assignment_index ON public.module_bay_compatible_types USING btree (module_bay_id, organization_id, module_type_id);


--
-- Name: module_bay_compatible_types_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX module_bay_compatible_types_type_index ON public.module_bay_compatible_types USING btree (organization_id, module_type_id);


--
-- Name: module_bays_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX module_bays_id_organization_id_index ON public.module_bays USING btree (id, organization_id);


--
-- Name: module_bays_owner_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX module_bays_owner_name_index ON public.module_bays USING btree (organization_id, owner_resource_id, lower((name)::text));


--
-- Name: module_installation_events_bay_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX module_installation_events_bay_sequence_index ON public.module_installation_events USING btree (organization_id, module_bay_id, sequence);


--
-- Name: module_types_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX module_types_id_organization_id_index ON public.module_types USING btree (id, organization_id);


--
-- Name: module_types_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX module_types_organization_id_resource_id_index ON public.module_types USING btree (organization_id, resource_id);


--
-- Name: module_types_organization_manufacturer_model_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX module_types_organization_manufacturer_model_index ON public.module_types USING btree (organization_id, manufacturer_id, lower((model)::text));


--
-- Name: modules_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX modules_id_organization_id_index ON public.modules USING btree (id, organization_id);


--
-- Name: modules_installation_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX modules_installation_index ON public.modules USING btree (id, organization_id, module_type_id);


--
-- Name: modules_organization_id_module_type_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX modules_organization_id_module_type_id_index ON public.modules USING btree (organization_id, module_type_id);


--
-- Name: modules_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX modules_organization_id_resource_id_index ON public.modules USING btree (organization_id, resource_id);


--
-- Name: neighbor_generation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_id ON public.neighbor_generation_rows USING btree (generation_id, kind, (((payload ->> 'id'::text))::uuid));


--
-- Name: neighbor_generation_interface_a_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_interface_a_id ON public.neighbor_generation_rows USING btree (generation_id, kind, (((payload ->> 'interface_a_id'::text))::uuid));


--
-- Name: neighbor_generation_interface_b_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_interface_b_id ON public.neighbor_generation_rows USING btree (generation_id, kind, (((payload ->> 'interface_b_id'::text))::uuid));


--
-- Name: neighbor_generation_interface_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_interface_id ON public.neighbor_generation_rows USING btree (generation_id, kind, (((payload ->> 'interface_id'::text))::uuid));


--
-- Name: neighbor_generation_interface_neighbor_evidence_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_interface_neighbor_evidence_id ON public.neighbor_generation_rows USING btree (generation_id, kind, (((payload ->> 'interface_neighbor_evidence_id'::text))::uuid));


--
-- Name: neighbor_generation_rows_generation_id_kind_endpoint_a_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_rows_generation_id_kind_endpoint_a_index ON public.neighbor_generation_rows USING btree (generation_id, kind, endpoint_a);


--
-- Name: neighbor_generation_rows_generation_id_kind_endpoint_b_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_rows_generation_id_kind_endpoint_b_index ON public.neighbor_generation_rows USING btree (generation_id, kind, endpoint_b);


--
-- Name: neighbor_generation_selection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generation_selection ON public.neighbor_generation_rows USING btree (generation_id, kind, processed, reciprocal, observed_at, observation_id, endpoint_a, endpoint_b);


--
-- Name: neighbor_generations_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX neighbor_generations_organization_id_index ON public.neighbor_generations USING btree (organization_id) WHERE (status = 'building'::text);


--
-- Name: neighbor_generations_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX neighbor_generations_organization_id_status_index ON public.neighbor_generations USING btree (organization_id, status);


--
-- Name: observation_reconciliations_matched_resource_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observation_reconciliations_matched_resource_index ON public.observation_reconciliations USING btree (organization_id, matched_resource_id);


--
-- Name: observation_reconciliations_observation_attempt_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX observation_reconciliations_observation_attempt_index ON public.observation_reconciliations USING btree (organization_id, observation_id, attempt);


--
-- Name: observation_reconciliations_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observation_reconciliations_organization_id_status_index ON public.observation_reconciliations USING btree (organization_id, status);


--
-- Name: observations_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX observations_id_organization_id_index ON public.observations USING btree (id, organization_id);


--
-- Name: observations_id_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX observations_id_organization_id_source_id_index ON public.observations USING btree (id, organization_id, source_id);


--
-- Name: observations_organization_id_intake_api_key_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observations_organization_id_intake_api_key_id_index ON public.observations USING btree (organization_id, intake_api_key_id);


--
-- Name: observations_organization_id_observed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observations_organization_id_observed_at_index ON public.observations USING btree (organization_id, observed_at);


--
-- Name: observations_organization_id_source_id_idempotency_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX observations_organization_id_source_id_idempotency_key_index ON public.observations USING btree (organization_id, source_id, idempotency_key);


--
-- Name: observations_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observations_organization_id_source_id_index ON public.observations USING btree (organization_id, source_id);


--
-- Name: observations_organization_id_sync_run_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observations_organization_id_sync_run_id_index ON public.observations USING btree (organization_id, sync_run_id);


--
-- Name: observations_parent_resource_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX observations_parent_resource_index ON public.observations USING btree (parent_observation_id, resource_index) WHERE (parent_observation_id IS NOT NULL);


--
-- Name: operator_idempotency_keys_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operator_idempotency_keys_expires_at_index ON public.operator_idempotency_keys USING btree (expires_at);


--
-- Name: operator_idempotency_keys_namespace_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operator_idempotency_keys_namespace_index ON public.operator_idempotency_keys USING btree (operator_token_id, method, route, key);


--
-- Name: operator_invitation_deliveries_available_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operator_invitation_deliveries_available_index ON public.operator_invitation_deliveries USING btree (available_at, lease_expires_at);


--
-- Name: operator_invitation_deliveries_invitation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operator_invitation_deliveries_invitation_id_index ON public.operator_invitation_deliveries USING btree (invitation_id);


--
-- Name: operator_tokens_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operator_tokens_name_index ON public.operator_tokens USING btree (name);


--
-- Name: operator_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operator_tokens_token_hash_index ON public.operator_tokens USING btree (token_hash);


--
-- Name: organization_domains_one_verified_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_domains_one_verified_index ON public.organization_domains USING btree (domain) WHERE (verified_at IS NOT NULL);


--
-- Name: organization_domains_organization_id_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_domains_organization_id_domain_index ON public.organization_domains USING btree (organization_id, domain);


--
-- Name: organization_exports_generation_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_exports_generation_queue ON public.organization_exports USING btree (organization_id, processing_deadline) WHERE ((status)::text = 'running'::text);


--
-- Name: organization_exports_one_running; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_exports_one_running ON public.organization_exports USING btree (organization_id) WHERE ((status)::text = 'running'::text);


--
-- Name: organization_exports_organization_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_exports_organization_id_inserted_at_index ON public.organization_exports USING btree (organization_id, inserted_at);


--
-- Name: organization_exports_status_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_exports_status_expires_at_index ON public.organization_exports USING btree (status, expires_at);


--
-- Name: organization_imports_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_imports_organization_id_index ON public.organization_imports USING btree (organization_id);


--
-- Name: organization_invitations_imported_principal_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_invitations_imported_principal_id_index ON public.organization_invitations USING btree (imported_principal_id);


--
-- Name: organization_invitations_open_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_invitations_open_email_index ON public.organization_invitations USING btree (organization_id, email) WHERE ((accepted_at IS NULL) AND (revoked_at IS NULL));


--
-- Name: organization_invitations_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_invitations_token_hash_index ON public.organization_invitations USING btree (token_hash);


--
-- Name: organization_limits_organization_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_limits_organization_id_name_index ON public.organization_limits USING btree (organization_id, name);


--
-- Name: organization_memberships_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_memberships_id_organization_id_index ON public.organization_memberships USING btree (id, organization_id);


--
-- Name: organization_memberships_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_organization_id_status_index ON public.organization_memberships USING btree (organization_id, status);


--
-- Name: organization_memberships_organization_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_memberships_organization_id_user_id_index ON public.organization_memberships USING btree (organization_id, user_id);


--
-- Name: organization_memberships_scim_connection_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_scim_connection_id_index ON public.organization_memberships USING btree (scim_connection_id) WHERE (scim_connection_id IS NOT NULL);


--
-- Name: organization_memberships_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_user_id_index ON public.organization_memberships USING btree (user_id);


--
-- Name: organization_security_settings_changed_by_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_security_settings_changed_by_user_id_index ON public.organization_security_settings USING btree (changed_by_user_id);


--
-- Name: organization_security_settings_organization_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_security_settings_organization_id_name_index ON public.organization_security_settings USING btree (organization_id, name);


--
-- Name: organizations_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organizations_slug_index ON public.organizations USING btree (slug);


--
-- Name: organizations_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organizations_status_index ON public.organizations USING btree (status);


--
-- Name: organizations_status_lock_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organizations_status_lock_key ON public.organizations USING btree (id, status);


--
-- Name: placement_evidence_organization_id_resource_id_observed_at_inde; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX placement_evidence_organization_id_resource_id_observed_at_inde ON public.placement_evidence USING btree (organization_id, resource_id, observed_at);


--
-- Name: placement_evidence_organization_id_source_id_observation_id_ind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX placement_evidence_organization_id_source_id_observation_id_ind ON public.placement_evidence USING btree (organization_id, source_id, observation_id);


--
-- Name: placement_findings_open_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX placement_findings_open_kind_index ON public.placement_findings USING btree (organization_id, resource_id, kind) WHERE ((status)::text = 'open'::text);


--
-- Name: placement_findings_organization_id_status_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX placement_findings_organization_id_status_kind_index ON public.placement_findings USING btree (organization_id, status, kind);


--
-- Name: power_correlation_samples_organization_id_source_id_target_minu; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX power_correlation_samples_organization_id_source_id_target_minu ON public.power_correlation_samples USING btree (organization_id, source_id, target, minute);


--
-- Name: power_correlation_samples_series_minute_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_correlation_samples_series_minute_index ON public.power_correlation_samples USING btree (source_id, target, sensor, boundary, quantity, minute) NULLS NOT DISTINCT;


--
-- Name: power_feeds_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_feeds_id_organization_id_index ON public.power_feeds USING btree (id, organization_id);


--
-- Name: power_feeds_organization_id_panel_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_feeds_organization_id_panel_id_name_index ON public.power_feeds USING btree (organization_id, panel_id, name);


--
-- Name: power_feeds_organization_id_rack_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX power_feeds_organization_id_rack_id_index ON public.power_feeds USING btree (organization_id, rack_id) WHERE (rack_id IS NOT NULL);


--
-- Name: power_feeds_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_feeds_organization_id_resource_id_index ON public.power_feeds USING btree (organization_id, resource_id);


--
-- Name: power_findings_open_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_findings_open_index ON public.power_findings USING btree (organization_id, resource_id, kind, resolution_key) WHERE ((status)::text = 'open'::text);


--
-- Name: power_findings_organization_id_status_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX power_findings_organization_id_status_kind_index ON public.power_findings USING btree (organization_id, status, kind);


--
-- Name: power_outlets_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_outlets_id_organization_id_index ON public.power_outlets USING btree (id, organization_id);


--
-- Name: power_outlets_organization_id_resource_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_outlets_organization_id_resource_id_name_index ON public.power_outlets USING btree (organization_id, resource_id, name);


--
-- Name: power_panels_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_panels_id_organization_id_index ON public.power_panels USING btree (id, organization_id);


--
-- Name: power_panels_id_organization_id_site_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_panels_id_organization_id_site_id_index ON public.power_panels USING btree (id, organization_id, site_id);


--
-- Name: power_panels_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_panels_organization_id_resource_id_index ON public.power_panels USING btree (organization_id, resource_id);


--
-- Name: power_panels_organization_id_site_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_panels_organization_id_site_id_name_index ON public.power_panels USING btree (organization_id, site_id, name);


--
-- Name: power_ports_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_ports_id_organization_id_index ON public.power_ports USING btree (id, organization_id);


--
-- Name: power_ports_id_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_ports_id_organization_id_resource_id_index ON public.power_ports USING btree (id, organization_id, resource_id);


--
-- Name: power_ports_organization_id_resource_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_ports_organization_id_resource_id_name_index ON public.power_ports USING btree (organization_id, resource_id, name);


--
-- Name: power_readings_organization_id_source_id_target_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX power_readings_organization_id_source_id_target_index ON public.power_readings USING btree (organization_id, source_id, target);


--
-- Name: power_readings_series_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX power_readings_series_index ON public.power_readings USING btree (source_id, target, sensor, boundary, quantity, window_ms) NULLS NOT DISTINCT;


--
-- Name: prefix_vlan_relationships_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX prefix_vlan_relationships_id_organization_id_index ON public.prefix_vlan_relationships USING btree (id, organization_id);


--
-- Name: prefix_vlan_relationships_prefix_vlan_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX prefix_vlan_relationships_prefix_vlan_index ON public.prefix_vlan_relationships USING btree (organization_id, prefix_id, vlan_id);


--
-- Name: prefix_vlan_relationships_vlan_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX prefix_vlan_relationships_vlan_index ON public.prefix_vlan_relationships USING btree (organization_id, vlan_id);


--
-- Name: prefixes_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX prefixes_id_organization_id_index ON public.prefixes USING btree (id, organization_id);


--
-- Name: prefixes_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX prefixes_organization_id_resource_id_index ON public.prefixes USING btree (organization_id, resource_id);


--
-- Name: prefixes_organization_vrf_prefix_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX prefixes_organization_vrf_prefix_index ON public.prefixes USING btree (organization_id, vrf_id, prefix) NULLS NOT DISTINCT;


--
-- Name: prefixes_prefix_gist_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX prefixes_prefix_gist_index ON public.prefixes USING gist (prefix inet_ops);


--
-- Name: rack_occupancies_current_placement_id_face_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rack_occupancies_current_placement_id_face_index ON public.rack_occupancies USING btree (current_placement_id, face);


--
-- Name: rack_occupancies_organization_id_rack_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rack_occupancies_organization_id_rack_id_index ON public.rack_occupancies USING btree (organization_id, rack_id);


--
-- Name: racks_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX racks_id_organization_id_index ON public.racks USING btree (id, organization_id);


--
-- Name: racks_id_organization_id_site_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX racks_id_organization_id_site_id_index ON public.racks USING btree (id, organization_id, site_id);


--
-- Name: racks_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX racks_organization_id_resource_id_index ON public.racks USING btree (organization_id, resource_id);


--
-- Name: racks_organization_id_site_id_location_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX racks_organization_id_site_id_location_id_index ON public.racks USING btree (organization_id, site_id, location_id);


--
-- Name: reconciliation_lanes_last_turn_at_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reconciliation_lanes_last_turn_at_organization_id_index ON public.reconciliation_lanes USING btree (last_turn_at, organization_id);


--
-- Name: reconciliation_lanes_work_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reconciliation_lanes_work_id_organization_id_index ON public.reconciliation_lanes USING btree (work_id, organization_id);


--
-- Name: reconciliation_work_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX reconciliation_work_id_organization_id_index ON public.reconciliation_work USING btree (id, organization_id);


--
-- Name: reconciliation_work_observation_id_organization_id_source_id_in; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reconciliation_work_observation_id_organization_id_source_id_in ON public.reconciliation_work USING btree (observation_id, organization_id, source_id);


--
-- Name: reconciliation_work_organization_id_observation_id_position_ind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reconciliation_work_organization_id_observation_id_position_ind ON public.reconciliation_work USING btree (organization_id, observation_id, "position");


--
-- Name: reconciliation_work_organization_id_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX reconciliation_work_organization_id_position_index ON public.reconciliation_work USING btree (organization_id, "position");


--
-- Name: reconciliation_work_outstanding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reconciliation_work_outstanding ON public.reconciliation_work USING btree (organization_id, "position") WHERE ((status)::text <> 'succeeded'::text);


--
-- Name: resource_conditions_organization_id_resource_id_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_conditions_organization_id_resource_id_type_index ON public.resource_conditions USING btree (organization_id, resource_id, type);


--
-- Name: resource_conditions_organization_id_type_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_conditions_organization_id_type_status_index ON public.resource_conditions USING btree (organization_id, type, status);


--
-- Name: resource_group_members_group_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_group_members_group_id_resource_id_index ON public.resource_group_members USING btree (group_id, resource_id);


--
-- Name: resource_group_members_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_group_members_organization_id_resource_id_index ON public.resource_group_members USING btree (organization_id, resource_id);


--
-- Name: resource_group_memberships_exclusive_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_group_memberships_exclusive_index ON public.resource_group_memberships USING btree (organization_id, resource_id, view, group_set_id) WHERE (group_set_id IS NOT NULL);


--
-- Name: resource_group_memberships_group_id_view_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_group_memberships_group_id_view_index ON public.resource_group_memberships USING btree (group_id, view);


--
-- Name: resource_group_sets_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_group_sets_id_organization_id_index ON public.resource_group_sets USING btree (id, organization_id);


--
-- Name: resource_group_sets_organization_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_group_sets_organization_name_index ON public.resource_group_sets USING btree (organization_id, lower((name)::text));


--
-- Name: resource_group_suggestion_dismissals_organization_id_rule_id_in; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_group_suggestion_dismissals_organization_id_rule_id_in ON public.resource_group_suggestion_dismissals USING btree (organization_id, rule_id);


--
-- Name: resource_group_suggestion_dismissals_suggestion_id_rule_id_inde; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_group_suggestion_dismissals_suggestion_id_rule_id_inde ON public.resource_group_suggestion_dismissals USING btree (suggestion_id, rule_id);


--
-- Name: resource_group_suggestions_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_group_suggestions_id_organization_id_index ON public.resource_group_suggestions USING btree (id, organization_id);


--
-- Name: resource_group_suggestions_organization_id_resource_id_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_group_suggestions_organization_id_resource_id_group_id ON public.resource_group_suggestions USING btree (organization_id, resource_id, group_id);


--
-- Name: resource_group_suggestions_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_group_suggestions_organization_id_status_index ON public.resource_group_suggestions USING btree (organization_id, status);


--
-- Name: resource_groups_group_set_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_groups_group_set_id_index ON public.resource_groups USING btree (group_set_id);


--
-- Name: resource_groups_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_groups_id_organization_id_index ON public.resource_groups USING btree (id, organization_id);


--
-- Name: resource_groups_organization_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_groups_organization_name_index ON public.resource_groups USING btree (organization_id, lower((name)::text));


--
-- Name: resource_identifier_claims_canonical_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifier_claims_canonical_index ON public.resource_identifier_claims USING btree (organization_id, resource_identifier_id);


--
-- Name: resource_identifier_claims_normalized_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifier_claims_normalized_value_index ON public.resource_identifier_claims USING btree (organization_id, kind, normalized_value);


--
-- Name: resource_identifier_claims_observation_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_identifier_claims_observation_value_index ON public.resource_identifier_claims USING btree (organization_id, observation_id, kind, normalized_value);


--
-- Name: resource_identifier_claims_organization_id_observation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifier_claims_organization_id_observation_id_index ON public.resource_identifier_claims USING btree (organization_id, observation_id);


--
-- Name: resource_identifier_claims_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifier_claims_organization_id_resource_id_index ON public.resource_identifier_claims USING btree (organization_id, resource_id);


--
-- Name: resource_identifier_claims_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifier_claims_organization_id_source_id_index ON public.resource_identifier_claims USING btree (organization_id, source_id);


--
-- Name: resource_identifiers_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_identifiers_id_organization_id_index ON public.resource_identifiers USING btree (id, organization_id);


--
-- Name: resource_identifiers_id_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_identifiers_id_organization_id_resource_id_index ON public.resource_identifiers USING btree (id, organization_id, resource_id);


--
-- Name: resource_identifiers_normalized_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifiers_normalized_value_index ON public.resource_identifiers USING btree (organization_id, kind, normalized_value);


--
-- Name: resource_identifiers_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifiers_organization_id_resource_id_index ON public.resource_identifiers USING btree (organization_id, resource_id);


--
-- Name: resource_identifiers_resource_kind_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_identifiers_resource_kind_value_index ON public.resource_identifiers USING btree (organization_id, resource_id, kind, normalized_value);


--
-- Name: resource_overrides_organization_id_created_by_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_overrides_organization_id_created_by_user_id_index ON public.resource_overrides USING btree (organization_id, created_by_user_id);


--
-- Name: resource_overrides_organization_id_resource_id_field_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_overrides_organization_id_resource_id_field_index ON public.resource_overrides USING btree (organization_id, resource_id, field);


--
-- Name: resource_overrides_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_overrides_organization_id_resource_id_index ON public.resource_overrides USING btree (organization_id, resource_id);


--
-- Name: resource_owners_child_controller_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_owners_child_controller_index ON public.resource_owners USING btree (organization_id, child_resource_id) WHERE (controller = true);


--
-- Name: resource_owners_owner_child_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_owners_owner_child_kind_index ON public.resource_owners USING btree (organization_id, owner_resource_id, child_resource_id, kind);


--
-- Name: resource_relationships_organization_id_target_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_relationships_organization_id_target_resource_id_index ON public.resource_relationships USING btree (organization_id, target_resource_id);


--
-- Name: resource_relationships_source_target_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_relationships_source_target_kind_index ON public.resource_relationships USING btree (organization_id, source_resource_id, target_resource_id, kind);


--
-- Name: resource_revisions_organization_id_resource_id_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_revisions_organization_id_resource_id_revision_index ON public.resource_revisions USING btree (organization_id, resource_id, revision);


--
-- Name: resource_revisions_organization_id_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_revisions_organization_id_revision_index ON public.resource_revisions USING btree (organization_id, revision);


--
-- Name: resource_revisions_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_revisions_revision_index ON public.resource_revisions USING btree (revision);


--
-- Name: resources_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resources_id_organization_id_index ON public.resources USING btree (id, organization_id);


--
-- Name: resources_labels_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_labels_index ON public.resources USING gin (labels);


--
-- Name: resources_module_owner_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resources_module_owner_index ON public.resources USING btree (id, organization_id, kind);


--
-- Name: resources_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_kind_index ON public.resources USING btree (organization_id, kind);


--
-- Name: resources_organization_id_kind_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resources_organization_id_kind_name_index ON public.resources USING btree (organization_id, kind, name);


--
-- Name: resources_organization_id_lifecycle_state_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_lifecycle_state_index ON public.resources USING btree (organization_id, lifecycle_state);


--
-- Name: resources_organization_id_owner_team_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_owner_team_id_index ON public.resources USING btree (organization_id, owner_team_id);


--
-- Name: resources_organization_id_resource_version_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_resource_version_index ON public.resources USING btree (organization_id, resource_version);


--
-- Name: role_assignments_organization_id_membership_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX role_assignments_organization_id_membership_id_index ON public.role_assignments USING btree (organization_id, membership_id);


--
-- Name: role_assignments_role_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX role_assignments_role_id_index ON public.role_assignments USING btree (role_id);


--
-- Name: role_assignments_valid_until_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX role_assignments_valid_until_index ON public.role_assignments USING btree (valid_until) WHERE ((valid_until IS NOT NULL) AND (expired_at IS NULL));


--
-- Name: roles_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX roles_id_organization_id_index ON public.roles USING btree (id, organization_id);


--
-- Name: roles_organization_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX roles_organization_name_index ON public.roles USING btree (organization_id, lower((name)::text));


--
-- Name: saved_views_organization_id_area_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX saved_views_organization_id_area_index ON public.saved_views USING btree (organization_id, area);


--
-- Name: saved_views_organization_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX saved_views_organization_id_user_id_index ON public.saved_views USING btree (organization_id, user_id);


--
-- Name: saved_views_organization_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX saved_views_organization_name_index ON public.saved_views USING btree (organization_id, area, lower((name)::text)) WHERE (user_id IS NULL);


--
-- Name: saved_views_personal_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX saved_views_personal_name_index ON public.saved_views USING btree (organization_id, user_id, area, lower((name)::text)) WHERE (user_id IS NOT NULL);


--
-- Name: scim_connections_one_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_connections_one_enabled ON public.scim_connections USING btree (organization_id) WHERE (disabled_at IS NULL);


--
-- Name: scim_connections_organization_id_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_connections_organization_id_id_index ON public.scim_connections USING btree (organization_id, id);


--
-- Name: scim_connections_provider_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scim_connections_provider_id_index ON public.scim_connections USING btree (provider_id);


--
-- Name: scim_group_members_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scim_group_members_user_id_index ON public.scim_group_members USING btree (user_id);


--
-- Name: scim_groups_connection_id_display_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_groups_connection_id_display_name_index ON public.scim_groups USING btree (connection_id, lower((display_name)::text));


--
-- Name: scim_groups_connection_id_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_groups_connection_id_id_index ON public.scim_groups USING btree (connection_id, id);


--
-- Name: scim_tokens_connection_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scim_tokens_connection_id_index ON public.scim_tokens USING btree (connection_id) WHERE (revoked_at IS NULL);


--
-- Name: scim_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_tokens_token_hash_index ON public.scim_tokens USING btree (token_hash);


--
-- Name: scim_users_connection_id_external_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_users_connection_id_external_id_index ON public.scim_users USING btree (connection_id, external_id) WHERE (external_id IS NOT NULL);


--
-- Name: scim_users_connection_id_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_users_connection_id_id_index ON public.scim_users USING btree (connection_id, id);


--
-- Name: scim_users_connection_id_user_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_users_connection_id_user_name_index ON public.scim_users USING btree (connection_id, user_name);


--
-- Name: scim_users_organization_id_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scim_users_organization_id_id_index ON public.scim_users USING btree (organization_id, id);


--
-- Name: scim_users_user_identity_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scim_users_user_identity_id_index ON public.scim_users USING btree (user_identity_id);


--
-- Name: site_groups_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX site_groups_id_organization_id_index ON public.site_groups USING btree (id, organization_id);


--
-- Name: site_groups_organization_id_parent_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX site_groups_organization_id_parent_id_index ON public.site_groups USING btree (organization_id, parent_id);


--
-- Name: site_groups_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX site_groups_organization_id_resource_id_index ON public.site_groups USING btree (organization_id, resource_id);


--
-- Name: sites_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sites_id_organization_id_index ON public.sites USING btree (id, organization_id);


--
-- Name: sites_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sites_organization_id_resource_id_index ON public.sites USING btree (organization_id, resource_id);


--
-- Name: sites_organization_id_site_group_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sites_organization_id_site_group_id_index ON public.sites USING btree (organization_id, site_group_id);


--
-- Name: sites_organization_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sites_organization_id_slug_index ON public.sites USING btree (organization_id, slug);


--
-- Name: source_routing_domain_mappings_source_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_routing_domain_mappings_source_key_index ON public.source_routing_domain_mappings USING btree (organization_id, source_id, lower((source_local_key)::text));


--
-- Name: source_vlan_group_mappings_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_vlan_group_mappings_id_organization_id_index ON public.source_vlan_group_mappings USING btree (id, organization_id);


--
-- Name: source_vlan_group_mappings_source_scope_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_vlan_group_mappings_source_scope_index ON public.source_vlan_group_mappings USING btree (organization_id, source_id, source_local_scope);


--
-- Name: sources_agent_collector_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sources_agent_collector_index ON public.sources USING btree (organization_id, agent_id, collector_id) WHERE (collector_id IS NOT NULL);


--
-- Name: sources_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sources_id_organization_id_index ON public.sources USING btree (id, organization_id);


--
-- Name: sources_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sources_organization_id_kind_index ON public.sources USING btree (organization_id, kind);


--
-- Name: sources_organization_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sources_organization_id_name_index ON public.sources USING btree (organization_id, name);


--
-- Name: sources_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sources_organization_id_status_index ON public.sources USING btree (organization_id, status);


--
-- Name: sync_runs_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sync_runs_id_organization_id_index ON public.sync_runs USING btree (id, organization_id);


--
-- Name: sync_runs_id_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sync_runs_id_organization_id_source_id_index ON public.sync_runs USING btree (id, organization_id, source_id);


--
-- Name: sync_runs_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sync_runs_organization_id_source_id_index ON public.sync_runs USING btree (organization_id, source_id);


--
-- Name: sync_runs_organization_id_started_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sync_runs_organization_id_started_at_index ON public.sync_runs USING btree (organization_id, started_at);


--
-- Name: sync_runs_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sync_runs_organization_id_status_index ON public.sync_runs USING btree (organization_id, status);


--
-- Name: target_bindings_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX target_bindings_active_index ON public.target_bindings USING btree (organization_id, resource_id) WHERE ((status)::text = 'active'::text);


--
-- Name: target_bindings_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX target_bindings_id_organization_id_index ON public.target_bindings USING btree (id, organization_id);


--
-- Name: target_bindings_organization_id_agent_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX target_bindings_organization_id_agent_id_index ON public.target_bindings USING btree (organization_id, agent_id);


--
-- Name: target_bindings_organization_id_installation_key_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX target_bindings_organization_id_installation_key_id_index ON public.target_bindings USING btree (organization_id, installation_key_id);


--
-- Name: target_bindings_organization_id_resource_id_version_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX target_bindings_organization_id_resource_id_version_index ON public.target_bindings USING btree (organization_id, resource_id, version);


--
-- Name: team_memberships_organization_id_membership_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX team_memberships_organization_id_membership_id_index ON public.team_memberships USING btree (organization_id, membership_id);


--
-- Name: team_memberships_team_id_membership_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX team_memberships_team_id_membership_id_index ON public.team_memberships USING btree (team_id, membership_id);


--
-- Name: teams_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX teams_id_organization_id_index ON public.teams USING btree (id, organization_id);


--
-- Name: teams_organization_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX teams_organization_name_index ON public.teams USING btree (organization_id, lower((name)::text));


--
-- Name: telemetry_batches_organization_id_received_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telemetry_batches_organization_id_received_at_index ON public.telemetry_batches USING btree (organization_id, received_at);


--
-- Name: telemetry_batches_received_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telemetry_batches_received_at_index ON public.telemetry_batches USING btree (received_at);


--
-- Name: telemetry_batches_source_id_replay_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX telemetry_batches_source_id_replay_id_index ON public.telemetry_batches USING btree (source_id, replay_id);


--
-- Name: telemetry_buckets_bucket_start_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telemetry_buckets_bucket_start_index ON public.telemetry_buckets USING btree (bucket_start);


--
-- Name: telemetry_buckets_organization_id_bucket_start_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telemetry_buckets_organization_id_bucket_start_index ON public.telemetry_buckets USING btree (organization_id, bucket_start);


--
-- Name: topology_findings_interface_history_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX topology_findings_interface_history_index ON public.topology_findings_neighbor_storage USING btree (organization_id, interface_id, GREATEST(last_observed_at, COALESCE(resolved_at, last_observed_at)) DESC);


--
-- Name: topology_findings_open_resolution_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX topology_findings_open_resolution_index ON public.topology_findings_neighbor_storage USING btree (organization_id, interface_id, kind, resolution_key) WHERE ((status)::text = 'open'::text);


--
-- Name: topology_findings_organization_id_status_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX topology_findings_organization_id_status_kind_index ON public.topology_findings_neighbor_storage USING btree (organization_id, status, kind);


--
-- Name: topology_snapshot_events_observation_section_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX topology_snapshot_events_observation_section_index ON public.topology_snapshot_events USING btree (organization_id, observation_id, resource_id, section);


--
-- Name: topology_snapshot_events_source_resource_section_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX topology_snapshot_events_source_resource_section_index ON public.topology_snapshot_events USING btree (organization_id, resource_id, section, source_id, observed_at DESC, observation_id DESC);


--
-- Name: triage_rules_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX triage_rules_id_organization_id_index ON public.triage_rules USING btree (id, organization_id);


--
-- Name: triage_rules_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX triage_rules_organization_id_kind_index ON public.triage_rules USING btree (organization_id, kind);


--
-- Name: triage_rules_organization_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX triage_rules_organization_name_index ON public.triage_rules USING btree (organization_id, lower((name)::text));


--
-- Name: user_identities_provider_id_subject_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_identities_provider_id_subject_index ON public.user_identities USING btree (provider_id, subject);


--
-- Name: user_identities_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_identities_user_id_index ON public.user_identities USING btree (user_id);


--
-- Name: user_passkeys_credential_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_passkeys_credential_id_index ON public.user_passkeys USING btree (credential_id);


--
-- Name: user_passkeys_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_passkeys_user_id_index ON public.user_passkeys USING btree (user_id);


--
-- Name: user_recovery_codes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_recovery_codes_user_id_index ON public.user_recovery_codes USING btree (user_id);


--
-- Name: user_totps_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_totps_user_id_index ON public.user_totps USING btree (user_id);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_tokens_browser_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_tokens_browser_session_id_index ON public.users_tokens USING btree (browser_session_id);


--
-- Name: users_tokens_context_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_tokens_context_token_index ON public.users_tokens USING btree (context, token);


--
-- Name: users_tokens_scoped_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_tokens_scoped_organization_id_index ON public.users_tokens USING btree (scoped_organization_id) WHERE (scoped_organization_id IS NOT NULL);


--
-- Name: users_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_tokens_user_id_index ON public.users_tokens USING btree (user_id);


--
-- Name: vlan_group_vid_ranges_organization_id_vlan_group_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vlan_group_vid_ranges_organization_id_vlan_group_id_index ON public.vlan_group_vid_ranges USING btree (organization_id, vlan_group_id);


--
-- Name: vlan_groups_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vlan_groups_id_organization_id_index ON public.vlan_groups USING btree (id, organization_id);


--
-- Name: vlan_groups_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vlan_groups_organization_id_resource_id_index ON public.vlan_groups USING btree (organization_id, resource_id);


--
-- Name: vlan_groups_organization_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vlan_groups_organization_id_slug_index ON public.vlan_groups USING btree (organization_id, slug);


--
-- Name: vlan_groups_scope_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vlan_groups_scope_index ON public.vlan_groups USING btree (organization_id, scope_kind, site_id, location_id);


--
-- Name: vlans_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vlans_id_organization_id_index ON public.vlans USING btree (id, organization_id);


--
-- Name: vlans_organization_group_vid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vlans_organization_group_vid_index ON public.vlans USING btree (organization_id, vlan_group_id, vid) NULLS NOT DISTINCT;


--
-- Name: vlans_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vlans_organization_id_resource_id_index ON public.vlans USING btree (organization_id, resource_id);


--
-- Name: vlans_organization_id_vlan_group_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vlans_organization_id_vlan_group_id_index ON public.vlans USING btree (organization_id, vlan_group_id);


--
-- Name: vrfs_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vrfs_id_organization_id_index ON public.vrfs USING btree (id, organization_id);


--
-- Name: vrfs_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vrfs_organization_id_resource_id_index ON public.vrfs USING btree (organization_id, resource_id);


--
-- Name: vrfs_organization_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vrfs_organization_name_index ON public.vrfs USING btree (organization_id, lower((name)::text));


--
-- Name: vrfs_organization_route_distinguisher_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vrfs_organization_route_distinguisher_index ON public.vrfs USING btree (organization_id, route_distinguisher) WHERE (route_distinguisher IS NOT NULL);


--
-- Name: webauthn_challenges_bytes_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX webauthn_challenges_bytes_index ON public.webauthn_challenges USING btree (bytes);


--
-- Name: webauthn_challenges_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webauthn_challenges_expires_at_index ON public.webauthn_challenges USING btree (expires_at);


--
-- Name: cable_assertions cable_assertions_enforce_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cable_assertions_enforce_immutability BEFORE UPDATE ON public.cable_assertions FOR EACH ROW EXECUTE FUNCTION public.enforce_cable_assertion_immutability();


--
-- Name: cable_assertions cable_assertions_enforce_retention; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cable_assertions_enforce_retention BEFORE DELETE ON public.cable_assertions FOR EACH ROW EXECUTE FUNCTION public.enforce_cable_assertion_retention();


--
-- Name: cable_endpoint_terminations cable_endpoint_terminations_enforce_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER cable_endpoint_terminations_enforce_consistency AFTER INSERT OR DELETE OR UPDATE ON public.cable_endpoint_terminations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_cable_endpoint_termination();


--
-- Name: cables cables_enforce_endpoints_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cables_enforce_endpoints_immutable BEFORE UPDATE ON public.cables FOR EACH ROW EXECUTE FUNCTION public.enforce_cable_endpoints_immutable();


--
-- Name: cables cables_enforce_primary_assertion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cables_enforce_primary_assertion BEFORE INSERT OR UPDATE ON public.cables FOR EACH ROW EXECUTE FUNCTION public.enforce_cable_primary_assertion();


--
-- Name: cables cables_occupy_endpoints; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cables_occupy_endpoints AFTER INSERT ON public.cables FOR EACH ROW EXECUTE FUNCTION public.occupy_cable_endpoints();


--
-- Name: catalog_type_revisions catalog_type_revisions_enforce_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER catalog_type_revisions_enforce_immutability BEFORE DELETE OR UPDATE ON public.catalog_type_revisions FOR EACH ROW EXECUTE FUNCTION public.enforce_catalog_type_revision_immutability();


--
-- Name: component_templates component_templates_enforce_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER component_templates_enforce_immutability BEFORE INSERT OR DELETE OR UPDATE ON public.component_templates FOR EACH ROW EXECUTE FUNCTION public.enforce_component_template_immutability();


--
-- Name: current_interface_adjacencies_neighbor_storage current_interface_adjacencies_enforce_endpoints_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER current_interface_adjacencies_enforce_endpoints_immutable BEFORE UPDATE ON public.current_interface_adjacencies_neighbor_storage FOR EACH ROW EXECUTE FUNCTION public.enforce_current_interface_adjacency_endpoints_immutable();


--
-- Name: current_interface_adjacencies_neighbor_storage current_interface_adjacencies_occupy_endpoints; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER current_interface_adjacencies_occupy_endpoints AFTER INSERT ON public.current_interface_adjacencies_neighbor_storage FOR EACH ROW EXECUTE FUNCTION public.occupy_current_interface_adjacency_endpoints();


--
-- Name: current_interface_adjacency_endpoints current_interface_adjacency_endpoints_enforce_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER current_interface_adjacency_endpoints_enforce_consistency AFTER INSERT OR DELETE OR UPDATE ON public.current_interface_adjacency_endpoints DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_current_interface_adjacency_occupancy();


--
-- Name: interface_neighbor_evidence_neighbor_storage interface_neighbor_evidence_enforce_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER interface_neighbor_evidence_enforce_immutability BEFORE UPDATE ON public.interface_neighbor_evidence_neighbor_storage FOR EACH ROW EXECUTE FUNCTION public.enforce_interface_neighbor_evidence_immutability();


--
-- Name: interface_vlan_evidence interface_vlan_evidence_enforce_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER interface_vlan_evidence_enforce_immutability BEFORE UPDATE ON public.interface_vlan_evidence FOR EACH ROW EXECUTE FUNCTION public.enforce_interface_vlan_evidence_immutability();


--
-- Name: interface_vlan_mode_evidence interface_vlan_mode_evidence_reject_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER interface_vlan_mode_evidence_reject_update BEFORE UPDATE ON public.interface_vlan_mode_evidence FOR EACH ROW EXECUTE FUNCTION public.reject_interface_vlan_mode_evidence_update();


--
-- Name: job_events job_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER job_events_append_only BEFORE DELETE OR UPDATE ON public.job_events FOR EACH ROW EXECUTE FUNCTION public.reject_job_event_change();


--
-- Name: jobs jobs_reject_imported_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER jobs_reject_imported_update BEFORE UPDATE ON public.jobs FOR EACH ROW WHEN ((old.imported_at IS NOT NULL)) EXECUTE FUNCTION public.reject_imported_job_update();


--
-- Name: cable_assertions neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.cable_assertions FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: cable_plans neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.cable_plans FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: cables neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.cables FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: current_interface_adjacencies_neighbor_storage neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.current_interface_adjacencies_neighbor_storage FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: hosts neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.hosts FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: interface_neighbor_evidence_neighbor_storage neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.interface_neighbor_evidence_neighbor_storage FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: interface_neighbor_matches_neighbor_storage neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.interface_neighbor_matches_neighbor_storage FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: interfaces neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.interfaces FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: resource_identifiers neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.resource_identifiers FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: resources neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.resources FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: sources neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.sources FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: topology_findings_neighbor_storage neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.topology_findings_neighbor_storage FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: topology_snapshot_events neighbor_input_changed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR DELETE OR UPDATE ON public.topology_snapshot_events FOR EACH ROW EXECUTE FUNCTION public.neighbor_input_changed();


--
-- Name: observations observations_reject_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER observations_reject_update BEFORE UPDATE ON public.observations FOR EACH ROW EXECUTE FUNCTION public.reject_observation_update();


--
-- Name: reconciliation_lanes reconciliation_lanes_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reconciliation_lanes_history BEFORE DELETE OR UPDATE ON public.reconciliation_lanes FOR EACH ROW EXECUTE FUNCTION public.guard_reconciliation_history();


--
-- Name: reconciliation_work reconciliation_work_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reconciliation_work_history BEFORE DELETE OR UPDATE ON public.reconciliation_work FOR EACH ROW EXECUTE FUNCTION public.guard_reconciliation_history();


--
-- Name: resources resources_enforce_kind_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resources_enforce_kind_immutability BEFORE UPDATE OF kind ON public.resources FOR EACH ROW EXECUTE FUNCTION public.enforce_resource_kind_immutability();


--
-- Name: topology_snapshot_events topology_snapshot_events_reject_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER topology_snapshot_events_reject_update BEFORE UPDATE ON public.topology_snapshot_events FOR EACH ROW EXECUTE FUNCTION public.reject_topology_snapshot_event_update();


--
-- Name: current_interface_adjacencies write_neighbor_view; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER write_neighbor_view INSTEAD OF INSERT OR DELETE OR UPDATE ON public.current_interface_adjacencies FOR EACH ROW EXECUTE FUNCTION public.write_neighbor_view();


--
-- Name: interface_neighbor_evidence write_neighbor_view; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER write_neighbor_view INSTEAD OF INSERT OR DELETE OR UPDATE ON public.interface_neighbor_evidence FOR EACH ROW EXECUTE FUNCTION public.write_neighbor_view();


--
-- Name: interface_neighbor_matches write_neighbor_view; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER write_neighbor_view INSTEAD OF INSERT OR DELETE OR UPDATE ON public.interface_neighbor_matches FOR EACH ROW EXECUTE FUNCTION public.write_neighbor_view();


--
-- Name: topology_findings write_neighbor_view; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER write_neighbor_view INSTEAD OF INSERT OR DELETE OR UPDATE ON public.topology_findings FOR EACH ROW EXECUTE FUNCTION public.write_neighbor_view();


--
-- Name: account_authorizations account_authorizations_session_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_authorizations
    ADD CONSTRAINT account_authorizations_session_token_id_fkey FOREIGN KEY (session_token_id) REFERENCES public.users_tokens(id) ON DELETE CASCADE;


--
-- Name: account_authorizations account_authorizations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_authorizations
    ADD CONSTRAINT account_authorizations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: account_challenges account_challenges_session_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_challenges
    ADD CONSTRAINT account_challenges_session_token_id_fkey FOREIGN KEY (session_token_id) REFERENCES public.users_tokens(id) ON DELETE CASCADE;


--
-- Name: account_challenges account_challenges_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_challenges
    ADD CONSTRAINT account_challenges_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: account_security_events account_security_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_security_events
    ADD CONSTRAINT account_security_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: actual_component_evidence_matches actual_component_evidence_matches_component_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actual_component_evidence_matches
    ADD CONSTRAINT actual_component_evidence_matches_component_fkey FOREIGN KEY (actual_component_id, organization_id, owner_resource_id) REFERENCES public.actual_components(id, organization_id, owner_resource_id) ON DELETE CASCADE;


--
-- Name: actual_component_evidence_matches actual_component_evidence_matches_evidence_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actual_component_evidence_matches
    ADD CONSTRAINT actual_component_evidence_matches_evidence_fkey FOREIGN KEY (component_evidence_id, organization_id, owner_resource_id) REFERENCES public.component_evidence(id, organization_id, resource_id) ON DELETE CASCADE;


--
-- Name: actual_components actual_components_owner_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actual_components
    ADD CONSTRAINT actual_components_owner_resource_fkey FOREIGN KEY (owner_resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: address_evidence address_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_evidence
    ADD CONSTRAINT address_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: address_evidence address_evidence_tenant_address_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_evidence
    ADD CONSTRAINT address_evidence_tenant_address_fkey FOREIGN KEY (address_id, organization_id) REFERENCES public.addresses(id, organization_id) ON DELETE CASCADE;


--
-- Name: address_evidence address_evidence_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_evidence
    ADD CONSTRAINT address_evidence_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: address_evidence address_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_evidence
    ADD CONSTRAINT address_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: address_findings address_findings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_findings
    ADD CONSTRAINT address_findings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: address_findings address_findings_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_findings
    ADD CONSTRAINT address_findings_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: addresses addresses_interface_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_interface_resource_fkey FOREIGN KEY (interface_id, organization_id, resource_id) REFERENCES public.interfaces(id, organization_id, resource_id) ON DELETE CASCADE;


--
-- Name: addresses addresses_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: addresses addresses_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: addressing_plan_levels addressing_plan_levels_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addressing_plan_levels
    ADD CONSTRAINT addressing_plan_levels_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: addressing_plan_levels addressing_plan_levels_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addressing_plan_levels
    ADD CONSTRAINT addressing_plan_levels_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: agent_leases agent_leases_organization_agent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_leases
    ADD CONSTRAINT agent_leases_organization_agent_fkey FOREIGN KEY (agent_id, organization_id) REFERENCES public.agents(id, organization_id) ON DELETE CASCADE;


--
-- Name: agent_leases agent_leases_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_leases
    ADD CONSTRAINT agent_leases_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: agents agents_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: agents agents_organization_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_organization_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: cable_assertions cable_assertions_actor_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_actor_principal_id_fkey FOREIGN KEY (actor_principal_id, organization_id) REFERENCES public.imported_principals(id, organization_id) ON DELETE RESTRICT;


--
-- Name: cable_assertions cable_assertions_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: cable_assertions cable_assertions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: cable_assertions cable_assertions_tenant_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_tenant_a_fkey FOREIGN KEY (interface_a_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_assertions cable_assertions_tenant_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_tenant_b_fkey FOREIGN KEY (interface_b_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_assertions cable_assertions_tenant_evidence_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_tenant_evidence_fkey FOREIGN KEY (interface_neighbor_evidence_id, organization_id) REFERENCES public.interface_neighbor_evidence_neighbor_storage(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_assertions cable_assertions_tenant_power_feed_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_tenant_power_feed_fkey FOREIGN KEY (power_feed_id, organization_id) REFERENCES public.power_feeds(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_assertions cable_assertions_tenant_power_outlet_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_tenant_power_outlet_fkey FOREIGN KEY (power_outlet_id, organization_id) REFERENCES public.power_outlets(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_assertions cable_assertions_tenant_power_port_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_tenant_power_port_fkey FOREIGN KEY (power_port_id, organization_id) REFERENCES public.power_ports(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_assertions cable_assertions_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_assertions
    ADD CONSTRAINT cable_assertions_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_change_events cable_change_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_change_events
    ADD CONSTRAINT cable_change_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: cable_change_events cable_change_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_change_events
    ADD CONSTRAINT cable_change_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: cable_change_events cable_change_events_tenant_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_change_events
    ADD CONSTRAINT cable_change_events_tenant_a_fkey FOREIGN KEY (interface_a_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE SET NULL (interface_a_id);


--
-- Name: cable_change_events cable_change_events_tenant_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_change_events
    ADD CONSTRAINT cable_change_events_tenant_b_fkey FOREIGN KEY (interface_b_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE SET NULL (interface_b_id);


--
-- Name: cable_change_events cable_change_events_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_change_events
    ADD CONSTRAINT cable_change_events_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE SET NULL (source_id);


--
-- Name: cable_endpoint_terminations cable_endpoint_terminations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_endpoint_terminations
    ADD CONSTRAINT cable_endpoint_terminations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: cable_endpoint_terminations cable_endpoint_terminations_tenant_cable_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_endpoint_terminations
    ADD CONSTRAINT cable_endpoint_terminations_tenant_cable_fkey FOREIGN KEY (cable_id, organization_id) REFERENCES public.cables(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_endpoint_terminations cable_endpoint_terminations_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_endpoint_terminations
    ADD CONSTRAINT cable_endpoint_terminations_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_import_contracts cable_import_contracts_granted_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_import_contracts
    ADD CONSTRAINT cable_import_contracts_granted_by_id_fkey FOREIGN KEY (granted_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: cable_import_contracts cable_import_contracts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_import_contracts
    ADD CONSTRAINT cable_import_contracts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: cable_import_contracts cable_import_contracts_revoked_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_import_contracts
    ADD CONSTRAINT cable_import_contracts_revoked_by_id_fkey FOREIGN KEY (revoked_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: cable_import_contracts cable_import_contracts_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_import_contracts
    ADD CONSTRAINT cable_import_contracts_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_plans cable_plans_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_plans
    ADD CONSTRAINT cable_plans_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: cable_plans cable_plans_tenant_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_plans
    ADD CONSTRAINT cable_plans_tenant_a_fkey FOREIGN KEY (interface_a_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_plans cable_plans_tenant_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_plans
    ADD CONSTRAINT cable_plans_tenant_b_fkey FOREIGN KEY (interface_b_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_plans cable_plans_tenant_power_feed_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_plans
    ADD CONSTRAINT cable_plans_tenant_power_feed_fkey FOREIGN KEY (power_feed_id, organization_id) REFERENCES public.power_feeds(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_plans cable_plans_tenant_power_outlet_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_plans
    ADD CONSTRAINT cable_plans_tenant_power_outlet_fkey FOREIGN KEY (power_outlet_id, organization_id) REFERENCES public.power_outlets(id, organization_id) ON DELETE CASCADE;


--
-- Name: cable_plans cable_plans_tenant_power_port_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_plans
    ADD CONSTRAINT cable_plans_tenant_power_port_fkey FOREIGN KEY (power_port_id, organization_id) REFERENCES public.power_ports(id, organization_id) ON DELETE CASCADE;


--
-- Name: cables cables_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: cables cables_tenant_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_tenant_a_fkey FOREIGN KEY (interface_a_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: cables cables_tenant_assertion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_tenant_assertion_fkey FOREIGN KEY (primary_assertion_id, organization_id) REFERENCES public.cable_assertions(id, organization_id) ON DELETE CASCADE;


--
-- Name: cables cables_tenant_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_tenant_b_fkey FOREIGN KEY (interface_b_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: cables cables_tenant_power_feed_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_tenant_power_feed_fkey FOREIGN KEY (power_feed_id, organization_id) REFERENCES public.power_feeds(id, organization_id) ON DELETE CASCADE;


--
-- Name: cables cables_tenant_power_outlet_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_tenant_power_outlet_fkey FOREIGN KEY (power_outlet_id, organization_id) REFERENCES public.power_outlets(id, organization_id) ON DELETE CASCADE;


--
-- Name: cables cables_tenant_power_port_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_tenant_power_port_fkey FOREIGN KEY (power_port_id, organization_id) REFERENCES public.power_ports(id, organization_id) ON DELETE CASCADE;


--
-- Name: catalog_type_revisions catalog_type_revisions_hardware_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_type_revisions
    ADD CONSTRAINT catalog_type_revisions_hardware_type_fkey FOREIGN KEY (hardware_type_id, organization_id) REFERENCES public.hardware_types(id, organization_id) ON DELETE CASCADE;


--
-- Name: catalog_type_revisions catalog_type_revisions_module_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_type_revisions
    ADD CONSTRAINT catalog_type_revisions_module_type_fkey FOREIGN KEY (module_type_id, organization_id) REFERENCES public.module_types(id, organization_id) ON DELETE CASCADE;


--
-- Name: change_events change_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: change_events change_events_finding_workflow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_finding_workflow_id_fkey FOREIGN KEY (finding_workflow_id) REFERENCES public.finding_workflows(id) ON DELETE SET NULL;


--
-- Name: change_events change_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: change_events change_events_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id) REFERENCES public.observations(id, organization_id) ON DELETE SET NULL (observation_id);


--
-- Name: change_events change_events_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE SET NULL (resource_id);


--
-- Name: change_events change_events_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE SET NULL (source_id);


--
-- Name: change_events change_events_tenant_sync_run_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_tenant_sync_run_fkey FOREIGN KEY (sync_run_id, organization_id) REFERENCES public.sync_runs(id, organization_id) ON DELETE SET NULL (sync_run_id);


--
-- Name: change_requests change_requests_decided_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_requests
    ADD CONSTRAINT change_requests_decided_by_user_id_fkey FOREIGN KEY (decided_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: change_requests change_requests_requested_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_requests
    ADD CONSTRAINT change_requests_requested_by_user_id_fkey FOREIGN KEY (requested_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: change_requests change_requests_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_requests
    ADD CONSTRAINT change_requests_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: collector_findings collector_findings_organization_agent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_findings
    ADD CONSTRAINT collector_findings_organization_agent_fkey FOREIGN KEY (agent_id, organization_id) REFERENCES public.agents(id, organization_id) ON DELETE CASCADE;


--
-- Name: collector_findings collector_findings_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_findings
    ADD CONSTRAINT collector_findings_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: collector_findings collector_findings_organization_target_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_findings
    ADD CONSTRAINT collector_findings_organization_target_fkey FOREIGN KEY (target_id, organization_id) REFERENCES public.collector_targets(id, organization_id) ON DELETE CASCADE;


--
-- Name: collector_target_resources collector_target_resources_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_target_resources
    ADD CONSTRAINT collector_target_resources_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: collector_target_resources collector_target_resources_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_target_resources
    ADD CONSTRAINT collector_target_resources_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: collector_target_resources collector_target_resources_tenant_target_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_target_resources
    ADD CONSTRAINT collector_target_resources_tenant_target_fkey FOREIGN KEY (target_id, organization_id, source_id) REFERENCES public.collector_targets(id, organization_id, source_id) ON DELETE CASCADE;


--
-- Name: collector_targets collector_targets_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_targets
    ADD CONSTRAINT collector_targets_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: collector_targets collector_targets_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_targets
    ADD CONSTRAINT collector_targets_tenant_observation_fkey FOREIGN KEY (last_observation_id, organization_id) REFERENCES public.observations(id, organization_id) ON DELETE SET NULL;


--
-- Name: collector_targets collector_targets_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_targets
    ADD CONSTRAINT collector_targets_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: component_evidence component_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_evidence
    ADD CONSTRAINT component_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: component_evidence component_evidence_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_evidence
    ADD CONSTRAINT component_evidence_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: component_evidence component_evidence_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_evidence
    ADD CONSTRAINT component_evidence_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: component_evidence component_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_evidence
    ADD CONSTRAINT component_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: component_findings component_findings_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_findings
    ADD CONSTRAINT component_findings_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: component_templates component_templates_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_templates
    ADD CONSTRAINT component_templates_revision_fkey FOREIGN KEY (catalog_type_revision_id, organization_id) REFERENCES public.catalog_type_revisions(id, organization_id) ON DELETE CASCADE;


--
-- Name: confirmed_components confirmed_components_confirmed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmed_components
    ADD CONSTRAINT confirmed_components_confirmed_by_user_id_fkey FOREIGN KEY (confirmed_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: confirmed_components confirmed_components_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmed_components
    ADD CONSTRAINT confirmed_components_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: confirmed_components confirmed_components_tenant_assignment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmed_components
    ADD CONSTRAINT confirmed_components_tenant_assignment_fkey FOREIGN KEY (hardware_assignment_id, organization_id) REFERENCES public.hardware_assignments(id, organization_id) ON DELETE CASCADE;


--
-- Name: confirmed_components confirmed_components_tenant_exception_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmed_components
    ADD CONSTRAINT confirmed_components_tenant_exception_fkey FOREIGN KEY (exception_id, organization_id) REFERENCES public.expected_component_exceptions(id, organization_id) ON DELETE CASCADE;


--
-- Name: confirmed_components confirmed_components_tenant_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmed_components
    ADD CONSTRAINT confirmed_components_tenant_template_fkey FOREIGN KEY (component_template_id, organization_id) REFERENCES public.component_templates(id, organization_id) ON DELETE RESTRICT;


--
-- Name: current_interface_adjacencies_neighbor_storage current_interface_adjacencies_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacencies_neighbor_storage
    ADD CONSTRAINT current_interface_adjacencies_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: current_interface_adjacencies_neighbor_storage current_interface_adjacencies_tenant_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacencies_neighbor_storage
    ADD CONSTRAINT current_interface_adjacencies_tenant_a_fkey FOREIGN KEY (interface_a_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_interface_adjacencies_neighbor_storage current_interface_adjacencies_tenant_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacencies_neighbor_storage
    ADD CONSTRAINT current_interface_adjacencies_tenant_b_fkey FOREIGN KEY (interface_b_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_interface_adjacencies_neighbor_storage current_interface_adjacencies_tenant_evidence_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacencies_neighbor_storage
    ADD CONSTRAINT current_interface_adjacencies_tenant_evidence_fkey FOREIGN KEY (primary_evidence_id, organization_id) REFERENCES public.interface_neighbor_evidence_neighbor_storage(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_interface_adjacency_endpoints current_interface_adjacency_endpoints_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacency_endpoints
    ADD CONSTRAINT current_interface_adjacency_endpoints_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: current_interface_adjacency_endpoints current_interface_adjacency_endpoints_tenant_adjacency_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacency_endpoints
    ADD CONSTRAINT current_interface_adjacency_endpoints_tenant_adjacency_fkey FOREIGN KEY (adjacency_id, organization_id) REFERENCES public.current_interface_adjacencies_neighbor_storage(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_interface_adjacency_endpoints current_interface_adjacency_endpoints_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_adjacency_endpoints
    ADD CONSTRAINT current_interface_adjacency_endpoints_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_interface_vlan_memberships current_interface_vlan_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_memberships
    ADD CONSTRAINT current_interface_vlan_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: current_interface_vlan_memberships current_interface_vlan_memberships_tenant_evidence_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_memberships
    ADD CONSTRAINT current_interface_vlan_memberships_tenant_evidence_fkey FOREIGN KEY (interface_vlan_evidence_id, organization_id, interface_id, vlan_id) REFERENCES public.interface_vlan_evidence(id, organization_id, interface_id, vlan_id) ON DELETE CASCADE;


--
-- Name: current_interface_vlan_memberships current_interface_vlan_memberships_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_memberships
    ADD CONSTRAINT current_interface_vlan_memberships_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_interface_vlan_memberships current_interface_vlan_memberships_tenant_vlan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_memberships
    ADD CONSTRAINT current_interface_vlan_memberships_tenant_vlan_fkey FOREIGN KEY (vlan_id, organization_id) REFERENCES public.vlans(id, organization_id) ON DELETE RESTRICT;


--
-- Name: current_interface_vlan_modes current_interface_vlan_modes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_modes
    ADD CONSTRAINT current_interface_vlan_modes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: current_interface_vlan_modes current_interface_vlan_modes_tenant_evidence_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_modes
    ADD CONSTRAINT current_interface_vlan_modes_tenant_evidence_fkey FOREIGN KEY (interface_vlan_mode_evidence_id, organization_id, interface_id) REFERENCES public.interface_vlan_mode_evidence(id, organization_id, interface_id) ON DELETE CASCADE;


--
-- Name: current_interface_vlan_modes current_interface_vlan_modes_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_interface_vlan_modes
    ADD CONSTRAINT current_interface_vlan_modes_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_module_installations current_module_installations_bay_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_module_installations
    ADD CONSTRAINT current_module_installations_bay_fkey FOREIGN KEY (module_bay_id, organization_id) REFERENCES public.module_bays(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_module_installations current_module_installations_compatibility_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_module_installations
    ADD CONSTRAINT current_module_installations_compatibility_fkey FOREIGN KEY (module_bay_id, organization_id, module_type_id) REFERENCES public.module_bay_compatible_types(module_bay_id, organization_id, module_type_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: current_module_installations current_module_installations_module_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_module_installations
    ADD CONSTRAINT current_module_installations_module_fkey FOREIGN KEY (module_id, organization_id, module_type_id) REFERENCES public.modules(id, organization_id, module_type_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: current_placements current_placements_location_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_placements
    ADD CONSTRAINT current_placements_location_fkey FOREIGN KEY (location_id, organization_id, site_id) REFERENCES public.locations(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: current_placements current_placements_rack_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_placements
    ADD CONSTRAINT current_placements_rack_fkey FOREIGN KEY (rack_id, organization_id, site_id) REFERENCES public.racks(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: current_placements current_placements_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_placements
    ADD CONSTRAINT current_placements_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: current_placements current_placements_site_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.current_placements
    ADD CONSTRAINT current_placements_site_fkey FOREIGN KEY (site_id, organization_id) REFERENCES public.sites(id, organization_id) ON DELETE RESTRICT;


--
-- Name: desired_interface_vlan_assignments desired_interface_vlan_assignments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_interface_vlan_assignments
    ADD CONSTRAINT desired_interface_vlan_assignments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: desired_interface_vlan_assignments desired_interface_vlan_assignments_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_interface_vlan_assignments
    ADD CONSTRAINT desired_interface_vlan_assignments_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: desired_interface_vlan_assignments desired_interface_vlan_assignments_tenant_vlan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_interface_vlan_assignments
    ADD CONSTRAINT desired_interface_vlan_assignments_tenant_vlan_fkey FOREIGN KEY (vlan_id, organization_id) REFERENCES public.vlans(id, organization_id) ON DELETE RESTRICT;


--
-- Name: desired_interface_vlan_modes desired_interface_vlan_modes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_interface_vlan_modes
    ADD CONSTRAINT desired_interface_vlan_modes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: desired_interface_vlan_modes desired_interface_vlan_modes_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_interface_vlan_modes
    ADD CONSTRAINT desired_interface_vlan_modes_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: desired_module_assignments desired_module_assignments_bay_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_module_assignments
    ADD CONSTRAINT desired_module_assignments_bay_fkey FOREIGN KEY (module_bay_id, organization_id) REFERENCES public.module_bays(id, organization_id) ON DELETE CASCADE;


--
-- Name: desired_module_assignments desired_module_assignments_compatibility_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_module_assignments
    ADD CONSTRAINT desired_module_assignments_compatibility_fkey FOREIGN KEY (module_bay_id, organization_id, module_type_id) REFERENCES public.module_bay_compatible_types(module_bay_id, organization_id, module_type_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: desired_module_assignments desired_module_assignments_confirmed_by_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_module_assignments
    ADD CONSTRAINT desired_module_assignments_confirmed_by_principal_id_fkey FOREIGN KEY (confirmed_by_principal_id, organization_id) REFERENCES public.imported_principals(id, organization_id) ON DELETE RESTRICT;


--
-- Name: desired_module_assignments desired_module_assignments_confirmed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_module_assignments
    ADD CONSTRAINT desired_module_assignments_confirmed_by_user_id_fkey FOREIGN KEY (confirmed_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: desired_placements desired_placements_location_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_placements
    ADD CONSTRAINT desired_placements_location_fkey FOREIGN KEY (location_id, organization_id, site_id) REFERENCES public.locations(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: desired_placements desired_placements_rack_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_placements
    ADD CONSTRAINT desired_placements_rack_fkey FOREIGN KEY (rack_id, organization_id, site_id) REFERENCES public.racks(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: desired_placements desired_placements_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_placements
    ADD CONSTRAINT desired_placements_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: desired_placements desired_placements_site_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.desired_placements
    ADD CONSTRAINT desired_placements_site_fkey FOREIGN KEY (site_id, organization_id) REFERENCES public.sites(id, organization_id) ON DELETE RESTRICT;


--
-- Name: expected_component_exceptions expected_component_exceptions_assignment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_component_exceptions
    ADD CONSTRAINT expected_component_exceptions_assignment_fkey FOREIGN KEY (hardware_assignment_id, organization_id) REFERENCES public.hardware_assignments(id, organization_id) ON DELETE CASCADE;


--
-- Name: expected_component_exceptions expected_component_exceptions_assignment_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_component_exceptions
    ADD CONSTRAINT expected_component_exceptions_assignment_revision_fkey FOREIGN KEY (hardware_assignment_id, organization_id, catalog_type_revision_id) REFERENCES public.hardware_assignments(id, organization_id, catalog_type_revision_id) ON DELETE CASCADE;


--
-- Name: expected_component_exceptions expected_component_exceptions_confirmed_by_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_component_exceptions
    ADD CONSTRAINT expected_component_exceptions_confirmed_by_principal_id_fkey FOREIGN KEY (confirmed_by_principal_id, organization_id) REFERENCES public.imported_principals(id, organization_id) ON DELETE RESTRICT;


--
-- Name: expected_component_exceptions expected_component_exceptions_confirmed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_component_exceptions
    ADD CONSTRAINT expected_component_exceptions_confirmed_by_user_id_fkey FOREIGN KEY (confirmed_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: expected_component_exceptions expected_component_exceptions_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_component_exceptions
    ADD CONSTRAINT expected_component_exceptions_template_fkey FOREIGN KEY (component_template_id, organization_id) REFERENCES public.component_templates(id, organization_id) ON DELETE RESTRICT;


--
-- Name: expected_component_exceptions expected_component_exceptions_template_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_component_exceptions
    ADD CONSTRAINT expected_component_exceptions_template_revision_fkey FOREIGN KEY (component_template_id, organization_id, catalog_type_revision_id) REFERENCES public.component_templates(id, organization_id, catalog_type_revision_id) ON DELETE RESTRICT;


--
-- Name: expected_components expected_components_assignment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_components
    ADD CONSTRAINT expected_components_assignment_fkey FOREIGN KEY (hardware_assignment_id, organization_id) REFERENCES public.hardware_assignments(id, organization_id) ON DELETE CASCADE;


--
-- Name: expected_components expected_components_assignment_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_components
    ADD CONSTRAINT expected_components_assignment_revision_fkey FOREIGN KEY (hardware_assignment_id, organization_id, catalog_type_revision_id) REFERENCES public.hardware_assignments(id, organization_id, catalog_type_revision_id) ON DELETE CASCADE;


--
-- Name: expected_components expected_components_exception_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_components
    ADD CONSTRAINT expected_components_exception_fkey FOREIGN KEY (exception_id, organization_id) REFERENCES public.expected_component_exceptions(id, organization_id) ON DELETE RESTRICT;


--
-- Name: expected_components expected_components_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expected_components
    ADD CONSTRAINT expected_components_template_fkey FOREIGN KEY (component_template_id, organization_id, catalog_type_revision_id) REFERENCES public.component_templates(id, organization_id, catalog_type_revision_id) ON DELETE RESTRICT;


--
-- Name: finding_workflows finding_workflows_assignee_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finding_workflows
    ADD CONSTRAINT finding_workflows_assignee_user_id_fkey FOREIGN KEY (assignee_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: finding_workflows finding_workflows_exception_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finding_workflows
    ADD CONSTRAINT finding_workflows_exception_by_user_id_fkey FOREIGN KEY (exception_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: finding_workflows finding_workflows_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finding_workflows
    ADD CONSTRAINT finding_workflows_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: hardware_assignments hardware_assignments_hardware_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_assignments
    ADD CONSTRAINT hardware_assignments_hardware_type_fkey FOREIGN KEY (hardware_type_id, organization_id) REFERENCES public.hardware_types(id, organization_id) ON DELETE RESTRICT;


--
-- Name: hardware_assignments hardware_assignments_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_assignments
    ADD CONSTRAINT hardware_assignments_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: hardware_assignments hardware_assignments_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_assignments
    ADD CONSTRAINT hardware_assignments_revision_fkey FOREIGN KEY (catalog_type_revision_id, organization_id, hardware_type_id) REFERENCES public.catalog_type_revisions(id, organization_id, hardware_type_id) ON DELETE RESTRICT;


--
-- Name: hardware_match_findings hardware_match_findings_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_match_findings
    ADD CONSTRAINT hardware_match_findings_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: hardware_types hardware_types_organization_manufacturer_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_types
    ADD CONSTRAINT hardware_types_organization_manufacturer_fkey FOREIGN KEY (manufacturer_id, organization_id) REFERENCES public.manufacturers(id, organization_id) ON DELETE RESTRICT;


--
-- Name: hardware_types hardware_types_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_types
    ADD CONSTRAINT hardware_types_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: hosts hosts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hosts
    ADD CONSTRAINT hosts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: hosts hosts_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hosts
    ADD CONSTRAINT hosts_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: identity_provider_attempts identity_provider_attempts_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_attempts
    ADD CONSTRAINT identity_provider_attempts_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.identity_providers(id) ON DELETE CASCADE;


--
-- Name: identity_provider_attempts identity_provider_attempts_session_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_attempts
    ADD CONSTRAINT identity_provider_attempts_session_token_id_fkey FOREIGN KEY (session_token_id) REFERENCES public.users_tokens(id) ON DELETE CASCADE;


--
-- Name: identity_provider_attempts identity_provider_attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_attempts
    ADD CONSTRAINT identity_provider_attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: identity_provider_events identity_provider_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_events
    ADD CONSTRAINT identity_provider_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: identity_provider_events identity_provider_events_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_events
    ADD CONSTRAINT identity_provider_events_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.identity_providers(id) ON DELETE RESTRICT;


--
-- Name: identity_provider_revisions identity_provider_revisions_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_revisions
    ADD CONSTRAINT identity_provider_revisions_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.identity_providers(id) ON DELETE RESTRICT;


--
-- Name: identity_provider_tests identity_provider_tests_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_tests
    ADD CONSTRAINT identity_provider_tests_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: identity_provider_tests identity_provider_tests_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_provider_tests
    ADD CONSTRAINT identity_provider_tests_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.identity_providers(id) ON DELETE RESTRICT;


--
-- Name: imported_attributions imported_attributions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_attributions
    ADD CONSTRAINT imported_attributions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: imported_attributions imported_attributions_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_attributions
    ADD CONSTRAINT imported_attributions_principal_id_fkey FOREIGN KEY (principal_id, organization_id) REFERENCES public.imported_principals(id, organization_id) ON DELETE CASCADE;


--
-- Name: imported_held_records imported_held_records_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_held_records
    ADD CONSTRAINT imported_held_records_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: imported_held_records imported_held_records_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_held_records
    ADD CONSTRAINT imported_held_records_principal_id_fkey FOREIGN KEY (principal_id, organization_id) REFERENCES public.imported_principals(id, organization_id) ON DELETE CASCADE;


--
-- Name: imported_principals imported_principals_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_principals
    ADD CONSTRAINT imported_principals_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: imported_principals imported_principals_organization_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_principals
    ADD CONSTRAINT imported_principals_organization_import_id_fkey FOREIGN KEY (organization_import_id) REFERENCES public.organization_imports(id) ON DELETE CASCADE;


--
-- Name: imported_principals imported_principals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imported_principals
    ADD CONSTRAINT imported_principals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: installation_keys installation_keys_approved_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_keys
    ADD CONSTRAINT installation_keys_approved_by_user_id_fkey FOREIGN KEY (approved_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: installation_keys installation_keys_organization_agent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_keys
    ADD CONSTRAINT installation_keys_organization_agent_fkey FOREIGN KEY (agent_id, organization_id) REFERENCES public.agents(id, organization_id) ON DELETE CASCADE;


--
-- Name: intake_api_keys intake_api_keys_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intake_api_keys
    ADD CONSTRAINT intake_api_keys_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_evidence interface_evidence_component_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_evidence
    ADD CONSTRAINT interface_evidence_component_template_fkey FOREIGN KEY (component_template_id, organization_id) REFERENCES public.component_templates(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interface_evidence interface_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_evidence
    ADD CONSTRAINT interface_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_evidence interface_evidence_tenant_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_evidence
    ADD CONSTRAINT interface_evidence_tenant_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: interface_evidence interface_evidence_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_evidence
    ADD CONSTRAINT interface_evidence_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_evidence interface_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_evidence
    ADD CONSTRAINT interface_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interface_neighbor_evidence_neighbor_storage interface_neighbor_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_evidence_neighbor_storage
    ADD CONSTRAINT interface_neighbor_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_neighbor_evidence_neighbor_storage interface_neighbor_evidence_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_evidence_neighbor_storage
    ADD CONSTRAINT interface_neighbor_evidence_tenant_interface_fkey FOREIGN KEY (local_interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_neighbor_evidence_neighbor_storage interface_neighbor_evidence_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_evidence_neighbor_storage
    ADD CONSTRAINT interface_neighbor_evidence_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: interface_neighbor_evidence_neighbor_storage interface_neighbor_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_evidence_neighbor_storage
    ADD CONSTRAINT interface_neighbor_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interface_neighbor_matches_neighbor_storage interface_neighbor_matches_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_matches_neighbor_storage
    ADD CONSTRAINT interface_neighbor_matches_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_neighbor_matches_neighbor_storage interface_neighbor_matches_tenant_evidence_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_matches_neighbor_storage
    ADD CONSTRAINT interface_neighbor_matches_tenant_evidence_fkey FOREIGN KEY (interface_neighbor_evidence_id, organization_id) REFERENCES public.interface_neighbor_evidence_neighbor_storage(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_neighbor_matches_neighbor_storage interface_neighbor_matches_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_neighbor_matches_neighbor_storage
    ADD CONSTRAINT interface_neighbor_matches_tenant_interface_fkey FOREIGN KEY (remote_interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_relationship_evidence interface_relationship_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationship_evidence
    ADD CONSTRAINT interface_relationship_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_relationship_evidence interface_relationship_evidence_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationship_evidence
    ADD CONSTRAINT interface_relationship_evidence_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: interface_relationship_evidence interface_relationship_evidence_tenant_relationship_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationship_evidence
    ADD CONSTRAINT interface_relationship_evidence_tenant_relationship_fkey FOREIGN KEY (interface_relationship_id, organization_id) REFERENCES public.interface_relationships(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_relationship_evidence interface_relationship_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationship_evidence
    ADD CONSTRAINT interface_relationship_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interface_relationships interface_relationships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationships
    ADD CONSTRAINT interface_relationships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_relationships interface_relationships_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationships
    ADD CONSTRAINT interface_relationships_tenant_source_fkey FOREIGN KEY (source_interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_relationships interface_relationships_tenant_target_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_relationships
    ADD CONSTRAINT interface_relationships_tenant_target_fkey FOREIGN KEY (target_interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_routing_domain_evidence interface_routing_domain_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domain_evidence
    ADD CONSTRAINT interface_routing_domain_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_routing_domain_evidence interface_routing_domain_evidence_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domain_evidence
    ADD CONSTRAINT interface_routing_domain_evidence_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_routing_domain_evidence interface_routing_domain_evidence_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domain_evidence
    ADD CONSTRAINT interface_routing_domain_evidence_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: interface_routing_domain_evidence interface_routing_domain_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domain_evidence
    ADD CONSTRAINT interface_routing_domain_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interface_routing_domains interface_routing_domains_evidence_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domains
    ADD CONSTRAINT interface_routing_domains_evidence_id_fkey FOREIGN KEY (evidence_id) REFERENCES public.interface_routing_domain_evidence(id) ON DELETE CASCADE;


--
-- Name: interface_routing_domains interface_routing_domains_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domains
    ADD CONSTRAINT interface_routing_domains_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_routing_domains interface_routing_domains_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domains
    ADD CONSTRAINT interface_routing_domains_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_routing_domains interface_routing_domains_tenant_vrf_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_routing_domains
    ADD CONSTRAINT interface_routing_domains_tenant_vrf_fkey FOREIGN KEY (vrf_id, organization_id) REFERENCES public.vrfs(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_vlan_evidence interface_vlan_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_evidence
    ADD CONSTRAINT interface_vlan_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_vlan_evidence interface_vlan_evidence_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_evidence
    ADD CONSTRAINT interface_vlan_evidence_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_vlan_evidence interface_vlan_evidence_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_evidence
    ADD CONSTRAINT interface_vlan_evidence_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: interface_vlan_evidence interface_vlan_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_evidence
    ADD CONSTRAINT interface_vlan_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interface_vlan_evidence interface_vlan_evidence_tenant_vlan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_evidence
    ADD CONSTRAINT interface_vlan_evidence_tenant_vlan_fkey FOREIGN KEY (vlan_id, organization_id) REFERENCES public.vlans(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interface_vlan_mode_evidence interface_vlan_mode_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_mode_evidence
    ADD CONSTRAINT interface_vlan_mode_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interface_vlan_mode_evidence interface_vlan_mode_evidence_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_mode_evidence
    ADD CONSTRAINT interface_vlan_mode_evidence_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: interface_vlan_mode_evidence interface_vlan_mode_evidence_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_mode_evidence
    ADD CONSTRAINT interface_vlan_mode_evidence_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: interface_vlan_mode_evidence interface_vlan_mode_evidence_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interface_vlan_mode_evidence
    ADD CONSTRAINT interface_vlan_mode_evidence_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: interfaces interfaces_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interfaces
    ADD CONSTRAINT interfaces_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interfaces interfaces_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interfaces
    ADD CONSTRAINT interfaces_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: inventory_items inventory_items_owner_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT inventory_items_owner_parent_fkey FOREIGN KEY (parent_id, organization_id, owner_resource_id) REFERENCES public.inventory_items(id, organization_id, owner_resource_id) ON DELETE RESTRICT;


--
-- Name: inventory_items inventory_items_owner_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT inventory_items_owner_resource_fkey FOREIGN KEY (owner_resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: inventory_items inventory_items_promoted_module_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT inventory_items_promoted_module_fkey FOREIGN KEY (promoted_module_id, organization_id) REFERENCES public.modules(id, organization_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: ip_address_assignments ip_address_assignments_assigned_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_address_assignments
    ADD CONSTRAINT ip_address_assignments_assigned_by_id_fkey FOREIGN KEY (assigned_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: ip_address_assignments ip_address_assignments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_address_assignments
    ADD CONSTRAINT ip_address_assignments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: ip_address_assignments ip_address_assignments_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_address_assignments
    ADD CONSTRAINT ip_address_assignments_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: ip_address_assignments ip_address_assignments_tenant_ip_address_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_address_assignments
    ADD CONSTRAINT ip_address_assignments_tenant_ip_address_fkey FOREIGN KEY (ip_address_id, organization_id) REFERENCES public.ip_addresses(id, organization_id) ON DELETE CASCADE;


--
-- Name: ip_addresses ip_addresses_adopted_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_addresses
    ADD CONSTRAINT ip_addresses_adopted_by_id_fkey FOREIGN KEY (adopted_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: ip_addresses ip_addresses_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_addresses
    ADD CONSTRAINT ip_addresses_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: ip_addresses ip_addresses_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_addresses
    ADD CONSTRAINT ip_addresses_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: ip_addresses ip_addresses_tenant_vrf_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_addresses
    ADD CONSTRAINT ip_addresses_tenant_vrf_fkey FOREIGN KEY (vrf_id, organization_id) REFERENCES public.vrfs(id, organization_id) ON DELETE RESTRICT;


--
-- Name: job_events job_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_events
    ADD CONSTRAINT job_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: job_events job_events_tenant_job_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_events
    ADD CONSTRAINT job_events_tenant_job_fkey FOREIGN KEY (job_id, organization_id) REFERENCES public.jobs(id, organization_id) ON DELETE CASCADE;


--
-- Name: jobs jobs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: jobs jobs_organization_target_binding_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_organization_target_binding_fkey FOREIGN KEY (target_binding_id, organization_id) REFERENCES public.target_bindings(id, organization_id) ON DELETE SET NULL (target_binding_id);


--
-- Name: jobs jobs_requested_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_requested_by_user_id_fkey FOREIGN KEY (requested_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: jobs jobs_tenant_agent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_tenant_agent_fkey FOREIGN KEY (agent_id, organization_id) REFERENCES public.agents(id, organization_id);


--
-- Name: jobs jobs_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE SET NULL (resource_id);


--
-- Name: locations locations_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: locations locations_organization_site_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_organization_site_fkey FOREIGN KEY (site_id, organization_id) REFERENCES public.sites(id, organization_id) ON DELETE RESTRICT;


--
-- Name: locations locations_site_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_site_parent_fkey FOREIGN KEY (parent_id, organization_id, site_id) REFERENCES public.locations(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: manufacturers manufacturers_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manufacturers
    ADD CONSTRAINT manufacturers_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: module_bay_compatible_types module_bay_compatible_types_bay_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_bay_compatible_types
    ADD CONSTRAINT module_bay_compatible_types_bay_fkey FOREIGN KEY (module_bay_id, organization_id) REFERENCES public.module_bays(id, organization_id) ON DELETE CASCADE;


--
-- Name: module_bay_compatible_types module_bay_compatible_types_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_bay_compatible_types
    ADD CONSTRAINT module_bay_compatible_types_type_fkey FOREIGN KEY (module_type_id, organization_id) REFERENCES public.module_types(id, organization_id) ON DELETE CASCADE;


--
-- Name: module_bays module_bays_owner_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_bays
    ADD CONSTRAINT module_bays_owner_resource_fkey FOREIGN KEY (owner_resource_id, organization_id, owner_kind) REFERENCES public.resources(id, organization_id, kind) ON DELETE CASCADE;


--
-- Name: module_installation_events module_installation_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_installation_events
    ADD CONSTRAINT module_installation_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: module_installation_events module_installation_events_bay_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_installation_events
    ADD CONSTRAINT module_installation_events_bay_fkey FOREIGN KEY (module_bay_id, organization_id) REFERENCES public.module_bays(id, organization_id) ON DELETE CASCADE;


--
-- Name: module_installation_events module_installation_events_module_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_installation_events
    ADD CONSTRAINT module_installation_events_module_fkey FOREIGN KEY (module_id, organization_id) REFERENCES public.modules(id, organization_id) ON DELETE CASCADE;


--
-- Name: module_types module_types_organization_manufacturer_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_types
    ADD CONSTRAINT module_types_organization_manufacturer_fkey FOREIGN KEY (manufacturer_id, organization_id) REFERENCES public.manufacturers(id, organization_id) ON DELETE RESTRICT;


--
-- Name: module_types module_types_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_types
    ADD CONSTRAINT module_types_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: modules modules_module_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_module_type_fkey FOREIGN KEY (module_type_id, organization_id) REFERENCES public.module_types(id, organization_id) ON DELETE RESTRICT;


--
-- Name: modules modules_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: modules modules_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_revision_fkey FOREIGN KEY (catalog_type_revision_id, organization_id, module_type_id) REFERENCES public.catalog_type_revisions(id, organization_id, module_type_id) ON DELETE RESTRICT;


--
-- Name: neighbor_generation_heads neighbor_generation_heads_current_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generation_heads
    ADD CONSTRAINT neighbor_generation_heads_current_generation_id_fkey FOREIGN KEY (current_generation_id) REFERENCES public.neighbor_generations(id);


--
-- Name: neighbor_generation_heads neighbor_generation_heads_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generation_heads
    ADD CONSTRAINT neighbor_generation_heads_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: neighbor_generation_rows neighbor_generation_rows_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generation_rows
    ADD CONSTRAINT neighbor_generation_rows_generation_id_fkey FOREIGN KEY (generation_id) REFERENCES public.neighbor_generations(id) ON DELETE CASCADE;


--
-- Name: neighbor_generation_rows neighbor_generation_rows_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generation_rows
    ADD CONSTRAINT neighbor_generation_rows_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: neighbor_generations neighbor_generations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.neighbor_generations
    ADD CONSTRAINT neighbor_generations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: observation_reconciliations observation_reconciliations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observation_reconciliations
    ADD CONSTRAINT observation_reconciliations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: observation_reconciliations observation_reconciliations_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observation_reconciliations
    ADD CONSTRAINT observation_reconciliations_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id) REFERENCES public.observations(id, organization_id) ON DELETE CASCADE;


--
-- Name: observation_reconciliations observation_reconciliations_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observation_reconciliations
    ADD CONSTRAINT observation_reconciliations_tenant_resource_fkey FOREIGN KEY (matched_resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE SET NULL (matched_resource_id);


--
-- Name: observations observations_intake_api_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_intake_api_key_fkey FOREIGN KEY (intake_api_key_id, organization_id) REFERENCES public.intake_api_keys(id, organization_id) ON DELETE SET NULL (intake_api_key_id);


--
-- Name: observations observations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: observations observations_organization_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_organization_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: observations observations_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_parent_fkey FOREIGN KEY (parent_observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: observations observations_source_sync_run_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_source_sync_run_fkey FOREIGN KEY (sync_run_id, organization_id, source_id) REFERENCES public.sync_runs(id, organization_id, source_id) ON DELETE SET NULL (sync_run_id);


--
-- Name: operator_idempotency_keys operator_idempotency_keys_operator_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operator_idempotency_keys
    ADD CONSTRAINT operator_idempotency_keys_operator_token_id_fkey FOREIGN KEY (operator_token_id) REFERENCES public.operator_tokens(id) ON DELETE CASCADE;


--
-- Name: operator_invitation_deliveries operator_invitation_deliveries_invitation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operator_invitation_deliveries
    ADD CONSTRAINT operator_invitation_deliveries_invitation_id_fkey FOREIGN KEY (invitation_id) REFERENCES public.organization_invitations(id) ON DELETE CASCADE;


--
-- Name: organization_domains organization_domains_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_domains
    ADD CONSTRAINT organization_domains_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_export_chunks organization_export_chunks_export_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_export_chunks
    ADD CONSTRAINT organization_export_chunks_export_id_fkey FOREIGN KEY (export_id) REFERENCES public.organization_exports(id) ON DELETE CASCADE;


--
-- Name: organization_exports organization_exports_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_exports
    ADD CONSTRAINT organization_exports_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_exports organization_exports_requested_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_exports
    ADD CONSTRAINT organization_exports_requested_by_user_id_fkey FOREIGN KEY (requested_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: organization_exports organization_exports_revoked_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_exports
    ADD CONSTRAINT organization_exports_revoked_by_user_id_fkey FOREIGN KEY (revoked_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: organization_imports organization_imports_imported_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_imports
    ADD CONSTRAINT organization_imports_imported_by_user_id_fkey FOREIGN KEY (imported_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: organization_imports organization_imports_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_imports
    ADD CONSTRAINT organization_imports_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_invitations organization_invitations_accepted_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_accepted_by_user_id_fkey FOREIGN KEY (accepted_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: organization_invitations organization_invitations_imported_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_imported_principal_id_fkey FOREIGN KEY (imported_principal_id, organization_id) REFERENCES public.imported_principals(id, organization_id) ON DELETE CASCADE;


--
-- Name: organization_invitations organization_invitations_invited_by_operator_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_invited_by_operator_token_id_fkey FOREIGN KEY (invited_by_operator_token_id) REFERENCES public.operator_tokens(id) ON DELETE RESTRICT;


--
-- Name: organization_invitations organization_invitations_invited_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_invited_by_user_id_fkey FOREIGN KEY (invited_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: organization_invitations organization_invitations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_invitations organization_invitations_revoked_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_revoked_by_user_id_fkey FOREIGN KEY (revoked_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: organization_lifecycle_notices organization_lifecycle_notices_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_lifecycle_notices
    ADD CONSTRAINT organization_lifecycle_notices_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_limits organization_limits_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_limits
    ADD CONSTRAINT organization_limits_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_memberships organization_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_memberships organization_memberships_scim_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_scim_connection_id_fkey FOREIGN KEY (scim_connection_id) REFERENCES public.scim_connections(id);


--
-- Name: organization_memberships organization_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: organization_security_settings organization_security_settings_changed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_security_settings
    ADD CONSTRAINT organization_security_settings_changed_by_user_id_fkey FOREIGN KEY (changed_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: organization_security_settings organization_security_settings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_security_settings
    ADD CONSTRAINT organization_security_settings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: placement_evidence placement_evidence_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placement_evidence
    ADD CONSTRAINT placement_evidence_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: placement_evidence placement_evidence_source_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placement_evidence
    ADD CONSTRAINT placement_evidence_source_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE CASCADE;


--
-- Name: placement_findings placement_findings_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placement_findings
    ADD CONSTRAINT placement_findings_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: power_correlation_samples power_correlation_samples_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_correlation_samples
    ADD CONSTRAINT power_correlation_samples_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: power_correlation_samples power_correlation_samples_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_correlation_samples
    ADD CONSTRAINT power_correlation_samples_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: power_feeds power_feeds_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_feeds
    ADD CONSTRAINT power_feeds_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: power_feeds power_feeds_site_panel_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_feeds
    ADD CONSTRAINT power_feeds_site_panel_fkey FOREIGN KEY (panel_id, organization_id, site_id) REFERENCES public.power_panels(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: power_feeds power_feeds_site_rack_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_feeds
    ADD CONSTRAINT power_feeds_site_rack_fkey FOREIGN KEY (rack_id, organization_id, site_id) REFERENCES public.racks(id, organization_id, site_id) ON DELETE SET NULL (rack_id);


--
-- Name: power_findings power_findings_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_findings
    ADD CONSTRAINT power_findings_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: power_outlets power_outlets_device_inlet_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_outlets
    ADD CONSTRAINT power_outlets_device_inlet_fkey FOREIGN KEY (inlet_port_id, organization_id, resource_id) REFERENCES public.power_ports(id, organization_id, resource_id) ON DELETE SET NULL (inlet_port_id);


--
-- Name: power_outlets power_outlets_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_outlets
    ADD CONSTRAINT power_outlets_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: power_panels power_panels_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_panels
    ADD CONSTRAINT power_panels_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: power_panels power_panels_organization_site_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_panels
    ADD CONSTRAINT power_panels_organization_site_fkey FOREIGN KEY (site_id, organization_id) REFERENCES public.sites(id, organization_id) ON DELETE RESTRICT;


--
-- Name: power_panels power_panels_site_location_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_panels
    ADD CONSTRAINT power_panels_site_location_fkey FOREIGN KEY (location_id, organization_id, site_id) REFERENCES public.locations(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: power_ports power_ports_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_ports
    ADD CONSTRAINT power_ports_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: power_readings power_readings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_readings
    ADD CONSTRAINT power_readings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: power_readings power_readings_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.power_readings
    ADD CONSTRAINT power_readings_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: prefix_vlan_relationships prefix_vlan_relationships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefix_vlan_relationships
    ADD CONSTRAINT prefix_vlan_relationships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: prefix_vlan_relationships prefix_vlan_relationships_tenant_prefix_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefix_vlan_relationships
    ADD CONSTRAINT prefix_vlan_relationships_tenant_prefix_fkey FOREIGN KEY (prefix_id, organization_id) REFERENCES public.prefixes(id, organization_id) ON DELETE CASCADE;


--
-- Name: prefix_vlan_relationships prefix_vlan_relationships_tenant_vlan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefix_vlan_relationships
    ADD CONSTRAINT prefix_vlan_relationships_tenant_vlan_fkey FOREIGN KEY (vlan_id, organization_id) REFERENCES public.vlans(id, organization_id) ON DELETE CASCADE;


--
-- Name: prefixes prefixes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefixes
    ADD CONSTRAINT prefixes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: prefixes prefixes_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefixes
    ADD CONSTRAINT prefixes_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: prefixes prefixes_tenant_vrf_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefixes
    ADD CONSTRAINT prefixes_tenant_vrf_fkey FOREIGN KEY (vrf_id, organization_id) REFERENCES public.vrfs(id, organization_id) ON DELETE RESTRICT;


--
-- Name: rack_occupancies rack_occupancies_placement_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rack_occupancies
    ADD CONSTRAINT rack_occupancies_placement_fkey FOREIGN KEY (current_placement_id, organization_id) REFERENCES public.current_placements(id, organization_id) ON DELETE CASCADE;


--
-- Name: rack_occupancies rack_occupancies_rack_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rack_occupancies
    ADD CONSTRAINT rack_occupancies_rack_fkey FOREIGN KEY (rack_id, organization_id) REFERENCES public.racks(id, organization_id) ON DELETE CASCADE;


--
-- Name: racks racks_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.racks
    ADD CONSTRAINT racks_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: racks racks_organization_site_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.racks
    ADD CONSTRAINT racks_organization_site_fkey FOREIGN KEY (site_id, organization_id) REFERENCES public.sites(id, organization_id) ON DELETE RESTRICT;


--
-- Name: racks racks_site_location_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.racks
    ADD CONSTRAINT racks_site_location_fkey FOREIGN KEY (location_id, organization_id, site_id) REFERENCES public.locations(id, organization_id, site_id) ON DELETE RESTRICT;


--
-- Name: reconciliation_lanes reconciliation_lane_work_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_lanes
    ADD CONSTRAINT reconciliation_lane_work_fkey FOREIGN KEY (work_id, organization_id) REFERENCES public.reconciliation_work(id, organization_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: reconciliation_lanes reconciliation_lanes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_lanes
    ADD CONSTRAINT reconciliation_lanes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: reconciliation_work reconciliation_work_evidence_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_work
    ADD CONSTRAINT reconciliation_work_evidence_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: reconciliation_work reconciliation_work_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_work
    ADD CONSTRAINT reconciliation_work_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_conditions resource_conditions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_conditions
    ADD CONSTRAINT resource_conditions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_conditions resource_conditions_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_conditions
    ADD CONSTRAINT resource_conditions_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_members resource_group_members_added_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_members
    ADD CONSTRAINT resource_group_members_added_by_user_id_fkey FOREIGN KEY (added_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: resource_group_members resource_group_members_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_members
    ADD CONSTRAINT resource_group_members_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_group_members resource_group_members_tenant_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_members
    ADD CONSTRAINT resource_group_members_tenant_group_fkey FOREIGN KEY (group_id, organization_id) REFERENCES public.resource_groups(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_members resource_group_members_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_members
    ADD CONSTRAINT resource_group_members_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_memberships resource_group_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_memberships
    ADD CONSTRAINT resource_group_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_group_memberships resource_group_memberships_tenant_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_memberships
    ADD CONSTRAINT resource_group_memberships_tenant_group_fkey FOREIGN KEY (group_id, organization_id) REFERENCES public.resource_groups(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_memberships resource_group_memberships_tenant_group_set_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_memberships
    ADD CONSTRAINT resource_group_memberships_tenant_group_set_fkey FOREIGN KEY (group_set_id, organization_id) REFERENCES public.resource_group_sets(id, organization_id) ON DELETE SET NULL (group_set_id);


--
-- Name: resource_group_memberships resource_group_memberships_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_memberships
    ADD CONSTRAINT resource_group_memberships_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_sets resource_group_sets_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_sets
    ADD CONSTRAINT resource_group_sets_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_group_suggestion_dismissals resource_group_suggestion_dismissals_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestion_dismissals
    ADD CONSTRAINT resource_group_suggestion_dismissals_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_group_suggestion_dismissals resource_group_suggestion_dismissals_tenant_rule_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestion_dismissals
    ADD CONSTRAINT resource_group_suggestion_dismissals_tenant_rule_fkey FOREIGN KEY (rule_id, organization_id) REFERENCES public.triage_rules(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_suggestion_dismissals resource_group_suggestion_dismissals_tenant_suggestion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestion_dismissals
    ADD CONSTRAINT resource_group_suggestion_dismissals_tenant_suggestion_fkey FOREIGN KEY (suggestion_id, organization_id) REFERENCES public.resource_group_suggestions(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_suggestions resource_group_suggestions_decided_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestions
    ADD CONSTRAINT resource_group_suggestions_decided_by_user_id_fkey FOREIGN KEY (decided_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: resource_group_suggestions resource_group_suggestions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestions
    ADD CONSTRAINT resource_group_suggestions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_group_suggestions resource_group_suggestions_tenant_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestions
    ADD CONSTRAINT resource_group_suggestions_tenant_group_fkey FOREIGN KEY (group_id, organization_id) REFERENCES public.resource_groups(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_suggestions resource_group_suggestions_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestions
    ADD CONSTRAINT resource_group_suggestions_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_group_suggestions resource_group_suggestions_tenant_rule_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group_suggestions
    ADD CONSTRAINT resource_group_suggestions_tenant_rule_fkey FOREIGN KEY (rule_id, organization_id) REFERENCES public.triage_rules(id, organization_id) ON DELETE SET NULL (rule_id);


--
-- Name: resource_groups resource_groups_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_groups
    ADD CONSTRAINT resource_groups_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_groups resource_groups_tenant_group_set_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_groups
    ADD CONSTRAINT resource_groups_tenant_group_set_fkey FOREIGN KEY (group_set_id, organization_id) REFERENCES public.resource_group_sets(id, organization_id) ON DELETE SET NULL (group_set_id);


--
-- Name: resource_identifier_claims resource_identifier_claims_canonical_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifier_claims
    ADD CONSTRAINT resource_identifier_claims_canonical_resource_fkey FOREIGN KEY (resource_identifier_id, organization_id, resource_id) REFERENCES public.resource_identifiers(id, organization_id, resource_id);


--
-- Name: resource_identifier_claims resource_identifier_claims_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifier_claims
    ADD CONSTRAINT resource_identifier_claims_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_identifier_claims resource_identifier_claims_tenant_identifier_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifier_claims
    ADD CONSTRAINT resource_identifier_claims_tenant_identifier_fkey FOREIGN KEY (resource_identifier_id, organization_id) REFERENCES public.resource_identifiers(id, organization_id) ON DELETE SET NULL (resource_identifier_id);


--
-- Name: resource_identifier_claims resource_identifier_claims_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifier_claims
    ADD CONSTRAINT resource_identifier_claims_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: resource_identifier_claims resource_identifier_claims_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifier_claims
    ADD CONSTRAINT resource_identifier_claims_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE SET NULL (resource_id);


--
-- Name: resource_identifier_claims resource_identifier_claims_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifier_claims
    ADD CONSTRAINT resource_identifier_claims_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: resource_identifiers resource_identifiers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifiers
    ADD CONSTRAINT resource_identifiers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_identifiers resource_identifiers_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifiers
    ADD CONSTRAINT resource_identifiers_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_overrides resource_overrides_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_overrides
    ADD CONSTRAINT resource_overrides_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: resource_overrides resource_overrides_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_overrides
    ADD CONSTRAINT resource_overrides_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_overrides resource_overrides_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_overrides
    ADD CONSTRAINT resource_overrides_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_owners resource_owners_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_owners
    ADD CONSTRAINT resource_owners_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_owners resource_owners_tenant_child_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_owners
    ADD CONSTRAINT resource_owners_tenant_child_fkey FOREIGN KEY (child_resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_owners resource_owners_tenant_owner_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_owners
    ADD CONSTRAINT resource_owners_tenant_owner_fkey FOREIGN KEY (owner_resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_relationships resource_relationships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_relationships
    ADD CONSTRAINT resource_relationships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_relationships resource_relationships_tenant_endpoints_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_relationships
    ADD CONSTRAINT resource_relationships_tenant_endpoints_fkey FOREIGN KEY (target_resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_relationships resource_relationships_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_relationships
    ADD CONSTRAINT resource_relationships_tenant_source_fkey FOREIGN KEY (source_resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resource_revisions resource_revisions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_revisions
    ADD CONSTRAINT resource_revisions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_revisions resource_revisions_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_revisions
    ADD CONSTRAINT resource_revisions_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: resources resources_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resources resources_owner_rule_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_owner_rule_fkey FOREIGN KEY (owner_rule_id, organization_id) REFERENCES public.triage_rules(id, organization_id) ON DELETE SET NULL (owner_rule_id);


--
-- Name: resources resources_owner_team_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_owner_team_fkey FOREIGN KEY (owner_team_id, organization_id) REFERENCES public.teams(id, organization_id) ON DELETE SET NULL (owner_team_id);


--
-- Name: role_assignments role_assignments_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments
    ADD CONSTRAINT role_assignments_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: role_assignments role_assignments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments
    ADD CONSTRAINT role_assignments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: role_assignments role_assignments_tenant_membership_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments
    ADD CONSTRAINT role_assignments_tenant_membership_fkey FOREIGN KEY (membership_id, organization_id) REFERENCES public.organization_memberships(id, organization_id) ON DELETE CASCADE;


--
-- Name: role_assignments role_assignments_tenant_role_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments
    ADD CONSTRAINT role_assignments_tenant_role_fkey FOREIGN KEY (role_id, organization_id) REFERENCES public.roles(id, organization_id) ON DELETE CASCADE;


--
-- Name: roles roles_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: saved_views saved_views_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_views
    ADD CONSTRAINT saved_views_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: saved_views saved_views_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_views
    ADD CONSTRAINT saved_views_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: saved_views saved_views_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_views
    ADD CONSTRAINT saved_views_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: scim_connections scim_connections_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_connections
    ADD CONSTRAINT scim_connections_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: scim_connections scim_connections_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_connections
    ADD CONSTRAINT scim_connections_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: scim_connections scim_connections_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_connections
    ADD CONSTRAINT scim_connections_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.identity_providers(id) ON DELETE RESTRICT;


--
-- Name: scim_group_members scim_group_members_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_group_members
    ADD CONSTRAINT scim_group_members_group_fkey FOREIGN KEY (group_id, connection_id) REFERENCES public.scim_groups(id, connection_id) ON DELETE CASCADE;


--
-- Name: scim_group_members scim_group_members_user_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_group_members
    ADD CONSTRAINT scim_group_members_user_fkey FOREIGN KEY (user_id, connection_id) REFERENCES public.scim_users(id, connection_id) ON DELETE CASCADE;


--
-- Name: scim_groups scim_groups_tenant_connection_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_groups
    ADD CONSTRAINT scim_groups_tenant_connection_fkey FOREIGN KEY (connection_id, organization_id) REFERENCES public.scim_connections(id, organization_id) ON DELETE CASCADE;


--
-- Name: scim_tokens scim_tokens_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT scim_tokens_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: scim_tokens scim_tokens_revoked_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT scim_tokens_revoked_by_user_id_fkey FOREIGN KEY (revoked_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: scim_tokens scim_tokens_tenant_connection_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT scim_tokens_tenant_connection_fkey FOREIGN KEY (connection_id, organization_id) REFERENCES public.scim_connections(id, organization_id) ON DELETE CASCADE;


--
-- Name: scim_users scim_users_tenant_connection_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_users
    ADD CONSTRAINT scim_users_tenant_connection_fkey FOREIGN KEY (connection_id, organization_id) REFERENCES public.scim_connections(id, organization_id) ON DELETE CASCADE;


--
-- Name: scim_users scim_users_user_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_users
    ADD CONSTRAINT scim_users_user_identity_id_fkey FOREIGN KEY (user_identity_id) REFERENCES public.user_identities(id) ON DELETE SET NULL;


--
-- Name: site_groups site_groups_organization_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_groups
    ADD CONSTRAINT site_groups_organization_parent_fkey FOREIGN KEY (parent_id, organization_id) REFERENCES public.site_groups(id, organization_id) ON DELETE RESTRICT;


--
-- Name: site_groups site_groups_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_groups
    ADD CONSTRAINT site_groups_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: sites sites_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: sites sites_organization_site_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_organization_site_group_fkey FOREIGN KEY (site_group_id, organization_id) REFERENCES public.site_groups(id, organization_id) ON DELETE RESTRICT;


--
-- Name: source_routing_domain_mappings source_routing_domain_mappings_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_routing_domain_mappings
    ADD CONSTRAINT source_routing_domain_mappings_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: source_routing_domain_mappings source_routing_domain_mappings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_routing_domain_mappings
    ADD CONSTRAINT source_routing_domain_mappings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: source_routing_domain_mappings source_routing_domain_mappings_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_routing_domain_mappings
    ADD CONSTRAINT source_routing_domain_mappings_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: source_routing_domain_mappings source_routing_domain_mappings_tenant_vrf_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_routing_domain_mappings
    ADD CONSTRAINT source_routing_domain_mappings_tenant_vrf_fkey FOREIGN KEY (vrf_id, organization_id) REFERENCES public.vrfs(id, organization_id) ON DELETE CASCADE;


--
-- Name: source_vlan_group_mappings source_vlan_group_mappings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_vlan_group_mappings
    ADD CONSTRAINT source_vlan_group_mappings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: source_vlan_group_mappings source_vlan_group_mappings_tenant_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_vlan_group_mappings
    ADD CONSTRAINT source_vlan_group_mappings_tenant_group_fkey FOREIGN KEY (vlan_group_id, organization_id) REFERENCES public.vlan_groups(id, organization_id) ON DELETE RESTRICT;


--
-- Name: source_vlan_group_mappings source_vlan_group_mappings_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_vlan_group_mappings
    ADD CONSTRAINT source_vlan_group_mappings_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: sources sources_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: sources sources_tenant_agent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_tenant_agent_fkey FOREIGN KEY (agent_id, organization_id) REFERENCES public.agents(id, organization_id);


--
-- Name: sync_runs sync_runs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT sync_runs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: sync_runs sync_runs_organization_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT sync_runs_organization_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE SET NULL (source_id);


--
-- Name: target_bindings target_bindings_approved_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.target_bindings
    ADD CONSTRAINT target_bindings_approved_by_user_id_fkey FOREIGN KEY (approved_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: target_bindings target_bindings_organization_agent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.target_bindings
    ADD CONSTRAINT target_bindings_organization_agent_fkey FOREIGN KEY (agent_id, organization_id) REFERENCES public.agents(id, organization_id) ON DELETE CASCADE;


--
-- Name: target_bindings target_bindings_organization_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.target_bindings
    ADD CONSTRAINT target_bindings_organization_key_fkey FOREIGN KEY (installation_key_id, organization_id) REFERENCES public.installation_keys(id, organization_id) ON DELETE CASCADE;


--
-- Name: target_bindings target_bindings_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.target_bindings
    ADD CONSTRAINT target_bindings_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: target_bindings target_bindings_revoked_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.target_bindings
    ADD CONSTRAINT target_bindings_revoked_by_user_id_fkey FOREIGN KEY (revoked_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: team_memberships team_memberships_added_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT team_memberships_added_by_user_id_fkey FOREIGN KEY (added_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: team_memberships team_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT team_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: team_memberships team_memberships_tenant_membership_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT team_memberships_tenant_membership_fkey FOREIGN KEY (membership_id, organization_id) REFERENCES public.organization_memberships(id, organization_id) ON DELETE CASCADE;


--
-- Name: team_memberships team_memberships_tenant_team_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT team_memberships_tenant_team_fkey FOREIGN KEY (team_id, organization_id) REFERENCES public.teams(id, organization_id) ON DELETE CASCADE;


--
-- Name: teams teams_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: telemetry_batches telemetry_batches_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_batches
    ADD CONSTRAINT telemetry_batches_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: telemetry_batches telemetry_batches_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_batches
    ADD CONSTRAINT telemetry_batches_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE CASCADE;


--
-- Name: telemetry_buckets telemetry_buckets_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_buckets
    ADD CONSTRAINT telemetry_buckets_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: telemetry_marks telemetry_marks_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_marks
    ADD CONSTRAINT telemetry_marks_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: topology_findings_neighbor_storage topology_findings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_findings_neighbor_storage
    ADD CONSTRAINT topology_findings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: topology_findings_neighbor_storage topology_findings_tenant_interface_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_findings_neighbor_storage
    ADD CONSTRAINT topology_findings_tenant_interface_fkey FOREIGN KEY (interface_id, organization_id) REFERENCES public.interfaces(id, organization_id) ON DELETE CASCADE;


--
-- Name: topology_snapshot_events topology_snapshot_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_snapshot_events
    ADD CONSTRAINT topology_snapshot_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: topology_snapshot_events topology_snapshot_events_tenant_observation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_snapshot_events
    ADD CONSTRAINT topology_snapshot_events_tenant_observation_fkey FOREIGN KEY (observation_id, organization_id, source_id) REFERENCES public.observations(id, organization_id, source_id) ON DELETE RESTRICT;


--
-- Name: topology_snapshot_events topology_snapshot_events_tenant_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_snapshot_events
    ADD CONSTRAINT topology_snapshot_events_tenant_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: topology_snapshot_events topology_snapshot_events_tenant_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topology_snapshot_events
    ADD CONSTRAINT topology_snapshot_events_tenant_source_fkey FOREIGN KEY (source_id, organization_id) REFERENCES public.sources(id, organization_id) ON DELETE RESTRICT;


--
-- Name: triage_rules triage_rules_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: triage_rules triage_rules_intake_api_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_intake_api_key_fkey FOREIGN KEY (intake_api_key_id, organization_id) REFERENCES public.intake_api_keys(id, organization_id) ON DELETE CASCADE;


--
-- Name: triage_rules triage_rules_location_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_location_fkey FOREIGN KEY (location_id, organization_id) REFERENCES public.locations(id, organization_id) ON DELETE CASCADE;


--
-- Name: triage_rules triage_rules_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: triage_rules triage_rules_resource_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_resource_group_fkey FOREIGN KEY (resource_group_id, organization_id) REFERENCES public.resource_groups(id, organization_id) ON DELETE CASCADE;


--
-- Name: triage_rules triage_rules_site_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_site_fkey FOREIGN KEY (site_id, organization_id) REFERENCES public.sites(id, organization_id) ON DELETE CASCADE;


--
-- Name: triage_rules triage_rules_team_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.triage_rules
    ADD CONSTRAINT triage_rules_team_fkey FOREIGN KEY (team_id, organization_id) REFERENCES public.teams(id, organization_id) ON DELETE CASCADE;


--
-- Name: user_identities user_identities_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_identities
    ADD CONSTRAINT user_identities_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.identity_providers(id) ON DELETE RESTRICT;


--
-- Name: user_identities user_identities_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_identities
    ADD CONSTRAINT user_identities_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_passkeys user_passkeys_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_passkeys
    ADD CONSTRAINT user_passkeys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_recovery_codes user_recovery_codes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_recovery_codes
    ADD CONSTRAINT user_recovery_codes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_totps user_totps_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_totps
    ADD CONSTRAINT user_totps_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users_tokens users_tokens_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.identity_providers(id) ON DELETE SET NULL;


--
-- Name: users_tokens users_tokens_scoped_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_scoped_organization_id_fkey FOREIGN KEY (scoped_organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: vlan_group_vid_ranges vlan_group_vid_ranges_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlan_group_vid_ranges
    ADD CONSTRAINT vlan_group_vid_ranges_group_fkey FOREIGN KEY (vlan_group_id, organization_id) REFERENCES public.vlan_groups(id, organization_id) ON DELETE CASCADE;


--
-- Name: vlan_groups vlan_groups_organization_location_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlan_groups
    ADD CONSTRAINT vlan_groups_organization_location_fkey FOREIGN KEY (location_id, organization_id) REFERENCES public.locations(id, organization_id) ON DELETE RESTRICT;


--
-- Name: vlan_groups vlan_groups_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlan_groups
    ADD CONSTRAINT vlan_groups_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: vlan_groups vlan_groups_organization_site_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlan_groups
    ADD CONSTRAINT vlan_groups_organization_site_fkey FOREIGN KEY (site_id, organization_id) REFERENCES public.sites(id, organization_id) ON DELETE RESTRICT;


--
-- Name: vlans vlans_organization_group_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlans
    ADD CONSTRAINT vlans_organization_group_fkey FOREIGN KEY (vlan_group_id, organization_id) REFERENCES public.vlan_groups(id, organization_id) ON DELETE RESTRICT;


--
-- Name: vlans vlans_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vlans
    ADD CONSTRAINT vlans_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: vrfs vrfs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vrfs
    ADD CONSTRAINT vrfs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: vrfs vrfs_organization_resource_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vrfs
    ADD CONSTRAINT vrfs_organization_resource_fkey FOREIGN KEY (resource_id, organization_id) REFERENCES public.resources(id, organization_id) ON DELETE CASCADE;


--
-- Name: webauthn_challenges webauthn_challenges_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webauthn_challenges
    ADD CONSTRAINT webauthn_challenges_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict eZy04iMxcqdUFFYiduGPfhnmrMZvGv0Ri6mmBRvIEqWhgMSoFTixBnMC1ohM8JB

INSERT INTO public."schema_migrations" (version) VALUES (20260730221344);
INSERT INTO public."schema_migrations" (version) VALUES (20260730222025);
INSERT INTO public."schema_migrations" (version) VALUES (20260730222922);
INSERT INTO public."schema_migrations" (version) VALUES (20260730223000);
INSERT INTO public."schema_migrations" (version) VALUES (20260730224000);
INSERT INTO public."schema_migrations" (version) VALUES (20260731183310);
INSERT INTO public."schema_migrations" (version) VALUES (20260731183553);
INSERT INTO public."schema_migrations" (version) VALUES (20260731183943);
INSERT INTO public."schema_migrations" (version) VALUES (20260731184550);
INSERT INTO public."schema_migrations" (version) VALUES (20260731231835);
INSERT INTO public."schema_migrations" (version) VALUES (20260807183000);
INSERT INTO public."schema_migrations" (version) VALUES (20260808070000);
INSERT INTO public."schema_migrations" (version) VALUES (20260808110000);
INSERT INTO public."schema_migrations" (version) VALUES (20260813072000);
INSERT INTO public."schema_migrations" (version) VALUES (20260813193000);
INSERT INTO public."schema_migrations" (version) VALUES (20260813210000);
INSERT INTO public."schema_migrations" (version) VALUES (20260825170000);
INSERT INTO public."schema_migrations" (version) VALUES (20260825200000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826100000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826110000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826130000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826140000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826150000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826160000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826170000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826180000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826190000);
INSERT INTO public."schema_migrations" (version) VALUES (20260826200000);
INSERT INTO public."schema_migrations" (version) VALUES (20260903213000);
INSERT INTO public."schema_migrations" (version) VALUES (20260907070000);
INSERT INTO public."schema_migrations" (version) VALUES (20260908090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260908120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260910090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260916120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260928120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261002120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261008120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261009120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261009130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261010120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261010130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261010140000);
INSERT INTO public."schema_migrations" (version) VALUES (20261010150000);
INSERT INTO public."schema_migrations" (version) VALUES (20261011120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261012120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261012130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261013120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261013130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261014120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261015120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261016120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261017120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261018120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261019120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261020120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261021120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261022120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261023120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261024120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261025120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261026120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261027120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261028120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261029120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030131900);
INSERT INTO public."schema_migrations" (version) VALUES (20261030132000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030132100);
INSERT INTO public."schema_migrations" (version) VALUES (20261030132200);
INSERT INTO public."schema_migrations" (version) VALUES (20261030135000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030140000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030140100);
INSERT INTO public."schema_migrations" (version) VALUES (20261030140200);
INSERT INTO public."schema_migrations" (version) VALUES (20261030140300);
INSERT INTO public."schema_migrations" (version) VALUES (20261030150000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030154700);
INSERT INTO public."schema_migrations" (version) VALUES (20261030160300);
INSERT INTO public."schema_migrations" (version) VALUES (20261030162100);
INSERT INTO public."schema_migrations" (version) VALUES (20261030164500);
INSERT INTO public."schema_migrations" (version) VALUES (20261030171500);
INSERT INTO public."schema_migrations" (version) VALUES (20261030172000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030173000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030174000);
INSERT INTO public."schema_migrations" (version) VALUES (20261030180000);
INSERT INTO public."schema_migrations" (version) VALUES (20261031094217);
INSERT INTO public."schema_migrations" (version) VALUES (20261031120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261031120100);
INSERT INTO public."schema_migrations" (version) VALUES (20261101120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261101130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261101130100);
INSERT INTO public."schema_migrations" (version) VALUES (20261101130200);
INSERT INTO public."schema_migrations" (version) VALUES (20261101153700);
INSERT INTO public."schema_migrations" (version) VALUES (20261101153750);
INSERT INTO public."schema_migrations" (version) VALUES (20261101153800);
INSERT INTO public."schema_migrations" (version) VALUES (20261101153900);
INSERT INTO public."schema_migrations" (version) VALUES (20261101190400);
INSERT INTO public."schema_migrations" (version) VALUES (20261101190500);
INSERT INTO public."schema_migrations" (version) VALUES (20261101190600);
INSERT INTO public."schema_migrations" (version) VALUES (20261102093100);
INSERT INTO public."schema_migrations" (version) VALUES (20261102093200);
INSERT INTO public."schema_migrations" (version) VALUES (20261102093300);
INSERT INTO public."schema_migrations" (version) VALUES (20261102093400);
INSERT INTO public."schema_migrations" (version) VALUES (20261102093500);
INSERT INTO public."schema_migrations" (version) VALUES (20261102093600);
INSERT INTO public."schema_migrations" (version) VALUES (20261102094312);
INSERT INTO public."schema_migrations" (version) VALUES (20261102151500);
INSERT INTO public."schema_migrations" (version) VALUES (20261102161700);
INSERT INTO public."schema_migrations" (version) VALUES (20261102161800);
INSERT INTO public."schema_migrations" (version) VALUES (20261102161900);
INSERT INTO public."schema_migrations" (version) VALUES (20261102161950);
INSERT INTO public."schema_migrations" (version) VALUES (20261102162000);
INSERT INTO public."schema_migrations" (version) VALUES (20261102162500);
INSERT INTO public."schema_migrations" (version) VALUES (20261102170000);
INSERT INTO public."schema_migrations" (version) VALUES (20261102173000);
INSERT INTO public."schema_migrations" (version) VALUES (20261102174000);
INSERT INTO public."schema_migrations" (version) VALUES (20261102193715);
INSERT INTO public."schema_migrations" (version) VALUES (20261102193716);
INSERT INTO public."schema_migrations" (version) VALUES (20261102193717);
INSERT INTO public."schema_migrations" (version) VALUES (20261103090000);
INSERT INTO public."schema_migrations" (version) VALUES (20261103100000);
INSERT INTO public."schema_migrations" (version) VALUES (20261104090000);
INSERT INTO public."schema_migrations" (version) VALUES (20261104120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261105090000);
INSERT INTO public."schema_migrations" (version) VALUES (20261105130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261105135900);
INSERT INTO public."schema_migrations" (version) VALUES (20261105140000);
INSERT INTO public."schema_migrations" (version) VALUES (20261106090000);
INSERT INTO public."schema_migrations" (version) VALUES (20261106100000);
INSERT INTO public."schema_migrations" (version) VALUES (20261106110000);
INSERT INTO public."schema_migrations" (version) VALUES (20261106120000);
INSERT INTO public."schema_migrations" (version) VALUES (20261106130000);
INSERT INTO public."schema_migrations" (version) VALUES (20261110120000);
