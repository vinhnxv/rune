#!/bin/bash
# Rune Context Statusline — Producer half of context monitoring pipeline
# Writes context metrics to bridge file for rune-context-monitor.sh consumer
set -euo pipefail
trap 'exit 0' ERR    # SB-SEC-001: fail-open — statusline must never crash
umask 077            # SB-SEC-003: bridge file not world-readable

# Session identity — resolved config_dir for cross-session isolation (Core Rule 11)
# GAP-2 FIX: Source shared resolver instead of inlining (matches all 5 ownership-check scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/resolve-session-identity.sh"
source "${SCRIPT_DIR}/lib/platform.sh"

# Trace logging (SB-IMPL: match all Rune hooks)
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] rune-statusline: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

INPUT=$(head -c 1048576 2>/dev/null || true)

# Extract fields with jq, fallback if unavailable
if ! command -v jq &>/dev/null; then
  echo "[Rune] (jq required for context bar)"
  exit 0
fi

# SB-PERF-001: Single jq call with @tsv instead of 6 separate invocations
IFS=$'\t' read -r MODEL DIR SESSION_ID REMAINING USED COST <<< "$(
  echo "$INPUT" | jq -r '[
    (.model.display_name // "Claude"),
    (.workspace.current_dir // ""),
    (.session_id // ""),
    (.context_window.remaining_percentage // ""),
    ((.context_window.used_percentage // 0) | tostring | split(".")[0]),
    (.cost.total_cost_usd // 0)
  ] | @tsv' 2>/dev/null
)" || { echo "[Rune] parse error"; exit 0; }
_trace "PARSED model=$MODEL used=$USED remaining=$REMAINING"

# --- Bridge file write (best-effort, never crash statusline) ---
if [[ -n "$SESSION_ID" && -n "$REMAINING" ]]; then
  BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}.json"
  # Validate session_id characters (prevent path traversal)
  if [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    # SB-SEC-004: Symlink guard before write
    [[ -L "$BRIDGE_FILE" ]] && rm -f "$BRIDGE_FILE"
    # SB-IMPL-003: Include config_dir + owner_pid for session isolation (Core Rule 11)
    # GAP-1 FIX: Use resolved $RUNE_CURRENT_CFG (from resolve-session-identity.sh)
    # so bridge value matches what on-session-stop.sh compares against (both use pwd -P)
    # SEC-P3-001: Atomic write via mktemp+mv (prevents partial reads by consumers)
    _BRIDGE_TMP=$(mktemp "${BRIDGE_FILE}.XXXXXX" 2>/dev/null) || true
    if [[ -n "${_BRIDGE_TMP:-}" ]]; then
      jq -n \
        --arg sid "$SESSION_ID" \
        --arg rem "$REMAINING" \
        --arg used "$USED" \
        --argjson ts "$(date +%s)" \
        --arg cfg "$RUNE_CURRENT_CFG" \
        --arg pid "${PPID:-0}" \
        '{session_id: $sid, remaining_percentage: ($rem | tonumber), used_pct: ($used | tonumber), timestamp: $ts, config_dir: $cfg, owner_pid: $pid}' \
        > "$_BRIDGE_TMP" 2>/dev/null && mv -f "$_BRIDGE_TMP" "$BRIDGE_FILE" 2>/dev/null || rm -f "$_BRIDGE_TMP" 2>/dev/null
    fi
    _trace "BRIDGE written: $BRIDGE_FILE"
  fi
fi

# --- Statusline display ---
# Color thresholds (based on used_percentage)
GREEN='\033[32m'; YELLOW='\033[33m'; ORANGE='\033[38;5;208m'
RED='\033[31m'; BLINK_RED='\033[5;31m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'

if [[ "$USED" -ge 90 ]]; then BAR_COLOR="$BLINK_RED"
elif [[ "$USED" -ge 80 ]]; then BAR_COLOR="$RED"
elif [[ "$USED" -ge 65 ]]; then BAR_COLOR="$ORANGE"
elif [[ "$USED" -ge 50 ]]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

# Progress bar (10 segments)
BAR_WIDTH=10
FILLED=$((USED * BAR_WIDTH / 100))
[[ "$FILLED" -gt "$BAR_WIDTH" ]] && FILLED=$BAR_WIDTH
EMPTY=$((BAR_WIDTH - FILLED))
# Build progress bar using printf loop (tr is byte-oriented, can't handle multi-byte UTF-8 chars)
BAR=""
_i=0; while [[ $_i -lt "$FILLED" ]]; do BAR="${BAR}█"; _i=$((_i+1)); done
_i=0; while [[ $_i -lt "$EMPTY" ]]; do BAR="${BAR}░"; _i=$((_i+1)); done

# Git branch (cached 5s to avoid lag)
# SB-SEC-005: Scope cache to user
CACHE_FILE="${TMPDIR:-/tmp}/rune-statusline-git-cache-$(id -u)"
CACHE_MAX_AGE=5
BRANCH=""
if [[ -d "${DIR}/.git" ]] || git -C "$DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  _cache_mtime=$(_stat_mtime "$CACHE_FILE"); _cache_mtime="${_cache_mtime:-0}"
  if [[ ! -f "$CACHE_FILE" ]] || [[ $(($(date +%s) - _cache_mtime)) -gt $CACHE_MAX_AGE ]]; then
    BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null || true)
    # P2-1 FIX: Symlink guard before cache write
    [[ -L "$CACHE_FILE" ]] && rm -f "$CACHE_FILE" 2>/dev/null
    echo "$BRANCH" > "$CACHE_FILE" 2>/dev/null || true
  else
    # P2-1 FIX: Symlink guard before cache read
    [[ -L "$CACHE_FILE" ]] && { rm -f "$CACHE_FILE" 2>/dev/null; BRANCH=""; } || BRANCH=$(cat "$CACHE_FILE" 2>/dev/null || true)
  fi
fi

# Cost formatting
COST_FMT=$(printf '$%.2f' "$COST" 2>/dev/null || echo '$0.00')

# Active Rune workflow detection
WORKFLOW=""
shopt -s nullglob
for f in "${DIR}"/tmp/.rune-*.json; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && continue   # P2-2 FIX: symlink guard on workflow detection
  WF_STATUS=$(jq -r '.status // empty' "$f" 2>/dev/null || true)  # QUAL-004 FIX: Renamed from STATUS (read-only in zsh)
  if [[ "$WF_STATUS" == "active" ]]; then
    WF_TYPE=$(jq -r '.workflow // empty' "$f" 2>/dev/null || true)
    WORKFLOW=" ${BOLD}${WF_TYPE}${RESET}"
    break
  fi
done
shopt -u nullglob

# Output
BRANCH_DISPLAY=""
[[ -n "$BRANCH" ]] && BRANCH_DISPLAY=" ${DIM}${BRANCH}${RESET}"
printf '%b' "${DIM}[${MODEL}]${RESET}${BRANCH_DISPLAY}${WORKFLOW} ${BAR_COLOR}${BAR}${RESET} ${USED}%% ${DIM}${COST_FMT}${RESET}\n"
