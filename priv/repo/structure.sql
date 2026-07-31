--
-- PostgreSQL database dump
--

\restrict TPHlgPwoBwAoFOQrH8YtkFVdoSXRcE4WUgOKDqELNE916kx47d0EhI0eXWLlJKH

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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.addresses (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    interface_id uuid NOT NULL,
    source_id uuid,
    kind character varying(255) NOT NULL,
    address inet NOT NULL,
    scope character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    first_seen_at timestamp(0) without time zone,
    last_seen_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
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
    occurred_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: interfaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interfaces (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    source_id uuid,
    name character varying(255) NOT NULL,
    mac_address macaddr,
    kind character varying(255) DEFAULT 'ethernet'::character varying NOT NULL,
    status character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    mtu integer,
    speed_mbps integer,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    first_seen_at timestamp(0) without time zone,
    last_seen_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.observations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid,
    sync_run_id uuid,
    resource_id uuid,
    observation_id character varying(255),
    observed_at timestamp(0) without time zone NOT NULL,
    status character varying(255) DEFAULT 'accepted'::character varying NOT NULL,
    payload_digest bytea NOT NULL,
    payload jsonb NOT NULL,
    errors jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
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
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
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
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: resource_identifiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_identifiers (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    source_id uuid,
    kind character varying(255) NOT NULL,
    value character varying(255) NOT NULL,
    confidence integer DEFAULT 100 NOT NULL,
    first_seen_at timestamp(0) without time zone,
    last_seen_at timestamp(0) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
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
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resources (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    external_id character varying(255),
    serial_number character varying(255),
    asset_tag character varying(255),
    hostname character varying(255),
    fqdn character varying(255),
    vendor character varying(255),
    model character varying(255),
    status character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    first_seen_at timestamp(0) without time zone,
    last_seen_at timestamp(0) without time zone,
    last_changed_at timestamp(0) without time zone,
    stale_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
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
    token_hash bytea,
    capabilities character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    last_seen_at timestamp(0) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: sync_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_runs (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid,
    status character varying(255) DEFAULT 'running'::character varying NOT NULL,
    started_at timestamp(0) without time zone NOT NULL,
    completed_at timestamp(0) without time zone,
    resource_count integer DEFAULT 0 NOT NULL,
    error_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email public.citext NOT NULL,
    hashed_password character varying(255),
    confirmed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
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
    authenticated_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: addresses addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_pkey PRIMARY KEY (id);


--
-- Name: change_events change_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_pkey PRIMARY KEY (id);


--
-- Name: interfaces interfaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interfaces
    ADD CONSTRAINT interfaces_pkey PRIMARY KEY (id);


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
-- Name: addresses_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX addresses_organization_id_source_id_index ON public.addresses USING btree (organization_id, source_id);


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
-- Name: interfaces_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interfaces_organization_id_source_id_index ON public.interfaces USING btree (organization_id, source_id);


--
-- Name: observations_organization_id_observed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observations_organization_id_observed_at_index ON public.observations USING btree (organization_id, observed_at);


--
-- Name: observations_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observations_organization_id_resource_id_index ON public.observations USING btree (organization_id, resource_id);


--
-- Name: observations_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observations_organization_id_source_id_index ON public.observations USING btree (organization_id, source_id);


--
-- Name: observations_organization_id_source_id_observation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX observations_organization_id_source_id_observation_id_index ON public.observations USING btree (organization_id, source_id, observation_id) WHERE ((source_id IS NOT NULL) AND (observation_id IS NOT NULL));


--
-- Name: observations_organization_id_source_id_payload_digest_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX observations_organization_id_source_id_payload_digest_index ON public.observations USING btree (organization_id, source_id, payload_digest) WHERE (source_id IS NOT NULL);


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
-- Name: resource_identifiers_organization_id_kind_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifiers_organization_id_kind_value_index ON public.resource_identifiers USING btree (organization_id, kind, value);


--
-- Name: resource_identifiers_organization_id_resource_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifiers_organization_id_resource_id_index ON public.resource_identifiers USING btree (organization_id, resource_id);


--
-- Name: resource_identifiers_organization_id_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_identifiers_organization_id_source_id_index ON public.resource_identifiers USING btree (organization_id, source_id);


--
-- Name: resource_identifiers_organization_id_source_id_kind_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_identifiers_organization_id_source_id_kind_value_index ON public.resource_identifiers USING btree (organization_id, source_id, kind, value) WHERE (source_id IS NOT NULL);


--
-- Name: resource_identifiers_resource_kind_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_identifiers_resource_kind_value_index ON public.resource_identifiers USING btree (organization_id, resource_id, kind, value);


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
-- Name: resources_organization_id_asset_tag_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resources_organization_id_asset_tag_index ON public.resources USING btree (organization_id, asset_tag) WHERE (asset_tag IS NOT NULL);


--
-- Name: resources_organization_id_external_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resources_organization_id_external_id_index ON public.resources USING btree (organization_id, external_id) WHERE (external_id IS NOT NULL);


--
-- Name: resources_organization_id_fqdn_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_fqdn_index ON public.resources USING btree (organization_id, fqdn);


--
-- Name: resources_organization_id_hostname_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_hostname_index ON public.resources USING btree (organization_id, hostname);


--
-- Name: resources_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_kind_index ON public.resources USING btree (organization_id, kind);


--
-- Name: resources_organization_id_last_seen_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_last_seen_at_index ON public.resources USING btree (organization_id, last_seen_at);


--
-- Name: resources_organization_id_serial_number_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resources_organization_id_serial_number_index ON public.resources USING btree (organization_id, serial_number) WHERE (serial_number IS NOT NULL);


--
-- Name: resources_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resources_organization_id_status_index ON public.resources USING btree (organization_id, status);


--
-- Name: sources_organization_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sources_organization_id_kind_index ON public.sources USING btree (organization_id, kind);


--
-- Name: sources_organization_id_last_seen_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sources_organization_id_last_seen_at_index ON public.sources USING btree (organization_id, last_seen_at);


--
-- Name: sources_organization_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sources_organization_id_name_index ON public.sources USING btree (organization_id, name);


--
-- Name: sources_organization_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sources_organization_id_status_index ON public.sources USING btree (organization_id, status);


--
-- Name: sources_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sources_token_hash_index ON public.sources USING btree (token_hash) WHERE (token_hash IS NOT NULL);


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
-- Name: addresses addresses_interface_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_interface_id_fkey FOREIGN KEY (interface_id) REFERENCES public.interfaces(id) ON DELETE CASCADE;


--
-- Name: addresses addresses_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: addresses addresses_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(id) ON DELETE CASCADE;


--
-- Name: addresses addresses_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: change_events change_events_observation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_observation_id_fkey FOREIGN KEY (observation_id) REFERENCES public.observations(id) ON DELETE SET NULL;


--
-- Name: change_events change_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: change_events change_events_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(id) ON DELETE SET NULL;


--
-- Name: change_events change_events_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: change_events change_events_sync_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.change_events
    ADD CONSTRAINT change_events_sync_run_id_fkey FOREIGN KEY (sync_run_id) REFERENCES public.sync_runs(id) ON DELETE SET NULL;


--
-- Name: interfaces interfaces_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interfaces
    ADD CONSTRAINT interfaces_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: interfaces interfaces_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interfaces
    ADD CONSTRAINT interfaces_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(id) ON DELETE CASCADE;


--
-- Name: interfaces interfaces_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interfaces
    ADD CONSTRAINT interfaces_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: observations observations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: observations observations_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(id) ON DELETE SET NULL;


--
-- Name: observations observations_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: observations observations_sync_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_sync_run_id_fkey FOREIGN KEY (sync_run_id) REFERENCES public.sync_runs(id) ON DELETE SET NULL;


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
-- Name: resource_identifiers resource_identifiers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifiers
    ADD CONSTRAINT resource_identifiers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_identifiers resource_identifiers_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifiers
    ADD CONSTRAINT resource_identifiers_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(id) ON DELETE CASCADE;


--
-- Name: resource_identifiers resource_identifiers_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_identifiers
    ADD CONSTRAINT resource_identifiers_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


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
-- Name: resource_overrides resource_overrides_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_overrides
    ADD CONSTRAINT resource_overrides_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(id) ON DELETE CASCADE;


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
-- Name: sync_runs sync_runs_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT sync_runs_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict TPHlgPwoBwAoFOQrH8YtkFVdoSXRcE4WUgOKDqELNE916kx47d0EhI0eXWLlJKH

INSERT INTO public."schema_migrations" (version) VALUES (20260730221344);
INSERT INTO public."schema_migrations" (version) VALUES (20260730222025);
INSERT INTO public."schema_migrations" (version) VALUES (20260730222922);
INSERT INTO public."schema_migrations" (version) VALUES (20260730223000);
INSERT INTO public."schema_migrations" (version) VALUES (20260730224000);
INSERT INTO public."schema_migrations" (version) VALUES (20260731183310);
INSERT INTO public."schema_migrations" (version) VALUES (20260731183553);
INSERT INTO public."schema_migrations" (version) VALUES (20260731183943);
INSERT INTO public."schema_migrations" (version) VALUES (20260731184550);
