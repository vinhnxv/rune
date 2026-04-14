#!/bin/bash
# scripts/validate-shutdown-pattern.sh
# SHUTDOWN-DRIFT: Verifies canonical consumers of the team shutdown fallback
# pattern source lib/team-shutdown.sh instead of inlining the pattern.
#
# Detection strategy:
#   1. Fast-path: exit 0 if jq missing
#   2. Fast-path: exit 0 if FILE_PATH doesn't match one of the 3 canonical consumers
#   3. Slow path: read the file content and verify it sources lib/team-shutdown.sh
#      and calls rune_team_shutdown_fallback
#   4. Advisory (additionalContext) if pattern is missing — does NOT block writes
#
# Classification: OPERATIONAL (fail-forward)
# Exit 0 always — this hook is advisory-only, never denies writes.
#
# Canonical consumers (files that MUST source lib/team-shutdown.sh):
#   - plugins/rune/skills/team-sdk/references/engines.md
#   - plugins/rune/skills/roundtable-circle/references/orchestration-phases.md
#   - plugins/rune/skills/mend/references/phase-7-cleanup.md

set -euo pipefail
umask 077
trap 'exit 0' ERR

# Bypass: allow disabling for testing/development
if [[ "${_RUNE_DISABLE_SHUTDOWN_PATTERN_CHECK:-}" == "1" ]]; then
  exit 0
fi

# Pre-flight: jq is required for JSON parsing (fail-open if missing)
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Read stdin (PreToolUse hook input) — 1MB cap (SEC-2)
INPUT=$(head -c 1048576 2>/dev/null || true)

# Extract file_path from tool_input
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

# Extract CWD for relative path resolution
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && exit 0

# Normalize to relative path
REL_PATH="$FILE_PATH"
if [[ "$FILE_PATH" == /* ]]; then
  REL_PATH="${FILE_PATH#"${CWD}/"}"
fi
REL_PATH="${REL_PATH#./}"

# Fast-path: Only check the 3 canonical consumer files
case "$REL_PATH" in
  plugins/rune/skills/team-sdk/references/engines.md|\
  plugins/rune/skills/roundtable-circle/references/orchestration-phases.md|\
  plugins/rune/skills/mend/references/phase-7-cleanup.md)
    # This is a canonical consumer — proceed to content check
    ;;
  *)
    # Not a canonical consumer — no check needed
    exit 0
    ;;
esac

# Slow path: Extract the new content being written
# For Write tool: content field. For Edit tool: new_string field.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

NEW_CONTENT=""
case "$TOOL_NAME" in
  Write)
    NEW_CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)
    ;;
  Edit)
    # For Edit, we check the existing file + new_string — but the simplest
    # approach is to check the existing file on disk (the edit hasn't happened yet)
    # If the file already has the source pattern, allow. If it's being edited
    # to remove it, we'd need to check the result — but that's complex.
    # Pragmatic: check the file on disk. If it has the pattern, allow.
    # The advisory fires if the file currently lacks the pattern.
    if [[ -f "$FILE_PATH" ]]; then
      NEW_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || true)
    fi
    ;;
  *)
    exit 0
    ;;
esac

[[ -z "$NEW_CONTENT" ]] && exit 0

# Check for the sourcing pattern: source lib/team-shutdown.sh + rune_team_shutdown_fallback
# We look for BOTH indicators — the source line AND the function call
HAS_SOURCE=0
HAS_FUNCTION=0

if printf '%s' "$NEW_CONTENT" | grep -q 'lib/team-shutdown\.sh' 2>/dev/null; then
  HAS_SOURCE=1
fi

if printf '%s' "$NEW_CONTENT" | grep -q 'rune_team_shutdown_fallback' 2>/dev/null; then
  HAS_FUNCTION=1
fi

# If both are present, the file is compliant
if [[ "$HAS_SOURCE" -eq 1 && "$HAS_FUNCTION" -eq 1 ]]; then
  exit 0
fi

# Advisory: file is a canonical consumer but doesn't source the shared library
# This is additionalContext only — never blocks the write
ADVISORY_MSG="SHUTDOWN-DRIFT: '${REL_PATH}' is a canonical consumer of the team shutdown fallback pattern but does not appear to source lib/team-shutdown.sh and call rune_team_shutdown_fallback(). The shared library was extracted to prevent pattern drift across consumers. Please update Step 5 to: source lib/team-shutdown.sh and delegate to rune_team_shutdown_fallback()."

printf '%s\n' "$(jq -n \
  --arg ctx "$ADVISORY_MSG" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $ctx
    }
  }')"

exit 0
