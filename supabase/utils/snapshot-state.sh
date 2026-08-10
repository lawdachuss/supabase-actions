#!/usr/bin/env bash
# =============================================================================
# 📸 snapshot-state.sh — snapshot the FULL Supabase state into an archive
# =============================================================================
# Produces ./supabase-state.tar.gz containing:
#   backup.dump          - pg_dump (custom format) of the whole database
#   pgsodium_root.key    - Vault encryption key (from the db-config volume)
#   volumes/functions    - edge functions managed via Studio
#   volumes/snippets     - SQL snippets managed via Studio
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
       && docker compose cp db:/tmp/backup.dump.new ./backup.dump.new \
       && mv -f ./backup.dump.new ./backup.dump; then
    echo "  ✅ database dump updated ($(du -h ./backup.dump | cut -f1))"
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

# ── 3. Pack the full-state archive (tolerates missing pieces) ───────────
ARCHIVE_FILES="volumes/functions volumes/snippets"
[ -s ./backup.dump ] && ARCHIVE_FILES="$ARCHIVE_FILES backup.dump"
[ -s ./pgsodium_root.key ] && ARCHIVE_FILES="$ARCHIVE_FILES pgsodium_root.key"
rm -f ./supabase-state.tar.gz.new
if tar czf ./supabase-state.tar.gz.new -C . $ARCHIVE_FILES 2>/dev/null && \
   mv -f ./supabase-state.tar.gz.new ./supabase-state.tar.gz; then
  SIZE=$(du -h ./supabase-state.tar.gz | cut -f1)
  echo "  ✅ state archive updated ($SIZE): $ARCHIVE_FILES"
else
  rm -f ./supabase-state.tar.gz.new
  echo "  ⚠️  archive creation failed — previous archive preserved"
  exit 1
fi
