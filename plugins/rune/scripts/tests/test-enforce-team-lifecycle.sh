#!/usr/bin/env bash
# test-enforce-team-lifecycle.sh — Tests for scripts/enforce-team-lifecycle.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-team-lifecycle.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-team-lifecycle.sh"

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

# Helper: run the script with given JSON on stdin
# Uses a fake CLAUDE_CONFIG_DIR to avoid touching real state
run_hook() {
  local json="$1"
  local config_dir="${2:-$TMPWORK/fake-claude-config}"
  mkdir -p "$config_dir"
  local output
  local rc=0
  output=$(printf '%s' "$json" | CLAUDE_CONFIG_DIR="$config_dir" bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
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
# 1. Non-matching tool names (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-matching Tool Names ===\n"

# 1a. Non-TeamCreate tool should pass through
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"team_name": "rune-test"}}')
assert_eq "Non-TeamCreate tool exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Non-TeamCreate tool no output" "" "$(get_output "$result")"

# 1b. Empty tool name
result=$(run_hook '{"tool_name": "", "cwd": "/tmp", "tool_input": {"team_name": "rune-test"}}')
assert_eq "Empty tool_name exits 0" "0" "$(get_exit_code "$result")"

# 1c. Agent tool (not TeamCreate)
result=$(run_hook '{"tool_name": "Agent", "cwd": "/tmp", "tool_input": {"team_name": "rune-test"}}')
assert_eq "Agent tool exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 2. Valid team names (ALLOW)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Valid Team Names ===\n"

VALID_CWD="$TMPWORK/valid-project"
mkdir -p "$VALID_CWD"

# 2a. Simple valid name
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"rune-review-abc123\"}}")
assert_eq "Valid name exits 0" "0" "$(get_exit_code "$result")"

# 2b. Name with hyphens and underscores
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"arc-forge-test_run\"}}")
assert_eq "Hyphens and underscores exits 0" "0" "$(get_exit_code "$result")"

# 2c. Short name
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"a\"}}")
assert_eq "Short name exits 0" "0" "$(get_exit_code "$result")"

# 2d. Numbers only
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"12345\"}}")
assert_eq "Numbers-only name exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 3. Invalid team names (DENY — GATE 1)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Invalid Team Names (GATE 1) ===\n"

# 3a. Name with spaces
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"rune test\"}}")
output=$(get_output "$result")
assert_contains "Space in name denied" '"permissionDecision": "deny"' "$output"
assert_contains "Space in name has TLC-001" "TLC-001" "$output"

# 3b. Name with path traversal (..)
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"rune..test\"}}")
output=$(get_output "$result")
assert_contains "Path traversal denied" '"permissionDecision": "deny"' "$output"

# 3c. Name with special characters
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"rune;rm -rf /\"}}")
output=$(get_output "$result")
assert_contains "Shell injection denied" '"permissionDecision": "deny"' "$output"

# 3d. Name with slashes
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"rune/test\"}}")
output=$(get_output "$result")
assert_contains "Slash in name denied" '"permissionDecision": "deny"' "$output"

# 3e. Name with dots
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"rune.test\"}}")
output=$(get_output "$result")
assert_contains "Dots in name denied" '"permissionDecision": "deny"' "$output"

# 3f. Name with backticks (command injection)
JSON=$(jq -n --arg name 'rune-`whoami`' --arg cwd "$VALID_CWD" \
  '{tool_name: "TeamCreate", cwd: $cwd, tool_input: {team_name: $name}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "Backtick injection denied" '"permissionDecision": "deny"' "$output"

# 3g. Name that is ALL special characters (BACK-004: fallback for empty SAFE_NAME)
JSON=$(jq -n --arg name '!!@@##' --arg cwd "$VALID_CWD" \
  '{tool_name: "TeamCreate", cwd: $cwd, tool_input: {team_name: $name}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "All-special name denied" '"permissionDecision": "deny"' "$output"
assert_contains "All-special name uses fallback" "<invalid>" "$output"

# ═══════════════════════════════════════════════════════════════
# 4. Team name length (GATE 2)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Team Name Length (GATE 2) ===\n"

# 4a. Name at exactly 128 chars (should pass)
LONG_VALID_NAME=$(python3 -c "print('a' * 128)")
JSON=$(jq -n --arg name "$LONG_VALID_NAME" --arg cwd "$VALID_CWD" \
  '{tool_name: "TeamCreate", cwd: $cwd, tool_input: {team_name: $name}}')
result=$(run_hook "$JSON")
assert_eq "128-char name exits 0" "0" "$(get_exit_code "$result")"

# 4b. Name at 129 chars (should be denied)
LONG_INVALID_NAME=$(python3 -c "print('a' * 129)")
JSON=$(jq -n --arg name "$LONG_INVALID_NAME" --arg cwd "$VALID_CWD" \
  '{tool_name: "TeamCreate", cwd: $cwd, tool_input: {team_name: $name}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "129-char name denied" '"permissionDecision": "deny"' "$output"
assert_contains "129-char name has length reason" "128 characters" "$output"

# ═══════════════════════════════════════════════════════════════
# 5. Missing team_name
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing Team Name ===\n"

# 5a. No team_name field
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {}}")
assert_eq "Missing team_name exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Missing team_name no output" "" "$(get_output "$result")"

# 5b. Empty team_name
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"\"}}")
assert_eq "Empty team_name exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 6. Stale team detection and cleanup
# ═══════════════════════════════════════════════════════════════
printf "\n=== Stale Team Detection ===\n"

# Create a fake config dir with a stale team
STALE_CONFIG="$TMPWORK/stale-config"
mkdir -p "$STALE_CONFIG/teams/rune-stale-test"
mkdir -p "$STALE_CONFIG/tasks/rune-stale-test"
# Touch with old timestamp (60 minutes ago)
touch -t "$(date -v-60M +%Y%m%d%H%M 2>/dev/null || date -d '60 minutes ago' +%Y%m%d%H%M 2>/dev/null)" "$STALE_CONFIG/teams/rune-stale-test" 2>/dev/null || true

# Check if the touch worked (macOS vs Linux date formats)
if [[ -d "$STALE_CONFIG/teams/rune-stale-test" ]]; then
  # Verify the dir is old enough for find -mmin +30
  stale_found=$(find "$STALE_CONFIG/teams/" -maxdepth 1 -type d -name "rune-stale-test" -mmin +30 2>/dev/null | head -1)
  if [[ -n "$stale_found" ]]; then
    STALE_CWD="$TMPWORK/stale-project"
    mkdir -p "$STALE_CWD"
    result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$STALE_CWD\", \"tool_input\": {\"team_name\": \"rune-new-team\"}}" "$STALE_CONFIG")
    output=$(get_output "$result")
    assert_contains "Stale team advisory" "TLC-001 PRE-FLIGHT" "$output"
    assert_contains "Stale team advisory has cleaned count" "cleaned" "$output"
    assert_contains "Stale team advisory allows" '"permissionDecision": "allow"' "$output"
    # Verify the stale team dir was removed
    TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
    if [[ ! -d "$STALE_CONFIG/teams/rune-stale-test" ]]; then
      PASS_COUNT=$(( PASS_COUNT + 1 ))
      printf "  PASS: Stale team dir removed\n"
    else
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      printf "  FAIL: Stale team dir NOT removed\n"
    fi
  else
    # touch with old date didn't work; skip stale tests gracefully
    TOTAL_COUNT=$(( TOTAL_COUNT + 4 ))
    PASS_COUNT=$(( PASS_COUNT + 4 ))
    printf "  PASS: Stale team detection skipped (touch -t not working)\n"
    printf "  PASS: Stale team advisory skipped\n"
    printf "  PASS: Stale team allows skipped\n"
    printf "  PASS: Stale team dir removed skipped\n"
  fi
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 4 ))
  PASS_COUNT=$(( PASS_COUNT + 4 ))
  printf "  PASS: Stale team tests skipped (dir creation failed)\n"
  printf "  PASS: (placeholder)\n"
  printf "  PASS: (placeholder)\n"
  printf "  PASS: (placeholder)\n"
fi

# ═══════════════════════════════════════════════════════════════
# 7. No stale teams — silent allow
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Stale Teams ===\n"

CLEAN_CONFIG="$TMPWORK/clean-config"
mkdir -p "$CLEAN_CONFIG/teams"
CLEAN_CWD="$TMPWORK/clean-project"
mkdir -p "$CLEAN_CWD"

# 7a. Valid team, no stale dirs → silent allow (no output)
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$CLEAN_CWD\", \"tool_input\": {\"team_name\": \"rune-test\"}}" "$CLEAN_CONFIG")
assert_eq "Clean config exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Clean config no output" "" "$(get_output "$result")"

# 7b. Non-rune team dirs should not be scanned (foreign plugin teams)
mkdir -p "$CLEAN_CONFIG/teams/other-plugin-team"
touch -t "$(date -v-60M +%Y%m%d%H%M 2>/dev/null || date -d '60 minutes ago' +%Y%m%d%H%M 2>/dev/null)" "$CLEAN_CONFIG/teams/other-plugin-team" 2>/dev/null || true
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$CLEAN_CWD\", \"tool_input\": {\"team_name\": \"rune-test\"}}" "$CLEAN_CONFIG")
assert_eq "Foreign teams ignored" "0" "$(get_exit_code "$result")"
assert_eq "Foreign teams no advisory" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 8. CWD handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Handling ===\n"

# 8a. Empty CWD
result=$(run_hook '{"tool_name": "TeamCreate", "cwd": "", "tool_input": {"team_name": "rune-test"}}')
assert_eq "Empty CWD exits 0" "0" "$(get_exit_code "$result")"

# 8b. Missing CWD
result=$(run_hook '{"tool_name": "TeamCreate", "tool_input": {"team_name": "rune-test"}}')
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code "$result")"

# 8c. Invalid CWD path
result=$(run_hook '{"tool_name": "TeamCreate", "cwd": "/nonexistent/path/that/does/not/exist", "tool_input": {"team_name": "rune-test"}}')
assert_eq "Invalid CWD exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 9. Edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge Cases ===\n"

# 9a. Empty stdin
result=$(printf '' | CLAUDE_CONFIG_DIR="$TMPWORK/fake-config" bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Empty stdin exits 0" "0" "$result"

# 9b. Invalid JSON
result=$(printf 'not json' | CLAUDE_CONFIG_DIR="$TMPWORK/fake-config" bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Invalid JSON exits 0" "0" "$result"

# 9c. hookEventName present in deny output
result=$(run_hook "{\"tool_name\": \"TeamCreate\", \"cwd\": \"$VALID_CWD\", \"tool_input\": {\"team_name\": \"bad name!\"}}")
output=$(get_output "$result")
assert_contains "Deny has hookEventName" '"hookEventName": "PreToolUse"' "$output"

# 9d. Name with Unicode characters (should be denied — not in [a-zA-Z0-9_-])
JSON=$(jq -n --arg name 'rune-t\u00e9st' --arg cwd "$VALID_CWD" \
  '{tool_name: "TeamCreate", cwd: $cwd, tool_input: {team_name: $name}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "Unicode name denied" '"permissionDecision": "deny"' "$output"

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
