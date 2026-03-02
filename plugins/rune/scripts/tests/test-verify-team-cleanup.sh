#!/usr/bin/env bash
# test-verify-team-cleanup.sh -- Tests for scripts/verify-team-cleanup.sh
#
# Usage: bash plugins/rune/scripts/tests/test-verify-team-cleanup.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="${SCRIPT_DIR}/../verify-team-cleanup.sh"

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
    printf "  FAIL: %s (needle found but should not be)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

FAKE_CHOME="${TMPROOT}/fake-claude"
mkdir -p "$FAKE_CHOME/teams"

# ===================================================================
# 1. Wrong tool_name exits 0
# ===================================================================
printf "\n=== Wrong tool_name ===\n"

rc=0
echo '{"tool_name":"Bash","session_id":"test-sid"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" >/dev/null 2>&1 || rc=$?
assert_eq "Wrong tool_name exits 0" "0" "$rc"

# ===================================================================
# 2. Empty input exits 0
# ===================================================================
printf "\n=== Empty input ===\n"

rc=0
echo '' | CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" >/dev/null 2>&1 || rc=$?
assert_eq "Empty input exits 0" "0" "$rc"

# ===================================================================
# 3. No remaining team dirs -- clean output
# ===================================================================
printf "\n=== No remaining dirs ===\n"

output=$(echo '{"tool_name":"TeamDelete","session_id":"test-sid-clean"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
assert_not_contains "No TLC-002 output for clean state" "TLC-002" "$output"

# ===================================================================
# 4. Remaining rune-* dir detected
# ===================================================================
printf "\n=== Remaining rune-* dir ===\n"

mkdir -p "$FAKE_CHOME/teams/rune-zombie-team"

output=$(echo '{"tool_name":"TeamDelete","session_id":"test-sid-zombie"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
assert_contains "TLC-002 warning emitted" "TLC-002" "$output"
assert_contains "Zombie team name in output" "rune-zombie-team" "$output"

# ===================================================================
# 5. Remaining arc-* dir detected
# ===================================================================
printf "\n=== Remaining arc-* dir ===\n"

mkdir -p "$FAKE_CHOME/teams/arc-test-pipeline"

output=$(echo '{"tool_name":"TeamDelete","session_id":"test-sid-arc"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
assert_contains "Arc dir in TLC-002 output" "arc-test-pipeline" "$output"

# ===================================================================
# 6. Multiple remaining dirs counted correctly
# ===================================================================
printf "\n=== Multiple remaining dirs ===\n"

mkdir -p "$FAKE_CHOME/teams/rune-team-a"
mkdir -p "$FAKE_CHOME/teams/rune-team-b"

output=$(echo '{"tool_name":"TeamDelete","session_id":"test-sid-multi"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
# Should report count of all remaining rune-*/arc-* dirs
count=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ctx = d.get('hookSpecificOutput',{}).get('additionalContext','')
# Extract count from 'N rune/arc team dir(s)'
import re
m = re.search(r'(\d+) rune/arc team', ctx)
print(m.group(1) if m else 0)
" 2>/dev/null || echo "parse_error")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$count" -ge 4 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Multiple dirs counted (%s)\n" "$count"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Expected >=4 remaining dirs, got %s\n" "$count"
fi

# ===================================================================
# 7. Output is valid JSON with hookSpecificOutput
# ===================================================================
printf "\n=== Output JSON structure ===\n"

output=$(echo '{"tool_name":"TeamDelete","session_id":"test-sid"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)

json_valid=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'hookSpecificOutput' in d
assert 'hookEventName' in d['hookSpecificOutput']
assert d['hookSpecificOutput']['hookEventName'] == 'PostToolUse'
assert 'additionalContext' in d['hookSpecificOutput']
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "Output has correct hookSpecificOutput structure" "ok" "$json_valid"

# ===================================================================
# 8. Session ID short format in output
# ===================================================================
printf "\n=== Session ID short format ===\n"

output=$(echo '{"tool_name":"TeamDelete","session_id":"abcdefgh12345678"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
assert_contains "Short session ID (first 8 chars)" "abcdefgh" "$output"

# ===================================================================
# 9. Symlink team dir excluded from count
# ===================================================================
printf "\n=== Symlink team dir excluded ===\n"

REAL_DIR="${TMPROOT}/real-team-dir"
mkdir -p "$REAL_DIR"
ln -sf "$REAL_DIR" "$FAKE_CHOME/teams/rune-symlink-dir" 2>/dev/null || true

if [[ -L "$FAKE_CHOME/teams/rune-symlink-dir" ]]; then
  output=$(echo '{"tool_name":"TeamDelete","session_id":"sid"}' | \
    CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
  assert_not_contains "Symlink dir excluded" "rune-symlink-dir" "$output"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink team dir excluded (skip - creation failed)\n"
fi

# ===================================================================
# 10. Non-absolute CHOME exits 0
# ===================================================================
printf "\n=== Non-absolute CHOME ===\n"

rc=0
echo '{"tool_name":"TeamDelete","session_id":"sid"}' | \
  CLAUDE_CONFIG_DIR="relative/path" bash "$VERIFIER" >/dev/null 2>&1 || rc=$?
assert_eq "Non-absolute CHOME exits 0" "0" "$rc"

# ===================================================================
# 11. /rune:rest recommendation in output
# ===================================================================
printf "\n=== Heal recommendation ===\n"

output=$(echo '{"tool_name":"TeamDelete","session_id":"sid"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
assert_contains "Heal recommendation present" "/rune:rest" "$output"

# ===================================================================
# 12. RUNE_TRACE logging
# ===================================================================
printf "\n=== Trace logging ===\n"

TRACE_LOG="${TMPROOT}/trace.log"
rm -f "$TRACE_LOG" 2>/dev/null

echo '{"tool_name":"TeamDelete","session_id":"sid-trace"}' | \
  RUNE_TRACE=1 RUNE_TRACE_LOG="$TRACE_LOG" CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" >/dev/null 2>&1 || true

if [[ -f "$TRACE_LOG" ]]; then
  trace_content=$(cat "$TRACE_LOG")
  assert_contains "Trace log mentions TLC-002" "TLC-002" "$trace_content"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Trace log not created\n"
fi

# ===================================================================
# 13. Non-rune/arc team dirs are ignored
# ===================================================================
printf "\n=== Non-rune/arc dirs ignored ===\n"

# Clean up all rune/arc dirs first
rm -rf "$FAKE_CHOME/teams/rune-"* "$FAKE_CHOME/teams/arc-"* 2>/dev/null || true
mkdir -p "$FAKE_CHOME/teams/my-regular-team"

output=$(echo '{"tool_name":"TeamDelete","session_id":"sid"}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$VERIFIER" 2>/dev/null)
assert_not_contains "Non-rune dir not reported" "my-regular-team" "$output"

# ===================================================================
# Results
# ===================================================================
printf "\n===================================================\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "===================================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
