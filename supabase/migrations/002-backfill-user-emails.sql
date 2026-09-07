-- Backfill email addresses in user_profiles from auth.users
-- This fixes users who signed up before the email column was added

DO $$
BEGIN
  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    EXECUTE '
      UPDATE public.user_profiles up
      SET email = au.email
      FROM auth.users au
      WHERE up.user_id::text = au.id::text
        AND (up.email IS NULL OR up.email = '''')
    ';
  ELSE
    RAISE NOTICE 'user_profiles table does not exist — skipping email backfill';
  END IF;
END $$;
