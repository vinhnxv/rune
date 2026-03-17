#!/usr/bin/env bash
# scripts/context-percent-stop-guard.sh — Stop hook
# CTX-STOP-001: Context usage warning on conversation stop
# Classification: OPERATIONAL (fail-forward)
# Timeout: 5s
#
# IMPORTANT: This script MUST be placed LAST in the Stop array.
# arc-phase-stop-hook.sh, arc-batch-stop-hook.sh, arc-hierarchy-stop-hook.sh,
# arc-issues-stop-hook.sh, detect-workflow-complete.sh, and on-session-stop.sh
# all run before this guard. When an arc loop is active, this guard exits 0
# silently to avoid interfering with the phase loop continuation.
#
# Data source: Reuses the statusline bridge file (/tmp/rune-ctx-{SESSION_ID}.json)
# written by rune-statusline.sh on Notification:statusline events — same source
# as guard-context-critical.sh (PreToolUse). Avoids transcript parsing.
#
# Stop hook output format (PAT-011): exit 2 + stderr (NOT JSON stdout).
# stderr content becomes Claude's next prompt turn.
# exit 0 = allow stop silently (stdout/stderr discarded).

set -euo pipefail

# --- Fail-forward (OPERATIONAL hook) ---
_rune_fail_forward() { exit 0; }
trap '_rune_fail_forward' ERR

# --- Guard: jq dependency ---
command -v jq >/dev/null 2>&1 || exit 0

# --- Read stdin (SEC-2: 1MB cap) ---
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Extract session and stop metadata ---
SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[[ -z "$SESSION_ID" ]] && exit 0

# --- SEC-4: Validate SESSION_ID character set (prevent path injection) ---
if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

# --- Guard: Never block context_limit stops (would cause compaction deadlock) ---
STOP_REASON=$(printf '%s\n' "$INPUT" | jq -r '.stop_reason // .stopReason // empty' 2>/dev/null || true)
STOP_REASON_LOWER=$(printf '%s' "$STOP_REASON" | tr '[:upper:]' '[:lower:]')
case "$STOP_REASON_LOWER" in
  *context_limit*|*context_window*|*max_tokens*|*token_limit*) exit 0 ;;
esac

# --- Guard: Never block user abort ---
USER_REQUESTED=$(printf '%s\n' "$INPUT" | jq -r '.user_requested // .userRequested // false' 2>/dev/null || true)
[[ "$USER_REQUESTED" == "true" ]] && exit 0
case "$STOP_REASON_LOWER" in
  abort*|cancel*|interrupt*) exit 0 ;;
esac

# --- Guard: Exit silently when an arc loop is active ---
# arc-phase-stop-hook.sh, arc-batch-stop-hook.sh, arc-hierarchy-stop-hook.sh,
# and arc-issues-stop-hook.sh all handle arc loop continuation. Interfering
# would break the phase loop. Check for active arc loop state files.
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -n "$CWD" ]]; then
  # Arc loop state files live in ${CWD}/.claude/ (project-local), NOT $CHOME (global config)
  # Use find instead of glob to avoid zsh NOMATCH
  ARC_LOOP_COUNT=$(find "${CWD}/.claude" -maxdepth 1 \
    -name "arc-phase-loop.local.md" \
    -o -name "arc-batch-loop.local.md" \
    -o -name "arc-hierarchy-loop.local.md" \
    -o -name "arc-issues-loop.local.md" \
    2>/dev/null | wc -l | tr -dc '0-9' || echo "0")
  [[ -z "$ARC_LOOP_COUNT" ]] && ARC_LOOP_COUNT=0
  if (( ARC_LOOP_COUNT > 0 )); then
    exit 0  # Arc loop active — let arc hooks handle continuation
  fi
fi

# --- Source platform helpers for cross-platform stat ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh"

# --- Talisman gate (project → system fallback; symlink-safe via helper) ---
# shellcheck source=lib/talisman-shard-path.sh
source "${SCRIPT_DIR}/lib/talisman-shard-path.sh" 2>/dev/null || true
if type _rune_resolve_talisman_shard &>/dev/null; then
  TALISMAN_SHARD=$(_rune_resolve_talisman_shard "context_stop_guard")
else
  TALISMAN_SHARD="${CLAUDE_PROJECT_DIR:-.}/tmp/.talisman-resolved/context_stop_guard.json"
fi
WARNING_THRESHOLD=70
HIGH_THRESHOLD=85
MAX_BLOCKS=2
if [[ -f "$TALISMAN_SHARD" && ! -L "$TALISMAN_SHARD" ]]; then
  ENABLED=$(jq -r '.enabled // true' "$TALISMAN_SHARD" 2>/dev/null || echo "true")
  [[ "$ENABLED" == "false" ]] && exit 0
  # QUAL-001 FIX: Flat key access — shard file is the dedicated context_stop_guard object
  WARNING_THRESHOLD=$(jq -r '.warning_threshold // 70' "$TALISMAN_SHARD" 2>/dev/null || echo "70")
  HIGH_THRESHOLD=$(jq -r '.high_threshold // 85' "$TALISMAN_SHARD" 2>/dev/null || echo "85")
  MAX_BLOCKS=$(jq -r '.max_blocks_per_session // 2' "$TALISMAN_SHARD" 2>/dev/null || echo "2")
fi

# --- Read context % from statusline bridge file ---
# Bridge file written by rune-statusline.sh on Notification:statusline events.
# Consistent with guard-context-critical.sh (PreToolUse) which reads the same file.
BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}.json"

# Bridge must exist and not be a symlink (SEC-004)
[[ -f "$BRIDGE_FILE" ]] || exit 0
[[ -L "$BRIDGE_FILE" ]] && exit 0

# --- Staleness check (bridge older than 5 minutes = stale) ---
NOW=$(date +%s)
BRIDGE_MTIME=$(_stat_mtime "$BRIDGE_FILE"); BRIDGE_MTIME="${BRIDGE_MTIME:-0}"
AGE=$(( NOW - BRIDGE_MTIME ))
# Future timestamp guard
[[ "$AGE" -lt 0 ]] && exit 0
# 5 minutes = 300 seconds
(( AGE > 300 )) && exit 0

# --- Parse bridge data ---
USED_PCT=$(jq -r '.used_percentage // 0' "$BRIDGE_FILE" 2>/dev/null || echo "0")
REMAINING_PCT=$(jq -r '.remaining_percentage // 100' "$BRIDGE_FILE" 2>/dev/null || echo "100")

# Validate numeric values
[[ -z "$USED_PCT" || ! "$USED_PCT" =~ ^[0-9]+$ ]] && exit 0
[[ "$USED_PCT" -gt 100 ]] && exit 0

# --- Retry guard: max N blocks per session (prevent infinite loops) ---
GUARD_FILE="${TMPDIR:-/tmp}/rune-ctx-stop-guard-${SESSION_ID}.json"
BLOCK_COUNT=0
if [[ -f "$GUARD_FILE" && ! -L "$GUARD_FILE" ]]; then
  BLOCK_COUNT=$(jq -r '.block_count // 0' "$GUARD_FILE" 2>/dev/null || echo "0")
  [[ -z "$BLOCK_COUNT" || ! "$BLOCK_COUNT" =~ ^[0-9]+$ ]] && BLOCK_COUNT=0
fi
(( BLOCK_COUNT >= MAX_BLOCKS )) && exit 0

# --- Threshold evaluation ---
if (( USED_PCT >= HIGH_THRESHOLD )); then
  ADVICE="[CTX-STOP-001] Context usage at ${USED_PCT}% (${REMAINING_PCT}% remaining). Compact recommended before continuing. Run /compact or start a fresh session to maintain quality."
  # Increment block counter (atomic write via tmp+mv pattern)
  _tmpf=$(mktemp "${TMPDIR:-/tmp}/rune-ctx-guard-tmp.XXXXXX" 2>/dev/null) || _tmpf=""
  if [[ -n "$_tmpf" ]]; then
    jq -n --argjson c "$(( BLOCK_COUNT + 1 ))" '{ block_count: $c }' > "$_tmpf" 2>/dev/null \
      && mv "$_tmpf" "$GUARD_FILE" 2>/dev/null || rm -f "$_tmpf" 2>/dev/null
  else
    jq -n --argjson c "$(( BLOCK_COUNT + 1 ))" '{ block_count: $c }' > "$GUARD_FILE" 2>/dev/null || true
  fi
  # exit 2 + stderr = Stop hook "block" (PAT-011)
  printf '%s\n' "$ADVICE" >&2 2>/dev/null || true
  exit 2

elif (( USED_PCT >= WARNING_THRESHOLD )); then
  ADVICE="[CTX-STOP-001] Context usage at ${USED_PCT}% (${REMAINING_PCT}% remaining). Consider compacting soon to maintain quality. Run /compact when convenient."
  _tmpf=$(mktemp "${TMPDIR:-/tmp}/rune-ctx-guard-tmp.XXXXXX" 2>/dev/null) || _tmpf=""
  if [[ -n "$_tmpf" ]]; then
    jq -n --argjson c "$(( BLOCK_COUNT + 1 ))" '{ block_count: $c }' > "$_tmpf" 2>/dev/null \
      && mv "$_tmpf" "$GUARD_FILE" 2>/dev/null || rm -f "$_tmpf" 2>/dev/null
  else
    jq -n --argjson c "$(( BLOCK_COUNT + 1 ))" '{ block_count: $c }' > "$GUARD_FILE" 2>/dev/null || true
  fi
  printf '%s\n' "$ADVICE" >&2 2>/dev/null || true
  exit 2
fi

# Below threshold — allow stop silently
exit 0
