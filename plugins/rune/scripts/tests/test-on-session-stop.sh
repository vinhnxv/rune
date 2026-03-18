#!/usr/bin/env bash
# test-on-session-stop.sh — Tests for scripts/on-session-stop.sh
#
# Usage: bash plugins/rune/scripts/tests/test-on-session-stop.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/on-session-stop.sh"

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
# Canonicalize to handle macOS /var -> /private/var symlink
TMPWORK=$(cd "$TMPWORK_RAW" && pwd -P)
trap 'rm -rf "$TMPWORK"' EXIT

FAKE_CWD="$TMPWORK/project"
mkdir -p "$FAKE_CWD/tmp"
mkdir -p "$FAKE_CWD/.rune/arc"

FAKE_CONFIG_DIR="$TMPWORK/claude-config"
mkdir -p "$FAKE_CONFIG_DIR/teams"
mkdir -p "$FAKE_CONFIG_DIR/tasks"

# Use a known-dead PID for ownership fields. The hook checks:
#   if owner_pid != PPID && owner_pid is alive -> skip (foreign session)
#   if owner_pid != PPID && owner_pid is dead -> proceed (orphaned state)
# We use PID 99999 which is almost certainly dead.
DEAD_PID="99999"
# Verify it is actually dead (if not, find one that is)
if kill -0 "$DEAD_PID" 2>/dev/null; then
  DEAD_PID="99998"
fi

# Helper: run the hook with given JSON input
# Uses RUNE_CLEANUP_DRY_RUN=1 to prevent actual process kills during testing
run_hook() {
  local input="$1"
  local dry_run="${2:-1}"
  local exit_code=0
  local stdout stderr
  stdout=$(printf '%s' "$input" | \
    CLAUDE_CONFIG_DIR="$FAKE_CONFIG_DIR" \
    RUNE_TRACE="" \
    RUNE_CLEANUP_DRY_RUN="$dry_run" \
    TMPDIR="$TMPWORK/tmp-session" \
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

# 1b. Invalid JSON exits 0 (fail-forward via jq guard)
run_hook "not-json"
assert_eq "Invalid JSON exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 2. Missing CWD
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing CWD ===\n"

# 2a. Missing CWD exits 0
run_hook '{"stop_hook_active": false}'
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code)"

# 2b. Non-existent CWD exits 0
run_hook '{"cwd": "/nonexistent/path/xyz"}'
assert_eq "Non-existent CWD exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 3. Loop Prevention (stop_hook_active)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Loop Prevention ===\n"

# 3a. stop_hook_active: true -> immediate exit 0
run_hook "{\"stop_hook_active\": true, \"cwd\": \"$FAKE_CWD\"}"
assert_eq "stop_hook_active=true exits 0 (no re-entry)" "0" "$(get_exit_code)"
STDOUT_3=$(get_stdout)
assert_not_contains "Loop prevention produces no cleanup output" "STOP-001" "$STDOUT_3"

# ═══════════════════════════════════════════════════════════════
# 4. Nothing To Clean -> Silent Exit
# ═══════════════════════════════════════════════════════════════
printf "\n=== Nothing To Clean ===\n"

# Clean environment -- no teams, no state files, no arcs
run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Nothing to clean exits 0" "0" "$(get_exit_code)"
STDOUT_4=$(get_stdout)
assert_not_contains "Silent exit when nothing to clean" "STOP-001" "$STDOUT_4"

# ═══════════════════════════════════════════════════════════════
# 5. Phase 1: Team Directory Cleanup (With State File)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase 1: Team Directory Cleanup ===\n"

# Create team dirs
TEAM_DIR_5="$FAKE_CONFIG_DIR/teams/rune-review-test5"
TASK_DIR_5="$FAKE_CONFIG_DIR/tasks/rune-review-test5"
mkdir -p "$TEAM_DIR_5" "$TASK_DIR_5"

# Create matching active state file with dead PID (so hook treats as orphaned / owned by us)
jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{status: "active", team_name: "rune-review-test5", config_dir: $cfg, owner_pid: $pid}' \
  > "$FAKE_CWD/tmp/.rune-review-test5.json"

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Team cleanup exits 2 (stderr prompt)" "2" "$(get_exit_code)"
STDERR_5=$(get_stderr)
assert_contains "Report mentions cleaned teams" "Teams:" "$STDERR_5"
assert_contains "Report mentions team name" "rune-review-test5" "$STDERR_5"

# In dry-run mode, team dirs still exist
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$TEAM_DIR_5" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Dry-run preserves team dir\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Dry-run should preserve team dir\n"
fi

# ═══════════════════════════════════════════════════════════════
# 6. Phase 1: Orphan Team Cleanup (No State File, Old Dir)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase 1: Orphan Team Cleanup ===\n"

# Remove state file from previous test
rm -f "$FAKE_CWD/tmp/.rune-review-test5.json"

# Create an old team dir (> 30 min old), no state file
ORPHAN_DIR="$FAKE_CONFIG_DIR/teams/rune-orphan-test6"
mkdir -p "$ORPHAN_DIR"
touch -t 202601010000 "$ORPHAN_DIR" 2>/dev/null || true

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Orphan team cleanup exits 2 (stderr prompt)" "2" "$(get_exit_code)"
STDERR_6=$(get_stderr)
assert_contains "Report includes orphan cleanup" "rune-orphan-test6" "$STDERR_6"

# ═══════════════════════════════════════════════════════════════
# 7. Phase 1: Non-Rune Team Dirs Ignored
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase 1: Non-Rune Team Ignored ===\n"

# Clean previous test state
rm -rf "$FAKE_CONFIG_DIR/teams/rune-"* "$FAKE_CONFIG_DIR/teams/arc-"* 2>/dev/null || true

NON_RUNE_DIR="$FAKE_CONFIG_DIR/teams/some-other-team"
mkdir -p "$NON_RUNE_DIR"

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Non-rune team ignored exits 0" "0" "$(get_exit_code)"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$NON_RUNE_DIR" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Non-rune team dir preserved\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Non-rune team dir should be preserved\n"
fi

rm -rf "$NON_RUNE_DIR"

# ═══════════════════════════════════════════════════════════════
# 8. Phase 2: State File Status Update (active -> stopped)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase 2: State File Cleanup ===\n"

# Clean up
rm -rf "$FAKE_CONFIG_DIR/teams/rune-"* "$FAKE_CONFIG_DIR/tasks/rune-"* 2>/dev/null || true

# Create an active state file with dead PID
jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{status: "active", team_name: "rune-review-state8", config_dir: $cfg, owner_pid: $pid}' \
  > "$FAKE_CWD/tmp/.rune-review-state8.json"

# Run in NON-dry-run mode to verify actual state file update
run_hook "{\"cwd\": \"$FAKE_CWD\"}" "0"
assert_eq "State cleanup exits 2 (stderr prompt)" "2" "$(get_exit_code)"

# Verify status was updated to "stopped"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
STATE_STATUS=$(jq -r '.status' "$FAKE_CWD/tmp/.rune-review-state8.json" 2>/dev/null || echo "error")
if [[ "$STATE_STATUS" == "stopped" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: State file status updated to 'stopped'\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: State file status is '%s', expected 'stopped'\n" "$STATE_STATUS"
fi

# Verify stopped_by field
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
STOPPED_BY=$(jq -r '.stopped_by' "$FAKE_CWD/tmp/.rune-review-state8.json" 2>/dev/null || echo "error")
if [[ "$STOPPED_BY" == "STOP-001" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: State file stopped_by is STOP-001\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: State file stopped_by is '%s', expected 'STOP-001'\n" "$STOPPED_BY"
fi

rm -f "$FAKE_CWD/tmp/.rune-review-state8.json"

# ═══════════════════════════════════════════════════════════════
# 9. Phase 2: Completed State Files Not Touched
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase 2: Completed State Untouched ===\n"

jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{status: "completed", team_name: "rune-review-done9", config_dir: $cfg, owner_pid: $pid}' \
  > "$FAKE_CWD/tmp/.rune-review-done9.json"

run_hook "{\"cwd\": \"$FAKE_CWD\"}" "0"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
DONE_STATUS=$(jq -r '.status' "$FAKE_CWD/tmp/.rune-review-done9.json" 2>/dev/null || echo "error")
if [[ "$DONE_STATUS" == "completed" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Completed state file not modified\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Completed state file was modified to '%s'\n" "$DONE_STATUS"
fi

rm -f "$FAKE_CWD/tmp/.rune-review-done9.json"

# ═══════════════════════════════════════════════════════════════
# 10. Phase 3: Arc Checkpoint Cleanup
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase 3: Arc Checkpoint Cleanup ===\n"

ARC_DIR_10="$FAKE_CWD/.rune/arc/arc-test-stop10"
mkdir -p "$ARC_DIR_10"
jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{config_dir: $cfg, owner_pid: $pid, phases: {forge: {status: "completed"}, review: {status: "in_progress"}, ship: {status: "pending"}}}' \
  > "$ARC_DIR_10/checkpoint.json"

# Backdate so it passes the 5-min age check
touch -t 202601010000 "$ARC_DIR_10/checkpoint.json" 2>/dev/null || true

run_hook "{\"cwd\": \"$FAKE_CWD\"}" "0"
assert_eq "Arc checkpoint cleanup exits 2 (stderr prompt)" "2" "$(get_exit_code)"

# Verify in_progress phases were cancelled
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
REVIEW_STATUS=$(jq -r '.phases.review.status' "$ARC_DIR_10/checkpoint.json" 2>/dev/null || echo "error")
if [[ "$REVIEW_STATUS" == "cancelled" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: in_progress phase cancelled\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: in_progress phase status is '%s', expected 'cancelled'\n" "$REVIEW_STATUS"
fi

# Verify completed phases unchanged
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
FORGE_STATUS=$(jq -r '.phases.forge.status' "$ARC_DIR_10/checkpoint.json" 2>/dev/null || echo "error")
if [[ "$FORGE_STATUS" == "completed" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: completed phase unchanged\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: completed phase changed to '%s'\n" "$FORGE_STATUS"
fi

# ═══════════════════════════════════════════════════════════════
# 11. Phase 3: Recent Arc Checkpoints Not Touched
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase 3: Recent Arc Checkpoint Preserved ===\n"

ARC_DIR_11="$FAKE_CWD/.rune/arc/arc-test-recent11"
mkdir -p "$ARC_DIR_11"
jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{config_dir: $cfg, owner_pid: $pid, phases: {forge: {status: "in_progress"}}}' \
  > "$ARC_DIR_11/checkpoint.json"
# Do NOT backdate -- it should be skipped due to age < 5 min

run_hook "{\"cwd\": \"$FAKE_CWD\"}" "0"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
RECENT_STATUS=$(jq -r '.phases.forge.status' "$ARC_DIR_11/checkpoint.json" 2>/dev/null || echo "error")
if [[ "$RECENT_STATUS" == "in_progress" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Recent arc checkpoint preserved (< 5 min)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Recent arc checkpoint was modified to '%s'\n" "$RECENT_STATUS"
fi

rm -rf "$ARC_DIR_11"

# ═══════════════════════════════════════════════════════════════
# 12. Session Ownership: Skip Foreign State Files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Session Ownership Filtering ===\n"

# Create state file owned by a different config_dir
jq -n --arg cfg "/different/config/dir" --arg pid "$DEAD_PID" \
  '{status: "active", team_name: "rune-review-foreign12", config_dir: $cfg, owner_pid: $pid}' \
  > "$FAKE_CWD/tmp/.rune-review-foreign12.json"

run_hook "{\"cwd\": \"$FAKE_CWD\"}" "0"

# State should remain active (not touched due to config_dir mismatch)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
FOREIGN_STATUS=$(jq -r '.status' "$FAKE_CWD/tmp/.rune-review-foreign12.json" 2>/dev/null || echo "error")
if [[ "$FOREIGN_STATUS" == "active" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Foreign session state file preserved\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Foreign session state file modified to '%s'\n" "$FOREIGN_STATUS"
fi

rm -f "$FAKE_CWD/tmp/.rune-review-foreign12.json"

# ═══════════════════════════════════════════════════════════════
# 13. Cleanup Report Format
# ═══════════════════════════════════════════════════════════════
printf "\n=== Cleanup Report Format ===\n"

# Create teams and state file for a full report
TEAM_DIR_13="$FAKE_CONFIG_DIR/teams/rune-review-rpt13"
TASK_DIR_13="$FAKE_CONFIG_DIR/tasks/rune-review-rpt13"
mkdir -p "$TEAM_DIR_13" "$TASK_DIR_13"

jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{status: "active", team_name: "rune-review-rpt13", config_dir: $cfg, owner_pid: $pid}' \
  > "$FAKE_CWD/tmp/.rune-review-rpt13.json"

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Report cleanup exits 2 (stderr prompt)" "2" "$(get_exit_code)"
STDERR_13=$(get_stderr)
assert_contains "Report starts with STOP-001" "STOP-001" "$STDERR_13"
assert_contains "Report mentions AUTO-CLEANUP" "AUTO-CLEANUP" "$STDERR_13"

rm -f "$FAKE_CWD/tmp/.rune-review-rpt13.json"

# ═══════════════════════════════════════════════════════════════
# 14. Shutdown Signal File Cleanup
# ═══════════════════════════════════════════════════════════════
printf "\n=== Shutdown Signal Cleanup ===\n"

# Create a shutdown signal file with dead PID (orphaned = owned by us)
jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{config_dir: $cfg, owner_pid: $pid, reason: "test"}' \
  > "$FAKE_CWD/tmp/.rune-shutdown-signal-test14.json"

run_hook "{\"cwd\": \"$FAKE_CWD\"}" "0"
assert_eq "Shutdown signal cleanup exits 0" "0" "$(get_exit_code)"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$FAKE_CWD/tmp/.rune-shutdown-signal-test14.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Shutdown signal file removed\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Shutdown signal file should have been removed\n"
fi

# ═══════════════════════════════════════════════════════════════
# 15. Force Shutdown Signal File Cleanup
# ═══════════════════════════════════════════════════════════════
printf "\n=== Force Shutdown Signal Cleanup ===\n"

jq -n --arg cfg "$FAKE_CONFIG_DIR" --arg pid "$DEAD_PID" \
  '{config_dir: $cfg, owner_pid: $pid, reason: "test"}' \
  > "$FAKE_CWD/tmp/.rune-force-shutdown-test15.json"

run_hook "{\"cwd\": \"$FAKE_CWD\"}" "0"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$FAKE_CWD/tmp/.rune-force-shutdown-test15.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Force shutdown signal file removed\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Force shutdown signal file should have been removed\n"
fi

# ═══════════════════════════════════════════════════════════════
# 16. GUARD 5d: Phase Loop Deferral (Active Phase)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Phase Loop Deferral ===\n"

# Create an active phase loop file with dead PID (treated as owned).
# The hook's _check_loop_ownership reads YAML frontmatter for config_dir and owner_pid.
# With a dead PID, the ownership check passes (orphaned state -> proceed).
# But since active=true and file is recent, the hook will defer (exit 0).
# We need a PID that is NOT dead for deferral -- we need the hook to think this
# is the current session's file. Use no owner_pid so the check passes.
cat > "$FAKE_CWD/.rune/arc-phase-loop.local.md" <<EOF
---
active: true
config_dir: $FAKE_CONFIG_DIR
---
Phase loop content
EOF

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Active phase loop defers (exits 0)" "0" "$(get_exit_code)"
STDOUT_16=$(get_stdout)
# Should exit early -- no cleanup report
assert_not_contains "Phase loop defer produces no cleanup" "STOP-001" "$STDOUT_16"

rm -f "$FAKE_CWD/.rune/arc-phase-loop.local.md"

# ═══════════════════════════════════════════════════════════════
# 17. GUARD 5d: Stale Phase Loop Cleaned Up
# ═══════════════════════════════════════════════════════════════
printf "\n=== Stale Phase Loop Cleanup ===\n"

cat > "$FAKE_CWD/.rune/arc-phase-loop.local.md" <<EOF
---
active: true
config_dir: $FAKE_CONFIG_DIR
owner_pid: $DEAD_PID
---
Stale phase loop
EOF
# Backdate to be stale (> 90 min)
touch -t 202601010000 "$FAKE_CWD/.rune/arc-phase-loop.local.md" 2>/dev/null || true

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Stale phase loop cleanup exits 0" "0" "$(get_exit_code)"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$FAKE_CWD/.rune/arc-phase-loop.local.md" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Stale phase loop file removed\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Stale phase loop file should have been removed\n"
fi

# ═══════════════════════════════════════════════════════════════
# 18. GUARD 5: Batch Loop Deferral
# ═══════════════════════════════════════════════════════════════
printf "\n=== Batch Loop Deferral ===\n"

# Omit owner_pid so ownership check passes, active=true + recent -> defer
cat > "$FAKE_CWD/.rune/arc-batch-loop.local.md" <<EOF
---
active: true
config_dir: $FAKE_CONFIG_DIR
---
Batch loop content
EOF

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Active batch loop defers (exits 0)" "0" "$(get_exit_code)"
STDOUT_18=$(get_stdout)
assert_not_contains "Batch loop defer produces no cleanup" "STOP-001" "$STDOUT_18"

rm -f "$FAKE_CWD/.rune/arc-batch-loop.local.md"

# ═══════════════════════════════════════════════════════════════
# 19. Inactive Loop File Cleaned Up
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inactive Loop File Cleanup ===\n"

cat > "$FAKE_CWD/.rune/arc-batch-loop.local.md" <<EOF
---
active: false
config_dir: $FAKE_CONFIG_DIR
owner_pid: $DEAD_PID
---
Completed batch loop
EOF

run_hook "{\"cwd\": \"$FAKE_CWD\"}"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$FAKE_CWD/.rune/arc-batch-loop.local.md" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Inactive batch loop file removed\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Inactive batch loop file should have been removed\n"
fi

# ═══════════════════════════════════════════════════════════════
# 20. Goldmask Team Cleanup
# ═══════════════════════════════════════════════════════════════
printf "\n=== Goldmask Team Cleanup ===\n"

# Clean up previous
rm -rf "$FAKE_CONFIG_DIR/teams/rune-"* "$FAKE_CONFIG_DIR/teams/arc-"* "$FAKE_CONFIG_DIR/teams/goldmask-"* 2>/dev/null || true

GOLDMASK_DIR="$FAKE_CONFIG_DIR/teams/goldmask-test20"
mkdir -p "$GOLDMASK_DIR"
touch -t 202601010000 "$GOLDMASK_DIR" 2>/dev/null || true

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
STDERR_20=$(get_stderr)
assert_contains "Goldmask team included in cleanup" "goldmask-test20" "$STDERR_20"

# ═══════════════════════════════════════════════════════════════
# 21. Symlink Guards
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Guards ===\n"

# Clean up
rm -rf "$FAKE_CONFIG_DIR/teams/rune-"* "$FAKE_CONFIG_DIR/teams/arc-"* "$FAKE_CONFIG_DIR/teams/goldmask-"* 2>/dev/null || true

# Create a symlink team dir -- should be skipped
mkdir -p "$TMPWORK/evil-target"
ln -sf "$TMPWORK/evil-target" "$FAKE_CONFIG_DIR/teams/rune-symlink-test21" 2>/dev/null || true

run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Symlink team dir exits 0" "0" "$(get_exit_code)"

# The evil target should not be affected
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$TMPWORK/evil-target" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink target preserved\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Symlink target should not be removed\n"
fi

rm -f "$FAKE_CONFIG_DIR/teams/rune-symlink-test21"

# ═══════════════════════════════════════════════════════════════
# 22. Exit Codes (exit 0 when nothing to clean, exit 2 when cleanup done)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Exit Codes ===\n"

# Clean all residual state from previous tests
rm -rf "$FAKE_CONFIG_DIR/teams/rune-"* "$FAKE_CONFIG_DIR/teams/arc-"* "$FAKE_CONFIG_DIR/teams/goldmask-"* 2>/dev/null || true
rm -rf "$FAKE_CONFIG_DIR/tasks/rune-"* "$FAKE_CONFIG_DIR/tasks/arc-"* 2>/dev/null || true
rm -f "$FAKE_CWD"/tmp/.rune-*.json 2>/dev/null || true
rm -rf "$FAKE_CWD/.rune/arc/"* 2>/dev/null || true

# No cleanup needed -- exits 0
run_hook "{\"cwd\": \"$FAKE_CWD\"}"
assert_eq "Normal case exits 0" "0" "$(get_exit_code)"

run_hook ""
assert_eq "Empty input exits 0" "0" "$(get_exit_code)"

run_hook "{\"cwd\": \"$FAKE_CWD\", \"stop_hook_active\": true}"
assert_eq "Loop prevention exits 0" "0" "$(get_exit_code)"

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
