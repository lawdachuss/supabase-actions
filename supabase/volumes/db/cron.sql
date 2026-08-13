-- pg_cron: scheduled SQL jobs (cleanup, maintenance, nightly reports)
-- Usage: select cron.schedule('job-name', '0 3 * * *', $$ <sql> $$);
--
-- Runs only when the database is created fresh (docker-entrypoint-initdb.d).
-- NOTE: pg_cron needs shared_preload_libraries to run its worker; the
-- supabase/postgres image ships it preloaded. If the extension is missing,
-- the error is caught and the DB boots anyway.
--
-- IMPORTANT: cron job definitions live in the DB and are restored from the
-- state backup, but re-adding them via a committed migration (supabase/migrations/)
-- is the reliable way to keep them across sessions.
do $$
begin
  begin
    create extension if not exists pg_cron;
    raise notice 'pg_cron enabled';
  exception when others then
    raise notice 'pg_cron unavailable in this image: %', sqlerrm;
  end;
end $$;
