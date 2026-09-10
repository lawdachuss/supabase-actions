#!/usr/bin/env bash
# =============================================================================
# 📸 snapshot-state.sh — snapshot the FULL Supabase state into an archive
# =============================================================================
# Produces ./supabase-state.tar.gz containing:
#   backup.dump          - pg_dump (custom format) of the whole database
#   pgsodium_root.key    - Vault encryption key (from the db-config volume)
#   volumes/functions    - edge functions managed via Studio
#   volumes/snippets     - SQL snippets managed via Studio
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
if docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "^redis$"; then
  echo "  💾 saving Redis data..."
  REDIS_AUTH_FLAG=""
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    REDIS_AUTH_FLAG="-a ${REDIS_PASSWORD}"
  fi
  docker compose exec -T redis redis-cli $REDIS_AUTH_FLAG save > /dev/null 2>&1 || true
  # Safely copy dump.rdb via docker cp (daemon level, avoids directory lock/race)
  if docker compose cp redis:/data/dump.rdb ./dump.rdb.new 2>/dev/null && [ -s ./dump.rdb.new ]; then
    mv -f ./dump.rdb.new ./dump.rdb
    chmod 644 ./dump.rdb 2>/dev/null || true
    echo "  ✅ Redis dump saved ($(du -h ./dump.rdb | cut -f1))"
  elif [ -s ./volumes/redis/data/dump.rdb ]; then
    cp -f ./volumes/redis/data/dump.rdb ./dump.rdb 2>/dev/null || true
    chmod 644 ./dump.rdb 2>/dev/null || true
    echo "  ✅ Redis dump copied ($(du -h ./dump.rdb | cut -f1))"
  fi
fi

# ── 3b. Save the companion Coolify stack's own DB (if its postgres is up) ──
# Coolify keeps its config (projects, apps, servers, private keys) in its own
# 'coolify' database inside the coolify-db container. We exec into the running
# container by NAME (not the compose service) so this works regardless of which
# compose files are currently in scope.
if docker exec coolify-db pg_isready -U coolify -d coolify > /dev/null 2>&1; then
  echo "  🗄️  pg_dump coolify-db..."
  if docker exec coolify-db sh -c "pg_dump -U coolify -d coolify -F c -Z 6 -f /tmp/coolify_backup.dump.new" \
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

# ── 4. Pack the full-state archive (tolerates missing pieces) ───────────
ARCHIVE_FILES="volumes/functions volumes/snippets"
[ -s ./backup.dump ] && ARCHIVE_FILES="$ARCHIVE_FILES backup.dump"
[ -s ./pgsodium_root.key ] && ARCHIVE_FILES="$ARCHIVE_FILES pgsodium_root.key"
[ -s ./dump.rdb ] && ARCHIVE_FILES="$ARCHIVE_FILES dump.rdb"
[ -s ./coolify_backup.dump ] && ARCHIVE_FILES="$ARCHIVE_FILES coolify_backup.dump"
[ -s ./volumes/coolify/source/.env ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/source/.env"
[ -d ./volumes/coolify/ssh ] && ARCHIVE_FILES="$ARCHIVE_FILES volumes/coolify/ssh"
rm -f ./supabase-state.tar.gz.new
TAR_LOG=$(mktemp)
if tar --warning=no-file-changed -czf ./supabase-state.tar.gz.new -C . $ARCHIVE_FILES 2>"$TAR_LOG" && \
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

# ── 5. Off-site mirror to Cloudflare KV (best-effort, throttled) ────────
# The archive already contains DB dumps + Coolify secrets + pgsodium key, so a
# single push covers everything. cloudflare-backup.sh keeps 'latest/' fresh,
# stamps the same bytes under archive/<ts>/ and prunes the OLDEST generations —
# remote storage never grows, and the freshest backup survives even if the
# GitHub cache/artifacts are wiped for any reason.
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
    date +%s > "$CF_MARKER"
  else
    echo "  ℹ️  Cloudflare push skipped (last push < ${PUSH_INTERVAL}s ago)"
  fi
fi
