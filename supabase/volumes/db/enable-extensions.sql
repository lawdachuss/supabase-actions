-- =============================================================================
-- 🚀 Enable ALL Supabase Postgres Extensions
-- =============================================================================
-- This enables every useful extension bundled with the supabase/postgres image.
-- Run on first database initialization (via docker-entrypoint-initdb.d).
-- Safe to re-run: IF NOT EXISTS prevents duplicate errors.
--
-- NOTE: The `extensions` schema is created here because this file runs FIRST
-- (00- prefix) before other init scripts that expect it to exist.
-- Each extension is wrapped in a DO block so missing extensions don't crash
-- the entire initialization process.
-- =============================================================================

-- Create the extensions schema if it doesn't exist (needed by later init scripts)
create schema if not exists extensions;

-- ── Core / Foundation ─────────────────────────────────────────────────────
do $$ begin create extension if not exists "pgcrypto"       with schema extensions; exception when others then raise warning 'pgcrypto not available'; end; $$;
do $$ begin create extension if not exists "uuid-ossp"      with schema extensions; exception when others then raise warning 'uuid-ossp not available'; end; $$;
do $$ begin create extension if not exists "pg_stat_statements" with schema extensions; exception when others then raise warning 'pg_stat_statements not available'; end; $$;
do $$ begin create extension if not exists "pg_stat_monitor"    with schema extensions; exception when others then raise warning 'pg_stat_monitor not available'; end; $$;

-- ── Supabase Ecosystem ────────────────────────────────────────────────────
do $$ begin create extension if not exists "pg_graphql"     with schema extensions; exception when others then raise warning 'pg_graphql not available'; end; $$;
do $$ begin create extension if not exists "vector"         with schema extensions; exception when others then raise warning 'vector not available'; end; $$;
do $$ begin create extension if not exists "pg_cron"        with schema extensions; exception when others then raise warning 'pg_cron not available'; end; $$;
do $$ begin create extension if not exists "pg_net"         with schema extensions; exception when others then raise warning 'pg_net not available'; end; $$;
do $$ begin create extension if not exists "pgmq"           with schema extensions; exception when others then raise warning 'pgmq not available'; end; $$;
do $$ begin create extension if not exists "pg_jsonschema"  with schema extensions; exception when others then raise warning 'pg_jsonschema not available'; end; $$;
do $$ begin create extension if not exists "pgaudit"        with schema extensions; exception when others then raise warning 'pgaudit not available'; end; $$;
do $$ begin create extension if not exists "pgsodium"       with schema extensions; exception when others then raise warning 'pgsodium not available'; end; $$;
do $$ begin create extension if not exists "pgjwt"          with schema extensions; exception when others then raise warning 'pgjwt not available'; end; $$;
do $$ begin create extension if not exists "http"           with schema extensions; exception when others then raise warning 'http not available'; end; $$;
do $$ begin create extension if not exists "pg_hashids"     with schema extensions; exception when others then raise warning 'pg_hashids not available'; end; $$;

-- ── Search & Indexing ─────────────────────────────────────────────────────
do $$ begin create extension if not exists "pgroonga"       with schema extensions; exception when others then raise warning 'pgroonga not available'; end; $$;
do $$ begin create extension if not exists "rum"            with schema extensions; exception when others then raise warning 'rum not available'; end; $$;
do $$ begin create extension if not exists "hypopg"         with schema extensions; exception when others then raise warning 'hypopg not available'; end; $$;
do $$ begin create extension if not exists "index_advisor"  with schema extensions; exception when others then raise warning 'index_advisor not available'; end; $$;

-- ── Geospatial (PostGIS) ───────────────────────────────────────────────────
do $$ begin create extension if not exists "postgis"        with schema extensions; exception when others then raise warning 'postgis not available'; end; $$;
do $$ begin create extension if not exists "postgis_topology" with schema extensions; exception when others then raise warning 'postgis_topology not available'; end; $$;
do $$ begin create extension if not exists "fuzzystrmatch"  with schema extensions; exception when others then raise warning 'fuzzystrmatch not available'; end; $$;
do $$ begin create extension if not exists "pg_trgm"        with schema extensions; exception when others then raise warning 'pg_trgm not available'; end; $$;

-- ── Security & Compliance ──────────────────────────────────────────────────
do $$ begin create extension if not exists "pg_safeupdate"  with schema extensions; exception when others then raise warning 'pg_safeupdate not available'; end; $$;
do $$ begin create extension if not exists "supautils"      with schema extensions; exception when others then raise warning 'supautils not available'; end; $$;
do $$ begin create extension if not exists "anon"           with schema extensions; exception when others then raise warning 'anon not available'; end; $$;

-- ── Developer Tools ───────────────────────────────────────────────────────
do $$ begin create extension if not exists "pgtap"          with schema extensions; exception when others then raise warning 'pgtap not available'; end; $$;
do $$ begin create extension if not exists "plpgsql_check"  with schema extensions; exception when others then raise warning 'plpgsql_check not available'; end; $$;
do $$ begin create extension if not exists "pg_tle"         with schema extensions; exception when others then raise warning 'pg_tle not available'; end; $$;
do $$ begin create extension if not exists "plv8"           with schema extensions; exception when others then raise warning 'plv8 not available'; end; $$;

-- ── Performance & Maintenance ──────────────────────────────────────────────
do $$ begin create extension if not exists "pg_repack"      with schema extensions; exception when others then raise warning 'pg_repack not available'; end; $$;
do $$ begin create extension if not exists "pg_plan_filter" with schema extensions; exception when others then raise warning 'pg_plan_filter not available'; end; $$;

-- ── Data Integration ───────────────────────────────────────────────────────
do $$ begin create extension if not exists "wrappers"       with schema extensions; exception when others then raise warning 'wrappers not available'; end; $$;
do $$ begin create extension if not exists "ogr_fdw"        with schema extensions; exception when others then raise warning 'ogr_fdw not available'; end; $$;
do $$ begin create extension if not exists "mysql_fdw"      with schema extensions; exception when others then raise warning 'mysql_fdw not available'; end; $$;

-- ── Functions & Extras (may or may not be in image) ────────────────────────
do $$ begin create extension if not exists "pg_dbms_stats"  with schema extensions; exception when others then raise warning 'pg_dbms_stats not available'; end; $$;
do $$ begin create extension if not exists "pg_background"  with schema extensions; exception when others then raise warning 'pg_background not available'; end; $$;
do $$ begin create extension if not exists "count_distinct" with schema extensions; exception when others then raise warning 'count_distinct not available'; end; $$;
do $$ begin create extension if not exists "prefix"         with schema extensions; exception when others then raise warning 'prefix not available'; end; $$;

-- =============================================================================
-- 📊 Summary
-- =============================================================================
do $$
declare
    ext_count int;
    ext_list text;
begin
    select count(*), string_agg(extname, ', ' order by extname)
    into ext_count, ext_list
    from pg_extension
    where extnamespace = (select oid from pg_namespace where nspname = 'extensions');
    
    raise notice '✅ Enabled % extensions in schema: %', ext_count, ext_list;
end;
$$;
