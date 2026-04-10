#!/usr/bin/env bash
# test-enforce-bash-timeout.sh — Tests for scripts/enforce-bash-timeout.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-bash-timeout.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-bash-timeout.sh"

# ── Temp workspace ──
TMPWORK=$(mktemp -d "${TMPDIR:-/tmp}/test-bash-timeout-XXXXXX")
trap 'rm -rf "$TMPWORK"' EXIT

# ── Test framework ──
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
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
  local test_name="$1" needle="$2" haystack="$3"
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
  local test_name="$1" needle="$2" haystack="$3"
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

# Helper: run the script with given JSON on stdin, capture stdout and exit code
run_hook() {
  local json="$1"
  local output
  local rc=0
  output=$(printf '%s' "$json" | bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
  printf '%s\n%d' "$output" "$rc"
}

get_output() {
  local result="$1"
  printf '%s' "$result" | sed '$d'
}

get_exit_code() {
  local result="$1"
  printf '%s' "$result" | tail -1
}

# Helper: create a CWD with an active workflow state file
make_active_cwd() {
  local cwd="$1"
  mkdir -p "${cwd}/tmp"
  cat > "${cwd}/tmp/.rune-work-test.json" <<EOF
{"status": "in_progress", "owner_pid": "99999999"}
EOF
}

# ═══════════════════════════════════════════════════════════════
echo "=== Fast-path exits ==="

# 1. Non-Bash tool should pass through
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "tool_input": {"command": "npm test"}}')
assert_eq "Non-Bash tool exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Non-Bash tool no output" "" "$(get_output "$result")"

# 2. Empty command
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": ""}}')
assert_eq "Empty command exits 0" "0" "$(get_exit_code "$result")"

# 3. Missing tool_input
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp"}')
assert_eq "Missing tool_input exits 0" "0" "$(get_exit_code "$result")"

# 4. tool_input.timeout already set
TCWD="$TMPWORK/timeout-set"
make_active_cwd "$TCWD"
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$TCWD\", \"tool_input\": {\"command\": \"npm test\", \"timeout\": 60000}}")
assert_eq "tool_input.timeout set → skip" "0" "$(get_exit_code "$result")"
assert_eq "tool_input.timeout set → no wrapping" "" "$(get_output "$result")"

# 5. Command already has timeout prefix
TCWD2="$TMPWORK/already-timeout"
make_active_cwd "$TCWD2"
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$TCWD2\", \"tool_input\": {\"command\": \"timeout 300 npm test\"}}")
assert_eq "Already has timeout prefix → skip" "0" "$(get_exit_code "$result")"
assert_eq "Already has timeout prefix → no output" "" "$(get_output "$result")"

# 6. Command has gtimeout prefix
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$TCWD2\", \"tool_input\": {\"command\": \"gtimeout 300 cargo test\"}}")
assert_eq "Already has gtimeout prefix → skip" "0" "$(get_exit_code "$result")"

# 7. codex exec bypass
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$TCWD2\", \"tool_input\": {\"command\": \"codex exec --model o3 'review this'\"}}")
assert_eq "codex exec → skip" "0" "$(get_exit_code "$result")"
assert_eq "codex exec → no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "=== No active workflow ==="

EMPTYCWD="$TMPWORK/no-workflow"
mkdir -p "$EMPTYCWD"
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$EMPTYCWD\", \"tool_input\": {\"command\": \"npm test\"}}")
assert_eq "No workflow → skip" "0" "$(get_exit_code "$result")"
assert_eq "No workflow → no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "=== Pattern matching with active workflow ==="

WCWD="$TMPWORK/active-wf"
make_active_cwd "$WCWD"

# Test runners
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"npm test\"}}")
output=$(get_output "$result")
assert_eq "npm test → exit 0" "0" "$(get_exit_code "$result")"
assert_contains "npm test → wrapped" "BASH-TIMEOUT-001" "$output"
assert_contains "npm test → has timeout binary" "timeout" "$output"

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"pytest tests/ -v\"}}")
output=$(get_output "$result")
assert_contains "pytest → wrapped" "BASH-TIMEOUT-001" "$output"

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"cargo test --release\"}}")
output=$(get_output "$result")
assert_contains "cargo test → wrapped" "BASH-TIMEOUT-001" "$output"

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"go test ./...\"}}")
output=$(get_output "$result")
assert_contains "go test → wrapped" "BASH-TIMEOUT-001" "$output"

# Build tools
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"make test\"}}")
output=$(get_output "$result")
assert_contains "make test → wrapped" "BASH-TIMEOUT-001" "$output"

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"cargo build --release\"}}")
output=$(get_output "$result")
assert_contains "cargo build → wrapped" "BASH-TIMEOUT-001" "$output"

# Package managers
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"npm install\"}}")
output=$(get_output "$result")
assert_contains "npm install → wrapped" "BASH-TIMEOUT-001" "$output"

# Container
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"docker compose up -d\"}}")
output=$(get_output "$result")
assert_contains "docker compose → wrapped" "BASH-TIMEOUT-001" "$output"

# JVM
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"./gradlew build\"}}")
output=$(get_output "$result")
assert_contains "gradlew → wrapped" "BASH-TIMEOUT-001" "$output"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "=== Non-matching patterns (should pass through) ==="

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"echo hello world\"}}")
assert_eq "echo → no wrap" "0" "$(get_exit_code "$result")"
assert_eq "echo → no output" "" "$(get_output "$result")"

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"ls -la\"}}")
assert_eq "ls → no wrap" "0" "$(get_exit_code "$result")"
assert_eq "ls → no output" "" "$(get_output "$result")"

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"git status\"}}")
assert_eq "git status → no wrap" "0" "$(get_exit_code "$result")"
assert_eq "git status → no output" "" "$(get_output "$result")"

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"cat README.md\"}}")
assert_eq "cat → no wrap" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "=== setopt nullglob prefix handling ==="

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"setopt nullglob; npm test\"}}")
output=$(get_output "$result")
assert_contains "nullglob+npm test → wrapped" "BASH-TIMEOUT-001" "$output"
# Verify the nullglob prefix is preserved in the wrapped command
wrapped_cmd=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)
assert_contains "nullglob preserved in output" "setopt nullglob" "$wrapped_cmd"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "=== JSON output format validation ==="

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"npm test\"}}")
output=$(get_output "$result")

# Validate it's valid JSON
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | jq empty 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: output is valid JSON\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: output is not valid JSON\n"
fi

# Check required fields
hook_event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null || true)
assert_eq "hookEventName is PreToolUse" "PreToolUse" "$hook_event"

decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
assert_eq "permissionDecision is allow" "allow" "$decision"

updated_cmd=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)
assert_contains "updatedInput has timeout binary" "timeout" "$updated_cmd"
assert_contains "updatedInput has npm test" "npm test" "$updated_cmd"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "=== Piped/chained command wrapping ==="

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$WCWD\", \"tool_input\": {\"command\": \"npm test 2>&1 | tail -20\"}}")
output=$(get_output "$result")
assert_contains "piped npm test → wrapped" "BASH-TIMEOUT-001" "$output"
wrapped_cmd=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)
assert_contains "piped command uses bash -c" "bash -c" "$wrapped_cmd"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════"
printf "Results: %d passed, %d failed, %d total\n" "$PASS_COUNT" "$FAIL_COUNT" "$TOTAL_COUNT"
echo "═══════════════════════════════════════"

[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
