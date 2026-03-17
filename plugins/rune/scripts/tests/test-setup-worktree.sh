#!/usr/bin/env bash
# test-setup-worktree.sh — Tests for scripts/setup-worktree.sh
#
# Usage: bash plugins/rune/scripts/tests/test-setup-worktree.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/setup-worktree.sh"

# ── Temp directory for isolation ──
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-setup-wt-XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Guard: jq dependency ──
if ! command -v jq &>/dev/null; then
  echo "SKIP: jq not available (required by setup-worktree.sh)"
  exit 0
fi

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

assert_file_exists() {
  local test_name="$1"
  local file="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ -f "$file" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (file not found: %s)\n" "$test_name" "$file"
  fi
}

assert_dir_exists() {
  local test_name="$1"
  local dir="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ -d "$dir" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (dir not found: %s)\n" "$test_name" "$dir"
  fi
}

assert_file_not_exists() {
  local test_name="$1"
  local file="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ ! -e "$file" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (should not exist: %s)\n" "$test_name" "$file"
  fi
}

assert_dir_not_exists() {
  local test_name="$1"
  local dir="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ ! -d "$dir" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (dir should not exist: %s)\n" "$test_name" "$dir"
  fi
}

assert_exit_zero() {
  local test_name="$1"
  local exit_code="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$exit_code" -eq 0 ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (exit code: %d, expected 0)\n" "$test_name" "$exit_code"
  fi
}

# Helper: create a standard main repo fixture
setup_main_repo() {
  local base="$1"
  mkdir -p "$base/.claude/echoes" "$base/.claude/arc" "$base/.claude/worktrees/other"
  echo "test: true" > "$base/.claude/talisman.yml"
  echo '{}' > "$base/.claude/settings.json"
  echo "echo-entry" > "$base/.claude/echoes/MEMORY.md"
  echo "arc-data" > "$base/.claude/arc/checkpoint.json"
  echo "should-not-copy" > "$base/.claude/worktrees/other/data"
}

# Helper: run the hook with given JSON input
run_hook() {
  local input="$1"
  printf '%s\n' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null
  return $?
}

# ═══════════════════════════════════════════════════════════════
printf "\n═══════════════════════════════════════════════════\n"
printf " test-setup-worktree.sh\n"
printf "═══════════════════════════════════════════════════\n\n"

# ── Test 1: Happy path — full copy ──
printf "Test 1: Happy path — copies all essential files\n"
MAIN="$TMP_DIR/test1/main"
WT="$TMP_DIR/test1/wt"
setup_main_repo "$MAIN"
mkdir -p "$WT/.claude"
INPUT=$(jq -n --arg cwd "$MAIN" --arg wt "$WT" '{"name":"test","cwd":$cwd,"worktree_path":$wt}')
run_hook "$INPUT"
EXIT_CODE=$?

assert_exit_zero "Hook exits 0" "$EXIT_CODE"
assert_file_exists "talisman.yml copied" "$WT/.claude/talisman.yml"
assert_file_exists "settings.json copied" "$WT/.claude/settings.json"
assert_dir_exists "echoes/ copied" "$WT/.claude/echoes"
assert_file_exists "echoes/MEMORY.md copied" "$WT/.claude/echoes/MEMORY.md"
assert_dir_exists "arc/ copied" "$WT/.claude/arc"
assert_file_exists "arc/checkpoint.json copied" "$WT/.claude/arc/checkpoint.json"
assert_dir_exists "tmp/ created" "$WT/tmp"
assert_file_exists "Marker file written" "$WT/.claude/.rune-worktree-source"

# Verify marker content
MARKER_CONTENT=$(cat "$WT/.claude/.rune-worktree-source" 2>/dev/null | tr -d '\n')
# Canonicalize for comparison (macOS /private/var vs /var)
CANON_MAIN=$(cd "$MAIN" && pwd -P)
assert_eq "Marker contains canonical main repo path" "$CANON_MAIN" "$MARKER_CONTENT"
printf "\n"

# ── Test 2: Re-entry detection (idempotent) ──
printf "Test 2: Re-entry detection — idempotent\n"
# Modify the source talisman to verify it doesn't overwrite
echo "modified: true" > "$MAIN/.claude/talisman.yml"
run_hook "$INPUT"
EXIT_CODE=$?

assert_exit_zero "Re-entry exits 0" "$EXIT_CODE"
# Original content should still be there (not overwritten)
WT_CONTENT=$(cat "$WT/.claude/talisman.yml" 2>/dev/null)
assert_eq "Original talisman.yml preserved (not overwritten)" "test: true" "$WT_CONTENT"
printf "\n"

# ── Test 3: Missing .claude/ in source ──
printf "Test 3: Missing source .claude/ — graceful exit\n"
BARE="$TMP_DIR/test3/bare"
WT3="$TMP_DIR/test3/wt"
mkdir -p "$BARE" "$WT3"
INPUT3=$(jq -n --arg cwd "$BARE" --arg wt "$WT3" '{"name":"test","cwd":$cwd,"worktree_path":$wt}')
run_hook "$INPUT3"
EXIT_CODE=$?

assert_exit_zero "Exits 0 without source .claude/" "$EXIT_CODE"
assert_dir_not_exists "No .claude/ created in worktree" "$WT3/.claude"
printf "\n"

# ── Test 4: Excludes worktrees/ directory ──
printf "Test 4: Excludes worktrees/ directory\n"
assert_dir_not_exists "worktrees/ NOT copied" "$WT/.claude/worktrees"
printf "\n"

# ── Test 5: No stdin input ──
printf "Test 5: No stdin — graceful exit\n"
echo "" | bash "$HOOK_SCRIPT" 2>/dev/null
EXIT_CODE=$?
assert_exit_zero "Empty stdin exits 0" "$EXIT_CODE"
printf "\n"

# ── Test 6: Symlink guard ──
printf "Test 6: Symlink guard — rejects symlinked worktree_path\n"
MAIN6="$TMP_DIR/test6/main"
REAL6="$TMP_DIR/test6/real"
LINK6="$TMP_DIR/test6/link"
setup_main_repo "$MAIN6"
mkdir -p "$REAL6"
ln -s "$REAL6" "$LINK6"
INPUT6=$(jq -n --arg cwd "$MAIN6" --arg wt "$LINK6" '{"name":"test","cwd":$cwd,"worktree_path":$wt}')
run_hook "$INPUT6"
EXIT_CODE=$?

assert_exit_zero "Symlink guard exits 0 (fail-forward)" "$EXIT_CODE"
assert_dir_not_exists "No .claude/ in symlinked target" "$REAL6/.claude"
printf "\n"

# ── Test 7: Path traversal rejection ──
printf "Test 7: Path traversal rejection\n"
MAIN7="$TMP_DIR/test7/main"
setup_main_repo "$MAIN7"
INPUT7=$(jq -n --arg cwd "$MAIN7" '{"name":"test","cwd":$cwd,"worktree_path":"/tmp/../etc/bad"}')
run_hook "$INPUT7"
EXIT_CODE=$?

assert_exit_zero "Path traversal exits 0 (fail-forward)" "$EXIT_CODE"
printf "\n"

# ── Test 8: Derive worktree_path from name + cwd ──
printf "Test 8: Derive worktree_path from name when not provided\n"
MAIN8="$TMP_DIR/test8/main"
setup_main_repo "$MAIN8"
mkdir -p "$MAIN8/.claude/worktrees/my-feature/.claude"
INPUT8=$(jq -n --arg cwd "$MAIN8" '{"name":"my-feature","cwd":$cwd}')
run_hook "$INPUT8"
EXIT_CODE=$?

assert_exit_zero "Derived path exits 0" "$EXIT_CODE"
assert_file_exists "talisman.yml in derived path" "$MAIN8/.claude/worktrees/my-feature/.claude/talisman.yml"
printf "\n"

# ── Test 9: agent-memory/ and agent-memory-local/ excluded ──
printf "Test 9: agent-memory dirs excluded\n"
MAIN9="$TMP_DIR/test9/main"
WT9="$TMP_DIR/test9/wt"
setup_main_repo "$MAIN9"
mkdir -p "$MAIN9/.claude/agent-memory/test" "$MAIN9/.claude/agent-memory-local/test"
echo "persistent" > "$MAIN9/.claude/agent-memory/test/data"
echo "local" > "$MAIN9/.claude/agent-memory-local/test/data"
mkdir -p "$WT9/.claude"
INPUT9=$(jq -n --arg cwd "$MAIN9" --arg wt "$WT9" '{"name":"test","cwd":$cwd,"worktree_path":$wt}')
run_hook "$INPUT9"
EXIT_CODE=$?

assert_exit_zero "Exits 0" "$EXIT_CODE"
assert_dir_not_exists "agent-memory/ NOT copied" "$WT9/.claude/agent-memory"
assert_dir_not_exists "agent-memory-local/ NOT copied" "$WT9/.claude/agent-memory-local"
printf "\n"

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
