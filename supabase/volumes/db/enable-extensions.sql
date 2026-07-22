-- =============================================================================
-- 🚀 Enable ALL Supabase Postgres Extensions
-- =============================================================================
-- This enables every useful extension bundled with the supabase/postgres image.
-- Run on first database initialization (via docker-entrypoint-initdb.d).
-- Safe to re-run: IF NOT EXISTS prevents duplicate errors.
-- =============================================================================

-- ── Core / Foundation ─────────────────────────────────────────────────────
create extension if not exists "pgcrypto"       with schema extensions;    -- Cryptographic functions (gen_random_uuid(), etc.)
create extension if not exists "uuid-ossp"      with schema extensions;    -- UUID generation (uuid_generate_v4())
create extension if not exists "pg_stat_statements" with schema extensions; -- Query performance stats
create extension if not exists "pg_stat_monitor"    with schema extensions; -- Advanced query analytics

-- ── Supabase Ecosystem ────────────────────────────────────────────────────
create extension if not exists "pg_graphql"     with schema extensions;    -- Auto GraphQL API from your schema
create extension if not exists "vector"         with schema extensions;    -- pgvector: AI/embeddings similarity search
create extension if not exists "pg_cron"        with schema extensions;    -- Scheduled cron jobs (e.g. cleanups, reports)
create extension if not exists "pg_net"         with schema extensions;    -- HTTP requests from SQL (webhooks!)
create extension if not exists "pgmq"           with schema extensions;    -- Message queues (job queues, async tasks)
create extension if not exists "pg_jsonschema"  with schema extensions;    -- JSON schema validation for columns
create extension if not exists "pgaudit"        with schema extensions;    -- Database audit logging
create extension if not exists "pgsodium"       with schema extensions;    -- Transparent column encryption
create extension if not exists "pgjwt"          with schema extensions;    -- JWT token generation in SQL
create extension if not exists "http"           with schema extensions;    -- HTTP client (make API calls from SQL)
create extension if not exists "pg_hashids"     with schema extensions;    -- Short unique IDs (YouTube-style)

-- ── Search & Indexing ─────────────────────────────────────────────────────
create extension if not exists "pgroonga"       with schema extensions;    -- Full-text search (faster than plain GIN)
create extension if not exists "rum"            with schema extensions;    -- Efficient full-text search + ordering
create extension if not exists "hypopg"         with schema extensions;    -- Hypothetical indexes (test before creating)
create extension if not exists "index_advisor"  with schema extensions;    -- Index recommendations based on queries

-- ── Geospatial (PostGIS) ───────────────────────────────────────────────────
create extension if not exists "postgis"        with schema extensions;    -- Geospatial queries (locations, maps)
create extension if not exists "postgis_topology" with schema extensions;  -- Advanced topology
create extension if not exists "fuzzystrmatch"  with schema extensions;    -- Fuzzy string matching (spelling mistakes)
create extension if not exists "pg_trgm"        with schema extensions;    -- Trigram text search (autocomplete, fuzzy)

-- ── Security & Compliance ──────────────────────────────────────────────────
create extension if not exists "pg_safeupdate"  with schema extensions;    -- Prevents UPDATE/DELETE without WHERE
create extension if not exists "supautils"      with schema extensions;    -- Supabase security utilities
create extension if not exists "anon"           with schema extensions;    -- Data anonymization

-- ── Developer Tools ───────────────────────────────────────────────────────
create extension if not exists "pgtap"          with schema extensions;    -- Unit testing for SQL
create extension if not exists "plpgsql_check"  with schema extensions;    -- PL/pgSQL linter
create extension if not exists "pg_tle"         with schema extensions;    -- Trusted Language Extensions
create extension if not exists "plv8"           with schema extensions;    -- JavaScript functions in Postgres

-- ── Performance & Maintenance ──────────────────────────────────────────────
create extension if not exists "pg_repack"      with schema extensions;    -- Rebuild tables without locks
create extension if not exists "pg_plan_filter" with schema extensions;    -- Block bad query plans

-- ── Data Integration ───────────────────────────────────────────────────────
create extension if not exists "wrappers"       with schema extensions;    -- Foreign Data Wrappers (connect to Stripe, GitHub, etc.)
create extension if not exists "ogr_fdw"        with schema extensions;    -- GIS data foreign wrapper
create extension if not exists "mysql_fdw"      with schema extensions;    -- Connect to MySQL databases

-- ── Functions & Extras ─────────────────────────────────────────────────────
create extension if not exists "pg_dbms_stats"  with schema extensions;    -- Lock statistics
create extension if not exists "pg_background"  with schema extensions;    -- Run queries in background
create extension if not exists "count_distinct" with schema extensions;    -- Fast distinct count approximations
create extension if not exists "prefix"         with schema extensions;    -- Prefix matching for autocomplete

-- =============================================================================
-- 📊 Verify what's enabled
-- =============================================================================
do $$
declare
    ext_count int;
begin
    select count(*) into ext_count
    from pg_extension
    where extname in (
        'pgcrypto', 'uuid-ossp', 'pg_stat_statements', 'pg_stat_monitor',
        'pg_graphql', 'vector', 'pg_cron', 'pg_net', 'pgmq', 'pg_jsonschema',
        'pgaudit', 'pgsodium', 'pgjwt', 'http', 'pg_hashids',
        'pgroonga', 'rum', 'hypopg', 'index_advisor',
        'postgis', 'postgis_topology', 'fuzzystrmatch', 'pg_trgm',
        'pg_safeupdate', 'supautils', 'anon',
        'pgtap', 'plpgsql_check', 'pg_tle', 'plv8',
        'pg_repack', 'pg_plan_filter',
        'wrappers', 'ogr_fdw', 'mysql_fdw',
        'pg_dbms_stats', 'pg_background', 'count_distinct', 'prefix'
    );
    
    raise notice '✅ Enabled % extensions successfully!', ext_count;
end;
$$;
