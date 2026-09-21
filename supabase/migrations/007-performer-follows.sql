-- Performer follows: lets a signed-in user follow a performer and see the
-- list of performers they follow (used by /api/user/follows).
--
-- The table was used by the API but never migrated 2026-09 — this adds it
-- idempotently so GET/POST/DELETE /user/follows stop returning 500s.

-- 0. Drop every existing policy on the table. A stale policy (even one with a
--    different name) blocks ALTER COLUMN ... TYPE with
--    "cannot alter type of a column used in a policy definition".
DO $$
DECLARE pol RECORD;
BEGIN
  FOR pol IN SELECT policyname
             FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'performer_follows'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.performer_follows', pol.policyname);
  END LOOP;
END $$;

-- 1. Make sure the table exists.
CREATE TABLE IF NOT EXISTS public.performer_follows (
  user_id            uuid NOT NULL,
  performer_username text NOT NULL,
  followed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, performer_username)
);

-- 2. Normalize a pre-existing table that stored user_id as text instead of
--    uuid. Without this, `auth.uid() = user_id` fails with
--    "operator does not exist: uuid = text". Casting NULLs is a no-op, so an
--    untouched/empty table converts cleanly.
ALTER TABLE public.performer_follows
  ALTER COLUMN user_id TYPE uuid USING user_id::uuid;

-- 3. Guarantee the (user_id, performer_username) unique target relied on by
--    the route's `upsert(..., onConflict [onConflict: "user_id, performer_username"])`.
CREATE UNIQUE INDEX IF NOT EXISTS performer_follows_user_performer_key
  ON public.performer_follows (user_id, performer_username);

-- 4. FK to auth.users (added conditionally in case the pre-existing table
--    predates it). Rebuilds automatically with ALTER COLUMN ... TYPE above if
--    the PK covered user_id.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'performer_follows_user_id_fkey'
      AND conrelid = 'public.performer_follows'::regclass
  ) THEN
    ALTER TABLE public.performer_follows
      ADD CONSTRAINT performer_follows_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
  END IF;
END $$;

-- 5. Ordering query: follows for a user sorted by most recent first.
CREATE INDEX IF NOT EXISTS idx_performer_follows_user_followed
  ON public.performer_follows (user_id, followed_at DESC);

-- ─── Row Level Security ────────────────────────────────────────────────────
-- Users may manage (select/insert/update/delete) only their own follows.
-- The API's user-scoped client (createUserClient) hits these; the
-- service-role client used by recordings.ts / admin.ts bypasses RLS.
ALTER TABLE public.performer_follows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS performer_follows_owner_all ON performer_follows;
CREATE POLICY performer_follows_owner_all ON public.performer_follows
  FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);