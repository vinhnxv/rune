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
# v3.0.0-alpha.6 (Day 5 C4a): plan_refine absorbed into plan_review.
assert_eq "forge → planning" "planning" "$(_lookup_phase_group "forge")"
assert_eq "forge_qa → planning" "planning" "$(_lookup_phase_group "forge_qa")"
assert_eq "plan_review → planning" "planning" "$(_lookup_phase_group "plan_review")"
assert_eq "verification → planning" "planning" "$(_lookup_phase_group "verification")"

# Work group
# v3.0.0-alpha.6 (Day 5 C4b): drift_review absorbed into work.
assert_eq "work → work" "work" "$(_lookup_phase_group "work")"
assert_eq "work_qa → work" "work" "$(_lookup_phase_group "work_qa")"

# Verification group
assert_eq "gap_analysis → verification" "verification" "$(_lookup_phase_group "gap_analysis")"
assert_eq "gap_remediation → verification" "verification" "$(_lookup_phase_group "gap_remediation")"

# Inspect group
# v3.0.0-alpha.6 (Day 5 C4c): inspect_fix + verify_inspect absorbed into inspect.
assert_eq "inspect → inspect" "inspect" "$(_lookup_phase_group "inspect")"
# v3.0.0-alpha.2: goldmask_verification removed from default order.
# v3.0.0-alpha.1: design family (design_extraction, design_prototype,
# design_verification*, design_iteration) removed.

# Review group
# v3.0.0-alpha.6 (Day 5 C4d): verify_mend absorbed into mend_qa post-step.
assert_eq "code_review → review" "review" "$(_lookup_phase_group "code_review")"
assert_eq "code_review_qa → review" "review" "$(_lookup_phase_group "code_review_qa")"
assert_eq "verify → review" "review" "$(_lookup_phase_group "verify")"
assert_eq "mend → review" "review" "$(_lookup_phase_group "mend")"
assert_eq "mend_qa → review" "review" "$(_lookup_phase_group "mend_qa")"

# Verification group (QA phases)
assert_eq "gap_analysis_qa → verification" "verification" "$(_lookup_phase_group "gap_analysis_qa")"

# Testing group
assert_eq "test → testing" "testing" "$(_lookup_phase_group "test")"
assert_eq "test_qa → testing" "testing" "$(_lookup_phase_group "test_qa")"

# Ship group
# v3.0.0-alpha.6 (Day 5 C4e): deploy_verify removed; pre_ship_validation
# absorbed into ship as STEP -0.5.
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

# ── Negative cases: absorbed/removed phases must NOT be in any group ──
# v3.0.0-alpha.6 (Day 5 C4a–C4e): 7 phases removed from PHASE_ORDER.
# Re-introducing any of them would produce zero test failures without these guards.
assert_eq "plan_refine → empty (absorbed into plan_review, C4a)" "" "$(_lookup_phase_group "plan_refine")"
assert_eq "drift_review → empty (absorbed into work, C4b)" "" "$(_lookup_phase_group "drift_review")"
assert_eq "inspect_fix → empty (absorbed into inspect, C4c)" "" "$(_lookup_phase_group "inspect_fix")"
assert_eq "verify_inspect → empty (absorbed into inspect, C4c)" "" "$(_lookup_phase_group "verify_inspect")"
assert_eq "verify_mend → empty (absorbed into mend_qa post-step, C4d)" "" "$(_lookup_phase_group "verify_mend")"
assert_eq "deploy_verify → empty (removed, C4e)" "" "$(_lookup_phase_group "deploy_verify")"
assert_eq "pre_ship_validation → empty (absorbed into ship STEP -0.5, C4e)" "" "$(_lookup_phase_group "pre_ship_validation")"

# ══════════════════════════════════════════════════
# Test 3: All PHASE_ORDER phases return non-empty group
# v3.0.0-alpha.2: dropped 4 phases (goldmask_verification, goldmask_correlation,
# bot_review_wait, pr_comment_resolution) from the default order.
# ══════════════════════════════════════════════════
echo ""
echo "=== Coverage: all PHASE_ORDER phases return non-empty group ==="
# SYNC-CRITICAL: must match arc-phase-constants.md PHASE_ORDER (canonical, 19 entries
# after v3.0.0-alpha.6 Day 5 absorptions: plan_refine→plan_review (C4a),
# drift_review→work (C4b), inspect_fix+verify_inspect→inspect (C4c),
# verify_mend→mend_qa post-step (C4d), deploy_verify removed +
# pre_ship_validation→ship (C4e)).
# Any divergence indicates drift between bash/JS phase definitions.
PHASE_ORDER=(
  forge forge_qa plan_review verification
  work work_qa
  gap_analysis gap_analysis_qa gap_remediation
  inspect
  code_review code_review_qa verify mend mend_qa
  test test_qa
  ship merge
)

COVERAGE_COUNT=0
for phase in "${PHASE_ORDER[@]}"; do
  group=$(_lookup_phase_group "$phase")
  assert_nonempty "$phase has group" "$group"
  COVERAGE_COUNT=$(( COVERAGE_COUNT + 1 ))
done

# Verify we tested exactly 19 phases (canonical PHASE_ORDER, no conditional extras)
assert_eq "phase count is 19" "19" "$COVERAGE_COUNT"

# ══════════════════════════════════════════════════
# Test 4: Schema exception bound check
# INVARIANT: arc-checkpoint-init.md phases[] has exactly 21 status:"pending" keys
#   = 19 PHASE_ORDER entries + 2 transitional containers (verify_mend + pre_ship_validation).
# If this count drifts, a phantom key was added or a transitional container was removed
# without updating this test. See arc-checkpoint-init.md:416-419 for the documented invariant.
# ══════════════════════════════════════════════════
echo ""
echo "=== Schema exception bound check (phases[] key count) ==="

INIT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/skills/arc/references/arc-checkpoint-init.md"
if [[ -f "$INIT_FILE" ]]; then
  SCHEMA_KEY_COUNT=$(grep -c 'status: "pending"' "$INIT_FILE" 2>/dev/null || echo "0")
  assert_eq "checkpoint phases[] has exactly 21 keys (19 PHASE_ORDER + verify_mend + pre_ship_validation)" "21" "$SCHEMA_KEY_COUNT"

  # Confirm the two transitional containers are present (exception set, not in PHASE_ORDER)
  VERIFY_MEND_PRESENT=$(grep -c 'verify_mend:' "$INIT_FILE" 2>/dev/null || echo "0")
  PRE_SHIP_PRESENT=$(grep -c 'pre_ship_validation:' "$INIT_FILE" 2>/dev/null || echo "0")
  assert_eq "verify_mend transitional container present" "1" "$VERIFY_MEND_PRESENT"
  assert_eq "pre_ship_validation transitional container present" "1" "$PRE_SHIP_PRESENT"
else
  echo "  SKIP: arc-checkpoint-init.md not found at $INIT_FILE — skipping schema bound check"
fi

# ══════════════════════════════════════════════════
# Results
# ══════════════════════════════════════════════════
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total)"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
