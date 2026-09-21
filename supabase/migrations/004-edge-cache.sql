-- Shared cross-device edge cache for the frontend's Tier-0 cache layer
-- (artifacts/video-archive/src/lib/cache.ts). The browser writes API payloads
-- here keyed by query key with a TTL, so repeat visits on any device can hit
-- the edge instead of the API server. Only the `cache` edge function touches
-- this table (via the service-role key); anonymous users never see it.
CREATE TABLE IF NOT EXISTS public.edge_cache (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  expires_at timestamptz           -- NULL = never expires
);

CREATE INDEX IF NOT EXISTS edge_cache_expires_at_idx
  ON public.edge_cache (expires_at);

-- Locked down: no RLS policies, so only the service role (the edge function)
-- can read or write it.
ALTER TABLE public.edge_cache ENABLE ROW LEVEL SECURITY;