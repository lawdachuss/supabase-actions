-- Pin function search paths so callers cannot influence name resolution.
ALTER FUNCTION _supabase.register_access_token(text, text)
  SET search_path = pg_catalog, extensions;
ALTER FUNCTION _supabase.check_token_jti(uuid)
  SET search_path = pg_catalog, extensions;
ALTER FUNCTION _supabase.revoke_token_by_id(uuid)
  SET search_path = pg_catalog, extensions;
ALTER FUNCTION _supabase.list_access_tokens(boolean)
  SET search_path = pg_catalog, extensions;
ALTER FUNCTION public.claim_premium_reward(uuid, integer, integer)
  SET search_path = public, pg_catalog;
ALTER FUNCTION public.custom_access_token_hook(jsonb)
  SET search_path = pg_catalog;

-- This SECURITY DEFINER hook is intended only for the Supabase Auth service.
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb)
  TO supabase_auth_admin;
