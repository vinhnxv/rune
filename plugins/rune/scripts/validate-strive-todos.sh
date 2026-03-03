#!/bin/bash
# scripts/validate-strive-todos.sh
# STRIVE-TODOS-001: Advisory hook that checks if per-task file-todos exist before
# worker spawn during /rune:strive. If todos are missing, injects additionalContext
# reminding the LLM to create them. NOT blocking — workers still spawn.
#
# Event: PreToolUse:Agent (same as enforce-teams.sh)
# Pattern: Advisory (additionalContext injection), not deny.
#
# Detection strategy:
#   1. Fast-path: if tool_name is not "Task" or "Agent", exit 0
#   2. Extract team_name from tool_input — if not rune-work-*, exit 0
#   3. Find strive state file (tmp/.rune-work-*.json)
#   4. Read todos_base from state file
#   5. Check if {todos_base}/work/ contains any .md files
#   6. If empty: inject additionalContext advisory
#   7. If has files: exit 0 silently

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}"
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Pre-flight: jq required
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap

# Fast path: only care about Agent/Task tool calls
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Task" && "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

# Extract team_name — only care about rune-work-* teams
TEAM_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || true)
if [[ -z "$TEAM_NAME" || ! "$TEAM_NAME" =~ ^rune-work- ]]; then
  exit 0
fi

# QUAL-5: Canonicalize CWD
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# Session identity for ownership filtering
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  # shellcheck source=resolve-session-identity.sh
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
else
  RUNE_CURRENT_CFG=""
  rune_pid_alive() { return 1; }
fi

# Find matching strive state file
# Extract timestamp from team_name: "rune-work-{timestamp}" → "{timestamp}"
TIMESTAMP="${TEAM_NAME#rune-work-}"
STATE_FILE="${CWD}/tmp/.rune-work-${TIMESTAMP}.json"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# Ownership check: skip if state file belongs to another session
stored_cfg=$(jq -r '.config_dir // empty' "$STATE_FILE" 2>/dev/null || true)
stored_pid=$(jq -r '.owner_pid // empty' "$STATE_FILE" 2>/dev/null || true)
if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then
  exit 0
fi
if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
  rune_pid_alive "$stored_pid" && exit 0
fi

# Read todos_base from state file
TODOS_BASE=$(jq -r '.todos_base // empty' "$STATE_FILE" 2>/dev/null || true)
if [[ -z "$TODOS_BASE" ]]; then
  exit 0
fi

# Check if {todos_base}/work/ contains any .md files
TODOS_WORK_DIR="${CWD}/${TODOS_BASE}work/"
if [[ ! -d "$TODOS_WORK_DIR" ]]; then
  # Directory doesn't exist at all — strong advisory
  cat << ADVISORY_JSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "STRIVE-TODOS-001: WARNING — No file-todos found in ${TODOS_BASE}work/. The directory does not exist. Per-task file-todos are MANDATORY (Phase 1). Before spawning more workers, create per-task todo files using the inline todo creation loop in strive/SKILL.md Phase 1. Each task needs a todo file with YAML frontmatter (id, title, status, priority, source, task_id, files, created_at)."
  }
}
ADVISORY_JSON
  exit 0
fi

# Count .md files in todos/work/
shopt -s nullglob
TODO_FILES=("${TODOS_WORK_DIR}"*.md)
shopt -u nullglob
TODO_COUNT=${#TODO_FILES[@]}

if [[ "$TODO_COUNT" -eq 0 ]]; then
  cat << ADVISORY_JSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "STRIVE-TODOS-001: WARNING — No file-todos found in ${TODOS_BASE}work/ (directory exists but is empty). Per-task file-todos are MANDATORY (Phase 1). Before spawning more workers, create per-task todo files using the inline todo creation loop in strive/SKILL.md Phase 1. Each task needs a todo file with YAML frontmatter (id, title, status, priority, source, task_id, files, created_at)."
  }
}
ADVISORY_JSON
  exit 0
fi

# Todos exist — allow silently
exit 0
