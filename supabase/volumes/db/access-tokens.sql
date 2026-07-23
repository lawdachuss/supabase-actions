-- =============================================================================
-- 🔑 Personal Access Tokens (sbp_) Management
-- =============================================================================
-- Provides the "Access Tokens" feature similar to Supabase Cloud.
-- Tokens are service_role JWTs stored with metadata for tracking.
--
-- Usage:
--   1. Run:  ./run.sh gen-token "My Token" "For CI/CD"
--   2. Use:  Authorization: Bearer <token>
--   3. List: ./run.sh list-tokens
--   4. Revoke: ./run.sh revoke-token <uuid>
--
-- The token is a valid JWT signed with JWT_SECRET (HS256).
-- Kong validates it automatically via existing JWT verification.
-- The jti (JWT ID) is tracked in this table for management.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS _supabase;

-- ── Storage table ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS _supabase.access_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT DEFAULT '',
    jti UUID NOT NULL UNIQUE,                        -- JWT ID (embedded in the token)
    token_prefix TEXT NOT NULL,                      -- 'sbp_' + first 8 hex chars for identification
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ,
    revoked BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_access_tokens_jti ON _supabase.access_tokens(jti);
CREATE INDEX IF NOT EXISTS idx_access_tokens_revoked ON _supabase.access_tokens(revoked);

-- ── Register a new token (returns metadata; actual JWT is constructed by caller) ──
CREATE OR REPLACE FUNCTION _supabase.register_access_token(
    token_name TEXT,
    token_description TEXT DEFAULT ''
) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    token_jti UUID;
    token_expiry TIMESTAMPTZ;
    token_prefix_val TEXT;
BEGIN
    token_jti := gen_random_uuid();
    token_expiry := now() + INTERVAL '1 year';
    token_prefix_val := 'sbp_' || encode(gen_random_bytes(4), 'hex');

    INSERT INTO _supabase.access_tokens (name, description, jti, token_prefix, expires_at)
    VALUES (token_name, token_description, token_jti, token_prefix_val, token_expiry);

    RETURN json_build_object(
        'id', token_jti::TEXT,
        'name', token_name,
        'prefix', token_prefix_val,
        'expires_at', token_expiry::TEXT
    );
END;
$$;

-- ── Check if a jti is still valid (not revoked, not expired) ───────────────
CREATE OR REPLACE FUNCTION _supabase.check_token_jti(
    token_jti UUID
) RETURNS TABLE(valid BOOLEAN, token_name TEXT, token_description TEXT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    tok RECORD;
BEGIN
    SELECT * INTO tok FROM _supabase.access_tokens
    WHERE jti = token_jti AND revoked = false AND expires_at > now();

    IF tok.id IS NOT NULL THEN
        UPDATE _supabase.access_tokens SET last_used_at = now() WHERE id = tok.id;
        RETURN QUERY SELECT true, tok.name, tok.description;
    ELSE
        RETURN QUERY SELECT false, NULL::TEXT, NULL::TEXT;
    END IF;
END;
$$;

-- ── Revoke a token by its UUID id ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION _supabase.revoke_token_by_id(
    token_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    UPDATE _supabase.access_tokens SET revoked = true WHERE id = token_id;
    RETURN FOUND;
END;
$$;

-- ── List all tokens (without the actual JWT) ──────────────────────────────
CREATE OR REPLACE FUNCTION _supabase.list_access_tokens(
    include_revoked BOOLEAN DEFAULT false
) RETURNS TABLE(
    id UUID, name TEXT, description TEXT,
    token_prefix TEXT, created_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ, last_used_at TIMESTAMPTZ,
    is_revoked BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    IF include_revoked THEN
        RETURN QUERY SELECT a.id, a.name, a.description, a.token_prefix,
                            a.created_at, a.expires_at, a.last_used_at, a.revoked
                     FROM _supabase.access_tokens a
                     ORDER BY a.created_at DESC;
    ELSE
        RETURN QUERY SELECT a.id, a.name, a.description, a.token_prefix,
                            a.created_at, a.expires_at, a.last_used_at, a.revoked
                     FROM _supabase.access_tokens a
                     WHERE a.revoked = false
                     ORDER BY a.created_at DESC;
    END IF;
END;
$$;
