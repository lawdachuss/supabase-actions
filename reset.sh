#!/usr/bin/env bash
# =============================================================================
# 🔄 Supabase Self-Hosted Reset
# =============================================================================
# Quick shortcut to reset all data and start fresh.
# Delegates to: ./run.sh reset
#
# Usage:
#   sh reset.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "⚠️  WARNING: This will delete ALL data and reset Supabase from scratch!"
echo ""
cd "$SCRIPT_DIR" && exec sh run.sh reset
