# Phase 2: VSM-Guided Implementation

Algorithm for creating frontend components from Visual Spec Maps (VSM).

## Builder-Aware Implementation Paths

Two paths exist depending on whether a UI builder MCP was detected:

```
WITHOUT builder (fallback — existing behavior, unchanged):
  figma_to_react() reference code (~50-60% match) → workers apply directly
  Steps 1-8 below apply as documented.

WITH builder (preferred — when enriched-vsm.json exists):
  enriched-vsm.json contains real library component matches per region.
  Workers IMPORT real components instead of generating approximations.
  Regions without component_matches fall back to the standard token-based path.
```

### Worker Decision Tree (Step 2 addition when builder active)

```
For each VSM region:
  IF region.component_matches exists (from enriched-vsm.json):
    1. Import the matched component: import { ComponentName } from "library"
    2. Customize using builder conventions (props, variants from VSM)
    3. Skip Steps 3-5 below for this region (token application still applies for customization)
  ELSE (no library match or no builder):
    Apply Steps 3-8 below as documented (Tailwind token-based implementation)
```

### Match Confidence Handling

For each VSM region with component_matches in enriched-vsm.json:

```
IF region.component_matches[0].confidence === 'high' (score >= 0.80):
  -> Import directly: import { Component } from "library"
  -> Customize props from VSM variant map
  -> Trust: HIGH — minimal customization needed

ELSE IF region.component_matches[0].confidence === 'medium' (score 0.60-0.79):
  -> Import component as starting point
  -> Verify EVERY token against VSM (colors, spacing, typography may differ)
  -> Trust: MEDIUM — expect 20-40% customization

ELSE (confidence === 'low' or no match):
  -> Do NOT import library component
  -> Build from scratch using VSM tokens + project design system patterns
  -> Reference code provides INTENT hint only (component type, layout direction)
  -> Trust: LOW — implement entirely from VSM spec
```

See [worker-trust-hierarchy.md](worker-trust-hierarchy.md) for the full source priority order.

## Implementation Workflow

### Step 1: VSM Parsing

```
1. Read VSM file for the target component
2. Extract:
   - Token map (design tokens to use — including per-side spacing, full borders, margins)
   - Region tree (component structure — including separators, stacking context, icons)
   - Icon inventory (icon names, libraries, sizes, color tokens)
   - Variant map (props to implement)
   - Responsive spec (breakpoint behavior)
   - Accessibility requirements
   - Component dependencies (REUSE or EXTEND candidates)
3. Flag commonly-missed details for explicit verification:
   - Count separator nodes in Region Tree → these MUST appear in output
   - Count border entries in Token Map → these MUST be applied
   - Count icons in Icon Inventory → these MUST use correct names
   - Check for z-index annotations → stacking context MUST be set up
```

### Step 2: Component Scaffolding

```
1. Determine component location:
   - Check existing component directories (components/, src/components/, ui/)
   - Match project convention for subdirectory (by domain, by type)

2. Check for REUSE/EXTEND opportunities:
   - Search component library for similar components
   - If match >= 70% → EXTEND (add variant or compose)
   - If match < 70% → CREATE new component

3. Generate component skeleton:
   - Props interface from VSM variant map
   - Import statements for design tokens
   - Base markup from region tree
```

### Step 3: Token Application

```
For each visual property in the VSM token map:
  Apply the mapped token:
  - Colors → className="bg-{token}" or style={{ color: 'var(--{token})' }}
  - Spacing (MUST be per-side when VSM specifies asymmetric):
    - Symmetric → className="p-{n} gap-{n}"
    - Asymmetric → className="pt-{n} pr-{n} pb-{n} pl-{n}"
    - Margins → className="mb-{n} mt-{n}" (from parent gap or VSM margin entries)
  - Typography → className="text-{size} font-{weight} leading-{n}"
  - Shadows → className="shadow-{level}"
  - Borders (MUST include all of: width + color + style + radius):
    - All sides → className="border border-{color} rounded-{size}"
    - Per-side → className="border-b border-{color}" (common for headers, list items)
    - Width > 1px → className="border-2 border-{color}"
  - Icons (from Icon Inventory):
    - Import correct icon: import { {IconName} } from '{library}'
    - Apply size: className="w-{size} h-{size}" or size={n} prop
    - Apply color: className="text-{color-token}"

RULE: Never use hardcoded values. Every visual property must reference a token.
If the VSM flags a value as "unmatched," use the closest token and add a TODO comment.
```

### Step 4: Layout Implementation

```
Map VSM region tree to markup:
  FRAME (horizontal auto-layout) → <div className="flex flex-row gap-{n}">
  FRAME (vertical auto-layout)   → <div className="flex flex-col gap-{n}">
  FRAME (wrap)                   → <div className="flex flex-wrap gap-{n}">
  FRAME (grid)                   → <div className="grid grid-cols-{n} gap-{n}">
  TEXT                           → <p> / <h1-6> / <span> (based on context)
  RECTANGLE                      → <div> with background/border styles
  IMAGE fill                     → <img> with proper alt text

Sizing:
  Fixed → w-{n} h-{n} or w-[{n}px]
  Fill container → flex-1
  Hug contents → w-fit
```

### Step 5: Variant Implementation

```
For each prop in the VSM variant map:
  1. Add to props interface with TypeScript type
  2. Implement conditional styling per variant value
  3. Set default to VSM-specified default

Pattern (using cva or similar):
  const variants = {
    variant: {
      primary: "bg-primary text-primary-foreground",
      secondary: "bg-secondary text-secondary-foreground",
    },
    size: {
      sm: "h-8 px-3 text-sm",
      md: "h-10 px-4 text-base",
      lg: "h-12 px-6 text-lg",
    },
  }
```

### Step 6: State Implementation

```
For each required state (from VSM accessibility section):
  Loading → skeleton or spinner conditional
  Error → error message with recovery action
  Empty → empty state illustration with CTA
  Disabled → reduced opacity, aria-disabled="true"

Implementation pattern:
  if (loading) return <Skeleton />
  if (error) return <ErrorState message={error} onRetry={retry} />
  if (!data?.length) return <EmptyState action={createNew} />
  return <SuccessContent data={data} />
```

### Step 7: Responsive Implementation

```
For each breakpoint in VSM responsive spec:
  Apply mobile-first utilities:
  - Base (mobile) → no prefix
  - md (768px) → md: prefix
  - lg (1024px) → lg: prefix

Example from VSM:
  Mobile: flex-col, single column
  Tablet: flex-row, 2 columns
  Desktop: flex-row, 3 columns

Implementation:
  className="flex flex-col md:flex-row"
  className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3"
```

### Step 8: Accessibility Implementation

```
From VSM accessibility requirements:
  - Add ARIA attributes (role, aria-label, aria-expanded, etc.)
  - Add keyboard event handlers (onKeyDown for Enter/Space/Escape)
  - Ensure focus management (tabIndex, focus trap for modals)
  - Set color contrast (verified by token selection)
  - Add alt text for images, labels for inputs
```

## Quality Checks Before Completion

```
1. No hardcoded visual values (grep for hex, rgb, arbitrary px)
2. All VSM tokens applied
3. All variants from variant map implemented
4. All 4 UI states handled (loading, error, empty, success)
5. Responsive breakpoints match VSM spec
6. Accessibility attributes present per VSM requirements
7. Component registered (exported, Storybook story if applicable)
8. [Builder path only] Regions with component_matches use real library imports,
   not Tailwind-only approximations (prefer library component over hand-built)
9. [Trust hierarchy] Regions with match_score < 0.60 do NOT use library imports
   (fallback to VSM-guided Tailwind implementation per worker-trust-hierarchy.md)
```

## Domain Hints (Conditional Suffix)

When `designContext.domain` is present with confidence >= 0.70 and domain is not "general",
append domain-specific design hints to the worker prompt. Domain hints are the **lowest trust
level** — they never override Figma specs, VSM tokens, or library patterns.

```
// Appended AFTER Step 8 checklist, BEFORE worker begins implementation
// Uses loadDomainHints() pattern from domain-design-guide.md (same algorithm, inline here for clarity)
IF designContext.domain AND designContext.domain.confidence >= 0.70
   AND designContext.domain.inferred !== "general":
  domainHints = loadDomainHints(designContext.domain.inferred)
  // loadDomainHints reads domain-design-guide.md section for the inferred domain
  workerPrompt += "\n\n## Domain Context: {designContext.domain.inferred}\n{domainHints}"
  // ~50-100 words of additive hints — UX priorities and anti-patterns for this domain
```

## Cross-References

- [component-reuse-strategy.md](../../frontend-design-patterns/references/component-reuse-strategy.md) — REUSE > EXTEND > CREATE
- [layout-alignment.md](../../frontend-design-patterns/references/layout-alignment.md) — Flex/Grid patterns
- [vsm-spec.md](vsm-spec.md) — VSM schema
- [domain-design-guide.md](../../frontend-design-patterns/references/domain-design-guide.md) — Per-domain design recommendations
