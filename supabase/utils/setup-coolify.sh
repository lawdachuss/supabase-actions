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
# Idempotent key=value writer (keeps values safe for sed's '|' delimiter)
set_env() { # key value file
  local key="$1" val="$2" file="$3"
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
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

prep() {
  echo "🐳 [1/4] Preparing Coolify storage layout..."
  mkdir -p "$COOLIFY_DIR"/{source,ssh/keys,ssh/mux,applications,databases,services,backups,images/avatars,images/project-icons,proxy,sentinel}

  echo "🐳 [2/4] Deriving secrets and writing env files..."

  # Public URL: coolify.<base-of-tunnel-domain> (fallback: localhost)
  local domain="${CF_TUNNEL_DOMAIN:-${COOLIFY_DOMAIN:-}}"
  if [ -n "$domain" ]; then
    local base; base="$(echo "$domain" | sed 's/^supabase\.//')"
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

  local app_id app_key db_user db_name db_pass redis_pass pusher_id pusher_key pusher_secret root_pass
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
  root_pass="$(pval ROOT_USER_PASSWORD)";   [ -z "$root_pass" ]    && root_pass="$(rand_secret 18)"
  # an explicit COOLIFY_PASSWORD secret always wins
  [ -n "${COOLIFY_PASSWORD:-}" ] && root_pass="$COOLIFY_PASSWORD"

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
ROOT_USER_EMAIL=coolify@localhost
ROOT_USER_PASSWORD=$root_pass
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
  COOLIFY_DB_READY=0
  for i in $(seq 1 60); do
    if docker exec coolify-db pg_isready -U coolify -d coolify >/dev/null 2>&1; then
      COOLIFY_DB_READY=1
      break
    fi
    sleep 2
  done
  if [ "$COOLIFY_DB_READY" -ne 1 ]; then
    echo "  ⚠️  coolify-db not accepting connections — starting app without DB restore"
  elif [ -s ./coolify_backup.dump ]; then
    echo "  🗄️  Restoring Coolify DB from coolify_backup.dump ($(du -h ./coolify_backup.dump | cut -f1))..."
    if docker cp ./coolify_backup.dump coolify-db:/tmp/coolify_backup.dump \
       && docker exec coolify-db pg_restore -U coolify -d coolify \
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
    TABLES=$(docker exec coolify-db psql -U coolify -t -A -c \
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

  local app_url root_pass
  app_url="$(env_value COOLIFY_APP_URL)"
  root_pass="$(env_value COOLIFY_ROOT_PASSWORD)"

  echo ""
  echo "  ✅ Coolify is LIVE on http://127.0.0.1:${COOLIFY_PORT}"
  echo "  🔑 login: coolify / <Coolify root password> (secrets.COOLIFY_PASSWORD or persisted/random, see run summary)"
  echo "  🌐 public: $app_url (add a hostname for localhost:${COOLIFY_PORT} in your CF Zero-Trust tunnel)"
  echo "  🎯 apps via Coolify: deploy a frontend, then route *.apps.<your-domain> → localhost:80 (Traefik)"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### 🐳 Coolify is LIVE"
      echo ""
      echo "| Item | Value |"
      echo "|---|---|"
      echo "| **Dashboard** | [http://localhost:${COOLIFY_PORT}](http://localhost:${COOLIFY_PORT}) |"
      echo "| **Public URL** | $app_url |"
      echo "| **Username** | \`coolify\` |"
      echo "| **Password** | \`$root_pass\` (or the \`COOLIFY_PASSWORD\` secret) |"
      echo "| **REST API** | \`https://<your-api-token>@${app_url}/api/v1\` |"
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
  *) echo "usage: $0 {prep|pull|start|status}"; exit 1 ;;
esac