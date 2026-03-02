#!/usr/bin/env bash
# test-validate-mend-fixer-paths.sh — Tests for scripts/validate-mend-fixer-paths.sh
#
# Usage: bash plugins/rune/scripts/tests/test-validate-mend-fixer-paths.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SCRIPT="${SCRIPTS_DIR}/validate-mend-fixer-paths.sh"

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

setup_mend_project() {
  local project_name="$1"
  local identifier="$2"
  local inscription_json="${3:-}"

  local project_dir="${TMPDIR_ROOT}/${project_name}"
  mkdir -p "${project_dir}/tmp"
  mkdir -p "${project_dir}/tmp/mend/${identifier}"

  # owner_pid omitted — see test-validate-strive-worker-paths.sh for rationale.
  # $PPID inside piped bash subprocess differs from test harness PID.
  local chome="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '{"status":"active","config_dir":"%s","session_id":"test-session"}\n' \
    "$chome" > "${project_dir}/tmp/.rune-mend-${identifier}.json"

  if [[ -n "$inscription_json" ]]; then
    printf '%s\n' "$inscription_json" > "${project_dir}/tmp/mend/${identifier}/inscription.json"
  fi

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

# 1a. Read tool should pass through
result=$(run_validate '{"tool_name":"Read","tool_input":{"file_path":"/f"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Read tool exits 0 (pass-through)" "0" "$exit_code"

# 1b. Bash tool should pass through
result=$(run_validate '{"tool_name":"Bash","tool_input":{"command":"ls"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Bash tool exits 0 (pass-through)" "0" "$exit_code"

# 1c. Write tool proceeds to validation (but exits 0 without state)
result=$(run_validate '{"tool_name":"Write","tool_input":{"file_path":"/f"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Write tool with no state exits 0" "0" "$exit_code"

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

NOSTATE_CWD="${TMPDIR_ROOT}/nostate-mend"
mkdir -p "${NOSTATE_CWD}/tmp"

json=$(build_hook_input "Write" "${NOSTATE_CWD}/src/app.ts" "$NOSTATE_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "No mend state file exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 4. No Inscription File — fail open
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Inscription File ===\n"

NOINSC_CWD=$(setup_mend_project "noinsc-mend" "md001")
json=$(build_hook_input "Write" "${NOINSC_CWD}/src/app.ts" "$NOINSC_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "No inscription.json exits 0 (fail-open)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 5. Empty fixers Array — fail open with warning
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty Fixers Array ===\n"

EMPTY_CWD=$(setup_mend_project "empty-mend" "md002" '{"fixers": []}')
json=$(build_hook_input "Write" "${EMPTY_CWD}/src/app.ts" "$EMPTY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Empty fixers array exits 0 (fail-open)" "0" "$exit_code"
assert_contains "Empty fixers warns about enforcement disabled" "enforcement disabled" "$output"

# ═══════════════════════════════════════════════════════════════
# 6. Allowed Files — exact match
# ═══════════════════════════════════════════════════════════════
printf "\n=== Allowed Files ===\n"

ALLOW_CWD=$(setup_mend_project "allow-mend" "md003" '{
  "fixers": [
    {"name": "fixer-1", "file_group": ["src/app.ts", "src/utils.ts"]},
    {"name": "fixer-2", "file_group": ["tests/app.test.ts"]}
  ]
}')

# 6a. File in fixer-1 group
json=$(build_hook_input "Write" "${ALLOW_CWD}/src/app.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "File in fixer-1 group exits 0" "0" "$exit_code"
assert_not_contains "Allowed file has no deny" "deny" "$output"

# 6b. File in fixer-2 group
json=$(build_hook_input "Edit" "${ALLOW_CWD}/tests/app.test.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "File in fixer-2 group exits 0" "0" "$exit_code"
assert_not_contains "Cross-fixer file has no deny" "deny" "$output"

# 6c. Second file in fixer-1 group
json=$(build_hook_input "Write" "${ALLOW_CWD}/src/utils.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Second file in fixer-1 group exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 7. Denied Files — outside all groups
# ═══════════════════════════════════════════════════════════════
printf "\n=== Denied Files ===\n"

DENY_CWD=$(setup_mend_project "deny-mend" "md004" '{
  "fixers": [
    {"name": "fixer-1", "file_group": ["src/app.ts"]}
  ]
}')

# 7a. File not in any fixer's group
json=$(build_hook_input "Write" "${DENY_CWD}/config/settings.json" "$DENY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Denied file exits 0 (deny via JSON)" "0" "$exit_code"
assert_contains "Deny output contains SEC-MEND-001" "SEC-MEND-001" "$output"
assert_contains "Deny output contains permissionDecision deny" "deny" "$output"

# 7b. File in a different directory
json=$(build_hook_input "Edit" "${DENY_CWD}/lib/helpers.ts" "$DENY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "Different dir deny contains SEC-MEND-001" "SEC-MEND-001" "$output"

# 7c. NotebookEdit also denied
json=$(build_hook_input "NotebookEdit" "${DENY_CWD}/notebooks/analysis.ipynb" "$DENY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "NotebookEdit deny contains SEC-MEND-001" "SEC-MEND-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 8. Mend Output Directory — always allowed
# ═══════════════════════════════════════════════════════════════
printf "\n=== Mend Output Directory ===\n"

OUT_CWD=$(setup_mend_project "output-mend" "md005" '{
  "fixers": [
    {"name": "fixer-1", "file_group": ["src/app.ts"]}
  ]
}')

# 8a. Writing to tmp/mend/{identifier}/ is always allowed
json=$(build_hook_input "Write" "${OUT_CWD}/tmp/mend/md005/report.md" "$OUT_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Mend output dir exits 0" "0" "$exit_code"
assert_not_contains "Mend output dir has no deny" "deny" "$output"

# 8b. Deeply nested in output dir
json=$(build_hook_input "Write" "${OUT_CWD}/tmp/mend/md005/patches/fixer-1/patch.diff" "$OUT_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Deeply nested mend output dir exits 0" "0" "$exit_code"
assert_not_contains "Nested mend output has no deny" "deny" "$output"

# ═══════════════════════════════════════════════════════════════
# 9. Session Ownership — different session should skip
# ═══════════════════════════════════════════════════════════════
printf "\n=== Session Ownership ===\n"

OTHERSESS_CWD="${TMPDIR_ROOT}/othersess-mend"
mkdir -p "${OTHERSESS_CWD}/tmp"
mkdir -p "${OTHERSESS_CWD}/tmp/mend/md006"

# PID 1 (init) is always alive, simulates a different live session
printf '{"status":"active","config_dir":"%s","owner_pid":1,"session_id":"other"}\n' \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" > "${OTHERSESS_CWD}/tmp/.rune-mend-md006.json"

json=$(build_hook_input "Write" "${OTHERSESS_CWD}/src/app.ts" "$OTHERSESS_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Different session owner exits 0 (skip)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 10. Path Normalization — ./ prefix and absolute paths
# ═══════════════════════════════════════════════════════════════
printf "\n=== Path Normalization ===\n"

NORM_CWD=$(setup_mend_project "norm-mend" "md007" '{
  "fixers": [
    {"name": "fixer-1", "file_group": ["./src/app.ts"]}
  ]
}')

# 10a. Inscription has ./ prefix, tool provides absolute path
json=$(build_hook_input "Write" "${NORM_CWD}/src/app.ts" "$NORM_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Path with ./ prefix in inscription matches absolute input" "0" "$exit_code"
assert_not_contains "Normalized path has no deny" "deny" "$output"

# ═══════════════════════════════════════════════════════════════
# 11. Deny JSON Structure Validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Deny JSON Structure ===\n"

STRUCT_CWD=$(setup_mend_project "struct-mend" "md008" '{
  "fixers": [
    {"name": "fixer-1", "file_group": ["src/only.ts"]}
  ]
}')

json=$(build_hook_input "Write" "${STRUCT_CWD}/forbidden.ts" "$STRUCT_CWD")
result=$(run_validate "$json")
output="${result#*	}"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse"
assert h["permissionDecision"] == "deny"
assert "SEC-MEND-001" in h["permissionDecisionReason"]
assert "additionalContext" in h
' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Deny JSON has correct hookSpecificOutput structure\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Deny JSON structure invalid\n"
  printf "    output: %s\n" "$output"
fi

# ═══════════════════════════════════════════════════════════════
# 12. Empty / Malformed Input — fail open
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty / Malformed Input ===\n"

# 12a. Empty input
result=$(run_validate "")
exit_code="${result%%	*}"
assert_eq "Empty input exits 0 (fail-open)" "0" "$exit_code"

# 12b. Invalid JSON
result=$(run_validate "not-json")
exit_code="${result%%	*}"
assert_eq "Invalid JSON exits 0 (fail-open)" "0" "$exit_code"

# 12c. Empty JSON object
result=$(run_validate "{}")
exit_code="${result%%	*}"
assert_eq "Empty JSON object exits 0 (fail-open)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 13. Inactive State File — pass through
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inactive State File ===\n"

INACTIVE_CWD="${TMPDIR_ROOT}/inactive-mend"
mkdir -p "${INACTIVE_CWD}/tmp"
printf '{"status":"completed"}\n' > "${INACTIVE_CWD}/tmp/.rune-mend-done.json"

json=$(build_hook_input "Write" "${INACTIVE_CWD}/src/app.ts" "$INACTIVE_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Completed state file exits 0 (pass-through)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 14. Multiple Fixers — flat union of all file_groups
# ═══════════════════════════════════════════════════════════════
printf "\n=== Multiple Fixers (Flat Union) ===\n"

MULTI_CWD=$(setup_mend_project "multi-mend" "md009" '{
  "fixers": [
    {"name": "fixer-a", "file_group": ["src/a.ts"]},
    {"name": "fixer-b", "file_group": ["src/b.ts"]},
    {"name": "fixer-c", "file_group": ["src/c.ts"]}
  ]
}')

# 14a. fixer-b's file is allowed (even if called by fixer-a's subagent)
json=$(build_hook_input "Write" "${MULTI_CWD}/src/b.ts" "$MULTI_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Cross-fixer file allowed (flat union)" "0" "$exit_code"
assert_not_contains "Cross-fixer has no deny" "deny" "$output"

# 14b. File outside all fixers is denied
json=$(build_hook_input "Write" "${MULTI_CWD}/src/d.ts" "$MULTI_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "File outside all fixers denied" "SEC-MEND-001" "$output"

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
