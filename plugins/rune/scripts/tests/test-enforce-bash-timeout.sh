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

