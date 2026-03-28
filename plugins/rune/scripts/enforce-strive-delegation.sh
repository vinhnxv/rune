#!/usr/bin/env bash
# STRIVE-001: Blocks direct Write/Edit on source files during arc work phase
# when no strive team has been created. Prevents the Tarnished from bypassing
# /rune:strive and implementing directly.
#
# Classification: SECURITY (fail-closed)
# Matcher: PreToolUse:Write|Edit
# Timeout: 5s
#
# Rationale: The Tarnished (orchestrator) must delegate implementation to
# /rune:strive workers. Direct implementation bypasses audit trail, quality
# gates, worker reports, and file ownership enforcement.
#
# Uses pretooluse-write-guard.sh library for:
#   - SIGPIPE-safe stdin reading (FLAW-002 fix)
#   - CWD from hook input JSON, not CLAUDE_PROJECT_DIR (FLAW-003 fix)
#   - CWD canonicalization (SEC-002 fix)
#   - Path normalization (FLAW-001 fix)
#   - Session isolation via rune_verify_session_ownership (FLAW-004 fix)
#   - Standard deny JSON output

set -euo pipefail
trap 'exit 2' ERR  # XVER-SEC-002 FIX: fail-closed from start for SECURITY hook
umask 077

# Fail-closed ERR trap (SECURITY classification)
trap 'echo "STRIVE-001: enforce-strive-delegation.sh crashed at line $LINENO" >&2; exit 2' ERR

# Guard: jq required (fail-closed for SECURITY hook)
command -v jq >/dev/null 2>&1 || { echo "STRIVE-001: jq not found" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library (provides stdin reading, path normalization, session checks)
# NOTE: We use individual library functions but NOT rune_write_guard_preflight(),
# because that function exempts non-subagents (team lead). STRIVE-001 enforces
# on the team lead specifically.
# shellcheck source=lib/pretooluse-write-guard.sh
source "${SCRIPT_DIR}/lib/pretooluse-write-guard.sh"

# ── Read stdin and extract fields ──

# SEC-2: 1MB cap, SIGPIPE-safe (FLAW-002 fix)
INPUT=$(head -c 1048576 2>/dev/null || true)

# Extract tool name — only enforce on Write/Edit
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL_NAME" in
  Write|Edit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# Extract file path
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

# Canonicalize CWD from hook input JSON (FLAW-003 fix: not CLAUDE_PROJECT_DIR)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && exit 0
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
[[ -z "$CWD" || "$CWD" != /* ]] && exit 0

# Resolve CHOME
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CHOME=$(cd "$CHOME" 2>/dev/null && pwd -P 2>/dev/null || echo "$CHOME")

# Normalize file path to CWD-relative (FLAW-001 fix: handles absolute paths)
rune_normalize_path "$FILE_PATH"
# REL_FILE_PATH is now set

# Skip if target is in tmp/ or .rune/ (artifacts, reports — not source files)
case "$REL_FILE_PATH" in
    tmp/*|.rune/*) exit 0 ;;
esac

# ── Check arc state with symlink rejection and session isolation ──

STATE_FILE="${CWD}/.rune/arc-phase-loop.local.md"

# Symlink rejection (FLAW-005 fix)
[[ -L "$STATE_FILE" ]] && exit 0

# Skip if no arc phase loop active
[[ -f "$STATE_FILE" ]] || exit 0

# Session isolation: verify state file belongs to this session (FLAW-004 fix)
# Extract config_dir and owner_pid from the state file
_state_config_dir=$(grep -o 'config_dir: .*' "$STATE_FILE" 2>/dev/null | head -1 | sed 's/config_dir: //' || true)
_state_owner_pid=$(grep -o 'owner_pid: .*' "$STATE_FILE" 2>/dev/null | head -1 | sed 's/owner_pid: //' || true)

# Layer 1: Config-dir isolation
if [[ -n "$_state_config_dir" ]] && [[ -n "${RUNE_CURRENT_CFG:-}" ]] && [[ "$_state_config_dir" != "$RUNE_CURRENT_CFG" ]]; then
  exit 0  # Different installation — skip
fi

# Layer 2: PID isolation
if [[ -n "$_state_owner_pid" ]] && [[ "$_state_owner_pid" =~ ^[0-9]+$ ]] && [[ "$_state_owner_pid" != "$PPID" ]]; then
  if rune_pid_alive "$_state_owner_pid"; then
    exit 0  # Different live session — skip
  fi
fi

# ── Check if arc work phase is in_progress ──

CHECKPOINT_PATH=$(grep -o 'checkpoint_path: .*' "$STATE_FILE" 2>/dev/null | head -1 | sed 's/checkpoint_path: //')
[[ -z "$CHECKPOINT_PATH" ]] && exit 0

# Symlink rejection on checkpoint (FLAW-005 fix)
[[ -L "$CHECKPOINT_PATH" ]] && exit 0
[[ -f "$CHECKPOINT_PATH" ]] || exit 0

WORK_STATUS=$(jq -r '.phases.work.status // empty' "$CHECKPOINT_PATH" 2>/dev/null || true)
[[ "$WORK_STATUS" != "in_progress" ]] && exit 0

# ── Work phase is in_progress — check if strive team exists ──

STRIVE_TEAM=$(find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-work-*" -o -name "arc-work-*" \) 2>/dev/null | head -1)

if [[ -z "$STRIVE_TEAM" ]]; then
    # No strive team exists — check if target is a source file (using normalized relative path)
    case "$REL_FILE_PATH" in
        plugins/*|src/*|lib/*|skills/*|agents/*|commands/*)
            # Block: direct write to source file without strive team
            rune_deny_write \
              "STRIVE-001: Direct implementation blocked during arc work phase. The Tarnished must delegate to /rune:strive — invoke Skill(\"rune:strive\", planPath) instead of writing files directly. No exceptions for documentation, markdown, or simple changes." \
              "STRIVE-001 DENIED: You are in arc Phase 5 (WORK) but have not invoked /rune:strive. Direct file edits are blocked. Call Skill(\"rune:strive\", ...) to spawn workers."
            ;;
    esac
fi

# Strive team exists or target is not a source file — allow
exit 0
