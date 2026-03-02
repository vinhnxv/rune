# Fidelity Scoring Algorithm

Weighted scoring system for measuring how accurately an implementation matches its Visual Spec Map (VSM).

## Scoring Dimensions

| Dimension | Weight | What It Measures |
|-----------|--------|------------------|
| Token Compliance | 25% | Visual properties using design tokens vs hardcoded values |
| Layout Fidelity | 20% | Structural match between VSM region tree and DOM |
| Responsive Coverage | 15% | Specified breakpoints that are implemented |
| Accessibility | 20% | WCAG 2.1 AA requirements satisfied |
| Variant Completeness | 10% | Figma variants with code counterparts |
| State Coverage | 10% | Required UI states implemented |

## Per-Dimension Scoring

### Token Compliance (25%)

```
tokenized = count of visual properties using design tokens or Tailwind utilities
hardcoded = count of visual properties using literal values (hex, px, etc.)
total = tokenized + hardcoded

score = (tokenized / total) * 100

Penalties:
  - Each hardcoded color: -5 points
  - Each off-scale spacing value: -3 points
  - Each arbitrary font-size: -3 points
```

### Layout Fidelity (20%)

```
For each node in VSM region tree:
  Check implementation for:
    - Correct flex/grid direction: +10 per match
    - Correct alignment (justify/items): +5 per match
    - Correct gap value: +5 per match
    - Correct padding: +5 per match
    - Correct nesting depth: +5 per match
    - Correct sizing (fixed/fill/hug): +5 per match

score = (matched_checks / total_checks) * 100

Penalties:
  - Wrong flex direction: -15 points (layout completely wrong)
  - Extra nesting level: -5 per level
  - Missing node: -10 per node
```

### Responsive Coverage (15%)

```
specified = breakpoints in VSM responsive spec
implemented = breakpoints found in component code

score = (implemented / specified) * 100

Bonus:
  + 10 if mobile-first approach used (no-prefix = mobile styles)

Penalties:
  - Missing mobile base styles: -20 (critical)
  - Missing md breakpoint: -15
  - Missing lg breakpoint: -10
```

### Accessibility (20%)

```
Checklist items from VSM accessibility section:
  - Semantic HTML element: +15
  - ARIA attributes (where required): +15
  - Keyboard handlers (interactive elements): +15
  - Focus management: +15
  - Color contrast compliance: +10
  - Image alt text: +10
  - Form labels: +10
  - Touch target sizing: +10

score = (earned_points / total_possible_points) * 100

Critical penalties (auto-fail dimension):
  - Missing keyboard handler on interactive element: score = 0
  - Missing alt text on informational image: -30
```

### Variant Completeness (10%)

```
vsm_variants = variant values in VSM variant map
code_variants = variant values found in component code

score = (code_variants ∩ vsm_variants) / vsm_variants * 100

Penalties:
  - Missing variant entirely: -20 per missing variant
  - Wrong default value: -10
```

### State Coverage (10%)

```
required_states = states marked "Required: Yes" in VSM
implemented_states = states found in component code

score = (implemented_states / required_states) * 100

Penalties:
  - Missing loading state: -20
  - Missing error state: -20
  - Missing empty state: -10 (only if required)
```

## Overall Score Calculation

```
overall = (token * 0.25) + (layout * 0.20) + (responsive * 0.15) +
          (a11y * 0.20) + (variants * 0.10) + (states * 0.10)

Clamp to [0, 100]
```

## Verdict Thresholds

| Score Range | Verdict | Meaning |
|------------|---------|---------|
| 90-100 | EXCELLENT | Implementation matches design precisely |
| 80-89 | PASS | Acceptable with minor polish items |
| 60-79 | NEEDS_WORK | Significant gaps but structure is correct |
| 40-59 | POOR | Major gaps, partial re-implementation needed |
| 0-39 | FAIL | Implementation does not match design |

Default pass threshold: 80 (configurable via `design_sync.fidelity_threshold`).

## P1 Override Rule

Regardless of overall score, if ANY P1 finding exists, the verdict is FAIL:

```
if p1_findings.length > 0:
  verdict = "FAIL"
  reason = "P1 findings present: {p1_findings.map(f => f.id).join(', ')}"
```

## Score Report Format

```markdown
**Fidelity Score: {overall}/100** — {verdict}

| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|----------|
| Token Compliance | {t}/100 | 25% | {t*0.25} |
| Layout Fidelity | {l}/100 | 20% | {l*0.20} |
| Responsive Coverage | {r}/100 | 15% | {r*0.15} |
| Accessibility | {a}/100 | 20% | {a*0.20} |
| Variant Completeness | {v}/100 | 10% | {v*0.10} |
| State Coverage | {s}/100 | 10% | {s*0.10} |
```

## Aesthetic Quality — Companion Metric

Aesthetic quality is scored as a **separate 0-100 metric** reported alongside the fidelity score. It is NOT integrated into the weighted fidelity formula above. Both scores are independent — a component can have high fidelity (matches the design) but low aesthetic quality (the design itself has slop patterns), or vice versa.

### Why Separate

Fidelity measures **correctness** (does the code match the spec?). Aesthetic quality measures **design quality** (does the result look good?). Mixing them would dilute both signals — a pixel-perfect implementation of a bad design should score high on fidelity and low on aesthetics.

### 7 Aesthetic Dimensions

| Dimension | Weight | What It Measures |
|-----------|--------|------------------|
| Visual Hierarchy | 20% | Heading weight progression, contrast between content levels, section separation |
| Typography Quality | 20% | Font pairing, line-height consistency, letter-spacing variation, absence of generic-only fonts |
| Whitespace Balance | 15% | Padding/margin consistency, breathing room, content density balance |
| Color Coherence | 15% | Palette consistency, semantic color use, contrast compliance, temperature variation |
| Layout Personality | 15% | Avoids cookie-cutter grid, intentional asymmetry, visual rhythm variation |
| Micro-Interaction Presence | 10% | Hover states, purposeful transitions, designed focus indicators |
| Design System Fidelity | 5% | Matches project design system personality (sharp vs rounded, dense vs spacious) |

### Aesthetic Score Calculation

```
aesthetic = (hierarchy * 0.20) + (typography * 0.20) + (whitespace * 0.15) +
            (color * 0.15) + (layout_personality * 0.15) +
            (micro_interaction * 0.10) + (system_fidelity * 0.05)

Clamp to [0, 100]
```

### Aesthetic Verdict Thresholds

| Score Range | Verdict | Meaning |
|------------|---------|---------|
| 90-100 | EXCEPTIONAL | Intentional design choices, no slop detected |
| 70-89 | GOOD | Minor improvement opportunities, no slop patterns |
| 50-69 | ADEQUATE | Functional but generic, some slop patterns present |
| 30-49 | BELOW_STANDARD | Multiple slop patterns, lacks visual personality |
| 0-29 | POOR | Pervasive slop, appears auto-generated |

Default threshold: 60 (configurable via `design_sync.aesthetic_review.threshold`).

### Reporting

Both scores are reported together in the design review output:

```markdown
**Fidelity Score: {fidelity}/100** — {fidelity_verdict}
**Aesthetic Score: {aesthetic}/100** — {aesthetic_verdict}
```

The aesthetic-quality-reviewer agent produces the aesthetic score. See the [anti-slop-guardrails.md](anti-slop-guardrails.md) reference for the slop detection patterns used during scoring.

### Opt-In

Aesthetic review is gated by `design_sync.aesthetic_review.enabled` in talisman.yml (default: `false`). When disabled, only the fidelity score is produced.

## Cross-References

- [phase3-fidelity-review.md](phase3-fidelity-review.md) — Review pipeline using scores
- [vsm-spec.md](vsm-spec.md) — Source of truth for comparison
- [anti-slop-guardrails.md](anti-slop-guardrails.md) — Slop detection patterns for aesthetic scoring
