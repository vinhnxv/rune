#!/bin/bash
# scripts/stamp-team-session.sh
# TLC-004: Post-TeamCreate session marker hook.
# Runs AFTER every successful TeamCreate call. Writes a .session marker file
# inside the team directory containing the session_id. This enables
# enforce-team-lifecycle.sh to verify session ownership during stale scans.
#
# PostToolUse hooks CANNOT block — they are informational only.
# Exit 0 on all errors (fail-open).
#
# NOTE: If this hook fails silently (fail-open), the team dir will lack a .session
# marker and be treated as stale by enforce-team-lifecycle.sh after 30 min.
# This is acceptable (fail-open design) — the worst case is premature cleanup
# of an unmarked team, not data corruption.
#
# Hook events: PostToolUse:TeamCreate
# Timeout: 5s

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Guard: jq dependency (PostToolUse — exit 0 if missing)
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Input size cap (SEC-2: 1MB DoS prevention)
INPUT=$(head -c 1048576)

# Tool name match (fast path)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "TeamCreate" ]]; then
  exit 0
fi

# Extract session_id from hook input
HOOK_SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
if [[ -z "$HOOK_SESSION_ID" ]]; then
  exit 0
fi

# Extract team_name from tool_input
TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || true)
if [[ -z "$TEAM_NAME" ]]; then
  exit 0
fi

# Validate team_name (defense-in-depth — lifecycle guard already validated)
if [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ "$TEAM_NAME" == *".."* ]]; then
  exit 0
fi

# CHOME: CLAUDE_CONFIG_DIR pattern (multi-account support)
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# CHOME absoluteness guard
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  exit 0
fi

TEAM_DIR="$CHOME/teams/${TEAM_NAME}"

# Verify team dir exists and is not a symlink
if [[ ! -d "$TEAM_DIR" ]] || [[ -L "$TEAM_DIR" ]]; then
  exit 0
fi

# Symlink guard on .session itself (close latent TOCTOU gap on write path)
if [[ -L "$TEAM_DIR/.session" ]]; then
  rm -f "$TEAM_DIR/.session" 2>/dev/null
fi

# Atomic write: .session.tmp.$$ then mv
TMP_FILE=$(mktemp "$TEAM_DIR/.session.tmp.XXXXXX")
if jq -n --arg sid "$HOOK_SESSION_ID" --arg pid "$PPID" --arg cfg "${RUNE_CURRENT_CFG:-}" '{session_id: $sid, owner_pid: $pid, config_dir: $cfg}' > "$TMP_FILE" 2>/dev/null; then
  mv -f "$TMP_FILE" "$TEAM_DIR/.session" 2>/dev/null || rm -f "$TMP_FILE" 2>/dev/null
else
  rm -f "$TMP_FILE" 2>/dev/null
fi

# QUAL-005 FIX: Use standard RUNE_TRACE_LOG path instead of hardcoded /tmp/rune-hook-trace.log
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] TLC-004: stamped .session for team=%s session=%s\n' "$(date '+%H:%M:%S')" "$TEAM_NAME" "$HOOK_SESSION_ID" >> "$RUNE_TRACE_LOG"

exit 0
