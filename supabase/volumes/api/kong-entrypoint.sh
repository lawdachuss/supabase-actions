#!/bin/sh
# Custom entrypoint for Kong that builds Lua expressions for request-transformer
# and performs environment variable substitution in the declarative config.

# Build Lua expressions for translating opaque API keys to asymmetric JWTs.
# When opaque keys are not configured (empty env vars), expressions fall through
# to legacy-only behavior - just passing apikey as-is.
#
# Full expression logic (when opaque keys are configured):
#   1. If Authorization header exists and is NOT an sb_ key -> pass through (user session JWT)
#   2. If apikey matches secret key -> set service_role asymmetric JWT internal "API key"
#   3. If apikey matches publishable key -> set anon asymmetric JWT internal "API key"
#   4. Fallback: pass apikey as-is (legacy HS256 JWT)

for key in "$SUPABASE_API_KEY" "$SUPABASE_SERVICE_ROLE_KEY"; do
    case "$key" in
        *[!A-Za-z0-9._-]*)
            echo "Invalid character in configured Supabase compatibility API key" >&2
            exit 1
            ;;
    esac
done

if [ -n "$SUPABASE_SECRET_KEY" ] && [ -n "$SUPABASE_PUBLISHABLE_KEY" ]; then
    # Opaque keys configured -> full translation expressions
    export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= 'Bearer sb_' and headers.authorization) or (headers.apikey == '$SUPABASE_SECRET_KEY' and 'Bearer $SERVICE_ROLE_KEY_ASYMMETRIC') or (headers.apikey == '$SUPABASE_PUBLISHABLE_KEY' and 'Bearer $ANON_KEY_ASYMMETRIC') or headers.apikey)"

    # Realtime WebSocket: reads from query_params.apikey (supabase-js sends apikey
    # via query string), outputs to x-api-key header which Realtime checks first.
    export LUA_RT_WS_EXPR="\$((query_params.apikey == '$SUPABASE_SECRET_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (query_params.apikey == '$SUPABASE_PUBLISHABLE_KEY' and '$ANON_KEY_ASYMMETRIC') or query_params.apikey)"
else
    # Legacy API keys, not sb_ API keys -> pass apikey through unchanged
    export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= 'Bearer sb_' and headers.authorization) or headers.apikey)"
    export LUA_RT_WS_EXPR="\$(query_params.apikey)"
fi

if [ -n "$SUPABASE_API_KEY" ] || [ -n "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    export LUA_AUTH_EXPR="\$((headers.authorization == 'Bearer $SUPABASE_SERVICE_ROLE_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (headers.authorization == 'Bearer $SUPABASE_API_KEY' and '$ANON_KEY_ASYMMETRIC') or (headers.authorization ~= nil and headers.authorization) or (headers.apikey == '$SUPABASE_SERVICE_ROLE_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (headers.apikey == '$SUPABASE_API_KEY' and '$ANON_KEY_ASYMMETRIC') or (headers.apikey == '$SUPABASE_SECRET_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (headers.apikey == '$SUPABASE_PUBLISHABLE_KEY' and '$ANON_KEY_ASYMMETRIC') or headers.apikey)"
    export LUA_RT_WS_EXPR="\$((query_params.apikey == '$SUPABASE_SERVICE_ROLE_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (query_params.apikey == '$SUPABASE_API_KEY' and '$ANON_KEY_ASYMMETRIC') or (query_params.apikey == '$SUPABASE_SECRET_KEY' and '$SERVICE_ROLE_KEY_ASYMMETRIC') or (query_params.apikey == '$SUPABASE_PUBLISHABLE_KEY' and '$ANON_KEY_ASYMMETRIC') or query_params.apikey)"
fi

# Substitute environment variables in the Kong declarative config and remove
# duplicate credentials within a consumer. Kong rejects duplicate key-auth
# values, which can occur when compatibility keys equal generated keys.
# Credentials shared by different consumers remain fatal: that is an unsafe
# role collision, not a harmless alias.
if ! awk '
  function indent(line, copy) {
    copy = line
    sub(/[^ ].*$/, "", copy)
    return length(copy)
  }
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }
  index($0, "$SUPABASE_API_KEY") && !ENVIRON["SUPABASE_API_KEY"] { next }
  index($0, "$SUPABASE_SERVICE_ROLE_KEY") && !ENVIRON["SUPABASE_SERVICE_ROLE_KEY"] { next }
  {
  result = ""
  rest = $0
  while (match(rest, /\$[A-Za-z_][A-Za-z_0-9]*/)) {
    varname = substr(rest, RSTART + 1, RLENGTH - 1)
    if (varname in ENVIRON) {
      result = result substr(rest, 1, RSTART - 1) ENVIRON[varname]
    } else {
      result = result substr(rest, 1, RSTART + RLENGTH - 1)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  result = result rest

  if (result ~ /^[[:space:]]*-[[:space:]]*username:/) {
    consumer = result
    sub(/^[[:space:]]*-[[:space:]]*username:[[:space:]]*/, "", consumer)
    consumer = trim(consumer)
    in_credentials = 0
  } else if (result ~ /^[[:space:]]*keyauth_credentials:[[:space:]]*$/) {
    in_credentials = 1
    credentials_indent = indent(result)
  } else if (in_credentials && result !~ /^[[:space:]]*(#.*)?$/ &&
             indent(result) <= credentials_indent) {
    in_credentials = 0
  }

  if (in_credentials && result ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/) {
    credential = result
    sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", credential)
    credential = trim(credential)
    if (credential != "") {
      if (credential in credential_owner &&
          credential_owner[credential] != consumer) {
        printf "Duplicate Kong API key is assigned to both %s and %s\n", \
          credential_owner[credential], consumer > "/dev/stderr"
        exit 1
      }
      if ((consumer SUBSEP credential) in consumer_credentials) next
      consumer_credentials[consumer SUBSEP credential] = 1
      credential_owner[credential] = consumer
    }
  }

  print result
}' /home/kong/temp.yml > "$KONG_DECLARATIVE_CONFIG"; then
    exit 1
fi

# Remove empty key-auth credentials (unconfigured opaque keys)
sed -i '/^[[:space:]]*- key:[[:space:]]*$/d' "$KONG_DECLARATIVE_CONFIG"

exec /entrypoint.sh kong docker-start
