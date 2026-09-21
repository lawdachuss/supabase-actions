#!/usr/bin/env bash
# =============================================================================
# 🌍 remote.sh — control this self-hosted Supabase from anywhere
# =============================================================================
# Applies migrations / runs SQL on the LIVE remote instance over HTTPS (via the
# built-in 'migrate' edge function). No SSH, no waiting for the next 6-hour
# GitHub Actions session, no TCP exposure needed.
#
# Config — export these OR add them to ./remote.env (gitignored):
#   REMOTE_URL          the public Studio URL, e.g. https://supabase.yourdomain.com
#   REMOTE_SERVICE_KEY  the service_role key (find it in the workflow run summary
#                       or generate one with ./run.sh gen-token)
#   REMOTE_TIMEOUT      curl timeout seconds (default 60)
#
# On Windows run this from Git Bash or WSL:  bash remote.sh <command>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/supabase/migrations"
ENV_FILE="$SCRIPT_DIR/remote.env"

# Load optional ./remote.env (REMOTE_URL, REMOTE_SERVICE_KEY) if it exists.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ENV_FILE"
  set +a
fi

URL="${REMOTE_URL:-}"
KEY="${REMOTE_SERVICE_KEY:-}"
TIMEOUT="${REMOTE_TIMEOUT:-60}"
ENDPOINT="/functions/v1/migrate"

# Strip a trailing slash so URL+path concatenation is always clean.
URL="${URL%/}"

die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  [ -n "$URL" ] || die "set REMOTE_URL (e.g. https://supabase.yourdomain.com) in remote.env / env"
  [ -n "$KEY" ] || die "set REMOTE_SERVICE_KEY (the service_role key) in remote.env / env"
}

require_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required by remote.sh"
}

# api <method> <path> [payload-file] → prints the raw response body
api() {
  local method="$1" path="$2" payload="${3:-}"
  local args=(
    -sS --max-time "$TIMEOUT" -X "$method" "$URL$path"
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY"
  )
  if [ -n "$payload" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "@$payload")
  fi
  curl "${args[@]}"
}

# pprint <raw-json> → pretty-printed (falls back to raw)
pprint() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

cmd_status() {
  require
  echo "→ GET $URL$ENDPOINT"
  pprint "$(api GET "$ENDPOINT")"
}

cmd_run() {
  require
  require_python
  local sql=""
  if [ $# -eq 0 ] || [ "$1" = "-" ]; then
    sql="$(cat)" # read from stdin
  else
    sql="$1"
  fi
  [ -n "$sql" ] || die "no SQL given — pass it as the first argument or pipe it via stdin"
  local tmp
  tmp="$(mktemp)"
  SQL="$sql" python3 - <<'PY' >"$tmp"
import json, os
print(json.dumps({"sql": os.environ["SQL"]}))
PY
  echo "→ POST $URL$ENDPOINT  (one-off SQL, not tracked)"
  pprint "$(api POST "$ENDPOINT" "$tmp")"
  rm -f "$tmp"
}

cmd_push() {
  require
  require_python
  local files=()
  if [ $# -gt 0 ]; then
    for f in "$@"; do
      [ -f "$f" ] || die "file not found: $f"
      files+=("$f")
    done
  else
    shopt -s nullglob
    local glob=("$MIGRATIONS_DIR"/*.sql)
    shopt -u nullglob
    [ ${#glob[@]} -gt 0 ] || die "no migrations found in $MIGRATIONS_DIR"
    files=("${glob[@]}")
  fi

  local tmp
  tmp="$(mktemp)"
  python3 - "${files[@]}" >"$tmp" <<'PY'
import json, os, sys
migs = []
for f in sys.argv[1:]:
    with open(f, "r", encoding="utf-8") as fh:
        migs.append({"name": os.path.basename(f), "sql": fh.read()})
print(json.dumps({"migrations": migs}))
PY
  echo "→ POST $URL$ENDPOINT  (push ${#files[@]} migration(s), idempotent — already-applied are skipped)"
  pprint "$(api POST "$ENDPOINT" "$tmp")"
  rm -f "$tmp"
}

cmd_untrack() {
  require
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ./remote.sh untrack <file.sql>"
  case "$name" in
    *.sql) ;;
    *) die "name must end in .sql (got: $name)" ;;
  esac
  echo "→ DELETE $URL$ENDPOINT?name=$name  (untracked migrations re-apply on next push)"
  pprint "$(curl -sS --max-time "$TIMEOUT" -X DELETE -G "$URL$ENDPOINT" \
    --data-urlencode "name=$name" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY")"
}

usage() {
  cat <<EOF
usage: ./remote.sh <command> [args]

Control this self-hosted Supabase from anywhere, over HTTPS.

Config — export these or create ./remote.env (gitignored):
  REMOTE_URL          e.g. https://supabase.yourdomain.com
  REMOTE_SERVICE_KEY  your service_role key (see workflow run summary)

Commands:
  status                   list applied migrations + DB info
  health                   alias for status
  run '<SQL>' | - | stdin  run one-off SQL (not tracked)
  push [file.sql ...]      apply migrations — default: supabase/migrations/*.sql
                           (idempotent; already-applied files are skipped)
  untrack <file.sql>       un-track a migration so it can be re-applied
  help                     show this help

Examples:
  ./remote.sh status
  ./remote.sh push supabase/migrations/003-foo.sql
  ./remote.sh push
  ./remote.sh run "ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;"
  ./remote.sh run < schema.sql
EOF
}

case "${1:-help}" in
  status|list) shift; cmd_status "$@" ;;
  health) shift; cmd_status "$@" ;;
  run|sql|exec) shift; cmd_run "$@" ;;
  push|apply|migrate) shift; cmd_push "$@" ;;
  untrack|forget) shift; cmd_untrack "$@" ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: ${1:-}"; usage; exit 1 ;;
esac