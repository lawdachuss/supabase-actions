#!/usr/bin/env bash
# =============================================================================
# 🧹 prune-caches.sh — prune stale state-snapshot GitHub cache entries
# =============================================================================
# Each run saves its state archive to the Actions cache at shutdown
# (keys 'supabase-db-live-<run_id>-final'; GitHub doesn't expose cache-service
# env vars to run: steps, so mid-session uploads aren't possible). Without
# pruning those accumulate and can hit GitHub's 10GB per-repo cache cap.
# This keeps only the newest KEEP entries (default 3) so the cache stays small
# while the restore step always has the freshest state available.
#
# Requires:
#   GITHUB_TOKEN      - must have 'actions: write' (best-effort if not granted)
#   GITHUB_REPOSITORY - set automatically by the Actions runner
# =============================================================================
set -uo pipefail

export KEEP="${KEEP:-3}"
API="https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/caches"

CACHES=$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "$API?key=supabase-db-" 2>/dev/null | \
  python3 -c 'import sys,json,os; d=json.load(sys.stdin); keep=int(os.environ.get("KEEP","3")); ids=[c["id"] for c in sorted(d.get("actions_caches",[]), key=lambda c: c["created_at"], reverse=True)]; print("\n".join(str(i) for i in ids[keep:]))' 2>/dev/null || true)

if [ -n "$CACHES" ]; then
  for ID in $CACHES; do
    curl -sS -X DELETE -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "$API/$ID" >/dev/null 2>&1 || true
  done
  echo "🗑️  Pruned $(echo "$CACHES" | wc -l) stale cache entrie(s)"
fi
