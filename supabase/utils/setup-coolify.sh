#!/usr/bin/env bash
# =============================================================================
# 🐳 setup-coolify.sh — prepare + start the Coolify self-hosted PaaS
# =============================================================================
# Deploys a companion Coolify stack alongside a (running) Supabase stack:
#   - coolify            (UI dashboard + API on host port 8082 by default)
#   - coolify-postgres   (Coolify's own metadata DB, container name coolify-db)
#   - coolify-redis
#   - coolify-realtime   (websocket broadcasts / live deploy logs)
#
# Subcommands (idempotent, safe to re-run):
#   prep    create storage dirs, secrets/.env, SSH key + start sshd
#   pull    (prep must have run) pre-pull the Coolify images   (background job)
#   start   prep + two-phase up + Coolify DB restore + health  (default)
#   status  show Coolify container status / public endpoints
#
# PERSISTENCE: Coolify stores its config in its own 'coolify' DB, and encrypts
# stored credentials with its application key (APP_KEY). To keep everything
# decryptable across GitHub Actions sessions:
#   - snapshot-state.sh dumps coolify-db -> coolify_backup.dump AND archives
#     volumes/coolify/source/.env + volumes/coolify/ssh,
#   - prep() reuses those archived values instead of regenerating them, so
#     APP_KEY is stable and the restored DB stays readable,
#   - start() restores coolify_backup.dump BEFORE the app boots (avoids any
#     migration race with Coolify's first-boot bootstrap).
#
# How Coolify manages the host:
#   - the Docker socket is mounted into the container for app/proxy deploys
#   - an SSH key + sshd are configured as well, so Coolify's "localhost"
#     server works (the standard self-hosted flow).
#
# The coolify up MUST see the exact same files the running Supabase stack uses
# (base + logs + redis) so existing services keep identical configs and are
# never recreated mid-session.
# =============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ACTION="${1:-start}"

# COMPOSE_FILE is unset so -f wins (the workflow exports COMPOSE_FILE for the
# Supabase project).
unset COMPOSE_FILE 2>/dev/null || true
COMPOSE_CMD=(docker compose -f docker-compose.yml -f docker-compose.logs.yml -f docker-compose.redis.yml -f docker-compose.coolify.yml)

COOLIFY_DIR="volumes/coolify"
SOURCE_ENV="$COOLIFY_DIR/source/.env"
HOST_ENV=".env"
COOLIFY_PORT="${COOLIFY_PORT:-8082}"
SSH_USER="$(id -un)"
KEY_FILE="$COOLIFY_DIR/ssh/keys/id.${SSH_USER}@host.docker.internal"

# ── Helpers ──────────────────────────────────────────────────────────────────
# Idempotent key=value writer (safe for arbitrary secret values)
set_env() { # key value file
  local key="$1" val="$2" file="$3"
  # Drop any existing line for the key and append the new one, rather than
  # substituting in-place. Values are never interpolated into sed/awk, so
  # secrets containing & | \ (all valid in a password) survive intact — the
  # old `sed s|^KEY=.*|KEY=${val}|` mangled `&` into the matched line.
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
    { grep -v "^${key}=" "$file" || true; } > "$file.tmp" && mv -f "$file.tmp" "$file"
  fi
  echo "${key}=${val}" >> "$file"
}

# Read a persisted value back (e.g. after a separate prep run)
env_value() { # key file
  grep -E "^${1}=" "${2:-$HOST_ENV}" 2>/dev/null | head -1 | cut -d= -f2-
}

# Random secret (no |, keeps sed happy)
rand_secret() { # bytes
  openssl rand -base64 "$1" 2>/dev/null | tr -d '\n'
}
rand_hex() { # bytes
  openssl rand -hex "$1" 2>/dev/null
}

# Password that always satisfies Coolify's root-user rule:
# Password::min(8)->mixedCase()->letters()->numbers()->symbols()
# (openssl base64 can legitimately come out with no symbol at all, which made
# root-user creation fail on ~half of all first boots).
rand_password() {
  local raw
  raw="$(openssl rand -hex 10 2>/dev/null)"   # 20 lowercase hex chars
  printf 'Co1!%s' "$raw"                       # upper + lower + digit + symbol, 24 chars
}

# True when a password can pass Coolify's root-user validator.
password_ok() {
  local p="$1"
  [ "${#p}" -ge 8 ] || return 1
  printf '%s' "$p" | grep -q '[A-Z]' || return 1
  printf '%s' "$p" | grep -q '[a-z]' || return 1
  printf '%s' "$p" | grep -q '[0-9]' || return 1
  printf '%s' "$p" | grep -q '[^A-Za-z0-9]' || return 1
  return 0
}

# psql against the companion Coolify DB. Uses the CONFIGURED user/name (written
# to .env by prep) so a non-default COOLIFY_DB_USERNAME / COOLIFY_DB_NAME keeps
# working; falls back to the Coolify defaults.
coolify_psql() {
  local user name
  user="$(env_value COOLIFY_DB_USERNAME)"; [ -n "$user" ] || user="coolify"
  name="$(env_value COOLIFY_DB_NAME)";     [ -n "$name" ] || name="coolify"
  docker exec coolify-db psql -U "$user" -d "$name" "$@"
}

# Enable Coolify's API (disabled by default since migration
# 2024_09_26_083441_disable_api_by_default — the deploy webhook sits behind it)
# and mint a fresh deploy-scoped token for the first admin/owner. Sanctum stores
# sha256(plaintext) in personal_access_tokens.token, so inserting the hash here
# is exactly what the UI's "Create token" does. Echoes the plaintext token on
# success; returns 1 (printing nothing) when there is no user/team yet.
mint_deploy_token() {
  local token token_hash count
  token="coolify-autodeploy-$(rand_hex 16)"
  token_hash="$(printf '%s' "$token" | sha256sum 2>/dev/null | cut -d' ' -f1)"
  [ -n "$token_hash" ] || return 1
  coolify_psql -q -c "UPDATE instance_settings SET is_api_enabled = true, updated_at = now();" \
    >/dev/null 2>&1 || true
  coolify_psql -v ON_ERROR_STOP=1 -q -c "
      DELETE FROM personal_access_tokens WHERE name = 'coolify-autodeploy';
      INSERT INTO personal_access_tokens
        (tokenable_type, tokenable_id, name, token, abilities, team_id, created_at, updated_at)
      SELECT 'App\Models\User', u.id, 'coolify-autodeploy', '$token_hash',
             '["deploy"]'::json, t.team_id, now(), now()
      FROM users u
      JOIN team_user t ON t.user_id = u.id
      ORDER BY u.id, t.team_id
      LIMIT 1;" >/dev/null 2>&1 || return 1
  count="$(coolify_psql -t -A -c \
    "SELECT COUNT(*) FROM personal_access_tokens WHERE token = '$token_hash';" \
    2>/dev/null | tr -d ' \r')"
  [ "$count" = "1" ] || return 1
  printf '%s' "$token"
}

# RootUserSeeder creates the root user (id 0) exactly once, so a
# COOLIFY_PASSWORD secret added or changed later would never reach the database
# while the run summary still claimed it was the password. When the secret is
# present, make it authoritative by re-hashing it onto the root user.
sync_root_password() {
  [ -n "${COOLIFY_PASSWORD:-}" ] || return 0
  if ! coolify_psql -t -A -c "SELECT to_regclass('public.users') IS NOT NULL;" 2>/dev/null | grep -q t; then
    echo "  ⚠️  users table not present yet — root password sync skipped"
    return 0
  fi
  local n pw_q
  n="$(coolify_psql -t -A -c "SELECT COUNT(*) FROM users WHERE id = 0;" 2>/dev/null | tr -d ' \r')"
  if [ "$n" != "1" ]; then
    echo "  ℹ️  no root user (id 0) yet — COOLIFY_PASSWORD applies at first boot"
    return 0
  fi
  pw_q="${COOLIFY_PASSWORD//\'/\'\'}"
  if coolify_psql -v ON_ERROR_STOP=1 -q -c \
      "CREATE EXTENSION IF NOT EXISTS pgcrypto;
       UPDATE users SET password = crypt('$pw_q', gen_salt('bf')), updated_at = now()
       WHERE id = 0;" >/dev/null 2>&1; then
    echo "  🔑 root password synced to the COOLIFY_PASSWORD secret"
  else
    echo "  ⚠️  could not sync the root password to COOLIFY_PASSWORD"
  fi
}

# Post-start assertions for the paths that used to fail silently: a usable
# admin, open registration and an authenticated deploy API. Exits non-zero when
# any check fails so a broken dashboard shows up as a red step, not as hours of
# a quietly unusable Coolify.
smoke() {
  local fails=0 n reg token code
  echo "🐳 Coolify smoke test"

  if curl -sf -o /dev/null --max-time 10 "http://127.0.0.1:${COOLIFY_PORT}/api/health"; then
    echo "  ✅ /api/health"
  else
    echo "  ❌ /api/health unreachable on port ${COOLIFY_PORT}"
    fails=$((fails + 1))
  fi

  # 1. an admin exists — without one, dashboard login is impossible
  n="$(coolify_psql -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \r')"
  if [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then
    echo "  ✅ users present ($n)"
  else
    echo "  ❌ no users in Coolify — dashboard login impossible"
    fails=$((fails + 1))
  fi

  # 2. open registration
  reg="$(coolify_psql -t -A -c \
    "SELECT is_registration_enabled FROM instance_settings ORDER BY id LIMIT 1;" \
    2>/dev/null | tr -d ' \r')"
  case "$reg" in
    t|true)
      echo "  ✅ open registration enabled" ;;
    *)
      echo "  ❌ registration not enabled (instance_settings.is_registration_enabled='${reg:-<missing>}')"
      fails=$((fails + 1)) ;;
  esac

  # 3. the deploy API answers an authenticated call. A bogus uuid is expected to
  #    4xx because the resource doesn't exist; 401/403 means auth or the API
  #    gate (instance_settings.is_api_enabled) is broken.
  if token="$(mint_deploy_token)"; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
      -H "Authorization: Bearer $token" \
      "http://127.0.0.1:${COOLIFY_PORT}/api/v1/deploy?uuid=00000000-0000-0000-0000-000000000000" \
      2>/dev/null || echo 000)"
    case "$code" in
      200|201|202|204|400|404|422)
        echo "  ✅ deploy API reachable and authenticated (HTTP $code)" ;;
      401|403)
        echo "  ❌ deploy API rejected the token (HTTP $code) — API gate or token ability broken"
        fails=$((fails + 1)) ;;
      *)
        echo "  ❌ deploy API unexpected response (HTTP $code)"
        fails=$((fails + 1)) ;;
    esac
  else
    echo "  ❌ could not mint a deploy token (no user/team, or API gate)"
    fails=$((fails + 1))
  fi

  if [ "$fails" -eq 0 ]; then
    echo "✅ Coolify smoke test passed"
    return 0
  fi
  echo "❌ Coolify smoke test failed ($fails check(s))"
  return 1
}

prep() {
  echo "🐳 [1/4] Preparing Coolify storage layout..."
  mkdir -p "$COOLIFY_DIR"/{source,ssh/keys,ssh/mux,applications,databases,services,backups,images/avatars,images/project-icons,proxy,sentinel}

  echo "🐳 [2/4] Deriving secrets and writing env files..."

  # Public URL: coolify.<base-of-tunnel-domain> (fallback: localhost)
  local domain="${CF_TUNNEL_DOMAIN:-${COOLIFY_DOMAIN:-}}"
  local base=""
  if [ -n "$domain" ]; then
    base="$(echo "$domain" | sed 's/^supabase\.//')"
    local app_url="https://coolify.${base}"
  else
    local app_url="http://localhost:${COOLIFY_PORT}"
  fi

  # ── Reuse persisted secrets from the archived source/.env (stable APP_KEY) ──
  # Coolify encrypts stored credentials with APP_KEY; regenerating it each
  # session would make a restored DB's secrets undecryptable. Values are only
  # generated when no persisted one exists (very first session, or .env missing).
  local persisted="$SOURCE_ENV"
  pval() { # key -> persisted value from the archived env (may be empty)
    [ -f "$persisted" ] && sed -n "s/^${1}=//p" "$persisted" 2>/dev/null | head -1
  }

  local app_id app_key db_user db_name db_pass redis_pass pusher_id pusher_key pusher_secret root_pass admin_pass
  app_id="$(pval APP_ID)";          [ -z "$app_id" ]        && app_id="$(rand_hex 16)"
  app_key="$(pval APP_KEY)";        [ -z "$app_key" ]       && app_key="base64:$(rand_secret 32)"
  case "$app_key" in base64:*) : ;; *) app_key="base64:${app_key}" ;; esac   # normalize
  db_user="$(pval DB_USERNAME)";    [ -z "$db_user" ]       && db_user="coolify"
  db_name="$(pval DB_DATABASE)";    [ -z "$db_name" ]       && db_name="coolify"
  db_pass="$(pval DB_PASSWORD)";    [ -z "$db_pass" ]       && db_pass="$(rand_secret 24)"
  redis_pass="$(pval REDIS_PASSWORD)"; [ -z "$redis_pass" ] && redis_pass="$(rand_secret 24)"
  pusher_id="$(pval PUSHER_APP_ID)";    [ -z "$pusher_id" ] || [ "$pusher_id" = "coolify" ] && pusher_id="$(rand_hex 32)"
  pusher_key="$(pval PUSHER_APP_KEY)";  [ -z "$pusher_key" ] || [ "$pusher_key" = "coolify" ] && pusher_key="$(rand_hex 32)"
  pusher_secret="$(pval PUSHER_APP_SECRET)"; [ -z "$pusher_secret" ] && pusher_secret="$(rand_hex 32)"
  root_pass="$(pval ROOT_USER_PASSWORD)"
  # an explicit COOLIFY_PASSWORD secret always wins
  [ -n "${COOLIFY_PASSWORD:-}" ] && root_pass="$COOLIFY_PASSWORD"
  # Coolify validates the root password on first boot. Regenerate a persisted
  # value that would be rejected (e.g. generated by an older version of this
  # script, or a base64 draw that happened to contain no symbol) so the root
  # user is actually created.
  if ! password_ok "$root_pass"; then
    if [ -n "${COOLIFY_PASSWORD:-}" ]; then
      echo "  ⚠️  COOLIFY_PASSWORD fails Coolify's policy (needs 8+ chars with upper, lower, digit and symbol) — the root user may not be created"
    else
      root_pass="$(rand_password)"
    fi
  fi
  # Coolify validates ROOT_USER_EMAIL with `email:rfc,dns`. A non-resolvable
  # domain (such as the previous hard-coded `coolify@localhost`) makes the
  # seeder skip creating the root user entirely, so derive a resolvable address
  # from the tunnel domain (fallback: example.com, which has real DNS records).
  local root_email
  root_email="${COOLIFY_ROOT_EMAIL:-$(env_value COOLIFY_ROOT_EMAIL)}"
  [ -n "$root_email" ] || root_email="$(env_value COOLIFY_ADMIN_EMAIL)"
  if [ -z "$root_email" ]; then
    if [ -n "$base" ]; then root_email="coolify@${base}"; else root_email="coolify@example.com"; fi
  fi
  # Password for the fallback admin that seed_admin() creates when the restored
  # DB has no users. Never hard-coded in the repo: persisted in the archived
  # Coolify env (stable across sessions) or generated on first use.
  admin_pass="$(pval ADMIN_PASSWORD)"; [ -z "$admin_pass" ] && admin_pass="$(rand_hex 16)"

  # Compose interpolation vars -> append to the Supabase .env
  set_env COOLIFY_PORT            "$COOLIFY_PORT"   "$HOST_ENV"
  set_env COOLIFY_APP_URL         "$app_url"        "$HOST_ENV"
  set_env COOLIFY_APP_NAME        "Coolify"         "$HOST_ENV"
  set_env COOLIFY_APP_ID          "$app_id"         "$HOST_ENV"
  set_env COOLIFY_APP_KEY         "$app_key"        "$HOST_ENV"
  set_env COOLIFY_DB_USERNAME     "$db_user"        "$HOST_ENV"
  set_env COOLIFY_DB_NAME         "$db_name"        "$HOST_ENV"
  set_env COOLIFY_DB_PASSWORD     "$db_pass"        "$HOST_ENV"
  set_env COOLIFY_REDIS_PASSWORD  "$redis_pass"     "$HOST_ENV"
  set_env COOLIFY_PUSHER_APP_ID    "$pusher_id"     "$HOST_ENV"
  set_env COOLIFY_PUSHER_APP_KEY   "$pusher_key"    "$HOST_ENV"
  set_env COOLIFY_PUSHER_APP_SECRET "$pusher_secret" "$HOST_ENV"
  set_env COOLIFY_ROOT_PASSWORD   "$root_pass"      "$HOST_ENV"

  # Laravel env for the container (volumes/coolify/source/.env) — also archived.
  cat > "$SOURCE_ENV" << EOF
APP_NAME=Coolify
APP_ENV=production
APP_DEBUG=false
APP_ID=$app_id
APP_KEY=$app_key
APP_URL=$app_url
DB_CONNECTION=pgsql
DB_HOST=coolify-db
DB_PORT=5432
DB_DATABASE=$db_name
DB_USERNAME=$db_user
DB_PASSWORD=$db_pass
REDIS_HOST=coolify-redis
REDIS_PORT=6379
REDIS_PASSWORD=$redis_pass
REDIS_DB=0
PUSHER_APP_ID=$pusher_id
PUSHER_APP_KEY=$pusher_key
PUSHER_APP_SECRET=$pusher_secret
PUSHER_BACKEND_HOST=coolify-realtime
PUSHER_BACKEND_PORT=6001
PUSHER_SCHEME=http
ROOT_USERNAME=coolify
ROOT_USER_EMAIL=$root_email
ROOT_USER_PASSWORD=$root_pass
ADMIN_PASSWORD=$admin_pass
AUTOUPDATE=false
TELEMETRY_ENABLED=false
REGISTRY_URL=docker.io
LATEST_IMAGE=latest
EOF
  echo "  ✅ env written: $SOURCE_ENV (+ $(grep -c '^COOLIFY_' "$HOST_ENV" 2>/dev/null || echo 0) COOLIFY_* vars in .env)"

  echo "🐳 [3/4] Configuring SSH so Coolify can manage the host..."
  mkdir -p "$HOME/.ssh"
  if [ ! -f "$KEY_FILE" ]; then
    ssh-keygen -t ed25519 -a 100 -f "$KEY_FILE" -q -N "" -C coolify
    echo "  ✅ generated ${KEY_FILE}"
  fi
  touch "$HOME/.ssh/authorized_keys"
  if ! grep -qxF "$(cat "$KEY_FILE.pub" 2>/dev/null)" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    cat "$KEY_FILE.pub" >> "$HOME/.ssh/authorized_keys" 2>/dev/null || true
    echo "  ✅ public key added to ~/.ssh/authorized_keys"
  fi
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  chmod 600 "$HOME/.ssh/authorized_keys" 2>/dev/null || true

  if ! pgrep -x sshd >/dev/null 2>&1; then
    if sudo systemctl start ssh >/dev/null 2>&1; then
      echo "  ✅ sshd started (systemd)"
    elif sudo mkdir -p /run/sshd 2>/dev/null && sudo /usr/sbin/sshd 2>/dev/null; then
      echo "  ✅ sshd started (direct)"
    else
      echo "  ⚠️  could not start sshd — Coolify will rely on the mounted Docker socket"
    fi
  else
    echo "  ✅ sshd already running"
  fi

  # Container user UID 9999 + Coolify need write access to its storage
  chmod -R 777 "$COOLIFY_DIR" 2>/dev/null || true

  echo "🐳 [4/4] Coolify prepped. UI will be on port $COOLIFY_PORT."
}

pull() {
  # Assumes prep already ran (the workflow runs it synchronously first) so the
  # env_file + .env interpolation exist. pull() itself only reads, never writes,
  # so it can run in the background without racing the later start() prep.
  echo "🐳 Pre-pulling Coolify images (coolify, postgres, redis, realtime)..."
  "${COMPOSE_CMD[@]}" pull coolify coolify-postgres coolify-redis coolify-realtime 2>&1 | tail -5
  echo "🐳 Image pull finished."
}

redeploy_apps() {
  # A fresh GitHub Actions session is a brand-new VM: the Coolify metadata DB,
  # SSH keys and per-app configs survive (restored from the archive), but the
  # deployed containers, images and their volumes do NOT. So after the DB is
  # restored and Coolify is healthy, queue a deployment for every stored
  # application through Coolify's own API so it comes back up.
  #
  # Coolify's only deploy entrypoint is the AUTHENTICATED webhook
  # `POST /api/v1/deploy?uuid=<uuid>` (the old unauthenticated `/deploy?uuid=`
  # route no longer exists — it 404s). Rather than requiring the operator to
  # create a token, we mint a deploy-scoped one directly in Postgres (Sanctum
  # stores `sha256(plaintext)` in personal_access_tokens.token) for the first
  # admin/owner, and make sure API access is switched on (Coolify ships with it
  # disabled). Best-effort only — never fails the session.
  # Opt out: COOLIFY_AUTO_REDEPLOY=0
  if [ "${COOLIFY_AUTO_REDEPLOY:-1}" != "1" ]; then
    echo "  ℹ️  auto-redeploy disabled (COOLIFY_AUTO_REDEPLOY=0) — apps stay stopped"
    return 0
  fi
  echo "🐳 Redeploying previously-deployed Coolify applications (fresh VM)..."

  local uuids u
  uuids="$(coolify_psql -t -A -c "SELECT uuid FROM applications;" 2>/dev/null || true)"
  uuids="$(printf '%s\n' "$uuids" | grep -E '^[0-9a-f-]{36}$' || true)"
  [ -z "$uuids" ] && { echo "  🎯 no applications stored in Coolify yet — nothing to redeploy"; return 0; }

  # Turn on the API gate and mint a deploy-scoped token (shared with `smoke`).
  local token
  if ! token="$(mint_deploy_token)"; then
    echo "  ⚠️  could not mint a deploy token (no user/team, or API gate) — skipping redeploy"
    return 0
  fi

  # Hit the API on the loopback address: the local container is always
  # reachable, whereas the public coolify.<domain> hostname needs a manual
  # Zero-Trust ingress entry and would otherwise silently fail.
  local api_url="http://127.0.0.1:${COOLIFY_PORT}/api/v1/deploy"
  echo "  🎯 $api_url ..."
  local queued=0 failed=0 code
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -X POST \
      -H "Authorization: Bearer $token" \
      "$api_url?uuid=$u&force=false" 2>/dev/null || echo 000)"
    case "$code" in
      200|201|202|204|302) echo "  ✅ queued deploy for $u (HTTP $code)"; queued=$((queued + 1)) ;;
      401|403) echo "  ⚠️  deploy for $u denied (HTTP $code) — API access or token ability rejected"; failed=$((failed + 1)) ;;
      404) echo "  ⏭️  $u not found (HTTP 404) — the application was deleted from Coolify"; failed=$((failed + 1)) ;;
      *) echo "  ⚠️  deploy for $u returned HTTP $code"; failed=$((failed + 1)) ;;
    esac
  done <<EOF
$uuids
EOF
  echo "  🎯 redeploy summary: ${queued} queued, ${failed} not queued (Coolify builds them in the background)"
}

ensure_registration_open() {
  # Coolify turns open registration OFF once the first user exists (and the
  # setting itself lives in the restored DB), so every previous session can
  # ship back with it disabled. Force it open after each restore so users can
  # always self-register. Runs after the app is healthy (schema exists).
  #
  # The flag is `instance_settings.is_registration_enabled` — Coolify has no
  # `settings` key/value table, so the previous INSERT there always failed
  # (and the to_regclass() guard made it a silent no-op). Best-effort; never
  # fails the session.
  if ! coolify_psql -t -A -c \
      "SELECT to_regclass('public.instance_settings') IS NOT NULL;" 2>/dev/null | grep -q t; then
    echo "  ⚠️  instance_settings table not present yet — skipping registration enable"
    return 0
  fi
  if coolify_psql -v ON_ERROR_STOP=1 -q -c \
      "INSERT INTO instance_settings (is_registration_enabled, is_api_enabled, created_at, updated_at)
         SELECT true, false, now(), now()
         WHERE NOT EXISTS (SELECT 1 FROM instance_settings);
       UPDATE instance_settings SET is_registration_enabled = true, updated_at = now();" \
      >/dev/null 2>&1; then
    echo "  ✅ open registration enabled (instance_settings.is_registration_enabled=true)"
  else
    echo "  ⚠️  could not enable registration — check the session log"
  fi
}

seed_admin() {
  # Deterministic first admin: bootstrapping through the web registration form
  # is rate-limited and easy to flake on, so when the restored DB has no users
  # yet we seed one directly in Postgres (bcrypt via pgcrypto — no php/htpasswd
  # needed on the runner). Only the `users` table is required; teams/pivot rows
  # are only created when their tables/columns exist, so Coolify version drift
  # can't break login. Any failure is non-fatal and logged; open registration
  # stays as the fallback.
  if ! coolify_psql -t -A -c \
      "SELECT to_regclass('public.users') IS NOT NULL;" 2>/dev/null | grep -q t; then
    echo "  ⚠️  users table not present yet — admin seeding skipped"
    return 0
  fi
  local n
  n="$(coolify_psql -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null | head -1 | tr -d ' \r')"
  if [ "$n" != "0" ]; then
    echo "  👤 existing users ($n) — admin seeding skipped"
    return 0
  fi

  local name email pw
  name="$(env_value COOLIFY_ADMIN_NAME)";      [ -z "$name" ] && name="Test Admin"
  email="$(env_value COOLIFY_ADMIN_EMAIL)";    [ -z "$email" ] && email="admin@chuglii.in"
  # Never ship a hard-coded admin password in the repo: an explicit
  # COOLIFY_ADMIN_PASSWORD secret wins, otherwise reuse the value persisted in
  # the archived Coolify env, and only generate+persist one if neither exists.
  pw="${COOLIFY_ADMIN_PASSWORD:-$(env_value COOLIFY_ADMIN_PASSWORD)}"
  [ -n "$pw" ] || pw="$(env_value ADMIN_PASSWORD "$SOURCE_ENV")"
  if [ -z "$pw" ]; then
    pw="$(rand_hex 16)"
    set_env ADMIN_PASSWORD "$pw" "$SOURCE_ENV"
  fi

  local q c
  local has_teams=0 has_team_user=0 has_t_owner=0 has_t_personal=0 has_tu_role=0 has_current_team=0
  q="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('teams');"
  c="$(coolify_psql -t -A -c "$q" 2>/dev/null | head -1 | tr -d ' \r')"
  [ "$c" = "1" ] && has_teams=1
  q="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('team_user');"
  c="$(coolify_psql -t -A -c "$q" 2>/dev/null | head -1 | tr -d ' \r')"
  [ "$c" = "1" ] && has_team_user=1
  q="SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='teams' AND column_name='user_id';"
  c="$(coolify_psql -t -A -c "$q" 2>/dev/null | head -1 | tr -d ' \r')"
  [ "$c" = "1" ] && has_t_owner=1
  q="SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='teams' AND column_name='personal_team';"
  c="$(coolify_psql -t -A -c "$q" 2>/dev/null | head -1 | tr -d ' \r')"
  [ "$c" = "1" ] && has_t_personal=1
  q="SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='team_user' AND column_name='role';"
  c="$(coolify_psql -t -A -c "$q" 2>/dev/null | head -1 | tr -d ' \r')"
  [ "$c" = "1" ] && has_tu_role=1
  q="SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='current_team_id';"
  c="$(coolify_psql -t -A -c "$q" 2>/dev/null | head -1 | tr -d ' \r')"
  [ "$c" = "1" ] && has_current_team=1

  local t_md="" tv_md="" t_exs=""
  [ "$has_t_owner" = "1" ]     && { t_md="$t_md ,user_id";       tv_md="$tv_md ,u_id"; }
  [ "$has_t_personal" = "1" ]  && { t_md="$t_md ,personal_team"; tv_md="$tv_md ,true"; }
  [ "$has_teams" = "1" ]       && t_exs="TRUE" || t_exs="FALSE"
  local tu_md="" tuv_md="" tu_exs="FALSE"
  [ "$has_tu_role" = "1" ]     && { tu_md=" ,role"; tuv_md=" ,'admin'"; }
  [ "$has_team_user" = "1" ]   && tu_exs="TRUE"
  local cur_set=""
  [ "$has_current_team" = "1" ] && cur_set="UPDATE users SET current_team_id=t_id WHERE id=u_id;"

  local sql
  sql=$(cat <<'SQL'
DO $do$
DECLARE
  u_id bigint;
  t_id bigint;
BEGIN
  CREATE EXTENSION IF NOT EXISTS pgcrypto;
  INSERT INTO users (name,email,password,email_verified_at,created_at,updated_at)
    VALUES ('__NAME__','__EMAIL__',crypt('__PW__',gen_salt('bf')),now(),now(),now())
    RETURNING id INTO u_id;
  IF __HAS_TEAMS__ THEN
    INSERT INTO teams (name__T_MD__,created_at,updated_at)
      VALUES ('__NAME__'__TV_MD__,now(),now())
      RETURNING id INTO t_id;
    __SET_CUR__
    IF __HAS_TEAM_USER__ THEN
      INSERT INTO team_user (team_id,user_id__TU_MD__,created_at,updated_at)
        VALUES (t_id,u_id__TUV_MD__,now(),now());
    END IF;
  END IF;
  RAISE NOTICE 'Coolify admin seeded (user %)', u_id;
END
$do$;
SQL
)
  # The values are spliced into SQL string literals — escape single quotes first.
  local name_q email_q pw_q
  name_q="${name//\'/\'\'}"; email_q="${email//\'/\'\'}"; pw_q="${pw//\'/\'\'}"
  sql="${sql//__NAME__/$name_q}"
  sql="${sql//__EMAIL__/$email_q}"
  sql="${sql//__PW__/$pw_q}"
  sql="${sql//__T_MD__/$t_md}";      sql="${sql//__TV_MD__/$tv_md}";      sql="${sql//__HAS_TEAMS__/$t_exs}"
  sql="${sql//__TU_MD__/$tu_md}";    sql="${sql//__TUV_MD__/$tuv_md}";    sql="${sql//__HAS_TEAM_USER__/$tu_exs}"
  sql="${sql//__SET_CUR__/$cur_set}"

  local err
  err="$(coolify_psql -v ON_ERROR_STOP=1 -c "$sql" 2>&1 >/dev/null)"
  if [ -z "$err" ] || ! printf '%s' "$err" | grep -q "ERROR"; then
    n="$(coolify_psql -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null | head -1 | tr -d ' \r')"
    echo "  ✅ admin seeded: $name <$email> ($n user(s) now) — login: $email / $pw"
  else
    echo "  ⚠️  admin seeding failed — ${err//$'\n'/ }"
  fi
}

start() {
  prep

  # ── Phase 1: infra only (db, redis, realtime) — no app yet ──
  echo "🐳 Starting Coolify infrastructure (postgres, redis, realtime)..."
  if ! "${COMPOSE_CMD[@]}" up -d coolify-postgres coolify-redis coolify-realtime 2>&1 | tail -10; then
    echo "  ⚠️  infra up failed — latest logs:"
    "${COMPOSE_CMD[@]}" logs --tail 60 coolify-postgres coolify-redis coolify-realtime 2>/dev/null | tail -60 || true
    return 1
  fi

  # ── Restore Coolify's own DB before the app boots (no migration race) ──
  local cdb_user cdb_name
  cdb_user="$(env_value COOLIFY_DB_USERNAME)"; [ -n "$cdb_user" ] || cdb_user="coolify"
  cdb_name="$(env_value COOLIFY_DB_NAME)";     [ -n "$cdb_name" ] || cdb_name="coolify"
  COOLIFY_DB_READY=0
  for i in $(seq 1 60); do
    if docker exec coolify-db pg_isready -U "$cdb_user" -d "$cdb_name" >/dev/null 2>&1; then
      COOLIFY_DB_READY=1
      break
    fi
    sleep 2
  done
  if [ "$COOLIFY_DB_READY" -ne 1 ]; then
    echo "  ⚠️  coolify-db not accepting connections after 120s — failing step so the session restarts and retries"
    echo "  ⚠️  (starting the app against a missing DB would leave Coolify silently broken for hours)"
    "${COMPOSE_CMD[@]}" logs --tail 30 coolify-postgres 2>/dev/null | tail -30 || true
    return 1
  elif [ -s ./coolify_backup.dump ]; then
    echo "  🗄️  Restoring Coolify DB from coolify_backup.dump ($(du -h ./coolify_backup.dump | cut -f1))..."
    if docker cp ./coolify_backup.dump coolify-db:/tmp/coolify_backup.dump \
       && docker exec coolify-db pg_restore -U "$cdb_user" -d "$cdb_name" \
            --clean --if-exists --no-owner --no-privileges --jobs 2 \
            /tmp/coolify_backup.dump > /tmp/coolify-restore.log 2>&1; then
      echo "  ✅ Coolify DB restored"
    else
      REAL_ERRORS=$(grep -iE "error:" /tmp/coolify-restore.log 2>/dev/null | grep -viE "does not exist|already exists|must be owner of" | head -5 || true)
      if [ -n "$REAL_ERRORS" ]; then
        echo "  ⚠️  Coolify DB restore warnings:"
        echo "$REAL_ERRORS" | sed 's/^/      /'
      else
        echo "  ✅ Coolify DB restored (drop/create notices are harmless)"
      fi
    fi
    rm -f /tmp/coolify-restore.log
    TABLES=$(coolify_psql -t -A -c \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';" 2>/dev/null || echo 0)
    echo "  📊 Coolify user tables (public schema): $TABLES"
  else
    echo "  ℹ️  No coolify_backup.dump — fresh Coolify database"
  fi

  # ── Phase 2: the app ──
  echo "🐳 Starting the Coolify app..."
  if ! "${COMPOSE_CMD[@]}" up -d coolify 2>&1 | tail -10; then
    echo "  ⚠️  compose up failed — latest coolify logs:"
    "${COMPOSE_CMD[@]}" logs --tail 80 coolify 2>/dev/null | tail -80 || true
    return 1
  fi

  echo "Polling Coolify health on http://127.0.0.1:${COOLIFY_PORT}/api/health ..."
  local ok=0
  for i in $(seq 1 60); do
    if curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:${COOLIFY_PORT}/api/health"; then
      ok=1
      break
    fi
    [ $((i % 5)) -eq 0 ] && echo "  ... still waiting (${i}/60)"
    sleep 3
  done

  if [ "$ok" -ne 1 ]; then
    echo "  ⚠️  Coolify is NOT healthy yet. Container state/logs:"
    "${COMPOSE_CMD[@]}" ps coolify 2>/dev/null || true
    "${COMPOSE_CMD[@]}" logs --tail 100 coolify 2>/dev/null | tail -100 || true
    return 1
  fi

  # The container's bind-mounted dirs (ssh/keys, ssh/mux) are owned by the
  # container user and unreadable by the runner user — which made the state
  # archive never rebuild (tar aborts). Normalize perms now that the container
  # has booted, so snapshots can pack them.
  sudo -n chmod -R a+rX "$COOLIFY_DIR" 2>/dev/null || chmod -R a+rX "$COOLIFY_DIR" 2>/dev/null || true

  # Coolify disables open registration after the first user; the setting is
  # stored in the restored DB, so re-allow user signup on every restore.
  ensure_registration_open || true

  # First admin (web registration is rate-limited): seed when no users exist.
  seed_admin || true

  # A COOLIFY_PASSWORD secret must actually be the dashboard password (the
  # seeder only sets it at first boot), so re-hash it onto the root user.
  sync_root_password || true

  # On a fresh VM, previously-deployed apps exist in the restored Coolify DB but
  # nothing is running — bring them back via the API (best-effort). Runs AFTER
  # seed_admin so a user/team exists to mint the deploy token from.
  redeploy_apps || true

  local app_url root_pass pw_display
  app_url="$(env_value COOLIFY_APP_URL)"
  root_pass="$(env_value COOLIFY_ROOT_PASSWORD)"
  # Never print an operator-supplied secret. A generated one is still shown
  # (it is the only way to recover a fresh install); the console never prints it.
  if [ -n "${COOLIFY_PASSWORD:-}" ]; then
    pw_display='set via the `COOLIFY_PASSWORD` repo secret (not printed)'
  else
    pw_display="\`$root_pass\` (generated — store it somewhere safe)"
  fi

  echo ""
  echo "  ✅ Coolify is LIVE on http://127.0.0.1:${COOLIFY_PORT}"
  if [ -n "${COOLIFY_PASSWORD:-}" ]; then
    echo "  🔑 login: coolify / \$COOLIFY_PASSWORD (repo secret; not printed)"
  else
    echo "  🔑 login: coolify / see run summary (generated password)"
  fi
  echo "  🌐 public: $app_url (add a hostname for localhost:${COOLIFY_PORT} in your CF Zero-Trust tunnel)"
  echo "  🎯 apps via Coolify: deploy a frontend, then route *.apps.<your-domain> → localhost:80 (Coolify's managed proxy)"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### 🐳 Coolify is LIVE"
      echo ""
      echo "| Item | Value |"
      echo "|---|---|"
      echo "| **Dashboard** | [http://localhost:${COOLIFY_PORT}](http://localhost:${COOLIFY_PORT}) |"
      echo "| **Public URL** | $app_url |"
      echo "| **Username** | \`coolify\` |"
      echo "| **Password** | $pw_display |"
      echo "| **REST API** | \`curl -H 'Authorization: Bearer <api-token>' ${app_url}/api/v1/...\` |"
      echo ""
      echo "> Add a hostname for \`localhost:${COOLIFY_PORT}\` in your Cloudflare Zero-Trust tunnel ingress for public access. Route deployed apps via \`*.<apps-domain> → localhost:80\`."
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

status() {
  "${COMPOSE_CMD[@]}" ps coolify coolify-postgres coolify-redis coolify-realtime
  echo ""
  echo "Coolify UI:        http://127.0.0.1:${COOLIFY_PORT}"
  echo "Public URL:        $(env_value COOLIFY_APP_URL)"
}

case "$ACTION" in
  prep)    prep ;;
  pull)    pull ;;
  start)   start ;;
  status)  status ;;
  smoke)   smoke ;;
  *) echo "usage: $0 {prep|pull|start|status|smoke}"; exit 1 ;;
esac