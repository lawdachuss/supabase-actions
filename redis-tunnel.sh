#!/usr/bin/env bash
# =============================================================================
# 🔌 redis-tunnel.sh — a PERMANENT Redis link, free (no card, no new provider)
# =============================================================================
# The bore.pub relay in the workflow hands out a RANDOM port every session, so
# it can never be a permanent redis:// URL. ngrok can't help on the free plan
# either (reserved TCP addresses are paid-only — `ngrok tcp 6379` prints a NEW
# random N.tcp.ngrok.io:PORT every session).
#
# Your Cloudflare Tunnel, on the other hand, is already permanent. This script
# dials Redis through it and exposes a stable LOCAL port, so the address you
# put in your app never changes:
#
#     ./redis-tunnel.sh                     # redis://127.0.0.1:6379, stays up
#     redis-cli -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD"
#
# ---------------------------------------------------------------------------
# ONE-TIME SETUP (Cloudflare dashboard — free plan is fine, no card needed)
# ---------------------------------------------------------------------------
#   Zero Trust → Networks → Tunnels → <your tunnel> → Public Hostname → Add
#     Subdomain: redis
#     Domain:    your-domain.com          (e.g. chuglii.in)
#     Type:      TCP
#     URL:       localhost:6379
#
#   Recommended: protect it with an Access application + a service token, then
#   put the token in remote.env (CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET)
#   and this script will present it automatically.
#
#   Note: TCP tunnels require cloudflared on the CLIENT too (Cloudflare does
#   not hand out plain public TCP ports on the free plan) — that's what this
#   script is. Once it's running, everything else talks plain redis://127.0.0.1.
#
# ---------------------------------------------------------------------------
# Config — export these OR add them to ./remote.env (gitignored):
#   REDIS_TUNNEL_HOSTNAME    e.g. redis.chuglii.in
#                            (or derived from REMOTE_URL: subdomain "redis")
#   REDIS_TUNNEL_LOCAL_PORT  local port to expose       (default 6379)
#   REDIS_PASSWORD           only used to print a ready-to-paste URI
#   CF_ACCESS_CLIENT_ID      Access service token id     (optional)
#   CF_ACCESS_CLIENT_SECRET  Access service token secret (optional)
#
# Usage:
#   ./redis-tunnel.sh                 # use config / derive from REMOTE_URL
#   ./redis-tunnel.sh redis.mydomain.com
#   ./redis-tunnel.sh -p 6380         # expose on a different local port
#
# On Windows run this from Git Bash or WSL:  bash redis-tunnel.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/remote.env"

# Load optional ./remote.env (REMOTE_URL, REDIS_*) if it exists.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ENV_FILE"
  set +a
fi

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "→ $*"; }

LOCAL_PORT="${REDIS_TUNNEL_LOCAL_PORT:-6379}"
HOSTNAME_ARG=""

# ── Parse args ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port)  [ -n "${2:-}" ] || die "-p needs a port"; LOCAL_PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  HOSTNAME_ARG="$1"; shift ;;
  esac
done

# ── Resolve the permanent hostname ──────────────────────────────────────────
HOST="${HOSTNAME_ARG:-${REDIS_TUNNEL_HOSTNAME:-}}"

if [ -z "$HOST" ]; then
  # Derive from REMOTE_URL: https://supabase.example.com → redis.example.com
  if [ -n "${REMOTE_URL:-}" ]; then
    BASE="${REMOTE_URL#*://}"   # strip scheme
    BASE="${BASE%%/*}"          # strip any path
    BASE="${BASE#supabase.}"    # supabase.example.com → example.com
    HOST="redis.$BASE"
    info "derived hostname from REMOTE_URL: $HOST"
  fi
fi

if [ -z "$HOST" ]; then
  die "no hostname. Pass it as an argument, or set REDIS_TUNNEL_HOSTNAME, or set REMOTE_URL in ./remote.env"
fi

# ── Require cloudflared ─────────────────────────────────────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: cloudflared is not installed — it's the client half of a Cloudflare
       TCP tunnel (Cloudflare's free plan has no plain public TCP port).

Install it, then re-run this script:
  macOS:          brew install cloudflared
  Debian/Ubuntu:  see https://pkg.cloudflare.com/
  Windows:        winget install --id Cloudflare.cloudflared
  Any:            https://github.com/cloudflare/cloudflared/releases/latest
EOF
  exit 1
fi

# ── Build the command (add Access service token when configured) ────────────
ARGS=(access tcp --hostname "$HOST" --url "127.0.0.1:$LOCAL_PORT")
if [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  ARGS+=(--service-token-id "$CF_ACCESS_CLIENT_ID")
  ARGS+=(--service-token-secret "$CF_ACCESS_CLIENT_SECRET")
  info "using Cloudflare Access service token"
fi

echo ""
echo "==================================================================="
echo "  Permanent Redis link"
echo "==================================================================="
echo "  Tunnel:      $HOST  →  127.0.0.1:$LOCAL_PORT"
echo "  Keep this running — the local address stays valid forever."
echo ""
if [ -n "${REDIS_PASSWORD:-}" ]; then
  echo "  URI:         redis://default:${REDIS_PASSWORD}@127.0.0.1:$LOCAL_PORT"
  echo "  CLI:         redis-cli -h 127.0.0.1 -p $LOCAL_PORT -a '\$REDIS_PASSWORD'"
else
  echo "  URI:         redis://default:<REDIS_PASSWORD>@127.0.0.1:$LOCAL_PORT"
  echo "  CLI:         redis-cli -h 127.0.0.1 -p $LOCAL_PORT"
fi
echo "==================================================================="
echo ""

exec cloudflared "${ARGS[@]}"
