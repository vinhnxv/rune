# Phase Necessity Report Template

Template for the necessity analysis section of SELF-AUDIT-REPORT.md.

## Report Section Template

```markdown
## Phase Necessity Analysis

**Arc runs analyzed**: {run_count} ({date_range})
**Model**: {model_id}
**Analysis confidence**: {high|medium|low} (requires >= 3 runs for high confidence)

### Per-Phase Scores

| Phase | Necessity | Avg Duration | Artifacts | Quality Δ | Skip Rate | Uniqueness | Recommendation |
|-------|-----------|-------------|-----------|-----------|-----------|------------|----------------|
{for each phase, sorted by necessity score ascending:}
| {phase_name} | {necessity_score:.2f} | {avg_duration} | {artifact_value:.2f} | {quality_delta:.2f} | {skip_rate:.0%} | {uniqueness:.2f} | {recommendation} |

### Recommendations

#### CANDIDATE_FOR_REMOVAL (necessity < 0.40)

{for each candidate, sorted by score ascending:}
- **{phase_name}** ({necessity_score:.2f}) — {reason}
  - Artifact value: {artifact_value} | Quality Δ: {quality_delta} | Skip rate: {skip_rate}
  - Suggestion: {specific_action — e.g., "merge into {other_phase}" or "remove with A/B test"}

#### REVIEW (necessity 0.40-0.69)

{for each review candidate:}
- **{phase_name}** ({necessity_score:.2f}) — {reason}
  - Consider: {optimization suggestion}

#### ESSENTIAL (necessity >= 0.70)

{for each essential phase:}
- **{phase_name}** ({necessity_score:.2f}) — {value_summary}

### Model Context

These scores reflect the capabilities of **{model_id}** at the time of analysis.
As model capabilities improve, phases that scaffold model limitations may score
lower in future audits. Re-run necessity analysis after major model upgrades.

### Trend Analysis

{if multiple audit runs available:}
| Phase | {date_1} | {date_2} | {date_3} | Trend |
|-------|----------|----------|----------|-------|
| {phase} | {score} | {score} | {score} | {improving ↑ | stable → | declining ↓} |

### Caveats

- Necessity scores are **advisory only** — human judgment required before removing phases
- Low scores may reflect insufficient arc run data rather than low phase value
- Phases with high uniqueness scores catch issues no other phase catches — removing them
  eliminates a safety net even if their overall necessity score is marginal
- Skip rate inflates necessity for rarely-triggered conditional phases — consider their value
  when they DO trigger, not just their average contribution
```

## Scoring Thresholds

| Score Range | Label | Color | Action |
|-------------|-------|-------|--------|
| >= 0.70 | ESSENTIAL | green | No action needed |
| 0.40-0.69 | REVIEW | yellow | Investigate optimization opportunities |
| < 0.40 | CANDIDATE_FOR_REMOVAL | red | Evaluate for removal or merging |

## Aggregation into SELF-AUDIT-REPORT.md

When necessity analysis completes, the orchestrator adds a "Phase Necessity" section
to the main SELF-AUDIT-REPORT.md:

1. Insert after the existing dimension sections (Workflow, Agent, Hook, Rule)
2. Use the per-phase table from above
3. Add a single-line dimension score:
   ```
   necessity_dimension_score = 100 - (candidates_for_removal * 10 + review_needed * 3)
   clamped to [0, 100]
   ```
4. Include in the overall score calculation as an additional dimension

## Quality Snapshot Schema

The necessity analyzer depends on `quality_snapshot` data in arc checkpoints.
When available, the checkpoint phase entry includes:

```json
{
  "phase": "code_review",
  "status": "completed",
  "duration_ms": 45000,
  "quality_snapshot": {
    "pre": {
      "finding_count": 0,
      "p1_count": 0,
      "file_coverage": 0.0
    },
    "post": {
      "finding_count": 12,
      "p1_count": 2,
      "file_coverage": 0.85
    }
  }
}
```

When `quality_snapshot` is absent (older checkpoints), the analyzer falls back to:
- Estimating quality delta from artifact presence/size (lower confidence)
- Marking the quality_delta component as "estimated" in the report

This ensures backward compatibility — the necessity analyzer produces useful output
even with checkpoints that predate the quality_snapshot enhancement.
