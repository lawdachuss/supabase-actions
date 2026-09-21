-- Premium / ad-free access + ad-earn tracking.
--
-- Tables:
--   user_premium        — per-user premium expiry + daily ad-earn progress
--   premium_purchases   — idempotent record of completed purchases (webhook-safe)
--   site_settings       — runtime config overrides (ads kill-switch, earn target,
--                         cooldown, grace window, price) readable without a redeploy
--
-- Functions:
--   claim_premium_reward — atomic "watch an ad -> progress toward premium" claim.
--     SQL-level transaction + row lock prevents double-claims at the midnight
--     boundary or from concurrent requests.

CREATE TABLE IF NOT EXISTS user_premium (
  user_id           uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  premium_expires_at timestamptz,
  ads_seen_date     date,
  ads_seen_count    integer NOT NULL DEFAULT 0,
  last_rewarded_at  timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_premium_expiry
  ON user_premium (premium_expires_at);

CREATE TABLE IF NOT EXISTS premium_purchases (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider             text NOT NULL,
  provider_session_id  text UNIQUE,
  amount               numeric(10,2),
  currency             text,
  days                 integer NOT NULL DEFAULT 30,
  purchased_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_premium_purchases_user
  ON premium_purchases (user_id);

CREATE TABLE IF NOT EXISTS site_settings (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO site_settings (key, value) VALUES
  ('ads_enabled',        'true'::jsonb),
  ('ads_target',         '5'::jsonb),
  ('reward_cooldown_s',  '60'::jsonb),
  ('grace_minutes',      '10'::jsonb),
  ('price_usd',          '4.99'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ─── Row Level Security ────────────────────────────────────────────────────
-- Users may read their own premium/premium_purchases rows. site_settings is
-- public-read (server still gates writes via the service-role key). All
-- authenticated API writes go through the service-role client (bypasses RLS),
-- matching the existing role/auth endpoints.

ALTER TABLE user_premium ENABLE ROW LEVEL SECURITY;
ALTER TABLE premium_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE site_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_premium_owner_select ON user_premium;
CREATE POLICY user_premium_owner_select ON user_premium
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS premium_purchases_owner_select ON premium_purchases;
CREATE POLICY premium_purchases_owner_select ON premium_purchases
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS site_settings_read ON site_settings;
CREATE POLICY site_settings_read ON site_settings
  FOR SELECT USING (true);

-- ─── Atomic reward claim ───────────────────────────────────────────────────
-- p_cooldown_s: minimum seconds between claims (0 disables the cap)
-- p_target:     ads seen after which premium is granted (+1 day, extends expiry)

CREATE OR REPLACE FUNCTION claim_premium_reward(
  p_user_id    uuid,
  p_cooldown_s integer,
  p_target     integer
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_row         user_premium;
  v_now         timestamptz := now();
  v_today       date        := current_date;
  v_granted     boolean     := false;
  v_cooldown_ms integer     := 0;
BEGIN
  -- Ensure a row exists so SELECT ... FOR UPDATE has something to lock.
  INSERT INTO user_premium (user_id, created_at, updated_at)
  VALUES (p_user_id, v_now, v_now)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT * INTO v_row
  FROM user_premium
  WHERE user_id = p_user_id
  FOR UPDATE;

  -- Cooldown gate (rejects early unless it's already expired).
  IF v_row.last_rewarded_at IS NOT NULL AND p_cooldown_s > 0 THEN
    v_cooldown_ms := GREATEST(
      0,
      p_cooldown_s * 1000 - (EXTRACT(EPOCH FROM (v_now - v_row.last_rewarded_at))::integer) * 1000
    );
    IF v_cooldown_ms > 0 THEN
      RETURN jsonb_build_object(
        'granted',         false,
        'cooldown_ms',     v_cooldown_ms,
        'ads_viewed_today', v_row.ads_seen_count,
        'ads_target',      p_target,
        'premium_until',   v_row.premium_expires_at,
        'is_premium',      v_row.premium_expires_at > v_now
      );
    END IF;
  END IF;

  -- Roll the daily window when the date changes.
  IF v_row.ads_seen_date IS DISTINCT FROM v_today THEN
    v_row.ads_seen_date  := v_today;
    v_row.ads_seen_count := 0;
  END IF;

  v_row.ads_seen_count  := v_row.ads_seen_count + 1;
  v_row.last_rewarded_at := v_now;

  -- Grant: extend from the later of "now" and the existing expiry so stacking
  -- never shortens a current subscription, then reset the daily counter.
  IF p_target > 0 AND v_row.ads_seen_count >= p_target THEN
    v_row.premium_expires_at := GREATEST(v_now, COALESCE(v_row.premium_expires_at, v_now)) + interval '1 day';
    v_row.ads_seen_count     := 0;
    v_granted                := true;
  END IF;

  UPDATE user_premium
  SET premium_expires_at = v_row.premium_expires_at,
      ads_seen_date      = v_row.ads_seen_date,
      ads_seen_count     = v_row.ads_seen_count,
      last_rewarded_at   = v_row.last_rewarded_at,
      updated_at         = v_now
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'granted',          v_granted,
    'cooldown_ms',      v_cooldown_ms,
    'ads_viewed_today', v_row.ads_seen_count,
    'ads_target',       p_target,
    'premium_until',    v_row.premium_expires_at,
    'is_premium',       v_row.premium_expires_at > v_now
  );
END;
$$;