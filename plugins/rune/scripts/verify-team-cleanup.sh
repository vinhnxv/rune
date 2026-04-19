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
      # VP-008 FIX (audit 20260414-194615): Filter by session ownership. Without this,
      # one session's TeamDelete reports zombie warnings about another session's live
      # teams (multi-session concurrency is supported per CLAUDE.md rule #11). Developers
      # learned to ignore TLC-002 output — real zombies buried in noise.
      #
      # If this dir has a .session marker, skip it when marker belongs to a different
      # live session. Dirs with no marker, or owned by current session / dead session,
      # fall through to the "remaining" list unchanged.
      if [[ -n "$HOOK_SESSION_ID" && -r "$dir/.session" ]]; then
        marker_session=$(jq -r '.session_id // empty' "$dir/.session" 2>/dev/null || echo "")
        marker_pid=$(jq -r '.owner_pid // empty' "$dir/.session" 2>/dev/null || echo "")
        if [[ -n "$marker_session" && "$marker_session" != "$HOOK_SESSION_ID" ]]; then
          # SEC-006 FIX (review c1a9714-018c647e): bounds-check marker_pid before
          # passing to `kill -0`. A crafted .session file with owner_pid 0 or -1
          # would otherwise expand to kill -0 0 (entire process group) or -1 (all).
          # kill -0 is signal-free so impact is bounded, but align with the
          # defensive pattern applied in resolve-session-identity.sh:207 and
          # detect-stale-lead.sh:101 (MON-005 FIX).
          if [[ -n "$marker_pid" && "$marker_pid" =~ ^[0-9]+$ && "$marker_pid" -gt 0 && "$marker_pid" -lt 4194304 ]] && kill -0 "$marker_pid" 2>/dev/null; then
            continue
          fi
        fi
      fi
      remaining+=("$dirname")
    fi
  # QUAL-003 NOTE: No -mmin filter — after TeamDelete, report ALL remaining dirs (informational).
  # Unlike TLC-001/003 which use -mmin +30 threshold, TLC-002 shows everything since
  # PostToolUse cannot block and you want to know about ANY residual dirs post-delete.
    # TEAM-002 FIX (audit 20260419-150325): include goldmask-* prefix to
    # match enforce-team-lifecycle.sh:201. Previously zombie goldmask teams
    # were invisible to the TLC-002 post-delete advisory.
  done < <(find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" -o -name "goldmask-*" \) 2>/dev/null)
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
