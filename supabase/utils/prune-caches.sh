#!/usr/bin/env bash
# =============================================================================
# 🧹 prune-caches.sh — prune stale GitHub Actions cache entries
# =============================================================================
# Each run saves its state archive to the Actions cache at shutdown (keys
# 'supabase-db-live-<run_id>-final'; GitHub doesn't expose cache-service env
# vars to run: steps, so mid-session uploads aren't possible) and a gzip'd
# Docker image archive ('docker-images-<compose-hash>'). Over time those
# accumulate — and when docker-compose.yml changes, the old docker-images key
# becomes an orphaned multi-GB entry nobody restores. This keeps only the
# newest few of each family so the cache stays well under the 10GB repo cap
# while the restore step always has the freshest data available.
#
# Policy:
#   supabase-db-*    keep newest KEEP (default 3)  — state archives
#   docker-images-*  keep newest DOCKER_KEEP (default 2) — image tars
#
# Requires:
#   GITHUB_TOKEN      - must have 'actions: write' (best-effort if not granted)
#   GITHUB_REPOSITORY - set automatically by the Actions runner
# =============================================================================
set -uo pipefail

export KEEP="${KEEP:-3}"
export DOCKER_KEEP="${DOCKER_KEEP:-2}"
API="https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/caches"

# prune <key-prefix> <keep>: delete all entries starting with <key-prefix>
# except the <keep> newest (sorted by created_at).
prune() {
  local prefix="$1" keep="$2"
  export PREFIX="$prefix" KEEP="$keep"
  local ids
  ids=$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$API?key=${prefix}" 2>/dev/null | \
    python3 -c '
import sys, json, os
d = json.load(sys.stdin)
keep = int(os.environ.get("KEEP", "3"))
ids = [c["id"] for c in sorted(d.get("actions_caches", []),
       key=lambda c: c["created_at"], reverse=True)]
print("\n".join(str(i) for i in ids[keep:]))' 2>/dev/null || true)

  if [ -n "$ids" ]; then
    local n=0
    for ID in $ids; do
      curl -sS -X DELETE -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "$API/$ID" >/dev/null 2>&1 || true
      n=$((n + 1))
    done
    echo "🗑️  Pruned $n '${prefix}' cache entrie(s)"
  fi
}

prune "supabase-db-" "$KEEP"
prune "docker-images-" "$DOCKER_KEEP"
