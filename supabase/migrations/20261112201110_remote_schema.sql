--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11
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
-- Name: audit; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA audit;


--
-- Name: SCHEMA audit; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA audit IS 'Esquema de auditoría. No se expone vía API (Supabase solo expone "public" por defecto); solo es accesible mediante funciones SECURITY DEFINER o por el rol de servicio.';


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: difficulty_level; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.difficulty_level AS ENUM (
    'easy',
    'medium',
    'hard'
);


--
-- Name: TYPE difficulty_level; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.difficulty_level IS 'Nivel de dificultad de un ejercicio guiado.';


--
-- Name: reminder_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.reminder_status AS ENUM (
    'shown',
    'dismissed',
    'completed',
    'skipped'
);


--
-- Name: TYPE reminder_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.reminder_status IS 'Resultado de un recordatorio de pausa activa al mostrarse.';


--
-- Name: user_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.user_role AS ENUM (
    'patient',
    'professional',
    'admin'
);


--
-- Name: TYPE user_role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.user_role IS 'Rol del usuario dentro de la aplicación.';


--
-- Name: fn_audit_trigger(); Type: FUNCTION; Schema: audit; Owner: -
--

CREATE FUNCTION audit.fn_audit_trigger() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'audit', 'public'
    AS $$
begin
  insert into audit.audit_log (table_name, operation, row_id, changed_by, old_data, new_data)
  values (
    tg_table_name,
    tg_op,
    coalesce((case when tg_op = 'DELETE' then old.id else new.id end), null),
    auth.uid(),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('UPDATE', 'INSERT') then to_jsonb(new) else null end
  );
  return coalesce(new, old);
end;
$$;


--
-- Name: create_usage_events_partition(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_usage_events_partition(for_month date) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  partition_name text := 'usage_events_y' || to_char(for_month, 'YYYY') || 'm' || to_char(for_month, 'MM');
  start_date     date := date_trunc('month', for_month);
  end_date       date := start_date + interval '1 month';
begin
  if not exists (select 1 from pg_class where relname = partition_name) then
    execute format(
      'create table public.%I partition of public.usage_events for values from (%L) to (%L);',
      partition_name, start_date, end_date
    );
  end if;
end;
$$;


--
-- Name: FUNCTION create_usage_events_partition(for_month date); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.create_usage_events_partition(for_month date) IS 'Crea la partición mensual de usage_events para el mes de la fecha dada, si no existe. Programar su llamada mensual (ej. con la extensión pg_cron, disponible en Supabase) con: select public.create_usage_events_partition(current_date + interval ''1 month'');';


--
-- Name: purge_usage_events(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.purge_usage_events(retention_months integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  cutoff      date := date_trunc('month', now()) - (retention_months || ' months')::interval;
  part        record;
begin
  for part in
    select c.relname
    from pg_inherits i
    join pg_class c on c.oid = i.inhrelid
    join pg_class p on p.oid = i.inhparent
    where p.relname = 'usage_events'
      and c.relname <> 'usage_events_default'
      and to_date(substring(c.relname from 'y(\d{4})m\d{2}$') || substring(c.relname from 'y\d{4}m(\d{2})$'), 'YYYYMM') < cutoff
  loop
    execute format('drop table if exists public.%I;', part.relname);
  end loop;
end;
$_$;


--
-- Name: FUNCTION purge_usage_events(retention_months integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.purge_usage_events(retention_months integer) IS 'Elimina particiones mensuales de usage_events más antiguas que retention_months. Implementa la política de retención/archivado de datos de uso (ver CLAUDE.md §6).';


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


--
-- Name: FUNCTION set_updated_at(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.set_updated_at() IS 'Trigger genérico: mantiene updated_at sin duplicar lógica por tabla.';


SET default_table_access_method = heap;

--
-- Name: audit_log; Type: TABLE; Schema: audit; Owner: -
--

CREATE TABLE audit.audit_log (
    id bigint NOT NULL,
    table_name text NOT NULL,
    operation text NOT NULL,
    row_id uuid,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    old_data jsonb,
    new_data jsonb,
    CONSTRAINT audit_log_operation_check CHECK ((operation = ANY (ARRAY['INSERT'::text, 'UPDATE'::text, 'DELETE'::text])))
);


--
-- Name: TABLE audit_log; Type: COMMENT; Schema: audit; Owner: -
--

COMMENT ON TABLE audit.audit_log IS 'Bitácora de auditoría académica: INSERT/UPDATE/DELETE sobre tablas sensibles, con estado anterior/posterior.';


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: audit; Owner: -
--

ALTER TABLE audit.audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME audit.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: content_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_content_categories_slug_format CHECK ((slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text))
);


--
-- Name: content_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_id uuid NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    media_url text,
    source text NOT NULL,
    is_published boolean DEFAULT false NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE content_items; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.content_items IS 'Contenido educativo. "source" es obligatorio: el contenido debe citar evidencia validable.';


--
-- Name: event_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_types (
    id smallint NOT NULL,
    code text NOT NULL,
    description text NOT NULL
);


--
-- Name: usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    event_type_id smallint NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_usage_events_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text))
)
PARTITION BY RANGE (occurred_at);


--
-- Name: TABLE usage_events; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.usage_events IS 'Tabla particionada mensualmente por occurred_at. Ver fn public.create_usage_events_partition() para crear la partición del siguiente mes y fn public.purge_usage_events() para retención.';


--
-- Name: daily_usage_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.daily_usage_summary WITH (security_invoker='true') AS
 SELECT ue.user_id,
    date_trunc('day'::text, ue.occurred_at) AS day,
    et.code AS event_type,
    count(*) AS event_count
   FROM (public.usage_events ue
     JOIN public.event_types et ON ((et.id = ue.event_type_id)))
  GROUP BY ue.user_id, (date_trunc('day'::text, ue.occurred_at)), et.code;


--
-- Name: VIEW daily_usage_summary; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.daily_usage_summary IS 'Agregación diaria de eventos por usuario. security_invoker=true: respeta la RLS de usage_events.';


--
-- Name: event_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.event_types ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.event_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: exercise_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exercise_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    exercise_id uuid NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    perceived_pain smallint,
    CONSTRAINT chk_exercise_sessions_completion_after_start CHECK (((completed_at IS NULL) OR (completed_at >= started_at))),
    CONSTRAINT exercise_sessions_perceived_pain_check CHECK (((perceived_pain >= 0) AND (perceived_pain <= 10)))
);


--
-- Name: exercises; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exercises (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    body_area text NOT NULL,
    difficulty public.difficulty_level DEFAULT 'easy'::public.difficulty_level NOT NULL,
    duration_sec integer NOT NULL,
    media_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT exercises_duration_sec_check CHECK ((duration_sec > 0))
);


--
-- Name: heuristic_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.heuristic_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    description text NOT NULL,
    condition jsonb NOT NULL,
    action jsonb NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_heuristic_rules_action_object CHECK ((jsonb_typeof(action) = 'object'::text)),
    CONSTRAINT chk_heuristic_rules_condition_object CHECK ((jsonb_typeof(condition) = 'object'::text))
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    full_name text,
    birth_date date,
    height_cm numeric(5,2),
    weight_kg numeric(5,2),
    role public.user_role DEFAULT 'patient'::public.user_role NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_profiles_birth_date_past CHECK (((birth_date IS NULL) OR (birth_date <= CURRENT_DATE))),
    CONSTRAINT chk_profiles_height_positive CHECK (((height_cm IS NULL) OR (height_cm > (0)::numeric))),
    CONSTRAINT chk_profiles_weight_positive CHECK (((weight_kg IS NULL) OR (weight_kg > (0)::numeric)))
);


--
-- Name: TABLE profiles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.profiles IS 'Perfil de aplicación de cada usuario autenticado (extiende auth.users).';


--
-- Name: COLUMN profiles.height_cm; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.height_cm IS 'Centímetros. Opcional; usado por el motor de reglas heurísticas.';


--
-- Name: COLUMN profiles.weight_kg; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.weight_kg IS 'Kilogramos. Opcional; usado por el motor de reglas heurísticas.';


--
-- Name: reminder_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reminder_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    triggered_at timestamp with time zone DEFAULT now() NOT NULL,
    status public.reminder_status NOT NULL
);


--
-- Name: reminder_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reminder_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    interval_minutes integer DEFAULT 60 NOT NULL,
    active_from time without time zone DEFAULT '08:00:00'::time without time zone NOT NULL,
    active_to time without time zone DEFAULT '20:00:00'::time without time zone NOT NULL,
    weekdays smallint[] DEFAULT '{1,2,3,4,5}'::smallint[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_reminder_settings_weekdays CHECK (((array_length(weekdays, 1) > 0) AND (weekdays <@ ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint]))),
    CONSTRAINT chk_reminder_settings_window CHECK ((active_from < active_to)),
    CONSTRAINT reminder_settings_interval_minutes_check CHECK ((interval_minutes > 0))
);


--
-- Name: rule_evaluations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rule_evaluations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    rule_id uuid NOT NULL,
    matched boolean NOT NULL,
    evaluated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: usage_events_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events_default (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    event_type_id smallint NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_usage_events_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text))
);


--
-- Name: usage_events_y2026m10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events_y2026m10 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    event_type_id smallint NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_usage_events_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text))
);


--
-- Name: usage_events_y2026m11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events_y2026m11 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    event_type_id smallint NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_usage_events_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text))
);


--
-- Name: usage_events_y2026m12; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events_y2026m12 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    event_type_id smallint NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_usage_events_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text))
);


--
-- Name: usage_events_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events ATTACH PARTITION public.usage_events_default DEFAULT;


--
-- Name: usage_events_y2026m10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events ATTACH PARTITION public.usage_events_y2026m10 FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');


--
-- Name: usage_events_y2026m11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events ATTACH PARTITION public.usage_events_y2026m11 FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');


--
-- Name: usage_events_y2026m12; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events ATTACH PARTITION public.usage_events_y2026m12 FOR VALUES FROM ('2026-12-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: audit; Owner: -
--

ALTER TABLE ONLY audit.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: content_categories content_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_categories
    ADD CONSTRAINT content_categories_pkey PRIMARY KEY (id);


--
-- Name: content_categories content_categories_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_categories
    ADD CONSTRAINT content_categories_slug_key UNIQUE (slug);


--
-- Name: content_items content_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_items
    ADD CONSTRAINT content_items_pkey PRIMARY KEY (id);


--
-- Name: event_types event_types_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_types
    ADD CONSTRAINT event_types_code_key UNIQUE (code);


--
-- Name: event_types event_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_types
    ADD CONSTRAINT event_types_pkey PRIMARY KEY (id);


--
-- Name: exercise_sessions exercise_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exercise_sessions
    ADD CONSTRAINT exercise_sessions_pkey PRIMARY KEY (id);


--
-- Name: exercises exercises_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exercises
    ADD CONSTRAINT exercises_pkey PRIMARY KEY (id);


--
-- Name: heuristic_rules heuristic_rules_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heuristic_rules
    ADD CONSTRAINT heuristic_rules_code_key UNIQUE (code);


--
-- Name: heuristic_rules heuristic_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heuristic_rules
    ADD CONSTRAINT heuristic_rules_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: reminder_logs reminder_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminder_logs
    ADD CONSTRAINT reminder_logs_pkey PRIMARY KEY (id);


--
-- Name: reminder_settings reminder_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminder_settings
    ADD CONSTRAINT reminder_settings_pkey PRIMARY KEY (id);


--
-- Name: rule_evaluations rule_evaluations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_evaluations
    ADD CONSTRAINT rule_evaluations_pkey PRIMARY KEY (id);


--
-- Name: reminder_settings uq_reminder_settings_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminder_settings
    ADD CONSTRAINT uq_reminder_settings_user UNIQUE (user_id);


--
-- Name: usage_events usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT usage_events_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: usage_events_default usage_events_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events_default
    ADD CONSTRAINT usage_events_default_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: usage_events_y2026m10 usage_events_y2026m10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events_y2026m10
    ADD CONSTRAINT usage_events_y2026m10_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: usage_events_y2026m11 usage_events_y2026m11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events_y2026m11
    ADD CONSTRAINT usage_events_y2026m11_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: usage_events_y2026m12 usage_events_y2026m12_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events_y2026m12
    ADD CONSTRAINT usage_events_y2026m12_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: idx_audit_log_table_time; Type: INDEX; Schema: audit; Owner: -
--

CREATE INDEX idx_audit_log_table_time ON audit.audit_log USING btree (table_name, changed_at DESC);


--
-- Name: idx_content_items_category_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_items_category_active ON public.content_items USING btree (category_id) WHERE ((is_published = true) AND (is_deleted = false));


--
-- Name: idx_exercise_sessions_exercise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exercise_sessions_exercise ON public.exercise_sessions USING btree (exercise_id);


--
-- Name: idx_exercise_sessions_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exercise_sessions_user_time ON public.exercise_sessions USING btree (user_id, started_at DESC);


--
-- Name: idx_exercises_body_area; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exercises_body_area ON public.exercises USING btree (body_area);


--
-- Name: idx_heuristic_rules_condition_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_heuristic_rules_condition_gin ON public.heuristic_rules USING gin (condition);


--
-- Name: idx_profiles_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_role ON public.profiles USING btree (role);


--
-- Name: idx_reminder_logs_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reminder_logs_user_time ON public.reminder_logs USING btree (user_id, triggered_at DESC);


--
-- Name: idx_rule_evaluations_rule; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rule_evaluations_rule ON public.rule_evaluations USING btree (rule_id);


--
-- Name: idx_rule_evaluations_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rule_evaluations_user_time ON public.rule_evaluations USING btree (user_id, evaluated_at DESC);


--
-- Name: idx_usage_events_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_events_type ON ONLY public.usage_events USING btree (event_type_id);


--
-- Name: idx_usage_events_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_events_user_time ON ONLY public.usage_events USING btree (user_id, occurred_at DESC);


--
-- Name: usage_events_default_event_type_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_default_event_type_id_idx ON public.usage_events_default USING btree (event_type_id);


--
-- Name: usage_events_default_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_default_user_id_occurred_at_idx ON public.usage_events_default USING btree (user_id, occurred_at DESC);


--
-- Name: usage_events_y2026m10_event_type_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_y2026m10_event_type_id_idx ON public.usage_events_y2026m10 USING btree (event_type_id);


--
-- Name: usage_events_y2026m10_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_y2026m10_user_id_occurred_at_idx ON public.usage_events_y2026m10 USING btree (user_id, occurred_at DESC);


--
-- Name: usage_events_y2026m11_event_type_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_y2026m11_event_type_id_idx ON public.usage_events_y2026m11 USING btree (event_type_id);


--
-- Name: usage_events_y2026m11_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_y2026m11_user_id_occurred_at_idx ON public.usage_events_y2026m11 USING btree (user_id, occurred_at DESC);


--
-- Name: usage_events_y2026m12_event_type_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_y2026m12_event_type_id_idx ON public.usage_events_y2026m12 USING btree (event_type_id);


--
-- Name: usage_events_y2026m12_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_events_y2026m12_user_id_occurred_at_idx ON public.usage_events_y2026m12 USING btree (user_id, occurred_at DESC);


--
-- Name: usage_events_default_event_type_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_type ATTACH PARTITION public.usage_events_default_event_type_id_idx;


--
-- Name: usage_events_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.usage_events_pkey ATTACH PARTITION public.usage_events_default_pkey;


--
-- Name: usage_events_default_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_user_time ATTACH PARTITION public.usage_events_default_user_id_occurred_at_idx;


--
-- Name: usage_events_y2026m10_event_type_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_type ATTACH PARTITION public.usage_events_y2026m10_event_type_id_idx;


--
-- Name: usage_events_y2026m10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.usage_events_pkey ATTACH PARTITION public.usage_events_y2026m10_pkey;


--
-- Name: usage_events_y2026m10_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_user_time ATTACH PARTITION public.usage_events_y2026m10_user_id_occurred_at_idx;


--
-- Name: usage_events_y2026m11_event_type_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_type ATTACH PARTITION public.usage_events_y2026m11_event_type_id_idx;


--
-- Name: usage_events_y2026m11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.usage_events_pkey ATTACH PARTITION public.usage_events_y2026m11_pkey;


--
-- Name: usage_events_y2026m11_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_user_time ATTACH PARTITION public.usage_events_y2026m11_user_id_occurred_at_idx;


--
-- Name: usage_events_y2026m12_event_type_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_type ATTACH PARTITION public.usage_events_y2026m12_event_type_id_idx;


--
-- Name: usage_events_y2026m12_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.usage_events_pkey ATTACH PARTITION public.usage_events_y2026m12_pkey;


--
-- Name: usage_events_y2026m12_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_usage_events_user_time ATTACH PARTITION public.usage_events_y2026m12_user_id_occurred_at_idx;


--
-- Name: exercise_sessions trg_audit_exercise_sessions; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_exercise_sessions AFTER INSERT OR DELETE OR UPDATE ON public.exercise_sessions FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_trigger();


--
-- Name: heuristic_rules trg_audit_heuristic_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_heuristic_rules AFTER INSERT OR DELETE OR UPDATE ON public.heuristic_rules FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_trigger();


--
-- Name: profiles trg_audit_profiles; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_profiles AFTER INSERT OR DELETE OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_trigger();


--
-- Name: rule_evaluations trg_audit_rule_evaluations; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_rule_evaluations AFTER INSERT OR DELETE OR UPDATE ON public.rule_evaluations FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_trigger();


--
-- Name: content_items trg_content_items_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_content_items_updated_at BEFORE UPDATE ON public.content_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: exercises trg_exercises_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_exercises_updated_at BEFORE UPDATE ON public.exercises FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: profiles trg_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: reminder_settings trg_reminder_settings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reminder_settings_updated_at BEFORE UPDATE ON public.reminder_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: content_items content_items_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_items
    ADD CONSTRAINT content_items_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.content_categories(id) ON DELETE RESTRICT;


--
-- Name: content_items content_items_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_items
    ADD CONSTRAINT content_items_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: exercise_sessions exercise_sessions_exercise_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exercise_sessions
    ADD CONSTRAINT exercise_sessions_exercise_id_fkey FOREIGN KEY (exercise_id) REFERENCES public.exercises(id) ON DELETE RESTRICT;


--
-- Name: exercise_sessions exercise_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exercise_sessions
    ADD CONSTRAINT exercise_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: reminder_logs reminder_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminder_logs
    ADD CONSTRAINT reminder_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: reminder_settings reminder_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminder_settings
    ADD CONSTRAINT reminder_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: rule_evaluations rule_evaluations_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_evaluations
    ADD CONSTRAINT rule_evaluations_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.heuristic_rules(id) ON DELETE CASCADE;


--
-- Name: rule_evaluations rule_evaluations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_evaluations
    ADD CONSTRAINT rule_evaluations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: usage_events usage_events_event_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.usage_events
    ADD CONSTRAINT usage_events_event_type_id_fkey FOREIGN KEY (event_type_id) REFERENCES public.event_types(id) ON DELETE RESTRICT;


--
-- Name: usage_events usage_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.usage_events
    ADD CONSTRAINT usage_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: audit_log; Type: ROW SECURITY; Schema: audit; Owner: -
--

ALTER TABLE audit.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: content_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.content_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: content_categories content_categories_read_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY content_categories_read_all ON public.content_categories FOR SELECT USING (true);


--
-- Name: content_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.content_items ENABLE ROW LEVEL SECURITY;

--
-- Name: content_items content_items_manage_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY content_items_manage_own ON public.content_items USING ((( SELECT auth.uid() AS uid) = created_by)) WITH CHECK ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: content_items content_items_read_published; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY content_items_read_published ON public.content_items FOR SELECT USING (((is_published = true) AND (is_deleted = false)));


--
-- Name: event_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.event_types ENABLE ROW LEVEL SECURITY;

--
-- Name: event_types event_types_read_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY event_types_read_all ON public.event_types FOR SELECT USING (true);


--
-- Name: exercise_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.exercise_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: exercise_sessions exercise_sessions_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY exercise_sessions_own ON public.exercise_sessions USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: exercises; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.exercises ENABLE ROW LEVEL SECURITY;

--
-- Name: exercises exercises_read_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY exercises_read_all ON public.exercises FOR SELECT USING (true);


--
-- Name: heuristic_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.heuristic_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: heuristic_rules heuristic_rules_read_active; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY heuristic_rules_read_active ON public.heuristic_rules FOR SELECT USING ((is_active = true));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: reminder_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reminder_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: reminder_logs reminder_logs_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reminder_logs_own ON public.reminder_logs USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: reminder_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reminder_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: reminder_settings reminder_settings_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reminder_settings_own ON public.reminder_settings USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: rule_evaluations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rule_evaluations ENABLE ROW LEVEL SECURITY;

--
-- Name: rule_evaluations rule_evaluations_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rule_evaluations_own ON public.rule_evaluations USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: usage_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;

--
-- Name: usage_events_default; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.usage_events_default ENABLE ROW LEVEL SECURITY;

--
-- Name: usage_events usage_events_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY usage_events_own ON public.usage_events USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: usage_events_y2026m10; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.usage_events_y2026m10 ENABLE ROW LEVEL SECURITY;

--
-- Name: usage_events_y2026m11; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.usage_events_y2026m11 ENABLE ROW LEVEL SECURITY;

--
-- Name: usage_events_y2026m12; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.usage_events_y2026m12 ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION create_usage_events_partition(for_month date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_usage_events_partition(for_month date) TO anon;
GRANT ALL ON FUNCTION public.create_usage_events_partition(for_month date) TO authenticated;
GRANT ALL ON FUNCTION public.create_usage_events_partition(for_month date) TO service_role;


--
-- Name: FUNCTION purge_usage_events(retention_months integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.purge_usage_events(retention_months integer) TO anon;
GRANT ALL ON FUNCTION public.purge_usage_events(retention_months integer) TO authenticated;
GRANT ALL ON FUNCTION public.purge_usage_events(retention_months integer) TO service_role;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_updated_at() TO anon;
GRANT ALL ON FUNCTION public.set_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: TABLE content_categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.content_categories TO anon;
GRANT ALL ON TABLE public.content_categories TO authenticated;
GRANT ALL ON TABLE public.content_categories TO service_role;


--
-- Name: TABLE content_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.content_items TO anon;
GRANT ALL ON TABLE public.content_items TO authenticated;
GRANT ALL ON TABLE public.content_items TO service_role;


--
-- Name: TABLE event_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.event_types TO anon;
GRANT ALL ON TABLE public.event_types TO authenticated;
GRANT ALL ON TABLE public.event_types TO service_role;


--
-- Name: TABLE usage_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.usage_events TO anon;
GRANT ALL ON TABLE public.usage_events TO authenticated;
GRANT ALL ON TABLE public.usage_events TO service_role;


--
-- Name: TABLE daily_usage_summary; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_usage_summary TO anon;
GRANT ALL ON TABLE public.daily_usage_summary TO authenticated;
GRANT ALL ON TABLE public.daily_usage_summary TO service_role;


--
-- Name: SEQUENCE event_types_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.event_types_id_seq TO anon;
GRANT ALL ON SEQUENCE public.event_types_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.event_types_id_seq TO service_role;


--
-- Name: TABLE exercise_sessions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.exercise_sessions TO anon;
GRANT ALL ON TABLE public.exercise_sessions TO authenticated;
GRANT ALL ON TABLE public.exercise_sessions TO service_role;


--
-- Name: TABLE exercises; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.exercises TO anon;
GRANT ALL ON TABLE public.exercises TO authenticated;
GRANT ALL ON TABLE public.exercises TO service_role;


--
-- Name: TABLE heuristic_rules; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.heuristic_rules TO anon;
GRANT ALL ON TABLE public.heuristic_rules TO authenticated;
GRANT ALL ON TABLE public.heuristic_rules TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO anon;
GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;


--
-- Name: TABLE reminder_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.reminder_logs TO anon;
GRANT ALL ON TABLE public.reminder_logs TO authenticated;
GRANT ALL ON TABLE public.reminder_logs TO service_role;


--
-- Name: TABLE reminder_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.reminder_settings TO anon;
GRANT ALL ON TABLE public.reminder_settings TO authenticated;
GRANT ALL ON TABLE public.reminder_settings TO service_role;


--
-- Name: TABLE rule_evaluations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.rule_evaluations TO anon;
GRANT ALL ON TABLE public.rule_evaluations TO authenticated;
GRANT ALL ON TABLE public.rule_evaluations TO service_role;


--
-- Name: TABLE usage_events_default; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.usage_events_default TO anon;
GRANT ALL ON TABLE public.usage_events_default TO authenticated;
GRANT ALL ON TABLE public.usage_events_default TO service_role;


--
-- Name: TABLE usage_events_y2026m10; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.usage_events_y2026m10 TO anon;
GRANT ALL ON TABLE public.usage_events_y2026m10 TO authenticated;
GRANT ALL ON TABLE public.usage_events_y2026m10 TO service_role;


--
-- Name: TABLE usage_events_y2026m11; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.usage_events_y2026m11 TO anon;
GRANT ALL ON TABLE public.usage_events_y2026m11 TO authenticated;
GRANT ALL ON TABLE public.usage_events_y2026m11 TO service_role;


--
-- Name: TABLE usage_events_y2026m12; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.usage_events_y2026m12 TO anon;
GRANT ALL ON TABLE public.usage_events_y2026m12 TO authenticated;
GRANT ALL ON TABLE public.usage_events_y2026m12 TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--


