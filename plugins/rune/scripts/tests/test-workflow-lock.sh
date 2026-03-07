#!/usr/bin/env bash
# test-workflow-lock.sh — Tests for scripts/lib/workflow-lock.sh
#
# Usage: bash plugins/rune/scripts/tests/test-workflow-lock.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Temp directory for isolation ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Set up mock environment ──
# Override git root to point to our temp dir so LOCK_BASE is contained
export CLAUDE_CONFIG_DIR="$TMP_DIR/config"
mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_SESSION_ID="test-session-$$"

# Initialize a git repo in TMP_DIR so workflow-lock.sh can resolve git root
git -C "$TMP_DIR" init --quiet 2>/dev/null

# ── Source the library under test ──
# workflow-lock.sh uses SCRIPT_DIR internally for resolve-session-identity.sh,
# so we need to source it from its actual location
# shellcheck source=../lib/workflow-lock.sh
source "$LIB_DIR/workflow-lock.sh"

# Override LOCK_BASE to use our temp dir
LOCK_BASE="$TMP_DIR/tmp/.rune-locks"

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

# ═══════════════════════════════════════════════════════════════
# 1. _rune_validate_workflow_name
# ═══════════════════════════════════════════════════════════════
printf "\n=== _rune_validate_workflow_name ===\n"

# 1a. Valid workflow names
_rune_validate_workflow_name "arc" && rc=0 || rc=1
assert_eq "Valid name: arc" "0" "$rc"

_rune_validate_workflow_name "strive-work" && rc=0 || rc=1
assert_eq "Valid name: strive-work" "0" "$rc"

_rune_validate_workflow_name "batch_123" && rc=0 || rc=1
assert_eq "Valid name: batch_123" "0" "$rc"

_rune_validate_workflow_name "A-Z_0-9" && rc=0 || rc=1
assert_eq "Valid name: A-Z_0-9" "0" "$rc"

# 1b. Invalid workflow names
_rune_validate_workflow_name "" && rc=0 || rc=1
assert_eq "Invalid name: empty string" "1" "$rc"

_rune_validate_workflow_name "has spaces" && rc=0 || rc=1
assert_eq "Invalid name: has spaces" "1" "$rc"

_rune_validate_workflow_name "../traversal" && rc=0 || rc=1
assert_eq "Invalid name: path traversal" "1" "$rc"

_rune_validate_workflow_name "has/slash" && rc=0 || rc=1
assert_eq "Invalid name: has slash" "1" "$rc"

_rune_validate_workflow_name 'inject;cmd' && rc=0 || rc=1
assert_eq "Invalid name: shell metachar" "1" "$rc"

_rune_validate_workflow_name 'with$var' && rc=0 || rc=1
assert_eq "Invalid name: dollar sign" "1" "$rc"

# ═══════════════════════════════════════════════════════════════
# 2. rune_acquire_lock — basic acquisition
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_acquire_lock — basic ===\n"

# Clean lock base before tests
rm -rf "$LOCK_BASE" 2>/dev/null || true

# 2a. First acquire succeeds
rune_acquire_lock "test-wf1" "writer" && rc=0 || rc=1
assert_eq "First acquire succeeds" "0" "$rc"

# 2b. Lock directory was created
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$LOCK_BASE/test-wf1" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Lock directory created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Lock directory not created\n"
fi

# 2c. meta.json exists
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$LOCK_BASE/test-wf1/meta.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: meta.json exists\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: meta.json not found\n"
fi

# 2d. meta.json contains correct workflow name
wf_name=$(jq -r '.workflow' "$LOCK_BASE/test-wf1/meta.json" 2>/dev/null || echo "")
assert_eq "meta.json workflow field" "test-wf1" "$wf_name"

# 2e. meta.json contains correct class
wf_class=$(jq -r '.class' "$LOCK_BASE/test-wf1/meta.json" 2>/dev/null || echo "")
assert_eq "meta.json class field" "writer" "$wf_class"

# 2f. meta.json contains PID
wf_pid=$(jq -r '.pid' "$LOCK_BASE/test-wf1/meta.json" 2>/dev/null || echo "")
assert_eq "meta.json pid is PPID" "$PPID" "$wf_pid"

# 2g. meta.json contains config_dir
wf_cfg=$(jq -r '.config_dir' "$LOCK_BASE/test-wf1/meta.json" 2>/dev/null || echo "")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -n "$wf_cfg" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: meta.json has config_dir\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: meta.json missing config_dir\n"
fi

# 2h. meta.json contains timestamp
wf_ts=$(jq -r '.started' "$LOCK_BASE/test-wf1/meta.json" 2>/dev/null || echo "")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$wf_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: meta.json has ISO timestamp\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: meta.json timestamp format invalid: %s\n" "$wf_ts"
fi

# ═══════════════════════════════════════════════════════════════
# 3. rune_acquire_lock — re-entrant acquisition
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_acquire_lock — re-entrant ===\n"

# 3a. Same workflow, same PID = re-entrant (should succeed)
rune_acquire_lock "test-wf1" "writer" && rc=0 || rc=1
assert_eq "Re-entrant acquire (same PID) succeeds" "0" "$rc"

# ═══════════════════════════════════════════════════════════════
# 4. rune_acquire_lock — invalid workflow name
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_acquire_lock — invalid names ===\n"

# 4a. Empty name
rune_acquire_lock "" "writer" && rc=0 || rc=1
assert_eq "Empty name rejected" "1" "$rc"

# 4b. Path traversal name
rune_acquire_lock "../evil" "writer" && rc=0 || rc=1
assert_eq "Path traversal name rejected" "1" "$rc"

# 4c. Name with spaces
rune_acquire_lock "has spaces" "writer" && rc=0 || rc=1
assert_eq "Name with spaces rejected" "1" "$rc"

# ═══════════════════════════════════════════════════════════════
# 5. rune_release_lock
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_release_lock ===\n"

# 5a. Release existing lock owned by us
rune_release_lock "test-wf1" && rc=0 || rc=1
assert_eq "Release own lock succeeds" "0" "$rc"

# 5b. Lock directory removed after release
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -d "$LOCK_BASE/test-wf1" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Lock directory removed after release\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Lock directory still exists after release\n"
fi

# 5c. Release non-existent lock is safe (returns 0)
rune_release_lock "nonexistent" && rc=0 || rc=1
assert_eq "Release nonexistent lock is safe" "0" "$rc"

# 5d. Release with invalid name is safe
rune_release_lock "" && rc=0 || rc=1
assert_eq "Release empty name is safe" "0" "$rc"

# 5e. Release lock owned by different PID (should NOT remove)
rune_acquire_lock "test-foreign" "writer" && rc=0 || rc=1
assert_eq "Acquire test-foreign" "0" "$rc"
# Tamper with PID in meta.json to simulate foreign ownership
jq '.pid = 99999' "$LOCK_BASE/test-foreign/meta.json" > "$LOCK_BASE/test-foreign/meta.json.tmp"
mv -f "$LOCK_BASE/test-foreign/meta.json.tmp" "$LOCK_BASE/test-foreign/meta.json"
rune_release_lock "test-foreign"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$LOCK_BASE/test-foreign" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Foreign-owned lock NOT released\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Foreign-owned lock was incorrectly released\n"
fi
# Clean up
rm -rf "$LOCK_BASE/test-foreign" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
# 6. rune_release_all_locks
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_release_all_locks ===\n"

# Clean slate for release_all tests
rm -rf "$LOCK_BASE" 2>/dev/null || true

# 6a. Create multiple locks
rune_acquire_lock "multi-1" "writer"
rune_acquire_lock "multi-2" "reader"
rune_acquire_lock "multi-3" "planner"

# Release all
rune_release_all_locks && rc=0 || rc=1
assert_eq "Release all locks succeeds" "0" "$rc"

# 6b. All lock dirs removed
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
shopt -s nullglob
lock_dirs=("$LOCK_BASE"/*/)
remaining=${#lock_dirs[@]}
if [[ "$remaining" == "0" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: All lock dirs removed\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: %s lock dirs remain\n" "$remaining"
fi

# 6c. Release all on empty lock base is safe
rm -rf "$LOCK_BASE"
rune_release_all_locks && rc=0 || rc=1
assert_eq "Release all on empty base is safe" "0" "$rc"

# ═══════════════════════════════════════════════════════════════
# 7. rune_check_conflicts
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_check_conflicts ===\n"

# 7a. No conflicts when no locks
rm -rf "$LOCK_BASE" 2>/dev/null || true
result=$(rune_check_conflicts "writer")
assert_eq "No conflicts when no locks" "" "$result"

# 7b. No conflict with own lock (same PID)
rune_acquire_lock "my-work" "writer"
result=$(rune_check_conflicts "writer")
assert_eq "No conflict with own lock" "" "$result"
rune_release_lock "my-work"

# 7c. Writer vs writer = CONFLICT (simulate foreign PID)
mkdir -p "$LOCK_BASE/foreign-writer"
jq -n --argjson pid 99998 --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"foreign-writer",class:"writer",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/foreign-writer/meta.json"
# Mock: make PID 99998 appear alive by using our own PID
jq --argjson pid "$$" '.pid = $pid' "$LOCK_BASE/foreign-writer/meta.json" > "$LOCK_BASE/foreign-writer/meta.json.tmp"
mv -f "$LOCK_BASE/foreign-writer/meta.json.tmp" "$LOCK_BASE/foreign-writer/meta.json"
result=$(rune_check_conflicts "writer")
assert_contains "Writer vs writer = CONFLICT" "CONFLICT" "$result"
rm -rf "$LOCK_BASE/foreign-writer"

# 7d. Writer vs reader = ADVISORY (simulate foreign PID)
mkdir -p "$LOCK_BASE/foreign-reader"
jq -n --argjson pid "$$" --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"foreign-reader",class:"reader",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/foreign-reader/meta.json"
result=$(rune_check_conflicts "writer")
assert_contains "Writer vs reader = ADVISORY" "ADVISORY" "$result"
rm -rf "$LOCK_BASE/foreign-reader"

# 7e. Different config_dir = skipped (no conflict)
mkdir -p "$LOCK_BASE/other-install"
jq -n --argjson pid "$$" \
  '{workflow:"other-install",class:"writer",pid:$pid,config_dir:"/different/path",started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/other-install/meta.json"
result=$(rune_check_conflicts "writer")
assert_not_contains "Different config_dir skipped" "other-install" "$result"
rm -rf "$LOCK_BASE/other-install"

# 7f. Dead PID lock is cleaned up (conflict check cleans orphans)
mkdir -p "$LOCK_BASE/dead-lock"
jq -n --argjson pid 99997 --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"dead-lock",class:"writer",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/dead-lock/meta.json"
result=$(rune_check_conflicts "writer")
assert_eq "Dead PID lock cleaned (no conflict)" "" "$result"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -d "$LOCK_BASE/dead-lock" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Dead PID lock dir removed\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Dead PID lock dir still exists\n"
fi

# 7g. Always returns 0 (conflicts in stdout, not exit code)
mkdir -p "$LOCK_BASE/conflict-lock"
jq -n --argjson pid "$$" --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"conflict-lock",class:"writer",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/conflict-lock/meta.json"
rune_check_conflicts "writer" >/dev/null
rc=$?
assert_eq "check_conflicts always returns 0" "0" "$rc"
rm -rf "$LOCK_BASE/conflict-lock"

# ═══════════════════════════════════════════════════════════════
# 8. _rune_lock_safe — symlink guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== _rune_lock_safe — symlink guard ===\n"

# 8a. Regular directory passes
mkdir -p "$TMP_DIR/safe-dir"
_rune_lock_safe "$TMP_DIR/safe-dir" && rc=0 || rc=1
assert_eq "Regular directory passes symlink guard" "0" "$rc"
rmdir "$TMP_DIR/safe-dir"

# 8b. Symlink rejected
mkdir -p "$TMP_DIR/real-dir"
ln -sf "$TMP_DIR/real-dir" "$TMP_DIR/sym-dir"
_rune_lock_safe "$TMP_DIR/sym-dir" && rc=0 || rc=1
assert_eq "Symlink rejected by guard" "1" "$rc"
rm -rf "$TMP_DIR/real-dir" "$TMP_DIR/sym-dir"

# ═══════════════════════════════════════════════════════════════
# 9. Orphaned lock reclamation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Orphaned lock reclamation ===\n"

# 9a. Lock with dead PID is reclaimed on acquire
rm -rf "$LOCK_BASE" 2>/dev/null || true
mkdir -p "$LOCK_BASE/orphan-wf"
jq -n --argjson pid 99996 --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"orphan-wf",class:"writer",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/orphan-wf/meta.json"
rune_acquire_lock "orphan-wf" "writer" && rc=0 || rc=1
assert_eq "Orphaned lock reclaimed" "0" "$rc"

# Verify our PID now owns it
new_pid=$(jq -r '.pid' "$LOCK_BASE/orphan-wf/meta.json" 2>/dev/null || echo "")
assert_eq "Reclaimed lock has our PID" "$PPID" "$new_pid"
rune_release_lock "orphan-wf"

# 9b. Ghost lock dir (no meta.json) is reclaimed
rm -rf "$LOCK_BASE" 2>/dev/null || true
mkdir -p "$LOCK_BASE/ghost-wf"
# No meta.json written
rune_acquire_lock "ghost-wf" "writer" && rc=0 || rc=1
assert_eq "Ghost lock dir reclaimed" "0" "$rc"
rune_release_lock "ghost-wf"

# ═══════════════════════════════════════════════════════════════
# 10. Default class parameter
# ═══════════════════════════════════════════════════════════════
printf "\n=== Default class parameter ===\n"

rm -rf "$LOCK_BASE" 2>/dev/null || true

# 10a. Default class is "writer"
rune_acquire_lock "default-class"
wf_class=$(jq -r '.class' "$LOCK_BASE/default-class/meta.json" 2>/dev/null || echo "")
assert_eq "Default class is writer" "writer" "$wf_class"
rune_release_lock "default-class"

# 10b. Custom class is preserved
rune_acquire_lock "custom-class" "planner"
wf_class=$(jq -r '.class' "$LOCK_BASE/custom-class/meta.json" 2>/dev/null || echo "")
assert_eq "Custom class preserved" "planner" "$wf_class"
rune_release_lock "custom-class"

# ═══════════════════════════════════════════════════════════════
# 11. Cross-session lock coexistence
# ═══════════════════════════════════════════════════════════════
printf "\n=== Cross-session lock coexistence ===\n"

rm -rf "$LOCK_BASE" 2>/dev/null || true

# 11a. Writer + reader coexistence (different PIDs)
# Simulate Session A: arc (writer) with a foreign PID
mkdir -p "$LOCK_BASE/arc"
jq -n --argjson pid "$$" --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"arc",class:"writer",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/arc/meta.json"
# Session B: acquire audit (reader) — should succeed without CONFLICT
rune_acquire_lock "audit" "reader" && rc=0 || rc=1
assert_eq "Writer + reader coexistence: reader acquires" "0" "$rc"
# Check conflicts from reader perspective → should be ADVISORY, not CONFLICT
result=$(rune_check_conflicts "reader")
assert_not_contains "Writer + reader: no CONFLICT" "CONFLICT" "$result"
rune_release_lock "audit"
rm -rf "$LOCK_BASE/arc"

# 11b. Writer + planner coexistence (different PIDs)
mkdir -p "$LOCK_BASE/arc"
jq -n --argjson pid "$$" --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"arc",class:"writer",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/arc/meta.json"
rune_acquire_lock "devise" "planner" && rc=0 || rc=1
assert_eq "Writer + planner coexistence: planner acquires" "0" "$rc"
rune_release_lock "devise"
rm -rf "$LOCK_BASE/arc"

# 11c. Dead PID reclamation in cross-session scenario
rm -rf "$LOCK_BASE" 2>/dev/null || true
mkdir -p "$LOCK_BASE/stale-arc"
jq -n --argjson pid 99999 --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"stale-arc",class:"writer",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/stale-arc/meta.json"
# New session tries to acquire same lock — should reclaim (PID 99999 is dead)
rune_acquire_lock "stale-arc" "writer" && rc=0 || rc=1
assert_eq "Dead PID lock reclaimed by new session" "0" "$rc"
new_pid=$(jq -r '.pid' "$LOCK_BASE/stale-arc/meta.json" 2>/dev/null || echo "")
assert_eq "Reclaimed lock has new session PID" "$PPID" "$new_pid"
rune_release_lock "stale-arc"

# 11d. Same-workflow re-entry (same PID acquires same lock twice)
rm -rf "$LOCK_BASE" 2>/dev/null || true
rune_acquire_lock "reentrant-wf" "writer" && rc=0 || rc=1
assert_eq "First acquire for re-entry test" "0" "$rc"
rune_acquire_lock "reentrant-wf" "writer" && rc=0 || rc=1
assert_eq "Re-entrant acquire succeeds" "0" "$rc"
rune_release_lock "reentrant-wf"

# 11e. Conflict detection accuracy: writer sees ADVISORY for reader, not CONFLICT
rm -rf "$LOCK_BASE" 2>/dev/null || true
mkdir -p "$LOCK_BASE/foreign-audit"
jq -n --argjson pid "$$" --arg cfg "$RUNE_CURRENT_CFG" \
  '{workflow:"foreign-audit",class:"reader",pid:$pid,config_dir:$cfg,started:"2026-01-01T00:00:00Z"}' \
  > "$LOCK_BASE/foreign-audit/meta.json"
result=$(rune_check_conflicts "writer")
assert_contains "Writer sees ADVISORY for reader" "ADVISORY" "$result"
assert_not_contains "Writer does NOT see CONFLICT for reader" "CONFLICT" "$result"
rm -rf "$LOCK_BASE/foreign-audit"

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
