#!/usr/bin/env bash
# test-rune-context-monitor.sh — Tests for scripts/rune-context-monitor.sh
#
# Usage: bash plugins/rune/scripts/tests/test-rune-context-monitor.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/rune-context-monitor.sh"

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

# ── Setup ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"; rm -f /tmp/rune-ctx-test-mon-*.json ${TMPDIR:-/tmp}/rune-ctx-test-mon-*' EXIT

MOCK_CWD="$TMP_DIR/project"
mkdir -p "$MOCK_CWD/tmp"
mkdir -p "$MOCK_CWD/.claude"

MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME"

# Resolve paths (macOS: /tmp → /private/tmp symlink)
MOCK_CWD=$(cd "$MOCK_CWD" && pwd -P)
MOCK_CHOME=$(cd "$MOCK_CHOME" && pwd -P)

SESSION_ID="test-mon-$$"
BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}.json"
WARN_STATE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}-warned.json"

# Helper: create bridge file with given remaining_percentage
# NOTE: owner_pid is set to "NONE" (non-numeric) to bypass the script's PID ownership
# check. The script checks [[ "$B_PID" =~ ^[0-9]+$ ]] — non-numeric values skip
# the whole block. We can't use the test's $PPID because when `bash "$UNDER_TEST"`
# runs, the child's $PPID is the test script's PID, not the test script's $PPID.
create_bridge() {
  local rem_pct="$1"
  local used_pct=$((100 - rem_pct))
  jq -n \
    --argjson rem "$rem_pct" \
    --argjson used "$used_pct" \
    --argjson ts "$(date +%s)" \
    --arg cfg "$MOCK_CHOME" \
    --arg pid "NONE" \
    '{remaining_percentage: $rem, used_pct: $used, timestamp: $ts, config_dir: $cfg, owner_pid: $pid}' \
    > "$BRIDGE_FILE"
}

cleanup_state() {
  rm -f "$BRIDGE_FILE" "$WARN_STATE"
}

build_input() {
  jq -n \
    --arg sid "$SESSION_ID" \
    --arg cwd "$MOCK_CWD" \
    '{session_id: $sid, cwd: $cwd}'
}

# ═══════════════════════════════════════════════════════════════
# 1. No bridge file → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Bridge File ===\n"

cleanup_state
result_code=0
result=$(build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "No bridge → exit 0" "0" "$result_code"
assert_eq "No bridge → no output" "" "$result"

# ═══════════════════════════════════════════════════════════════
# 2. Healthy context → no warning
# ═══════════════════════════════════════════════════════════════
printf "\n=== Healthy Context ===\n"

create_bridge 60
result=$(build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "60% remaining → no output" "" "$result"
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 3. Warning threshold (30% remaining)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Warning Threshold ===\n"

create_bridge 30
result=$(build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Warning fires at 30%" "RUNE CONTEXT MONITOR WARNING" "$result"
assert_contains "Warning has PostToolUse hookEventName" "PostToolUse" "$result"
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 4. Critical threshold (20% remaining)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Critical Threshold ===\n"

create_bridge 20
result=$(build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Critical fires at 20%" "RUNE CONTEXT MONITOR CRITICAL" "$result"
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 5. Debounce — second warning suppressed
# ═══════════════════════════════════════════════════════════════
printf "\n=== Debounce ===\n"

create_bridge 30
# First call — fires
build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1
# Second call — should be suppressed
result=$(build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Second warning suppressed by debounce" "" "$result"
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 6. Severity escalation bypasses debounce
# ═══════════════════════════════════════════════════════════════
printf "\n=== Severity Escalation ===\n"

create_bridge 30
# First call at warning level
build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1
# Now escalate to critical
create_bridge 20
result=$(build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Critical bypasses warning debounce" "CRITICAL" "$result"
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 7. Stale bridge → no warning
# ═══════════════════════════════════════════════════════════════
printf "\n=== Stale Bridge ===\n"

# Create bridge with old timestamp
jq -n \
  --argjson rem 10 \
  --argjson used 90 \
  --argjson ts "$(($(date +%s) - 120))" \
  --arg cfg "$MOCK_CHOME" \
  --arg pid "NONE" \
  '{remaining_percentage: $rem, used_pct: $used, timestamp: $ts, config_dir: $cfg, owner_pid: $pid}' \
  > "$BRIDGE_FILE"

result=$(build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Stale bridge → no output" "" "$result"
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 8. Teammate bypass
# ═══════════════════════════════════════════════════════════════
printf "\n=== Teammate Bypass ===\n"

create_bridge 10  # Critical
TEAMMATE_INPUT=$(jq -n \
  --arg sid "$SESSION_ID" \
  --arg cwd "$MOCK_CWD" \
  --arg transcript "/path/to/subagents/ash-1/t.jsonl" \
  '{session_id: $sid, cwd: $cwd, transcript_path: $transcript}')

result=$(echo "$TEAMMATE_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Teammate skipped" "" "$result"
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 9. Recovery clears debounce
# ═══════════════════════════════════════════════════════════════
printf "\n=== Recovery Clears Debounce ===\n"

# Fire a warning
create_bridge 30
build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1

# Context recovers
create_bridge 60
build_input | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1

# Warn state should be cleared
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$WARN_STATE" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Recovery cleared debounce state\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Debounce state NOT cleared on recovery\n"
fi
cleanup_state

# ═══════════════════════════════════════════════════════════════
# 10. Empty session ID → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty Session ID ===\n"

result_code=0
result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Empty session ID → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 11. Fail-forward guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fail-forward Guard ===\n"

result_code=0
echo 'not-json' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Invalid JSON → exit 0 (fail-forward)" "0" "$result_code"

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
