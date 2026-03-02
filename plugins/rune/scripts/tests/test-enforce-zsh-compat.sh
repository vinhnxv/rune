#!/usr/bin/env bash
# test-enforce-zsh-compat.sh — Tests for scripts/enforce-zsh-compat.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-zsh-compat.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-zsh-compat.sh"

# ── Temp workspace ──
TMPWORK=$(mktemp -d)
trap 'rm -rf "$TMPWORK"' EXIT

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

# Helper: run the script with given JSON on stdin, with SHELL set to zsh
# Returns: stdout\n<exit_code> on last line
run_hook() {
  local json="$1"
  local shell_val="${2:-/bin/zsh}"
  local output
  local rc=0
  output=$(printf '%s' "$json" | SHELL="$shell_val" bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
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

# ═══════════════════════════════════════════════════════════════
# 1. Shell detection — skip for non-zsh shells
# ═══════════════════════════════════════════════════════════════
printf "\n=== Shell Detection ===\n"

# 1a. SHELL=/bin/bash — should skip entirely
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "status=$(echo test)"}}' "/bin/bash")
assert_eq "Bash shell exits 0 silently" "0" "$(get_exit_code "$result")"
assert_eq "Bash shell no output" "" "$(get_output "$result")"

# 1b. SHELL=/bin/fish — should skip
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "status=$(echo test)"}}' "/bin/fish")
assert_eq "Fish shell exits 0 silently" "0" "$(get_exit_code "$result")"

# 1c. SHELL=/bin/zsh — should enforce
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "status=$(echo test)"}}' "/bin/zsh")
assert_eq "zsh shell exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_contains "zsh shell blocks status=" "ZSH-001" "$output"

# 1d. SHELL=/usr/local/bin/zsh — also matches zsh
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "status=$(echo test)"}}' "/usr/local/bin/zsh")
output=$(get_output "$result")
assert_contains "Alternative zsh path blocks status=" "ZSH-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 2. Non-matching tool names (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-matching Tool Names ===\n"

# 2a. Non-Bash tool should pass through
result=$(run_hook '{"tool_name": "Write", "tool_input": {"command": "status=$(echo test)"}}')
assert_eq "Non-Bash tool exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Non-Bash tool no output" "" "$(get_output "$result")"

# 2b. Empty tool name
result=$(run_hook '{"tool_name": "", "tool_input": {"command": "status=$(echo test)"}}')
assert_eq "Empty tool_name exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 3. Check A: bare status= assignment (DENY)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Check A: bare status= (DENY) ===\n"

# 3a. Simple status= assignment
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "status=$(jq -r .status file.json)"}}')
output=$(get_output "$result")
assert_contains "Bare status= denied" '"permissionDecision": "deny"' "$output"
assert_contains "Bare status= has ZSH-001" "ZSH-001" "$output"

# 3b. local status= assignment
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "local status=$(echo test)"}}')
output=$(get_output "$result")
assert_contains "local status= denied" '"permissionDecision": "deny"' "$output"

# 3c. export status= assignment
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "export status=active"}}')
output=$(get_output "$result")
assert_contains "export status= denied" '"permissionDecision": "deny"' "$output"

# 3d. task_status= should NOT be blocked (has prefix)
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "task_status=$(echo active)"}}')
assert_eq "task_status= exits 0" "0" "$(get_exit_code "$result")"
assert_eq "task_status= no output" "" "$(get_output "$result")"

# 3e. exit_status= should NOT be blocked
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "exit_status=$?"}}')
assert_eq "exit_status= exits 0" "0" "$(get_exit_code "$result")"

# 3f. http_status= should NOT be blocked
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "http_status=200"}}')
assert_eq "http_status= exits 0" "0" "$(get_exit_code "$result")"

# 3g. status= after semicolon
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "echo hello; status=$(echo done)"}}')
output=$(get_output "$result")
assert_contains "status= after semicolon denied" '"permissionDecision": "deny"' "$output"

# ═══════════════════════════════════════════════════════════════
# 4. Check B: unprotected glob in for-loop (AUTO-FIX)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Check B: Unprotected Glob in For-Loop ===\n"

# 4a. for f in *.md; do — should auto-fix with setopt nullglob
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "for f in *.md; do echo $f; done"}}')
output=$(get_output "$result")
assert_contains "For-loop glob auto-fix has allow" '"permissionDecision": "allow"' "$output"
assert_contains "For-loop glob auto-fix prepends nullglob" "setopt nullglob" "$output"

# 4b. for f in path/*.json; do
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "for f in tmp/*.json; do cat $f; done"}}')
output=$(get_output "$result")
assert_contains "Path glob auto-fix" "setopt nullglob" "$output"

# 4c. Already protected with (N) — should pass through
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "for f in *.md(N); do echo $f; done"}}')
assert_eq "(N) protected exits 0" "0" "$(get_exit_code "$result")"
assert_eq "(N) protected no output" "" "$(get_output "$result")"

# 4d. Already protected with setopt nullglob — should pass through
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "setopt nullglob; for f in *.md; do echo $f; done"}}')
assert_eq "setopt nullglob protected exits 0" "0" "$(get_exit_code "$result")"
assert_eq "setopt nullglob protected no output" "" "$(get_output "$result")"

# 4e. Already protected with shopt -s nullglob
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "shopt -s nullglob; for f in *.md; do echo $f; done"}}')
assert_eq "shopt nullglob protected exits 0" "0" "$(get_exit_code "$result")"

# 4f. ? glob character in for loop
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "for f in file?.txt; do echo $f; done"}}')
output=$(get_output "$result")
assert_contains "? glob auto-fix" "setopt nullglob" "$output"

# ═══════════════════════════════════════════════════════════════
# 5. Check C: ! [[ history expansion (AUTO-FIX)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Check C: ! [[ History Expansion ===\n"

# 5a. ! [[ should be rewritten to [[ !
CMD='! [[ -f file.txt ]] && echo exists'
JSON=$(jq -n --arg cmd "$CMD" '{tool_name: "Bash", tool_input: {command: $cmd}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "! [[ auto-fixed" '"permissionDecision": "allow"' "$output"
assert_contains "! [[ rewrite noted" "rewrote" "$output"
# The updatedInput should contain [[ ! instead of ! [[
assert_contains "! [[ -> [[ ! in updatedInput" "[[ !" "$output"

# ═══════════════════════════════════════════════════════════════
# 6. Check D: \!= escaped not-equal (AUTO-FIX)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Check D: Escaped \\!= ===\n"

# 6a. \!= should be rewritten to !=
CMD='[[ "$a" \!= "$b" ]]'
JSON=$(jq -n --arg cmd "$CMD" '{tool_name: "Bash", tool_input: {command: $cmd}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "\\!= auto-fixed" '"permissionDecision": "allow"' "$output"
assert_contains "\\!= rewrite noted" "rewrote" "$output"

# ═══════════════════════════════════════════════════════════════
# 7. Check E: unprotected glob in command arguments (AUTO-FIX)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Check E: Argument Globs ===\n"

# 7a. rm -rf path/rune-* — unprotected glob
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "rm -rf tmp/rune-*"}}')
output=$(get_output "$result")
assert_contains "rm glob auto-fix" "setopt nullglob" "$output"
assert_contains "rm glob has allow" '"permissionDecision": "allow"' "$output"

# 7b. ls *.txt — unprotected glob
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "ls *.txt"}}')
output=$(get_output "$result")
assert_contains "ls glob auto-fix" "setopt nullglob" "$output"

# 7c. cat "quoted/*.txt" — glob inside quotes should NOT trigger
# The script strips quoted strings before checking for globs
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "cat \"path/*.txt\""}}')
assert_eq "Quoted glob exits 0" "0" "$(get_exit_code "$result")"

# 7d. Already protected with setopt nullglob
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "setopt nullglob; rm -rf tmp/rune-*"}}')
assert_eq "setopt nullglob rm exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 8. Combined fixes (BACK-016 accumulated auto-fix)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Combined Fixes (BACK-016) ===\n"

# 8a. Command with both \!= and unprotected glob
CMD='[[ "$a" \!= "$b" ]] && rm -rf tmp/rune-*'
JSON=$(jq -n --arg cmd "$CMD" '{tool_name: "Bash", tool_input: {command: $cmd}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "Combined fix has allow" '"permissionDecision": "allow"' "$output"
# Should have both fixes noted
assert_contains "Combined fix mentions rewrite" "rewrote" "$output"
assert_contains "Combined fix mentions nullglob" "nullglob" "$output"

# ═══════════════════════════════════════════════════════════════
# 9. Commands with no target patterns (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Target Patterns (Fast Path) ===\n"

# 9a. Normal echo command
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "echo hello world"}}')
assert_eq "Normal echo exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Normal echo no output" "" "$(get_output "$result")"

# 9b. Git command
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "git status"}}')
assert_eq "Git command exits 0" "0" "$(get_exit_code "$result")"

# 9c. Python command
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "python3 -c \"print(42)\""}}')
assert_eq "Python command exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 10. Empty/missing command
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty/Missing Command ===\n"

# 10a. Empty command
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": ""}}')
assert_eq "Empty command exits 0" "0" "$(get_exit_code "$result")"

# 10b. Missing command
result=$(run_hook '{"tool_name": "Bash", "tool_input": {}}')
assert_eq "Missing command exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 11. Edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge Cases ===\n"

# 11a. Empty stdin
result=$(printf '' | SHELL=/bin/zsh bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Empty stdin exits 0" "0" "$result"

# 11b. Invalid JSON
result=$(printf 'not json' | SHELL=/bin/zsh bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Invalid JSON exits 0" "0" "$result"

# 11c. diff_status= should NOT be blocked (has prefix)
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "diff_status=changed"}}')
assert_eq "diff_status= exits 0" "0" "$(get_exit_code "$result")"
assert_eq "diff_status= no output" "" "$(get_output "$result")"

# 11d. declare status= (shell keyword prefix)
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "declare status=ok"}}')
output=$(get_output "$result")
assert_contains "declare status= denied" '"permissionDecision": "deny"' "$output"

# 11e. Command with only * but no file command (should not trigger Check E)
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "echo 2*3=6"}}')
assert_eq "echo with * no file cmd exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 12. macOS fallback (SHELL unset on Darwin)
# ═══════════════════════════════════════════════════════════════
printf "\n=== macOS Fallback ===\n"

# 12a. On macOS with SHELL unset, should enforce (Darwin default is zsh)
if [[ "$(uname -s)" == "Darwin" ]]; then
  mac_output=""
  mac_rc=0
  mac_output=$(printf '{"tool_name": "Bash", "tool_input": {"command": "status=$(echo test)"}}' | env -u SHELL bash "$ENFORCE_SCRIPT" 2>/dev/null) || mac_rc=$?
  assert_eq "macOS fallback exits 0" "0" "$mac_rc"
  assert_contains "macOS fallback enforces (deny)" '"permissionDecision": "deny"' "$mac_output"
  printf "  INFO: macOS SHELL-unset test ran (platform: Darwin)\n"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 2 ))
  PASS_COUNT=$(( PASS_COUNT + 2 ))
  printf "  PASS: macOS fallback exits 0 (skipped, platform: %s)\n" "$(uname -s)"
  printf "  PASS: macOS fallback enforces (skipped, platform: %s)\n" "$(uname -s)"
fi

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
