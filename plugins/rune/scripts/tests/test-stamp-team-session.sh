#!/usr/bin/env bash
# test-stamp-team-session.sh -- Tests for scripts/stamp-team-session.sh
#
# Usage: bash plugins/rune/scripts/tests/test-stamp-team-session.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMPER="${SCRIPT_DIR}/../stamp-team-session.sh"

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
mkdir -p "$FAKE_CHOME"

# ===================================================================
# 1. Wrong tool_name exits 0
# ===================================================================
printf "\n=== Wrong tool_name ===\n"

rc=0
echo '{"tool_name":"Bash","session_id":"test-sid","tool_input":{"team_name":"rune-test"}}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Wrong tool_name exits 0" "0" "$rc"

# ===================================================================
# 2. Missing session_id exits 0
# ===================================================================
printf "\n=== Missing session_id ===\n"

rc=0
echo '{"tool_name":"TeamCreate","tool_input":{"team_name":"rune-test"}}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Missing session_id exits 0" "0" "$rc"

# ===================================================================
# 3. Missing team_name exits 0
# ===================================================================
printf "\n=== Missing team_name ===\n"

rc=0
echo '{"tool_name":"TeamCreate","session_id":"test-sid","tool_input":{}}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Missing team_name exits 0" "0" "$rc"

# ===================================================================
# 4. Invalid team_name (path traversal) exits 0
# ===================================================================
printf "\n=== Invalid team_name ===\n"

rc=0
echo '{"tool_name":"TeamCreate","session_id":"test-sid","tool_input":{"team_name":"../evil"}}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Path traversal team_name exits 0" "0" "$rc"

rc=0
echo '{"tool_name":"TeamCreate","session_id":"test-sid","tool_input":{"team_name":"bad team!"}}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Special chars team_name exits 0" "0" "$rc"

# ===================================================================
# 5. Team directory doesn't exist exits 0
# ===================================================================
printf "\n=== Team dir not found ===\n"

rc=0
echo '{"tool_name":"TeamCreate","session_id":"test-sid","tool_input":{"team_name":"rune-nonexistent"}}' | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Non-existent team dir exits 0" "0" "$rc"

# ===================================================================
# 6. Successful .session stamp
# ===================================================================
printf "\n=== Successful stamp ===\n"

TEAM_NAME="rune-test-stamp"
TEAM_DIR="$FAKE_CHOME/teams/$TEAM_NAME"
mkdir -p "$TEAM_DIR"

rc=0
echo "{\"tool_name\":\"TeamCreate\",\"session_id\":\"sid-abc123\",\"tool_input\":{\"team_name\":\"$TEAM_NAME\"}}" | \
  CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Successful stamp exits 0" "0" "$rc"

SESSION_FILE="$TEAM_DIR/.session"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SESSION_FILE" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: .session file created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .session file not created\n"
fi

# ===================================================================
# 7. .session contains session_id
# ===================================================================
printf "\n=== .session content: session_id ===\n"

if [[ -f "$SESSION_FILE" ]]; then
  content=$(cat "$SESSION_FILE")
  assert_contains "session_id present" '"session_id"' "$content"
  assert_contains "session_id value correct" '"sid-abc123"' "$content"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 2 ))
  FAIL_COUNT=$(( FAIL_COUNT + 2 ))
  printf "  FAIL: .session file missing for content check\n"
  printf "  FAIL: .session file missing for value check\n"
fi

# ===================================================================
# 8. .session contains owner_pid
# ===================================================================
printf "\n=== .session content: owner_pid ===\n"

if [[ -f "$SESSION_FILE" ]]; then
  content=$(cat "$SESSION_FILE")
  assert_contains "owner_pid present" '"owner_pid"' "$content"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .session file missing for owner_pid check\n"
fi

# ===================================================================
# 9. .session contains config_dir
# ===================================================================
printf "\n=== .session content: config_dir ===\n"

if [[ -f "$SESSION_FILE" ]]; then
  content=$(cat "$SESSION_FILE")
  assert_contains "config_dir present" '"config_dir"' "$content"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .session file missing for config_dir check\n"
fi

# ===================================================================
# 10. .session is valid JSON
# ===================================================================
printf "\n=== .session is valid JSON ===\n"

if [[ -f "$SESSION_FILE" ]]; then
  json_valid=$(jq '.' "$SESSION_FILE" >/dev/null 2>&1 && echo "valid" || echo "invalid")
  assert_eq ".session is valid JSON" "valid" "$json_valid"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .session file missing for JSON validation\n"
fi

# ===================================================================
# 11. Symlink team dir rejected
# ===================================================================
printf "\n=== Symlink team dir ===\n"

REAL_TEAM_DIR="${TMPROOT}/real-team"
mkdir -p "$REAL_TEAM_DIR"
SYMLINK_TEAM="rune-symlink-team"
ln -sf "$REAL_TEAM_DIR" "$FAKE_CHOME/teams/$SYMLINK_TEAM" 2>/dev/null || true

if [[ -L "$FAKE_CHOME/teams/$SYMLINK_TEAM" ]]; then
  rc=0
  echo "{\"tool_name\":\"TeamCreate\",\"session_id\":\"sid-xyz\",\"tool_input\":{\"team_name\":\"$SYMLINK_TEAM\"}}" | \
    CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
  assert_eq "Symlink team dir exits 0" "0" "$rc"
  # Should NOT create .session inside the symlink target
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ ! -f "$REAL_TEAM_DIR/.session" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: No .session in symlink target\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: .session created in symlink target\n"
  fi
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 2 ))
  PASS_COUNT=$(( PASS_COUNT + 2 ))
  printf "  PASS: Symlink team dir test (skip - symlink creation failed)\n"
  printf "  PASS: No .session in symlink target (skip)\n"
fi

# ===================================================================
# 12. Symlink .session file is cleaned up
# ===================================================================
printf "\n=== Symlink .session cleanup ===\n"

CLEAN_TEAM="rune-clean-symlink"
CLEAN_DIR="$FAKE_CHOME/teams/$CLEAN_TEAM"
mkdir -p "$CLEAN_DIR"
ln -sf "/tmp/evil-target" "$CLEAN_DIR/.session" 2>/dev/null || true

if [[ -L "$CLEAN_DIR/.session" ]]; then
  echo "{\"tool_name\":\"TeamCreate\",\"session_id\":\"sid-clean\",\"tool_input\":{\"team_name\":\"$CLEAN_TEAM\"}}" | \
    CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || true

  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ ! -L "$CLEAN_DIR/.session" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Symlink .session was cleaned up\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Symlink .session still exists\n"
  fi
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink .session cleanup (skip - symlink creation failed)\n"
fi

# ===================================================================
# 13. Empty input exits 0
# ===================================================================
printf "\n=== Empty input ===\n"

rc=0
echo '' | CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Empty input exits 0" "0" "$rc"

# ===================================================================
# 14. Non-absolute CHOME exits 0
# ===================================================================
printf "\n=== Non-absolute CHOME ===\n"

rc=0
echo '{"tool_name":"TeamCreate","session_id":"sid","tool_input":{"team_name":"rune-test"}}' | \
  CLAUDE_CONFIG_DIR="relative/path" bash "$STAMPER" >/dev/null 2>&1 || rc=$?
assert_eq "Non-absolute CHOME exits 0" "0" "$rc"

# ===================================================================
# 15. RUNE_TRACE logging
# ===================================================================
printf "\n=== Trace logging ===\n"

TRACE_TEAM="rune-trace-test"
TRACE_DIR="$FAKE_CHOME/teams/$TRACE_TEAM"
mkdir -p "$TRACE_DIR"
TRACE_LOG="${TMPROOT}/trace.log"
rm -f "$TRACE_LOG" 2>/dev/null

echo "{\"tool_name\":\"TeamCreate\",\"session_id\":\"sid-trace\",\"tool_input\":{\"team_name\":\"$TRACE_TEAM\"}}" | \
  RUNE_TRACE=1 RUNE_TRACE_LOG="$TRACE_LOG" CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$STAMPER" >/dev/null 2>&1 || true

if [[ -f "$TRACE_LOG" ]]; then
  trace_content=$(cat "$TRACE_LOG")
  assert_contains "Trace log mentions TLC-004" "TLC-004" "$trace_content"
  assert_contains "Trace log mentions team name" "$TRACE_TEAM" "$trace_content"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 2 ))
  FAIL_COUNT=$(( FAIL_COUNT + 2 ))
  printf "  FAIL: Trace log not created\n"
  printf "  FAIL: Trace log team name check (no log)\n"
fi

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
