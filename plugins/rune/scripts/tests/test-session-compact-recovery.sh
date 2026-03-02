#!/usr/bin/env bash
# test-session-compact-recovery.sh — Tests for scripts/session-compact-recovery.sh
#
# Usage: bash plugins/rune/scripts/tests/test-session-compact-recovery.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/session-compact-recovery.sh"

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

# Create mock project dir with tmp/
MOCK_CWD="$TMP_DIR/project"
mkdir -p "$MOCK_CWD/tmp"
mkdir -p "$MOCK_CWD/.claude"

# Create mock CLAUDE_CONFIG_DIR with teams
MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME"

# Resolve paths (macOS: /tmp → /private/tmp symlink)
MOCK_CWD=$(cd "$MOCK_CWD" && pwd -P)
MOCK_CHOME=$(cd "$MOCK_CHOME" && pwd -P)

# ═══════════════════════════════════════════════════════════════
# 1. Guard: non-compact trigger
# ═══════════════════════════════════════════════════════════════
printf "\n=== Guard: Non-compact Trigger ===\n"

# 1a. Exit 0 silently when trigger != compact
result=$(echo '{"trigger":"startup","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Non-compact trigger produces no output" "" "$result"

# 1b. Exit 0 when trigger is missing
result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Missing trigger produces no output" "" "$result"

# ═══════════════════════════════════════════════════════════════
# 2. Guard: missing checkpoint
# ═══════════════════════════════════════════════════════════════
printf "\n=== Guard: Missing Checkpoint ===\n"

# 2a. No checkpoint file → exit 0 silently
result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "No checkpoint produces no output" "" "$result"

# ═══════════════════════════════════════════════════════════════
# 3. Guard: empty team name
# ═══════════════════════════════════════════════════════════════
printf "\n=== Guard: Empty Team Name ===\n"

# 3a. Checkpoint with empty team_name and no loop state → cleanup + exit 0
# NOTE: Omit owner_pid to trigger legacy fail-open path (script skips ownership check
# when owner_pid is missing, per design: "missing fields = legacy checkpoint → allow recovery")
cat > "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" <<JSON
{"team_name":"","saved_at":"2026-01-01T00:00:00Z","config_dir":"$MOCK_CHOME"}
JSON
result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Empty team name → no output (silent cleanup)" "" "$result"

# Checkpoint should be deleted
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Checkpoint deleted on empty team\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Checkpoint NOT deleted on empty team\n"
fi

# ═══════════════════════════════════════════════════════════════
# 4. Guard: team name prefix filter
# ═══════════════════════════════════════════════════════════════
printf "\n=== Guard: Team Name Prefix Filter ===\n"

# 4a. Non-rune/arc prefix → silent exit
mkdir -p "$MOCK_CHOME/teams/foreign-team"
cat > "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" <<JSON
{"team_name":"foreign-team","saved_at":"2026-01-01T00:00:00Z","config_dir":"$MOCK_CHOME"}
JSON
result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Foreign team prefix produces no output" "" "$result"
rm -rf "$MOCK_CHOME/teams/foreign-team"

# ═══════════════════════════════════════════════════════════════
# 5. Valid team recovery
# ═══════════════════════════════════════════════════════════════
printf "\n=== Valid Team Recovery ===\n"

# 5a. Happy path: valid checkpoint with existing team
# Omit owner_pid to trigger legacy fail-open path
mkdir -p "$MOCK_CHOME/teams/rune-test-team"
cat > "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" <<JSON
{
  "team_name": "rune-test-team",
  "saved_at": "2026-01-15T10:30:00Z",
  "config_dir": "$MOCK_CHOME",
  "team_config": {"members": [{"name": "ash-1"}, {"name": "ash-2"}]},
  "tasks": [{"id": "t1", "status": "completed"}, {"id": "t2", "status": "in_progress"}],
  "workflow_state": {"workflow": "review", "status": "active"},
  "arc_checkpoint": {},
  "arc_batch_state": {},
  "arc_issues_state": {}
}
JSON

result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)

assert_contains "Recovery output has hookSpecificOutput" "hookSpecificOutput" "$result"
assert_contains "Recovery output has SessionStart" "SessionStart" "$result"
assert_contains "Recovery mentions team name" "rune-test-team" "$result"
assert_contains "Recovery mentions member count" "Members: 2" "$result"
assert_contains "Recovery mentions workflow type" "review" "$result"

# 5b. Checkpoint deleted after recovery
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Checkpoint deleted after recovery\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Checkpoint NOT deleted after recovery\n"
fi

# ═══════════════════════════════════════════════════════════════
# 6. Team no longer exists
# ═══════════════════════════════════════════════════════════════
printf "\n=== Team No Longer Exists ===\n"

# 6a. Team dir gone → stale checkpoint notification
rm -rf "$MOCK_CHOME/teams/rune-test-team"
cat > "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" <<JSON
{
  "team_name": "rune-gone-team",
  "saved_at": "2026-01-15T10:30:00Z",
  "config_dir": "$MOCK_CHOME",
  "team_config": {},
  "tasks": [],
  "workflow_state": {},
  "arc_checkpoint": {},
  "arc_batch_state": {},
  "arc_issues_state": {}
}
JSON

result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Stale checkpoint mentions team" "rune-gone-team" "$result"
assert_contains "Stale checkpoint mentions no longer exists" "no longer exists" "$result"

# ═══════════════════════════════════════════════════════════════
# 7. Invalid team name characters
# ═══════════════════════════════════════════════════════════════
printf "\n=== Invalid Team Name ===\n"

cat > "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" <<JSON
{"team_name":"rune/../../../etc/passwd","saved_at":"2026-01-01T00:00:00Z","config_dir":"$MOCK_CHOME"}
JSON
result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Invalid team name chars → silent exit" "" "$result"

# ═══════════════════════════════════════════════════════════════
# 8. Symlink checkpoint guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Guard ===\n"

# Create a real file and symlink to it
echo '{"team_name":"rune-hack"}' > "$TMP_DIR/real-checkpoint.json"
ln -sf "$TMP_DIR/real-checkpoint.json" "$MOCK_CWD/tmp/.rune-compact-checkpoint.json"
result_code=0
result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Symlink checkpoint exits 0" "0" "$result_code"
assert_eq "Symlink checkpoint no output" "" "$result"
rm -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json"

# ═══════════════════════════════════════════════════════════════
# 9. Ownership guard: dead PID allows recovery (orphan recovery)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Ownership: Dead PID → Recovery ===\n"

# Use a PID that is guaranteed dead (99999 is almost certainly not running)
mkdir -p "$MOCK_CHOME/teams/rune-dead-pid-team"
cat > "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" <<JSON
{
  "team_name": "rune-dead-pid-team",
  "saved_at": "2026-01-15T10:30:00Z",
  "config_dir": "$MOCK_CHOME",
  "owner_pid": "99999",
  "team_config": {"members": [{"name": "ash-1"}]},
  "tasks": [],
  "workflow_state": {},
  "arc_checkpoint": {},
  "arc_batch_state": {},
  "arc_issues_state": {}
}
JSON

result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Dead PID recovery has hookSpecificOutput" "hookSpecificOutput" "$result"
assert_contains "Dead PID recovery mentions team" "rune-dead-pid-team" "$result"
rm -rf "$MOCK_CHOME/teams/rune-dead-pid-team"

# ═══════════════════════════════════════════════════════════════
# 10. Config dir mismatch → cleanup + silent exit
# ═══════════════════════════════════════════════════════════════
printf "\n=== Config Dir Mismatch ===\n"

WRONG_CHOME="$TMP_DIR/wrong-config"
mkdir -p "$WRONG_CHOME"
WRONG_CHOME_RESOLVED=$(cd "$WRONG_CHOME" && pwd -P)

cat > "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" <<JSON
{"team_name":"rune-wrong-cfg","saved_at":"2026-01-01T00:00:00Z","config_dir":"$WRONG_CHOME_RESOLVED"}
JSON

result=$(echo '{"trigger":"compact","cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Config dir mismatch → no output" "" "$result"

# Checkpoint should be cleaned up
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Checkpoint cleaned on config dir mismatch\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Checkpoint NOT cleaned on config dir mismatch\n"
fi

# Cleanup
rm -rf "$MOCK_CHOME/teams"

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
