-- 008: notifications hardening
--
-- Ensures the two notification tables exist with the columns the API and the
-- notify_requesters_on_upload trigger rely on, adds a read-optimized index,
-- locks RLS to owner-only access, and registers user_notifications with the
-- supabase_realtime publication so the bell updates instantly.
-- Idempotent — safe to re-run in the Supabase SQL Editor.
--
-- NOTE: user_id is kept as `text` (matching the legacy bootstrap used by the
-- rest of the user-data tables and the notify_requesters_on_upload trigger,
-- which reads user_id straight out of `requests`). RLS compares via
-- auth.uid()::text so it type-checks regardless of the stored type.

-- ─── user_notifications ──────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_notifications (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    text NOT NULL,
  type       text NOT NULL,
  message    text NOT NULL,
  related_id text,
  is_read    boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Fill in columns that may be missing on older/bootstrapped installs.
ALTER TABLE public.user_notifications
  ADD COLUMN IF NOT EXISTS type text NOT NULL DEFAULT 'request_status',
  ADD COLUMN IF NOT EXISTS message text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS related_id text,
  ADD COLUMN IF NOT EXISTS is_read boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

-- Read pattern: per-user list ordered newest-first (used by GET /notifications).
CREATE INDEX IF NOT EXISTS idx_user_notifications_user_created
  ON public.user_notifications (user_id, created_at DESC);

-- ─── user_notification_preferences ────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_notification_preferences (
  user_id           text NOT NULL,
  notification_type text NOT NULL,
  enabled           boolean NOT NULL DEFAULT true,
  email_enabled     boolean NOT NULL DEFAULT false,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, notification_type)
);

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS email_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- ─── Row Level Security ────────────────────────────────────────────────────
-- Users may read/manage only their own notification rows. Server-side
-- insert/delete paths run through the service-role client (bypasses RLS) and
-- the notify_requesters_on_upload trigger is SECURITY DEFINER, so those are
-- unaffected.

-- Drop any stale policies (possibly bootstrapped ad-hoc) so the owner
-- policies below are the only ones in effect.
DO $$
DECLARE pol RECORD;
BEGIN
  FOR pol IN SELECT policyname
             FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'user_notifications'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.user_notifications', pol.policyname);
  END LOOP;
  FOR pol IN SELECT policyname
             FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'user_notification_preferences'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.user_notification_preferences', pol.policyname);
  END LOOP;
END $$;

ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_notification_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_notifications_owner_all ON user_notifications;
CREATE POLICY user_notifications_owner_all ON public.user_notifications
  FOR ALL
  USING (auth.uid()::text = user_id::text)
  WITH CHECK (auth.uid()::text = user_id::text);

DROP POLICY IF EXISTS user_notification_preferences_owner_all ON user_notification_preferences;
CREATE POLICY user_notification_preferences_owner_all ON public.user_notification_preferences
  FOR ALL
  USING (auth.uid()::text = user_id::text)
  WITH CHECK (auth.uid()::text = user_id::text);

-- ─── Realtime ──────────────────────────────────────────────────────────────
-- Register with Supabase Realtime so the client's postgres_changes
-- subscription (use-realtime-notifications) stops warning about a missing
-- source. No-op if the publication doesn't exist or already includes it.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'user_notifications'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_notifications;
  END IF;
END $$;