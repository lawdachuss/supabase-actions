-- 006: security hardening day
--
-- Changes:
-- 1. Daily reward cap: claim_premium_reward now only grants once per calendar
--    day (last_granted_date). Grinding past 5 ads on a day won't produce a
--    second +1 day, eliminating the unlimited-farming vector.
-- 2. Atomic view count: increment_viewer_count() replaces the read-modify-write
--    loop with a single UPDATE … RETURNING, eliminating lost increments from
--    concurrent requests.

-- ─── 1. Daily reward cap ─────────────────────────────────────────────────────

ALTER TABLE user_premium ADD COLUMN IF NOT EXISTS last_granted_date date;

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
        'granted',             false,
        'cooldown_ms',         v_cooldown_ms,
        'already_granted_today', false,
        'ads_viewed_today',    v_row.ads_seen_count,
        'ads_target',          p_target,
        'premium_until',       v_row.premium_expires_at,
        'is_premium',          v_row.premium_expires_at > v_now
      );
    END IF;
  END IF;

  -- Roll the daily window when the date changes.
  IF v_row.ads_seen_date IS DISTINCT FROM v_today THEN
    v_row.ads_seen_date      := v_today;
    v_row.ads_seen_count     := 0;
    v_row.last_granted_date  := NULL;
  END IF;

  -- DAILY GRANT CAP: if the user already received a reward today, refuse.
  IF v_row.last_granted_date = v_today THEN
    RETURN jsonb_build_object(
      'granted',             false,
      'cooldown_ms',         0,
      'already_granted_today', true,
      'ads_viewed_today',    v_row.ads_seen_count,
      'ads_target',          p_target,
      'premium_until',       v_row.premium_expires_at,
      'is_premium',          v_row.premium_expires_at > v_now
    );
  END IF;

  v_row.ads_seen_count  := v_row.ads_seen_count + 1;
  v_row.last_rewarded_at := v_now;

  -- Grant: extend from the later of "now" and the existing expiry so stacking
  -- never shortens a current subscription, then reset the daily counter.
  IF p_target > 0 AND v_row.ads_seen_count >= p_target THEN
    v_row.premium_expires_at := GREATEST(v_now, COALESCE(v_row.premium_expires_at, v_now)) + interval '1 day';
    v_row.ads_seen_count     := 0;
    v_row.last_granted_date  := v_today;
    v_granted                := true;
  END IF;

  UPDATE user_premium
  SET premium_expires_at = v_row.premium_expires_at,
      ads_seen_date      = v_row.ads_seen_date,
      ads_seen_count     = v_row.ads_seen_count,
      last_rewarded_at   = v_row.last_rewarded_at,
      last_granted_date  = v_row.last_granted_date,
      updated_at         = v_now
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'granted',             v_granted,
    'cooldown_ms',         v_cooldown_ms,
    'already_granted_today', false,
    'ads_viewed_today',    v_row.ads_seen_count,
    'ads_target',          p_target,
    'premium_until',       v_row.premium_expires_at,
    'is_premium',          v_row.premium_expires_at > v_now
  );
END;
$$;

-- ─── 2. Atomic view count ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION increment_viewer_count(p_recording_id uuid)
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.recordings
  SET viewers = COALESCE(viewers, 0) + 1
  WHERE id = p_recording_id
  RETURNING COALESCE(viewers, 0);
$$;
