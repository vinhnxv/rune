#!/usr/bin/env bash
# test-validate-gap-fixer-paths.sh — Tests for scripts/validate-gap-fixer-paths.sh
#
# Usage: bash plugins/rune/scripts/tests/test-validate-gap-fixer-paths.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SCRIPT="${SCRIPTS_DIR}/validate-gap-fixer-paths.sh"

# ── Temp directory ──
# Resolve via pwd -P to handle macOS /var -> /private/var symlink.
TMPDIR_ROOT=$(mktemp -d)
TMPDIR_ROOT=$(cd "$TMPDIR_ROOT" && pwd -P)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# ── Test framework ──
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$expected" = "$actual" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s\n" "$test_name"
    printf "    expected: %q\n" "$expected"
    printf "    actual:   %q\n" "$actual"
  fi
}

assert_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle not found)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

assert_not_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle was found but should not be)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

# ── Test Setup Helpers ──

setup_gap_project() {
  local project_name="$1"
  local identifier="$2"

  local project_dir="${TMPDIR_ROOT}/${project_name}"
  mkdir -p "${project_dir}/tmp"
  mkdir -p "${project_dir}/tmp/arc/${identifier}"

  # owner_pid omitted — see test-validate-strive-worker-paths.sh for rationale.
  # $PPID inside piped bash subprocess differs from test harness PID.
  local chome="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '{"status":"active","config_dir":"%s","session_id":"test-session"}\n' \
    "$chome" > "${project_dir}/tmp/.rune-gap-fix-${identifier}.json"

  printf '%s' "$project_dir"
}

build_hook_input() {
  local tool_name="$1"
  local file_path="$2"
  local cwd="$3"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"transcript_path":"/some/path/subagents/fixer-1/transcript","cwd":"%s"}' \
    "$tool_name" "$file_path" "$cwd"
}

run_validate() {
  local json="$1"
  local exit_code=0
  local output
  output=$(printf '%s\n' "$json" | bash "$VALIDATE_SCRIPT" 2>&1) || exit_code=$?
  printf '%s\t%s' "$exit_code" "$output"
}

# ═══════════════════════════════════════════════════════════════
# 1. Tool Name Filtering
# ═══════════════════════════════════════════════════════════════
printf "\n=== Tool Name Filtering ===\n"

# 1a. Read tool passes through
result=$(run_validate '{"tool_name":"Read","tool_input":{"file_path":"/f"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Read tool exits 0 (pass-through)" "0" "$exit_code"

# 1b. Bash tool passes through
result=$(run_validate '{"tool_name":"Bash","tool_input":{"command":"ls"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Bash tool exits 0 (pass-through)" "0" "$exit_code"

# 1c. Glob tool passes through
result=$(run_validate '{"tool_name":"Glob","tool_input":{"pattern":"*.ts"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Glob tool exits 0 (pass-through)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 2. Subagent Detection
# ═══════════════════════════════════════════════════════════════
printf "\n=== Subagent Detection ===\n"

# 2a. No transcript_path — team lead exempt
result=$(run_validate '{"tool_name":"Write","tool_input":{"file_path":"/f"},"cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Missing transcript_path (team lead) exits 0" "0" "$exit_code"

# 2b. Non-subagent transcript path
result=$(run_validate '{"tool_name":"Write","tool_input":{"file_path":"/f"},"transcript_path":"/main/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Non-subagent transcript exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 3. No Active State File
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Active State File ===\n"

NOSTATE_CWD="${TMPDIR_ROOT}/nostate-gap"
mkdir -p "${NOSTATE_CWD}/tmp"

json=$(build_hook_input "Write" "${NOSTATE_CWD}/src/app.ts" "$NOSTATE_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "No gap-fix state file exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 4. Gap Output Directory — always allowed
# ═══════════════════════════════════════════════════════════════
printf "\n=== Gap Output Directory ===\n"

OUT_CWD=$(setup_gap_project "output-gap" "gf001")

# 4a. Writing to tmp/arc/{identifier}/ is allowed
json=$(build_hook_input "Write" "${OUT_CWD}/tmp/arc/gf001/report.md" "$OUT_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Gap output dir exits 0" "0" "$exit_code"
assert_not_contains "Gap output has no deny" "deny" "$output"

# 4b. Deeply nested in output dir
json=$(build_hook_input "Write" "${OUT_CWD}/tmp/arc/gf001/patches/fix.diff" "$OUT_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Deeply nested gap output exits 0" "0" "$exit_code"
assert_not_contains "Nested gap output has no deny" "deny" "$output"

# ═══════════════════════════════════════════════════════════════
# 5. Allowed Source Code Files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Allowed Source Code Files ===\n"

ALLOW_CWD=$(setup_gap_project "allow-gap" "gf002")

# 5a. Regular source file
json=$(build_hook_input "Write" "${ALLOW_CWD}/src/app.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Regular source file exits 0" "0" "$exit_code"
assert_not_contains "Source file has no deny" "deny" "$output"

# 5b. Test file
json=$(build_hook_input "Write" "${ALLOW_CWD}/tests/app.test.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Test file exits 0" "0" "$exit_code"
assert_not_contains "Test file has no deny" "deny" "$output"

# 5c. Python file
json=$(build_hook_input "Edit" "${ALLOW_CWD}/scripts/helper.py" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Python file exits 0" "0" "$exit_code"
assert_not_contains "Python file has no deny" "deny" "$output"

# 5d. Regular YAML (not CI-related)
json=$(build_hook_input "Write" "${ALLOW_CWD}/config/database.yml" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Non-CI YAML exits 0" "0" "$exit_code"
assert_not_contains "Non-CI YAML has no deny" "deny" "$output"

# ═══════════════════════════════════════════════════════════════
# 6. Blocked: .claude/ Configuration
# ═══════════════════════════════════════════════════════════════
printf "\n=== Blocked: .claude/ Configuration ===\n"

CLAUDE_CWD=$(setup_gap_project "claude-gap" "gf003")

# 6a. .claude/settings.json
json=$(build_hook_input "Write" "${CLAUDE_CWD}/.claude/settings.json" "$CLAUDE_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq ".claude/settings.json exits 0 (deny via JSON)" "0" "$exit_code"
assert_contains ".claude deny contains SEC-GAP-001" "SEC-GAP-001" "$output"
assert_contains ".claude deny mentions .claude/" ".claude/" "$output"

# 6b. .claude/talisman.yml
json=$(build_hook_input "Edit" "${CLAUDE_CWD}/.claude/talisman.yml" "$CLAUDE_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains ".claude/talisman.yml denied" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 7. Blocked: .github/ CI/CD
# ═══════════════════════════════════════════════════════════════
printf "\n=== Blocked: .github/ CI/CD ===\n"

GH_CWD=$(setup_gap_project "github-gap" "gf004")

# 7a. .github/workflows/ci.yml
json=$(build_hook_input "Write" "${GH_CWD}/.github/workflows/ci.yml" "$GH_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains ".github/workflows denied" "SEC-GAP-001" "$output"
assert_contains ".github deny mentions CI/CD" ".github/" "$output"

# 7b. .github/CODEOWNERS
json=$(build_hook_input "Write" "${GH_CWD}/.github/CODEOWNERS" "$GH_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains ".github/CODEOWNERS denied" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 8. Blocked: node_modules/
# ═══════════════════════════════════════════════════════════════
printf "\n=== Blocked: node_modules/ ===\n"

NM_CWD=$(setup_gap_project "nodemod-gap" "gf005")

# 8a. node_modules file
json=$(build_hook_input "Write" "${NM_CWD}/node_modules/package/index.js" "$NM_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "node_modules denied" "SEC-GAP-001" "$output"
assert_contains "node_modules deny mentions node_modules" "node_modules" "$output"

# ═══════════════════════════════════════════════════════════════
# 9. Blocked: .env Files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Blocked: .env Files ===\n"

ENV_CWD=$(setup_gap_project "env-gap" "gf006")

# 9a. .env file
json=$(build_hook_input "Write" "${ENV_CWD}/.env" "$ENV_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains ".env denied" "SEC-GAP-001" "$output"
assert_contains ".env deny mentions environment" "environment" "$output"

# 9b. .env.local file
json=$(build_hook_input "Write" "${ENV_CWD}/.env.local" "$ENV_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains ".env.local denied" "SEC-GAP-001" "$output"

# 9c. .env.production file
json=$(build_hook_input "Write" "${ENV_CWD}/.env.production" "$ENV_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains ".env.production denied" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 10. Blocked: CI/Deployment YAML Files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Blocked: CI/Deployment YAML ===\n"

CI_CWD=$(setup_gap_project "ci-gap" "gf007")

# 10a. ci.yml
json=$(build_hook_input "Write" "${CI_CWD}/ci.yml" "$CI_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "ci.yml denied" "SEC-GAP-001" "$output"
assert_contains "CI YAML deny mentions CI/deployment" "CI/deployment" "$output"

# 10b. pipeline.yml
json=$(build_hook_input "Write" "${CI_CWD}/pipeline.yml" "$CI_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "pipeline.yml denied" "SEC-GAP-001" "$output"

# 10c. deploy.yml
json=$(build_hook_input "Write" "${CI_CWD}/deploy.yml" "$CI_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "deploy.yml denied" "SEC-GAP-001" "$output"

# 10d. release.yml
json=$(build_hook_input "Write" "${CI_CWD}/release.yml" "$CI_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "release.yml denied" "SEC-GAP-001" "$output"

# 10e. Nested CI YAML (e.g., .github/workflows/ci-build.yml)
json=$(build_hook_input "Write" "${CI_CWD}/.github/workflows/ci-build.yml" "$CI_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "Nested CI YAML denied (matches .github/ first)" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 11. Blocked: Path Traversal
# ═══════════════════════════════════════════════════════════════
printf "\n=== Blocked: Path Traversal ===\n"

TRAV_CWD=$(setup_gap_project "trav-gap" "gf008")

# 11a. ../ in path
json=$(build_hook_input "Write" "${TRAV_CWD}/../etc/passwd" "$TRAV_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "Path traversal ../ denied" "SEC-GAP-001" "$output"
assert_contains "Path traversal deny mentions traversal" "traversal" "$output"

# ═══════════════════════════════════════════════════════════════
# 12. Blocked: Hidden Files (except .claude/)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Blocked: Hidden Files ===\n"

HIDDEN_CWD=$(setup_gap_project "hidden-gap" "gf009")

# 12a. .gitignore (hidden file under root)
json=$(build_hook_input "Write" "${HIDDEN_CWD}/.gitignore" "$HIDDEN_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
# Note: .gitignore matches */.* pattern — it's a hidden file at root
# The script checks REL_FILE_PATH which would be ".gitignore"
# The pattern */.* requires a / before the dot, so .gitignore at root may not match
# Let's check — if REL_FILE_PATH is ".gitignore", the pattern */.* wouldn't match
# (no / before the .). But .claude/* is tested first. Let's test a nested hidden file.

# 12b. Nested hidden file (src/.hidden)
json=$(build_hook_input "Write" "${HIDDEN_CWD}/src/.hidden-config" "$HIDDEN_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "Nested hidden file denied" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 13. Session Ownership — different session skips
# ═══════════════════════════════════════════════════════════════
printf "\n=== Session Ownership ===\n"

OTHERSESS_CWD="${TMPDIR_ROOT}/othersess-gap"
mkdir -p "${OTHERSESS_CWD}/tmp"
mkdir -p "${OTHERSESS_CWD}/tmp/arc/gf010"

printf '{"status":"active","config_dir":"%s","owner_pid":1,"session_id":"other"}\n' \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" > "${OTHERSESS_CWD}/tmp/.rune-gap-fix-gf010.json"

json=$(build_hook_input "Write" "${OTHERSESS_CWD}/.claude/settings.json" "$OTHERSESS_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Different session skips enforcement exits 0" "0" "$exit_code"
# With a different session, it should not produce a deny
assert_not_contains "Different session produces no deny" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 14. Deny JSON Structure Validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Deny JSON Structure ===\n"

STRUCT_CWD=$(setup_gap_project "struct-gap" "gf011")

json=$(build_hook_input "Write" "${STRUCT_CWD}/.claude/CLAUDE.md" "$STRUCT_CWD")
result=$(run_validate "$json")
output="${result#*	}"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse"
assert h["permissionDecision"] == "deny"
assert "SEC-GAP-001" in h["permissionDecisionReason"]
assert "additionalContext" in h
assert "NEEDS_HUMAN_REVIEW" in h["additionalContext"]
' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Deny JSON has correct hookSpecificOutput structure\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Deny JSON structure invalid\n"
  printf "    output: %s\n" "$output"
fi

# ═══════════════════════════════════════════════════════════════
# 15. Empty / Malformed Input — fail open
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty / Malformed Input ===\n"

# 15a. Empty input
result=$(run_validate "")
exit_code="${result%%	*}"
assert_eq "Empty input exits 0 (fail-open)" "0" "$exit_code"

# 15b. Invalid JSON
result=$(run_validate "not-json{{")
exit_code="${result%%	*}"
assert_eq "Invalid JSON exits 0 (fail-open)" "0" "$exit_code"

# 15c. Empty JSON
result=$(run_validate "{}")
exit_code="${result%%	*}"
assert_eq "Empty JSON exits 0 (fail-open)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 16. Inactive State File — pass through
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inactive State File ===\n"

INACTIVE_CWD="${TMPDIR_ROOT}/inactive-gap"
mkdir -p "${INACTIVE_CWD}/tmp"
printf '{"status":"completed"}\n' > "${INACTIVE_CWD}/tmp/.rune-gap-fix-done.json"

json=$(build_hook_input "Write" "${INACTIVE_CWD}/.claude/settings.json" "$INACTIVE_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Completed state file exits 0 (pass-through)" "0" "$exit_code"
assert_not_contains "Inactive state produces no deny" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 17. All Three Tool Types Enforced
# ═══════════════════════════════════════════════════════════════
printf "\n=== All Tool Types Enforced ===\n"

TOOLS_CWD=$(setup_gap_project "tools-gap" "gf012")

# 17a. Write to blocked path
json=$(build_hook_input "Write" "${TOOLS_CWD}/.github/actions.yml" "$TOOLS_CWD")
result=$(run_validate "$json")
output="${result#*	}"
assert_contains "Write to .github denied" "SEC-GAP-001" "$output"

# 17b. Edit to blocked path
json=$(build_hook_input "Edit" "${TOOLS_CWD}/node_modules/pkg/index.js" "$TOOLS_CWD")
result=$(run_validate "$json")
output="${result#*	}"
assert_contains "Edit to node_modules denied" "SEC-GAP-001" "$output"

# 17c. NotebookEdit to blocked path
json=$(build_hook_input "NotebookEdit" "${TOOLS_CWD}/.env" "$TOOLS_CWD")
result=$(run_validate "$json")
output="${result#*	}"
assert_contains "NotebookEdit to .env denied" "SEC-GAP-001" "$output"

# ═══════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════
printf "\n═══════════════════════════════════════════════════\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "═══════════════════════════════════════════════════\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
