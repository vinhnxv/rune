#!/usr/bin/env bash
# test-enforce-polling.sh — Tests for scripts/enforce-polling.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-polling.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-polling.sh"

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
  # Everything except the last line (which is the exit code)
  printf '%s' "$result" | sed '$d'
}

get_exit_code() {
  local result="$1"
  printf '%s' "$result" | tail -1
}

# ═══════════════════════════════════════════════════════════════
# 1. Non-matching tool names (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-matching Tool Names ===\n"

# 1a. Non-Bash tool should pass through
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "tool_input": {"command": "sleep 30 && echo done"}}')
assert_eq "Non-Bash tool exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Non-Bash tool produces no output" "" "$(get_output "$result")"

# 1b. Empty tool name
result=$(run_hook '{"tool_name": "", "cwd": "/tmp", "tool_input": {"command": "sleep 30 && echo done"}}')
assert_eq "Empty tool_name exits 0" "0" "$(get_exit_code "$result")"

# 1c. Missing tool_name field
result=$(run_hook '{"cwd": "/tmp", "tool_input": {"command": "sleep 30 && echo done"}}')
assert_eq "Missing tool_name exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 2. Commands without sleep (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Sleep in Command ===\n"

# 2a. Normal command with no sleep
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "echo hello world"}}')
assert_eq "No-sleep command exits 0" "0" "$(get_exit_code "$result")"
assert_eq "No-sleep command no output" "" "$(get_output "$result")"

# 2b. Command with ls
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "ls -la"}}')
assert_eq "ls command exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 3. Small sleep values (below threshold)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Small Sleep Values (Below Threshold) ===\n"

# 3a. sleep 5 && echo (below 10s threshold) — no active workflow needed
# Create a fake CWD with no workflow state
NOCWD="$TMPWORK/no-workflow"
mkdir -p "$NOCWD"
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$NOCWD\", \"tool_input\": {\"command\": \"sleep 5 && echo poll\"}}")
assert_eq "sleep 5 exits 0 (below threshold)" "0" "$(get_exit_code "$result")"
assert_eq "sleep 5 no deny output" "" "$(get_output "$result")"

# 3b. sleep 1 && echo (startup probe)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$NOCWD\", \"tool_input\": {\"command\": \"sleep 1 && echo check\"}}")
assert_eq "sleep 1 exits 0 (startup probe)" "0" "$(get_exit_code "$result")"

# 3c. sleep 9 && echo (just below threshold)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$NOCWD\", \"tool_input\": {\"command\": \"sleep 9 && echo check\"}}")
assert_eq "sleep 9 exits 0 (just below threshold)" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 4. Sleep+echo pattern WITHOUT active workflow
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sleep+Echo Without Active Workflow ===\n"

# 4a. sleep 30 && echo with no workflow state files
EMPTYCWD="$TMPWORK/empty-project"
mkdir -p "$EMPTYCWD"
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$EMPTYCWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll check\"}}")
assert_eq "sleep 30+echo without workflow exits 0" "0" "$(get_exit_code "$result")"
assert_eq "sleep 30+echo without workflow no deny" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 5. Sleep+echo pattern WITH active workflow (BLOCK expected)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sleep+Echo With Active Workflow (Arc) ===\n"

# Create a fake CWD with active arc checkpoint
# Use a dead PID (99999999) so ownership filter treats it as "our" orphaned state
# Omit config_dir so the config_dir filter is skipped (both empty = no mismatch)
ARCCWD="$TMPWORK/arc-project"
mkdir -p "$ARCCWD/.claude/arc/test-phase"
cat > "$ARCCWD/.claude/arc/test-phase/checkpoint.json" <<EOF
{"phase_status": "in_progress", "owner_pid": "99999999"}
EOF

# 5a. sleep 30 && echo with active arc workflow (owner_pid is dead PID = owned by us)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$ARCCWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll check\"}}")
assert_eq "sleep+echo with arc exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_contains "sleep+echo with arc produces deny JSON" "POLL-001" "$output"
assert_contains "deny JSON has permissionDecision deny" '"permissionDecision": "deny"' "$output"
assert_contains "deny JSON has hookEventName" '"hookEventName": "PreToolUse"' "$output"

# 5b. sleep 60 && echo with active arc workflow
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$ARCCWD\", \"tool_input\": {\"command\": \"sleep 60 && echo checking status\"}}")
output=$(get_output "$result")
assert_contains "sleep 60+echo blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 6. Sleep+echo with state file workflows
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sleep+Echo With State File Workflows ===\n"

# Create CWD with active review state file (dead PID, no config_dir = owned by us)
REVIEWCWD="$TMPWORK/review-project"
mkdir -p "$REVIEWCWD/tmp"
cat > "$REVIEWCWD/tmp/.rune-review-abc123.json" <<EOF
{"status": "active", "owner_pid": "99999999"}
EOF

# 6a. sleep 30 && echo with active review
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "sleep+echo with review blocked" "POLL-001" "$output"

# 6b. Also test with semicolon separator: sleep 30 ; echo
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 ; echo poll\"}}")
output=$(get_output "$result")
assert_contains "sleep+echo with semicolon blocked" "POLL-001" "$output"

# 6c. sleep 30 && printf variant
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 && printf poll\"}}")
output=$(get_output "$result")
assert_contains "sleep+printf blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 7. Commands that mention sleep but are not the anti-pattern
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Anti-Pattern Sleep Commands ===\n"

# 7a. Simple sleep without echo
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30\"}}")
assert_eq "Bare sleep exits 0 (no echo)" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "Bare sleep not blocked" "POLL-001" "$output"

# 7b. sleep || echo (error fallback, not anti-pattern)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 || echo failed\"}}")
assert_eq "sleep || echo exits 0 (error fallback)" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "sleep||echo not blocked" "POLL-001" "$output"

# 7c. echo command that mentions sleep in string (no chain operator)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"echo sleep is important\"}}")
assert_eq "echo mentioning sleep exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 8. Empty/missing command field
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty/Missing Command ===\n"

# 8a. Empty command
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": ""}}')
assert_eq "Empty command exits 0" "0" "$(get_exit_code "$result")"

# 8b. Missing command field
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {}}')
assert_eq "Missing command exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 9. Empty/missing CWD
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty/Missing CWD ===\n"

# 9a. Empty cwd
result=$(run_hook '{"tool_name": "Bash", "cwd": "", "tool_input": {"command": "sleep 30 && echo poll"}}')
assert_eq "Empty cwd exits 0" "0" "$(get_exit_code "$result")"

# 9b. Missing cwd
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "sleep 30 && echo poll"}}')
assert_eq "Missing cwd exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 10. VEIL-009: Max sleep extraction (bypass prevention)
# ═══════════════════════════════════════════════════════════════
printf "\n=== VEIL-009: Max Sleep Extraction ===\n"

# 10a. Bypass attempt: small sleep first, big sleep second
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 1 && echo setup; sleep 60 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "Max sleep extracted — blocks on sleep 60" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 11. Word boundary — nosleep should not match
# ═══════════════════════════════════════════════════════════════
printf "\n=== Word Boundary (SEC-002) ===\n"

# 11a. nosleep variable name should not match
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"nosleep=30 && echo done\"}}")
assert_eq "nosleep variable exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "nosleep not blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 12. Multiline command normalization
# ═══════════════════════════════════════════════════════════════
printf "\n=== Multiline Commands ===\n"

# 12a. Multiline sleep+echo (newline between)
MULTI_CMD=$(printf 'sleep 30\necho poll check')
JSON=$(jq -n --arg cmd "$MULTI_CMD" --arg cwd "$REVIEWCWD" \
  '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $cmd}}')
result=$(run_hook "$JSON")
# Multiline with newline (not && or ;) may or may not match the pattern.
# After normalization, "sleep 30 echo poll check" does NOT have && or ; between them.
# So this should NOT be blocked by the current regex.
assert_eq "Multiline without chain op exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 13. v4 nested checkpoint schema
# ═══════════════════════════════════════════════════════════════
printf "\n=== V4 Nested Checkpoint Schema ===\n"

# Create CWD with v4 nested schema
V4CWD="$TMPWORK/v4-project"
mkdir -p "$V4CWD/.claude/arc/test-v4"
cat > "$V4CWD/.claude/arc/test-v4/checkpoint.json" <<EOF
{"phases": {"forge": {"status": "in_progress"}}, "owner_pid": "99999999"}
EOF

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$V4CWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "v4 nested schema detected" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 14. Empty JSON input
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge Cases ===\n"

# 14a. Completely empty stdin
result=$(printf '' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Empty stdin exits 0" "0" "$result"

# 14b. Invalid JSON
result=$(printf 'not json at all' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Invalid JSON exits 0" "0" "$result"

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
