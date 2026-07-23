#!/bin/sh
set -e

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  major=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
  [ -n "$major" ] && [ "$major" -ge 16 ] 2>/dev/null
}

if node_ok; then
  node_runner="node"
else
  if command -v node >/dev/null 2>&1; then
    echo "Local node $(node -v) is too old (need >= 16), falling back to docker."
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: requires either node (>= 16) or docker."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Error: docker is installed but the daemon is not running."
    exit 1
  fi
  if ! docker image inspect node:22-alpine >/dev/null 2>&1; then
    echo "Pulling node:22-alpine (first-run only)..."
    docker pull node:22-alpine
  fi
  node_runner="docker run --rm node:22-alpine node"
fi

env_file="${1:-../../.env}"
if [ ! -f "$env_file" ]; then
  echo "Error: $env_file not found."
  exit 1
fi

jwt_secret=$(grep '^JWT_SECRET=' "$env_file" | cut -d= -f2- | tr -d '\r')
if [ -z "$jwt_secret" ]; then
  echo "Error: JWT_SECRET not found in $env_file."
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

$node_runner -e '
const crypto = require("crypto");
const jwtSecret = process.argv[1];
const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
const jwkPrivate = privateKey.export({ format: "jwk" });
const kid = crypto.randomUUID();
const octKey = {
  kty: "oct",
  k: Buffer.from(jwtSecret).toString("base64url"),
  alg: "HS256"
};
const jwksKeypair = { keys: [
  { kty: "EC", kid, use: "sig", key_ops: ["sign", "verify"], alg: "ES256", ext: true,
    crv: jwkPrivate.crv, x: jwkPrivate.x, y: jwkPrivate.y, d: jwkPrivate.d },
  octKey
]};
const jwksPublic = { keys: [
  { kty: "EC", kid, use: "sig", key_ops: ["verify"], alg: "ES256", ext: true,
    crv: jwkPrivate.crv, x: jwkPrivate.x, y: jwkPrivate.y },
  octKey
]};
function signES256(payload) {
  const header = { alg: "ES256", typ: "JWT", kid };
  const b64Header = Buffer.from(JSON.stringify(header)).toString("base64url");
  const b64Payload = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const data = b64Header + "." + b64Payload;
  const sig = crypto.sign("SHA256", Buffer.from(data), {
    key: privateKey, dsaEncoding: "ieee-p1363"
  }).toString("base64url");
  return data + "." + sig;
}
const iat = Math.floor(Date.now() / 1000);
const exp = iat + 5 * 365 * 24 * 3600;
const anonJwt = signES256({ role: "anon", iss: "supabase", iat, exp });
const serviceJwt = signES256({ role: "service_role", iss: "supabase", iat, exp });
const PROJECT_REF = "supabase-self-hosted";
function generateOpaqueKey(prefix) {
  const random = crypto.randomBytes(17).toString("base64url").slice(0, 22);
  const intermediate = prefix + random;
  const checksum = crypto.createHash("sha256")
    .update(PROJECT_REF + "|" + intermediate)
    .digest("base64url").slice(0, 8);
  return intermediate + "_" + checksum;
}
const publishableKey = generateOpaqueKey("sb_publishable_");
const secretKey = generateOpaqueKey("sb_secret_");
console.log("SUPABASE_PUBLISHABLE_KEY=" + publishableKey);
console.log("SUPABASE_SECRET_KEY=" + secretKey);
console.log("ANON_KEY_ASYMMETRIC=" + anonJwt);
console.log("SERVICE_ROLE_KEY_ASYMMETRIC=" + serviceJwt);
console.log("JWT_KEYS=" + JSON.stringify(jwksKeypair.keys));
console.log("JWT_JWKS=" + JSON.stringify(jwksPublic));
' "$jwt_secret" > "$tmpdir/output"

SUPABASE_PUBLISHABLE_KEY=$(grep '^SUPABASE_PUBLISHABLE_KEY=' "$tmpdir/output" | cut -d= -f2-)
SUPABASE_SECRET_KEY=$(grep '^SUPABASE_SECRET_KEY=' "$tmpdir/output" | cut -d= -f2-)
ANON_KEY_ASYMMETRIC=$(grep '^ANON_KEY_ASYMMETRIC=' "$tmpdir/output" | cut -d= -f2-)
SERVICE_ROLE_KEY_ASYMMETRIC=$(grep '^SERVICE_ROLE_KEY_ASYMMETRIC=' "$tmpdir/output" | cut -d= -f2-)
JWT_KEYS=$(grep '^JWT_KEYS=' "$tmpdir/output" | cut -d= -f2-)
JWT_JWKS=$(grep '^JWT_JWKS=' "$tmpdir/output" | cut -d= -f2-)

echo ""
echo "SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY}"
echo "SUPABASE_SECRET_KEY=${SUPABASE_SECRET_KEY}"
echo "JWT_KEYS=${JWT_KEYS}"
echo "JWT_JWKS=${JWT_JWKS}"
echo ""

for var in SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY ANON_KEY_ASYMMETRIC SERVICE_ROLE_KEY_ASYMMETRIC JWT_KEYS JWT_JWKS; do
  eval "val=\$$var"
  if grep -q "^${var}=" "$env_file" 2>/dev/null; then
    sed -i.old -e "s|^${var}=.*$|${var}=${val}|" "$env_file"
  else
    echo "${var}=${val}" >> "$env_file"
  fi
done
echo "Updated $env_file"
