#!/bin/bash
# scripts/resolve-session-identity.sh
# Resolve current session identity for cross-session ownership checks.
# Source this file — do not execute directly.
#
# Exports: RUNE_CURRENT_CFG (resolved config dir path)
#          RUNE_CURRENT_SID (resolved session ID — primary identifier)
#          rune_pid_alive()  (EPERM-safe PID liveness check function)
# Uses: $PPID (Claude Code process PID — fallback identifier)
#       CLAUDE_SESSION_ID / RUNE_SESSION_ID (primary session identifier)
#
# Pattern: Three-layer session identity (XVER-004 FIX)
#   Layer 1: config_dir (CLAUDE_CONFIG_DIR) — installation/account isolation
#   Layer 2: session_id (CLAUDE_SESSION_ID) — primary session identifier
#   Layer 3: owner_pid ($PPID) — fallback for liveness checks
#
# Ownership check pattern (for callers):
#   stored_cfg=$(jq -r '.config_dir // empty' "$f")
#   stored_sid=$(jq -r '.session_id // empty' "$f")
#   stored_pid=$(jq -r '.owner_pid // empty' "$f")
#   # Layer 1: config dir mismatch → different installation
#   if [[ -n "$stored_cfg" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
#   # Layer 2: session_id match → same session (definitive)
#   if [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" && "$stored_sid" == "$RUNE_CURRENT_SID" ]]; then
#     : # same session, proceed
#   elif [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" && "$stored_sid" != "$RUNE_CURRENT_SID" ]]; then
#     continue  # different session, skip
#   else
#     # Layer 3: PID mismatch + alive → different session (fallback)
#     #          PID mismatch + dead → orphaned state (proceed with cleanup)
#     if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
#       rune_pid_alive "$stored_pid" && continue  # alive = different session
#     fi
#   fi

if [[ -z "${RUNE_CURRENT_CFG:-}" ]]; then
  RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  RUNE_CURRENT_CFG=$(cd "$RUNE_CURRENT_CFG" 2>/dev/null && pwd -P || echo "$RUNE_CURRENT_CFG")
  export RUNE_CURRENT_CFG
fi

# XVER-004 FIX: Resolve session ID as PRIMARY identifier
# Priority: CLAUDE_SESSION_ID > RUNE_SESSION_ID > empty (fallback to PPID)
if [[ -z "${RUNE_CURRENT_SID:-}" ]]; then
  RUNE_CURRENT_SID="${CLAUDE_SESSION_ID:-${RUNE_SESSION_ID:-}}"
  # Validate format: alphanumeric + hyphens/underscores only, max 64 chars
  if [[ -n "$RUNE_CURRENT_SID" && "$RUNE_CURRENT_SID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    RUNE_CURRENT_SID="${RUNE_CURRENT_SID:0:64}"
  else
    RUNE_CURRENT_SID=""  # Invalid or missing — fall back to PPID-based checks
  fi
  export RUNE_CURRENT_SID
fi

# ── PID liveness check (EPERM-safe) ──
# kill -0 returns non-zero for BOTH "no such process" (ESRCH) AND "permission denied" (EPERM).
# EPERM means the process IS alive but owned by another user — treat as alive to avoid
# cross-session contamination in restricted/multi-user runtimes.
#
# Usage: rune_pid_alive "$pid" && continue  # alive = skip
# Returns: 0 if alive (or EPERM), 1 if dead
rune_pid_alive() {
  local pid="$1"
  # Single kill -0 call — captures both exit code and stderr in one shot.
  # Fixes BACK-P2-001: eliminates TOCTOU window from double kill -0 calls.
  local err rc
  err=$(kill -0 "$pid" 2>&1); rc=$?
  [[ $rc -eq 0 ]] && return 0  # definitely alive
  # kill -0 failed — distinguish ESRCH (dead) from EPERM (alive, different user)
  case "$err" in
    *"Operation not permitted"*|*"EPERM"*|*"permission"*)
      return 0  # alive but owned by another user
      ;;
    *)
      return 1  # dead (ESRCH or other error)
      ;;
  esac
}
