#!/usr/bin/env bash
# =============================================================================
# 📸 snapshot-state.sh — snapshot the FULL Supabase state into an archive
# =============================================================================
# Produces ./supabase-state.tar.gz containing:
#   db-backups/          - custom-format dumps of every connectable database
#   db-backups/globals.sql - roles, memberships, and tablespaces
#   .state-settings.env  - allowlisted non-secret runtime settings
#   postgresql.auto.conf - PostgreSQL ALTER SYSTEM settings
#   pgsodium_root.key    - Vault encryption key (from the db-config volume)
#   volumes/functions    - edge functions managed via Studio
#   volumes/snippets     - SQL snippets managed via Studio
#   dump.rdb             - Redis RDB (compact, secondary/fallback)
#   appendonlydir/       - Redis AOF (primary: written on every change)
#
# Called by the keepalive loop every 5 minutes AND by the final shutdown step.
# Crash-safe: a previous archive is never removed until the new one is fully
# written (write .new, then atomic mv).
# =============================================================================
set -uo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$COMPOSE_DIR"

# ── 1. Dump every connectable database and cluster globals ─────────────
if ! docker compose exec -T db pg_isready -U postgres > /dev/null 2>&1; then
  echo "  ERROR: PostgreSQL is not ready; keeping the previous complete archive" >&2
  exit 1
fi

DB_STAGING="$(mktemp -d ./db-backups.new.XXXXXX)"
if ! DB_LIST=$(docker compose exec -T db psql -U postgres -d postgres -At -F '|' -c \
  "SELECT replace(encode(convert_to(datname, 'UTF8'), 'base64'), chr(10), '') || '|' || replace(encode(convert_to(pg_get_userbyid(datdba), 'UTF8'), 'base64'), chr(10), '') FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"); then
  echo "  ERROR: could not enumerate PostgreSQL databases; keeping the previous archive" >&2
  rm -rf "$DB_STAGING"
  exit 1
fi
if [ -z "$DB_LIST" ]; then
  echo "  ERROR: PostgreSQL returned no connectable databases; keeping the previous archive" >&2
  rm -rf "$DB_STAGING"
  exit 1
fi

if ! docker compose exec -T db pg_dumpall -U postgres --globals-only > "$DB_STAGING/globals.sql"; then
  echo "  ERROR: failed to dump PostgreSQL roles and global settings" >&2
  rm -rf "$DB_STAGING"
  exit 1
fi

: > "$DB_STAGING/manifest.tsv"
DB_INDEX=0
while IFS='|' read -r DB_NAME_B64 DB_OWNER_B64; do
  [ -n "$DB_NAME_B64" ] || continue
  DB_INDEX=$((DB_INDEX + 1))
  DB_NAME="$(printf '%s' "$DB_NAME_B64" | base64 -d)"
  DB_OWNER="$(printf '%s' "$DB_OWNER_B64" | base64 -d)"
  if [ -z "$DB_NAME" ] || [ -z "$DB_OWNER" ]; then
    echo "  ERROR: invalid database metadata returned by PostgreSQL" >&2
    rm -rf "$DB_STAGING"
    exit 1
  fi
  DB_DUMP_NAME="$(printf 'db-%08d.dump' "$DB_INDEX")"
  echo "  🗄️  dumping database: $DB_NAME"
  if ! docker compose exec -T db pg_dump -U postgres --format=custom --compress=6 --create \
       --dbname="$DB_NAME" > "$DB_STAGING/$DB_DUMP_NAME" \
       || [ ! -s "$DB_STAGING/$DB_DUMP_NAME" ]; then
    echo "  ERROR: failed to dump database: $DB_NAME" >&2
    rm -rf "$DB_STAGING"
    exit 1
  fi
  if ! docker compose cp "$DB_STAGING/$DB_DUMP_NAME" db:/tmp/state-validation.dump \
       || ! docker compose exec -T db pg_restore --list /tmp/state-validation.dump >/dev/null \
       || ! docker compose exec -T db rm -f /tmp/state-validation.dump; then
    echo "  ERROR: PostgreSQL dump validation failed for database: $DB_NAME" >&2
    rm -rf "$DB_STAGING"
    exit 1
  fi
  printf '%s\t%s\t%s\n' "$DB_DUMP_NAME" "$DB_NAME_B64" "$DB_OWNER_B64" >> "$DB_STAGING/manifest.tsv"
done <<EOF
$DB_LIST
EOF

if [ "$DB_INDEX" -eq 0 ]; then
  echo "  ERROR: no database dumps were created; keeping the previous archive" >&2
  rm -rf "$DB_STAGING"
  exit 1
fi

DB_OLD="./db-backups.previous"
rm -rf "$DB_OLD"
if [ -d ./db-backups ]; then
  mv ./db-backups "$DB_OLD"
fi
if mv "$DB_STAGING" ./db-backups; then
  DB_STAGING=""
  rm -rf "$DB_OLD"
  echo "  ✅ complete database snapshot updated ($DB_INDEX databases)"
else
  [ ! -d "$DB_OLD" ] || mv "$DB_OLD" ./db-backups
  echo "  ERROR: could not publish the complete database snapshot" >&2
  rm -rf "$DB_STAGING"
  exit 1
fi

if ! bash utils/state-settings.sh save; then
  echo "  ERROR: could not snapshot runtime settings" >&2
  exit 1
fi

# ── 2. Save PostgreSQL ALTER SYSTEM settings ───────────────────────────
PG_AUTO_CONF_NEW=./postgresql.auto.conf.new
if docker compose exec -T db sh -c 'test -f "$PGDATA/postgresql.auto.conf"'; then
  if ! docker compose exec -T db sh -c 'cat "$PGDATA/postgresql.auto.conf"' > "$PG_AUTO_CONF_NEW"; then
    echo "  ERROR: could not snapshot PostgreSQL ALTER SYSTEM settings" >&2
    rm -f "$PG_AUTO_CONF_NEW"
    exit 1
  fi
  if [ -s "$PG_AUTO_CONF_NEW" ]; then
    mv -f "$PG_AUTO_CONF_NEW" ./postgresql.auto.conf
  else
    rm -f "$PG_AUTO_CONF_NEW" ./postgresql.auto.conf
  fi
else
  rm -f "$PG_AUTO_CONF_NEW" ./postgresql.auto.conf
fi

# ── 3. Save the pgsodium root key (straight from the db-config volume) ──
DB_VOL=$(docker volume ls --format '{{.Name}}' | grep -E 'db-config$' | head -1 || true)
if [ -n "$DB_VOL" ] && \
   docker run --rm -v "$DB_VOL":/etc/postgresql-custom supabase/postgres:17.6.1.136 \
     sh -c "cat /etc/postgresql-custom/pgsodium_root.key" > ./pgsodium_root.key 2>/dev/null && \
   [ -s ./pgsodium_root.key ]; then
  echo "  🔑 pgsodium root key saved"
else
  rm -f ./pgsodium_root.key
  echo "  ℹ️  no pgsodium key found in db-config volume"
fi

# ── 4. Save Redis data (if redis container is running) ──────────────────
# Redis persists in two formats and BOTH are archived:
#   appendonlydir/  AOF — primary. Appended on every write, so it captures
#                   everything up to the last second (durable across in-session
#                   container restarts and hard kills).
#   dump.rdb        RDB — compact secondary and fallback if the AOF is ever
#                   missing/unreadable on restore.
if docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "^redis$"; then
  echo "  💾 saving Redis data..."
  REDIS_AUTH_FLAG=""
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    REDIS_AUTH_FLAG="-a ${REDIS_PASSWORD}"
  fi
  redis_cli() { docker compose exec -T redis redis-cli $REDIS_AUTH_FLAG "$@" 2>/dev/null; }

  # Poll until ALL named background-persistence flags report 0. Redis only
  # renames a completed dump/rewrite into place at the very end, so copying
  # while one is in flight (or merely scheduled) would capture a partial file —
  # and a broken RDB/AOF makes Redis refuse to boot on the next session.
  # `aof_rewrite_scheduled` matters too: a rewrite that is queued but not yet
  # started would otherwise kick off halfway through our copy.
  wait_persistence() {
    local tries="${1:-30}"; shift
    for _ in $(seq 1 "$tries"); do
      local info busy=0
      info=$(redis_cli info persistence || true)
      for field in "$@"; do
        if echo "$info" | grep -q "${field}:1"; then busy=1; fi
      done
      if [ "$busy" -eq 0 ]; then return 0; fi
      sleep 1
    done
    return 1
  }

  # BGSAVE/BGREWRITEAOF instead of SAVE: a plain SAVE BLOCKS the server for the
  # whole dump, stalling every client (and Kong's rate limiting) for seconds
  # every 5 minutes. The background variants let Redis keep serving.
  redis_cli bgsave > /dev/null 2>&1 || true
  wait_persistence 30 rdb_bgsave_in_progress rdb_bgsave_scheduled || echo "  ⚠️  BGSAVE still running after 30s"

  # Compact the AOF so the archived copy stays small. Also async.
  AOF_ENABLED=$(redis_cli config get appendonly | tail -1 || true)
  if [ "$AOF_ENABLED" = "yes" ]; then
    redis_cli bgrewriteaof > /dev/null 2>&1 || true
    wait_persistence 30 aof_rewrite_scheduled aof_rewrite_in_progress || \
      echo "  ⚠️  BGREWRITEAOF still running after 30s"
  fi

  # Copy dump.rdb via docker cp (daemon level, avoids directory lock/race).
  # Validate the RDB magic header before publishing it — a half-written file
  # would be worse than a stale one, because Redis would fail to start.
  if docker compose cp redis:/data/dump.rdb ./dump.rdb.new 2>/dev/null && \
     [ -s ./dump.rdb.new ] && [ "$(head -c 5 ./dump.rdb.new 2>/dev/null)" = "REDIS" ]; then
    mv -f ./dump.rdb.new ./dump.rdb
    chmod 644 ./dump.rdb 2>/dev/null || true
    echo "  ✅ Redis RDB saved ($(du -h ./dump.rdb | cut -f1))"
  else
    rm -f ./dump.rdb.new
    if [ -s ./volumes/redis/data/dump.rdb ]; then
      cp -f ./volumes/redis/data/dump.rdb ./dump.rdb 2>/dev/null || true
      chmod 644 ./dump.rdb 2>/dev/null || true
      echo "  ✅ Redis RDB copied ($(du -h ./dump.rdb | cut -f1))"
    fi
  fi

  # AOF (Redis 7 multi-part: appendonlydir/ + .manifest). Only published when
  # the manifest AND at least one .aof file are present: a partial directory
  # would stop Redis from starting on restore, which is worse than losing a tail.
  if [ "$AOF_ENABLED" = "yes" ]; then
    rm -rf ./appendonlydir.new
    mkdir -p ./appendonlydir.new
    if docker compose cp redis:/data/appendonlydir/. ./appendonlydir.new/ 2>/dev/null && \
       [ -s ./appendonlydir.new/appendonly.aof.manifest ] && \
       ls ./appendonlydir.new/*.aof > /dev/null 2>&1; then
      rm -rf ./appendonlydir
      mv -f ./appendonlydir.new ./appendonlydir
      chmod -R a+rX ./appendonlydir 2>/dev/null || true
      echo "  ✅ Redis AOF saved ($(du -sh ./appendonlydir | cut -f1))"
    else
      rm -rf ./appendonlydir.new
      echo "  ⚠️  Redis AOF incomplete — keeping previous copy (RDB still archived)"
    fi
  fi
fi

# ── 5. Pack the full-state archive ─────────────────────────────────────
pack_archive() {
  local archive_files=(volumes/functions volumes/snippets db-backups)
  local inbucket_stage="" tar_log
  local -a tar_args
  [ -f ./.state-settings.env ] && archive_files+=(.state-settings.env)
  [ -s ./postgresql.auto.conf ] && archive_files+=(postgresql.auto.conf)
  [ -s ./pgsodium_root.key ] && archive_files+=(pgsodium_root.key)
  [ -s ./dump.rdb ] && archive_files+=(dump.rdb)
  [ -d ./appendonlydir ] && archive_files+=(appendonlydir)
  [ -s ./.cf-creds ] && archive_files+=(.cf-creds)

  date +%s > ./state-ts
  archive_files+=(state-ts)

  if docker compose ps --services --filter "status=running" 2>/dev/null \
    | grep -qx "supabase-mail"; then
    inbucket_stage="$(mktemp -d ./inbucket-snapshot.XXXXXX)" || return 1
    if ! mkdir -p "$inbucket_stage/volumes/inbucket/data"; then
      rm -rf "$inbucket_stage"
      return 1
    fi
    if ! docker compose cp supabase-mail:/data/. "$inbucket_stage/volumes/inbucket/data/"; then
      echo "  ERROR: could not copy Inbucket mail from the running container" >&2
      rm -rf "$inbucket_stage"
      return 1
    fi
  elif [ -d ./volumes/inbucket/data ]; then
    archive_files+=(volumes/inbucket/data)
  fi

  rm -f ./supabase-state.tar.gz.new
  tar_log="$(mktemp)"
  tar_args=(--warning=no-file-changed -czf ./supabase-state.tar.gz.new -C .)
  tar_args+=("${archive_files[@]}")
  if [ -n "$inbucket_stage" ]; then
    tar_args+=(-C "$inbucket_stage" volumes/inbucket/data)
  fi
  if tar "${tar_args[@]}" 2>"$tar_log" && \
     mv -f ./supabase-state.tar.gz.new ./supabase-state.tar.gz; then
    SIZE=$(du -h ./supabase-state.tar.gz | cut -f1)
    echo "  ✅ full-state archive updated ($SIZE)"
    rm -f "$tar_log"
    [ -z "$inbucket_stage" ] || rm -rf "$inbucket_stage"
    return 0
  else
    rm -f ./supabase-state.tar.gz.new
    echo "  ⚠️  archive creation failed — previous archive preserved"
    [ -s "$tar_log" ] && sed 's/^/      /' "$tar_log"
    rm -f "$tar_log"
    [ -z "$inbucket_stage" ] || rm -rf "$inbucket_stage"
    return 1
  fi
}

pack_archive || exit 1

# ── 6. Off-site mirror to Cloudflare KV (best-effort, throttled) ────────
PUSH_INTERVAL=1500
CF_MARKER=./.cf_push_last
if [ -s ./supabase-state.tar.gz ]; then
  DO_PUSH=1
  if [ -f "$CF_MARKER" ]; then
    LAST_PUSH=$(cat "$CF_MARKER" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ $(( NOW - LAST_PUSH )) -lt $PUSH_INTERVAL ]; then DO_PUSH=0; fi
  fi
  if [ "$DO_PUSH" = 1 ]; then
    CRED_SYNC_STABLE=0
    CRED_SYNC_ATTEMPT=0
    while [ "$CRED_SYNC_ATTEMPT" -lt 3 ]; do
      CRED_SYNC_ATTEMPT=$(( CRED_SYNC_ATTEMPT + 1 ))
      CF_CREDS_BEFORE=""
      [ -s ./.cf-creds ] && CF_CREDS_BEFORE=$(sha256sum ./.cf-creds 2>/dev/null | cut -d' ' -f1)
      echo "  ☁️  pushing to Cloudflare..."
      bash utils/cloudflare-backup.sh push ./supabase-state.tar.gz || true
      CF_CREDS_AFTER=""
      [ -s ./.cf-creds ] && CF_CREDS_AFTER=$(sha256sum ./.cf-creds 2>/dev/null | cut -d' ' -f1)
      if [ "$CF_CREDS_BEFORE" = "$CF_CREDS_AFTER" ]; then
        CRED_SYNC_STABLE=1
        break
      fi
      echo "  ☁️  backup credentials rotated — repacking current state"
      pack_archive || exit 1
    done
    bash utils/cloudflare-backup.sh verify || true
    if [ "$CRED_SYNC_STABLE" != 1 ]; then
      echo "  ⚠️  Cloudflare credentials changed repeatedly; local archive is current, but the off-site token may require a later successful push"
    fi
    date +%s > "$CF_MARKER"
  else
    echo "  ℹ️  Cloudflare push skipped (last push < ${PUSH_INTERVAL}s ago)"
  fi
fi
