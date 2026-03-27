#!/bin/bash
# scripts/validate-context-isolation.sh
# DISCIPLINE-CTX-001: Enforce context isolation for worker Ashes.
# Blocks Read tool when target file is a task file (tmp/work/*/tasks/*.md)
# and the caller is a worker team subagent (rune-work-*/arc-work-*).
#
# Purpose: Prevents workers from reading other workers' task files, which would
# violate the Separation Principle — each worker should only know its own task
# assignment, not other workers' criteria or self-assessments.
#
# Option A: Block ALL task file reads for worker teams (including own task file).
# Workers receive their task via the spawn prompt, not by reading task files.
#
# Detection strategy:
#   1. Fast-path: Check if tool is Read
#   2. Fast-path: Check if caller is a subagent (team-lead is exempt)
#   3. Check if target file matches tmp/work/*/tasks/*.md pattern
#   4. Check for active work workflow via tmp/.rune-work-*.json or tmp/.rune-arc-*.json
#   5. Verify session ownership (config_dir + owner_pid)
#   6. Read talisman discipline.context_isolation config (default: true)
#   7. Block (deny) if all conditions met
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
#
# Fail-open design: On any parsing/validation error, allow the operation.
# OPERATIONAL hook — _rune_fail_forward ERR trap (ADR-002).

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL — see ADR-002) ---
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

# Pre-flight: jq is required for JSON parsing.
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — validate-context-isolation.sh hook is inactive" >&2
  exit 0
fi

# SEC-2: 1MB cap to prevent unbounded stdin read
INPUT=$(head -c 1048576 2>/dev/null || true)

# Fast-path 1: Extract tool name, file path, and transcript path in one jq call
IFS=$'\t' read -r TOOL_NAME FILE_PATH TRANSCRIPT_PATH <<< \
  "$(printf '%s' "$INPUT" | jq -r '[.tool_name // "", .tool_input.file_path // "", .transcript_path // ""] | @tsv' 2>/dev/null)" || true

# Only intercept Read tool
if [[ "$TOOL_NAME" != "Read" ]]; then
  exit 0
fi

# Fast-path 2: File path must be non-empty
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Fast-path 3: Only enforce for subagents (team-lead is the orchestrator — exempt)
if [[ -z "$TRANSCRIPT_PATH" ]] || [[ "$TRANSCRIPT_PATH" != */subagents/* ]]; then
  exit 0
fi

# Fast-path 4: Quick pattern check — only block task file reads
# Matches: tmp/work/<anything>/tasks/<anything>.md
# This avoids the cost of state file discovery for non-matching reads.
case "$FILE_PATH" in
  */tmp/work/*/tasks/*.md) ;;
  *) exit 0 ;;
esac

# Fast-path 5: Canonicalize CWD
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then
  exit 0
fi

# Fast-path 6: Check for active work state file (rune-work-* or arc-work-*)
WORK_STATE=""
shopt -s nullglob
for sf in "${CWD}/tmp/.rune-work-"*.json "${CWD}/tmp/.rune-arc-"*.json; do
  # Validate status is active
  sf_status=$(jq -r '.status // ""' "$sf" 2>/dev/null || true)
  if [[ "$sf_status" == "active" ]]; then
    WORK_STATE="$sf"
    break
  fi
done
shopt -u nullglob

if [[ -z "$WORK_STATE" ]]; then
  # No active work workflow — allow (not a worker context)
  exit 0
fi

# Session ownership check: verify this state file belongs to our session
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-session-identity.sh
source "${SCRIPT_DIR}/resolve-session-identity.sh" 2>/dev/null || true

if [[ -n "${RUNE_CURRENT_CFG:-}" ]]; then
  sf_config_dir=$(jq -r '.config_dir // ""' "$WORK_STATE" 2>/dev/null || true)
  if [[ -n "$sf_config_dir" && "$sf_config_dir" != "$RUNE_CURRENT_CFG" ]]; then
    # State file belongs to a different session — allow
    exit 0
  fi
fi

sf_owner_pid=$(jq -r '.owner_pid // ""' "$WORK_STATE" 2>/dev/null || true)
if [[ -n "$sf_owner_pid" && "$sf_owner_pid" != "$PPID" ]]; then
  # Check if owner PID is still alive (EPERM-safe via resolve-session-identity.sh)
  if [[ -n "$sf_owner_pid" && "$sf_owner_pid" =~ ^[0-9]+$ ]] && rune_pid_alive "$sf_owner_pid"; then
    # Different live session owns this — allow
    exit 0
  fi
  # Owner is dead — this is an orphan state; allow
fi

# Check talisman config: discipline.context_isolation (default: true)
CONTEXT_ISOLATION="true"
TALISMAN_SHARD="${CWD}/tmp/.talisman-resolved/discipline.json"
if [[ -f "$TALISMAN_SHARD" ]]; then
  ci_val=$(jq -r 'if .context_isolation == null then "true" else .context_isolation end' "$TALISMAN_SHARD" 2>/dev/null || true)
  if [[ "$ci_val" == "false" ]]; then
    CONTEXT_ISOLATION="false"
  fi
fi

# If context isolation is disabled, allow
if [[ "$CONTEXT_ISOLATION" != "true" ]]; then
  exit 0
fi

# Self-read exemption: Workers MAY read their OWN task file.
# The task file path is embedded in TaskCreate metadata (task_file field).
# We allow reads when the file path matches a task file that the worker's own
# inscription.json task_ownership entry authorizes.
#
# CDX-GAP-001 FIX (v1.179.0): Workers must read their own task file as the
# first step of the updated lifecycle. Without this exemption, the Discipline
# Work Loop cannot function — workers would be blocked from reading their
# assigned task briefs.
#
# SHD-001 FIX (v1.180.0): Use exact task ID matching with word boundary.
# Previous blanket-allow made DISCIPLINE-CTX-001 a no-op — task-1 could read
# task-10, task-11, etc. Now we extract the task ID from the file path and
# verify it exists as an exact key in inscription.json task_ownership.
#
# The Separation Principle is preserved because:
# 1. Workers only know their OWN task file path (from TaskCreate metadata)
# 2. Workers have no incentive to enumerate other task files
# 3. The spawn prompt does not reveal other workers' task file paths
# 4. inscription.json task_ownership restricts WRITE scope (SEC-STRIVE-001)

# Extract the work timestamp directory from the file path to find inscription.json.
# FILE_PATH matches: */tmp/work/<timestamp>/tasks/<taskfile>.md
WORK_DIR=""
case "$FILE_PATH" in
  */tmp/work/*/tasks/*.md)
    # Strip everything after /tasks/ to get the work directory
    WORK_DIR="${FILE_PATH%%/tasks/*}"
    ;;
esac

if [[ -z "$WORK_DIR" ]]; then
  # Can't determine work directory — fail open (allow)
  exit 0
fi

# Extract task ID from the file being read.
# Task files follow the pattern: task-{ID}.md (e.g., task-1.md, task-2.1.md)
TASK_FILENAME=$(basename "$FILE_PATH")
TASK_ID=""
if [[ "$TASK_FILENAME" =~ ^(task-[0-9]+(\.[0-9]+)*)(\.md)$ ]]; then
  TASK_ID="${BASH_REMATCH[1]}"
fi

if [[ -z "$TASK_ID" ]]; then
  # Non-standard task file name — fail open (allow)
  exit 0
fi

# Look up inscription.json for this work directory.
# Try both signal-based path (rune-work-*/arc-work-*) and direct path.
INSCRIPTION_PATH=""
shopt -s nullglob
for insc in "${CWD}/tmp/.rune-signals/"*/inscription.json; do
  # Check if this inscription has task_ownership with our task ID as an exact key
  if jq -e --arg tid "$TASK_ID" '.task_ownership[$tid]' "$insc" >/dev/null 2>&1; then
    INSCRIPTION_PATH="$insc"
    break
  fi
done
shopt -u nullglob

if [[ -z "$INSCRIPTION_PATH" ]]; then
  # No inscription.json found with this task — fail open (allow)
  # This handles early lifecycle before inscription is written
  exit 0
fi

# Verify the task ID exists as an EXACT key in task_ownership.
# This prevents task-1 from matching task-10, task-11, etc.
if jq -e --arg tid "$TASK_ID" '.task_ownership | has($tid)' "$INSCRIPTION_PATH" >/dev/null 2>&1; then
  # Task ID is a valid exact key — allow the read
  exit 0
fi

# Task ID not found as an exact key — block the read (Separation Principle)
DENY_MSG=$(jq -n \
  --arg reason "DISCIPLINE-CTX-001: Context isolation blocked read of task file outside worker scope. Target: ${TASK_FILENAME}" \
  --arg context "Workers may only read their own assigned task file. The task ID '${TASK_ID}' is not in your assigned task_ownership scope. If you need this file, request it via SendMessage to team-lead." \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason,
      additionalContext: $context
    }
  }')

printf '%s\n' "$DENY_MSG"
exit 0
