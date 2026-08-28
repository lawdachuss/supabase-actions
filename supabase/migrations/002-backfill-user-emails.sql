-- Backfill email addresses in user_profiles from auth.users
-- This fixes users who signed up before the email column was added

UPDATE user_profiles up
SET email = au.email
FROM auth.users au
WHERE up.user_id = au.id::text
  AND (up.email IS NULL OR up.email = '');

-- Verify
SELECT up.user_id, up.username, up.email
FROM user_profiles up
ORDER BY up.created_at;
