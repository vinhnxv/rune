#!/usr/bin/env bash
# test-validate-strive-worker-paths.sh — Tests for scripts/validate-strive-worker-paths.sh
#
# Usage: bash plugins/rune/scripts/tests/test-validate-strive-worker-paths.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SCRIPT="${SCRIPTS_DIR}/validate-strive-worker-paths.sh"

# ── Temp directory ──
# Resolve via pwd -P to handle macOS /var -> /private/var symlink.
# The validate scripts canonicalize CWD with pwd -P, so all paths
# in test fixtures must use the resolved form to match.
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

# Create a fully valid project directory with state file and inscription
# Returns: CWD path
setup_strive_project() {
  local project_name="$1"
  local identifier="$2"
  local task_ownership_json="${3:-}"

  local project_dir="${TMPDIR_ROOT}/${project_name}"
  mkdir -p "${project_dir}/tmp"
  mkdir -p "${project_dir}/tmp/.rune-signals/rune-work-${identifier}"
  mkdir -p "${project_dir}/tmp/work/${identifier}"

  # Create active state file.
  # PATT-001 EXCEPTION: owner_pid is deliberately omitted so the session
  # ownership check is bypassed for THIS test only. When the validator runs
  # in a subshell ($() capture), $PPID inside the validator differs from
  # $PPID/$$ in the test harness, so we cannot predict the correct value.
  # Omitting owner_pid causes rune_verify_session_ownership() to skip the
  # PID check entirely (empty field → no enforcement). This is an explicit
  # test-harness-only workaround, NOT a schema contract — production state
  # files MUST include all three session-isolation fields per CLAUDE.md.
  local chome="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '{"status":"active","config_dir":"%s","session_id":"test-session"}\n' \
    "$chome" > "${project_dir}/tmp/.rune-work-${identifier}.json"

  # Create inscription.json if task_ownership provided
  if [[ -n "$task_ownership_json" ]]; then
    printf '%s\n' "$task_ownership_json" > "${project_dir}/tmp/.rune-signals/rune-work-${identifier}/inscription.json"
  fi

  printf '%s' "$project_dir"
}

# Build the hook JSON input for a Write/Edit/NotebookEdit call as a subagent
build_hook_input() {
  local tool_name="$1"
  local file_path="$2"
  local cwd="$3"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"transcript_path":"/some/path/subagents/worker-1/transcript","cwd":"%s"}' \
    "$tool_name" "$file_path" "$cwd"
}

# Helper: run the script with given JSON on stdin
run_validate() {
  local json="$1"
  local exit_code=0
  local output
  output=$(printf '%s\n' "$json" | bash "$VALIDATE_SCRIPT" 2>&1) || exit_code=$?
  printf '%s\t%s' "$exit_code" "$output"
}

# ═══════════════════════════════════════════════════════════════
# 1. Tool Name Filtering — non-write tools should pass through
# ═══════════════════════════════════════════════════════════════
printf "\n=== Tool Name Filtering ===\n"

# 1a. Read tool should be allowed
result=$(run_validate '{"tool_name":"Read","tool_input":{"file_path":"/some/file"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Read tool exits 0 (pass-through)" "0" "$exit_code"

# 1b. Bash tool should be allowed
result=$(run_validate '{"tool_name":"Bash","tool_input":{"command":"ls"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Bash tool exits 0 (pass-through)" "0" "$exit_code"

# 1c. Grep tool should be allowed
result=$(run_validate '{"tool_name":"Grep","tool_input":{"pattern":"foo"},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Grep tool exits 0 (pass-through)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 2. Subagent Detection — team lead is exempt
# ═══════════════════════════════════════════════════════════════
printf "\n=== Subagent Detection ===\n"

# 2a. No transcript_path — team lead, should pass through
result=$(run_validate '{"tool_name":"Write","tool_input":{"file_path":"/some/file"},"cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Missing transcript_path (team lead) exits 0" "0" "$exit_code"

# 2b. Transcript path without /subagents/ — team lead
result=$(run_validate '{"tool_name":"Write","tool_input":{"file_path":"/some/file"},"transcript_path":"/main/transcript","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Non-subagent transcript_path exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 3. No Active State File — should pass through
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Active State File ===\n"

NOSTATE_CWD="${TMPDIR_ROOT}/nostate-project"
mkdir -p "${NOSTATE_CWD}/tmp"

# 3a. No state file exists at all
json=$(build_hook_input "Write" "${NOSTATE_CWD}/src/app.ts" "$NOSTATE_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "No state file exits 0 (pass-through)" "0" "$exit_code"

# 3b. State file exists but not active
# PATT-001: `status:completed` alone is sufficient because the validator
# short-circuits on non-"active" status before reading session fields.
# Session-isolation triple is omitted intentionally to assert that a
# minimal inactive record is still handled correctly (schema-permissive).
mkdir -p "${TMPDIR_ROOT}/inactive-project/tmp"
printf '{"status":"completed"}\n' > "${TMPDIR_ROOT}/inactive-project/tmp/.rune-work-done123.json"
json=$(build_hook_input "Write" "${TMPDIR_ROOT}/inactive-project/src/app.ts" "${TMPDIR_ROOT}/inactive-project")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Inactive state file exits 0 (pass-through)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 4. No Inscription File — fail open
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Inscription File ===\n"

NOINSC_CWD=$(setup_strive_project "noinsc" "ts001")
# Remove the inscription.json (setup_strive_project doesn't create one without args)
json=$(build_hook_input "Write" "${NOINSC_CWD}/src/app.ts" "$NOINSC_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "No inscription.json exits 0 (fail-open)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 5. No task_ownership Key — fail open
# ═══════════════════════════════════════════════════════════════
printf "\n=== No task_ownership Key ===\n"

NOOWN_CWD=$(setup_strive_project "noown" "ts002" '{"tasks": []}')
json=$(build_hook_input "Write" "${NOOWN_CWD}/src/app.ts" "$NOOWN_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "No task_ownership key exits 0 (fail-open)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 6. Allowed Files — exact match allows
# ═══════════════════════════════════════════════════════════════
printf "\n=== Allowed Files ===\n"

ALLOW_CWD=$(setup_strive_project "allow" "ts003" '{
  "task_ownership": {
    "task-1": {"files": ["src/app.ts", "src/utils.ts"], "dirs": []},
    "task-2": {"files": ["tests/app.test.ts"], "dirs": []}
  }
}')

# 6a. File in task-1's file list
json=$(build_hook_input "Write" "${ALLOW_CWD}/src/app.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Allowed file (src/app.ts) exits 0" "0" "$exit_code"
assert_not_contains "Allowed file has no deny" "deny" "$output"

# 6b. File in task-2's file list
json=$(build_hook_input "Edit" "${ALLOW_CWD}/tests/app.test.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Allowed file (tests/app.test.ts) exits 0" "0" "$exit_code"

# 6c. Second file in task-1's file list
json=$(build_hook_input "Write" "${ALLOW_CWD}/src/utils.ts" "$ALLOW_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Allowed file (src/utils.ts) exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 7. Allowed Directories — prefix match allows
# ═══════════════════════════════════════════════════════════════
printf "\n=== Allowed Directories ===\n"

DIRS_CWD=$(setup_strive_project "dirs" "ts004" '{
  "task_ownership": {
    "task-1": {"files": [], "dirs": ["src/components", "lib/"]}
  }
}')

# 7a. File under allowed directory
json=$(build_hook_input "Write" "${DIRS_CWD}/src/components/Button.tsx" "$DIRS_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "File under allowed dir exits 0" "0" "$exit_code"

# 7b. File under allowed directory (with trailing slash in config)
json=$(build_hook_input "Write" "${DIRS_CWD}/lib/helpers.ts" "$DIRS_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "File under allowed dir with trailing slash exits 0" "0" "$exit_code"

# 7c. Deeply nested file under allowed dir
json=$(build_hook_input "Write" "${DIRS_CWD}/src/components/forms/Input.tsx" "$DIRS_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Deeply nested file under allowed dir exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 8. Denied Files — outside all scopes
# ═══════════════════════════════════════════════════════════════
printf "\n=== Denied Files ===\n"

DENY_CWD=$(setup_strive_project "deny" "ts005" '{
  "task_ownership": {
    "task-1": {"files": ["src/app.ts"], "dirs": ["src/components"]}
  }
}')

# 8a. File not in any task's scope
json=$(build_hook_input "Write" "${DENY_CWD}/config/settings.json" "$DENY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Denied file exits 0 (deny via JSON)" "0" "$exit_code"
assert_contains "Deny output contains SEC-STRIVE-001" "SEC-STRIVE-001" "$output"
assert_contains "Deny output contains permissionDecision deny" "deny" "$output"

# 8b. File in a sibling directory (not under allowed dir)
json=$(build_hook_input "Edit" "${DENY_CWD}/src/services/api.ts" "$DENY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "Sibling dir deny contains SEC-STRIVE-001" "SEC-STRIVE-001" "$output"

# 8c. NotebookEdit tool also denied
json=$(build_hook_input "NotebookEdit" "${DENY_CWD}/notebooks/analysis.ipynb" "$DENY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_contains "NotebookEdit deny contains SEC-STRIVE-001" "SEC-STRIVE-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 9. Work Output Directory — always allowed
# ═══════════════════════════════════════════════════════════════
printf "\n=== Work Output Directory ===\n"

OUT_CWD=$(setup_strive_project "output" "ts006" '{
  "task_ownership": {
    "task-1": {"files": ["src/app.ts"], "dirs": []}
  }
}')

# 9a. Writing to tmp/work/{identifier}/ is always allowed
json=$(build_hook_input "Write" "${OUT_CWD}/tmp/work/ts006/report.md" "$OUT_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Work output dir exits 0" "0" "$exit_code"
assert_not_contains "Work output dir has no deny" "deny" "$output"

# ═══════════════════════════════════════════════════════════════
# 10. Signal Directory — always allowed
# ═══════════════════════════════════════════════════════════════
printf "\n=== Signal Directory ===\n"

SIG_CWD=$(setup_strive_project "signal" "ts007" '{
  "task_ownership": {
    "task-1": {"files": ["src/app.ts"], "dirs": []}
  }
}')

# 10a. Writing to tmp/.rune-signals/{team}/ is always allowed
json=$(build_hook_input "Write" "${SIG_CWD}/tmp/.rune-signals/rune-work-ts007/status.json" "$SIG_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "Signal dir exits 0" "0" "$exit_code"
assert_not_contains "Signal dir has no deny" "deny" "$output"

# ═══════════════════════════════════════════════════════════════
# 11. Empty File/Dir Lists — fail open
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty File/Dir Lists ===\n"

EMPTY_CWD=$(setup_strive_project "empty" "ts008" '{
  "task_ownership": {
    "task-1": {"files": [], "dirs": []}
  }
}')

# 11a. Empty task_ownership files and dirs — should allow anything (fail-open)
json=$(build_hook_input "Write" "${EMPTY_CWD}/anything.ts" "$EMPTY_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Empty file/dir lists exits 0 (fail-open)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 12. Session Ownership — different session should skip
# ═══════════════════════════════════════════════════════════════
printf "\n=== Session Ownership ===\n"

OTHERSESS_CWD="${TMPDIR_ROOT}/othersess-project"
mkdir -p "${OTHERSESS_CWD}/tmp"
mkdir -p "${OTHERSESS_CWD}/tmp/.rune-signals/rune-work-ts009"

# Create state file owned by a different (alive) PID — use PID 1 (init, always alive)
printf '{"status":"active","config_dir":"%s","owner_pid":1,"session_id":"other"}\n' \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" > "${OTHERSESS_CWD}/tmp/.rune-work-ts009.json"

json=$(build_hook_input "Write" "${OTHERSESS_CWD}/src/app.ts" "$OTHERSESS_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
assert_eq "Different session owner exits 0 (skip)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 13. Files with ./ Prefix — normalized correctly
# ═══════════════════════════════════════════════════════════════
printf "\n=== Path Normalization ===\n"

NORM_CWD=$(setup_strive_project "norm" "ts010" '{
  "task_ownership": {
    "task-1": {"files": ["./src/app.ts"], "dirs": []}
  }
}')

# 13a. Allowed file specified with ./ prefix in inscription
json=$(build_hook_input "Write" "${NORM_CWD}/src/app.ts" "$NORM_CWD")
result=$(run_validate "$json")
exit_code="${result%%	*}"
output="${result#*	}"
assert_eq "File with ./ prefix in inscription exits 0" "0" "$exit_code"
assert_not_contains "Normalized path match has no deny" "deny" "$output"

# ═══════════════════════════════════════════════════════════════
# 14. Deny JSON Structure Validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Deny JSON Structure ===\n"

STRUCT_CWD=$(setup_strive_project "struct" "ts011" '{
  "task_ownership": {
    "task-1": {"files": ["src/only-this.ts"], "dirs": []}
  }
}')

# 14a. Validate deny JSON has correct structure
json=$(build_hook_input "Write" "${STRUCT_CWD}/forbidden.ts" "$STRUCT_CWD")
result=$(run_validate "$json")
output="${result#*	}"

# Parse the JSON output to validate structure
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse"
assert h["permissionDecision"] == "deny"
assert "permissionDecisionReason" in h
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
# 15. Empty Input / Malformed JSON — fail open
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty / Malformed Input ===\n"

# 15a. Empty input
result=$(run_validate "")
exit_code="${result%%	*}"
assert_eq "Empty input exits 0 (fail-open)" "0" "$exit_code"

# 15b. Invalid JSON
result=$(run_validate "{invalid json{{")
exit_code="${result%%	*}"
assert_eq "Invalid JSON exits 0 (fail-open)" "0" "$exit_code"

# 15c. Missing file_path in tool_input
result=$(run_validate '{"tool_name":"Write","tool_input":{},"transcript_path":"/subagents/x/t","cwd":"/tmp"}')
exit_code="${result%%	*}"
assert_eq "Missing file_path exits 0 (fail-open)" "0" "$exit_code"

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
