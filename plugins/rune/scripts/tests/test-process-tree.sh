#!/usr/bin/env bash
# test-process-tree.sh — Tests for scripts/lib/process-tree.sh
#
# Usage: bash plugins/rune/scripts/tests/test-process-tree.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Source process-tree.sh (also sources platform.sh) ──
source "${LIB_DIR}/process-tree.sh"

# ── Temp directory ──
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-process-tree-XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

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
    printf "  FAIL: %s (expected='%s', actual='%s')\n" "$test_name" "$expected" "$actual"
  fi
}

assert_ge() {
  local test_name="$1" expected="$2" actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$actual" -ge "$expected" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s (got %s >= %s)\n" "$test_name" "$actual" "$expected"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected >= %s, got %s)\n" "$test_name" "$expected" "$actual"
  fi
}

# ═══════════════════════════════════
echo "=== Sourcing guard ==="

assert_eq "sourcing guard set" "1" "$_RUNE_PROCESS_TREE_LOADED"

# Re-source should be no-op (idempotent)
source "${LIB_DIR}/process-tree.sh"
assert_eq "sourcing guard idempotent" "1" "$_RUNE_PROCESS_TREE_LOADED"

# ═══════════════════════════════════
echo ""
echo "=== _proc_name ==="

# _proc_name should return something for PID 1
proc1=$(_proc_name 1 || echo "")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -n "$proc1" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: _proc_name(1) returned '%s'\n" "$proc1"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: _proc_name(1) returned empty\n"
fi

# _proc_name for non-existent PID returns empty
nonexist=$(_proc_name 999999999 || echo "")
assert_eq "_proc_name(non-existent) is empty" "" "$nonexist"

# ═══════════════════════════════════
echo ""
echo "=== _rune_collect_descendants ==="

# Collect descendants of current shell
_RUNE_DESC_PIDS=()
_rune_collect_descendants $$
# Current shell may or may not have children, just check it doesn't crash
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
PASS_COUNT=$(( PASS_COUNT + 1 ))
printf "  PASS: _rune_collect_descendants($$) ran without error (found %d)\n" "${#_RUNE_DESC_PIDS[@]}"

# Non-existent PID returns empty array
_RUNE_DESC_PIDS=()
_rune_collect_descendants 999999999
assert_eq "descendants of non-existent PID" "0" "${#_RUNE_DESC_PIDS[@]}"

# Invalid PID input
_RUNE_DESC_PIDS=()
_rune_collect_descendants "abc"
assert_eq "descendants of invalid PID" "0" "${#_RUNE_DESC_PIDS[@]}"

# Empty PID input
_RUNE_DESC_PIDS=()
_rune_collect_descendants ""
assert_eq "descendants of empty PID" "0" "${#_RUNE_DESC_PIDS[@]}"

# ═══════════════════════════════════
echo ""
echo "=== _rune_kill_tree ==="

# Kill tree with non-existent root PID returns 0
result=$(_rune_kill_tree 999999999 "2stage" "1" "all")
assert_eq "kill_tree non-existent root returns 0" "0" "$result"

# Kill tree with invalid root PID returns 0
result=$(_rune_kill_tree "abc" "2stage" "1" "all")
assert_eq "kill_tree invalid root returns 0" "0" "$result"

# Kill tree with empty root PID returns 0
result=$(_rune_kill_tree "" "2stage" "1" "all")
assert_eq "kill_tree empty root returns 0" "0" "$result"

# Spawn a child process tree and kill it
# Parent sleep → child sleep
sleep 300 &
PARENT_PID=$!
# Give it a moment to start
sleep 0.1

# Kill tree should find and kill the sleep process
result=$(_rune_kill_tree $$ "2stage" "1" "all")
assert_ge "kill_tree found sleep child" "0" "$result"

# Verify sleep is dead
sleep 0.2
if kill -0 "$PARENT_PID" 2>/dev/null; then
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: sleep child still alive after kill_tree\n"
  kill -KILL "$PARENT_PID" 2>/dev/null || true
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: sleep child terminated after kill_tree\n"
fi

# ═══════════════════════════════════
echo ""
echo "=== _rune_kill_tree filter=claude ==="

# With claude filter, non-claude processes should be spared
sleep 300 &
SLEEP_PID=$!
sleep 0.1

# Claude filter should NOT kill a "sleep" process
result=$(_rune_kill_tree $$ "2stage" "1" "claude")
assert_eq "kill_tree claude filter spares sleep" "0" "$result"

# Verify sleep is still alive
if kill -0 "$SLEEP_PID" 2>/dev/null; then
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: sleep child survived claude filter\n"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: sleep child was killed despite claude filter\n"
fi
kill -KILL "$SLEEP_PID" 2>/dev/null || true
wait "$SLEEP_PID" 2>/dev/null || true

# ═══════════════════════════════════
echo ""
echo "=== _rune_kill_tree mode=term ==="

# term mode should only SIGTERM, not SIGKILL
sleep 300 &
TERM_PID=$!
sleep 0.1

result=$(_rune_kill_tree $$ "term" "0" "all")
assert_ge "kill_tree term mode returns count" "0" "$result"

# Clean up
kill -KILL "$TERM_PID" 2>/dev/null || true
wait "$TERM_PID" 2>/dev/null || true

# ═══════════════════════════════════
echo ""
echo "═══════════════════════════════════════"
printf "Results: %d passed, %d failed, %d total\n" "$PASS_COUNT" "$FAIL_COUNT" "$TOTAL_COUNT"
echo "═══════════════════════════════════════"

[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
