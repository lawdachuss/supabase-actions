#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/supabase" && pwd)"
cd "$COMPOSE_DIR"

# Default compose files when COMPOSE_FILE env var is not set
DEFAULT_FILES="docker-compose.yml:docker-compose.logs.yml"
COMPOSE_FILE="${COMPOSE_FILE:-$DEFAULT_FILES}"

# Convert colon-separated paths to -f arguments for docker compose
build_f_args() {
  local files
  IFS=':' read -ra files <<< "$COMPOSE_FILE"
  for f in "${files[@]}"; do
    echo -n "-f $f "
  done
}

usage() {
  cat <<EOF
Usage: ./run.sh <command>

Commands:
  start              Start Supabase (safe restart if already running)
  stop               Stop all containers (no data loss)
  restart            Restart all containers
  status             Show container status
  logs [service]     Show logs (optional: filter by service name)
  psql               Open interactive PostgreSQL shell
  backup [dir]       Backup database to timestamped archive
  restore <file>     Restore from a backup archive
  reset              WARNING: Deletes ALL data and resets from scratch
  config             Show available compose overrides
  gen-keys           Generate fresh secrets and API keys (interactive)
  gen-auth-keys      Generate asymmetric ES256 + opaque API keys
  gen-token          Generate a new personal access token (sbp_)
  list-tokens        List all personal access tokens
  revoke-token       Revoke a personal access token by UUID

EOF
}

get_compose_cmd() {
  if docker compose version &>/dev/null; then
    echo "docker compose"
  elif docker-compose --version &>/dev/null; then
    echo "docker-compose"
  else
    echo "ERROR: docker compose not found" >&2
    exit 1
  fi
}

cmd_start() {
  local compose
  compose=$(get_compose_cmd)
  # Ensure PG data directory exists
  mkdir -p volumes/db/data
  echo "Starting Supabase..."
  # shellcheck disable=SC2046
  $compose $(build_f_args) up -d
  echo "Supabase is running. Dashboard: http://localhost:8000"
}

cmd_stop() {
  local compose
  compose=$(get_compose_cmd)
  echo "Stopping Supabase (data preserved)..."
  # shellcheck disable=SC2046
  $compose $(build_f_args) down
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  local compose
  compose=$(get_compose_cmd)
  $compose -f "$COMPOSE_FILE" ps
}

cmd_logs() {
  local compose
  compose=$(get_compose_cmd)
  if [ $# -gt 0 ]; then
    $compose -f "$COMPOSE_FILE" logs -f "$@"
  else
    $compose -f "$COMPOSE_FILE" logs -f
  fi
}

cmd_psql() {
  local compose
  compose=$(get_compose_cmd)
  $compose -f "$COMPOSE_FILE" exec db psql -U postgres
}

cmd_backup() {
  local backup_dir="${1:-../backups}"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local archive="${backup_dir}/supabase-backup-${timestamp}.tar.gz"

  mkdir -p "$backup_dir"

  echo "Creating backup: ${archive}"

  # Create a temp directory for backup assembly
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  # Dump PostgreSQL database
  local compose
  compose=$(get_compose_cmd)
  echo "  -> Dumping PostgreSQL database..."
  $compose -f "$COMPOSE_FILE" exec -T db pg_dump -U postgres --clean --if-exists > "${tmpdir}/database.sql" 2>/dev/null || {
    echo "  WARNING: Database dump failed (db may not be running). Skipping."
  }

  # Archive everything
  tar czf "$archive" -C "$tmpdir" .
  echo "Backup saved: ${archive}"
}

cmd_restore() {
  local archive="$1"
  if [ ! -f "$archive" ]; then
    echo "ERROR: Backup file not found: ${archive}"
    exit 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  echo "Restoring from: ${archive}"
  tar xzf "$archive" -C "$tmpdir"

  local compose
  compose=$(get_compose_cmd)

  # Restore database
  if [ -f "${tmpdir}/database.sql" ]; then
    echo "  -> Restoring PostgreSQL database..."
    # Ensure DB is running
    $compose -f "$COMPOSE_FILE" up -d db
    $compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -f - < "${tmpdir}/database.sql" || {
      echo "  ERROR: Database restore failed."
      exit 1
    }
  fi

  echo "Restore complete. Run './run.sh restart' to apply."
}

cmd_reset() {
  echo "WARNING: This will DELETE ALL DATA!"
  read -rp "Type 'RESET' to confirm: " confirm
  if [ "$confirm" != "RESET" ]; then
    echo "Aborted."
    exit 1
  fi

  local compose
  compose=$(get_compose_cmd)
  echo "Stopping containers..."
  $compose -f "$COMPOSE_FILE" down

  echo "Removing all data..."
  rm -rf volumes/db/data/*
  rm -rf volumes/snippets/*
  rm -rf volumes/functions/*

  echo "Reset complete. Run './run.sh start' to start fresh."
}

cmd_config() {
  echo "Available compose overrides (in supabase/):"
  echo "  docker-compose.logs.yml  - Logflare analytics + Vector log pipeline"
  echo ""
  echo "Usage: docker compose -f docker-compose.yml -f <override> up -d"
  echo "Or set COMPOSE_FILE in .env to include them."
}

# Main
case "${1:-help}" in
  start)    shift; cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  status)   cmd_status ;;
  logs)     shift; cmd_logs "$@" ;;
  psql)     cmd_psql ;;
  backup)   shift; cmd_backup "$@" ;;
  restore)  shift; cmd_restore "$@" ;;
  reset)    cmd_reset ;;
  config)   shift; cmd_config "$@" ;;
  gen-keys) shift; sh utils/generate-keys.sh "$@" ;;
  gen-auth-keys) shift; sh utils/add-new-auth-keys.sh "$@" ;;
  gen-token)
    shift
    if [ $# -lt 1 ]; then
      echo "Usage: ./run.sh gen-token <name> [description]"
      exit 1
    fi
    compose=$(get_compose_cmd)
    RUN_COMPOSE="$compose $(build_f_args)" python3 utils/gen-token.py "$@"
    ;;
  list-tokens)
    compose=$(get_compose_cmd)
    $compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "
      SELECT * FROM _supabase.list_access_tokens(false);
    " 2>/dev/null || echo "No tokens found or database not ready."
    ;;
  revoke-token)
    shift
    if [ $# -lt 1 ]; then
      echo "Usage: ./run.sh revoke-token <token-uuid>"
      exit 1
    fi
    compose=$(get_compose_cmd)
    $compose -f "$COMPOSE_FILE" exec -T db psql -U postgres \
      -v v_id="$1" \
      -c "SELECT _supabase.revoke_token_by_id(:'v_id');" \
      2>/dev/null || echo "Could not revoke token. Make sure Supabase is running."
    ;;
  help|--help|-h) usage ;;
  *)        echo "Unknown command: ${1}"; usage; exit 1 ;;
esac
