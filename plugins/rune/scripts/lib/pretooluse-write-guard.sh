#!/bin/bash
# scripts/lib/pretooluse-write-guard.sh
# Shared guard library for PreToolUse Write/Edit/NotebookEdit validation hooks.
#
# USAGE: Source this file AFTER set -euo pipefail, umask 077, and jq check.
#   set -euo pipefail
#   umask 077
#   if ! command -v jq &>/dev/null; then
#     echo "WARNING: jq not found — <script-name> hook is inactive" >&2
#     exit 0
#   fi
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/pretooluse-write-guard.sh
#   source "${SCRIPT_DIR}/lib/pretooluse-write-guard.sh"
#
# This library implements common fast-path gates for file-writing tool validation:
#   rune_write_guard_preflight()    — All common gates (stdin, tool filter, subagent, CWD)
#   rune_find_active_state()        — Find active workflow state file by glob
#   rune_extract_identifier()       — Extract + validate identifier from state file basename
#   rune_verify_session_ownership() — config_dir + owner_pid isolation check
#   rune_normalize_path()           — Normalize file path to CWD-relative
#   rune_deny_write()               — Emit standard deny JSON and exit
#
# EXPORTED VARIABLES (set as side-effects by functions):
#   INPUT          — raw stdin (1MB cap)
#   TOOL_NAME      — extracted tool name from hook event
#   FILE_PATH      — extracted file_path from tool_input
#   TRANSCRIPT_PATH — extracted transcript_path
#   CWD            — canonicalized working directory (absolute path)
#   CHOME          — resolved CLAUDE_CONFIG_DIR
#   STATE_FILE     — active state file path (set by rune_find_active_state)
#   IDENTIFIER     — validated identifier from state file (set by rune_extract_identifier)
#   REL_FILE_PATH  — CWD-relative file path (set by rune_normalize_path)
#
# EXIT BEHAVIOR:
#   All guard functions call `exit 0` on failure (fail-open — allow tool call).
#   Callers SHOULD have `trap 'exit 0' ERR` before calling library functions.
#   Under set -e, unexpected ERR-triggered exits inside library functions are caught
#   by the caller's trap (which is fail-open). This mirrors stop-hook-common.sh.
#
# IMPORTANT: Do NOT wrap library function calls in subshells $() — subshells
#   isolate the `exit`, turning fail-open into a silent no-op.
#
# DEPENDENCIES:
#   - jq (caller must check BEFORE sourcing)
#   - resolve-session-identity.sh (sourced by rune_verify_session_ownership)

# ── Source session identity resolver ──
_PRETOOLUSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../resolve-session-identity.sh
source "${_PRETOOLUSE_LIB_DIR}/../resolve-session-identity.sh"

# ── rune_write_guard_preflight(): Common fast-path gates ──
# Reads stdin, extracts tool name/file_path/transcript_path/CWD.
# Calls exit 0 if:
#   - Tool is not Write/Edit/NotebookEdit
#   - FILE_PATH is empty
#   - Caller is not a subagent (team-lead exempt)
#   - CWD is empty or non-absolute
# Also sets CHOME (resolved CLAUDE_CONFIG_DIR).
# Param: $1 = script name (for warning messages, currently unused but reserved)
rune_write_guard_preflight() {
  # SEC-2: 1MB cap to prevent unbounded stdin read (DoS prevention)
  # BACK-004: Guard against SIGPIPE (exit 141) when stdin closes early under set -e
  INPUT=$(head -c 1048576 2>/dev/null || true)

  # Fast-path 1: Extract tool name, file path, and transcript path in one jq call
  IFS=$'\t' read -r TOOL_NAME FILE_PATH TRANSCRIPT_PATH <<< \
    "$(printf '%s' "$INPUT" | jq -r '[.tool_name // "", .tool_input.file_path // "", .transcript_path // ""] | @tsv' 2>/dev/null)" || true

  # Only validate file-writing tools
  case "$TOOL_NAME" in
    Write|Edit|NotebookEdit) ;;
    *) exit 0 ;;
  esac

  # Fast-path 2: File path must be non-empty
  [[ -z "$FILE_PATH" ]] && exit 0

  # Fast-path 3: Only enforce for subagents (team-lead is the orchestrator — exempt)
  # transcript_path: documented common field (all hook events). Detection is best-effort.
  # If transcript_path is missing or doesn't contain /subagents/, allow the operation.
  if [[ -z "$TRANSCRIPT_PATH" ]] || [[ "$TRANSCRIPT_PATH" != */subagents/* ]]; then
    exit 0
  fi

  # Fast-path 4: Canonicalize CWD
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  [[ -z "$CWD" ]] && exit 0
  CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
  [[ -z "$CWD" || "$CWD" != /* ]] && exit 0

  # Resolve CHOME (CLAUDE_CONFIG_DIR) — needed by callers for talisman lookup etc.
  CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  CHOME=$(cd "$CHOME" 2>/dev/null && pwd -P 2>/dev/null || echo "$CHOME")
}

# ── rune_find_active_state(): Find active workflow state file ──
# Searches ${CWD}/tmp/ for files matching the given glob pattern with status == "active".
# Sets STATE_FILE variable.
# Calls exit 0 if no active state file found.
# Param: $1 = glob pattern (e.g., ".rune-work-*.json")
rune_find_active_state() {
  local pattern="$1"

  # Save nullglob state and enable it (prevent literal glob on no match)
  local _nullglob_was_set=0
  if shopt -q nullglob 2>/dev/null; then
    _nullglob_was_set=1
  fi
  shopt -s nullglob

  STATE_FILE=""
  for f in "${CWD}"/tmp/${pattern}; do
    if [[ -f "$f" ]] && jq -e '.status == "active"' "$f" >/dev/null 2>&1; then
      STATE_FILE="$f"
      break
    fi
  done

  # Restore nullglob state
  if [[ "$_nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi

  # No active workflow — allow (hook only applies during active workflow)
  [[ -z "$STATE_FILE" ]] && exit 0
  return 0
}

# ── rune_extract_identifier(): Extract identifier from state file basename ──
# Strips prefix and .json suffix from state file name.
# Sets IDENTIFIER variable.
# Calls exit 0 if identifier is empty or fails SAFE_IDENTIFIER validation.
# Param: $1 = state file path, $2 = prefix to strip (e.g., ".rune-work-")
rune_extract_identifier() {
  local state_file="$1"
  local prefix="$2"

  # FLAW-006: Escape sed metacharacters in prefix (dots in .rune-work-)
  local escaped_prefix
  escaped_prefix=$(printf '%s' "$prefix" | sed 's/[.[\*^$]/\\&/g')
  IDENTIFIER=$(basename "$state_file" .json | sed "s/^${escaped_prefix}//")

  # Security pattern: SAFE_IDENTIFIER — see security-patterns.md
  # Validate identifier format (safe chars + length cap)
  if [[ ! "$IDENTIFIER" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ${#IDENTIFIER} -gt 64 ]]; then
    # Invalid identifier — fail open (allow)
    exit 0
  fi
}

# ── rune_verify_session_ownership(): config_dir + owner_pid isolation check ──
# Verifies the state file belongs to the current session.
# Calls exit 0 if state belongs to a different session (fail-open skip).
# Param: $1 = state file path
rune_verify_session_ownership() {
  local state_file="$1"

  local state_config_dir
  state_config_dir=$(jq -r '.config_dir // empty' "$state_file" 2>/dev/null || true)
  local state_owner_pid
  state_owner_pid=$(jq -r '.owner_pid // empty' "$state_file" 2>/dev/null || true)

  # Use RUNE_CURRENT_CFG from resolve-session-identity.sh (aliased to CHOME for callers)
  local current_cfg="${RUNE_CURRENT_CFG:-$CHOME}"

  # Layer 1: Config-dir isolation (different Claude Code installations)
  if [[ -n "$state_config_dir" && "$state_config_dir" != "$current_cfg" ]]; then
    exit 0
  fi

  # Layer 2: PID isolation (same config dir, different session)
  # BACK-002 FIX: Use rune_pid_alive() for EPERM-safe PID liveness check
  if [[ -n "$state_owner_pid" ]]; then
    if rune_pid_alive "$state_owner_pid"; then
      # PID is alive — check if it matches our parent
      if [[ "$state_owner_pid" != "$PPID" ]]; then
        # State belongs to another live session — skip
        exit 0
      fi
    else
      # PID is dead — orphan state, clean up stale file and skip
      rm -f "$state_file" 2>/dev/null || true
      echo "TRACE: rune_verify_session_ownership: cleaned up stale state file (dead PID $state_owner_pid): $state_file" >&2
      exit 0
    fi
  fi
}

# ── rune_normalize_path(): Normalize file path to CWD-relative ──
# Resolves absolute paths relative to CWD, strips leading ./
# Sets REL_FILE_PATH variable.
# Param: $1 = file path to normalize (defaults to FILE_PATH if not provided)
rune_normalize_path() {
  local file_path="${1:-$FILE_PATH}"

  if [[ "$file_path" == /* ]]; then
    # Absolute path — make relative to CWD for comparison
    REL_FILE_PATH="${file_path#"${CWD}/"}"
  else
    REL_FILE_PATH="$file_path"
  fi

  # Strip leading ./ for consistent comparison
  REL_FILE_PATH="${REL_FILE_PATH#./}"
}

# ── rune_deny_write(): Emit standard deny JSON and exit ──
# Param: $1 = SEC code + reason (e.g., "SEC-STRIVE-001: Strive worker attempted...")
# Param: $2 = additional context message for Claude
rune_deny_write() {
  local reason="$1"
  local context="$2"

  local deny_msg
  deny_msg=$(jq -n \
    --arg reason "$reason" \
    --arg context "$context" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason,
        additionalContext: $context
      }
    }')

  printf '%s\n' "$deny_msg"
  exit 0
}
