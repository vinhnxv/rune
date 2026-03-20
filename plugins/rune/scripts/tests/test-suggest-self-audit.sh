#!/usr/bin/env bash
# test-suggest-self-audit.sh — Tests for scripts/suggest-self-audit.sh
#
# Tests the auto-suggestion Stop hook that advises running /rune:self-audit
# when recent arc QA scores are marginal.
#
# Usage: bash plugins/rune/scripts/tests/test-suggest-self-audit.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/suggest-self-audit.sh"

# ── Temp workspace ──
TMPWORK=$(mktemp -d "${TMPDIR:-/tmp}/test-suggest-audit-XXXXXX")
trap 'rm -rf "$TMPWORK"' EXIT

# ── Prereq: jq ──
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (required by suggest-self-audit.sh)"
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

assert_exit() {
  local test_name="$1"
  local expected_code="$2"
  local actual_code="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$expected_code" = "$actual_code" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s (exit %s)\n" "$test_name" "$actual_code"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected exit %s, got %s)\n" "$test_name" "$expected_code" "$actual_code"
  fi
}

# Helper: run the hook with a prepared CWD
run_hook() {
  local cwd="$1"
  local session_id="${2:-test-session-$$}"
  local input
  input=$(jq -n --arg cwd "$cwd" --arg sid "$session_id" '{cwd: $cwd, session_id: $sid}')
  # Run with stdin, capture exit code. Redirect stderr to capture suggestion.
  local exit_code=0
  printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>"$TMPWORK/stderr.txt" || exit_code=$?
  echo "$exit_code"
}

# ═══════════════════════════════════════════════
# TEST FIXTURES
# ═══════════════════════════════════════════════

setup_cwd() {
  local cwd="$TMPWORK/project"
  rm -rf "$cwd"
  mkdir -p "$cwd"
  echo "$cwd"
}

create_verdict() {
  local cwd="$1"
  local arc_id="$2"
  local score="$3"
  local dir="$cwd/tmp/arc/$arc_id/qa"
  mkdir -p "$dir"
  jq -n --argjson score "$score" '{scores: {overall_score: $score}}' > "$dir/${arc_id}-verdict.json"
  # Touch with incremental mtime so sorting works
  sleep 0.1
}

# ═══════════════════════════════════════════════
# TEST CASES
# ═══════════════════════════════════════════════

echo ""
echo "=== Test: Fast-path — no CWD ==="
exit_code=0
echo '{}' | bash "$HOOK_SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "exits 0 with no CWD" "0" "$exit_code"

echo ""
echo "=== Test: Fast-path — fewer than 3 verdicts ==="
cwd=$(setup_cwd)
create_verdict "$cwd" "arc-001" 50
create_verdict "$cwd" "arc-002" 50
exit_code=$(run_hook "$cwd" "session-few-$$")
assert_exit "exits 0 with <3 verdicts" "0" "$exit_code"

echo ""
echo "=== Test: Fast-path — active arc ==="
cwd=$(setup_cwd)
create_verdict "$cwd" "arc-001" 50
create_verdict "$cwd" "arc-002" 50
create_verdict "$cwd" "arc-003" 50
mkdir -p "$cwd/.rune"
touch "$cwd/.rune/arc-phase-loop.local.md"
exit_code=$(run_hook "$cwd" "session-arc-$$")
assert_exit "exits 0 during active arc" "0" "$exit_code"
rm -f "$cwd/.rune/arc-phase-loop.local.md"

echo ""
echo "=== Test: All scores healthy — no suggestion ==="
cwd=$(setup_cwd)
create_verdict "$cwd" "arc-001" 90
create_verdict "$cwd" "arc-002" 85
create_verdict "$cwd" "arc-003" 80
exit_code=$(run_hook "$cwd" "session-healthy-$$")
assert_exit "exits 0 with healthy scores" "0" "$exit_code"

echo ""
echo "=== Test: Marginal scores — suggestion fires ==="
cwd=$(setup_cwd)
create_verdict "$cwd" "arc-001" 40
create_verdict "$cwd" "arc-002" 50
create_verdict "$cwd" "arc-003" 60
exit_code=$(run_hook "$cwd" "session-marginal-$$")
assert_exit "exits 2 with marginal scores" "2" "$exit_code"

echo ""
echo "=== Test: Debounce — second run skipped ==="
# Same session_id should be debounced
exit_code=$(run_hook "$cwd" "session-marginal-$$")
assert_exit "exits 0 on debounced second run" "0" "$exit_code"

echo ""
echo "=== Test: Mixed scores — below 60% marginal threshold ==="
cwd=$(setup_cwd)
create_verdict "$cwd" "arc-001" 90
create_verdict "$cwd" "arc-002" 50
create_verdict "$cwd" "arc-003" 80
create_verdict "$cwd" "arc-004" 85
exit_code=$(run_hook "$cwd" "session-mixed-$$")
assert_exit "exits 0 when only 1/4 marginal" "0" "$exit_code"

# ═══════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════

echo ""
echo "════════════════════════════════"
printf "Results: %d/%d passed" "$PASS_COUNT" "$TOTAL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf " (%d FAILED)" "$FAIL_COUNT"
fi
echo ""
echo "════════════════════════════════"

[[ "$FAIL_COUNT" -eq 0 ]]
