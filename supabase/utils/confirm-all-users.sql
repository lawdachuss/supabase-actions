-- Confirm ALL unconfirmed users at once
-- Run: docker compose exec -T db psql -U postgres -f utils/confirm-all-users.sql

-- Step 1: Show what will be affected
SELECT id, email, email_confirmed_at, created_at
FROM auth.users
WHERE email_confirmed_at IS NULL;

-- Step 2: Confirm them
UPDATE auth.users
SET email_confirmed_at = NOW(),
    email_change_confirm_status = 0
WHERE email_confirmed_at IS NULL;

-- Step 3: Verify
SELECT id, email, email_confirmed_at, created_at
FROM auth.users
ORDER BY created_at DESC;
