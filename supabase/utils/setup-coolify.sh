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

redeploy_apps() {
  # A fresh GitHub Actions session is a brand-new VM: the Coolify metadata DB,
  # SSH keys and per-app configs survive (restored from the archive), but the
  # deployed containers, images and their volumes do NOT. So after the DB is
  # restored and Coolify is healthy, fire each stored application's Deploy
  # Webhook to bring it back. Apps without a "Deploy Webhook" enabled in the
  # Coolify UI are skipped (endpoint 404s) and stay visible-but-stopped.
  # Best-effort only — never fails the session. Opt out: COOLIFY_AUTO_REDEPLOY=0
  local base_url
  base_url="$(env_value COOLIFY_APP_URL)"
  [ -n "$base_url" ] || base_url="http://127.0.0.1:${COOLIFY_PORT}"
  if [ "${COOLIFY_AUTO_REDEPLOY:-1}" = "1" ]; then
    echo "🐳 Redeploying previously-deployed Coolify applications (fresh VM)..."
  else
    echo "  ℹ️  auto-redeploy disabled (COOLIFY_AUTO_REDEPLOY=0) — apps stay stopped"
    return 0
  fi

  local uuids u
  uuids="$(docker exec coolify-db psql -U coolify -d coolify -t -A \
    -c "SELECT uuid FROM applications;" 2>/dev/null || true)"
  uuids="$(printf '%s\n' "$uuids" | grep -E '^[0-9a-f-]{36}$' || true)"
  [ -z "$uuids" ] && { echo "  🎯 no applications stored in Coolify yet — nothing to redeploy"; return 0; }

  echo "  🎯 ${base_url%/}/deploy webhook ..."
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -X POST \
      "${base_url%/}/deploy?uuid=$u" 2>/dev/null || echo 000)"
    case "$code" in
      200|201|202|204|302) echo "  ✅ queued redeploy for $u (HTTP $code)" ;;
      404) echo "  ⏭️  $u has no Deploy Webhook enabled (enable it in the app's settings for auto-redeploy)" ;;
      *) echo "  ⚠️  deploy webhook for $u returned HTTP $code" ;;
    esac
  done <<EOF
$uuids
EOF
}

ensure_registration_open() {
  # Coolify turns open registration OFF once the first user exists (and the
  # setting itself lives in the restored DB), so every previous session can
  # ship back with it disabled. Force it open after each restore so users can
  # always self-register. Runs after the app is healthy (schema exists) using
  # Coolify's own `settings` table. Best-effort; never fails the session.
  if ! docker exec coolify-db psql -U coolify -d coolify -t -A -c \
      "SELECT to_regclass('public.settings') IS NOT NULL;" 2>/dev/null | grep -q t; then
    echo "  ⚠️  settings table not present yet — skipping registration enable"
    return 0
  fi
  if docker exec coolify-db psql -U coolify -d coolify -v ON_ERROR_STOP=1 -q -c \
      "INSERT INTO settings (key, value) VALUES ('register_enabled', 'true')
       ON CONFLICT (key) DO UPDATE SET value = 'true';" >/dev/null 2>&1; then
    echo "  ✅ open registration enabled (register_enabled=true)"
  else
    echo "  ⚠️  could not enable registration — check the session log"
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
  COOLIFY_DB_READY=0
  for i in $(seq 1 60); do
    if docker exec coolify-db pg_isready -U coolify -d coolify >/dev/null 2>&1; then
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

  # The container's bind-mounted dirs (ssh/keys, ssh/mux) are owned by the
  # container user and unreadable by the runner user — which made the state
  # archive never rebuild (tar aborts). Normalize perms now that the container
  # has booted, so snapshots can pack them.
  sudo -n chmod -R a+rX "$COOLIFY_DIR" 2>/dev/null || chmod -R a+rX "$COOLIFY_DIR" 2>/dev/null || true

  # On a fresh VM, previously-deployed apps exist in the restored Coolify DB but
  # nothing is running — bring them back via their Deploy Webhooks (best-effort).
  redeploy_apps || true

  # Coolify disables open registration after the first user; the setting is
  # stored in the restored DB, so re-allow user signup on every restore.
  ensure_registration_open || true

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