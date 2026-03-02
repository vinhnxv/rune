#!/usr/bin/env bash
# test-advise-post-completion.sh — Tests for scripts/advise-post-completion.sh
#
# Usage: bash plugins/rune/scripts/tests/test-advise-post-completion.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/advise-post-completion.sh"

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

# ── Setup temp environment ──
TMPWORK_RAW=$(mktemp -d)
# Canonicalize TMPWORK to handle macOS /var -> /private/var symlink
TMPWORK=$(cd "$TMPWORK_RAW" && pwd -P)
trap 'rm -rf "$TMPWORK"' EXIT

FAKE_CWD="$TMPWORK/project"
mkdir -p "$FAKE_CWD/tmp"
mkdir -p "$FAKE_CWD/.claude/arc"

# Unique session ID per test run to avoid flag file conflicts
TEST_SESSION_ID="test-session-$(date +%s)-$$"

# Helper: run the hook with given JSON input
run_hook() {
  local input="$1"
  local exit_code=0
  local stdout stderr
  stdout=$(printf '%s' "$input" | \
    CLAUDE_CONFIG_DIR="$TMPWORK/claude-config" \
    RUNE_TRACE="" \
    TMPDIR="$TMPWORK/tmp-flags" \
    bash "$HOOK_SCRIPT" 2>"$TMPWORK/stderr.tmp") || exit_code=$?
  stderr=$(cat "$TMPWORK/stderr.tmp" 2>/dev/null || true)
  printf '%s' "$exit_code" > "$TMPWORK/exit_code.tmp"
  printf '%s' "$stdout" > "$TMPWORK/stdout.tmp"
  printf '%s' "$stderr" > "$TMPWORK/stderr_out.tmp"
}

get_exit_code() { cat "$TMPWORK/exit_code.tmp" 2>/dev/null || echo "999"; }
get_stdout() { cat "$TMPWORK/stdout.tmp" 2>/dev/null || true; }
get_stderr() { cat "$TMPWORK/stderr_out.tmp" 2>/dev/null || true; }

# ═══════════════════════════════════════════════════════════════
# 1. Empty / Invalid Input
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty / Invalid Input ===\n"

# 1a. Empty stdin exits 0
run_hook ""
assert_eq "Empty stdin exits 0" "0" "$(get_exit_code)"

# 1b. Invalid JSON exits 0 (fail-open)
run_hook "not-json"
assert_eq "Invalid JSON exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 2. Missing Fields
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing Fields ===\n"

# 2a. Missing CWD exits 0
run_hook "{\"session_id\": \"$TEST_SESSION_ID\"}"
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code)"

# 2b. Missing session_id exits 0
run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Missing session_id exits 0" "0" "$(get_exit_code)"

# 2c. Non-existent CWD exits 0
run_hook "{\"cwd\": \"/nonexistent/xyz\", \"session_id\": \"$TEST_SESSION_ID\"}"
assert_eq "Non-existent CWD exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 3. Session ID Validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Session ID Validation ===\n"

# 3a. Invalid session ID (path injection) exits 0
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"../../etc/passwd\"}"
assert_eq "Path injection session_id exits 0" "0" "$(get_exit_code)"

# 3b. Session ID with spaces exits 0
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"bad session id\"}"
assert_eq "Session ID with spaces exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 4. Subagent Bypass
# ═══════════════════════════════════════════════════════════════
printf "\n=== Subagent Bypass ===\n"

run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$TEST_SESSION_ID\", \"transcript_path\": \"/some/path/subagents/explore/transcript\"}"
assert_eq "Subagent transcript exits 0 (bypass)" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 5. Active Workflow Suppression
# ═══════════════════════════════════════════════════════════════
printf "\n=== Active Workflow Suppression ===\n"

# Create an active state file (no owner_pid to skip PID check in hook)
jq -n --arg cfg "$TMPWORK/claude-config" \
  '{status: "active", team_name: "rune-review-test", config_dir: $cfg}' \
  > "$FAKE_CWD/tmp/.rune-active-test.json"

SID_5="test-active-suppress-$(date +%s)"
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_5\"}"
assert_eq "Active workflow suppresses advisory" "0" "$(get_exit_code)"

# No advisory output when workflow is active
STDOUT_5=$(get_stdout)
assert_not_contains "No advisory when workflow active" "additionalContext" "$STDOUT_5"

rm -f "$FAKE_CWD/tmp/.rune-active-test.json"

# ═══════════════════════════════════════════════════════════════
# 6. No Completed Arc → No Advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Completed Arc ===\n"

# Clean any previous test state
rm -rf "$FAKE_CWD/.claude/arc/"*

SID_6="test-no-arc-$(date +%s)"
mkdir -p "$TMPWORK/tmp-flags"
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_6\"}"
assert_eq "No completed arc exits 0" "0" "$(get_exit_code)"

STDOUT_6=$(get_stdout)
assert_not_contains "No advisory without completed arc" "additionalContext" "$STDOUT_6"

# ═══════════════════════════════════════════════════════════════
# 7. Completed Arc → Advisory Output
# ═══════════════════════════════════════════════════════════════
printf "\n=== Completed Arc → Advisory ===\n"

# Create a completed arc checkpoint (all phases completed)
# Omit owner_pid to avoid PID mismatch (subshell PPID differs from $$)
ARC_DIR="$FAKE_CWD/.claude/arc/arc-test-completed"
mkdir -p "$ARC_DIR"
jq -n --arg cfg "$TMPWORK/claude-config" \
  '{config_dir: $cfg, phases: {forge: {status: "completed"}, review: {status: "completed"}, ship: {status: "completed"}}}' \
  > "$ARC_DIR/checkpoint.json"

# Backdate the checkpoint so it passes the age check
touch -t 202601010000 "$ARC_DIR/checkpoint.json" 2>/dev/null || true

SID_7="test-completed-arc-$(date +%s)"
mkdir -p "$TMPWORK/tmp-flags"
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_7\"}"
assert_eq "Completed arc exits 0" "0" "$(get_exit_code)"

STDOUT_7=$(get_stdout)
assert_contains "Advisory output has hookSpecificOutput" "hookSpecificOutput" "$STDOUT_7"
assert_contains "Advisory mentions arc pipeline" "arc pipeline" "$STDOUT_7"
assert_contains "Advisory mentions PreToolUse hookEventName" "PreToolUse" "$STDOUT_7"

# ═══════════════════════════════════════════════════════════════
# 8. Debounce — Second Call Skipped
# ═══════════════════════════════════════════════════════════════
printf "\n=== Debounce ===\n"

# Re-run with same session ID — should be debounced
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_7\"}"
assert_eq "Debounced call exits 0" "0" "$(get_exit_code)"

STDOUT_8=$(get_stdout)
assert_not_contains "Debounced call produces no advisory" "additionalContext" "$STDOUT_8"

# ═══════════════════════════════════════════════════════════════
# 9. Advisory Never Blocks (Never Deny)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Advisory Never Blocks ===\n"

# Verify output never contains "deny"
SID_9="test-never-deny-$(date +%s)"
mkdir -p "$TMPWORK/tmp-flags"
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_9\"}"
STDOUT_9=$(get_stdout)

# Even when advisory fires, it should NEVER contain permissionDecision: deny
assert_not_contains "Advisory never denies" "\"deny\"" "$STDOUT_9"

# ═══════════════════════════════════════════════════════════════
# 10. Arc With Active Phase → No Advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Active Arc Phase → No Advisory ===\n"

# Create an arc with an in_progress phase
ARC_DIR_10="$FAKE_CWD/.claude/arc/arc-test-active"
mkdir -p "$ARC_DIR_10"
jq -n --arg cfg "$TMPWORK/claude-config" \
  '{config_dir: $cfg, phases: {forge: {status: "completed"}, review: {status: "in_progress"}}}' \
  > "$ARC_DIR_10/checkpoint.json"

SID_10="test-active-arc-$(date +%s)"
mkdir -p "$TMPWORK/tmp-flags"
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_10\"}"
assert_eq "Active arc phase exits 0" "0" "$(get_exit_code)"

STDOUT_10=$(get_stdout)
assert_not_contains "No advisory when arc has active phase" "additionalContext" "$STDOUT_10"

rm -rf "$ARC_DIR_10"

# ═══════════════════════════════════════════════════════════════
# 11. JSON Output Validity
# ═══════════════════════════════════════════════════════════════
printf "\n=== JSON Output Validity ===\n"

SID_11="test-json-valid-$(date +%s)"
mkdir -p "$TMPWORK/tmp-flags"
run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_11\"}"
STDOUT_11=$(get_stdout)

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -z "$STDOUT_11" ]] || printf '%s' "$STDOUT_11" | jq empty 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Output is valid JSON (or empty)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Output is not valid JSON: %q\n" "$STDOUT_11"
fi

# ═══════════════════════════════════════════════════════════════
# 12. Flag File Symlink Guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== Flag File Symlink Guard ===\n"

# Create a symlink flag file — should be removed
SID_12="test-symlink-flag-$(date +%s)"
FLAG_FILE_12="$TMPWORK/tmp-flags/rune-postcomp-$(id -u)-${SID_12}.json"
mkdir -p "$TMPWORK/tmp-flags"
ln -sf /etc/passwd "$FLAG_FILE_12" 2>/dev/null || true

run_hook "{\"cwd\": \"$FAKE_CWD\", \"session_id\": \"$SID_12\"}"
assert_eq "Symlink flag file handled gracefully" "0" "$(get_exit_code)"

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
