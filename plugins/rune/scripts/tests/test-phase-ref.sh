#!/usr/bin/env bash
# test-phase-ref.sh — Tests for scripts/lib/phase-ref.sh
#
# Usage: bash plugins/rune/scripts/tests/test-phase-ref.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# _phase_ref returns paths relative to the repo root (e.g., plugins/rune/skills/arc/...)
# REPO_ROOT is four levels up from the tests/ directory:
#   tests/ → scripts/ → plugins/rune/ → plugins/ → repo-root/
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# ── Source phase-ref.sh ──
source "${LIB_DIR}/phase-ref.sh"

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
    printf "  FAIL: %s (expected='%s', actual='%s')\n" "$test_name" "$expected" "$actual"
  fi
}

assert_nonempty() {
  local test_name="$1"
  local actual="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ -n "$actual" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s (got '%s')\n" "$test_name" "$actual"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected non-empty, got empty)\n" "$test_name"
  fi
}

# ══════════════════════════════════════════════════
# Test 1: All 19 PHASE_ORDER phases return non-empty path AND file exists
# SYNC-CRITICAL: must match arc-phase-constants.md PHASE_ORDER (19 entries
# as of v3.0.0-alpha.6 after Day 5 absorptions).
# ══════════════════════════════════════════════════
echo "=== PHASE_ORDER phases: _phase_ref returns non-empty path that exists ==="

PHASE_ORDER=(
  forge forge_qa
  plan_review verification
  work work_qa
  gap_analysis gap_analysis_qa
  gap_remediation
  inspect
  code_review code_review_qa
  verify mend mend_qa
  test test_qa
  ship merge
)

for phase in "${PHASE_ORDER[@]}"; do
  ref=$(_phase_ref "$phase")
  assert_nonempty "${phase}: _phase_ref returns non-empty path" "$ref"
  if [[ -n "$ref" ]]; then
    if [[ -f "${REPO_ROOT}/${ref}" ]]; then
      TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
      PASS_COUNT=$(( PASS_COUNT + 1 ))
      printf "  PASS: %s: file exists (%s)\n" "$phase" "$ref"
    else
      TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      printf "  FAIL: %s: file NOT found at %s\n" "$phase" "${REPO_ROOT}/${ref}"
    fi
  fi
done

# Verify we tested exactly 19 phases
COVERAGE_COUNT="${#PHASE_ORDER[@]}"
assert_eq "phase count is 19" "19" "$COVERAGE_COUNT"

# ══════════════════════════════════════════════════
# Test 2: 5 removed/absorbed phases return empty string
# v3.0.0-alpha.6 (Day 5 C4a-C4e): these phases were absorbed or removed.
# If _phase_ref returns non-empty for any of them, the mapping is out of sync.
# ══════════════════════════════════════════════════
echo ""
echo "=== Absorbed/removed phases: _phase_ref returns empty string ==="

REMOVED_PHASES=(
  plan_refine      # C4a: absorbed into plan_review
  drift_review     # C4b: absorbed into work
  inspect_fix      # C4c: absorbed into inspect
  verify_inspect   # C4c: absorbed into inspect
  deploy_verify    # C4e: removed entirely
)

for phase in "${REMOVED_PHASES[@]}"; do
  ref=$(_phase_ref "$phase")
  assert_eq "${phase} → empty (absorbed/removed)" "" "$ref"
done

# ══════════════════════════════════════════════════
# Test 3: Unknown phase returns empty string
# ══════════════════════════════════════════════════
echo ""
echo "=== Unknown phase returns empty ==="
assert_eq "unknown_phase → empty" "" "$(_phase_ref "unknown_phase")"
assert_eq "empty string → empty" "" "$(_phase_ref "")"

# ══════════════════════════════════════════════════
# Results
# ══════════════════════════════════════════════════
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total)"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
