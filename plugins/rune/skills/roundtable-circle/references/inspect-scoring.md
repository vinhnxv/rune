# Inspect Scoring — Verdict Determination Algorithm

> Reference for `/rune:inspect` Phase 5. Computes completion percentage, dimension scores, and final verdict.

## Completion Scoring

### Per-Requirement Completion

Each Inspector Ash classifies requirements with a status and completion percentage:

| Status | Completion % | Description |
|--------|-------------|-------------|
| `COMPLETE` | 100% | Fully implemented with evidence |
| `PARTIAL` | 25-75% | Some code exists but incomplete. Inspector provides specific % |
| `MISSING` | 0% | No evidence of implementation found |
| `DEVIATED` | 50% | Implemented differently from plan. Inspector assesses alignment |

### Overall Completion

```
overallCompletion = sum(requirement.completion) / requirements.length
```

Weighted by priority:
```
weights = { P1: 3, P2: 2, P3: 1 }
weightedSum = sum(requirement.completion * weights[requirement.priority])
totalWeight = sum(weights[requirement.priority])
overallCompletion = weightedSum / totalWeight
```

## Dimension Scoring

### 9 Dimensions (0-10 scale)

Each Inspector Ash scores their assigned dimensions. Scores are computed from findings:

| Dimension | Inspector | Score Formula |
|-----------|-----------|---------------|
| Correctness | Grace Warden | `10 - (P1 * 3 + P2 * 1.5 + P3 * 0.5)`, floor 0, saturated* |
| Completeness | Grace Warden | `overallCompletion / 10` (maps 0-100% to 0-10) |
| Failure Modes | Ruin Prophet | `10 - (missing_handlers * 2 + weak_handlers * 1)`, floor 0 |
| Security | Ruin Prophet | `10 - (P1_sec * 4 + P2_sec * 2 + P3_sec * 0.5)`, floor 0 |
| Design | Sight Oracle | `10 - (coupling_issues * 2 + pattern_violations * 1.5)`, floor 0 |
| Performance | Sight Oracle | `10 - (P1_perf * 3 + P2_perf * 1.5 + P3_perf * 0.5)`, floor 0 |
| Observability | Vigil Keeper | `10 - (missing_logging * 1 + missing_metrics * 2 + missing_traces * 1.5)`, floor 0 |
| Test Coverage | Vigil Keeper | `testCoverageRatio * 10` (estimated from test file presence) |
| Maintainability | Vigil Keeper | `10 - (complexity_issues * 1.5 + naming_issues * 0.5 + doc_gaps * 1)`, floor 0 |

*\*Saturation note: When a score floors at 0, the raw (unclamped) negative value is preserved in the VERDICT.md as `raw_score` to indicate severity beyond saturation. Example: a Correctness raw score of -5 (floored to 0) indicates more severe issues than a raw score of -1 (also floored to 0). Verdict Binder includes raw scores when `score === 0`.*

### Priority-Weighted Dimension Aggregate

The overall dimension score uses priority order:

```
dimensionWeights = {
  Correctness: 1.0,      // Highest priority
  "Failure Modes": 0.9,
  Security: 0.9,
  Design: 0.7,
  Performance: 0.6,
  Completeness: 0.8,
  Observability: 0.4,
  "Test Coverage": 0.5,
  Maintainability: 0.4
}

weightedDimScore = sum(score * weight) / sum(weights)
```

## Gap Classification

### 9 Gap Categories

Findings from all Inspectors are classified into gap categories:

| Gap Category | Source Inspectors | Classification Rule |
|-------------|-------------------|---------------------|
| Correctness | Grace Warden | Logic errors, wrong behavior, incorrect data flow |
| Coverage | Grace Warden | Missing requirements, unimplemented features |
| Wiring | Grace Warden | Integration point gaps, missing file modifications, unregistered code (WIRE- prefix, NOT auto-fixable) |
| Test | Vigil Keeper | Missing tests, untested paths, low coverage |
| Observability | Vigil Keeper | Missing logs, metrics, traces, health checks |
| Security | Ruin Prophet | Auth gaps, injection risks, secret exposure |
| Operational | Ruin Prophet | Missing rollback, config gaps, deployment risks |
| Architectural | Sight Oracle | Layer violations, coupling, design drift |
| Performance | Sight Oracle | N+1 queries, missing indexes, blocking I/O, caching gaps |
| Documentation | Vigil Keeper | Missing docs, stale docs, undocumented APIs |

### Gap Priority

Gaps inherit priority from their source findings:
- **P1 (Critical)**: Blocks deployment or creates security risk
- **P2 (Important)**: Should be addressed before production
- **P3 (Minor)**: Improvement opportunity, not blocking

## Verdict Determination

### Verdict Logic

```
function determineVerdict(completion, gaps, dimensionScores):
  p1Gaps = gaps.filter(g => g.priority === "P1")
  p2Gaps = gaps.filter(g => g.priority === "P2")
  p1Security = p1Gaps.filter(g => g.category === "Security" || g.category === "Correctness")

  // Read thresholds from talisman (with defaults)
  completionThreshold = config?.inspect?.completion_threshold ?? 80
  gapThreshold = config?.inspect?.gap_threshold ?? 20

  // CRITICAL_ISSUES: any P1 security/correctness gap OR very low completion
  if (p1Security.length > 0 || completion < gapThreshold):
    return "CRITICAL_ISSUES"

  // INCOMPLETE: low completion
  if (completion < 50):
    return "INCOMPLETE"

  // GAPS_FOUND: medium completion OR P2 gaps exist
  if (completion < completionThreshold || p2Gaps.length > 0):
    return "GAPS_FOUND"

  // READY: high completion AND no P1 gaps
  if (completion >= completionThreshold && p1Gaps.length === 0):
    return "READY"

  return "GAPS_FOUND"  // Default fallback
```

### Verdict Summary

| Verdict | Meaning | Criteria |
|---------|---------|----------|
| `READY` | Implementation matches plan | >= threshold% completion AND 0 P1 gaps |
| `GAPS_FOUND` | Partially implemented | 50-threshold% completion OR P2 gaps |
| `INCOMPLETE` | Significant work remaining | 20-49% completion |
| `CRITICAL_ISSUES` | Blockers found | < 20% OR P1 security/correctness gaps |

## VERDICT.md Output Template

```markdown
# Inspection Verdict

> The Tarnished gazes upon the land, measuring what has been forged against what was decreed.

## Summary

| Metric | Value |
|--------|-------|
| Plan | {plan_path} |
| Requirements | {total_requirements} |
| Overall Completion | {completion}% |
| Verdict | **{VERDICT}** |
| Inspectors | {inspector_count} |
| Date | {timestamp} |

## Requirement Matrix

| # | Requirement | Status | Completion | Inspector | Evidence |
|---|------------|--------|------------|-----------|----------|
| REQ-001 | {text} | {COMPLETE/PARTIAL/MISSING/DEVIATED} | {N}% | {inspector} | {file:line or "not found"} |

## Dimension Scores

| Dimension | Score | P1 | P2 | P3 | Inspector |
|-----------|-------|----|----|-----|-----------|
| Correctness | {X}/10 | {count} | {count} | {count} | Grace Warden |
| Completeness | {X}/10 | — | — | — | Grace Warden |
| Failure Modes | {X}/10 | {count} | {count} | {count} | Ruin Prophet |
| Security | {X}/10 | {count} | {count} | {count} | Ruin Prophet |
| Design | {X}/10 | {count} | {count} | {count} | Sight Oracle |
| Performance | {X}/10 | {count} | {count} | {count} | Sight Oracle |
| Observability | {X}/10 | {count} | {count} | {count} | Vigil Keeper |
| Test Coverage | {X}/10 | {count} | {count} | {count} | Vigil Keeper |
| Maintainability | {X}/10 | {count} | {count} | {count} | Vigil Keeper |

## Gap Analysis

### Critical Gaps (P1)

- [ ] **[{PREFIX}-{NUM}]** {gap_description} — `{file:line}`
  - **Category:** {gap_category}
  - **Inspector:** {inspector_name}
  - **Evidence:** {code snippet or observation}

### Important Gaps (P2)

{same format}

### Minor Gaps (P3)

{same format}

## Recommendations

### Immediate Actions
{P1 gaps that must be addressed before deployment}

### Next Steps
{P2 gaps prioritized by impact}

### Future Improvements
{P3 gaps for backlog consideration}
```

## Edge Cases

| Case | Handling |
|------|----------|
| 0 requirements extracted | Hard error in Phase 0.5 — no verdict produced (plan must contain actionable items) |
| All requirements COMPLETE | Verify at least 1 dimension score < 8 before READY (sanity check) |
| Inspector produced no findings | Score that dimension 10/10, note "no issues found" |
| Inspector timeout/crash | Mark dimension as "unscored", exclude from aggregate |
| Plan describes external systems | Mark requirements as "out-of-scope" if no local code expected |
