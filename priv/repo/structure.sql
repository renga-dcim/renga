--
-- PostgreSQL database dump
--

\restrict 7R2HcTx5lHoek4odrWGINi2QMsDB26Fe0KPDa0KL8NYLDCAmGbHl7kxcDPV3ozm

-- Dumped from database version 17.10
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
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


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
    CONSTRAINT interface_evidence_mtu_speed_positive CHECK ((((mtu IS NULL) OR (mtu > 0)) AND ((speed_mbps IS NULL) OR (speed_mbps > 0))))
);


--
-- Name: interface_relationship_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interface_relationship_evidence (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    interface_relationship_id uuid NOT NULL,
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
-- Name: change_events change_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_pkey PRIMARY KEY (id);


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
-- Name: prefixes prefixes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prefixes
    ADD CONSTRAINT prefixes_pkey PRIMARY KEY (id);


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
-- Name: prefixes_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX prefixes_organization_id_resource_id_index ON public.prefixes USING btree (organization_id, resource_id);


--
-- Name: prefixes_prefix_gist_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX prefixes_prefix_gist_index ON public.prefixes USING gist (prefix inet_ops);


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
-- Name: observations observations_reject_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER observations_reject_update BEFORE UPDATE ON public.observations FOR EACH ROW EXECUTE FUNCTION public.reject_observation_update();


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

\unrestrict 7R2HcTx5lHoek4odrWGINi2QMsDB26Fe0KPDa0KL8NYLDCAmGbHl7kxcDPV3ozm

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
