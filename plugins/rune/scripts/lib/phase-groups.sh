#!/bin/bash
# scripts/lib/phase-groups.sh
# Phase-to-group lookup for arc --step-groups mode.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/phase-groups.sh"
#   group=$(_lookup_phase_group "forge")   # returns "planning"
#   group=$(_lookup_phase_group "unknown") # returns ""
#
# SYNC-CRITICAL: Phase group assignments are mirrored in:
#   1. arc-phase-constants.md PHASE_GROUPS (JavaScript reference)
#   2. This file (Bash lookup for boundary detection in stop hook)
# These MUST stay in sync. When adding a new phase to PHASE_ORDER,
# also add it to the appropriate group here AND in arc-phase-constants.md.
#
# SOURCING GUARD: Safe to source multiple times (idempotent — function redefinition only).

# Maps a phase name to its group ID.
# Returns empty string for unknown phases (should not happen if SYNC-CRITICAL is maintained).
_lookup_phase_group() {
  local phase="$1"
  case "$phase" in
    forge|forge_qa|plan_review|verification)
      echo "planning" ;;
    # v3.0.0-alpha.6 (Day 5 C4a): plan_refine absorbed into plan_review.
    work|work_qa)
      echo "work" ;;
    # v3.0.0-alpha.6 (Day 5 C4b): drift_review absorbed into work.
    gap_analysis|gap_analysis_qa|gap_remediation)
      echo "verification" ;;
    inspect)
      echo "inspect" ;;
    # v3.0.0-alpha.6 (Day 5 C4c): inspect_fix + verify_inspect absorbed into inspect.
    code_review|code_review_qa|verify|mend|mend_qa|verify_mend)
      echo "review" ;;
    test|test_qa)
      echo "testing" ;;
    # v3.0.0-alpha.2: bot_review_wait, pr_comment_resolution removed from default order.
    # v3.0.0-alpha.2 (codex-strip sync, self-audit 1778278942): semantic_verification,
    # task_decomposition, test_coverage_critique, release_quality_check removed —
    # they are no longer in PHASE_ORDER, so they cannot reach this lookup.
    # v3.0.0-alpha.2 (audit 1778280306): design_extraction, design_prototype,
    # design_verification, design_verification_qa, design_iteration removed —
    # the design family was cut in v3.0.0-alpha.1; bash side now matches.
    # v3.0.0-alpha.3 (TOME pr523-524-1778336733): storybook_verification,
    # ux_verification, browser_test, browser_test_fix, verify_browser_test
    # removed — these were never canonical post-alpha.1 but lingered as dead
    # case arms.
    deploy_verify|pre_ship_validation|ship|merge)
      echo "ship" ;;
    *)
      echo "" ;;
  esac
}
