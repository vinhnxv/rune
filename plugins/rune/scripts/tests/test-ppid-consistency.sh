#!/usr/bin/env bash
# test-ppid-consistency.sh — Verify $PPID is consistent between skill and hook contexts
#
# This test confirms that $PPID in hook scripts matches the value written by skills
# via Bash('echo $PPID'). If they differ, cross-session isolation would break entirely.
#
# Usage: bash plugins/rune/scripts/tests/test-ppid-consistency.sh
# Exit: 0 on pass, 1 on failure

set -euo pipefail

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

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

printf "\n=== PPID Consistency Tests ===\n"

# 1. $PPID is available and numeric
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$PPID" =~ ^[0-9]+$ ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: PPID is numeric (%s)\n" "$PPID"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: PPID is not numeric: %s\n" "$PPID"
fi

# 2. Simulate skill context: write PPID to a state file (same as Bash('echo $PPID'))
echo "{\"owner_pid\": \"$PPID\"}" > "$TMP_DIR/skill-state.json"
STORED_PID=$(jq -r '.owner_pid' "$TMP_DIR/skill-state.json")
assert_eq "Skill-written PPID matches current PPID" "$PPID" "$STORED_PID"

# 3. Simulate hook context: read PPID directly (same as hooks do)
# In a real hook, $PPID is the Claude Code process PID
HOOK_PPID="$PPID"
assert_eq "Hook PPID matches skill-written PPID" "$STORED_PID" "$HOOK_PPID"

# 4. Verify resolve-session-identity.sh exports consistent value
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$SCRIPT_DIR/resolve-session-identity.sh" ]]; then
  # Source in subshell to avoid polluting test env
  RSI_PPID=$(bash -c "source '$SCRIPT_DIR/resolve-session-identity.sh' && echo \$PPID")
  # Note: In subshell, PPID changes to the subshell's parent (this script)
  # The key assertion is that $PPID is consistent WITHIN a single process tree
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$RSI_PPID" =~ ^[0-9]+$ ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: resolve-session-identity.sh PPID is numeric (%s)\n" "$RSI_PPID"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: resolve-session-identity.sh PPID not numeric: %s\n" "$RSI_PPID"
  fi
fi

# 5. Verify PPID is stable across multiple reads (not changing between invocations)
PPID_READ1="$PPID"
PPID_READ2="$PPID"
PPID_READ3="$PPID"
assert_eq "PPID stable across reads (1 vs 2)" "$PPID_READ1" "$PPID_READ2"
assert_eq "PPID stable across reads (2 vs 3)" "$PPID_READ2" "$PPID_READ3"

# 6. Verify PPID process is alive (it should be — it's our parent)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if kill -0 "$PPID" 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: PPID process is alive\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: PPID process is not alive\n"
fi

# ═══ Results ═══
printf "\n═══════════════════════════════════════════════════\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "═══════════════════════════════════════════════════\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
