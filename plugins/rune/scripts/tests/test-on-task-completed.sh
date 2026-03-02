#!/usr/bin/env bash
# test-on-task-completed.sh — Tests for scripts/on-task-completed.sh
#
# Usage: bash plugins/rune/scripts/tests/test-on-task-completed.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/on-task-completed.sh"

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
TMPWORK=$(mktemp -d)
trap 'rm -rf "$TMPWORK"' EXIT

FAKE_CWD="$TMPWORK/project"
mkdir -p "$FAKE_CWD/tmp/.rune-signals"

# Helper: run the hook with given JSON input
run_hook() {
  local input="$1"
  local exit_code=0
  local stdout stderr
  stdout=$(printf '%s' "$input" | \
    CLAUDE_CONFIG_DIR="$TMPWORK/claude-config" \
    RUNE_TRACE="" \
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

# 1b. Invalid JSON exits 0 with warning
run_hook "not-valid-json"
assert_eq "Invalid JSON exits 0" "0" "$(get_exit_code)"
assert_contains "Invalid JSON warns on stderr" "not valid JSON" "$(get_stderr)"

# 1c. JSON without team_name exits 0
run_hook '{"task_id": "task-1", "cwd": "/tmp"}'
assert_eq "Missing team_name exits 0" "0" "$(get_exit_code)"

# 1d. JSON without task_id exits 0
run_hook "{\"team_name\": \"rune-review-test\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Missing task_id exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 2. Non-Rune Team Filtering
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Rune Team Filtering ===\n"

# 2a. Non-rune team exits 0
run_hook "{\"team_name\": \"other-team\", \"task_id\": \"task-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Non-rune team exits 0" "0" "$(get_exit_code)"

# 2b. TodoWrite-like input (no team) exits 0
run_hook '{"task_id": "todo-1"}'
assert_eq "TodoWrite-like input exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 3. Name Validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Name Validation ===\n"

# 3a. Team name with path traversal characters exits 0
run_hook "{\"team_name\": \"rune-test/../evil\", \"task_id\": \"task-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Team name path traversal exits 0" "0" "$(get_exit_code)"

# 3b. Team name over 128 chars exits 0
LONG_NAME="rune-$(python3 -c "print('a' * 130)")"
run_hook "{\"team_name\": \"$LONG_NAME\", \"task_id\": \"task-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Team name too long exits 0" "0" "$(get_exit_code)"

# 3c. Task ID with invalid chars exits 0
run_hook "{\"team_name\": \"rune-test\", \"task_id\": \"task/../evil\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Task ID invalid chars exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 4. CWD Handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Handling ===\n"

# 4a. Missing CWD exits 0
run_hook '{"team_name": "rune-test", "task_id": "task-1"}'
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code)"

# 4b. Non-existent CWD exits 0
run_hook '{"team_name": "rune-test", "task_id": "task-1", "cwd": "/nonexistent/xyz"}'
assert_eq "Non-existent CWD exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 5. No Signal Directory → Silent Exit
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Signal Directory ===\n"

# CWD with no signal dir for the team
run_hook "{\"team_name\": \"rune-review-nosigdir\", \"task_id\": \"task-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "No signal dir exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 6. Signal File Writing
# ═══════════════════════════════════════════════════════════════
printf "\n=== Signal File Writing ===\n"

TEAM_NAME_6="rune-review-sig6"
SIGNAL_DIR_6="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_6"
mkdir -p "$SIGNAL_DIR_6"

run_hook "{\"team_name\": \"$TEAM_NAME_6\", \"task_id\": \"task-alpha\", \"teammate_name\": \"forge-warden\", \"task_subject\": \"Review auth module\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Signal file write exits 0" "0" "$(get_exit_code)"

# 6a. Signal file exists
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SIGNAL_DIR_6/task-alpha.done" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Signal file task-alpha.done created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal file task-alpha.done not created\n"
fi

# 6b. Signal file contains correct task_id
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if jq -e '.task_id == "task-alpha"' "$SIGNAL_DIR_6/task-alpha.done" >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Signal file has correct task_id\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal file task_id mismatch\n"
fi

# 6c. Signal file contains teammate name
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if jq -e '.teammate == "forge-warden"' "$SIGNAL_DIR_6/task-alpha.done" >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Signal file has correct teammate\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal file teammate mismatch\n"
fi

# 6d. Signal file contains subject
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if jq -e '.subject == "Review auth module"' "$SIGNAL_DIR_6/task-alpha.done" >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Signal file has correct subject\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal file subject mismatch\n"
fi

# 6e. Signal file has completed_at timestamp
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if jq -e '.completed_at' "$SIGNAL_DIR_6/task-alpha.done" >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Signal file has completed_at timestamp\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal file missing completed_at\n"
fi

# ═══════════════════════════════════════════════════════════════
# 7. All-Done Sentinel
# ═══════════════════════════════════════════════════════════════
printf "\n=== All-Done Sentinel ===\n"

TEAM_NAME_7="rune-review-alldone7"
SIGNAL_DIR_7="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_7"
mkdir -p "$SIGNAL_DIR_7"

# Write .expected = 2
printf "2" > "$SIGNAL_DIR_7/.expected"

# Write first task signal
run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"task_id\": \"task-1\", \"teammate_name\": \"a1\", \"cwd\": \"$FAKE_CWD\"}"

# 7a. After 1/2 tasks, no .all-done
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$SIGNAL_DIR_7/.all-done" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No .all-done after 1/2 tasks\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .all-done created after only 1/2 tasks\n"
fi

# Write second task signal
run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"task_id\": \"task-2\", \"teammate_name\": \"a2\", \"cwd\": \"$FAKE_CWD\"}"

# 7b. After 2/2 tasks, .all-done exists
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SIGNAL_DIR_7/.all-done" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: .all-done created after 2/2 tasks\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .all-done not created after 2/2 tasks\n"
fi

# 7c. .all-done is valid JSON with expected fields
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if jq -e '.total and .expected and .completed_at' "$SIGNAL_DIR_7/.all-done" >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: .all-done has valid JSON structure\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .all-done JSON structure invalid\n"
fi

# ═══════════════════════════════════════════════════════════════
# 8. Invalid .expected file
# ═══════════════════════════════════════════════════════════════
printf "\n=== Invalid .expected File ===\n"

TEAM_NAME_8="rune-review-badexp8"
SIGNAL_DIR_8="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_8"
mkdir -p "$SIGNAL_DIR_8"

# 8a. Non-numeric .expected
printf "abc" > "$SIGNAL_DIR_8/.expected"
run_hook "{\"team_name\": \"$TEAM_NAME_8\", \"task_id\": \"task-1\", \"teammate_name\": \"a1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Non-numeric .expected exits 0" "0" "$(get_exit_code)"
assert_contains "Warns about invalid .expected" "invalid count" "$(get_stderr)"

# 8b. Zero in .expected
printf "0" > "$SIGNAL_DIR_8/.expected"
run_hook "{\"team_name\": \"$TEAM_NAME_8\", \"task_id\": \"task-2\", \"teammate_name\": \"a2\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Zero .expected exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 9. Subject Truncation (SEC-C05)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Subject Truncation ===\n"

TEAM_NAME_9="rune-review-trunc9"
SIGNAL_DIR_9="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_9"
mkdir -p "$SIGNAL_DIR_9"

LONG_SUBJECT=$(python3 -c "print('S' * 500)")
run_hook "{\"team_name\": \"$TEAM_NAME_9\", \"task_id\": \"task-trunc\", \"teammate_name\": \"a1\", \"task_subject\": \"$LONG_SUBJECT\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Long subject exits 0" "0" "$(get_exit_code)"

# Check subject is truncated to max 256 chars
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
SUBJ_LEN=$(jq -r '.subject | length' "$SIGNAL_DIR_9/task-trunc.done" 2>/dev/null || echo "0")
if [[ "$SUBJ_LEN" -le 256 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Subject truncated to <= 256 chars (%s)\n" "$SUBJ_LEN"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Subject not truncated (%s chars)\n" "$SUBJ_LEN"
fi

# ═══════════════════════════════════════════════════════════════
# 10. Default Subject (BACK-012)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Default Subject ===\n"

TEAM_NAME_10="rune-review-defsub10"
SIGNAL_DIR_10="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_10"
mkdir -p "$SIGNAL_DIR_10"

run_hook "{\"team_name\": \"$TEAM_NAME_10\", \"task_id\": \"task-nosub\", \"teammate_name\": \"a1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "No subject exits 0" "0" "$(get_exit_code)"

# Default subject should be "Task task-nosub"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
SUBJ=$(jq -r '.subject' "$SIGNAL_DIR_10/task-nosub.done" 2>/dev/null || echo "")
if [[ "$SUBJ" == "Task task-nosub" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Default subject is 'Task task-nosub'\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Default subject mismatch: %q\n" "$SUBJ"
fi

# ═══════════════════════════════════════════════════════════════
# 11. Arc-prefixed Teams Work
# ═══════════════════════════════════════════════════════════════
printf "\n=== Arc-Prefixed Teams ===\n"

TEAM_NAME_11="arc-2026-03-01-test"
SIGNAL_DIR_11="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_11"
mkdir -p "$SIGNAL_DIR_11"

run_hook "{\"team_name\": \"$TEAM_NAME_11\", \"task_id\": \"task-arc\", \"teammate_name\": \"worker\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Arc team exits 0" "0" "$(get_exit_code)"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SIGNAL_DIR_11/task-arc.done" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Arc team signal file written\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Arc team signal file not written\n"
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
