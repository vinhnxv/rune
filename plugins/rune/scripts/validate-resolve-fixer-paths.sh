#!/bin/bash
# scripts/validate-resolve-fixer-paths.sh
# SEC-RESOLVE-001: Enforce file scope restrictions for resolve-todos fixer Ashes.
# Blocks Write/Edit/NotebookEdit when target file is outside the fixer's assigned file group.
#
# Detection strategy:
#   1. Fast-path: Check for active resolve-todos workflow via inscription.json
#   2. Verify session ownership (config_dir + owner_pid)
#   3. Read inscription.json to get fixer's assigned file group
#   4. Validate target file path against assigned group (exact match after normalization)
#   5. Block (deny) if file is outside the group
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
# Exit 2 = hook error, stderr fed to Claude (not used by this script).
#
# Fail-forward design: On any parsing/validation error, allow the operation.
# Fail-closed on missing jq (SECURITY-class requirement).

# Fail-forward: errors allow the operation (exit 0) rather than blocking.
# Using set -euo pipefail (aligned with sibling validate-*-paths.sh scripts).
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
# The ERR trap exits 0 before -e would trigger for most failures.
set -euo pipefail
umask 077
trap 'exit 0' ERR

# Pre-flight: jq is required for JSON parsing (SEC-002: fail-closed if missing)
if ! command -v jq &>/dev/null; then
  echo "SEC-RESOLVE-001: jq required but not found — denying to be safe" >&2
  exit 2
fi

# Source shared PreToolUse Write guard library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pretooluse-write-guard.sh
source "${SCRIPT_DIR}/lib/pretooluse-write-guard.sh"

# Common fast-path gates (sets INPUT, TOOL_NAME, FILE_PATH, TRANSCRIPT_PATH, CWD, CHOME)
rune_write_guard_preflight "validate-resolve-fixer-paths.sh"

# Resolve-todos-specific: find active resolve-todos state file
rune_find_active_state ".rune-resolve-todos-*.json"
rune_extract_identifier "$STATE_FILE" ".rune-resolve-todos-"
rune_verify_session_ownership "$STATE_FILE"

# Find inscription.json via signal directory
INSCRIPTION_PATH="${CWD}/tmp/.rune-signals/rune-resolve-todos-${IDENTIFIER}/inscription.json"
if [[ ! -f "$INSCRIPTION_PATH" ]]; then
  # No inscription found — fail open (allow)
  # This may happen if workflow is in early setup phase before inscription is written
  exit 0
fi

# Verify inscription session ownership (SEC-004: session isolation)
INSCR_CFG=$(jq -r '.config_dir // ""' "$INSCRIPTION_PATH" 2>/dev/null || true)
INSCR_PID=$(jq -r '.owner_pid // ""' "$INSCRIPTION_PATH" 2>/dev/null || true)
CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ -n "$INSCR_CFG" && "$INSCR_CFG" != "$CURRENT_CFG" ]]; then
  # Inscription belongs to a different session — skip (fail-open)
  exit 0
fi
if [[ -n "$INSCR_PID" && "$INSCR_PID" =~ ^[0-9]+$ ]] && ! kill -0 "$INSCR_PID" 2>/dev/null; then
  # Owner PID is dead — stale inscription, skip
  exit 0
fi

# ── Deny-overlay patterns ──
# These patterns are never allowed for resolve-todos fixers
DENY_PATTERNS=(
  ".claude/"
  ".github/"
  "node_modules/"
  ".env"
  ".env."
  "hooks/"
  ".hooks/"
  "plugins/rune/scripts/"
  ".claude/scripts/"
)

# Normalize the target file path (resolve relative to CWD, strip ./)
rune_normalize_path "$FILE_PATH"

# Use anchored matching to prevent false positives (e.g., "src/not.claude/file.ts")
for pattern in "${DENY_PATTERNS[@]}"; do
  if [[ "$REL_FILE_PATH" == "$pattern"* || "$REL_FILE_PATH" == */"$pattern"* ]]; then
    rune_deny_write \
      "SEC-RESOLVE-001: Deny-overlay blocked: ${REL_FILE_PATH} matches ${pattern}" \
      "Resolve-todos fixers cannot write to protected paths (${pattern}). Mark finding as SKIPPED if this file needs modification."
  fi
done

# Extract allowed files from task_ownership
ALLOWED_FILES=$(jq -r '.task_ownership[]?.files[]?' "$INSCRIPTION_PATH" 2>/dev/null || true)

if [[ -z "$ALLOWED_FILES" ]]; then
  # No files in allowlist yet — fail-open (workflow just started)
  # jq missing — fail-open per validate-*-paths.sh convention (see CLAUDE.md Hook Infrastructure)
  exit 0
fi

# Check if FILE_PATH matches any allowed file (SEC-001: exact match after normalization)
while IFS= read -r allowed; do
  # Strip leading ./ from allowed path too
  allowed="${allowed#./}"
  if [[ "$REL_FILE_PATH" == "$allowed" ]]; then
    # File is in an assigned group — allow
    exit 0
  fi
done <<< "$ALLOWED_FILES"

# Also allow writes to the resolve-todos output directory (agents write reports there)
# Scope output prefix to current workflow's timestamp (not any resolve-todos- dir)
# FLAW-004 FIX: Added trailing / to prevent prefix matching longer directory names
# (e.g., "resolve-todos-abc" matching "resolve-todos-abcdef/file.txt")
RESOLVE_OUTPUT_PREFIX="tmp/resolve-todos-${IDENTIFIER}/"
if [[ "$REL_FILE_PATH" == ${RESOLVE_OUTPUT_PREFIX}* ]]; then
  exit 0
fi

# DENY: File is outside all assigned groups and output directory
rune_deny_write \
  "SEC-RESOLVE-001: Resolve-todos fixer attempted to write outside assigned file group. Target: ${REL_FILE_PATH}. Only files listed in inscription.json task_ownership arrays are allowed." \
  "Resolve-todos fixers are restricted to editing files in their assigned file group (from inscription.json). If you need to edit this file, mark the finding as SKIPPED with reason \"cross-file dependency\" and the orchestrator will handle it."
