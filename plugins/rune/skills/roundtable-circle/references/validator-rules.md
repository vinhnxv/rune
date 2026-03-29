# Validator Rules — Confidence Scoring and Risk Classification

> Rules for validating Ash outputs: dedup, confidence scoring, and risk assessment.

## Inscription Validation

After all Ash complete, validate outputs against `inscription.json`:

### Circuit Breaker (Check FIRST)

```
IF ALL output files in inscription are missing:
  → Systemic failure. Abort workflow.
  → Write failure notice to TOME.md
  → Skip to cleanup phase (Phase 7)
```

### Per-File Validation

```
FOR each teammate in inscription.teammates:
  file = {output_dir}/{teammate.output_file}
  IF file exists AND file_size > 100 bytes:
    → PASS
  ELSE:
    → FAIL (add to gaps list)
```

### Section Validation

```
FOR each PASS file:
  FOR each section in teammate.required_sections:
    IF grep "## {section}" file:
      → Section present
    ELSE:
      → Section missing (add to warnings)
```

### Seal Validation

```
FOR each PASS file:
  IF grep "SEAL:" file:
    → Parse seal fields
    → Validate: findings >= 0, confidence between 0-1
  ELSE:
    → Missing seal (proceed with file, note in TOME.md)
```

## Confidence Scoring

### Per-Ash Confidence

| Confidence | Range | Meaning | Lead Action |
|-----------|-------|---------|-------------|
| High | ≥ 0.85 | Strong evidence for all findings | Accept findings |
| Medium | 0.70 - 0.84 | Most findings well-evidenced | Spot-check 1-2 P1 findings |
| Low | < 0.70 | Significant uncertainty | Spot-check ALL P1 findings |

### Confidence Calculation

Ash self-assess based on:

```
confidence = (findings_with_rune_trace / total_findings) *
             (files_actually_read / files_claimed_reviewed) *
             self_review_factor

where self_review_factor:
  - 1.0 if self-reviewed with log
  - 0.8 if self-reviewed without log
  - 0.6 if not self-reviewed
```

### Aggregate Confidence

For the overall review:

```
aggregate_confidence = weighted_average(
  each ash.confidence,
  weight = ash.findings_count
)
```

## Risk Classification

### Finding Risk Matrix

| Priority | Evidence Quality | Risk Level |
|----------|-----------------|-----------|
| P1 + High confidence | Verified rune trace | **Critical** — requires fix |
| P1 + Low confidence | Weak/missing trace | **Needs verification** |
| P2 + High confidence | Verified rune trace | **Important** — should fix |
| P2 + Low confidence | Weak/missing trace | **Review** — may be noise |
| P3 (any confidence) | Any | **Advisory** — nice to have |

### Auto-Escalation Rules

| Condition | Action |
|-----------|--------|
| P1 finding with `SEC-` prefix | Always surface in TOME.md summary |
| 2+ Ashes flag same file | Escalate to P1 if any flags P2+ |
| Confidence < 0.5 from any Ash | Flag entire output as unreliable |
| Self-review deleted > 25% of findings | Flag potential quality issue |

## Dedup Rules (Quick Reference)

### Hierarchy

```
SEC (Ward Sentinel) > BACK (Forge Warden) > VEIL (Veil Piercer) > DOUBT (Doubt Seer) > FLOW (Flow Integrity Tracer) > DOC (Knowledge Keeper) > QUAL (Pattern Weaver) > FRONT (Glyph Scribe) > CDX (Codex Oracle)
```

### Same-File, Same-Line Detection

```
FOR each finding A in all outputs:
  FOR each finding B (from different Ash):
    IF A.file == B.file AND abs(A.line - B.line) <= 5:
      → Potential duplicate
      → Keep finding from higher-priority Ash
      → Note: "Also flagged by {other_ash}"
```

### Same-Issue, Different-Priority

```
IF duplicate found AND A.priority != B.priority:
  → Keep the HIGHER priority (P1 > P2 > P3)
  → Note: "{lower_ash} rated this as {lower_priority}"
```

## Gap Reporting

### TOME.md Coverage Gaps Section

```markdown
## Coverage Gaps

### Missing Ash
| Ash | Expected | Status | Impact |
|-----------|----------|--------|--------|
| forge-warden | Yes | Missing | Backend code not reviewed |

### Budget-Limited Coverage
| Ash | Files Assigned | Files Skipped | Skipped Reason |
|-----------|---------------|--------------|----------------|
| ward-sentinel | 20 | 15 | Context budget (20 max) |

### Incomplete Deliverables
| Ash | Missing Sections | Impact |
|-----------|-----------------|--------|
| pattern-weaver | Self-Review Log | Cannot verify finding quality |
```

## Re-Run Recommendations

After validation, generate re-run recommendations:

| Condition | Recommendation |
|-----------|---------------|
| Ash missing entirely | Re-run with `--focus {area}` |
| Confidence < 0.5 | Re-run Ash with reduced scope |
| > 50% files skipped (budget) | Re-run with `--focus {area}` for deeper coverage |
| Multiple hallucinations detected | Re-run Ash with stricter evidence rules |

## References

- [Dedup Runes](dedup-runes.md) — Full deduplication algorithm
- [Inscription Protocol](../../rune-orchestration/references/inscription-protocol.md) — Validation rules
- [Truthsight Pipeline](../../rune-orchestration/references/truthsight-pipeline.md) — Verification layers
