#!/usr/bin/env bash
# =============================================================================
# 🐘 pg-tunnel.sh — reach Postgres from anywhere through your Cloudflare Tunnel
# =============================================================================
# Why not a plain postgresql://host:5432 URL?
#   supabase.<domain> resolves to Cloudflare's HTTP proxy, which only forwards
#   80/443. Port 5432 is dropped at the EDGE, so the packets never reach your
#   runner — that is why `postgresql://...@supabase.<domain>:5432/postgres`
#   times out no matter how right the password is. The free plan cannot publish
#   a raw TCP port (that's Cloudflare Spectrum, paid).
#
#   So the connection is dialled through the tunnel instead: cloudflared opens a
#   stable LOCAL port, and anything on this machine then talks plain Postgres.
#
#     ./pg-tunnel.sh                                  # start it (leave running)
#     psql "postgresql://postgres.<TENANT>:<PASS>@127.0.0.1:5432/postgres"
#
# ---------------------------------------------------------------------------
# ⚠️  READ THIS — WHY THE ACCESS TOKEN IS NOT OPTIONAL HERE
# ---------------------------------------------------------------------------
# This repo is public and the Postgres password has been committed to it. A
# password in public git history provides no protection: anyone who finds it can
# connect to any port you expose. The ONLY thing standing between the internet
# and your database is the Cloudflare Access service token below — without it,
# publishing this route is equivalent to disabling authentication.
#
# So unlike redis-tunnel.sh, this script REFUSES to run without a token unless
# you explicitly pass --i-know-what-im-doing.
#
# ---------------------------------------------------------------------------
# ONE-TIME SETUP (free plan is fine, no card)
# ---------------------------------------------------------------------------
# 1. Zero Trust → Networks → Tunnels → <your tunnel> → Public Hostname → Add
#      Subdomain: db
#      Domain:    your-domain.com
#      Type:      TCP
#      URL:       localhost:5432        (Supavisor, SESSION mode)
#    Use 6543 instead for transaction mode (breaks prepared statements).
#
# 2. Zero Trust → Access → Applications → Add an application → Self-hosted
#      Name:    Postgres (tunnel)
#      Domain:  db.your-domain.com      (port left blank)
#    Then add a policy: Action = Service Auth, and create a Service Token
#    (Access → Service Auth → Service Tokens). Put its id/secret in remote.env.
#
# ---------------------------------------------------------------------------
# Config — export these OR add them to ./remote.env (gitignored):
#   PG_TUNNEL_HOSTNAME       e.g. db.chuglii.in (or derived from REMOTE_URL)
#   PG_TUNNEL_LOCAL_PORT     local port to open          (default 5432)
#   CF_ACCESS_CLIENT_ID      Access service token id     (REQUIRED)
#   CF_ACCESS_CLIENT_SECRET  Access service token secret (REQUIRED)
#   POSTGRES_PASSWORD        used only to print the URL  (read from supabase/.env)
#   POOLER_TENANT_ID         used to build the username  (read from supabase/.env)
#
# Usage:
#   ./pg-tunnel.sh                       # use config / derive from REMOTE_URL
#   ./pg-tunnel.sh db.mydomain.com
#   ./pg-tunnel.sh -p 5433               # different local port
#   ./pg-tunnel.sh --i-know-what-im-doing # allow running WITHOUT an Access token
#
# On Windows run this from Git Bash or WSL:  bash pg-tunnel.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/remote.env"
SUPABASE_ENV="$SCRIPT_DIR/supabase/.env"

# Optional credentials/config. remote.env wins over supabase/.env.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ENV_FILE"
  set +a
fi
# Read the Postgres password / pooler tenant for display only. Never committed
# (both files are gitignored) and never sent anywhere but your terminal.
read_env_value() {
  local key="$1"
  [ -f "$SUPABASE_ENV" ] || return 0
  grep -E "^${key}=" "$SUPABASE_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r'
}
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(read_env_value POSTGRES_PASSWORD)}"
POOLER_TENANT_ID="${POOLER_TENANT_ID:-$(read_env_value POOLER_TENANT_ID)}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "→ $*"; }

LOCAL_PORT="${PG_TUNNEL_LOCAL_PORT:-5432}"
HOSTNAME_ARG=""
ALLOW_INSECURE=0

usage() {
  sed -n '2,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port)  [ -n "${2:-}" ] || die "-p needs a port"; LOCAL_PORT="$2"; shift 2 ;;
    --i-know-what-im-doing) ALLOW_INSECURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  HOSTNAME_ARG="$1"; shift ;;
  esac
done

# ── Resolve the permanent hostname ──────────────────────────────────────────
HOST="${HOSTNAME_ARG:-${PG_TUNNEL_HOSTNAME:-}}"
if [ -z "$HOST" ] && [ -n "${REMOTE_URL:-}" ]; then
  BASE="${REMOTE_URL#*://}"   # strip scheme
  BASE="${BASE%%/*}"          # strip any path
  BASE="${BASE#supabase.}"    # supabase.example.com → example.com
  HOST="db.$BASE"
  info "derived hostname from REMOTE_URL: $HOST"
fi
[ -n "$HOST" ] || die "no hostname. Pass it as an argument, set PG_TUNNEL_HOSTNAME, or set REMOTE_URL in ./remote.env"

# ── Access token is mandatory unless explicitly waived ──────────────────────
HAVE_TOKEN=0
if [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  HAVE_TOKEN=1
fi
if [ "$HAVE_TOKEN" -eq 0 ] && [ "$ALLOW_INSECURE" -eq 0 ]; then
  cat >&2 <<'EOF'
ERROR: no Cloudflare Access service token configured.

The Postgres password for this stack is public (it is in this repo's git
history), so an ungated tunnel is an unauthenticated database open to the
internet. Add a service token first:

  Zero Trust → Access → Service Auth → Service Tokens → Create
  Zero Trust → Access → Applications → Add → Self-hosted
     Domain: <the hostname you are tunnelling>, policy action: Service Auth

  then put both values in ./remote.env:
     CF_ACCESS_CLIENT_ID=<id>
     CF_ACCESS_CLIENT_SECRET=<secret>

Override with --i-know-what-im-doing ONLY on a private/temporary network.
EOF
  exit 1
fi

# ── Require cloudflared ─────────────────────────────────────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: cloudflared is not installed — it's the client half of a Cloudflare TCP
       tunnel (the free plan has no plain public TCP port).

  macOS:          brew install cloudflared
  Windows:        winget install --id Cloudflare.cloudflared
  Any:            https://github.com/cloudflare/cloudflared/releases/latest
EOF
  exit 1
fi

# ── Build the connection URL ────────────────────────────────────────────────
# Supavisor wants <db_user>.<POOLER_TENANT_ID>, not a bare "postgres" — a bare
# username is the most common cause of "password authentication failed" here.
if [ -n "$POOLER_TENANT_ID" ]; then
  PG_USER="postgres.$POOLER_TENANT_ID"
else
  PG_USER="postgres.<POOLER_TENANT_ID>"
fi
SHOWN_PASS="${POSTGRES_PASSWORD:-<POSTGRES_PASSWORD>}"

echo ""
echo "==================================================================="
echo "  Postgres tunnel"
echo "==================================================================="
echo "  Tunnel:  $HOST  →  127.0.0.1:$LOCAL_PORT"
echo "  Access:  $([ "$HAVE_TOKEN" -eq 1 ] && echo 'service token ✓' || echo 'NONE (ungated!)')"
echo ""
echo "  DATABASE_URL:"
echo "    postgresql://${PG_USER}:${SHOWN_PASS}@127.0.0.1:${LOCAL_PORT}/postgres"
echo ""
echo "  psql:"
echo "    psql \"postgresql://${PG_USER}:***@127.0.0.1:${LOCAL_PORT}/postgres\""
echo ""
echo "  Keep this running. The local address never changes, but note the"
echo "  service itself is down ~1-2 min between sessions (ephemeral runner)."
if [ -z "$POOLER_TENANT_ID" ]; then
  echo ""
  echo "  ⚠️  POOLER_TENANT_ID not found — read it from supabase/.env"
  echo "     (grep POOLER_TENANT_ID supabase/.env) to fill in the username."
fi
echo "==================================================================="
echo ""

ARGS=(access tcp --hostname "$HOST" --url "127.0.0.1:$LOCAL_PORT")
if [ "$HAVE_TOKEN" -eq 1 ]; then
  ARGS+=(--service-token-id "$CF_ACCESS_CLIENT_ID")
  ARGS+=(--service-token-secret "$CF_ACCESS_CLIENT_SECRET")
fi

exec cloudflared "${ARGS[@]}"
