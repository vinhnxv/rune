#!/usr/bin/env bash
# scripts/enforce-sleep-background.sh
# SLEEP-BG-001: Auto-add run_in_background:true for sleep commands >= 2 seconds.
#
# Claude Code harness blocks `sleep N` (N >= 2) without run_in_background.
# This hook intercepts the Bash call BEFORE the harness validation and
# injects run_in_background:true via updatedInput, preventing the block.
#
# Hook event: PreToolUse
# Matcher: Bash
# Classification: OPERATIONAL (fail-forward)
# Timeout: 2s (lightweight regex check)
#
# Exit 0 with no output: Not a sleep command, or already has run_in_background
# Exit 0 with hookSpecificOutput: Auto-inject run_in_background:true

set -euo pipefail
trap 'exit 0' ERR
umask 077

_rune_fail_forward() { exit 0; }
trap '_rune_fail_forward' ERR

# ── GUARD 0: jq required ──
command -v jq &>/dev/null || exit 0

# ── Read stdin ──
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# ── GUARD 1: Only process Bash tool calls ──
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

# ── GUARD 2: Skip if run_in_background already set ──
RIB=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.run_in_background // empty' 2>/dev/null || true)
[[ "$RIB" == "true" ]] && exit 0

# ── Extract command ──
CMD=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[[ -z "$CMD" ]] && exit 0

# ── Detect sleep N where N >= 2 ──
# Match patterns: "sleep 2", "sleep 90", "sleep 30 && cmd", "sleep 5; cmd"
# Also match: "sleep 2.5", "sleep 0.5" (fractional — check integer part)
# Do NOT match: "sleep 1", "sleep 0.5" (under 2s threshold)
if [[ "$CMD" =~ ^[[:space:]]*(setopt[[:space:]]+nullglob;[[:space:]]*)?sleep[[:space:]]+([0-9]+)(\.[0-9]+)? ]]; then
  SLEEP_SECS="${BASH_REMATCH[2]}"
  # Validate numeric
  [[ "$SLEEP_SECS" =~ ^[0-9]+$ ]] || exit 0
  # Only inject for sleep >= 2 seconds
  [[ "$SLEEP_SECS" -ge 2 ]] || exit 0
else
  # No sleep at start of command
  exit 0
fi

# ── Emit updatedInput with run_in_background:true ──
CMD_JSON=$(printf '%s' "$CMD" | jq -Rs '.')

cat <<ENDJSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"SLEEP-BG-001: auto-added run_in_background for sleep ${SLEEP_SECS}s","updatedInput":{"command":${CMD_JSON},"run_in_background":true},"additionalContext":"Auto-converted sleep ${SLEEP_SECS}s to background execution. You will be notified when it completes."}}
ENDJSON
exit 0
