#!/usr/bin/env bash
# test-rune-status.sh — Tests for scripts/rune-statusline.sh
#
# Usage: bash plugins/rune/scripts/tests/test-rune-status.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/rune-statusline.sh"

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
trap 'rm -rf "$TMP_DIR"; rm -f /tmp/rune-ctx-test-status-sess-*.json /tmp/rune-statusline-git-cache-$(id -u)' EXIT

MOCK_CWD="$TMP_DIR/project"
mkdir -p "$MOCK_CWD/tmp"
mkdir -p "$MOCK_CWD/.git"  # Make it look like a git repo

MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME"

SESSION_ID="test-status-sess-$$"

# Helper: build statusline input JSON
build_input() {
  local used_pct="${1:-50}" remaining="${2:-50}" cost="${3:-1.23}"
  jq -n \
    --arg model "Claude" \
    --arg dir "$MOCK_CWD" \
    --arg sid "$SESSION_ID" \
    --argjson remaining "$remaining" \
    --argjson used "$used_pct" \
    --argjson cost "$cost" \
    '{
      model: {display_name: $model},
      workspace: {current_dir: $dir},
      session_id: $sid,
      context_window: {remaining_percentage: $remaining, used_percentage: $used},
      cost: {total_cost_usd: $cost}
    }'
}

# ═══════════════════════════════════════════════════════════════
# 1. Basic output (progress bar)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Basic Output ===\n"

result=$(build_input 50 50 1.23 | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
result_code=$?
assert_eq "Exits 0 on valid input" "0" "$result_code"

# Strip ANSI codes for content checking
plain=$(echo "$result" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Output contains percentage" "50%" "$plain"
assert_contains "Output contains cost" '$1.23' "$plain"
assert_contains "Output contains model" "Claude" "$plain"

# ═══════════════════════════════════════════════════════════════
# 2. Bridge file written
# ═══════════════════════════════════════════════════════════════
printf "\n=== Bridge File ===\n"

BRIDGE="/tmp/rune-ctx-${SESSION_ID}.json"
rm -f "$BRIDGE"
build_input 70 30 2.50 | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$BRIDGE" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Bridge file created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge file NOT created\n"
fi

# Bridge JSON is valid
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if python3 -c 'import sys,json; json.load(sys.stdin)' < "$BRIDGE" 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Bridge file is valid JSON\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge file is NOT valid JSON\n"
fi

# Bridge has session isolation fields
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
has_fields=$(python3 -c '
import sys, json
d = json.load(sys.stdin)
assert "config_dir" in d
assert "owner_pid" in d
assert "remaining_percentage" in d
print("ok")
' < "$BRIDGE" 2>/dev/null || echo "fail")
if [[ "$has_fields" == "ok" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Bridge has isolation fields\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge missing isolation fields\n"
fi

rm -f "$BRIDGE"

# ═══════════════════════════════════════════════════════════════
# 3. Color thresholds
# ═══════════════════════════════════════════════════════════════
printf "\n=== Color Thresholds ===\n"

# Low usage → green (contains the green escape code \033[32m)
result=$(build_input 30 70 0 | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Low usage has green color" $'\033[32m' "$result"

# High usage → red
result=$(build_input 85 15 0 | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "High usage has red color" $'\033[31m' "$result"

# Very high usage → blink red
result=$(build_input 95 5 0 | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Very high usage has blink red" $'\033[5;31m' "$result"

rm -f "/tmp/rune-ctx-${SESSION_ID}.json"

# ═══════════════════════════════════════════════════════════════
# 4. Missing jq
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing jq Fallback ===\n"

# We can't easily uninstall jq, but we can test the fallback message
# by checking the script has a fallback path
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if grep -q 'command -v jq' "$UNDER_TEST"; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Script checks for jq availability\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Script does not check for jq\n"
fi

# ═══════════════════════════════════════════════════════════════
# 5. Progress bar segments
# ═══════════════════════════════════════════════════════════════
printf "\n=== Progress Bar Segments ===\n"

result=$(build_input 50 50 0 | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
# Should contain filled and empty blocks
assert_contains "Has filled blocks" "█" "$result"
assert_contains "Has empty blocks" "░" "$result"

rm -f "/tmp/rune-ctx-${SESSION_ID}.json"

# ═══════════════════════════════════════════════════════════════
# 6. Fail-open guard (ERR trap)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fail-open Guard ===\n"

result_code=0
echo 'invalid-not-json' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Invalid JSON → exit 0 (fail-open)" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 7. Empty session ID
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty Session ID ===\n"

NO_SID_INPUT=$(jq -n \
  --arg model "Claude" \
  --arg dir "$MOCK_CWD" \
  '{
    model: {display_name: $model},
    workspace: {current_dir: $dir},
    context_window: {remaining_percentage: 50, used_percentage: 50},
    cost: {total_cost_usd: 0}
  }')

result_code=0
result=$(echo "$NO_SID_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Empty session_id → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 8. Workflow detection
# ═══════════════════════════════════════════════════════════════
printf "\n=== Workflow Detection ===\n"

# Create an active workflow state file
cat > "$MOCK_CWD/tmp/.rune-review-active.json" <<JSON
{"status":"active","workflow":"review"}
JSON

result=$(build_input 50 50 0 | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
plain=$(echo "$result" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Workflow detected in output" "review" "$plain"

rm -f "$MOCK_CWD/tmp/.rune-review-active.json"
rm -f "/tmp/rune-ctx-${SESSION_ID}.json"

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
