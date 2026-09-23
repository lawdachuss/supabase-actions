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
#   coolify_backup.dump  - pg_dump of the companion Coolify stack's own DB
#   volumes/coolify/...  - Coolify secrets + SSH keys (kept stable across
#                          sessions so APP_KEY still decrypts stored creds)
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

# ── 3b. Save the companion Coolify stack's own DB (if its postgres is up) ──
# Coolify keeps its config (projects, apps, servers, private keys) in its own
# database inside the coolify-db container. We exec into the running container
# by NAME (not the compose service) so this works regardless of which compose
# files are currently in scope. The DB user/name are read from .env (written by
# setup-coolify.sh prep) so a non-default COOLIFY_DB_USERNAME / COOLIFY_DB_NAME
# still dumps correctly.
COOLIFY_DB_USER="$(grep -E '^COOLIFY_DB_USERNAME=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
COOLIFY_DB_NAME="$(grep -E '^COOLIFY_DB_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
COOLIFY_DB_USER="${COOLIFY_DB_USER:-coolify}"
COOLIFY_DB_NAME="${COOLIFY_DB_NAME:-coolify}"
if docker exec coolify-db pg_isready -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" > /dev/null 2>&1; then
  echo "  🗄️  pg_dump coolify-db..."
  if docker exec coolify-db sh -c "pg_dump -U '$COOLIFY_DB_USER' -d '$COOLIFY_DB_NAME' -F c -Z 6 -f /tmp/coolify_backup.dump.new" \
     && docker cp coolify-db:/tmp/coolify_backup.dump.new ./coolify_backup.dump.new; then
    NEW_SIZE=$(stat -c%s ./coolify_backup.dump.new 2>/dev/null || echo 0)
    OLD_SIZE=$(stat -c%s ./coolify_backup.dump 2>/dev/null || echo 0)
    if [ "$OLD_SIZE" -gt 1000000 ] && [ "$NEW_SIZE" -lt 500000 ]; then
      # Same safeguard as the main dump: never clobber a real backup with a
      # truncated/suspicious tiny one.
      echo "  ⚠️  DANGER: new Coolify dump suspiciously small (${NEW_SIZE}B vs ${OLD_SIZE}B) — keeping previous"
      rm -f ./coolify_backup.dump.new
    elif [ "$NEW_SIZE" -gt 100 ]; then
      mv -f ./coolify_backup.dump.new ./coolify_backup.dump
      echo "  ✅ Coolify db dump updated ($(du -h ./coolify_backup.dump | cut -f1))"
    else
      echo "  ⚠️  Coolify dump empty — keeping previous"
      rm -f ./coolify_backup.dump.new
    fi
  else
    echo "  ⚠️  Coolify pg_dump failed — reusing previous coolify_backup.dump (if any)"
  fi
else
  echo "  ℹ️  Coolify db not ready — skipping its dump"
fi

# ── 4. Off-site mirror to Cloudflare KV (best-effort, throttled) ────────
# Runs BEFORE the archive is (re)packed below: a push can force an OAuth
# refresh-token rotation, and packing afterwards means the freshly rotated
# token inside .cf-creds is what ends up in the archive — otherwise the next
# session would hold an already-consumed token and the chain would die.
# cloudflare-backup.sh keeps 'latest/' fresh, stamps the same bytes under
# archive/<ts>/ and prunes the OLDEST generations — remote storage never
# grows, and the freshest backup survives even if the GitHub cache/artifacts
# are wiped for any reason. (KV gets the PREVIOUS snapshot's bytes — at most
# one 5-min cycle older; the restore step picks whichever copy is newer.)
PUSH_INTERVAL=1500   # push at most once per ~25 min (KV free: 1k writes/day)
CF_MARKER=./.cf_push_last
if [ -s ./supabase-state.tar.gz ]; then
  DO_PUSH=1
  if [ -f "$CF_MARKER" ]; then
    LAST_PUSH=$(cat "$CF_MARKER" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ $(( NOW - LAST_PUSH )) -lt $PUSH_INTERVAL ]; then DO_PUSH=0; fi
  fi
  if [ "$DO_PUSH" = 1 ]; then
    echo "  ☁️  pushing to Cloudflare..."
    bash utils/cloudflare-backup.sh push ./supabase-state.tar.gz || true
    bash utils/cloudflare-backup.sh verify || true
    date +%s > "$CF_MARKER"
  else
    echo "  ℹ️  Cloudflare push skipped (last push < ${PUSH_INTERVAL}s ago)"
  fi
fi

# ── 5. Pack the full-state archive (tolerates missing pieces) ───────────
ARCHIVE_FILES="volumes/functions volumes/snippets"
[ -s ./backup.dump ] && ARCHIVE_FILES="$ARCHIVE_FILES backup.dump"
[ -s ./pgsodium_root.key ] && ARCHIVE_FILES="$ARCHIVE_FILES pgsodium_root.key"
[ -s ./dump.rdb ] && ARCHIVE_FILES="$ARCHIVE_FILES dump.rdb"
[ -d ./appendonlydir ] && ARCHIVE_FILES="$ARCHIVE_FILES appendonlydir"
[ -s ./coolify_backup.dump ] && ARCHIVE_FILES="$ARCHIVE_FILES coolify_backup.dump"
[ -s ./volumes/coolify/source/.env ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/source/.env"
[ -d ./volumes/coolify/ssh ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/ssh"
# Rotated Cloudflare refresh token (single-use) — the ONLY copy that survives
# the per-run .env recreation; without it off-site backups die after one session.
[ -s ./.cf-creds ] && ARCHIVE_FILES="$ARCHIVE_FILES .cf-creds"
# Coolify's on-disk state for projects/apps (generated compose files etc.) — so
# a restored session has byte-identical configs for the auto-redeploy pass.
[ -d ./volumes/coolify/applications ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/applications"
[ -d ./volumes/coolify/databases ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/databases"
[ -d ./volumes/coolify/services ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/services"
[ -d ./volumes/coolify/backups ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/backups"

# Snapshot timestamp packed INTO the archive — the restore step compares it
# with the off-site KV manifest ts and adopts whichever backup is fresher
# (a cancelled run never reaches the end-of-run cache save).
date +%s > ./state-ts
ARCHIVE_FILES="$ARCHIVE_FILES state-ts"

# Coolify's container writes bind-mounted dirs (ssh/keys, ssh/mux) as ITS OWN
# user, which the runner user cannot read — that makes tar abort and the state
# archive go permanently stale (users/deployments never persist, KV never
# updates). Normalize permissions before packing, and never let an unreadable
# entry abort the archive. The transient ssh/mux sockets are excluded.
sudo -n chmod -R a+rX ./volumes/coolify 2>/dev/null || chmod -R a+rX ./volumes/coolify 2>/dev/null || true

rm -f ./supabase-state.tar.gz.new
TAR_LOG=$(mktemp)
# NOTE: the exclude pattern must match the stored member names, which are
# built by `-C .` + relative paths and therefore have NO './' prefix. The old
# './volumes/coolify/ssh/mux/*' pattern never matched anything, so the
# transient SSH mux sockets (owned by the container user, unreadable by the
# runner) were packed anyway — exactly what this exclude exists to prevent.
if tar --warning=no-file-changed --ignore-failed-read \
   --exclude='volumes/coolify/ssh/mux' \
   --exclude='./volumes/coolify/ssh/mux' \
   -czf ./supabase-state.tar.gz.new -C . $ARCHIVE_FILES 2>"$TAR_LOG" && \
   mv -f ./supabase-state.tar.gz.new ./supabase-state.tar.gz; then
  SIZE=$(du -h ./supabase-state.tar.gz | cut -f1)
  echo "  ✅ state archive updated ($SIZE): $ARCHIVE_FILES"
  rm -f "$TAR_LOG"
else
  rm -f ./supabase-state.tar.gz.new
  echo "  ⚠️  archive creation failed — previous archive preserved"
  [ -s "$TAR_LOG" ] && sed 's/^/      /' "$TAR_LOG"
  rm -f "$TAR_LOG"
  exit 1
fi
