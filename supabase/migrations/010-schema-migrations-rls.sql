ALTER TABLE public._schema_migrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public._schema_migrations FROM PUBLIC, anon, authenticated;
