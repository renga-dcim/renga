--
-- PostgreSQL database dump
--

\restrict Z2gGM93CfXo8WOz0GHgtMkkJ6LE8vD8k8fNtdRg6h1dmjS1EiuDp6OlYH9bDyF4

-- Dumped from database version 18.4
-- Dumped by pg_dump version 18.4

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
-- Name: enforce_catalog_type_revision_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_catalog_type_revision_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
      RETURN OLD;
    END IF;
  ELSIF OLD.finalized_at IS NULL
        AND NEW.finalized_at IS NOT NULL
        AND (to_jsonb(NEW) - 'finalized_at') = (to_jsonb(OLD) - 'finalized_at') THEN
    RETURN NEW;
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
-- Name: reject_observation_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_observation_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
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


SET default_tablespace = '';

SET default_table_access_method = heap;

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
    CONSTRAINT agents_metadata_size CHECK ((octet_length((metadata)::text) <= 16000))
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
    updated_at timestamp(3) without time zone NOT NULL
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
-- Name: desired_module_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.desired_module_assignments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    module_bay_id uuid NOT NULL,
    module_type_id uuid NOT NULL,
    confirmed_by_user_id uuid NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
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
    confirmed_by_user_id uuid NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
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
    updated_at timestamp(3) without time zone NOT NULL
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
    updated_at timestamp(3) without time zone NOT NULL
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
    inserted_at timestamp(3) without time zone NOT NULL
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
    updated_at timestamp(3) without time zone NOT NULL
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
-- Name: prefixes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prefixes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    prefix cidr NOT NULL,
    vrf character varying(255),
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
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
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
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
    updated_at timestamp(3) without time zone NOT NULL
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
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email public.citext NOT NULL,
    hashed_password character varying(255),
    confirmed_at timestamp(3) without time zone,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
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
    inserted_at timestamp(3) without time zone NOT NULL
);


--
-- Name: module_installation_events sequence; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_installation_events ALTER COLUMN sequence SET DEFAULT nextval('public.module_installation_events_sequence_seq'::regclass);


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
-- Name: addresses addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_pkey PRIMARY KEY (id);


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
-- Name: organization_memberships organization_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_pkey PRIMARY KEY (id);


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
-- Name: resource_conditions resource_conditions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_conditions
    ADD CONSTRAINT resource_conditions_pkey PRIMARY KEY (id);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


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
-- Name: actual_component_evidence_matches_component_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX actual_component_evidence_matches_component_index ON public.actual_component_evidence_matches USING btree (organization_id, owner_resource_id, actual_component_id);


--
-- Name: actual_component_evidence_matches_evidence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX actual_component_evidence_matches_evidence_index ON public.actual_component_evidence_matches USING btree (component_evidence_id);


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

CREATE UNIQUE INDEX address_evidence_observation_link_index ON public.address_evidence USING btree (organization_id, observation_id, address_id);


--
-- Name: address_evidence_organization_id_source_id_address_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX address_evidence_organization_id_source_id_address_id_index ON public.address_evidence USING btree (organization_id, source_id, address_id);


--
-- Name: addresses_id_organization_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX addresses_id_organization_id_index ON public.addresses USING btree (id, organization_id);


--
-- Name: addresses_organization_id_interface_id_address_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX addresses_organization_id_interface_id_address_index ON public.addresses USING btree (organization_id, interface_id, address);


--
-- Name: addresses_organization_id_interface_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX addresses_organization_id_interface_id_index ON public.addresses USING btree (organization_id, interface_id);


--
-- Name: addresses_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX addresses_organization_id_resource_id_index ON public.addresses USING btree (organization_id, resource_id);


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
-- Name: organization_memberships_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_organization_id_status_index ON public.organization_memberships USING btree (organization_id, status);


--
-- Name: organization_memberships_organization_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_memberships_organization_id_user_id_index ON public.organization_memberships USING btree (organization_id, user_id);


--
-- Name: organization_memberships_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_user_id_index ON public.organization_memberships USING btree (user_id);


--
-- Name: organizations_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organizations_slug_index ON public.organizations USING btree (slug);


--
-- Name: organizations_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organizations_status_index ON public.organizations USING btree (status);


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
-- Name: prefixes_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX prefixes_organization_id_resource_id_index ON public.prefixes USING btree (organization_id, resource_id);


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
-- Name: resource_conditions_organization_id_resource_id_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_conditions_organization_id_resource_id_type_index ON public.resource_conditions USING btree (organization_id, resource_id, type);


--
-- Name: resource_conditions_organization_id_type_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_conditions_organization_id_type_status_index ON public.resource_conditions USING btree (organization_id, type, status);


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
-- Name: resources_organization_id_resource_version_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_resource_version_index ON public.resources USING btree (organization_id, resource_version);


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
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_tokens_context_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_tokens_context_token_index ON public.users_tokens USING btree (context, token);


--
-- Name: users_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_tokens_user_id_index ON public.users_tokens USING btree (user_id);


--
-- Name: catalog_type_revisions catalog_type_revisions_enforce_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER catalog_type_revisions_enforce_immutability BEFORE DELETE OR UPDATE ON public.catalog_type_revisions FOR EACH ROW EXECUTE FUNCTION public.enforce_catalog_type_revision_immutability();


--
-- Name: component_templates component_templates_enforce_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER component_templates_enforce_immutability BEFORE INSERT OR DELETE OR UPDATE ON public.component_templates FOR EACH ROW EXECUTE FUNCTION public.enforce_component_template_immutability();


--
-- Name: observations observations_reject_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER observations_reject_update BEFORE UPDATE ON public.observations FOR EACH ROW EXECUTE FUNCTION public.reject_observation_update();


--
-- Name: resources resources_enforce_kind_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resources_enforce_kind_immutability BEFORE UPDATE OF kind ON public.resources FOR EACH ROW EXECUTE FUNCTION public.enforce_resource_kind_immutability();


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
-- Name: observations observations_source_sync_run_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_source_sync_run_fkey FOREIGN KEY (sync_run_id, organization_id, source_id) REFERENCES public.sync_runs(id, organization_id, source_id) ON DELETE SET NULL (sync_run_id);


--
-- Name: organization_memberships organization_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_memberships organization_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


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
-- Name: sources sources_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


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
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict Z2gGM93CfXo8WOz0GHgtMkkJ6LE8vD8k8fNtdRg6h1dmjS1EiuDp6OlYH9bDyF4

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
