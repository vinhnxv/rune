#!/bin/bash
# scripts/validate-mend-fixer-paths.sh
# SEC-MEND-001: Enforce file scope restrictions for mend fixer Ashes.
# Blocks Write/Edit/NotebookEdit when target file is outside the fixer's assigned file group.
#
# Detection strategy:
#   1. Fast-path: Check if tool is Write/Edit/NotebookEdit (only tools with file_path)
#   2. Fast-path: Check if caller is a subagent (team-lead is exempt)
#   3. Check for active mend workflow via tmp/.rune-mend-*.json state file
#   4. Verify session ownership (config_dir + owner_pid)
#   5. Read inscription.json to get fixer's assigned file group
#   6. Validate target file path against assigned group
#   7. Block (deny) if file is outside the group
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
# Exit 2 = hook error, stderr fed to Claude (not used by this script).
#
# Fail-open design: On any parsing/validation error, allow the operation.
# False negatives (allowing out-of-scope edits) are preferable to false positives
# (blocking legitimate fixes).

set -euo pipefail
umask 077
trap 'exit 0' ERR

# Pre-flight: jq is required for JSON parsing (SEC-002: fail-closed if missing).
if ! command -v jq &>/dev/null; then
  echo "BLOCKED: jq not found — validate-mend-fixer-paths.sh hook cannot validate file paths" >&2
  exit 2
fi

# Source shared PreToolUse Write guard library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pretooluse-write-guard.sh
source "${SCRIPT_DIR}/lib/pretooluse-write-guard.sh"

# Common fast-path gates (sets INPUT, TOOL_NAME, FILE_PATH, TRANSCRIPT_PATH, CWD, CHOME)
rune_write_guard_preflight "validate-mend-fixer-paths.sh"

# Mend-specific: find active mend state file
rune_find_active_state ".rune-mend-*.json"
rune_extract_identifier "$STATE_FILE" ".rune-mend-"
rune_verify_session_ownership "$STATE_FILE"

# Read inscription.json to find fixer's assigned file group
INSCRIPTION_PATH="${CWD}/tmp/mend/${IDENTIFIER}/inscription.json"
if [[ ! -f "$INSCRIPTION_PATH" ]]; then
  # No inscription found — fail open (allow)
  # This may happen if mend is in early setup phase before inscription is written
  exit 0
fi

# SEC-005 FIX: Per-fixer file scope enforcement.
# Extract the caller's agent name from TRANSCRIPT_PATH to scope the allowlist
# to only the files assigned to THIS fixer (not all fixers).
# Transcript path format: .../subagents/{agent-name}/transcript
# Fixer names in inscription.json: mend-fixer-1, mend-fixer-w1-2, etc.
#
# Fallback: If agent name cannot be determined or doesn't match any fixer,
# fall back to the flat union of all file groups (fail-open, preserves
# backward compatibility).
CALLER_AGENT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  # Extract the segment after "subagents/" — this is the agent name
  # e.g., /path/subagents/mend-fixer-1/transcript → mend-fixer-1
  CALLER_AGENT=$(printf '%s' "$TRANSCRIPT_PATH" | sed -n 's|.*/subagents/\([^/]*\)/.*|\1|p')
fi

ALLOWED_FILES=""
if [[ -n "$CALLER_AGENT" ]]; then
  # Try per-fixer scoping: find this fixer's file_group in inscription.json
  # SEC-4: Validate agent name before using in jq query (safe chars only)
  if [[ "$CALLER_AGENT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    ALLOWED_FILES=$(jq -r --arg name "$CALLER_AGENT" \
      '.fixers[] | select(.name == $name) | .file_group[]' \
      "$INSCRIPTION_PATH" 2>/dev/null || true)
  fi
fi

# Wave-mode name resolution: spawned as "mend-fixer-w1-1" but inscription has "mend-fixer-1"
# Wave format: mend-fixer-w{wave}-{suffix} where suffix = fixer.name.split('-').pop()
if [[ -z "$ALLOWED_FILES" && -n "$CALLER_AGENT" && "$CALLER_AGENT" =~ -w[0-9]+-([0-9]+)$ ]]; then
  local_suffix="${BASH_REMATCH[1]}"
  base_name="mend-fixer-${local_suffix}"
  if [[ "$base_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    ALLOWED_FILES=$(jq -r --arg name "$base_name" \
      '.fixers[] | select(.name == $name) | .file_group[]' \
      "$INSCRIPTION_PATH" 2>/dev/null || true)
  fi
fi

if [[ -z "$ALLOWED_FILES" ]]; then
  # Fallback: flat union of all fixers' file groups (original behavior).
  # This triggers when: (1) CALLER_AGENT is empty, (2) agent name doesn't
  # match any fixer in inscription after wave-mode resolution,
  # or (3) matched fixer has an empty file_group.
  echo "WARNING: Could not scope allowlist to fixer '${CALLER_AGENT:-unknown}' — using flat union" >&2
  ALLOWED_FILES=$(jq -r '.fixers[].file_group[]' "$INSCRIPTION_PATH" 2>/dev/null || true)
fi

if [[ -z "$ALLOWED_FILES" ]]; then
  # Empty file group list — fail open (allow) but warn if inscription exists
  echo "WARNING: inscription.json exists but yielded no allowed files — file ownership enforcement disabled for this call" >&2
  exit 0
fi

# Normalize the target file path (resolve relative to CWD, strip ./)
rune_normalize_path "$FILE_PATH"

# Check if the target file is in the allowed set
while IFS= read -r allowed; do
  # Strip leading ./ from allowed path too
  allowed="${allowed#./}"
  if [[ "$REL_FILE_PATH" == "$allowed" ]]; then
    # File is in an assigned group — allow
    exit 0
  fi
done <<< "$ALLOWED_FILES"

# Also allow writes to the mend output directory (fixers write reports there)
MEND_OUTPUT_PREFIX="tmp/mend/${IDENTIFIER}/"
if [[ "$REL_FILE_PATH" == "${MEND_OUTPUT_PREFIX}"* ]]; then
  exit 0
fi

# DENY: File is outside all assigned groups and output directory
rune_deny_write \
  "SEC-MEND-001: Mend fixer attempted to write outside assigned file group. Target: ${REL_FILE_PATH}. Only files listed in inscription.json file_group arrays are allowed." \
  "Mend fixers are restricted to editing files in their assigned file group (from tmp/mend/${IDENTIFIER}/inscription.json). If you need to edit this file, mark the finding as SKIPPED with reason \"cross-file dependency, needs: [${REL_FILE_PATH}]\" and the orchestrator will handle it in Phase 5.5."
