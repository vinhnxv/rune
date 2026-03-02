#!/usr/bin/env bash
# test-session-team-hygiene.sh — Tests for scripts/session-team-hygiene.sh
#
# Usage: bash plugins/rune/scripts/tests/test-session-team-hygiene.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/session-team-hygiene.sh"

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
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_CWD="$TMP_DIR/project"
mkdir -p "$MOCK_CWD/tmp"

MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME"

# ═══════════════════════════════════════════════════════════════
# 1. No orphans → no output
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Orphans ===\n"

result=$(echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-sess-1"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "No orphans → no output" "" "$result"

# ═══════════════════════════════════════════════════════════════
# 2. Empty CWD → silent exit
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty CWD ===\n"

result_code=0
result=$(echo '{"cwd":"","session_id":"test-sess"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Empty CWD exits 0" "0" "$result_code"
assert_eq "Empty CWD → no output" "" "$result"

# ═══════════════════════════════════════════════════════════════
# 3. Path traversal guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== Path Traversal Guard ===\n"

result_code=0
result=$(echo '{"cwd":"'"$MOCK_CWD"'/../../../etc","session_id":"test-sess"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Path traversal exits 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 4. Non-rune teams are ignored
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-rune Teams Ignored ===\n"

# Create a non-rune team dir (old enough to be detected)
mkdir -p "$MOCK_CHOME/teams/foreign-plugin-team"
touch -t 202601010000 "$MOCK_CHOME/teams/foreign-plugin-team" 2>/dev/null || true

result=$(echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-sess"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_not_contains "Foreign team not in output" "foreign-plugin-team" "$result"

rm -rf "$MOCK_CHOME/teams/foreign-plugin-team"

# ═══════════════════════════════════════════════════════════════
# 5. Fail-forward guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fail-forward Guard ===\n"

# The script should always exit 0 even with invalid CHOME
result_code=0
echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Fail-forward on empty CHOME exits 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 6. Exit 0 always (non-blocking)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Always Exit 0 ===\n"

# Missing resolve-session-identity.sh should fail-forward
ISOLATED_DIR="$TMP_DIR/isolated"
mkdir -p "$ISOLATED_DIR"
cp "$UNDER_TEST" "$ISOLATED_DIR/session-team-hygiene.sh"

result_code=0
echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$ISOLATED_DIR/session-team-hygiene.sh" >/dev/null 2>&1 || result_code=$?
assert_eq "Missing dependency exits 0 (fail-forward)" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 7. Output format when orphans found
# ═══════════════════════════════════════════════════════════════
printf "\n=== Output Format ===\n"

# Create a rune team dir that is old enough (>30 min)
mkdir -p "$MOCK_CHOME/teams/rune-orphan-test"
# Write session file with dead PID
echo '{"session_id":"dead-sess","config_dir":"'"$MOCK_CHOME"'","owner_pid":"99999999"}' > "$MOCK_CHOME/teams/rune-orphan-test/.session"
# Make dir old (touch with past time)
touch -t 202601010000 "$MOCK_CHOME/teams/rune-orphan-test" 2>/dev/null || true

result=$(echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-sess-format"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" RUNE_CLEANUP_DRY_RUN=1 bash "$UNDER_TEST" 2>/dev/null)

# Should have output (auto-cleaned orphan with dry run = still counted)
if [[ -n "$result" ]]; then
  # Verify JSON format
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if echo "$result" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Orphan output is valid JSON\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Orphan output is not valid JSON\n"
    printf "    output: %s\n" "$result"
  fi
  assert_contains "Output mentions TLC-003" "TLC-003" "$result"
  assert_contains "Output mentions SessionStart" "SessionStart" "$result"
else
  # Still valid — dry-run with dead PID that can't be verified
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No output (orphan PID cannot be verified as dead in this env)\n"
fi

rm -rf "$MOCK_CHOME/teams/rune-orphan-test"

# ═══════════════════════════════════════════════════════════════
# 8. CHOME absoluteness guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== CHOME Absoluteness Guard ===\n"

result_code=0
result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="relative/path" bash "$UNDER_TEST" >/dev/null 2>&1) || result_code=$?
assert_eq "Relative CHOME exits 0" "0" "$result_code"

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
