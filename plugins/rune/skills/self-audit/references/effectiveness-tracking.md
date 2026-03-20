# Effectiveness Tracking — Feedback Loop

Reference document for `/rune:self-audit` effectiveness measurement. Tracks whether applied fixes actually improve subsequent audit scores.

## Overview

The effectiveness feedback loop closes the gap between "we fixed it" and "it actually helped." After a fix is applied via `--apply` and a subsequent arc run completes, this system compares before/after finding states to determine if the fix was effective.

## Data Sources

Effectiveness tracking uses **persistent** data only — no ephemeral `tmp/` files:

| Source | Path | Contains |
|--------|------|----------|
| Meta-QA Echoes | `.rune/echoes/meta-qa/MEMORY.md` | Finding entries with `finding_id`, `recurrence_count`, fix history |
| Arc Checkpoints | `.rune/arc/*/checkpoint.json` | TOME counts, convergence history, phase statuses |
| Post-Arc Echoes | `.rune/echoes/planner/MEMORY.md` | Planning quality patterns |
| Post-Arc Echoes | `.rune/echoes/workers/MEMORY.md` | Implementation quality patterns |
| Post-Arc Echoes | `.rune/echoes/reviewer/MEMORY.md` | Review finding patterns |

## Dimension Mapping

Finding ID prefixes map to quality dimensions for targeted measurement:

| Prefix | Category | Dimension | What it measures |
|--------|----------|-----------|-----------------|
| SA-AGT | Agent | prompt | Agent prompt quality, frontmatter completeness, instruction clarity |
| SA-WF | Workflow | workflow | Workflow definition correctness, phase ordering, orchestration logic |
| SA-HK | Hook | hook | Hook script correctness, registration completeness, event handling |
| SA-RC | Rule Consistency | rule | Cross-file rule alignment, documentation accuracy, config sync |

## Pre/Post Metric Comparison

### Tracking Fix Application

When a fix is applied via `--apply`, record the before-state in the MEMORY.md entry:

```markdown
### [2026-03-19] Pattern: Missing maxTurns in phase-qa-verifier
- **layer**: etched
- **source**: rune:self-audit static-1773916367
- **finding_id**: SA-AGT-001
- **recurrence_count**: 5
- **last_seen**: 2026-03-19
- **fix_applied**: true
- **fix_date**: 2026-03-19
- **fix_run_id**: apply-1773916367
- **pre_fix_snapshot**:
  - findings_total: 42
  - findings_in_dimension: 15
  - dimension: prompt
```

### Measuring Effectiveness

On the next self-audit run after a fix, compare the current state against the pre-fix snapshot:

```javascript
function trackFixEffectiveness(fixEntry, currentFindings) {
  // fixEntry: parsed MEMORY.md entry with fix_applied: true
  // currentFindings: findings from current self-audit run

  const dimension = deriveDimension(fixEntry.finding_id)
  // dimension map: AGT→prompt, WF→workflow, HK→hook, RC→rule

  // Count findings in the same dimension
  const currentDimensionCount = currentFindings.filter(
    f => f.dimension === dimension
  ).length

  const preDimensionCount = fixEntry.pre_fix_snapshot.findings_in_dimension

  // Check if this specific finding is still present
  const findingResolved = !currentFindings.some(
    f => f.id === fixEntry.finding_id
  )

  // Compute improvement
  const dimensionDelta = preDimensionCount - currentDimensionCount
  const totalDelta = fixEntry.pre_fix_snapshot.findings_total -
    currentFindings.length

  // Determine verdict
  let verdict
  if (findingResolved && dimensionDelta > 0) {
    verdict = 'EFFECTIVE'
  } else if (findingResolved && dimensionDelta <= 0) {
    verdict = 'EFFECTIVE'  // finding gone, but other issues appeared
  } else if (!findingResolved && dimensionDelta > 0) {
    verdict = 'NO_CHANGE'  // dimension improved but target finding persists
  } else if (!findingResolved && dimensionDelta === 0) {
    verdict = 'NO_CHANGE'
  } else {
    verdict = 'REGRESSION'  // finding persists AND dimension worsened
  }

  return {
    finding_id: fixEntry.finding_id,
    fix_date: fixEntry.fix_date,
    fix_run_id: fixEntry.fix_run_id,
    dimension,
    pre_dimension_findings: preDimensionCount,
    post_dimension_findings: currentDimensionCount,
    dimension_delta: dimensionDelta,
    finding_resolved: findingResolved,
    verdict
  }
}
```

### Verdict Definitions

| Verdict | Condition | Action |
|---------|-----------|--------|
| **EFFECTIVE** | Target finding resolved | Record success, boost fix pattern confidence in echoes |
| **NO_CHANGE** | Target finding persists, dimension unchanged or improved | Investigate — fix may be incomplete or addressing symptoms |
| **REGRESSION** | Target finding persists AND dimension worsened | Auto-flag for review, consider reverting fix |

## Effectiveness Score

Computed per self-audit run as a ratio:

```
effectiveness_score = resolved_fixed / (resolved_fixed + persistent_fixed)
```

Where:
- `resolved_fixed` = findings that had fixes applied AND are now resolved
- `persistent_fixed` = findings that had fixes applied AND still persist

Score ranges:
- **1.0**: All applied fixes resolved their findings (perfect)
- **0.5-0.99**: Most fixes effective, some need refinement
- **0.1-0.49**: Low fix effectiveness, review fix quality
- **0.0**: No fixes resolved their findings (investigate fix approach)

## Writing Effectiveness Data to meta-qa/MEMORY.md

After computing effectiveness, update the MEMORY.md entry with results:

```markdown
### [2026-03-19] Pattern: Missing maxTurns in phase-qa-verifier
- **layer**: etched
- **source**: rune:self-audit static-1773916367
- **finding_id**: SA-AGT-001
- **recurrence_count**: 5
- **last_seen**: 2026-03-20
- **fix_applied**: true
- **fix_date**: 2026-03-19
- **fix_run_id**: apply-1773916367
- **pre_fix_snapshot**:
  - findings_total: 42
  - findings_in_dimension: 15
  - dimension: prompt
- **effectiveness**:
  - measured_date: 2026-03-20
  - measured_run_id: static-1773920000
  - verdict: EFFECTIVE
  - finding_resolved: true
  - pre_dimension_findings: 15
  - post_dimension_findings: 12
  - dimension_delta: 3
  - effectiveness_score: 0.75
```

### Run-Level Summary Entry

Additionally, write a run-level summary entry for tracking trends:

```markdown
### [2026-03-20] Effectiveness: Run static-1773920000
- **layer**: inscribed
- **source**: rune:self-audit effectiveness-1773920000
- **run_id**: static-1773920000
- **compared_against**: apply-1773916367
- **fixes_measured**: 3
- **fixes_effective**: 2
- **fixes_no_change**: 1
- **fixes_regression**: 0
- **effectiveness_score**: 0.67
- **dimension_breakdown**:
  - prompt: 2 effective, 0 no_change, 0 regression
  - workflow: 0 effective, 1 no_change, 0 regression
```

## Regression Auto-Flagging

When a fix produces a `REGRESSION` verdict:

1. **Immediate**: Add `⚠️ REGRESSION` marker to the MEMORY.md entry
2. **Report**: Include in the self-audit report under a dedicated "Regression Alerts" section
3. **Echo promotion**: Promote the entry to `etched` tier if not already (regressions are high-signal)
4. **Suggestion**: Include in report: "Consider reverting commit `self-audit-fix({context}): [SA-{CAT}-{NNN}]` via `git revert`"

### Regression Report Section

```markdown
## ⚠️ Regression Alerts

| Fix | Applied | Verdict | Dimension Delta | Action |
|-----|---------|---------|-----------------|--------|
| SA-RC-001 | 2026-03-10 | REGRESSION | -4 (75→71) | Review commit `self-audit-fix(rule): [SA-RC-001]` |

### SA-RC-001: Plugin version sync
- **Fix applied**: Synced marketplace.json version to plugin.json
- **Expected**: Rule consistency findings should decrease
- **Actual**: 4 new rule consistency findings appeared
- **Possible cause**: Version sync triggered downstream validation that exposed previously hidden issues
- **Recommendation**: Investigate new findings — regression may be "surfacing hidden debt" rather than true regression
```

## Available Data for Comparison

### Arc Checkpoint Data

Arc checkpoints (`.rune/arc/*/checkpoint.json`) provide indirect quality signals:

```javascript
// Fields available in checkpoint.json
{
  "arc_id": "arc-1773916367",
  "phases": {
    "code_review": { "status": "completed", "tome_finding_count": 12 },
    "gap_analysis": { "status": "completed", "gap_count": 3 },
    "test": { "status": "completed", "test_pass_rate": 0.95 }
  },
  "convergence_history": [
    { "iteration": 1, "findings": 15 },
    { "iteration": 2, "findings": 8 }
  ]
}
```

These are supplementary — the primary effectiveness metric is finding presence/absence in self-audit runs.

### Post-Arc Echo Data

Post-arc echoes in role-specific MEMORY.md files provide behavioral signals:

- `planner/MEMORY.md`: Patterns in plan quality (missing sections, unclear criteria)
- `workers/MEMORY.md`: Patterns in implementation quality (test gaps, evidence gaps)
- `reviewer/MEMORY.md`: Patterns in review finding types (recurring P1s, dimension distribution)

Cross-reference with self-audit findings to identify causal chains:
- Fix to agent prompt → check if worker echo patterns changed
- Fix to workflow → check if arc checkpoint convergence improved
- Fix to hook → check if enforcement echo entries decreased

## Timing Considerations

Effectiveness can only be measured after:
1. A fix is applied (`--apply`)
2. At least one arc run completes after the fix
3. A subsequent self-audit run executes

If no post-fix arc has run, the effectiveness section reports:
```markdown
## Fix Effectiveness
> Pending — {N} fixes applied but no subsequent arc run detected.
> Run an arc pipeline and then `/rune:self-audit` to measure effectiveness.
```

## Edge Cases

- **Multiple fixes applied before measurement**: Track each independently. If fixes overlap in dimension, note "shared dimension — improvement may be attributed to multiple fixes."
- **Fix reverted before measurement**: Check git log for revert commits with `self-audit-fix` prefix. If reverted, mark as `verdict: REVERTED` and skip effectiveness measurement.
- **No arc between audit runs**: Use previous self-audit findings as baseline instead of arc data. Less precise but still valid for finding presence/absence comparison.
- **Finding ID reassigned**: If a resolved finding's ID is later assigned to a different issue, the effectiveness measurement for the original fix remains valid — it tracked the original finding, not the ID.
