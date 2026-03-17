# Phase 3: Fidelity Review Protocol

Algorithm for scoring implementation fidelity against the Visual Spec Map (VSM).

## Review Pipeline

### Step 1: Load Review Context

```
1. Read VSM file for the target component
2. Read the implemented component file(s)
3. Read the design-implementation-reviewer agent's analysis framework
4. If available: load previous review results for delta comparison
```

### Step 2: Static Analysis (Code-Level)

Automated checks that don't require visual rendering:

```
Token Compliance:
  1. Grep component for hardcoded color values (hex, rgb, hsl)
  2. Compare against VSM token map — every visual property should use a token
  3. Score: (tokenized_properties / total_visual_properties) * 100

Layout Fidelity:
  1. Parse component JSX/template for flex/grid classes
  2. Compare against VSM region tree layout specifications
  3. Check: direction, alignment, gap, padding, sizing
  4. Score: (matching_properties / total_layout_properties) * 100

Responsive Coverage:
  1. Grep for breakpoint prefixes (sm:, md:, lg:, xl:)
  2. Compare against VSM responsive spec
  3. Score: (implemented_breakpoints / specified_breakpoints) * 100

Variant Completeness:
  1. Parse component props interface
  2. Compare against VSM variant map
  3. Score: (implemented_variants / specified_variants) * 100

State Coverage:
  1. Grep for loading/error/empty state conditionals
  2. Compare against required states from VSM
  3. Score: (implemented_states / required_states) * 100

Accessibility:
  1. Check for ARIA attributes, keyboard handlers, labels
  2. Compare against VSM accessibility requirements
  3. Score: (implemented_a11y / required_a11y) * 100
```

### Step 3: Visual Analysis (When Agent-Browser Available)

```
if agentBrowserAvailable:
  1. Render component in Storybook or test harness
  2. Capture screenshot of each variant/state
  3. Compare screenshot layout against Figma frame structure
  4. Identify visual discrepancies:
     - Spacing drift (gap/padding differs)
     - Color drift (wrong shade/opacity)
     - Typography drift (wrong size/weight/leading)
     - Alignment drift (items not centered/justified as designed)
  5. Add visual findings to review output
```

See [screenshot-comparison.md](screenshot-comparison.md) for browser automation details.

### Step 4: Scoring

See [fidelity-scoring.md](fidelity-scoring.md) for the weighted scoring algorithm.

### Step 5: Finding Classification

| Priority | Criteria | Examples |
|----------|----------|---------|
| P1 (Critical) | Design contract violation | Hardcoded colors, wrong layout direction, missing a11y |
| P2 (High) | Fidelity gap | Missing responsive breakpoint, incomplete variant |
| P3 (Medium) | Polish issue | Spacing 2px off-scale, wrong shadow level |

### Step 5.5: DES-Prefixed Criterion Evidence

Each finding is tagged with a DES-prefixed criterion ID for design convergence tracking.
Format: `DES-{ComponentName}-{dimension}` (e.g., `DES-Button-tokens`, `DES-Card-a11y`).

For each dimension scored in Step 2, emit a DES- criterion with evidence:

```json
{
  "id": "DES-Button-tokens",
  "component": "Button",
  "dimension": "tokens",
  "status": "PASS",
  "score": 95,
  "proof_type": "token_scan",
  "evidence": "47/49 visual properties use design tokens. 2 remaining: box-shadow uses raw value (P3).",
  "failure_code": null
}
```

DES- criteria feed into the design convergence loop (see
[design-convergence.md](../../../discipline/references/design-convergence.md)) for
per-criterion iteration. The fidelity score remains as a secondary convergence gate.

### Step 6: Review Output

Write to `{workDir}/reviews/{component-name}.md`:

```markdown
## Fidelity Review: {component_name}

**Score: {overall}/100** (Token: {t}, Layout: {l}, Responsive: {r}, A11Y: {a}, Variants: {v}, States: {s})
**Verdict: {PASS|NEEDS_WORK|FAIL}** (threshold: {config.fidelity_threshold ?? 80})
**DES Criteria: {pass}/{total} PASS** (DSR: {dsr})

### Findings
[P1/P2/P3 findings with DES-{Component}-{dimension} prefixes]

### VSM Compliance Matrix
| VSM Section | Compliance | Notes |
|------------|-----------|-------|
| Token Map | {pct}% | {summary} |
| Region Tree | {pct}% | {summary} |
| Variant Map | {pct}% | {summary} |
| Responsive | {pct}% | {summary} |
| Accessibility | {pct}% | {summary} |
| States | {pct}% | {summary} |
```

## Pass/Fail Criteria

```
overall_score >= config.fidelity_threshold (default: 80) → PASS
overall_score >= 60 AND no P1 findings → NEEDS_WORK (minor fixes)
overall_score < 60 OR any P1 findings → FAIL (re-implementation needed)
```

## Cross-References

- [fidelity-scoring.md](fidelity-scoring.md) — Weighted scoring formula
- [screenshot-comparison.md](screenshot-comparison.md) — Visual comparison
- [vsm-spec.md](vsm-spec.md) — VSM schema for comparison source
