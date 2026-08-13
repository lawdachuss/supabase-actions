-- pgvector: vector similarity search for embeddings (AI features)
-- Installed into the extensions schema like Supabase Cloud, so columns use
-- the `vector` type via `extensions.vector` or after `set search_path`.
--
-- Runs only when the database is created fresh (docker-entrypoint-initdb.d).
-- On restored databases the extension is carried by the state backup instead.
do $$
begin
  begin
    create extension if not exists vector with schema extensions;
    raise notice 'pgvector enabled';
  exception when others then
    raise notice 'pgvector unavailable in this image: %', sqlerrm;
  end;
end $$;
