# Self-Audit Report Template

Use this template to generate `SELF-AUDIT-REPORT.md` during Phase 3 aggregation.

## Template

```markdown
# Self-Audit Report — {date}

## Summary

| Dimension | Score | Findings | Status |
|-----------|-------|----------|--------|
| Workflow Definition | {N}/100 | {P1}/{P2}/{P3} | {verdict} |
| Prompt/Agent Consistency | {N}/100 | {P1}/{P2}/{P3} | {verdict} |
| Rule Consistency | {N}/100 | {P1}/{P2}/{P3} | {verdict} |
| Hook Integrity | {N}/100 | {P1}/{P2}/{P3} | {verdict} |
| **Overall** | **{N}/100** | **{total}** | **{verdict}** |

## Grounding Verification

- Total findings: {N}
- Verified (file:line confirmed): {N} ({pct}%)
- Dropped (hallucinated): {N}

## Critical Findings (P1)

{For each P1 finding, copy the SA-{DIM}-{NNN} block from dimension findings}

## Warnings (P2)

{For each P2 finding, copy the SA-{DIM}-{NNN} block from dimension findings}

## Info (P3) — verbose only

{For each P3 finding, copy the SA-{DIM}-{NNN} block. Only include when --verbose flag is set.}

## Self-Referential Findings

{Findings where self_referential: true — meta-qa agents auditing themselves}

## Recurrence Patterns (from Echoes)

| Finding Pattern | Occurrences | First Seen | Echo Tier |
|----------------|-------------|------------|-----------|
| {pattern} | {N} | {date} | {tier} |

## Improvement Roadmap

Prioritized list of suggested improvements derived from findings:
1. {Highest-impact improvement with affected files}
2. {Second highest-impact improvement}
3. ...
```

## Scoring Formula

```
dimension_score = 100 - (P1_count * 15 + P2_count * 5 + P3_count * 1)
clamped to [0, 100]

overall_score = avg(all active dimension scores)
```

## Verdict Thresholds

| Score Range | Verdict | Meaning |
|-------------|---------|---------|
| 90-100 | EXCELLENT | System is well-maintained |
| 70-89 | GOOD | Minor issues, no action required |
| 50-69 | NEEDS_ATTENTION | Several issues, review recommended |
| 0-49 | CRITICAL | Significant issues, action required |

## Grounding Rules

During aggregation, verify every finding:

1. **File existence**: `Glob(filePath)` — does the cited file exist?
2. **Line content**: `Read(filePath, { offset: line - 1, limit: 3 })` — does the evidence match?
3. **Quote accuracy**: Compare evidence quote against actual file content
4. **Drop unverified**: Remove findings where file or line doesn't match (hallucinated)
5. **Report grounding stats**: Total findings, verified count, dropped count

## Deduplication Rules

When findings from multiple agents overlap:

1. **Same file:line**: Keep the finding with higher severity
2. **Same pattern, different files**: Keep all (each is a separate instance)
3. **Cross-dimension overlap**: Note in both findings with cross-reference (e.g., "See also SA-WF-003")
