#!/bin/bash
# scripts/validate-strive-worker-paths.sh
# SEC-STRIVE-001: Enforce file scope restrictions for strive worker Ashes.
# Blocks Write/Edit/NotebookEdit when target file is outside the worker's assigned file scope.
#
# Detection strategy:
#   1. Fast-path: Check if tool is Write/Edit/NotebookEdit (only tools with file_path)
#   2. Fast-path: Check if caller is a subagent (team-lead is exempt)
#   3. Check for active strive workflow via tmp/.rune-work-*.json state file
#   4. Verify session ownership (config_dir + owner_pid)
#   5. Read inscription.json to get task_ownership allowlist
#   6. Validate target file path against flat union of assigned files/dirs
#   7. Block (deny) if file is outside all assigned scopes
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
# Exit 2 = hook error, stderr fed to Claude (not used by this script).
#
# Fail-open design: On any parsing/validation error, allow the operation.
# False negatives (allowing out-of-scope edits) are preferable to false positives
# (blocking legitimate work).

set -euo pipefail
umask 077

# SEC-003 FIX: Classification resolved — this is an OPERATIONAL hook (fail-forward).
# The jq guard warns but does NOT block (exit 0), consistent with fail-forward behavior.
# False negatives (allowing out-of-scope edits) are preferable to false positives.
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Pre-flight: jq is required for JSON parsing.
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — validate-strive-worker-paths.sh cannot validate file paths (fail-forward)" >&2
  exit 0
fi

# Source shared PreToolUse Write guard library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pretooluse-write-guard.sh
source "${SCRIPT_DIR}/lib/pretooluse-write-guard.sh"
source "${SCRIPT_DIR}/lib/rune-state.sh"

# Common fast-path gates (sets INPUT, TOOL_NAME, FILE_PATH, TRANSCRIPT_PATH, CWD, CHOME)
rune_write_guard_preflight "validate-strive-worker-paths.sh"

# Strive-specific: find active work state
rune_find_active_state ".rune-work-*.json"
rune_extract_identifier "$STATE_FILE" ".rune-work-"
rune_verify_session_ownership "$STATE_FILE"

# Read inscription.json to find task ownership mapping
INSCRIPTION_PATH="${CWD}/tmp/.rune-signals/rune-work-${IDENTIFIER}/inscription.json"
if [[ ! -f "$INSCRIPTION_PATH" ]]; then
  # No inscription found — fail open (allow)
  # This may happen if strive is in early setup phase before inscription is written
  exit 0
fi

# Fast-path 7: Check for task_ownership key
if ! jq -e '.task_ownership' "$INSCRIPTION_PATH" >/dev/null 2>&1; then
  # No task_ownership key — old format or pre-Phase 1; fail open (allow)
  exit 0
fi

# Extract all file targets from task_ownership into a flat allowlist.
# DESIGN LIMITATION (SEC-STRIVE-001): We collect ALL tasks' file targets into one flat
# allowlist because transcript_path format is undocumented and may not contain
# the worker name reliably. This means worker-A can write to worker-B's files.
# Compensating controls: (1) blockedBy serialization prevents temporal overlap
# for dependent tasks (Phase 1), (2) prompt instructions restrict each worker
# to its assigned files, (3) ward check in Phase 4 catches any regressions.
# The key guarantee: files NOT in ANY task's target list are blocked.
ALLOWED_FILES=$(jq -r '.task_ownership | to_entries[].value.files[]? // empty' "$INSCRIPTION_PATH" 2>/dev/null || true)
ALLOWED_DIRS=$(jq -r '.task_ownership | to_entries[].value.dirs[]? // empty' "$INSCRIPTION_PATH" 2>/dev/null || true)

# Read talisman unrestricted_shared_files (if any)
TALISMAN_SHARED=""
for tpath in "${CWD}/${RUNE_STATE}/talisman.yml" "${CHOME}/talisman.yml"; do
  if [[ -f "$tpath" ]]; then
    # Extract work.unrestricted_shared_files array values (simple YAML parsing via grep)
    # Look for lines under unrestricted_shared_files: that start with "- "
    TALISMAN_SHARED=$(sed -n '/unrestricted_shared_files:/,/^[^ ]/{ /^ *- /s/^ *- *//p; }' "$tpath" 2>/dev/null || true)
    break
  fi
done

# Fast-path 8: If no file targets AND no dir targets exist, all tasks are unrestricted
if [[ -z "$ALLOWED_FILES" && -z "$ALLOWED_DIRS" && -z "$TALISMAN_SHARED" ]]; then
  exit 0
fi

# Normalize the target file path (resolve relative to CWD, strip ./)
rune_normalize_path "$FILE_PATH"

# SEC-AUDIT-004 FIX: Reject writes whose path traverses a symlink component.
# Worker Ashes are untrusted — a symlink at src/link -> /tmp/outside would
# escape the allowlist below without this check.
rune_reject_symlink_path "$FILE_PATH"

# Also allow writes to the strive output directory (workers write reports/patches there)
WORK_OUTPUT_PREFIX="tmp/work/${IDENTIFIER}/"
if [[ "$REL_FILE_PATH" == "${WORK_OUTPUT_PREFIX}"* ]]; then
  exit 0
fi

# Also allow writes to the signal directory
SIGNAL_PREFIX="tmp/.rune-signals/rune-work-${IDENTIFIER}/"
if [[ "$REL_FILE_PATH" == "${SIGNAL_PREFIX}"* ]]; then
  exit 0
fi

# Check against exact file matches
if [[ -n "$ALLOWED_FILES" ]]; then
  while IFS= read -r allowed; do
    allowed="${allowed#./}"
    if [[ "$REL_FILE_PATH" == "$allowed" ]]; then
      exit 0
    fi
  done <<< "$ALLOWED_FILES"
fi

# Check against directory prefix matches
if [[ -n "$ALLOWED_DIRS" ]]; then
  while IFS= read -r allowed_dir; do
    allowed_dir="${allowed_dir#./}"
    # Ensure dir ends with /
    [[ "$allowed_dir" != */ ]] && allowed_dir="${allowed_dir}/"
    if [[ "$REL_FILE_PATH" == "${allowed_dir}"* ]]; then
      exit 0
    fi
  done <<< "$ALLOWED_DIRS"
fi

# Check against talisman unrestricted_shared_files
if [[ -n "$TALISMAN_SHARED" ]]; then
  while IFS= read -r shared; do
    shared="${shared#./}"
    [[ -z "$shared" ]] && continue
    if [[ "$REL_FILE_PATH" == "$shared" ]]; then
      exit 0
    fi
  done <<< "$TALISMAN_SHARED"
fi

# DENY: File is outside all assigned scopes
rune_deny_write \
  "SEC-STRIVE-001: Strive worker attempted to write outside assigned file scope. Target: ${REL_FILE_PATH}. Only files listed in task_ownership (inscription.json) are allowed." \
  "Strive workers are restricted to editing files in their assigned task scope (from tmp/.rune-signals/rune-work-${IDENTIFIER}/inscription.json task_ownership). If you need to edit this file, send a message to team-lead requesting a new task that includes this file, or mark it as a dependency in your task output."
