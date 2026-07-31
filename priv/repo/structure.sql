--
-- PostgreSQL database dump
--

\restrict a8is3vAyMpjH2eqiQMKd0ZKRPY83xuQheWBFVchLQjAYh2SfmpR8G4N1T6Yxbv7

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
-- Name: sources sources_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict a8is3vAyMpjH2eqiQMKd0ZKRPY83xuQheWBFVchLQjAYh2SfmpR8G4N1T6Yxbv7

INSERT INTO public."schema_migrations" (version) VALUES (20260730221344);
INSERT INTO public."schema_migrations" (version) VALUES (20260730222025);
INSERT INTO public."schema_migrations" (version) VALUES (20260730222922);
INSERT INTO public."schema_migrations" (version) VALUES (20260730223000);
INSERT INTO public."schema_migrations" (version) VALUES (20260730224000);
