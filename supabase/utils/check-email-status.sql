-- Check email confirmation status of all users
-- Run: docker compose exec -T db psql -U postgres -f utils/check-email-status.sql

SELECT
  id,
  email,
  email_confirmed_at,
  CASE
    WHEN email_confirmed_at IS NOT NULL THEN '✅ confirmed'
    WHEN created_at < NOW() - INTERVAL '1 hour' THEN '❌ unconfirmed (likely stuck)'
    ELSE '⏳ recent signup (pending)'
  END AS status,
  created_at,
  last_sign_in_at
FROM auth.users
ORDER BY created_at DESC;
