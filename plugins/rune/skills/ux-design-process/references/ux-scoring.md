# UX Finding Severity Scoring Framework

Defines the UX finding prefix scheme (UXH, UXF, UXI, UXC), severity levels (P0-P2), integration with the Rune dedup hierarchy, and scoring rubrics per prefix.

## Finding Prefix Scheme

| Prefix | Domain | Emitted By | Scope |
|--------|--------|-----------|-------|
| `UXH` | Heuristic | ux-heuristic-reviewer | Nielsen/Baymard heuristic violations in UI components |
| `UXF` | Flow | ux-flow-validator | User flow breakages, dead ends, circular loops |
| `UXI` | Interaction | ux-interaction-auditor | Micro-interaction gaps, state transition issues |
| `UXC` | Cognitive | ux-cognitive-walker | Cognitive load, learnability, mental model mismatches |

## Severity Levels

### P0 -- Blocks User Flow

The issue prevents users from completing a core task or causes data loss.

```
Criteria (any one is sufficient):
- User cannot complete the intended action
- Action causes unrecoverable data loss
- Navigation leads to dead end (404, blank page)
- Form submission silently fails
- Critical interactive element is unreachable (keyboard or touch)

Examples:
- UXH-P0: Submit button does nothing (no handler, no feedback)
- UXF-P0: Checkout flow ends at blank confirmation page
- UXI-P0: Modal has no close mechanism (no X, no Escape, no backdrop click)
- UXC-P0: User cannot discover how to perform a required action
```

### P1 -- Degrades Experience

The issue makes the experience frustrating or confusing but users can still complete their task.

```
Criteria (any one is sufficient):
- Missing loading state causes confusion about system status
- Error message is generic and offers no recovery path
- Interaction requires workaround (right-click instead of button)
- Touch target is too small (< 44px) causing frequent mis-taps
- Accessibility barrier affects assistive technology users

Examples:
- UXH-P1: Data table loads with 3-second blank screen (no skeleton)
- UXF-P1: User must navigate back and re-enter data after error
- UXI-P1: Hover tooltip has no keyboard/focus equivalent
- UXC-P1: Form has 15 fields on one page without section breaks
```

### P2 -- Cosmetic / Improvement

The issue is a minor usability improvement or visual inconsistency that doesn't block functionality.

```
Criteria:
- Visual inconsistency that doesn't affect comprehension
- Suboptimal but functional label or message text
- Minor spacing or alignment issue
- Enhancement opportunity (not a deficiency)

Examples:
- UXH-P2: Inconsistent button border radius across pages
- UXF-P2: Success message could be more specific about what was saved
- UXI-P2: Hover effect delay slightly too long (400ms vs recommended 150ms)
- UXC-P2: Icon meaning is guessable but a label would be clearer
```

## Dedup Hierarchy Position

UX prefixes are positioned below FRONT in the Rune dedup hierarchy:

```
SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > UXH > UXF > UXI > UXC > CDX
```

### Dedup Rules

```
1. If a FRONT finding covers the same issue as a UX finding, FRONT wins (higher priority)
2. Within UX prefixes: UXH > UXF > UXI > UXC (heuristic findings subsume others)
3. UX findings never supersede security (SEC) or backend (BACK) findings
4. UX findings with blocking: true are escalated to FRONT tier for visibility
```

### Finding ID Format

```
{PREFIX}-{SEVERITY}-{SEQUENCE}

Examples:
  UXH-P0-001  -- First P0 heuristic finding
  UXF-P1-003  -- Third P1 flow finding
  UXI-P2-001  -- First P2 interaction finding
  UXC-P1-002  -- Second P1 cognitive finding
```

## Scoring Rubrics

### UXH (Heuristic) Scoring

Based on the heuristic-checklist.md evaluation:

```
For each heuristic category (H1-H10):
  - Count applicable items
  - Count FAIL items
  - Weight by severity (P0 x3, P1 x2, P2 x1)

Category score = 10 * (1 - weighted_fails / weighted_total)
Overall UXH score = weighted average across categories

Weights per category:
  weights = getHeuristicWeights(domain)

  Default "general" domain weights (backward-compatible):
    H1:15  H2:5  H3:15  H4:10  H5:15  H6:10  H7:5  H8:5  H9:15  H10:5

  Domain is resolved via:
    1. talisman.yml → ux.industry (manual override, highest precedence)
    2. inferProjectDomain() when confidence >= 0.70
    3. Fallback: "general"

  When a category has 0 applicable items, its weight is redistributed
  proportionally to active categories (preserves relative proportions).

  See [industry-weights.md](industry-weights.md) for:
    - Full weight tables for 8 domains (general, e-commerce, saas, fintech,
      healthcare, creative, education, content)
    - getHeuristicWeights(domain) pseudocode
    - redistributeWeights() algorithm
    - Per-domain rationale citing UX research
```

### UXF (Flow) Scoring

```
For each user flow identified in changed files:
  - Can the user complete the flow? (P0 if no)
  - Are there dead ends? (P0 per dead end)
  - Are there unnecessary loops? (P1 per loop)
  - Is the flow discoverable? (P1 if hidden)
  - Is the flow efficient? (P2 if suboptimal)

Flow score = 10 - (P0_count * 3 + P1_count * 2 + P2_count * 1)
Clamped to [0, 10]
```

### UXI (Interaction) Scoring

```
For each interactive component in scope:
  - Hover state present? (P2 if missing)
  - Focus state present? (P1 if missing)
  - Active state present? (P2 if missing)
  - Disabled state handled? (P1 if missing)
  - Loading transition smooth? (P2 if abrupt)
  - Error recovery available? (P1 if missing)
  - Touch target adequate (>= 44px)? (P1 if not)

Interaction score = 10 - (P0_count * 3 + P1_count * 2 + P2_count * 1)
Clamped to [0, 10]
```

### UXC (Cognitive) Scoring

Only active when `ux.cognitive_walkthrough: true` in talisman.yml.

```
For each user task walkthrough:
  CW-01: Goal visibility       (weight 3)
  CW-02: Action discoverability (weight 3)
  CW-03: Action-goal mapping   (weight 2)
  CW-04: Progress feedback     (weight 2)
  CW-05: Error recovery path   (weight 3)
  CW-06: Learnability          (weight 1)

Cognitive score = 10 * (passed_weight / total_weight)
```

## Integration with TOME

### Finding Format in TOME.md

```markdown
<!-- RUNE:FINDING prefix="UXH" id="UXH-P1-001" severity="P1" file="components/Dashboard.tsx" line="45" scope="in-diff" blocking="false" -->
### UXH-P1-001: Missing loading state for dashboard data fetch

**Heuristic**: H1 (Visibility of System Status)
**Component**: `Dashboard.tsx:45`
**Issue**: `useQuery` result is rendered without checking `isLoading` state. Users see blank content for 1-3 seconds.
**Fix**: Add skeleton screen or loading indicator before data is available.
<!-- RUNE:FINDING:END -->
```

### Blocking Behavior

```
Default: blocking: false (UX findings do not block merge)

Override via talisman.yml:
  ux:
    blocking_findings: true    # All UX findings become blocking
    blocking_severity: P0      # Only P0 findings block (P1/P2 remain non-blocking)

When blocking: true:
  - P0 UX findings set workflow_blocked flag (same as SEC findings)
  - P1/P2 remain non-blocking unless blocking_severity includes them
  - Blocked findings appear in TOME.md with blocking="true" marker
```

## Aggregate UX Score

```
When multiple UX agents run, compute an aggregate:

Aggregate = (
    UXH_score * 0.35 +
    UXF_score * 0.25 +
    UXI_score * 0.25 +
    UXC_score * 0.15    # 0 if cognitive walkthrough disabled
)

If cognitive walkthrough disabled:
  Aggregate = (
    UXH_score * 0.40 +
    UXF_score * 0.30 +
    UXI_score * 0.30
  )

Score interpretation:
  9.0-10.0 = Excellent UX
  7.0-8.9  = Good UX
  5.0-6.9  = Fair UX (review recommended)
  3.0-4.9  = Poor UX (improvements required)
  0.0-2.9  = Critical UX (blocking issues present)
```
