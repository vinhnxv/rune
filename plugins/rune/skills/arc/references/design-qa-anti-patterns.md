# Design QA Anti-Pattern Detection Reference

Anti-pattern detection rules for the design-qa-verifier agent. These rules detect low-quality design verification output that indicates the reviewer is "going through the motions" rather than performing genuine fidelity analysis.

Cross-reference: Mirrors the WRK-MOT-01 pattern from work-qa-verifier, adapted for design verification context.

---

## Individual Anti-Pattern Rules

### DES-AP-01: Generic Evidence

**Detection**: The `evidence` field in a finding matches any of these vague phrases:

```regex
/looks? good|matches? (the )?design|implemented correctly|as expected|no issues/i
```

**Score impact**: -30 per finding

**Why this matters**: Generic evidence provides zero diagnostic value. A finding that says "looks good" cannot guide remediation — it's indistinguishable from no review at all.

**Examples of violations**:
```json
{ "evidence": "Component looks good and matches the design" }
{ "evidence": "Implemented correctly as expected" }
{ "evidence": "No issues found" }
```

**Examples of passing evidence**:
```json
{ "evidence": "Button.tsx:23 uses hardcoded #1A73E8 instead of var(--color-primary)" }
{ "evidence": "Card.tsx:45-52 flex-direction remains row at 375px viewport — should stack to column per VSM breakpoint spec" }
```

---

### DES-AP-02: Missing file:line References

**Detection**: The `evidence` field does NOT match the file:line pattern:

```regex
/\w+\.\w+:\d+/
```

**Score impact**: -15 per finding

**Why this matters**: Evidence without file:line references cannot be independently verified. Reviewers must point to specific locations in source files to provide actionable feedback.

**Note**: This is checked per-finding. A finding that references a component path like `src/components/Button/` but lacks a specific line reference still triggers this penalty. The file:line pattern requires at minimum `filename.ext:lineNumber`.

---

### DES-AP-03: Uniform Scores

**Detection**: All findings in `design-findings.json` have identical scores AND `findings.length >= 3`.

**Score impact**: -20 aggregate (applied once)

**Why this matters**: Real design verification naturally produces varying severity levels across different components and dimensions. Uniform scores across 3+ findings suggest the reviewer applied a template score without evaluating each finding individually.

**Edge case**: If all findings genuinely have the same score (rare but possible for small reviews), the composite DES-MOT-01 check prevents false positives by requiring 3+ signals before failing.

---

### DES-AP-04: Zero Findings for Multi-Component Review

**Detection**: `findings.length === 0` when `vsm_count >= 3` (excluding SKIP components).

**Score impact**: -40 aggregate (applied once)

**Why this matters**: A multi-component design review that produces zero findings is statistically implausible. Even well-implemented designs typically have minor discrepancies in token usage, spacing, or responsive behavior. Zero findings with 3+ components strongly indicates the review was not performed.

**SKIP exclusion**: Components with status `SKIP` in the criteria matrix are excluded from the vsm_count. A project with 5 components where 3 are SKIPped has an effective vsm_count of 2, which does not trigger this rule.

---

### DES-AP-05: Missing Dimensions

**Detection**: A component in `design-criteria-matrix` has fewer than 4 of the 6 standard fidelity dimensions covered.

The 6 standard dimensions are:
1. Layout
2. Typography
3. Color
4. Spacing
5. Responsive
6. Accessibility

**Score impact**: -10 per missing dimension (per component)

**Why this matters**: Each dimension represents a distinct aspect of design fidelity. Skipping dimensions suggests incomplete review coverage. The threshold of 4/6 allows flexibility for components where certain dimensions may not apply (e.g., a utility component might not have responsive breakpoints).

---

## Composite Rule: DES-MOT-01

The composite "Going Through the Motions" detector aggregates individual anti-pattern signals:

```javascript
weakness_signals = [
  DES-AP-01 count >= 2,      // 2+ findings with generic evidence
  DES-AP-02 count >= 3,      // 3+ findings without file:line
  DES-AP-03,                  // uniform scores across 3+ findings
  DES-AP-04,                  // zero findings for multi-component review
  DES-AP-05 count >= component_count / 2  // half+ components missing dimensions
]

if (weakness_signals.filter(Boolean).length >= 3) {
  verdict = "FAIL"
  reason = "DES-MOT-01: Design review appears to be going through the motions."
  // Override: this FAIL cannot be overridden by high scores in other dimensions
}
```

### Threshold Rationale

- **3-of-5 signals required**: Prevents false positives from edge cases. A single-component review may naturally trigger DES-AP-04 (no findings) without being a sham.
- **DES-AP-01 threshold (2+)**: One vague description can happen; two or more indicate a pattern.
- **DES-AP-02 threshold (3+)**: Some findings may legitimately reference design tokens or high-level patterns without line numbers. Three or more missing references indicate systemic laziness.
- **DES-AP-05 threshold (component_count / 2)**: Allows some components to have fewer dimensions (e.g., icons, utility components) without triggering the aggregate signal.

### Verdict Override

When DES-MOT-01 triggers, the verdict is FAIL regardless of dimension scores. This prevents a reviewer from padding artifact and completeness dimensions to mask low-quality evidence in the quality dimension.

---

## Relationship to Existing Patterns

The existing "Going Through the Motions" table in design-qa-verifier.md contains quick-check patterns (empty findings + score 100, all scores 100, etc.). The DES-AP rules provide **granular, accumulative** detection:

| Layer | Detection Style | Purpose |
|-------|----------------|---------|
| Quick-check table | Binary pattern match | Catch obvious sham reviews (empty findings, placeholder text) |
| DES-AP rules | Per-finding accumulative scoring | Catch subtle quality degradation (generic evidence, missing references) |
| DES-MOT-01 composite | Multi-signal aggregation | Catch systemic "going through the motions" behavior |

All three layers complement each other. The quick-check table catches blatant issues; DES-AP rules catch nuanced issues; DES-MOT-01 catches the aggregate pattern.

---

## See Also

- `../../agents/qa/design-qa-verifier.md` — Agent definition with full checklist
- `../../agents/qa/work-qa-verifier.md` — Work QA verifier with WRK-MOT-01 (pattern origin)
- `../../skills/discipline/references/design-proof-types.md` — Design proof type definitions
