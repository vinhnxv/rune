#!/usr/bin/env bash
# test-on-teammate-idle.sh — Tests for scripts/on-teammate-idle.sh
#
# Usage: bash plugins/rune/scripts/tests/test-on-teammate-idle.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/on-teammate-idle.sh"

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

# Create a fake CWD with signal directories
FAKE_CWD="$TMPWORK/project"
mkdir -p "$FAKE_CWD/tmp/.rune-signals"

# Create a fake CLAUDE_CONFIG_DIR
FAKE_CONFIG_DIR="$TMPWORK/claude-config"
mkdir -p "$FAKE_CONFIG_DIR"

# Helper: run the hook with given JSON input, capturing exit code and outputs
# Note: PPID is readonly in bash, so we cannot override it. The hook will use the real PPID.
run_hook() {
  local input="$1"
  local exit_code=0
  local stdout stderr
  stdout=$(printf '%s' "$input" | \
    CLAUDE_CONFIG_DIR="$FAKE_CONFIG_DIR" \
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
# 1. Empty / Invalid Input Handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty / Invalid Input ===\n"

# 1a. Empty stdin exits 0 (fail-forward)
run_hook ""
assert_eq "Empty stdin exits 0" "0" "$(get_exit_code)"

# 1b. Invalid JSON exits 0
run_hook "not-json-at-all"
assert_eq "Invalid JSON exits 0" "0" "$(get_exit_code)"

# 1c. JSON missing team_name exits 0
run_hook '{"teammate_name": "forge-warden", "cwd": "/tmp"}'
assert_eq "Missing team_name exits 0" "0" "$(get_exit_code)"

# 1d. Empty team_name exits 0
run_hook '{"team_name": "", "teammate_name": "forge-warden", "cwd": "/tmp"}'
assert_eq "Empty team_name exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 2. Non-Rune Team Prefix Filtering
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Rune Team Prefix Filtering ===\n"

# 2a. Non-rune/arc team name exits 0 silently
run_hook "{\"team_name\": \"other-team-123\", \"teammate_name\": \"worker\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Non-rune team exits 0" "0" "$(get_exit_code)"

# 2b. Rune-prefixed team passes prefix check (but may exit for other reasons)
run_hook "{\"team_name\": \"rune-review-test\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Rune-prefixed team exits 0 (no inscription)" "0" "$(get_exit_code)"

# 2c. Arc-prefixed team passes prefix check
run_hook "{\"team_name\": \"arc-2026-test\", \"teammate_name\": \"worker\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Arc-prefixed team exits 0 (no inscription)" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 3. Team Name Validation (Character Set & Length)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Team Name Validation ===\n"

# 3a. Team name with special characters exits 0
run_hook "{\"team_name\": \"rune-review/../evil\", \"teammate_name\": \"worker\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Team name with path traversal exits 0" "0" "$(get_exit_code)"

# 3b. Team name exceeding 128 chars exits 0
LONG_NAME="rune-$(python3 -c "print('a' * 130)")"
run_hook "{\"team_name\": \"$LONG_NAME\", \"teammate_name\": \"worker\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Overly long team name exits 0" "0" "$(get_exit_code)"

# 3c. Teammate name with invalid characters exits 0
run_hook "{\"team_name\": \"rune-review-test\", \"teammate_name\": \"forge/../evil\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Invalid teammate name exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 4. CWD Handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Handling ===\n"

# 4a. Missing CWD exits 0 with warning
run_hook '{"team_name": "rune-review-test", "teammate_name": "forge-warden"}'
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code)"
# Note: the script emits "WARN: ... missing 'cwd' field" to stderr
assert_contains "Missing CWD warns on stderr" "cwd" "$(get_stderr)"

# 4b. Non-existent CWD exits 0
run_hook '{"team_name": "rune-review-test", "teammate_name": "forge-warden", "cwd": "/nonexistent/path/xyz"}'
assert_eq "Non-existent CWD exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 5. Work Team Skip (output file gate bypass)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Work Team Output File Gate Bypass ===\n"

# 5a. Work team skips output file gate (no inscription needed)
run_hook "{\"team_name\": \"rune-work-abc123\", \"teammate_name\": \"smith-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Work team exits 0 (skips output gate)" "0" "$(get_exit_code)"

# 5b. Arc-work team also skips
run_hook "{\"team_name\": \"arc-work-abc123\", \"teammate_name\": \"smith-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Arc-work team exits 0 (skips output gate)" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 6. No Inscription File (Review Team)
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Inscription File ===\n"

# 6a. Review team with no inscription exits 0 (no gate to enforce)
run_hook "{\"team_name\": \"rune-review-test\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "No inscription exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 7. Inscription + Missing Output File → Block (exit 2)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inscription + Missing Output ===\n"

TEAM_NAME_7="rune-review-test7"
SIGNAL_DIR_7="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_7"
mkdir -p "$SIGNAL_DIR_7"
# Layer 0 guard: create team dir so hook doesn't short-circuit as orphan
mkdir -p "$FAKE_CONFIG_DIR/teams/$TEAM_NAME_7"

# Create inscription with expected output
cat > "$SIGNAL_DIR_7/inscription.json" <<'INSC'
{
  "team_name": "rune-review-test7",
  "output_dir": "tmp/reviews/test7/",
  "teammates": [
    {"name": "forge-warden", "output_file": "forge-warden.md"},
    {"name": "pattern-weaver", "output_file": "pattern-weaver.md"}
  ]
}
INSC

# Create the output directory but NOT the output file
mkdir -p "$FAKE_CWD/tmp/reviews/test7"

# 7a. Missing output file blocks (exit 2)
# Note: The script uses { echo >&2; } 2>/dev/null pattern so stderr is suppressed.
# We only verify exit code here.
run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Missing output file exits 2 (block)" "2" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 8. Inscription + Output Too Small → Block (exit 2)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Output Too Small ===\n"

# Create a tiny output file (< 50 bytes)
printf "tiny" > "$FAKE_CWD/tmp/reviews/test7/forge-warden.md"

run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Too-small output exits 2 (block)" "2" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 9. Inscription + Adequate Output → Pass (exit 0)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Adequate Output (Non-Review Team) ===\n"

# Use a non-review team to avoid SEAL requirement
TEAM_NAME_9="rune-plan-test9"
SIGNAL_DIR_9="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_9"
mkdir -p "$SIGNAL_DIR_9"
mkdir -p "$FAKE_CWD/tmp/plans/test9"
mkdir -p "$FAKE_CONFIG_DIR/teams/$TEAM_NAME_9"

cat > "$SIGNAL_DIR_9/inscription.json" <<'INSC9'
{
  "team_name": "rune-plan-test9",
  "output_dir": "tmp/plans/test9/",
  "teammates": [
    {"name": "planner-1", "output_file": "planner-1.md"}
  ]
}
INSC9

# Write adequate output (>= 50 bytes)
python3 -c "print('x' * 100)" > "$FAKE_CWD/tmp/plans/test9/planner-1.md"

run_hook "{\"team_name\": \"$TEAM_NAME_9\", \"teammate_name\": \"planner-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Adequate output exits 0 (pass)" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 10. SEAL Enforcement for Review/Audit Teams
# ═══════════════════════════════════════════════════════════════
printf "\n=== SEAL Enforcement ===\n"

# Clear retry counters from previous block tests (sections 7-8)
rm -f "$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_7/"*.idle-retries 2>/dev/null || true

# Write large output WITHOUT SEAL for the review team from section 7
python3 -c "print('x' * 200)" > "$FAKE_CWD/tmp/reviews/test7/forge-warden.md"

run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Missing SEAL exits 2 (block)" "2" "$(get_exit_code)"

# 10b. With SEAL: header at column 0 → pass
# Content depth check requires 20+ lines, so generate enough output
{
  python3 -c "
for i in range(25):
    print(f'P2: Finding #{i+1} in file.ts — description of issue')
"
  printf 'SEAL: test-seal\n'
} > "$FAKE_CWD/tmp/reviews/test7/forge-warden.md"

# Clear retry counter from 10a block
rm -f "$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_7/"*.idle-retries 2>/dev/null || true

run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Output with SEAL exits 0 (pass)" "0" "$(get_exit_code)"

# 10c. With <seal> XML tag → also pass
{
  python3 -c "
for i in range(25):
    print(f'P2: Finding #{i+1} in file.ts — description of issue')
"
  printf '<seal>test</seal>\n'
} > "$FAKE_CWD/tmp/reviews/test7/forge-warden.md"

run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Output with <seal> tag exits 0 (pass)" "0" "$(get_exit_code)"

# 10d. With Inner Flame marker → also pass
{
  python3 -c "
for i in range(25):
    print(f'P2: Finding #{i+1} in file.ts — description of issue')
"
  printf 'Inner Flame: verified\n'
} > "$FAKE_CWD/tmp/reviews/test7/forge-warden.md"

run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"teammate_name\": \"forge-warden\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Output with Inner Flame exits 0 (pass)" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 11. SEC-003: Path Traversal in Output File
# ═══════════════════════════════════════════════════════════════
printf "\n=== Path Traversal Guards ===\n"

TEAM_NAME_11="rune-review-sec11"
SIGNAL_DIR_11="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_11"
mkdir -p "$SIGNAL_DIR_11"
mkdir -p "$FAKE_CONFIG_DIR/teams/$TEAM_NAME_11"

# 11a. output_file with .. → exit 2
cat > "$SIGNAL_DIR_11/inscription.json" <<'INSC11A'
{
  "team_name": "rune-review-sec11",
  "output_dir": "tmp/reviews/sec11/",
  "teammates": [
    {"name": "evil", "output_file": "../../etc/passwd"}
  ]
}
INSC11A

run_hook "{\"team_name\": \"$TEAM_NAME_11\", \"teammate_name\": \"evil\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Path traversal in output_file exits 2" "2" "$(get_exit_code)"

# 11b. output_dir with .. → exit 2
cat > "$SIGNAL_DIR_11/inscription.json" <<'INSC11B'
{
  "team_name": "rune-review-sec11",
  "output_dir": "tmp/../../../etc/",
  "teammates": [
    {"name": "evil", "output_file": "passwd"}
  ]
}
INSC11B

run_hook "{\"team_name\": \"$TEAM_NAME_11\", \"teammate_name\": \"evil\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Path traversal in output_dir exits 2" "2" "$(get_exit_code)"

# 11c. output_dir not starting with tmp/ → exit 2
cat > "$SIGNAL_DIR_11/inscription.json" <<'INSC11C'
{
  "team_name": "rune-review-sec11",
  "output_dir": "etc/evil/",
  "teammates": [
    {"name": "evil", "output_file": "test.md"}
  ]
}
INSC11C

run_hook "{\"team_name\": \"$TEAM_NAME_11\", \"teammate_name\": \"evil\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "output_dir outside tmp/ exits 2" "2" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 12. Teammate Not in Inscription → Allow (exit 0)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Teammate Not in Inscription ===\n"

run_hook "{\"team_name\": \"$TEAM_NAME_7\", \"teammate_name\": \"unknown-agent\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Unknown teammate exits 0 (no gate)" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 13. Layer 4: All-Tasks-Done Signal
# ═══════════════════════════════════════════════════════════════
printf "\n=== All-Tasks-Done Signal ===\n"

TEAM_NAME_13="rune-work-atd13"
SIGNAL_DIR_13="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_13"
mkdir -p "$SIGNAL_DIR_13"
mkdir -p "$FAKE_CONFIG_DIR/teams/$TEAM_NAME_13"

# Create task directory with all tasks completed
TASK_DIR_13="$FAKE_CONFIG_DIR/tasks/$TEAM_NAME_13"
mkdir -p "$TASK_DIR_13"
echo '{"status": "completed"}' > "$TASK_DIR_13/task-1.json"
echo '{"status": "completed"}' > "$TASK_DIR_13/task-2.json"

run_hook "{\"team_name\": \"$TEAM_NAME_13\", \"teammate_name\": \"smith-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "All tasks done exits 0" "0" "$(get_exit_code)"

# Check signal file was written
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SIGNAL_DIR_13/all-tasks-done" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: all-tasks-done signal file created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: all-tasks-done signal file not created\n"
fi

# 13b. Verify the signal file is valid JSON with expected fields
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if jq -e '.timestamp and .config_dir and .owner_pid' "$SIGNAL_DIR_13/all-tasks-done" >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: all-tasks-done signal is valid JSON with expected fields\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: all-tasks-done signal JSON structure invalid\n"
fi

# 13c. Not all tasks done — no signal
TEAM_NAME_13B="rune-work-notdone13"
SIGNAL_DIR_13B="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_13B"
mkdir -p "$SIGNAL_DIR_13B"
mkdir -p "$FAKE_CONFIG_DIR/teams/$TEAM_NAME_13B"
TASK_DIR_13B="$FAKE_CONFIG_DIR/tasks/$TEAM_NAME_13B"
mkdir -p "$TASK_DIR_13B"
echo '{"status": "completed"}' > "$TASK_DIR_13B/task-1.json"
echo '{"status": "in_progress"}' > "$TASK_DIR_13B/task-2.json"

run_hook "{\"team_name\": \"$TEAM_NAME_13B\", \"teammate_name\": \"smith-1\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Incomplete tasks exits 0" "0" "$(get_exit_code)"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$SIGNAL_DIR_13B/all-tasks-done" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No all-tasks-done signal for incomplete tasks\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: all-tasks-done signal created despite incomplete tasks\n"
fi

# ═══════════════════════════════════════════════════════════════
# 14. Absolute Path in output_file → Block (SEC-003)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Absolute Path in output_file ===\n"

TEAM_NAME_14="rune-review-abs14"
SIGNAL_DIR_14="$FAKE_CWD/tmp/.rune-signals/$TEAM_NAME_14"
mkdir -p "$SIGNAL_DIR_14"
mkdir -p "$FAKE_CONFIG_DIR/teams/$TEAM_NAME_14"
cat > "$SIGNAL_DIR_14/inscription.json" <<'INSC14'
{
  "team_name": "rune-review-abs14",
  "output_dir": "tmp/reviews/abs14/",
  "teammates": [
    {"name": "evil", "output_file": "/etc/passwd"}
  ]
}
INSC14

run_hook "{\"team_name\": \"$TEAM_NAME_14\", \"teammate_name\": \"evil\", \"cwd\": \"$FAKE_CWD\"}"
assert_eq "Absolute output_file path exits 2" "2" "$(get_exit_code)"

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
