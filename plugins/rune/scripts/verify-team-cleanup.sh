#!/bin/bash
# scripts/verify-team-cleanup.sh
# TLC-002: Post-TeamDelete verification hook.
# Runs AFTER every TeamDelete call. Checks if zombie team dirs remain.
#
# NOTE: TeamDelete() takes no arguments — it targets the caller's active team.
# The SDK doesn't expose which team was deleted in PostToolUse input.
# Strategy: Scan for ALL rune-*/arc-* dirs and report any that exist.
# This is broader than needed but catches zombies reliably.
#
# PostToolUse hooks CANNOT block — they are informational only.
# Output on stdout is shown in transcript.
#
# Hook events: PostToolUse:TeamDelete
# Timeout: 5s

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Guard: jq dependency
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)

TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "TeamDelete" ]]; then
  exit 0
fi

# Extract session context for report prefixing
HOOK_SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
SHORT_SID="${HOOK_SESSION_ID:0:8}"

# SEC-2 NOTE: CWD not extracted — TLC-002 operates only on $CHOME paths.
# If adding CWD-relative operations, add canonicalization guard (see TLC-001 lines 36-41).

# Check for remaining rune-*/arc-* team dirs
# CHOME: CLAUDE_CONFIG_DIR pattern (multi-account support)
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# FIX-1: CHOME absoluteness guard
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  exit 0
fi

remaining=()
if [[ -d "$CHOME/teams/" ]]; then
  while IFS= read -r dir; do
    dirname=$(basename "$dir")
    if [[ "$dirname" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ ! -L "$dir" ]]; then
      remaining+=("$dirname")
    fi
  # QUAL-003 NOTE: No -mmin filter — after TeamDelete, report ALL remaining dirs (informational).
  # Unlike TLC-001/003 which use -mmin +30 threshold, TLC-002 shows everything since
  # PostToolUse cannot block and you want to know about ANY residual dirs post-delete.
  done < <(find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" \) 2>/dev/null)
fi

if [[ ${#remaining[@]} -gt 0 ]]; then
  _msg="TLC-002 POST-DELETE [${SHORT_SID:-no-sid}]: ${#remaining[@]} rune/arc team dir(s) still exist after TeamDelete: ${remaining[*]:0:5}. These may be from other workflows or zombie state. Run /rune:rest --heal if unexpected."
  jq -n --arg ctx "$_msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
fi

# SEC-P3-002: Symlink guard before trace log append
if [[ "${RUNE_TRACE:-}" == "1" ]]; then
  RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
  [[ ! -L "$RUNE_TRACE_LOG" ]] && echo "[$(date '+%H:%M:%S')] TLC-002 [${SHORT_SID:-no-sid}]: remaining team dirs after TeamDelete: ${#remaining[@]}" >> "$RUNE_TRACE_LOG"
fi

exit 0
