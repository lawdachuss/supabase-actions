#!/usr/bin/env bash
# =============================================================================
# ☁️  cloudflare-backup.sh — off-site state backup to Cloudflare Workers KV
# =============================================================================
# Why KV (not R2): KV is card-free (no payment method required) and is usable
# with the wrangler/tunnel credentials this stack already has. KV caps each
# value at 25 MiB, so larger archives are split into CHUNK_BYTES-sized chunks.
#
# Namespace layout:
#   archive/<generation>/<base>.<NNNNNNNN>  immutable archive chunks
#   archive/<generation>/manifest.json      verified archive manifest
#   latest/manifest.json                    pointer to the current generation
#
# Retention: the freshest set is always under 'latest/' (overwritten each
# push). Chunks are immutable and the latest pointer changes only after the
# full generation has been read back and verified. Failed uploads therefore
# cannot corrupt the last known-good backup.
#
# The runner keeps no growing local history either: snapshots overwrite a single
# on-disk archive and chunk temp dirs are removed after each push.
#
# Usage:
#   cloudflare-backup.sh push <file>            # verify, publish + prune oldest
#   cloudflare-backup.sh restore <outfile>      # pull latest and reassemble
#   cloudflare-backup.sh manifest               # print latest backup's unix ts
#   cloudflare-backup.sh verify                 # confirm 'latest' is restorable (size+sha256)
#   cloudflare-backup.sh refresh                # renew access token from the .env refresh token
#   cloudflare-backup.sh list                   # show keys + retention state
#
# NOTE on OAuth tokens: Cloudflare 'cfor*' refresh tokens are SINGLE-USE and
# rotate on every mint. The workflow keeps the rotated token in supabase/.env so
# the chain survives on a persistent runner; a fresh runner needs either a
# permanent API token (preferred — set CLOUDFLARE_BACKUP_TOKEN to it) or a
# re-seeded refresh token.
#
# Config (read from supabase/.env, or from the environment):
#   CF_ACCOUNT_ID, CF_KV_NAMESPACE_ID, CF_API_TOKEN
#   (CF_API_TOKEN needs Workers KV Storage → Edit on the account)
# =============================================================================
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CF_ENV="$BASE_DIR/.env"
ROOT_ENV="$BASE_DIR/../.env"

CHUNK_BYTES=$((24 * 1024 * 1024))   # 24 MiB (KV hard limit is 25 MiB)
KEEP_ARCHIVES=3                      # complete generations kept under archive/
RESTORE_ATTEMPTS=20                      # allow time for KV edge propagation during restore

CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_KV_NAMESPACE_ID="${CF_KV_NAMESPACE_ID:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_REFRESH_TOKEN="${CF_REFRESH_TOKEN:-}"

# Wrangler OAuth app (public client, used by `wrangler login`) — lets us renew
# the short-lived access token from the long-lived refresh token. Cloudflare's
# token endpoint also accepts Basic auth w/ client_id:client_secret, but this
# OAuth client is public so body-only is enough (matches wrangler's own code).
CF_OAUTH_CLIENT_ID="54d11594-84e4-41aa-b438-e81b8fa78ee7"

# ---------------------------------------------------------------------------
load_cfg() {
  local env_file
  for env_file in "$CF_ENV" "$ROOT_ENV"; do
    [ -f "$env_file" ] || continue
    [ -n "$CF_ACCOUNT_ID" ] || CF_ACCOUNT_ID="$(grep -E '^CF_ACCOUNT_ID=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_KV_NAMESPACE_ID" ] || CF_KV_NAMESPACE_ID="$(grep -E '^CF_KV_NAMESPACE_ID=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_API_TOKEN" ] || CF_API_TOKEN="$(grep -E '^CF_API_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_API_TOKEN" ] || CF_API_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    [ -n "$CF_REFRESH_TOKEN" ] || CF_REFRESH_TOKEN="$(grep -E '^CF_REFRESH_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  done
}

# Renew the OAuth access token from CF_REFRESH_TOKEN; rotates the refresh token
# too (Cloudflare refresh tokens are single-use) and persists both to .env so
# later snapshots and sibling processes stay in sync. The rotated token is also
# written to .cf-creds, which is archived with the state — without that, a
# rotation mid-session left the NEXT session holding an already-consumed token
# and the off-site backup chain died after one session.
cf_refresh_token() {
  [ -n "$CF_REFRESH_TOKEN" ] || return 1
  local resp at rt
  resp="$(curl -sS --max-time 20 -X POST "https://dash.cloudflare.com/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=refresh_token&refresh_token=$CF_REFRESH_TOKEN&client_id=$CF_OAUTH_CLIENT_ID")"
  at="$(printf '%s' "$resp" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  [ -n "$at" ] || return 1
  rt="$(printf '%s' "$resp" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')"
  CF_API_TOKEN="$at"
  if [ -f "$CF_ENV" ]; then
    sed -i -E '/^CF_API_TOKEN=/d; /^CF_REFRESH_TOKEN=/d' "$CF_ENV" 2>/dev/null || true
    {
      echo "CF_API_TOKEN=$at"
      [ -n "$rt" ] && echo "CF_REFRESH_TOKEN=$rt"
    } >> "$CF_ENV"
  fi
  # Archive-visible copy of the (single-use) refresh token — only overwrite
  # when Cloudflare actually handed back a rotation.
  if [ -n "$rt" ]; then
    printf 'CF_REFRESH_TOKEN=%s\n' "$rt" > "$BASE_DIR/.cf-creds" 2>/dev/null || true
    chmod 600 "$BASE_DIR/.cf-creds" 2>/dev/null || true
  fi
  echo "  ☁️  Cloudflare OAuth access token refreshed (~1h)"
  return 0
}

# put with a single 401 → refresh-retry (access tokens only live ~1h).
put_with_retry() {
  local status
  put_value "$1" "$2"
  status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  if [ "$status" -eq 2 ] && cf_refresh_token; then
    put_value "$1" "$2"
    return $?
  fi
  return 1
}

cfg_ok() {
  [ -n "$CF_ACCOUNT_ID" ] && [ -n "$CF_KV_NAMESPACE_ID" ] && [ -n "$CF_API_TOKEN" ]
}

# URL-encode only what our generated keys contain (keeps path-safe chars intact)
urlenc() {
  local s="$1" c
  local i len=${#s}
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
list_keys() {  # list_keys <urlencoded-prefix> -> one key per line, may paginate
  local prefix="$1" cursor="" body keys
  while :; do
    local q="?limit=1000&prefix=$prefix"
    [ -n "$cursor" ] && q="$q&cursor=$(urlenc "$cursor")"
    body="$(curl -fsS --max-time 30 "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/keys$q" \
      -H "Authorization: Bearer $CF_API_TOKEN")"
    if ! keys="$(printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("success") is not True:
    raise SystemExit(1)
for item in d.get("result", []):
    print(item["name"])
')"; then
      echo "  ERROR: Cloudflare KV returned an invalid key-list response" >&2
      return 1
    fi
    [ -n "$keys" ] && printf '%s\n' "$keys"
    if ! cursor="$(printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("success") is not True:
    raise SystemExit(1)
print(d.get("result_info", {}).get("cursor") or d.get("cursor") or "")
')"; then
      echo "  ERROR: Cloudflare KV returned an invalid pagination response" >&2
      return 1
    fi
    [ -z "$cursor" ] && break
  done
}

prune_archives() {
  local all keep="" tss="" ts latest_generation="" latest_tmp latest_status
  if ! all="$(list_keys 'archive%2F')"; then
    echo "  ⚠️  archive pruning skipped because KV listing was incomplete"
    return 1
  fi
  [ -z "$all" ] && return 0
  latest_tmp="$(mktemp)"
  get_value "latest/manifest.json" "$latest_tmp"
  latest_status=$?
  if [ "$latest_status" -eq 0 ]; then
    latest_generation="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("generation", ""))
' "$latest_tmp" 2>/dev/null)" || {
      rm -f "$latest_tmp"
      echo "  ⚠️  archive pruning skipped because the latest manifest is invalid"
      return 1
    }
  elif [ "$latest_status" -ne 2 ]; then
    rm -f "$latest_tmp"
    echo "  ⚠️  archive pruning skipped because the latest manifest could not be read"
    return 1
  fi
  rm -f "$latest_tmp"
  tss="$(printf '%s\n' "$all" \
    | sed -n 's|^archive/\([0-9][0-9]*\)/.*$|\1|p' \
    | sort -un)"
  [ -z "$tss" ] && return 0
  # Retain only complete generations; failed uploads have no manifest and
  # should not displace a usable backup or accumulate orphaned chunks.
  local complete
  complete="$(printf '%s\n' "$all" \
    | sed -n 's|^archive/\([0-9][0-9]*\)/manifest\.json$|\1|p' \
    | sort -un)"
  keep="$(printf '%s\n' "$complete" | tail -n "$KEEP_ARCHIVES")"
  if [ -n "$latest_generation" ] \
     && ! printf '%s\n' "$keep" | grep -Fxq "$latest_generation"; then
    keep="${keep}"$'\n'"$latest_generation"
  fi
  local doomed="" k delete_failed=0
  while IFS= read -r ts; do
    if ! printf '%s\n' "$keep" | grep -qx "$ts"; then
      while IFS= read -r k; do
        doomed="$doomed${doomed:+,}\"$k\""
      done <<EOF
$(printf '%s\n' "$all" | grep "^archive/$ts/")
EOF
    fi
  done <<EOF
$tss
EOF
  if [ -n "$doomed" ]; then
    local k code
    for k in $(printf '%s' "$doomed" | tr ',' '\n'); do
      k="${k#\"}"; k="${k%\"}"
      local enc enc_key
      enc_key=""
      # encode the key for the URL path
      local i len=${#k} c
      for ((i = 0; i < len; i++)); do
        c="${k:i:1}"
        case "$c" in
          [a-zA-Z0-9._-]) enc_key="$enc_key$c" ;;
          *) enc_key="$enc_key$(printf '%%%02X' "'$c")" ;;
        esac
      done
      code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$enc_key" \
        -H "Authorization: Bearer $CF_API_TOKEN")"
      if [ "$code" != "200" ]; then
        echo "  ⚠️  delete of $k returned HTTP $code"
        delete_failed=1
      fi
    done
    if [ "$delete_failed" -eq 1 ]; then
      return 1
    fi
    echo "  🧹 pruned $(printf '%s' "$doomed" | tr ',' '\n' | wc -l | tr -d ' ') old archive key(s) (kept newest $KEEP_ARCHIVES complete generation(s))"
  fi
}

put_value() {  # put_value <key> <file>
  local key="$1" file="$2" code
  code="$(curl -sS --max-time 120 -o /dev/null -w '%{http_code}' -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$(urlenc "$key")" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/octet-stream" --data-binary "@$file" || true)"
  [ "$code" = "200" ] && return 0
  [ "$code" = "401" ] && return 2
  echo "  ERROR: Cloudflare KV upload of $key returned HTTP ${code:-000}" >&2
  return 1
}

get_value() {  # get_value <key> <outfile>  (curl exit code 0 = found)
  local key="$1" dest="$2" code
  code="$(curl -sS --max-time 120 -o "$dest" -w '%{http_code}' \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$(urlenc "$key")" \
    -H "Authorization: Bearer $CF_API_TOKEN" || true)"
  [ "$code" = "200" ] && return 0
  rm -f "$dest"
  [ "$code" = "404" ] && return 2
  echo "  ERROR: Cloudflare KV download of $key returned HTTP ${code:-000}" >&2
  return 1
}

# ---------------------------------------------------------------------------
cmd_push() {
  # argv here is the ARGUMENTS ONLY: the dispatcher shifts the subcommand off, and
  # snapshot-state.sh invokes the CLI. Reading "$2" instead meant the positional was
  # always empty when cmd_verify called a sibling function directly.
  local file="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ::warning::Cloudflare backup SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  [ -n "$file" ] || { echo "  ⚠️  usage: cloudflare-backup.sh push <file>"; return 1; }
  [ -s "$file" ] || { echo "  ☁️  nothing to push ($file missing/empty)"; return 0; }

  local size base ts generation tmp sha manifest parts nn code attempt
  if ! tar -tzf "$file" >/dev/null 2>&1; then
    echo "  ERROR: refusing to upload an invalid state archive: $file" >&2
    return 1
  fi
  size="$(stat -c%s "$file")"
  base="$(basename "$file")"
  ts="$(date +%s)"
  generation="$(date +%s%N)"
  tmp="$(mktemp -d)"
  sha="$(sha256sum "$file" | cut -d' ' -f1)"

  if ! split -b "$CHUNK_BYTES" -d -a 8 "$file" "$tmp/chunk."; then
    echo "  ERROR: could not split state archive for Cloudflare KV" >&2
    rm -rf "$tmp"
    return 1
  fi
  parts=0
  for f in "$tmp"/chunk.*; do
    nn="${f##*.}"
    if ! put_with_retry "archive/$generation/$base.$nn" "$f"; then
      echo "  ::warning::Cloudflare backup: chunk $nn upload failed — previous latest preserved"
      rm -rf "$tmp"
      return 1
    fi
    attempt=0
    while [ "$attempt" -lt 5 ]; do
      attempt=$((attempt + 1))
      if get_value "archive/$generation/$base.$nn" "$tmp/readback.$nn" \
         && cmp -s "$f" "$tmp/readback.$nn"; then
        break
      fi
      [ "$attempt" -eq 5 ] || sleep 2
    done
    if [ "$attempt" -eq 5 ] && ! cmp -s "$f" "$tmp/readback.$nn"; then
      echo "  ::warning::Cloudflare backup: chunk $nn failed read-back verification — previous latest preserved"
      rm -rf "$tmp"
      return 1
    fi
    parts=$((parts + 1))
  done

  manifest="{\"version\":2,\"file\":\"$base\",\"ts\":$ts,\"generation\":\"$generation\",\"parts\":$parts,\"size\":$size,\"sha256\":\"$sha\"}"
  printf '%s' "$manifest" > "$tmp/manifest.json"
  if ! put_with_retry "archive/$generation/manifest.json" "$tmp/manifest.json"; then
    echo "  ::warning::Cloudflare archive manifest upload failed — previous latest preserved"
    rm -rf "$tmp"
    return 1
  fi
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    if get_value "archive/$generation/manifest.json" "$tmp/manifest.readback.json" \
       && cmp -s "$tmp/manifest.json" "$tmp/manifest.readback.json"; then
      break
    fi
    [ "$attempt" -eq 5 ] || sleep 2
  done
  if [ "$attempt" -eq 5 ] && ! cmp -s "$tmp/manifest.json" "$tmp/manifest.readback.json"; then
    echo "  ::warning::Cloudflare archive manifest failed read-back verification — previous latest preserved"
    rm -rf "$tmp"
    return 1
  fi

  if ! put_with_retry "latest/manifest.json" "$tmp/manifest.json"; then
    echo "  ⚠️  latest manifest upload failed — previous latest preserved"
    rm -rf "$tmp"
    return 1
  fi
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    if get_value "latest/manifest.json" "$tmp/latest.readback.json" \
       && cmp -s "$tmp/manifest.json" "$tmp/latest.readback.json"; then
      break
    fi
    [ "$attempt" -eq 5 ] || sleep 2
  done
  if [ "$attempt" -eq 5 ] && ! cmp -s "$tmp/manifest.json" "$tmp/latest.readback.json"; then
    echo "  ⚠️  latest manifest was not visible after upload; skipping retention pruning"
    rm -rf "$tmp"
    return 1
  fi

  echo "  ☁️  backup pushed and verified: $base (${parts}+1 keys, $(du -h "$file" | cut -f1)) → archive/$generation/"
  prune_archives || echo "  ⚠️  backup is safe; archive pruning will retry after the next upload"
  rm -rf "$tmp"
  return 0
}

# One attempt at restoring $1. Returns 2 when no backup exists, and 1 when the
# manifest, its chunks, or the assembled archive are invalid.
restore_once() {
  local outfile="$1"
  local tmp manifest mf base parts size sha generation prefix suffix_width ok outdir
  outdir="$(dirname "$outfile")"
  [ -d "$outdir" ] || return 1
  tmp="$(mktemp -d "$outdir/.cloudflare-restore.XXXXXX")"
  local get_status
  get_value "latest/manifest.json" "$tmp/manifest.json"
  get_status=$?
  if [ "$get_status" -ne 0 ]; then
    rm -rf "$tmp"
    if [ "$get_status" -eq 2 ]; then
      echo "  ☁️  no backup found in Cloudflare (latest/manifest.json missing)"
      return 2
    fi
    return 1
  fi
  if [ ! -s "$tmp/manifest.json" ]; then
    echo "  ☁️  no backup found in Cloudflare (latest/manifest.json missing)"
    rm -rf "$tmp"
    return 2
  fi
  mf="$(cat "$tmp/manifest.json")"
  base="$(printf '%s' "$mf" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
  parts="$(printf '%s' "$mf" | sed -n 's/.*"parts":\([0-9]*\).*/\1/p')"
  size="$(printf '%s' "$mf" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')"
  sha="$(printf '%s' "$mf" | sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p')"
  generation="$(printf '%s' "$mf" | sed -n 's/.*"generation":"\([0-9]*\)".*/\1/p')"
  if ! [[ "$base" =~ ^[A-Za-z0-9._-]{1,128}$ ]] \
     || ! [[ "$parts" =~ ^[0-9]{1,8}$ ]] \
     || ! [[ "$size" =~ ^[0-9]{1,18}$ ]] \
     || ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]] \
     || [ "$parts" -lt 1 ] || [ "$size" -lt 1 ]; then
    echo "  ⚠️  manifest unreadable"
    rm -rf "$tmp"
    return 1
  fi
  if [ -n "$generation" ]; then
    if ! [[ "$generation" =~ ^[0-9]{1,24}$ ]]; then
      echo "  ⚠️  manifest generation is invalid"
      rm -rf "$tmp"
      return 1
    fi
    prefix="archive/$generation"
    suffix_width=8
  else
    prefix="latest"
    suffix_width=2
  fi
  local expected_parts=$(( (size + CHUNK_BYTES - 1) / CHUNK_BYTES ))
  if [ "$parts" -ne "$expected_parts" ]; then
    echo "  ⚠️  manifest chunk count does not match the archive size"
    rm -rf "$tmp"
    return 1
  fi

  for ((i = 0; i < parts; i++)); do
    nn="$(printf "%0${suffix_width}d" "$i")"
    if ! get_value "$prefix/$base.$nn" "$tmp/part.$nn"; then
      echo "  ⚠️  chunk $prefix/$base.$nn missing or unreadable"
      rm -rf "$tmp"
      return 1
    fi
  done
  : > "$tmp/archive"
  for ((i = 0; i < parts; i++)); do
    nn="$(printf "%0${suffix_width}d" "$i")"
    cat "$tmp/part.$nn" >> "$tmp/archive"
  done

  local got
  got="$(stat -c%s "$tmp/archive")"
  if [ "$got" != "$size" ]; then
    echo "  ⚠️  size mismatch (got ${got}B, expected ${size}B) — discarding"
    rm -rf "$tmp"
    return 1
  fi
  local gotsha
  gotsha="$(sha256sum "$tmp/archive" | cut -d' ' -f1)"
  if [ "$gotsha" != "$sha" ]; then
    echo "  ⚠️  sha256 mismatch — discarding"
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -tzf "$tmp/archive" >/dev/null 2>&1; then
    echo "  ⚠️  downloaded state archive is not a valid tar.gz"
    rm -rf "$tmp"
    return 1
  fi
  if ! mv -f "$tmp/archive" "$outfile"; then
    echo "  ERROR: could not install the verified Cloudflare backup at $outfile" >&2
    rm -rf "$tmp"
    return 1
  fi
  echo "  ☁️  restored from Cloudflare: $outfile (${parts} chunks, $(du -h "$outfile" | cut -f1), sha256 ok)"
  rm -rf "$tmp"
  return 0
}

# Versioned chunk keys keep readers on a complete immutable generation even
# while a later snapshot is uploading.
cmd_restore() {
  # argv is ARGUMENTS ONLY (dispatcher shifts the subcommand). cmd_verify calls this
  # with a single path, so "$2" was empty and restore always printed its usage line.
  local outfile="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ☁️  Cloudflare restore SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  [ -n "$outfile" ] || { echo "  ⚠️  usage: cloudflare-backup.sh restore <outfile>"; return 1; }

  local attempt restore_status
  for ((attempt = 1; attempt <= RESTORE_ATTEMPTS; attempt++)); do
    restore_once "$outfile"
    restore_status=$?
    if [ "$restore_status" -eq 0 ]; then
      return 0
    fi
    if [ "$restore_status" -eq 2 ]; then
      return 2
    fi
    echo "  ⏳  backup read failed validation (attempt ${attempt}/${RESTORE_ATTEMPTS}) — retrying in 2s"
    if [ "$attempt" -lt "$RESTORE_ATTEMPTS" ]; then
      sleep 2
    fi
  done
  echo "  ⚠️  restore failed after ${RESTORE_ATTEMPTS} attempts — the backup is inconsistent"
  return 1
}

# Print the unix ts of the freshest off-site backup (stdout only, nothing on
# failure). The restore step compares this against the cached archive's
# embedded state-ts and adopts whichever is NEWER — a cancelled session never
# reaches the end-of-run cache save, so the KV mirror can be the only recent
# copy of the state.
cmd_manifest() {
  load_cfg
  cfg_ok || return 0
  local tmp status
  tmp="$(mktemp)"
  get_value "latest/manifest.json" "$tmp"
  status=$?
  if [ "$status" -eq 2 ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    rm -f "$tmp"
    return 1
  fi
  local ts
  if ! ts="$(python3 - "$tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)
ts = manifest.get("ts")
if isinstance(ts, bool) or not isinstance(ts, int) or ts < 0:
    raise SystemExit(1)
print(ts)
PY
)"; then
    echo "  ERROR: latest Cloudflare backup manifest is invalid" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  printf '%s' "$ts"
  return 0
}

cmd_refresh() {
  load_cfg
  if [ -z "$CF_REFRESH_TOKEN" ]; then
    echo "  ⚠️  no refresh token in .env — nothing to refresh"
    return 1
  fi
  if cf_refresh_token; then
    echo "  ☁️  access token renewed from the .env refresh token"
    return 0
  fi
  echo "  ⚠️  refresh from .env failed (token expired/revoked)"
  return 1
}

cmd_verify() {
  local tmp rc=0
  load_cfg
  if ! cfg_ok; then
    echo "  ⚠️  Cloudflare verify SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  tmp="$(mktemp -d)"
  cmd_restore "$tmp/candidate.tar.gz" || rc=1
  if [ "$rc" = 0 ] && [ -s "$tmp/candidate.tar.gz" ]; then
    echo "  ☁️  verify OK — latest backup is restorable ($(du -h "$tmp/candidate.tar.gz" | cut -f1))"
  else
    echo "  ::warning::Cloudflare verify FAILED — latest backup is NOT restorable"
    rc=1
  fi
  rm -rf "$tmp"
  return $rc
}

cmd_list() {
  load_cfg
  if ! cfg_ok; then
    echo "  ☁️  Cloudflare KV not configured"; return 0
  fi
  local all n
  if ! all="$(list_keys '')"; then
    echo "  ERROR: could not list Cloudflare KV backup keys" >&2
    return 1
  fi
  n="$(printf '%s\n' "$all" | grep -c '^latest\|^archive' || true)"
  if [ -z "$all" ]; then
    echo "  ☁️  namespace empty"
  else
    echo "  ☁️  $n keys:"
    printf '%s\n' "$all" | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  push)    shift; cmd_push "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  manifest) cmd_manifest "$@" ;;
  verify)  cmd_verify "$@" ;;
  refresh) cmd_refresh "$@" ;;
  list)    cmd_list ;;
  *) echo "usage: cloudflare-backup.sh {push <file> | restore <outfile> | manifest | verify | refresh | list}"; exit 1 ;;
esac