# Brownfield UX Design Process

UX process for existing codebases. Covers heuristic evaluation, usability audit, incremental improvement workflow, design debt assessment, and backward-compatible UX improvements.

## Process Overview

```
Phase 1: Assessment        -- Audit current UX state and identify debt
Phase 2: Prioritization    -- Score issues by impact and effort
Phase 3: Incremental Fix   -- Apply improvements without breaking changes
Phase 4: Verification      -- Validate improvements against baselines
```

## Phase 1: Assessment

### Design Debt Inventory

Scan the existing codebase for UX debt signals:

| Signal | What to Look For | Severity |
|--------|-----------------|----------|
| Missing states | Components without loading/error/empty handlers | P1 |
| Hardcoded strings | User-facing text not in i18n system | P2 |
| Inaccessible controls | `<div onClick>` instead of `<button>`, missing ARIA | P0 |
| Inconsistent patterns | Multiple loading spinner implementations | P2 |
| No error recovery | `catch` blocks that silently swallow errors | P1 |
| Missing keyboard support | Interactive elements not focusable | P0 |
| Touch target violations | Click targets < 44px | P1 |
| Layout shift | No skeleton/placeholder causing CLS | P1 |

### Heuristic Audit Workflow

```
1. Select scope:
   - Changed files only (for code review context)
   - Feature area (for targeted audit)
   - Full application (for comprehensive audit)

2. Run heuristic checklist against scope:
   - See heuristic-checklist.md for the full 50+ item checklist
   - Score each item: PASS / FAIL / N/A
   - Record evidence (file path, line number, component name)

3. Group findings by category:
   - Visibility of system status
   - User control and freedom
   - Consistency and standards
   - Error prevention
   - Recognition over recall
   - Flexibility and efficiency
   - Aesthetic and minimalist design
   - Error recovery
   - Help and documentation

4. Generate UX debt score:
   - Count FAIL items per category
   - Weight by severity (P0 x3, P1 x2, P2 x1)
   - Score = 10 - (weighted_fails / total_items) * 10
```

### Code Pattern Detection

Automated signals the UX review agents look for:

```
# Missing loading states
- Components with useQuery/useSWR/fetch but no isLoading/isPending check
- Async operations without loading indicator
- Data-dependent renders without Suspense boundary

# Missing error handling
- try/catch blocks that render nothing on error
- API calls without error state in the component
- Forms without validation feedback

# Accessibility gaps
- img tags without alt attribute
- Interactive divs/spans without role or tabIndex
- Color-only indicators (no icon or text supplement)
- Links without descriptive text ("click here", "read more")

# Interaction issues
- Click handlers without keyboard equivalent (onKeyDown)
- Hover-only tooltips (no focus trigger)
- Drag-and-drop without keyboard alternative
- Auto-playing animations without pause control
```

## Phase 2: Prioritization

### Impact vs Effort Matrix

```
             High Impact
                 |
    QUICK WINS   |   BIG BETS
    (Do first)   |   (Plan carefully)
                 |
  ---------------+---------------
                 |
    FILL-INS     |   MONEY PITS
    (Batch later) |   (Avoid or defer)
                 |
             Low Impact
  Low Effort                High Effort
```

### Scoring Rubric

| Factor | Weight | Criteria |
|--------|--------|----------|
| User impact | 40% | How many users affected? How severely? |
| Accessibility | 30% | Does it block assistive technology users? |
| Effort | 20% | Lines of code, risk of regression |
| Consistency | 10% | Does fixing this improve patterns elsewhere? |

### Priority Queue Template

```yaml
ux_debt:
  - id: UXH-001
    category: error_prevention
    description: "Delete button has no confirmation dialog"
    component: "UserSettings.tsx:45"
    impact: high
    effort: low
    priority: P0  # Quick win
    fix: "Add confirmation dialog before destructive action"

  - id: UXI-003
    category: loading_states
    description: "Dashboard loads with blank screen for 2-3 seconds"
    component: "Dashboard.tsx:12"
    impact: high
    effort: medium
    priority: P1  # Important improvement
    fix: "Add skeleton screen matching dashboard layout"
```

## Phase 3: Incremental Fix

### Backward-Compatible Improvement Strategies

| Strategy | When to Use | Example |
|----------|-------------|---------|
| **Additive** | Adding missing states | Add loading skeleton alongside existing content |
| **Wrapping** | Enhancing existing components | Wrap `<div onClick>` in `<button>` with preserved styles |
| **Progressive** | Replacing patterns gradually | New components use design tokens, old ones keep hardcoded values |
| **Feature-flagged** | Risky UX changes | A/B test new navigation with `ux.newNav` flag |

### Safe Refactoring Patterns

```
1. Add, don't replace (initially)
   - Add aria-label to existing buttons (non-breaking)
   - Add loading state check before render (additive)
   - Add error boundary around component (wrapping)

2. Extract, then improve
   - Extract inline styles to design tokens
   - Extract repeated patterns to shared components
   - Extract hardcoded strings to i18n keys

3. Test the improvement
   - Visual regression test for style changes
   - Accessibility audit for ARIA changes
   - Keyboard navigation test for focus changes
```

### Common Quick Fixes

| Issue | Fix | Risk |
|-------|-----|------|
| Missing alt text | Add descriptive alt to images | None |
| No focus styles | Add `:focus-visible` outline | Low (visual only) |
| Missing loading | Add `if (isLoading) return <Skeleton />` | Low |
| No error boundary | Wrap in `<ErrorBoundary>` | Low |
| Small touch targets | Increase padding to 44px minimum | Low (layout shift possible) |
| Missing labels | Add `<label htmlFor>` to form inputs | None |
| Auto-play animation | Add `prefers-reduced-motion` media query | None |
| Missing confirmation | Add dialog before delete/destructive actions | Low |

## Phase 4: Verification

### Before/After Checklist

```
For each UX improvement:
- [ ] Heuristic that was violated is now satisfied
- [ ] No new heuristic violations introduced
- [ ] Keyboard navigation still works
- [ ] Screen reader announces correctly
- [ ] Touch targets meet minimum size
- [ ] Loading/error/empty states render correctly
- [ ] Visual appearance matches design system
- [ ] No layout shift (CLS) introduced
```

### Regression Signals

Watch for these regressions when applying UX fixes:

```
- Focus trap: new modal steals focus but doesn't return it on close
- Tab order: new elements inserted in wrong focus sequence
- Layout shift: skeleton/placeholder has different dimensions than content
- Over-feedback: too many toast notifications for routine operations
- Inconsistency: fixed component now looks different from unfixed siblings
```

## Integration with Rune Review

When running as part of `/rune:appraise` or `/rune:arc`:

```
1. UX review agents receive changed_files from the review scope
2. Each agent applies its domain checklist to the changed files
3. Findings are emitted with UXH/UXF/UXI/UXC prefixes
4. Findings are non-blocking by default (configurable)
5. Findings enter the dedup hierarchy below FRONT prefix
6. Aggregated in TOME.md alongside other review findings
```
