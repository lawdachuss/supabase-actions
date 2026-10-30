#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${STATE_ENV_FILE:-$BASE_DIR/.env}"
SETTINGS_FILE="${STATE_SETTINGS_FILE:-$BASE_DIR/.state-settings.env}"

is_persistable_setting() {
  case "$1" in
    COMPOSE_FILE|SUPABASE_PUBLIC_URL|API_EXTERNAL_URL|POSTGRES_HOST|POSTGRES_DB|OPENDB_PORT|POSTGRES_PORT|POOLER_PROXY_PORT_TRANSACTION|POOLER_DEFAULT_POOL_SIZE|POOLER_MAX_CLIENT_CONN|POOLER_TENANT_ID|POOLER_DB_POOL_SIZE|STUDIO_DEFAULT_ORGANIZATION|STUDIO_DEFAULT_PROJECT|DASHBOARD_USERNAME|SITE_URL|ADDITIONAL_REDIRECT_URLS|JWT_EXPIRY|DISABLE_SIGNUP|MAILER_URLPATHS_CONFIRMATION|MAILER_URLPATHS_INVITE|MAILER_URLPATHS_RECOVERY|MAILER_URLPATHS_EMAIL_CHANGE|ENABLE_EMAIL_SIGNUP|ENABLE_EMAIL_AUTOCONFIRM|ENABLE_ANONYMOUS_USERS|ENABLE_PHONE_SIGNUP|ENABLE_PHONE_AUTOCONFIRM|ENABLE_CUSTOM_ACCESS_TOKEN_HOOK|CUSTOM_ACCESS_TOKEN_HOOK_URI|FUNCTIONS_VERIFY_JWT|INBUCKET_WEB_PORT|INBUCKET_SMTP_PORT|PGRST_DB_SCHEMAS|PGRST_DB_MAX_ROWS|PGRST_DB_EXTRA_SEARCH_PATH|DOCKER_SOCKET_LOCATION|GOOGLE_PROJECT_ID|GOOGLE_PROJECT_NUMBER|KONG_HTTP_PORT|KONG_HTTPS_PORT|PROXY_DOMAIN|CERTBOT_EMAIL|REDIS_PORT|REDIS_MAXMEMORY|REDIS_MAXMEMORY_POLICY|REDIS_APPENDONLY|REDIS_APPENDFSYNC|REDIS_SAVE_SECONDS|REDIS_AOF_REWRITE_PERCENT|REDIS_AOF_REWRITE_MIN_SIZE|REDIS_COMMANDER_PORT|REDIS_DASHBOARD_USER)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

save_settings() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "  No .env file found; runtime settings were not included in the state archive"
    return 0
  fi

  local tmp line key
  tmp="$(mktemp "$BASE_DIR/.state-settings.env.XXXXXX")"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*)
        key="${line%%=*}"
        if is_persistable_setting "$key"; then
          printf '%s\n' "$line" >> "$tmp"
        fi
        ;;
    esac
  done < "$ENV_FILE"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SETTINGS_FILE"
  echo "  Runtime settings saved (secret values excluded)"
}

restore_settings() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    return 0
  fi
  if [ ! -f "$ENV_FILE" ]; then
    echo "  ERROR: cannot restore runtime settings because .env is missing" >&2
    return 1
  fi

  local tmp line key
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*)
        key="${line%%=*}"
        if ! is_persistable_setting "$key"; then
          echo "  ERROR: refusing unsupported runtime setting: $key" >&2
          return 1
        fi
        tmp="$(mktemp "$BASE_DIR/.env.XXXXXX")"
        awk -v prefix="$key=" 'index($0, prefix) != 1' "$ENV_FILE" > "$tmp"
        printf '%s\n' "$line" >> "$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$ENV_FILE"
        ;;
    esac
  done < "$SETTINGS_FILE"
  echo "  Persisted non-secret runtime settings restored"
}

case "${1:-}" in
  save) save_settings ;;
  restore) restore_settings ;;
  *)
    echo "Usage: $0 {save|restore}" >&2
    exit 2
    ;;
esac
