#!/usr/bin/env bash
# test-phase-groups.sh — Tests for scripts/lib/phase-groups.sh
#
# Usage: bash plugins/rune/scripts/tests/test-phase-groups.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Source phase-groups.sh ──
source "${LIB_DIR}/phase-groups.sh"

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
# Test 1: Known phases return correct group
# ══════════════════════════════════════════════════
echo "=== _lookup_phase_group correctness ==="

# Planning group
assert_eq "forge → planning" "planning" "$(_lookup_phase_group "forge")"
assert_eq "forge_qa → planning" "planning" "$(_lookup_phase_group "forge_qa")"
assert_eq "plan_review → planning" "planning" "$(_lookup_phase_group "plan_review")"
assert_eq "plan_refine → planning" "planning" "$(_lookup_phase_group "plan_refine")"
assert_eq "verification → planning" "planning" "$(_lookup_phase_group "verification")"
assert_eq "semantic_verification → planning" "planning" "$(_lookup_phase_group "semantic_verification")"

# Design group
assert_eq "design_extraction → design" "design" "$(_lookup_phase_group "design_extraction")"
assert_eq "design_prototype → design" "design" "$(_lookup_phase_group "design_prototype")"
assert_eq "task_decomposition → design" "design" "$(_lookup_phase_group "task_decomposition")"

# Work group
assert_eq "work → work" "work" "$(_lookup_phase_group "work")"
assert_eq "work_qa → work" "work" "$(_lookup_phase_group "work_qa")"
assert_eq "drift_review → work" "work" "$(_lookup_phase_group "drift_review")"
assert_eq "storybook_verification → work" "work" "$(_lookup_phase_group "storybook_verification")"

# Verification group
assert_eq "design_verification → verification" "verification" "$(_lookup_phase_group "design_verification")"
assert_eq "gap_analysis → verification" "verification" "$(_lookup_phase_group "gap_analysis")"
assert_eq "codex_gap_analysis → verification" "verification" "$(_lookup_phase_group "codex_gap_analysis")"
assert_eq "gap_remediation → verification" "verification" "$(_lookup_phase_group "gap_remediation")"

# Inspect group
assert_eq "inspect → inspect" "inspect" "$(_lookup_phase_group "inspect")"
assert_eq "inspect_fix → inspect" "inspect" "$(_lookup_phase_group "inspect_fix")"
assert_eq "verify_inspect → inspect" "inspect" "$(_lookup_phase_group "verify_inspect")"
assert_eq "goldmask_verification → inspect" "inspect" "$(_lookup_phase_group "goldmask_verification")"

# Review group
assert_eq "code_review → review" "review" "$(_lookup_phase_group "code_review")"
assert_eq "mend → review" "review" "$(_lookup_phase_group "mend")"
assert_eq "verify_mend → review" "review" "$(_lookup_phase_group "verify_mend")"
assert_eq "design_iteration → review" "review" "$(_lookup_phase_group "design_iteration")"

# Testing group
assert_eq "test → testing" "testing" "$(_lookup_phase_group "test")"
assert_eq "browser_test → testing" "testing" "$(_lookup_phase_group "browser_test")"
assert_eq "test_coverage_critique → testing" "testing" "$(_lookup_phase_group "test_coverage_critique")"

# Ship group
assert_eq "deploy_verify → ship" "ship" "$(_lookup_phase_group "deploy_verify")"
assert_eq "ship → ship" "ship" "$(_lookup_phase_group "ship")"
assert_eq "merge → ship" "ship" "$(_lookup_phase_group "merge")"

# ══════════════════════════════════════════════════
# Test 2: Unknown phase returns empty string
# ══════════════════════════════════════════════════
echo ""
echo "=== Unknown phase returns empty ==="
assert_eq "unknown_phase → empty" "" "$(_lookup_phase_group "unknown_phase")"
assert_eq "empty string → empty" "" "$(_lookup_phase_group "")"
assert_eq "nonexistent → empty" "" "$(_lookup_phase_group "nonexistent")"

# ══════════════════════════════════════════════════
# Test 3: All 45 PHASE_ORDER phases return non-empty group
# ══════════════════════════════════════════════════
echo ""
echo "=== Coverage: all 45 phases return non-empty group ==="
PHASE_ORDER=(
  forge forge_qa plan_review plan_refine verification semantic_verification
  design_extraction design_prototype task_decomposition
  work work_qa drift_review storybook_verification
  design_verification design_verification_qa ux_verification gap_analysis gap_analysis_qa codex_gap_analysis gap_remediation
  inspect inspect_fix verify_inspect goldmask_verification
  code_review code_review_qa goldmask_correlation verify mend mend_qa verify_mend design_iteration
  test test_qa browser_test browser_test_fix verify_browser_test test_coverage_critique
  deploy_verify pre_ship_validation release_quality_check ship bot_review_wait pr_comment_resolution merge
)

COVERAGE_COUNT=0
for phase in "${PHASE_ORDER[@]}"; do
  group=$(_lookup_phase_group "$phase")
  assert_nonempty "$phase has group" "$group"
  COVERAGE_COUNT=$(( COVERAGE_COUNT + 1 ))
done

# Verify we tested exactly 45 phases
assert_eq "phase count is 45" "45" "$COVERAGE_COUNT"

# ══════════════════════════════════════════════════
# Results
# ══════════════════════════════════════════════════
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total)"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
