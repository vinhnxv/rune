#!/bin/bash
# scripts/validate-gap-fixer-paths.sh
# SEC-GAP-001: Enforce path restrictions for gap-fixer Ashes.
# Blocks Write/Edit/NotebookEdit to sensitive infrastructure paths during gap-fix workflows.
#
# Detection strategy:
#   1. Fast-path: Check if tool is Write/Edit/NotebookEdit (only tools with file_path)
#   2. Fast-path: Check if caller is a subagent (team-lead is exempt)
#   3. Check for active gap-fix workflow via tmp/.rune-gap-fix-*.json state file
#   4. Verify session ownership (config_dir + owner_pid)
#   5. Validate target file path against blocked path patterns
#   6. Block (deny) if file matches a restricted path
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
# Exit 2 = hook error, stderr fed to Claude (not used by this script).
#
# Fail-open design: On any parsing/validation error, allow the operation.
# False negatives (allowing risky writes) are preferable to false positives
# (blocking legitimate gap fixes during remediation).

set -euo pipefail
umask 077
trap 'exit 0' ERR

# Pre-flight: jq is required for JSON parsing.
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — validate-gap-fixer-paths.sh hook is inactive (fail-open)" >&2
  exit 0
fi

# Source shared PreToolUse Write guard
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pretooluse-write-guard.sh
source "${SCRIPT_DIR}/lib/pretooluse-write-guard.sh"

# Common fast-path gates (sets INPUT, TOOL_NAME, FILE_PATH, TRANSCRIPT_PATH, CWD, CHOME)
rune_write_guard_preflight "validate-gap-fixer-paths.sh"

# Gap-specific: find active gap-fix state
rune_find_active_state ".rune-gap-fix-*.json"
rune_extract_identifier "$STATE_FILE" ".rune-gap-fix-"
rune_verify_session_ownership "$STATE_FILE"

# Normalize the target file path (resolve relative to CWD, strip ./)
rune_normalize_path

# XVER-003: Reject absolute paths not under CWD (scope bypass prevention)
# After normalization, REL_FILE_PATH should be relative. If it's still absolute,
# the original FILE_PATH was outside the project root — block it.
if [[ "$REL_FILE_PATH" == /* ]]; then
  rune_deny_write \
    "SEC-GAP-001: Absolute path outside project root denied." \
    "Gap fixers are restricted to files within the project directory. Target: ${FILE_PATH}"
fi

# ── Allow-list check (before deny block) ──────────────────────────────────
# Gap fixers are allowed to write to their output directory unconditionally.
GAP_OUTPUT_PREFIX="tmp/arc/${IDENTIFIER}/"
if [[ "$REL_FILE_PATH" == "${GAP_OUTPUT_PREFIX}"* ]]; then
  exit 0
fi

# ── Blocked path patterns ──────────────────────────────────────────────────
# Gap fixers must not touch infrastructure config, CI pipelines, or secret files.
# Path traversal check: reject paths that navigate outside CWD.
if [[ "$REL_FILE_PATH" == *../* ]] || [[ "$REL_FILE_PATH" == *.. ]]; then
  DENY_REASON="SEC-GAP-001: Path traversal denied."
  DENY=1
elif [[ "$REL_FILE_PATH" == */.* && "$REL_FILE_PATH" != .claude/* && "$REL_FILE_PATH" != */.gitignore && "$REL_FILE_PATH" != */.dockerignore && "$REL_FILE_PATH" != */.eslintrc* && "$REL_FILE_PATH" != */.prettierrc* && "$REL_FILE_PATH" != */.editorconfig ]]; then
  DENY_REASON="SEC-GAP-001: Hidden file access denied (use explicit allowlist for safe dotfiles)."
  DENY=1
elif [[ "$REL_FILE_PATH" == .claude/* ]]; then
  DENY_REASON="SEC-GAP-001: Gap fixers must not modify .claude/ configuration files."
  DENY=1
elif [[ "$REL_FILE_PATH" == .rune/* ]]; then
  DENY_REASON="SEC-GAP-001: Gap fixers must not modify .rune/ state files."
  DENY=1
elif [[ "$REL_FILE_PATH" == .github/* ]]; then
  DENY_REASON="SEC-GAP-001: Gap fixers must not modify .github/ CI/CD configuration."
  DENY=1
elif [[ "$REL_FILE_PATH" == node_modules/* ]]; then
  DENY_REASON="SEC-GAP-001: Gap fixers must not modify node_modules/."
  DENY=1
elif [[ "$REL_FILE_PATH" == .env || "$REL_FILE_PATH" == .env.* ]]; then
  DENY_REASON="SEC-GAP-001: Gap fixers must not modify environment/secret files."
  DENY=1
elif [[ "$REL_FILE_PATH" == *.yml && (
    "$REL_FILE_PATH" == *ci*.yml ||
    "$REL_FILE_PATH" == *pipeline*.yml ||
    "$REL_FILE_PATH" == *deploy*.yml ||
    "$REL_FILE_PATH" == *release*.yml
  ) ]]; then
  DENY_REASON="SEC-GAP-001: Gap fixers must not modify CI/deployment YAML files."
  DENY=1
else
  DENY=0
fi

if [[ "$DENY" -eq 1 ]]; then
  rune_deny_write \
    "${DENY_REASON} Target: ${REL_FILE_PATH}" \
    "Gap fixers are restricted to source code changes only. Infrastructure, CI config, secrets, and .claude/ files are off-limits. If this file genuinely needs updating as part of gap remediation, flag it as NEEDS_HUMAN_REVIEW in your output report (tmp/arc/${IDENTIFIER}/)."
fi

exit 0
