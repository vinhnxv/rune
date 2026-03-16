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
  # Check if owner PID is still alive
  if kill -0 "$sf_owner_pid" 2>/dev/null; then
    # Different live session owns this — allow
    exit 0
  fi
  # Owner is dead — this is an orphan state; allow
fi

# Check talisman config: discipline.context_isolation (default: true)
CONTEXT_ISOLATION="true"
TALISMAN_SHARD="${CWD}/tmp/.talisman-resolved/misc.json"
if [[ -f "$TALISMAN_SHARD" ]]; then
  ci_val=$(jq -r '.discipline.context_isolation // "true"' "$TALISMAN_SHARD" 2>/dev/null || true)
  if [[ "$ci_val" == "false" ]]; then
    CONTEXT_ISOLATION="false"
  fi
fi

# If context isolation is disabled, allow
if [[ "$CONTEXT_ISOLATION" != "true" ]]; then
  exit 0
fi

# All conditions met: worker subagent trying to read a task file during active work
# → DENY with explanation
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"DISCIPLINE-CTX-001: Context isolation — worker Ashes cannot read task files (tmp/work/*/tasks/*.md). Workers receive their task via spawn prompt. Reading other workers task files violates the Separation Principle."}}'
exit 0
