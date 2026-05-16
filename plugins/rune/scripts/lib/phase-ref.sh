#!/bin/bash
# scripts/lib/phase-ref.sh
# Phase-to-reference-file mapping for arc pipeline phases.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/phase-ref.sh"
#   ref=$(_phase_ref "forge")          # returns "plugins/rune/skills/arc/references/arc-phase-forge.md"
#   ref=$(_phase_ref "plan_refine")    # returns "" (absorbed phase)
#
# SYNC-CRITICAL: Phase-to-file mapping is authoritative for the stop hook
#   phase dispatch. When adding a new PHASE_ORDER phase, add a case arm here.
#   When absorbing a phase, remove its arm and add a comment explaining the
#   absorption (do NOT leave an arm that returns a now-deleted file path).
#
# SOURCING GUARD: Safe to source multiple times (idempotent — function redefinition only).

# Maps each phase name to its reference file path (relative to plugin root).
# Returns empty string for unknown or absorbed phases.
_phase_ref() {
  local phase="$1"
  local base="plugins/rune/skills/arc/references"
  case "$phase" in
    forge)                    echo "${base}/arc-phase-forge.md" ;;
    plan_review)              echo "${base}/arc-phase-plan-review.md" ;;
    # plan_refine absorbed into plan_review in v3.0.0-alpha.6 (Day 5 C4a)
    verification)             echo "${base}/verification-gate.md" ;;
    work)                     echo "${base}/arc-phase-work.md" ;;
    # drift_review absorbed into work in v3.0.0-alpha.6 (Day 5 C4b)
    # gap_analysis + gap_remediation absorbed into inspect in v3.0.0-alpha.7 (Day 6).
    # The deterministic checks and halt-gate live in sub-references:
    # inspect-step-a-deterministic.md and inspect-step-d-halt-gate.md.
    inspect)                  echo "${base}/arc-phase-inspect.md" ;;
    # inspect_fix + verify_inspect absorbed into inspect in v3.0.0-alpha.6 (Day 5 C4c)
    code_review)              echo "${base}/arc-phase-code-review.md" ;;
    verify)                   echo "${base}/arc-phase-verify.md" ;;
    mend)                     echo "${base}/arc-phase-mend.md" ;;
    # verify_mend absorbed into mend_qa (post-QA convergence step) in
    # v3.0.0-alpha.6 (Day 5 C4d) — see arc-phase-qa-gate.md.
    test)                     echo "${base}/arc-phase-test.md" ;;
    # deploy_verify removed + pre_ship_validation absorbed into ship in
    # v3.0.0-alpha.6 (Day 5 C4e). See arc-phase-ship.md STEP -0.5/-0.4.
    ship)                     echo "${base}/arc-phase-ship.md" ;;
    merge)                    echo "${base}/arc-phase-merge.md" ;;
    # gap_analysis_qa retired in v3.0.0-alpha.7 (Day 6 Q3) — manifest dropped.
    forge_qa|work_qa|code_review_qa|mend_qa|test_qa)
                              echo "${base}/arc-phase-qa-gate.md" ;;
    # Absorbed/removed phases — return empty so callers can guard:
    plan_refine|drift_review|inspect_fix|verify_inspect|verify_mend|deploy_verify|pre_ship_validation|gap_analysis|gap_analysis_qa|gap_remediation)
                              echo "" ;;
    *)                        echo "" ;;
  esac
}
