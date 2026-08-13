-- Custom Access Token Hook (Supabase Auth) — pass-through example.
-- Ref: https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook
--
-- This function runs on every token issuance/refresh when enabled (set
-- ENABLE_CUSTOM_ACCESS_TOKEN_HOOK=true in the workflow secrets / .env).
-- It currently returns the claims unchanged — edit the `claims` jsonb below
-- to add custom claims (e.g. role from a table, feature flags, ...).
--
-- NOTE: it is safe to leave this applied even while the hook is disabled —
-- the function just sits unused until the flag is flipped.

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
  declare
    claims jsonb;
    user_id uuid;
  begin
    -- Fetch the user ID from the event
    user_id := (event->>'user_id')::uuid;

    -- Start from the claims the event already carries
    claims := event->'claims';

    -- ── Custom claims go here ─────────────────────────────────────────
    -- e.g. claims := claims || jsonb_build_object('app_role', 'member');
    -- ──────────────────────────────────────────────────────────────────

    -- Return the modified claims in the format GoTrue expects
    return jsonb_build_object('claims', claims);
  end;
$$;

-- The auth service needs execute permission on the hook
grant execute on function public.custom_access_token_hook to supabase_auth_admin;

-- Make sure the function is in the public schema (the pg-functions:// URI
-- in CUSTOM_ACCESS_TOKEN_HOOK_URI targets public.custom_access_token_hook)
alter function public.custom_access_token_hook owner to postgres;
