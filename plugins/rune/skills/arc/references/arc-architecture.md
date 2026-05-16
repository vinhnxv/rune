# Arc Pipeline Architecture

Pipeline overview, orchestrator design, and phase transition contracts.
Extracted from SKILL.md in v1.110.0 for phase-isolated context architecture.

## Pipeline Overview

> v3.0.0-alpha.6 default order is 19 phases. Goldmask verification/correlation,
> bot-review-wait, pr-comment-resolution, semantic_verification, task_decomposition,
> test_coverage_critique, release_quality_check were removed (alpha.1+alpha.2).
> plan_refinement, drift_review, inspect_fix, verify_inspect, verify_mend, deploy_verify,
> and pre_ship_validation were absorbed or removed in alpha.6 (Day 5 arc surface trim).
> Goldmask remains a standalone command (`/rune:goldmask`); PR-comment work moves
> to external pr-guardian or `/rune:resolve-all-gh-pr-comments`.

```
Phase 1:   FORGE → Research-enrich plan sections
    ↓ (enriched-plan.md)
Phase 1.5: FORGE QA → Independent forge artifact verification
    ↓ (forge-qa-verdict.json) — retry forge on FAIL
Phase 2:   PLAN REVIEW → 3 parallel reviewers + circuit breaker + CONCERN extraction (absorbed plan_refinement)
    ↓ (plan-review.md) — HALT on BLOCK; WARN on CONCERN (auto-proceed; --confirm to pause)
Phase 2.7: VERIFICATION GATE → Deterministic plan checks (zero LLM)
    ↓ (verification-report.md)
Phase 5:   WORK → Swarm implementation + incremental commits + drift advisory (absorbed drift_review)
    ↓ (work-summary.md + committed code)
Phase 5.1: WORK QA → Independent work artifact verification
    ↓ (work-qa-verdict.json) — retry work on FAIL
Phase 5.9: INSPECT → Unified plan-vs-implementation engine (v3.0.0-alpha.7 Day 6):
    STEP A: Deterministic pre-checks (absorbed gap_analysis STEP A)
      → inspect/deterministic.md (acceptance criteria coverage, doc consistency,
        plan-section coverage, spec compliance matrix, scope creep, stale refs)
    STEP 1-4: 4 Inspector Ashes audit + verdict-binder synthesis
      → inspect/VERDICT.md
    STEP 4.5: Halt-decision gate (absorbed gap_analysis STEP D)
      → inspect/UNIFIED.md + plan-file writeback (Implementation Status appendix)
      Task Completion Gate (PR #310 fix) HARD-BLOCKS in non-headless mode if completion < 100%
    STEP 5: Gap-fixer dispatch (absorbed inspect_fix C4c + gap_remediation Day 6)
      → inspect/remediation-report.md (conditional on needs_remediation)
    STEP 6: Convergence eval (absorbed verify_inspect C4c)
      → up to 2 converge rounds (audit + fix per round); on retry phase resets to pending
Phase 6:   CODE REVIEW (deep) → Multi-wave Roundtable Circle review (--deep)
    ↓ (TOME.md)
Phase 6.5: CODE REVIEW QA → Independent code-review artifact verification
    ↓ (code_review-qa-verdict.json) — retry on FAIL
Phase 6.7: VERIFY (findings) → Classify TOME findings TRUE_POSITIVE/FALSE_POSITIVE/NEEDS_CONTEXT
    ↓ (VERDICTS.md) — conditional on arc.verify.enabled
Phase 7:   MEND → Parallel finding resolution
    ↓ (resolution-report.md) — HALT on >3 FAILED
Phase 7.3: MEND QA → Independent mend artifact verification + convergence eval (absorbed verify_mend)
    ↓ (mend-qa-verdict.json) — retry mend on FAIL; convergence: converge/retry loop to Phase 6+7/halt
Phase 7.7: TEST → 4-tier QA gate: unit → property → integration → E2E/browser
    ↓ (test-report.md) — WARN only, never halts
Phase 7.8: TEST QA → Independent test artifact verification
    ↓ (test-qa-verdict.json) — retry on FAIL
Phase 9:   SHIP → Pre-ship validation STEP -0.5 (absorbed pre_ship_validation) + Push branch + create PR
    ↓ (pr-body.md + checkpoint.pr_url) — BLOCK verdict halts; WARN emits diagnostics; PASS silent
Phase 9.5: MERGE → Rebase + conflict check + auto-merge (orchestrator-only)
    ↓ (merge-report.md)
Post-arc: PLAN STAMP → Append completion record to plan file
Post-arc: COMPLETION REPORT → Display summary to user
Output: Implemented, reviewed, fixed, shipped, and merged feature
```

**Phase numbering note**: Phase numbers match the legacy pipeline phases from devise.md and appraise.md for cross-command consistency. Phase 4, 8, and 8.7 are reserved. Always use `PHASE_ORDER` for iteration order, not phase numbers.

## Arc Orchestrator Design (ARC-1)

The arc orchestrator is a **lightweight dispatcher**, not a monolithic agent. With the phase-isolated architecture (v1.110.0), each phase runs as its own Claude Code turn with fresh context. The `arc-phase-stop-hook.sh` drives phase iteration via the Stop hook pattern.

> **Delegation Contract**: The arc orchestrator delegates — it does NOT implement. When a phase
> instructs "Read and execute arc-phase-X.md", this means: load the algorithm into context, then
> delegate to the appropriate sub-command (`/rune:forge`, `/rune:strive`, `/rune:appraise`,
> `/rune:mend`). The orchestrator MUST NOT apply fixes, write code, or conduct reviews directly.

**Phase invocation model**: Each phase algorithm is a function invoked per-turn. Phase reference files use `return` for early exits — this exits the phase, and the Stop hook proceeds to the next phase in `PHASE_ORDER`.

## Phase Transition Contracts (ARC-3)

| From | To | Artifact | Contract |
|------|----|----------|----------|
| FORGE | PLAN REVIEW | `enriched-plan.md` | Markdown plan with enriched sections |
| PLAN REVIEW | VERIFICATION | `plan-review.md` + `concern-context.md` | 3 reviewer verdicts (PASS/CONCERN/BLOCK); CONCERN extraction sub-step 2.5 inline |
| VERIFICATION | WORK | `verification-report.md` | Deterministic check results (PASS/WARN) |
| WORK | INSPECT | Working tree + `work-summary.md` + `drift-review.md` | Git diff of committed changes + task summary; drift advisory emitted inline |
| INSPECT | CODE REVIEW | `inspect/VERDICT.md` + `inspect/deterministic.md` + `inspect/UNIFIED.md` + `inspect/remediation-report.md` + plan-file Implementation Status appendix | v3.0.0-alpha.7 Day 6: STEP A deterministic + STEP 1-4 audit + STEP 4.5 halt-gate (Task Completion Gate + plan writeback) + STEP 5 gap-fixer dispatch + STEP 6 convergence eval all inline; converge → proceed \| retry → loop \| halt-non-bypassable → error (non-headless) \| halt-bypassable → warn + proceed (headless/CI) |
| CODE REVIEW | VERIFY (findings) | `TOME.md` | TOME with `<!-- RUNE:FINDING ... -->` markers |
| VERIFY (findings) | MEND | `VERDICTS.md` | Per-finding TRUE_POSITIVE/FALSE_POSITIVE/NEEDS_CONTEXT classification |
| MEND | MEND QA | `resolution-report.md` | Fixed/FP/Failed finding list |
| MEND QA | MEND (retry) | `review-focus-round-{N}.json` + convergence verdict | Phase 6+7 reset to pending (convergence eval inline in mend_qa post-step) |
| MEND QA | TEST | `resolution-report.md` + checkpoint convergence | Convergence verdict: converged → TEST |
| TEST | TEST QA | `test-report.md` | Test results with pass_rate, coverage_pct |
| TEST QA | SHIP | `test-qa-verdict.json` | QA verdict; SHIP STEP -0.5 runs pre-ship validation inline |
| SHIP | MERGE | `pr-body.md` + `checkpoint.pr_url` | PR created, URL stored; BLOCK halts ship; WARN adds PR body section |
| MERGE | Done | `merge-report.md` | Merged or auto-merge enabled |
