# Arc Pipeline Architecture

Pipeline overview, orchestrator design, and phase transition contracts.
Extracted from SKILL.md in v1.110.0 for phase-isolated context architecture.

## Pipeline Overview

> v3.0.0-alpha.2 default order is 26 phases. Goldmask verification/correlation,
> bot-review-wait, pr-comment-resolution, semantic_verification, task_decomposition,
> test_coverage_critique, release_quality_check were removed (alpha.1+alpha.2).
> Goldmask remains a standalone command (`/rune:goldmask`); PR-comment work moves
> to external pr-guardian or `/rune:resolve-all-gh-pr-comments`.

```
Phase 1:   FORGE → Research-enrich plan sections
    ↓ (enriched-plan.md)
Phase 1.5: FORGE QA → Independent forge artifact verification
    ↓ (forge-qa-verdict.json) — retry forge on FAIL
Phase 2:   PLAN REVIEW → 3 parallel reviewers + circuit breaker
    ↓ (plan-review.md) — HALT on BLOCK
Phase 2.5: PLAN REFINEMENT → Extract CONCERNs, write concern context (conditional)
    ↓ (concern-context.md) — WARN on all-CONCERN (auto-proceed; --confirm to pause)
Phase 2.7: VERIFICATION GATE → Deterministic plan checks (zero LLM)
    ↓ (verification-report.md)
Phase 5:   WORK → Swarm implementation + incremental commits
    ↓ (work-summary.md + committed code)
Phase 5.1: WORK QA → Independent work artifact verification
    ↓ (work-qa-verdict.json) — retry work on FAIL
Phase 5.2: DRIFT REVIEW → Off-task code detection (advisory)
    ↓ (drift-review.md) — non-blocking
Phase 5.5: GAP ANALYSIS → Check plan criteria vs committed code (deterministic + LLM)
    ↓ (gap-analysis.md) — WARN only, never halts
Phase 5.6: GAP ANALYSIS QA → Independent gap-analysis verification
    ↓ (gap_analysis-qa-verdict.json) — retry on FAIL
Phase 5.8: GAP REMEDIATION → Auto-fix FIXABLE findings from VERDICT (v1.51.0)
    ↓ (gap-remediation-report.md) — conditional; WARN only, never halts
Phase 5.9: INSPECT → Plan-vs-code Inspector Ashes deep audit (4 inspectors, 11 dimensions)
    ↓ (VERDICT.md)
Phase 5.95: INSPECT FIX → Auto-fix FIXABLE findings from VERDICT
    ↓ (inspect-fix-report.md)
Phase 5.97: VERIFY INSPECT → Convergence check (orchestrator-only)
    ↓ converged → proceed | re-inspect → loop
Phase 6:   CODE REVIEW (deep) → Multi-wave Roundtable Circle review (--deep)
    ↓ (TOME.md)
Phase 6.5: CODE REVIEW QA → Independent code-review artifact verification
    ↓ (code_review-qa-verdict.json) — retry on FAIL
Phase 6.7: VERIFY (findings) → Classify TOME findings TRUE_POSITIVE/FALSE_POSITIVE/NEEDS_CONTEXT
    ↓ (VERDICTS.md) — conditional on arc.verify.enabled
Phase 7:   MEND → Parallel finding resolution
    ↓ (resolution-report.md) — HALT on >3 FAILED
Phase 7.3: MEND QA → Independent mend artifact verification
    ↓ (mend-qa-verdict.json) — retry mend on FAIL
Phase 7.5: VERIFY MEND → Convergence controller (adaptive review-mend loop)
    ↓ converged → proceed | retry → loop to Phase 6+7 | halted → warn + proceed
Phase 7.7: TEST → 4-tier QA gate: unit → property → integration → E2E/browser
    ↓ (test-report.md) — WARN only, never halts
Phase 7.8: TEST QA → Independent test artifact verification
    ↓ (test-qa-verdict.json) — retry on FAIL
Phase 8:   DEPLOY VERIFY → Conditional deployment-relevant validation
    ↓ (deploy-verify-report.md) — conditional on deployment-relevant files
Phase 8.5: PRE-SHIP VALIDATION → Dual-gate completion check (v1.80.0)
    ↓ (pre-ship-report.md) — non-blocking, proceeds with diagnostics in PR body
Phase 9:   SHIP → Push branch + create PR (orchestrator-only)
    ↓ (pr-body.md + checkpoint.pr_url)
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
| PLAN REVIEW | PLAN REFINEMENT | `plan-review.md` | 3 reviewer verdicts (PASS/CONCERN/BLOCK) |
| PLAN REFINEMENT | VERIFICATION | `concern-context.md` | Extracted concern list. Plan not modified |
| VERIFICATION | WORK | `verification-report.md` | Deterministic check results (PASS/WARN) |
| WORK | DRIFT REVIEW | Working tree + `work-summary.md` | Git diff of committed changes + task summary |
| DRIFT REVIEW | GAP ANALYSIS | `drift-review.md` | Off-task code report (advisory) |
| GAP ANALYSIS | GAP REMEDIATION | `gap-analysis.md` | Plan criteria gap report |
| GAP REMEDIATION | INSPECT | `gap-remediation-report.md` | Fixed findings list + deferred list |
| INSPECT | INSPECT FIX | `VERDICT.md` | Inspector Ashes verdict (completion %, dimensions, gaps) |
| INSPECT FIX | VERIFY INSPECT | `inspect-fix-report.md` | Fixed gap list (or skipped) |
| VERIFY INSPECT | CODE REVIEW | Convergence verdict | converged → proceed (or re-inspect loop) |
| CODE REVIEW | VERIFY (findings) | `TOME.md` | TOME with `<!-- RUNE:FINDING ... -->` markers |
| VERIFY (findings) | MEND | `VERDICTS.md` | Per-finding TRUE_POSITIVE/FALSE_POSITIVE/NEEDS_CONTEXT classification |
| MEND | VERIFY MEND | `resolution-report.md` | Fixed/FP/Failed finding list |
| VERIFY MEND | MEND (retry) | `review-focus-round-{N}.json` | Phase 6+7 reset to pending |
| VERIFY MEND | TEST | `resolution-report.md` + checkpoint convergence | Convergence verdict |
| TEST | DEPLOY VERIFY | `test-report.md` | Test results with pass_rate, coverage_pct |
| DEPLOY VERIFY | PRE-SHIP VALIDATION | `deploy-verify-report.md` | Conditional verdict (or skipped) |
| PRE-SHIP VALIDATION | SHIP | `pre-ship-report.md` | Dual-gate validation verdict |
| SHIP | MERGE | `pr-body.md` + `checkpoint.pr_url` | PR created, URL stored |
| MERGE | Done | `merge-report.md` | Merged or auto-merge enabled |
