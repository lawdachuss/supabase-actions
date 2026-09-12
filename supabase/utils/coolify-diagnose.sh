#!/usr/bin/env bash
# =============================================================================
# 🐳 coolify-diagnose.sh — Diagnose Coolify login issues after restart
# =============================================================================
# Run this after a GitHub Actions restart to check why login might be failing.
# =============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]})/.."

COMPOSE_CMD=(docker compose -f docker-compose.yml -f docker-compose.logs.yml -f docker-compose.redis.yml -f docker-compose.coolify.yml)

echo "=== 🐳 Coolify Login Diagnostic ==="
echo ""

# Check if containers are running
echo "📦 Container status:"
COMPOSE_CMD[@] ps coolify coolify-postgres coolify-redis coolify-realtime 2>/dev/null || echo "  (containers not running)"
echo ""

# Check Coolify DB
echo "🗄️  Coolify Database:"
COOLIFY_DB_USER="$(grep -E '^COOLIFY_DB_USERNAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
COOLIFY_DB_NAME="$(grep -E '^COOLIFY_DB_NAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
COOLIFY_DB_USER="${COOLIFY_DB_USER:-coolify}"
COOLIFY_DB_NAME="${COOLIFY_DB_NAME:-coolify}"

if docker exec coolify-db pg_isready -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" >/dev/null 2>&1; then
  echo "  ✅ Coolify DB is accepting connections"

  # Check users table
  USERS_COUNT=$(docker exec coolify-db psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -c \
    "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' \r')
  echo "  👤 Users in database: ${USERS_COUNT:-0}"

  if [ "${USERS_COUNT:-0}" -gt 0 ]; then
    echo ""
    echo "  📋 Users:"
    docker exec coolify-db psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -c \
      "SELECT id, name, email, created_at FROM users ORDER BY id LIMIT 5;" 2>/dev/null || echo "    (could not query users)"
  fi

  # Check root user (id 0)
  ROOT_EXISTS=$(docker exec coolify-db psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -c \
    "SELECT COUNT(*) FROM users WHERE id = 0;" 2>/dev/null | tr -d ' \r')
  if [ "$ROOT_EXISTS" = "1" ]; then
    echo ""
    echo "  🔑 Root user (id 0) exists:"
    docker exec coolify-db psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -c \
      "SELECT id, email, password IS NOT NULL as has_password, created_at FROM users WHERE id = 0;" 2>/dev/null || echo "    (could not query root user)"
  else
    echo ""
    echo "  ⚠️  Root user (id 0) does NOT exist in database"
  fi

  # Check registration setting
  REG_ENABLED=$(docker exec coolify-db psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -c \
    "SELECT is_registration_enabled FROM instance_settings ORDER BY id LIMIT 1;" 2>/dev/null | tr -d ' \r')
  echo ""
  echo "  ⚙️  Registration enabled: ${REG_ENABLED:-unknown}"
else
  echo "  ❌ Coolify DB is not accepting connections"
fi

echo ""
echo "📝 Coolify .env (source):"
if [ -f "volumes/coolify/source/.env" ]; then
  echo "  ✅ Found volumes/coolify/source/.env"
  echo "  APP_KEY: $(grep '^APP_KEY=' volumes/coolify/source/.env 2>/dev/null | cut -d= -f2- | head -c 20)..."
  echo "  ROOT_USER_EMAIL: $(grep '^ROOT_USER_EMAIL=' volumes/coolify/source/.env 2>/dev/null | cut -d= -f2-)"
  echo "  ROOT_USER_PASSWORD: $(grep '^ROOT_USER_PASSWORD=' volumes/coolify/source/.env 2>/dev/null | cut -d= -f2- | head -c 10)..."
else
  echo "  ❌ volumes/coolify/source/.env NOT FOUND"
fi

echo ""
echo "🔐 COOLIFY_PASSWORD secret:"
if [ -n "${COOLIFY_PASSWORD:-}" ]; then
  echo "  ✅ Set (length: ${#COOLIFY_PASSWORD} chars)"
  # Check if it meets Coolify's requirements
  if [ "${#COOLIFY_PASSWORD}" -ge 8 ] && \
     echo "${COOLIFY_PASSWORD}" | grep -q '[A-Z]' && \
     echo "${COOLIFY_PASSWORD}" | grep -q '[a-z]' && \
     echo "${COOLIFY_PASSWORD}" | grep -q '[0-9]' && \
     echo "${COOLIFY_PASSWORD}" | grep -q '[^A-Za-z0-9]'; then
    echo "  ✅ Meets Coolify's password requirements"
  else
    echo "  ⚠️  Does NOT meet Coolify's password requirements"
    echo "     Required: 8+ chars, upper, lower, digit, symbol"
  fi
else
  echo "  ⚠️  Not set (will use generated password from .env)"
fi

echo ""
echo "🌐 Health check:"
if curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:8082/api/health" 2>/dev/null; then
  echo "  ✅ Coolify API is healthy"
else
  echo "  ❌ Coolify API is NOT reachable on port 8082"
fi

echo ""
echo "=== 🔍 Possible Issues ==="
echo ""

# Diagnose common issues
ISSUES=0

# 1. No users
if [ "${USERS_COUNT:-0}" = "0" ]; then
  echo "❌ ISSUE: No users in Coolify database"
  echo "   → Login is impossible without any users"
  echo "   → Fix: Check if seed_admin() ran successfully in the workflow"
  ISSUES=$((ISSUES + 1))
fi

# 2. Root user exists but has no password
if [ "${ROOT_EXISTS:-0}" = "1" ]; then
  HAS_PWD=$(docker exec coolify-db psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -c \
    "SELECT password IS NOT NULL FROM users WHERE id = 0;" 2>/dev/null | tr -d ' \r')
  if [ "$HAS_PWD" != "t" ]; then
    echo "❌ ISSUE: Root user exists but has no password set"
    echo "   → sync_root_password() may have failed"
    echo "   → Fix: Check COOLIFY_PASSWORD secret and try restart"
    ISSUES=$((ISSUES + 1))
  fi
fi

# 3. Password policy mismatch
if [ -n "${COOLIFY_PASSWORD:-}" ]; then
  if ! [ "${#COOLIFY_PASSWORD}" -ge 8 ] || \
     ! echo "${COOLIFY_PASSWORD}" | grep -q '[A-Z]' || \
     ! echo "${COOLIFY_PASSWORD}" | grep -q '[a-z]' || \
     ! echo "${COOLIFY_PASSWORD}" | grep -q '[0-9]' || \
     ! echo "${COOLIFY_PASSWORD}" | grep -q '[^A-Za-z0-9]'; then
    echo "❌ ISSUE: COOLIFY_PASSWORD does not meet Coolify's requirements"
    echo "   → The password was synced but may not work for login"
    echo "   → Fix: Update COOLIFY_PASSWORD secret to meet requirements:"
    echo "     - At least 8 characters"
    echo "     - At least one uppercase letter"
    echo "     - At least one lowercase letter"
    echo "     - At least one digit"
    echo "     - At least one special character (!@#$%^&*)"
    ISSUES=$((ISSUES + 1))
  fi
fi

# 4. APP_KEY missing or changed
if [ -f "volumes/coolify/source/.env" ]; then
  OLD_KEY=$(grep '^APP_KEY=' volumes/coolify/source/.env 2>/dev/null | cut -d= -f2-)
  if [ -z "$OLD_KEY" ]; then
    echo "❌ ISSUE: APP_KEY is missing from volumes/coolify/source/.env"
    echo "   → Encrypted data in restored DB may be unreadable"
    ISSUES=$((ISSUES + 1))
  fi
else
  echo "❌ ISSUE: Coolify source .env is missing"
  echo "   → APP_KEY and other secrets may have been regenerated"
  ISSUES=$((ISSUES + 1))
fi

if [ $ISSUES -eq 0 ]; then
  echo "✅ No obvious issues found. Login should work."
  echo "   Try: Clear browser cache/cookies and retry."
else
  echo ""
  echo "💡 Tip: If you recently changed COOLIFY_PASSWORD, you may need to"
  echo "   update it in GitHub Secrets and restart the workflow."
fi
