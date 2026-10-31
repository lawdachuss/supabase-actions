-- Keep API permissions opt-in for objects created by postgres in public.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Internal data tables: client access is limited to authenticated owners;
-- service_role access remains server-side and explicit.
REVOKE ALL ON TABLE public.user_premium, public.premium_purchases
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.user_premium, public.premium_purchases
  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_premium, public.premium_purchases
  TO service_role;

-- Site settings are intentionally readable by clients, but writable only by
-- trusted server-side code.
REVOKE ALL ON TABLE public.site_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.site_settings TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.site_settings TO service_role;

-- Owner-scoped client data; anonymous API callers have no table privileges.
REVOKE ALL ON TABLE public.performer_follows,
  public.user_notifications,
  public.user_notification_preferences
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.performer_follows,
  public.user_notifications,
  public.user_notification_preferences
  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.performer_follows,
  public.user_notifications,
  public.user_notification_preferences
  TO service_role;

-- Neither client roles nor service_role should access internal cache/tracking
-- tables through the Data API. RLS remains enabled as an additional boundary.
REVOKE ALL ON TABLE public.edge_cache, public._schema_migrations
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.edge_cache TO service_role;

-- These RPCs mutate rows using caller-supplied identifiers. The application
-- routes them through trusted server-side clients, so do not expose them to
-- PUBLIC, anon, or authenticated callers.
REVOKE ALL ON FUNCTION public.claim_premium_reward(uuid, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_premium_reward(uuid, integer, integer)
  TO service_role;

REVOKE ALL ON FUNCTION public.increment_viewer_count(uuid)
  FROM PUBLIC, anon, authenticated;
ALTER FUNCTION public.increment_viewer_count(uuid)
  SET search_path = pg_catalog, public;
GRANT EXECUTE ON FUNCTION public.increment_viewer_count(uuid)
  TO service_role;
