#!/usr/bin/env bash
# doc-pack-staleness.sh — Lightweight SessionStart hook that checks installed
# doc pack manifests for staleness (default: > 90 days).
# Budget: < 50ms (stat + JSON parse per installed pack)
#
# Per enrichment C4:
# - Matcher: startup|resume
# - _rune_fail_forward ERR trap
# - umask 077
# - hookEventName: SessionStart in JSON output

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# ── EXIT trap: ensure hookEventName is always emitted (prevents "hook error") ──
_HOOK_JSON_SENT=false
_rune_session_hook_exit() {
  if [[ "$_HOOK_JSON_SENT" != "true" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart"}}\n'
  fi
}
trap '_rune_session_hook_exit' EXIT

# --- Trace logging ---
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}"
_trace() {
  [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && \
    printf '[%s] doc-pack-staleness: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"
  return 0
}

# --- Resolve paths ---
# QUAL-003 FIX: Single SCRIPT_DIR definition using BASH_SOURCE + pwd -P (matches convention)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Source platform helpers for _parse_iso_epoch
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MANIFESTS_DIR="$CHOME/echoes/global/manifests"

# Fast-path: no manifests directory → nothing to check
[[ -d "$MANIFESTS_DIR" ]] || exit 0
# Symlink guard
[[ -L "$MANIFESTS_DIR" ]] && exit 0

# --- Read staleness threshold from talisman (default: 90 days) ---
STALENESS_DAYS=90
# shellcheck source=lib/talisman-shard-path.sh
source "${SCRIPT_DIR}/lib/talisman-shard-path.sh" 2>/dev/null || true
if type _rune_resolve_talisman_shard &>/dev/null; then
  TALISMAN_SHARD=$(_rune_resolve_talisman_shard "misc" "${CWD:-}")
else
  # WORKTREE-FIX: Prefer CWD (worktree) over CLAUDE_PROJECT_DIR (may point to main repo per #27343)
  TALISMAN_SHARD="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}/tmp/.talisman-resolved/misc.json"
fi
if [[ -f "$TALISMAN_SHARD" && ! -L "$TALISMAN_SHARD" ]] && command -v jq &>/dev/null; then
  shard_val=$(jq -r '.echoes.global.staleness_days // empty' "$TALISMAN_SHARD" 2>/dev/null || true)
  if [[ -n "$shard_val" && "$shard_val" =~ ^[0-9]+$ ]]; then
    STALENESS_DAYS="$shard_val"
  fi
fi
_trace "staleness threshold: ${STALENESS_DAYS} days"

# --- Check each manifest for staleness ---
warnings=""
now=$(date +%s)

# Bash 3.2+: use nullglob to handle no-match gracefully
shopt -s nullglob
json_files=("$MANIFESTS_DIR"/*.json)
shopt -u nullglob

for manifest in "${json_files[@]}"; do
  [[ -f "$manifest" ]] || continue
  # Symlink guard per manifest
  [[ -L "$manifest" ]] && continue

  # Extract last_updated from manifest JSON
  if command -v jq &>/dev/null; then
    last_updated=$(jq -r '.last_updated // empty' "$manifest" 2>/dev/null || true)
  elif command -v python3 &>/dev/null; then
    last_updated=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('last_updated',''))" "$manifest" 2>/dev/null || true)
  else
    _trace "no jq or python3 — skipping staleness check"
    exit 0
  fi
  [[ -z "$last_updated" ]] && continue

  # Parse date and compute age
  if type _parse_iso_epoch &>/dev/null; then
    updated_epoch=$(_parse_iso_epoch "$last_updated" 2>/dev/null || echo 0)
  else
    # Fallback: try date parsing directly
    updated_epoch=$(date -d "$last_updated" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$last_updated" +%s 2>/dev/null || echo 0)
  fi
  [[ "$updated_epoch" == "0" ]] && continue

  age_days=$(( (now - updated_epoch) / 86400 ))

  if [[ "$age_days" -gt "$STALENESS_DAYS" ]]; then
    pack_name=$(basename "$manifest" .json)
    # Safe characters only
    [[ "$pack_name" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
    warnings="${warnings}[Doc Pack Staleness] \"${pack_name}\" last updated ${age_days} days ago (threshold: ${STALENESS_DAYS}). Run rune:echoes doc-packs update ${pack_name} to refresh.\n"
    _trace "stale: ${pack_name} (${age_days} days)"
  fi
done

# --- Output warning if any packs are stale ---
if [[ -n "$warnings" ]]; then
  _HOOK_JSON_SENT=true
  # Use jq/python3 for safe JSON string encoding (handles quotes, backslashes, control chars)
  if command -v jq &>/dev/null; then
    jq -n --arg w "$warnings" --arg event "SessionStart" \
      '{"hookSpecificOutput":{"hookEventName":$event,"additionalContext":$w}}'
  elif command -v python3 &>/dev/null; then
    python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))'  "$warnings"
  fi
fi

exit 0
