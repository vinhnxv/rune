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
Phase 2:   PLAN REVIEW → 3 parallel reviewers + circuit breaker
    ↓ (plan-review.md) — HALT on BLOCK
Phase 2.5: PLAN REFINEMENT → Extract CONCERNs, write concern context (conditional)
    ↓ (concern-context.md) — WARN on all-CONCERN (auto-proceed; --confirm to pause)
Phase 2.7: VERIFICATION GATE → Deterministic plan checks (zero LLM)
    ↓ (verification-report.md)
Phase 3:   DESIGN EXTRACTION → Figma VSM extraction (conditional, v1.109.0)
    ↓ (tmp/arc/{id}/vsm/) — conditional: design_sync.enabled + Figma URL in plan
Phase 5:   WORK → Swarm implementation + incremental commits
    ↓ (work-summary.md + committed code)
Phase 5.2: DESIGN VERIFICATION → VSM fidelity check (conditional, v1.109.0)
    ↓ (design-verification.md) — conditional: VSM files exist from Phase 3
Phase 5.5: GAP ANALYSIS → Check plan criteria vs committed code (deterministic + LLM)
    ↓ (gap-analysis.md) — WARN only, never halts
Phase 5.8: GAP REMEDIATION → Auto-fix FIXABLE findings from Inspector Ashes VERDICT (v1.51.0)
    ↓ (gap-remediation-report.md) — conditional; WARN only, never halts
Phase 6:   CODE REVIEW (deep) → Multi-wave Roundtable Circle review (--deep)
    ↓ (tome.md)
Phase 7:   MEND → Parallel finding resolution
    ↓ (resolution-report.md) — HALT on >3 FAILED
Phase 7.5: VERIFY MEND → Convergence controller (adaptive review-mend loop)
    ↓ converged → proceed | retry → loop to Phase 6+7 | halted → warn + proceed
Phase 7.6: DESIGN ITERATION → Screenshot→analyze→fix loop (conditional, v1.109.0)
    ↓ (design-iteration.md) — conditional: design_verification fidelity score < threshold
Phase 7.7: TEST → 3-tier QA gate: unit → integration → E2E/browser (v1.43.0)
    ↓ (test-report.md) — WARN only, never halts
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
| VERIFICATION | DESIGN EXTRACTION | `verification-report.md` | Deterministic check results (PASS/WARN) |
| DESIGN EXTRACTION | WORK | `tmp/arc/{id}/vsm/`, `tmp/arc/{id}/design/` | VSM files per component (or skipped) |
| WORK | DESIGN VERIFICATION | Working tree + `work-summary.md` | Git diff of committed changes + task summary |
| DESIGN VERIFICATION | GAP ANALYSIS | `design-verification-report.md` | Fidelity report + design-findings.json (or skipped) |
| GAP REMEDIATION | CODE REVIEW | `gap-remediation-report.md` | Fixed findings list + deferred list |
| CODE REVIEW | MEND | `tome.md` | TOME with `<!-- RUNE:FINDING ... -->` markers |
| MEND | VERIFY MEND | `resolution-report.md` | Fixed/FP/Failed finding list |
| VERIFY MEND | MEND (retry) | `review-focus-round-{N}.json` | Phase 6+7 reset to pending |
| VERIFY MEND | DESIGN ITERATION | `resolution-report.md` + checkpoint convergence | Convergence verdict |
| DESIGN ITERATION | TEST | `design-iteration-report.md` | Improved fidelity report (or skipped) |
| TEST | PRE-SHIP VALIDATION | `test-report.md` | Test results with pass_rate, coverage_pct |
| PRE-SHIP VALIDATION | SHIP | `pre-ship-report.md` | Dual-gate validation verdict |
| SHIP | MERGE | `pr-body.md` + `checkpoint.pr_url` | PR created, URL stored |
| MERGE | Done | `merge-report.md` | Merged or auto-merge enabled |
