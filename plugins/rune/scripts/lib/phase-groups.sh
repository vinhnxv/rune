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
    forge|forge_qa|plan_review|plan_refine|verification|semantic_verification)
      echo "planning" ;;
    design_extraction|design_prototype|task_decomposition)
      echo "design" ;;
    work|work_qa|drift_review|storybook_verification)
      echo "work" ;;
    design_verification|design_verification_qa|ux_verification|gap_analysis|gap_analysis_qa|codex_gap_analysis|gap_remediation)
      echo "verification" ;;
    inspect|inspect_fix|verify_inspect|goldmask_verification)
      echo "inspect" ;;
    code_review|code_review_qa|goldmask_correlation|verify|mend|mend_qa|verify_mend|design_iteration)
      echo "review" ;;
    test|test_qa|browser_test|browser_test_fix|verify_browser_test|test_coverage_critique)
      echo "testing" ;;
    deploy_verify|pre_ship_validation|release_quality_check|ship|bot_review_wait|pr_comment_resolution|merge)
      echo "ship" ;;
    *)
      echo "" ;;
  esac
}
