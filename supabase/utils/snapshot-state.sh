#!/usr/bin/env bash
# =============================================================================
# 📸 snapshot-state.sh — snapshot the FULL Supabase state into an archive
# =============================================================================
# Produces ./supabase-state.tar.gz containing:
#   backup.dump          - pg_dump (custom format) of the whole database
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

# ── 1. Dump the database (only if the db container is up) ──────────────
if docker compose exec -T db pg_isready -U postgres > /dev/null 2>&1; then
  echo "  🗄️  pg_dump..."
  # -Z 6: good compression for the custom-format dump — keeps snapshots small
  # within GitHub's 10GB per-repo cache budget without burning excessive CPU in
  # the live DB container every 5 minutes (max -Z 9 on a large DB can stall the
  # session). (The analytics/log data lives in the separate '_supabase' database
  # and is intentionally not backed up — it's disposable and would bloat every
  # snapshot.)
  if docker compose exec -T db pg_dump -U postgres -F c -Z 6 -f /tmp/backup.dump.new postgres \
       && docker compose cp db:/tmp/backup.dump.new ./backup.dump.new; then
    NEW_SIZE=$(stat -c%s ./backup.dump.new 2>/dev/null || echo 0)
    OLD_SIZE=$(stat -c%s ./backup.dump 2>/dev/null || echo 0)
    # Safeguard: never overwrite an existing large database backup (>1MB) with a tiny/empty dump (<500KB)
    if [ "$OLD_SIZE" -gt 1000000 ] && [ "$NEW_SIZE" -lt 500000 ]; then
      echo "  ⚠️  DANGER: New dump is suspiciously small (${NEW_SIZE}B vs ${OLD_SIZE}B)."
      echo "  ⚠️  Preserving existing backup.dump (${OLD_SIZE}B) to prevent accidental data loss!"
      rm -f ./backup.dump.new
    else
      mv -f ./backup.dump.new ./backup.dump
      echo "  ✅ database dump updated ($(du -h ./backup.dump | cut -f1))"
    fi
  else
    echo "  ⚠️  pg_dump failed — reusing previous backup.dump (if any)"
  fi
else
  echo "  ℹ️  DB not ready — skipping pg_dump"
fi

# ── 2. Save the pgsodium root key (straight from the db-config volume) ──
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

# ── 3. Save Redis data (if redis container is running) ──────────────────
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

# ── 4. Pack the full-state archive (tolerates missing pieces) ───────────
pack_archive() {
  ARCHIVE_FILES="volumes/functions volumes/snippets"
  [ -s ./backup.dump ] && ARCHIVE_FILES="$ARCHIVE_FILES backup.dump"
  [ -s ./pgsodium_root.key ] && ARCHIVE_FILES="$ARCHIVE_FILES pgsodium_root.key"
  [ -s ./dump.rdb ] && ARCHIVE_FILES="$ARCHIVE_FILES dump.rdb"
  [ -d ./appendonlydir ] && ARCHIVE_FILES="$ARCHIVE_FILES appendonlydir"
  [ -s ./.cf-creds ] && ARCHIVE_FILES="$ARCHIVE_FILES .cf-creds"

  date +%s > ./state-ts
  ARCHIVE_FILES="$ARCHIVE_FILES state-ts"

  rm -f ./supabase-state.tar.gz.new
  TAR_LOG=$(mktemp)
  if tar --warning=no-file-changed \
     -czf ./supabase-state.tar.gz.new -C . $ARCHIVE_FILES 2>"$TAR_LOG" && \
     mv -f ./supabase-state.tar.gz.new ./supabase-state.tar.gz; then
    SIZE=$(du -h ./supabase-state.tar.gz | cut -f1)
    echo "  ✅ state archive updated ($SIZE): $ARCHIVE_FILES"
    rm -f "$TAR_LOG"
    return 0
  else
    rm -f ./supabase-state.tar.gz.new
    echo "  ⚠️  archive creation failed — previous archive preserved"
    [ -s "$TAR_LOG" ] && sed 's/^/      /' "$TAR_LOG"
    rm -f "$TAR_LOG"
    return 1
  fi
}

pack_archive || exit 1

# ── 5. Off-site mirror to Cloudflare KV (best-effort, throttled) ────────
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
