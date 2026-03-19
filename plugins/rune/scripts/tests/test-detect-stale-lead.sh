#!/usr/bin/env bash
# test-detect-stale-lead.sh — Tests for scripts/detect-stale-lead.sh
#
# Usage: bash plugins/rune/scripts/tests/test-detect-stale-lead.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/detect-stale-lead.sh"

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
mkdir -p "$MOCK_CWD/.claude"
mkdir -p "$MOCK_CWD/.rune"

MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME/teams"
mkdir -p "$MOCK_CHOME/tasks"

# Resolve paths (macOS: /tmp → /private/tmp symlink)
MOCK_CWD=$(cd "$MOCK_CWD" && pwd -P)
MOCK_CHOME=$(cd "$MOCK_CHOME" && pwd -P)

# Helper: run the hook with mock env, capture exit code + stderr
run_hook() {
  local stdin_content="${1:-}"
  local extra_env="${2:-}"
  local rc=0
  local stderr_out
  stderr_out=$(eval "$extra_env" CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
    bash "$UNDER_TEST" <<< "$stdin_content" 2>&1 >/dev/null) || rc=$?
  printf '%s' "$stderr_out"
  return "$rc"
}

# ═══════════════════════════════════════════════════════════════
# 1. Fast path — no state files → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fast Path: No State Files ===\n"

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "No state files → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 2. Fast path — no jq → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fast Path: No jq ===\n"

# Create a state file so we get past the first guard
cat > "$MOCK_CWD/tmp/.rune-review-test.json" <<JSON
{"status":"running","team_name":"rune-review-test","config_dir":"$MOCK_CHOME","owner_pid":"$PPID"}
JSON
mkdir -p "$MOCK_CHOME/teams/rune-review-test"

result_code=0
PATH="/nonexistent" CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "No jq in PATH → exit 0 (fail-forward)" "0" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-review-test.json"
rm -rf "$MOCK_CHOME/teams/rune-review-test"

# ═══════════════════════════════════════════════════════════════
# 3. Method A — .all-done sentinel → exit 2 (WAKE)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Method A: .all-done Sentinel ===\n"

TEAM_A="rune-review-methoda"
mkdir -p "$MOCK_CHOME/teams/$TEAM_A"
mkdir -p "$MOCK_CHOME/tasks/$TEAM_A"
mkdir -p "$MOCK_CWD/tmp/.rune-signals/$TEAM_A"

cat > "$MOCK_CWD/tmp/.rune-review-methoda.json" <<JSON
{"status":"running","team_name":"$TEAM_A","config_dir":"$MOCK_CHOME","owner_pid":"$PPID","workflow_type":"review","output_dir":"tmp/reviews/latest"}
JSON

# Write the .all-done sentinel
touch "$MOCK_CWD/tmp/.rune-signals/$TEAM_A/.all-done"

result_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null 2>&1 >/dev/null) || result_code=$?
assert_eq "Method A: .all-done → exit 2 (wake)" "2" "$result_code"
assert_contains "Method A: wake message mentions completed" "completed" "$stderr_out"

rm -f "$MOCK_CWD/tmp/.rune-review-methoda.json"
rm -rf "$MOCK_CWD/tmp/.rune-signals/$TEAM_A"
rm -rf "$MOCK_CHOME/teams/$TEAM_A" "$MOCK_CHOME/tasks/$TEAM_A"

# ═══════════════════════════════════════════════════════════════
# 4. Method B — .done count matches .expected → exit 2
# ═══════════════════════════════════════════════════════════════
printf "\n=== Method B: .done Count Match ===\n"

TEAM_B="rune-review-methodb"
mkdir -p "$MOCK_CHOME/teams/$TEAM_B"
mkdir -p "$MOCK_CHOME/tasks/$TEAM_B"
SIGNAL_DIR_B="$MOCK_CWD/tmp/.rune-signals/$TEAM_B"
mkdir -p "$SIGNAL_DIR_B"

cat > "$MOCK_CWD/tmp/.rune-review-methodb.json" <<JSON
{"status":"running","team_name":"$TEAM_B","config_dir":"$MOCK_CHOME","owner_pid":"$PPID","workflow_type":"review","output_dir":"tmp/reviews/latest"}
JSON

# Write .expected count = 3, and 3 .done files
echo "3" > "$SIGNAL_DIR_B/.expected"
touch "$SIGNAL_DIR_B/agent-1.done"
touch "$SIGNAL_DIR_B/agent-2.done"
touch "$SIGNAL_DIR_B/agent-3.done"

result_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null 2>&1 >/dev/null) || result_code=$?
assert_eq "Method B: .done count == .expected → exit 2" "2" "$result_code"
assert_contains "Method B: wake message present" "completed" "$stderr_out"

rm -f "$MOCK_CWD/tmp/.rune-review-methodb.json"
rm -rf "$SIGNAL_DIR_B"
rm -rf "$MOCK_CHOME/teams/$TEAM_B" "$MOCK_CHOME/tasks/$TEAM_B"

# ═══════════════════════════════════════════════════════════════
# 5. Method C — all task files completed → exit 2
# ═══════════════════════════════════════════════════════════════
printf "\n=== Method C: All Task Files Completed ===\n"

TEAM_C="rune-review-methodc"
mkdir -p "$MOCK_CHOME/teams/$TEAM_C"
TASK_DIR_C="$MOCK_CHOME/tasks/$TEAM_C"
mkdir -p "$TASK_DIR_C"
mkdir -p "$MOCK_CWD/tmp/.rune-signals/$TEAM_C"

cat > "$MOCK_CWD/tmp/.rune-review-methodc.json" <<JSON
{"status":"running","team_name":"$TEAM_C","config_dir":"$MOCK_CHOME","owner_pid":"$PPID","workflow_type":"review","output_dir":"tmp/reviews/latest"}
JSON

# Write task files — all completed
cat > "$TASK_DIR_C/task-1.json" <<JSON
{"id":"1","status":"completed","owner":"agent-1"}
JSON
cat > "$TASK_DIR_C/task-2.json" <<JSON
{"id":"2","status":"completed","owner":"agent-2"}
JSON
cat > "$TASK_DIR_C/task-3.json" <<JSON
{"id":"3","status":"deleted","owner":"agent-3"}
JSON

result_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null 2>&1 >/dev/null) || result_code=$?
assert_eq "Method C: all tasks completed/deleted → exit 2" "2" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-review-methodc.json"
rm -rf "$MOCK_CWD/tmp/.rune-signals/$TEAM_C"
rm -rf "$MOCK_CHOME/teams/$TEAM_C" "$TASK_DIR_C"

# ═══════════════════════════════════════════════════════════════
# 6. Method D — no processes + tasks in_progress → exit 2 (CRASHED)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Method D: Crashed Teammates (Liveness) ===\n"

TEAM_D="rune-review-methodd"
mkdir -p "$MOCK_CHOME/teams/$TEAM_D"
TASK_DIR_D="$MOCK_CHOME/tasks/$TEAM_D"
mkdir -p "$TASK_DIR_D"
mkdir -p "$MOCK_CWD/tmp/.rune-signals/$TEAM_D"

cat > "$MOCK_CWD/tmp/.rune-review-methodd.json" <<JSON
{"status":"running","team_name":"$TEAM_D","config_dir":"$MOCK_CHOME","owner_pid":"$PPID","workflow_type":"review","output_dir":"tmp/reviews/latest"}
JSON

# Write task files — some still in_progress but NO teammate processes
cat > "$TASK_DIR_D/task-1.json" <<JSON
{"id":"1","status":"completed","owner":"agent-1"}
JSON
cat > "$TASK_DIR_D/task-2.json" <<JSON
{"id":"2","status":"in_progress","owner":"agent-2"}
JSON

# No .all-done, no .expected/.done files, not all tasks completed
# AND no child processes → Method D should fire (CRASHED mode)

result_code=0
stderr_out=""
stderr_out=$(CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null 2>&1 >/dev/null) || result_code=$?
assert_eq "Method D: no processes + in_progress → exit 2 (CRASHED)" "2" "$result_code"
assert_contains "Method D: wake message warns about crash" "crashed" "$stderr_out"

rm -f "$MOCK_CWD/tmp/.rune-review-methodd.json"
rm -rf "$MOCK_CWD/tmp/.rune-signals/$TEAM_D"
rm -rf "$MOCK_CHOME/teams/$TEAM_D" "$TASK_DIR_D"

# ═══════════════════════════════════════════════════════════════
# 7. Debounce — marker exists → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Debounce: Already Woken ===\n"

TEAM_DB="rune-review-debounce"
mkdir -p "$MOCK_CHOME/teams/$TEAM_DB"
mkdir -p "$MOCK_CHOME/tasks/$TEAM_DB"
SIGNAL_DIR_DB="$MOCK_CWD/tmp/.rune-signals/$TEAM_DB"
mkdir -p "$SIGNAL_DIR_DB"

cat > "$MOCK_CWD/tmp/.rune-review-debounce.json" <<JSON
{"status":"running","team_name":"$TEAM_DB","config_dir":"$MOCK_CHOME","owner_pid":"$PPID","workflow_type":"review","output_dir":"tmp/reviews/latest"}
JSON

# Write .all-done so detection would fire, BUT also write debounce marker
touch "$SIGNAL_DIR_DB/.all-done"
cat > "$SIGNAL_DIR_DB/.lead-woken" <<JSON
{"owner_pid":"$PPID","session_id":"test","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","wake_mode":"COMPLETE"}
JSON

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Debounce: marker exists → exit 0 (skip)" "0" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-review-debounce.json"
rm -rf "$SIGNAL_DIR_DB"
rm -rf "$MOCK_CHOME/teams/$TEAM_DB" "$MOCK_CHOME/tasks/$TEAM_DB"

# ═══════════════════════════════════════════════════════════════
# 8. Session isolation — different config_dir → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Session Isolation: Config Dir Mismatch ===\n"

TEAM_ISO="rune-review-isolation"
mkdir -p "$MOCK_CHOME/teams/$TEAM_ISO"
mkdir -p "$MOCK_CWD/tmp/.rune-signals/$TEAM_ISO"

cat > "$MOCK_CWD/tmp/.rune-review-isolation.json" <<JSON
{"status":"running","team_name":"$TEAM_ISO","config_dir":"/some/other/config","owner_pid":"$PPID","workflow_type":"review"}
JSON
touch "$MOCK_CWD/tmp/.rune-signals/$TEAM_ISO/.all-done"

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Foreign config_dir → exit 0 (skip)" "0" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-review-isolation.json"
rm -rf "$MOCK_CWD/tmp/.rune-signals/$TEAM_ISO"
rm -rf "$MOCK_CHOME/teams/$TEAM_ISO"

# ═══════════════════════════════════════════════════════════════
# 9. Arc defer — active arc loop → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Arc Defer: Active Arc Loop ===\n"

cat > "$MOCK_CWD/.rune/arc-phase-loop.local.md" <<ARCSTATE
---
active: true
current_phase: forge
status: running
---
ARCSTATE

# Create a state file + signals so detection WOULD fire
TEAM_ARC="rune-review-arcdefer"
mkdir -p "$MOCK_CHOME/teams/$TEAM_ARC"
mkdir -p "$MOCK_CWD/tmp/.rune-signals/$TEAM_ARC"

cat > "$MOCK_CWD/tmp/.rune-review-arcdefer.json" <<JSON
{"status":"running","team_name":"$TEAM_ARC","config_dir":"$MOCK_CHOME","owner_pid":"$PPID","workflow_type":"review"}
JSON
touch "$MOCK_CWD/tmp/.rune-signals/$TEAM_ARC/.all-done"

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Active arc loop → exit 0 (defer)" "0" "$result_code"

rm -f "$MOCK_CWD/.rune/arc-phase-loop.local.md"
rm -f "$MOCK_CWD/tmp/.rune-review-arcdefer.json"
rm -rf "$MOCK_CWD/tmp/.rune-signals/$TEAM_ARC"
rm -rf "$MOCK_CHOME/teams/$TEAM_ARC"

# ═══════════════════════════════════════════════════════════════
# 10. Fail-forward — malformed JSON state file → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fail-forward: Malformed JSON ===\n"

cat > "$MOCK_CWD/tmp/.rune-review-malformed.json" <<JSON
{this is not valid json at all!!!
JSON

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" \
  bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Malformed JSON state file → exit 0 (fail-forward)" "0" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-review-malformed.json"

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
