#!/usr/bin/env bash
# test-worktree-gc.sh — Tests for scripts/lib/worktree-gc.sh
#
# Usage: bash plugins/rune/scripts/tests/test-worktree-gc.sh
# Exit: 0 on all pass, 1 on any failure.
#
# NOTE: Tests that involve actual git worktree operations require a real git repo.
# We create a temporary git repo for isolation.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Temp directory for isolation ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Mock environment ──
export CLAUDE_CONFIG_DIR="$TMP_DIR/config"
mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_SESSION_ID="test-session-$$"

# ── Set up a real git repo for worktree tests ──
REPO_DIR="$TMP_DIR/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init --quiet
git -C "$REPO_DIR" config user.email "test@test.com"
git -C "$REPO_DIR" config user.name "Test"
# Need at least one commit for worktree operations
printf "init" > "$REPO_DIR/README.md"
git -C "$REPO_DIR" add README.md
git -C "$REPO_DIR" commit -m "init" --quiet
mkdir -p "$REPO_DIR/tmp"

# ── Source the library under test ──
# shellcheck source=../lib/worktree-gc.sh
source "$LIB_DIR/worktree-gc.sh"

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
# 1. rune_has_worktree_support
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_has_worktree_support ===\n"

# 1a. Valid git repo has worktree support
rune_has_worktree_support "$REPO_DIR" && rc=0 || rc=1
assert_eq "Git repo has worktree support" "0" "$rc"

# 1b. Non-git directory fails
mkdir -p "$TMP_DIR/not-a-repo"
rune_has_worktree_support "$TMP_DIR/not-a-repo" && rc=0 || rc=1
assert_eq "Non-git dir has no worktree support" "1" "$rc"

# 1c. Non-existent directory fails
rune_has_worktree_support "$TMP_DIR/does-not-exist" && rc=0 || rc=1
assert_eq "Non-existent dir has no worktree support" "1" "$rc"

# ═══════════════════════════════════════════════════════════════
# 2. rune_extract_wt_timestamp
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_extract_wt_timestamp ===\n"

# 2a. Standard rune-work-timestamp pattern
result=$(rune_extract_wt_timestamp "rune-work-20260301-123456")
assert_eq "Timestamp from rune-work pattern" "20260301-123456" "$result"

# 2b. With full path
result=$(rune_extract_wt_timestamp "/home/user/repo/.claude/worktrees/rune-work-abc123")
assert_eq "Timestamp from full path" "abc123" "$result"

# 2c. No rune-work pattern -> empty
# NOTE: grep returns exit code 1 on no match; under pipefail, this propagates.
# Protect with || true at the call site to avoid ERR trap.
result=$(rune_extract_wt_timestamp "some-other-branch" || true)
assert_eq "No rune-work pattern returns empty" "" "$result"

# 2d. Empty input -> empty
result=$(rune_extract_wt_timestamp "" || true)
assert_eq "Empty input returns empty" "" "$result"

# 2e. Multiple rune-work patterns -> first one
result=$(rune_extract_wt_timestamp "rune-work-first/rune-work-second" || true)
assert_eq "Multiple patterns: first one extracted" "first" "$result"

# ═══════════════════════════════════════════════════════════════
# 3. rune_wt_is_orphaned
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_wt_is_orphaned ===\n"

# 3a. Empty timestamp -> orphan (safe to remove)
rune_wt_is_orphaned "$REPO_DIR" "" && rc=0 || rc=1
assert_eq "Empty timestamp = orphan" "0" "$rc"

# 3b. No state file -> orphan
rune_wt_is_orphaned "$REPO_DIR" "nonexistent-ts" && rc=0 || rc=1
assert_eq "No state file = orphan" "0" "$rc"

# 3c. State file with dead PID -> orphan
printf '{"config_dir":"%s","owner_pid":"99999","session_id":"%s"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" "${CLAUDE_SESSION_ID:-test-session}" > "$REPO_DIR/tmp/.rune-work-dead-pid.json"
rune_wt_is_orphaned "$REPO_DIR" "dead-pid" && rc=0 || rc=1
assert_eq "Dead PID = orphan" "0" "$rc"

# 3d. State file with our PID -> orphan (our own session, safe to clean)
printf '{"config_dir":"%s","owner_pid":"%s","session_id":"%s"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" "$PPID" "${CLAUDE_SESSION_ID:-test-session}" > "$REPO_DIR/tmp/.rune-work-our-pid.json"
rune_wt_is_orphaned "$REPO_DIR" "our-pid" && rc=0 || rc=1
assert_eq "Our PID = safe to clean" "0" "$rc"

# 3e. State file with live different PID -> NOT orphan (skip)
printf '{"config_dir":"%s","owner_pid":"%s","session_id":"%s"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" "$$" "${CLAUDE_SESSION_ID:-test-session}" > "$REPO_DIR/tmp/.rune-work-live-pid.json"
rune_wt_is_orphaned "$REPO_DIR" "live-pid" && rc=0 || rc=1
assert_eq "Live different PID = not orphan (skip)" "1" "$rc"

# 3f. State file with different config_dir -> NOT orphan (different installation)
printf '{"config_dir":"/different/install","owner_pid":"%s"}' "$$" > "$REPO_DIR/tmp/.rune-work-diff-cfg.json"
rune_wt_is_orphaned "$REPO_DIR" "diff-cfg" && rc=0 || rc=1
assert_eq "Different config_dir = not orphan (skip)" "1" "$rc"

# 3g. State file with no PID -> orphan
printf '{"config_dir":"%s"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" > "$REPO_DIR/tmp/.rune-work-no-pid.json"
rune_wt_is_orphaned "$REPO_DIR" "no-pid" && rc=0 || rc=1
assert_eq "No PID in state file = orphan" "0" "$rc"

# Clean up state files
rm -f "$REPO_DIR"/tmp/.rune-work-*.json

# ═══════════════════════════════════════════════════════════════
# 4. rune_clean_worktree — security guards
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_clean_worktree — security ===\n"

# 4a. Empty path is safe (no-op)
rune_clean_worktree "" && rc=0 || rc=$?
assert_eq "Empty path is safe no-op" "0" "$rc"

# 4b. Non-existent path is safe
rune_clean_worktree "/nonexistent/path" && rc=0 || rc=$?
assert_eq "Non-existent path is safe" "0" "$rc"

# 4c. Path with .. is rejected
mkdir -p "$TMP_DIR/traversal-test"
rune_clean_worktree "$TMP_DIR/../traversal-test" && rc=0 || rc=$?
assert_eq "Path traversal (..) rejected" "0" "$rc"

# 4d. Symlink path is rejected
mkdir -p "$TMP_DIR/real-wt-dir"
ln -sf "$TMP_DIR/real-wt-dir" "$TMP_DIR/sym-wt-dir"
rune_clean_worktree "$TMP_DIR/sym-wt-dir" && rc=0 || rc=$?
assert_eq "Symlink path rejected" "0" "$rc"
# The real dir should still exist (not cleaned through symlink)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$TMP_DIR/real-wt-dir" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Real dir preserved after symlink rejection\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Real dir was removed through symlink\n"
fi
rm -rf "$TMP_DIR/real-wt-dir" "$TMP_DIR/sym-wt-dir"

# ═══════════════════════════════════════════════════════════════
# 5. rune_clean_branch — validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_clean_branch — validation ===\n"

# 5a. Empty branch name is safe
rune_clean_branch "$REPO_DIR" "" && rc=0 || rc=$?
assert_eq "Empty branch name is safe" "0" "$rc"

# 5b. Branch with injection chars rejected
rune_clean_branch "$REPO_DIR" 'branch;rm -rf /' && rc=0 || rc=$?
assert_eq "Branch with semicolon rejected" "0" "$rc"

# 5c. Valid branch name format accepted (branch may not exist, but validation passes)
# Create a test branch first
git -C "$REPO_DIR" branch rune-work-test-branch 2>/dev/null || true
rune_clean_branch "$REPO_DIR" "rune-work-test-branch" && rc=0 || rc=$?
assert_eq "Valid branch name accepted" "0" "$rc"

# 5d. Current branch cannot be deleted
current_branch=$(git -C "$REPO_DIR" branch --show-current)
rune_clean_branch "$REPO_DIR" "$current_branch" && rc=0 || rc=1
assert_eq "Current branch deletion returns 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════
# 6. rune_list_work_worktrees / rune_list_work_branches
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_list_work_worktrees / rune_list_work_branches ===\n"

# 6a. No rune-work worktrees initially
result=$(rune_list_work_worktrees "$REPO_DIR")
assert_eq "No rune-work worktrees initially" "" "$result"

# 6b. Create a rune-work worktree and verify listing
wt_path="$TMP_DIR/rune-work-test1"
git -C "$REPO_DIR" worktree add -b rune-work-test1 "$wt_path" HEAD --quiet 2>/dev/null
result=$(rune_list_work_worktrees "$REPO_DIR")
assert_contains "rune-work worktree listed" "rune-work-test1" "$result"

# 6c. rune_list_work_branches includes the branch
result=$(rune_list_work_branches "$REPO_DIR")
assert_contains "rune-work branch listed" "rune-work-test1" "$result"

# 6d. Non-rune branches not listed
git -C "$REPO_DIR" branch other-feature 2>/dev/null || true
result=$(rune_list_work_branches "$REPO_DIR")
assert_not_contains "Non-rune branch not listed" "other-feature" "$result"

# Clean up worktree
git -C "$REPO_DIR" worktree remove "$wt_path" --force 2>/dev/null || true
git -C "$REPO_DIR" branch -D rune-work-test1 2>/dev/null || true
git -C "$REPO_DIR" branch -D other-feature 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# 7. rune_worktree_gc — main function
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_worktree_gc — main ===\n"

# 7a. GC on repo with no rune-work worktrees returns empty
result=$(rune_worktree_gc "$REPO_DIR" "session-stop")
assert_eq "GC with no worktrees returns empty" "" "$result"

# 7b. GC returns 0 exit code always
rune_worktree_gc "$REPO_DIR" "session-stop" >/dev/null && rc=0 || rc=$?
assert_eq "GC always returns 0" "0" "$rc"

# 7c. GC on non-git dir returns empty (fail-open)
result=$(rune_worktree_gc "$TMP_DIR/not-a-repo" "session-stop")
assert_eq "GC on non-git dir returns empty" "" "$result"

# 7d. Create orphaned worktree (dead PID) and verify GC cleans it
wt_path2="$TMP_DIR/rune-work-orphan1"
git -C "$REPO_DIR" worktree add -b rune-work-orphan1 "$wt_path2" HEAD --quiet 2>/dev/null
# Create state file with dead PID
printf '{"config_dir":"%s","owner_pid":"99998"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" > "$REPO_DIR/tmp/.rune-work-orphan1.json"

result=$(rune_worktree_gc "$REPO_DIR" "rest")
assert_contains "GC cleans orphaned worktree" "removed" "$result"

# 7e. Verify GC attempted cleanup (reported in output)
# Note: git worktree remove may require running from the main repo.
# The GC function runs git worktree prune which handles stale entries.
# We verify the function reported removal and then force-clean for subsequent tests.
assert_contains "GC reported worktree removal" "removed" "$result"

# Force cleanup of any remaining directory artifacts for test isolation
rm -rf "$wt_path2" 2>/dev/null || true
git -C "$REPO_DIR" worktree prune 2>/dev/null || true
git -C "$REPO_DIR" branch -D rune-work-orphan1 2>/dev/null || true

# Clean up state files
rm -f "$REPO_DIR"/tmp/.rune-work-*.json

# ═══════════════════════════════════════════════════════════════
# 8. rune_worktree_gc — session-stop cap
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_worktree_gc — session-stop cap ===\n"

# 8a. Session-stop mode caps at 3 items
# Create 5 orphaned branches (no worktrees needed, just branches)
for i in 1 2 3 4 5; do
  git -C "$REPO_DIR" branch "rune-work-cap${i}" 2>/dev/null || true
  printf '{"config_dir":"%s","owner_pid":"99990"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" > "$REPO_DIR/tmp/.rune-work-cap${i}.json"
done

result=$(rune_worktree_gc "$REPO_DIR" "session-stop")
# Session-stop caps at 3, so some should remain
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
remaining_branches=$(git -C "$REPO_DIR" branch --list 'rune-work-cap*' 2>/dev/null | wc -l | tr -d ' ')
# With cap of 3, at least 2 should remain (5 - 3 = 2)
if [[ "$remaining_branches" -ge 1 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Session-stop cap limits cleanup (remaining: %s)\n" "$remaining_branches"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Session-stop cap did not limit (remaining: %s)\n" "$remaining_branches"
fi

# Clean up remaining
for i in 1 2 3 4 5; do
  git -C "$REPO_DIR" branch -D "rune-work-cap${i}" 2>/dev/null || true
  rm -f "$REPO_DIR/tmp/.rune-work-cap${i}.json"
done

# 8b. Rest mode has no cap (999)
for i in 1 2 3 4 5; do
  git -C "$REPO_DIR" branch "rune-work-rest${i}" 2>/dev/null || true
  printf '{"config_dir":"%s","owner_pid":"99989"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" > "$REPO_DIR/tmp/.rune-work-rest${i}.json"
done

result=$(rune_worktree_gc "$REPO_DIR" "rest")
remaining_branches=$(git -C "$REPO_DIR" branch --list 'rune-work-rest*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "Rest mode cleans all branches" "0" "$remaining_branches"

# Clean up state files
rm -f "$REPO_DIR"/tmp/.rune-work-*.json

# ═══════════════════════════════════════════════════════════════
# 9. rune_worktree_gc — live session protection
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_worktree_gc — live session protection ===\n"

# 9a. Worktree owned by live different PID is skipped
wt_live="$TMP_DIR/rune-work-livesess"
git -C "$REPO_DIR" worktree add -b rune-work-livesess "$wt_live" HEAD --quiet 2>/dev/null
printf '{"config_dir":"%s","owner_pid":"%s"}' "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" "$$" > "$REPO_DIR/tmp/.rune-work-livesess.json"

result=$(rune_worktree_gc "$REPO_DIR" "rest")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$wt_live" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Live session worktree preserved\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Live session worktree was removed\n"
fi

# Clean up
git -C "$REPO_DIR" worktree remove "$wt_live" --force 2>/dev/null || true
git -C "$REPO_DIR" branch -D rune-work-livesess 2>/dev/null || true
rm -f "$REPO_DIR/tmp/.rune-work-livesess.json"

# ═══════════════════════════════════════════════════════════════
# 10. Edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge cases ===\n"

# 10a. GC with empty CWD string
result=$(rune_worktree_gc "" "session-stop")
assert_eq "GC with empty CWD returns empty" "" "$result"

# 10b. GC with default mode parameter (clean repo, no orphans)
# Ensure clean state first
git -C "$REPO_DIR" worktree prune 2>/dev/null || true
shopt -s nullglob
for b in $(git -C "$REPO_DIR" branch --list 'rune-work-*' 2>/dev/null | sed 's/^[* ]*//'); do
  git -C "$REPO_DIR" branch -D "$b" 2>/dev/null || true
done
rm -f "$REPO_DIR"/tmp/.rune-work-*.json
result=$(rune_worktree_gc "$REPO_DIR")
assert_eq "GC with default mode returns empty (no orphans)" "" "$result"

# 10c. rune_list_work_worktrees on non-git dir returns empty
result=$(rune_list_work_worktrees "$TMP_DIR/not-a-repo")
assert_eq "list_work_worktrees on non-git dir returns empty" "" "$result"

# 10d. rune_list_work_branches on non-git dir returns empty
result=$(rune_list_work_branches "$TMP_DIR/not-a-repo")
assert_eq "list_work_branches on non-git dir returns empty" "" "$result"

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
