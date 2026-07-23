#!/usr/bin/env python3
"""
🔑 Supabase Self-Hosted Access Token Generator

Generates a service_role JWT access token, registers it in the
_supabase.access_tokens table via the register_access_token() SQL function,
and prints the full token.

Usage:
    python3 gen-token.py <name> [description]

Requires:
    - JWT_SECRET env var or .env file in parent dir
    - RUN_COMPOSE env var (e.g., "docker compose -f docker-compose.yml -f ...")
      or run via ./run.sh gen-token which sets it automatically

The token is a standard HS256 JWT that works with Kong's existing
JWT validation. It includes a unique jti (JWT ID) for revocation tracking.
"""

import os, sys, json, subprocess, uuid, base64, hashlib
from datetime import datetime, timezone

# ── Find JWT_SECRET ─────────────────────────────────────────────────────────
def find_jwt_secret():
    """Read JWT_SECRET from env, or from .env files if exists."""
    val = os.environ.get('JWT_SECRET')
    if val:
        return val
    # Try typical .env locations
    for path in [os.path.join(d, '.env') for d in [
        os.path.dirname(os.path.abspath(__file__)),        # utils/
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),  # supabase/
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),  # project root/
    ]]:
        if os.path.exists(path):
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('JWT_SECRET='):
                        return line.split('=', 1)[1]
    print("ERROR: JWT_SECRET not found. Set via env var or .env file.", file=sys.stderr)
    sys.exit(1)

# ── Find compose command ────────────────────────────────────────────────────
def get_compose_cmd():
    """Return the compose command from env, or auto-detect."""
    cmd = os.environ.get('RUN_COMPOSE', '').strip()
    if cmd:
        return cmd
    # Auto-detect
    for c in ["docker compose", "docker-compose"]:
        try:
            subprocess.run(c.split()[0], capture_output=True, check=True)
            return c
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
    return None

# ── Base64url helpers ───────────────────────────────────────────────────────
def b64url_encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

# ── Generate JWT ────────────────────────────────────────────────────────────
def sign_hs256(payload_dict, secret):
    """Create an HS256 JWT with the given payload dict."""
    header = json.dumps({"alg": "HS256", "typ": "JWT"}).encode()
    payload = json.dumps(payload_dict).encode()
    b64_h = b64url_encode(header)
    b64_p = b64url_encode(payload)
    sig = hmac.new(secret.encode(), f"{b64_h}.{b64_p}".encode(), hashlib.sha256).digest()
    return f"{b64_h}.{b64_p}.{b64url_encode(sig)}"

# ── Register token via SQL function ─────────────────────────────────────────
def register_token_in_db(name, description, compose_cmd):
    """
    Call _supabase.register_access_token() via psql.
    Returns (jti, prefix, expires_at) as strings on success, or (None, None, None).
    """
    if not compose_cmd:
        return None, None, None

    # Use psql's -v variable binding to safely pass values (prevents SQL injection)
    sql = "SELECT _supabase.register_access_token(:'v_name', :'v_desc')::TEXT;"
    cmd = (
        f'{compose_cmd} exec -T db psql -U postgres '
        f'-v v_name={shell_quote(name)} '
        f'-v v_desc={shell_quote(description)} '
        f'-At -c {shell_quote(sql)}'
    )
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.strip():
            meta = json.loads(result.stdout.strip())
            return meta.get('id'), meta.get('prefix'), meta.get('expires_at')
    except Exception as e:
        print(f"  ⚠ Could not register in DB: {e}", file=sys.stderr)
    return None, None, None

def shell_quote(s):
    """Quote a string for safe use in shell arguments."""
    return "'" + s.replace("'", "'\\''") + "'"

# ── Main ────────────────────────────────────────────────────────────────────
if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 gen-token.py <name> [description]", file=sys.stderr)
        print("", file=sys.stderr)
        print("Generates a new service_role access token and registers it.", file=sys.stderr)
        print("", file=sys.stderr)
        print("Environment:", file=sys.stderr)
        print("  JWT_SECRET    JWT signing secret", file=sys.stderr)
        print("  RUN_COMPOSE   Docker compose command prefix (optional, auto-detected)", file=sys.stderr)
        sys.exit(1)

    name = sys.argv[1]
    description = sys.argv[2] if len(sys.argv) > 2 else ""
    secret = find_jwt_secret()
    compose_cmd = get_compose_cmd()

    # ── Register in DB first (generates jti, prefix, expiry) ────────────
    jti, prefix, expires_str = register_token_in_db(name, description, compose_cmd)

    if jti:
        print(f"  ✓ Registered token '{name}' in database", file=sys.stderr)
    else:
        # Generate our own jti/prefix if DB registration failed
        jti = str(uuid.uuid4())
        prefix = 'sbp_' + jti[:8]
        expires_str = None
        print("  ⚠ Token will work but won't be tracked in DB", file=sys.stderr)

    # ── Generate JWT ────────────────────────────────────────────────────
    now = int(datetime.now(timezone.utc).timestamp())
    expires = now + 31536000  # 1 year

    # Parse DB expiry if available
    if expires_str:
        try:
            parsed = datetime.fromisoformat(expires_str.replace('Z', '+00:00'))
            expires = int(parsed.timestamp())
        except (ValueError, AttributeError):
            pass

    payload = {
        "role": "service_role",
        "iss": "supabase",
        "iat": now,
        "exp": expires,
        "jti": jti,
        "name": name
    }
    token = sign_hs256(payload, secret)

    # ── Output ──────────────────────────────────────────────────────────
    exp_date = datetime.fromtimestamp(expires, timezone.utc).strftime('%Y-%m-%d %H:%M UTC')

    print("", file=sys.stderr)
    print("╔══════════════════════════════════════════════════════════╗", file=sys.stderr)
    print("║           NEW ACCESS TOKEN GENERATED                    ║", file=sys.stderr)
    print("╠══════════════════════════════════════════════════════════╣", file=sys.stderr)
    print(f"║  Name:    {name:<44} ║", file=sys.stderr)
    print(f"║  Prefix:  {prefix:<44} ║", file=sys.stderr)
    print(f"║  Expires: {exp_date:<44} ║", file=sys.stderr)
    print("║                                                          ║", file=sys.stderr)
    print("║  Use with: Authorization: Bearer <token>                 ║", file=sys.stderr)
    print("╚══════════════════════════════════════════════════════════╝", file=sys.stderr)
    print("", file=sys.stderr)
    print("Token:", file=sys.stderr)
    print(token)
