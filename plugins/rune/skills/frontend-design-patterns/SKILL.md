---
name: frontend-design-patterns
description: |
  Frontend design implementation knowledge — generalized best practices for
  translating design specifications into production components. Covers design
  systems, design tokens, accessibility (WCAG 2.1 AA), responsive patterns,
  component reuse strategy, layout alignment, variant mapping, Storybook
  documentation, visual region analysis, and UI state handling.
  Trigger keywords: design system, design tokens, accessibility, responsive,
  storybook, component patterns, layout, spacing, typography, WCAG, variant,
  figma, mobile-first, a11y, state handling, error states, loading states.
user-invocable: false
disable-model-invocation: false
---

# Frontend Design Patterns

Generalized best practices for translating design specifications into production-quality frontend components. Framework-agnostic patterns applicable to React, Vue, Svelte, and other component-based architectures.

## When This Loads

Auto-loaded by the Stacks context router when:
- Changed files touch `components/`, `pages/`, `views/`, `styles/`, or `ui/` directories
- A Figma URL is present in the task description or plan
- The detected stack includes a frontend framework (React, Vue, Next.js, Vite)
- Review/work/forge workflows involve UI implementation

## Architecture (3 Layers)

```
Layer 1: Design Interpretation — Convert design specs into structured requirements
Layer 2: Implementation Patterns — Apply reusable component, layout, and state patterns
Layer 3: Quality Assurance — Verify accessibility, responsiveness, and visual fidelity
```

## Layer 1: Design Interpretation

### Design Token Resolution

Design tokens are the single source of truth bridging design tools and code. Every visual property (color, spacing, typography, shadow, radius) should map to a token rather than a hardcoded value.

See [design-token-reference.md](references/design-token-reference.md) for the full Figma-to-CSS/Tailwind token mapping.

### Visual Region Analysis

When working from screenshots or design files, decompose the UI into semantic regions before writing code. This prevents structural mismatches between design and implementation.

See [visual-region-analysis.md](references/visual-region-analysis.md) for the screenshot-to-structure analysis protocol.

### Variant Mapping

Figma components use variants (properties with named values) to represent interactive states, sizes, and themes. Map these directly to component props.

See [variant-mapping.md](references/variant-mapping.md) for the Figma variant-to-prop mapping strategy.

## Layer 2: Implementation Patterns

### Domain Context Injection

When `designContext.domain` is available with confidence >= 0.70 and domain is not "general",
domain-specific design hints are injected as the lowest-trust layer of implementation guidance.
These hints cover color palette conventions, typography hierarchy, layout patterns, UX priorities,
and anti-patterns specific to the detected business domain.

See [domain-design-guide.md](references/domain-design-guide.md) for per-domain recommendations (8 domains) and the trust hierarchy.

### Component Reuse Strategy

Follow the REUSE > EXTEND > CREATE decision tree to minimize duplication and maintain consistency.

See [component-reuse-strategy.md](references/component-reuse-strategy.md) for the full decision tree.

### Design System Rules

Enforce constraints from the project's design system: permitted colors, spacing scale, typography stack, elevation levels, and icon usage.

See [design-system-rules.md](references/design-system-rules.md) for generic design system constraints.

### Typography Pairing

Select heading/body font combinations based on project context, contrast principles, x-height compatibility, and performance budget. Cross-references `brand.typography` talisman config when available.

For typography guidance, see [typography-pairing.md](references/typography-pairing.md).

### Layout and Alignment

Use Flexbox and Grid patterns that match the design's alignment intent. Auto-layout in Figma maps directly to flex properties.

See [layout-alignment.md](references/layout-alignment.md) for Flexbox/Grid alignment patterns.

### Responsive Patterns

Apply mobile-first responsive design with breakpoint-aware layout shifts, fluid typography, and conditional rendering.

See [responsive-patterns.md](references/responsive-patterns.md) for responsive implementation patterns.

### State and Error Handling

Every interactive component has at least 4 UI states: loading, error, empty, and success. Design for all states, not just the happy path.

See [state-and-error-handling.md](references/state-and-error-handling.md) for UI state patterns.

## Layer 3: Quality Assurance

### Accessibility

WCAG 2.1 AA compliance is a baseline requirement. Every component must be keyboard-navigable, screen-reader-accessible, and color-contrast compliant.

See [accessibility-patterns.md](references/accessibility-patterns.md) for WCAG compliance patterns.

### Storybook Documentation

Every reusable component should have a Storybook story documenting its variants, states, and edge cases.

See [storybook-patterns.md](references/storybook-patterns.md) for CSF3 format and autodocs patterns.

## Cross-References

- [figma-to-react](../figma-to-react/SKILL.md) — MCP tools for Figma API access and code generation
- [stacks](../stacks/SKILL.md) — Stack detection and context routing
- [design-sync](../design-sync/SKILL.md) — Figma design synchronization workflow

## References

- [accessibility-patterns.md](references/accessibility-patterns.md) — WCAG 2.1 AA compliance
- [component-reuse-strategy.md](references/component-reuse-strategy.md) — REUSE > EXTEND > CREATE decision tree
- [design-system-rules.md](references/design-system-rules.md) — Generic design system constraints
- [design-token-reference.md](references/design-token-reference.md) — Figma-to-CSS/Tailwind token mapping
- [layout-alignment.md](references/layout-alignment.md) — Flexbox/Grid alignment patterns
- [responsive-patterns.md](references/responsive-patterns.md) — Mobile-first responsive design
- [state-and-error-handling.md](references/state-and-error-handling.md) — UI state patterns
- [storybook-patterns.md](references/storybook-patterns.md) — CSF3 format and autodocs
- [typography-pairing.md](references/typography-pairing.md) — Proven heading/body font combinations
- [visual-region-analysis.md](references/visual-region-analysis.md) — Screenshot-to-structure analysis
- [variant-mapping.md](references/variant-mapping.md) — Figma variant-to-prop mapping
- [domain-design-guide.md](references/domain-design-guide.md) — Per-domain design recommendations
