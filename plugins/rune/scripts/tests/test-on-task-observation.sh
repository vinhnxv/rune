#!/usr/bin/env bash
# test-on-task-observation.sh — Tests for scripts/on-task-observation.sh
#
# Usage: bash plugins/rune/scripts/tests/test-on-task-observation.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/on-task-observation.sh"

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
mkdir -p "$FAKE_CWD/.rune/echoes/reviewer"
mkdir -p "$FAKE_CWD/.rune/echoes/planner"
mkdir -p "$FAKE_CWD/.rune/echoes/workers"
mkdir -p "$FAKE_CWD/.rune/echoes/orchestrator"

# Create initial MEMORY.md files
for role in reviewer planner workers orchestrator; do
  printf "# %s Memory\n" "$role" > "$FAKE_CWD/.rune/echoes/$role/MEMORY.md"
done

# Helper: run the hook with given JSON input
run_hook() {
  local input="$1"
  local exit_code=0
  local stdout stderr
  stdout=$(printf '%s' "$input" | \
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

# 1b. Invalid JSON exits 0
run_hook "not-json"
assert_eq "Invalid JSON exits 0" "0" "$(get_exit_code)"

# 1c. JSON without team_name exits 0
run_hook '{"task_id": "task-1"}'
assert_eq "Missing team_name exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 2. Non-Rune Team Filtering
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Rune Team Filtering ===\n"

# 2a. Non-rune/arc team exits 0
run_hook "{\"team_name\": \"other-team\", \"task_id\": \"task-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Non-rune team exits 0" "0" "$(get_exit_code)"

# 2b. Team name with invalid chars exits 0
run_hook "{\"team_name\": \"rune-test/../evil\", \"task_id\": \"task-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Invalid team name chars exits 0" "0" "$(get_exit_code)"

# 2c. Team name over 128 chars exits 0
LONG_NAME="rune-$(python3 -c "print('a' * 130)")"
run_hook "{\"team_name\": \"$LONG_NAME\", \"task_id\": \"task-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Overly long team name exits 0" "0" "$(get_exit_code)"

# 2d. Task ID with invalid chars exits 0
run_hook "{\"team_name\": \"rune-test\", \"task_id\": \"task/../evil\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Invalid task ID exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 3. Shutdown/Cleanup Task Skipping
# ═══════════════════════════════════════════════════════════════
printf "\n=== Shutdown/Cleanup Task Skipping ===\n"

# 3a. Shutdown task exits 0 without writing
run_hook "{\"team_name\": \"rune-review-test\", \"task_id\": \"task-shut\", \"task_subject\": \"Shutdown all teammates\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Shutdown task exits 0" "0" "$(get_exit_code)"

# 3b. Cleanup task exits 0
run_hook "{\"team_name\": \"rune-review-test\", \"task_id\": \"task-clean\", \"task_subject\": \"Cleanup resources\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Cleanup task exits 0" "0" "$(get_exit_code)"

# 3c. Aggregate task exits 0
run_hook "{\"team_name\": \"rune-review-test\", \"task_id\": \"task-agg\", \"task_subject\": \"Aggregate all results\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Aggregate task exits 0" "0" "$(get_exit_code)"

# 3d. Monitor task exits 0
run_hook "{\"team_name\": \"rune-review-test\", \"task_id\": \"task-mon\", \"task_subject\": \"Monitor progress\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Monitor task exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 4. CWD Handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Handling ===\n"

# 4a. Missing CWD exits 0
run_hook '{"team_name": "rune-review-test", "task_id": "task-1", "task_subject": "Test"}'
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code)"

# 4b. Non-existent CWD exits 0
run_hook '{"team_name": "rune-review-test", "task_id": "task-1", "task_subject": "Test", "cwd": "/nonexistent/xyz"}'
assert_eq "Non-existent CWD exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 5. No Echoes Directory → Silent Exit
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Echoes Directory ===\n"

NO_ECHO_CWD="$TMPWORK/no-echo-project"
mkdir -p "$NO_ECHO_CWD/tmp/.rune-signals"
# No .rune/echoes/ dir
run_hook "{\"team_name\": \"rune-review-test\", \"task_id\": \"task-1\", \"task_subject\": \"Test\", \"cwd\": \"$NO_ECHO_CWD\"}"
assert_eq "No echoes dir exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 6. Role Detection from Team Name
# ═══════════════════════════════════════════════════════════════
printf "\n=== Role Detection ===\n"

# 6a. Review team → reviewer role
run_hook "{\"team_name\": \"rune-review-test6a\", \"task_id\": \"task-6a\", \"task_subject\": \"Review auth\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Review team exits 0" "0" "$(get_exit_code)"

REVIEWER_MEM=$(cat "$FAKE_CWD/.rune/echoes/reviewer/MEMORY.md")
assert_contains "Review task written to reviewer MEMORY.md" "Review auth" "$REVIEWER_MEM"
assert_contains "Reviewer source includes team name" "rune-review-test6a" "$REVIEWER_MEM"

# 6b. Plan team → planner role
run_hook "{\"team_name\": \"rune-plan-test6b\", \"task_id\": \"task-6b\", \"task_subject\": \"Plan feature X\", \"teammate_name\": \"planner-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Plan team exits 0" "0" "$(get_exit_code)"

PLANNER_MEM=$(cat "$FAKE_CWD/.rune/echoes/planner/MEMORY.md")
assert_contains "Plan task written to planner MEMORY.md" "Plan feature X" "$PLANNER_MEM"

# 6c. Work team → workers role
run_hook "{\"team_name\": \"rune-work-test6c\", \"task_id\": \"task-6c\", \"task_subject\": \"Implement API\", \"teammate_name\": \"smith-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Work team exits 0" "0" "$(get_exit_code)"

WORKERS_MEM=$(cat "$FAKE_CWD/.rune/echoes/workers/MEMORY.md")
assert_contains "Work task written to workers MEMORY.md" "Implement API" "$WORKERS_MEM"

# 6d. Arc team → workers role (arc matches *arc*)
run_hook "{\"team_name\": \"arc-2026-test6d\", \"task_id\": \"task-6d\", \"task_subject\": \"Arc phase\", \"teammate_name\": \"worker\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Arc team exits 0" "0" "$(get_exit_code)"

WORKERS_MEM2=$(cat "$FAKE_CWD/.rune/echoes/workers/MEMORY.md")
assert_contains "Arc task written to workers MEMORY.md" "Arc phase" "$WORKERS_MEM2"

# ═══════════════════════════════════════════════════════════════
# 7. Dedup — Same Task/Team Pair Not Written Twice
# ═══════════════════════════════════════════════════════════════
printf "\n=== Dedup ===\n"

# Count reviewer entries before
BEFORE_COUNT=$(grep -c "Observations" "$FAKE_CWD/.rune/echoes/reviewer/MEMORY.md" || echo "0")

# Re-run with same team+task as 6a
run_hook "{\"team_name\": \"rune-review-test6a\", \"task_id\": \"task-6a\", \"task_subject\": \"Review auth\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Dedup re-run exits 0" "0" "$(get_exit_code)"

AFTER_COUNT=$(grep -c "Observations" "$FAKE_CWD/.rune/echoes/reviewer/MEMORY.md" || echo "0")
assert_eq "Dedup prevents duplicate write" "$BEFORE_COUNT" "$AFTER_COUNT"

# ═══════════════════════════════════════════════════════════════
# 8. Observation Entry Format
# ═══════════════════════════════════════════════════════════════
printf "\n=== Observation Entry Format ===\n"

REVIEWER_MEM=$(cat "$FAKE_CWD/.rune/echoes/reviewer/MEMORY.md")
assert_contains "Entry has observations layer tag" "observations" "$REVIEWER_MEM"
assert_contains "Entry has Confidence: LOW" "Confidence" "$REVIEWER_MEM"
assert_contains "Entry has source with team/agent" "forge-warden" "$REVIEWER_MEM"

# ═══════════════════════════════════════════════════════════════
# 9. Echo-Dirty Signal
# ═══════════════════════════════════════════════════════════════
printf "\n=== Echo-Dirty Signal ===\n"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$FAKE_CWD/tmp/.rune-signals/.echo-dirty" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: .echo-dirty signal file created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .echo-dirty signal file not created\n"
fi

# ═══════════════════════════════════════════════════════════════
# 10. Symlink Guard on Echoes Directory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Guards ===\n"

SYMLINK_CWD="$TMPWORK/symlink-project"
mkdir -p "$SYMLINK_CWD/tmp/.rune-signals"
mkdir -p "$TMPWORK/real-echoes"
ln -s "$TMPWORK/real-echoes" "$SYMLINK_CWD/.claude"
mkdir -p "$SYMLINK_CWD/.claude"  2>/dev/null || true
# Create .rune/echoes as a symlink
mkdir -p "$TMPWORK/real-echoes-dir"
SYMLINK_CWD2="$TMPWORK/symlink-project2"
mkdir -p "$SYMLINK_CWD2/tmp/.rune-signals"
mkdir -p "$SYMLINK_CWD2/.claude"
mkdir -p "$SYMLINK_CWD2/.rune"
ln -s "$TMPWORK/real-echoes-dir" "$SYMLINK_CWD2/.rune/echoes"

run_hook "{\"team_name\": \"rune-review-sym\", \"task_id\": \"task-sym\", \"task_subject\": \"Symlink test\", \"cwd\": \"$SYMLINK_CWD2\"}"
assert_eq "Symlink echoes dir exits 0 (skipped)" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 11. No MEMORY.md for Role → Silent Exit
# ═══════════════════════════════════════════════════════════════
printf "\n=== No MEMORY.md for Role ===\n"

NO_MEM_CWD="$TMPWORK/no-mem-project"
mkdir -p "$NO_MEM_CWD/tmp/.rune-signals"
mkdir -p "$NO_MEM_CWD/.rune/echoes/reviewer"
# No MEMORY.md file in reviewer dir

run_hook "{\"team_name\": \"rune-review-nomem\", \"task_id\": \"task-nomem\", \"task_subject\": \"Test\", \"cwd\": \"$NO_MEM_CWD\"}"
assert_eq "No MEMORY.md exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 12. Task Description Truncation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Task Description Handling ===\n"

# 12a. Long description is handled without error
LONG_DESC=$(python3 -c "print('D' * 600)")
run_hook "{\"team_name\": \"rune-review-desc12\", \"task_id\": \"task-desc12\", \"task_subject\": \"Desc test\", \"task_description\": \"$LONG_DESC\", \"teammate_name\": \"worker\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Long description exits 0" "0" "$(get_exit_code)"

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
