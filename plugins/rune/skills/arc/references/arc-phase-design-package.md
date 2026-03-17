# Design Package — Reference Document

Defines the Design Context Document (DCD) schema, generation protocol, and consumption patterns for the arc design sync pipeline. Design Packages are self-contained artifact directories produced by Phase 3 (DESIGN EXTRACTION) and consumed by WORK phase workers, Phase 5.2 (DESIGN VERIFICATION), Phase 7.6 (DESIGN ITERATION), forge gaze agents, and code reviewers.

**Non-blocking**: All design package operations are advisory. Missing or incomplete packages never halt the pipeline.

## Directory Structure

```
tmp/arc/{id}/
├── vsm/                           # Visual Spec Maps (from Phase 3)
│   ├── {component-name}.json      # Per-component VSM (structured design data)
│   └── ...
├── design/                        # Design Context Documents (DCDs)
│   ├── {component-name}.md        # Per-component DCD (human-readable)
│   ├── _index.md                  # Master index of all DCDs
│   └── contracts.md               # Frontend-backend contract map
├── design-verification-report.md  # Phase 5.2 output
├── design-findings.json           # Phase 5.2 structured findings
└── design-iteration-report.md     # Phase 7.6 output
```

## Design Context Document (DCD) Schema

Each DCD is a markdown file with YAML frontmatter:

```yaml
---
type: design-context
component: "{component-name}"
figma_url: "https://www.figma.com/design/{file-key}/{file-name}?node-id={node-id}"
generated_at: "2026-02-26T19:15:00.000Z"
vsm_source: "tmp/arc/{id}/vsm/{component-name}.json"
tokens:
  colors:
    - name: "primary"
      value: "#1A73E8"
      usage: "CTA buttons, active states"
    - name: "surface"
      value: "#FFFFFF"
      usage: "Card backgrounds, input fields"
  spacing:
    - name: "sm"
      value: "8px"
    - name: "md"
      value: "16px"
    - name: "lg"
      value: "24px"
  typography:
    - name: "heading-lg"
      font: "Inter"
      size: "24px"
      weight: 600
      lineHeight: "32px"
    - name: "body"
      font: "Inter"
      size: "14px"
      weight: 400
      lineHeight: "20px"
  radii:
    - name: "card"
      value: "8px"
    - name: "button"
      value: "4px"
  shadows:
    - name: "card-elevated"
      value: "0 2px 8px rgba(0,0,0,0.1)"
acceptance_criteria:          # Optional — populated when design_sync.discipline.enabled
  - id: "DES-{component}-{dimension}"
    text: "Human-readable criterion description"
    proof: token_scan          # One of: token_scan, axe_passes, story_exists, storybook_renders, screenshot_diff, responsive_check
    args:
      target: "path/to/component"
    dimension: color           # One of: color, spacing, typography, accessibility, variant_coverage, responsive, fidelity
fidelity_dimensions:
  layout: null       # Scored 0-1 by Phase 5.2
  spacing: null
  typography: null
  color: null
  responsiveness: null
  accessibility: null
---
```

### DCD Body Sections

```markdown
# Design Context: {Component Name}

## Layout Spec (from VSM)

Region tree describing the component hierarchy. Derived from Figma auto-layout
and frame nesting.

- Root: `{frame-name}` (direction: vertical, gap: 16px, padding: 24px)
  - Header: `{header-frame}` (direction: horizontal, align: center, gap: 12px)
    - Icon: 24x24, color: primary
    - Title: heading-lg
  - Content: `{content-frame}` (direction: vertical, gap: 8px)
    - ...
  - Footer: `{footer-frame}` (direction: horizontal, justify: end, gap: 8px)

## Token Usage

Maps design tokens to specific component elements. Workers use this to select
correct design system values instead of hardcoding.

| Element | Token | CSS Property | Value |
|---------|-------|-------------|-------|
| Card background | surface | background-color | #FFFFFF |
| CTA button | primary | background-color | #1A73E8 |
| Title text | heading-lg | font-size / weight | 24px / 600 |
| Body text | body | font-size / weight | 14px / 400 |
| Card border | card | border-radius | 8px |

## Variant Matrix

Enumerates all design variants. Workers implement each state.

| Variant | Trigger | Visual Changes |
|---------|---------|---------------|
| Default | Initial render | Base styles |
| Hover | Mouse enter | Elevated shadow, primary accent |
| Active | Click/tap | Scale 0.98, darker primary |
| Disabled | disabled prop | Opacity 0.5, no pointer events |
| Loading | isLoading prop | Skeleton placeholder, pulse animation |
| Error | hasError prop | Red border, error icon visible |

## Accessibility Requirements

WCAG 2.1 AA compliance notes derived from Figma annotations and token analysis.

- Color contrast: primary (#1A73E8) on surface (#FFFFFF) = 4.6:1 (passes AA)
- Focus indicators: 2px solid primary outline, 2px offset
- Interactive elements: minimum 44x44px touch target
- Keyboard: Tab order follows visual layout (top→bottom, left→right)
- ARIA: role, aria-label, aria-describedby requirements per element
- Reduced motion: Disable animations when `prefers-reduced-motion: reduce`

## Implementation Notes

Architecture guidance for workers — maps design concepts to code patterns.

- Framework: [detected from stack — e.g., React, Vue, Svelte]
- Component pattern: [detected — e.g., compound component, render props]
- State management: [detected — e.g., useState, Zustand, Pinia]
- Styling approach: [detected — e.g., CSS Modules, Tailwind, styled-components]
- Token integration: [detected — e.g., CSS custom properties, theme provider]
```

## Acceptance Criteria (`acceptance_criteria`)

The optional `acceptance_criteria` field in DCD frontmatter enables per-criterion design verification with evidence trails. Generated automatically from VSM data when `design_sync.discipline.enabled` is `true` in talisman config.

Each criterion has: `id` (DES-prefixed), `text` (human-readable), `proof` (design proof type), `args` (proof-specific arguments), and `dimension` (fidelity dimension being verified).

Criteria are consumed by:
- **Workers** (Phase 5): Run design proofs alongside code proofs during implementation
- **Phase 5.2** (Design Verification): Produce DES-prefixed findings with per-criterion evidence
- **Phase 7.4** (Design Iteration): Use per-criterion PASS/FAIL for convergence instead of score-only threshold

The field is optional for backward compatibility — existing DCDs without criteria continue to work with score-only fidelity checking.

See [design-proof-types.md](../../discipline/references/design-proof-types.md) for the full acceptance criteria format, proof type definitions, and the design proof selection decision tree.

---

## Master Index (`_index.md`)

Lists all generated DCDs for the arc session. Workers scan this to find relevant design context.

```markdown
# Design Package Index

Generated: {ISO timestamp}
Arc ID: {id}
Figma URL: {url}
Components: {count}

## Components

| Component | DCD Path | VSM Path | Status |
|-----------|----------|----------|--------|
| LoginForm | design/LoginForm.md | vsm/LoginForm.json | complete |
| UserCard | design/UserCard.md | vsm/UserCard.json | complete |
| Navigation | design/Navigation.md | vsm/Navigation.json | partial |

## Coverage

- Total Figma components: {N}
- DCDs generated: {M}
- Coverage: {M/N * 100}%
```

## Frontend-Backend Contract Map (`contracts.md`)

Maps UI components to their data requirements. Helps workers identify API surface.

```markdown
# Frontend-Backend Contracts

## {Component Name}

### Data Requirements

| Field | Type | Source | Notes |
|-------|------|--------|-------|
| user.name | string | GET /api/users/:id | Display in header |
| user.avatar | string? | GET /api/users/:id | Fallback to initials |
| items | Item[] | GET /api/items?user=:id | Paginated, 20 per page |

### Events / Mutations

| Action | Endpoint | Method | Payload |
|--------|----------|--------|---------|
| Submit form | POST /api/forms | POST | { fields: FormData } |
| Delete item | DELETE /api/items/:id | DELETE | — |

### Backend Impact Decision Tree

Use this tree when a DCD references data not yet available from the API:

1. Does the API endpoint exist?
   - YES → Check response shape matches DCD data requirements
     - Matches → No backend change needed
     - Mismatch → Flag as CONTRACT_MISMATCH in findings
   - NO → Is this a read or write operation?
     - Read → Flag as MISSING_ENDPOINT (non-blocking — use mock data)
     - Write → Flag as MISSING_ENDPOINT (blocking for that component)

2. Is the endpoint authenticated?
   - YES → Verify auth token handling in component
   - NO → Flag if DCD data is user-specific (potential auth gap)
```

## Generation Protocol

### How Phase 3 (DESIGN EXTRACTION) Produces DCDs

```
1. Fetch Figma file metadata via MCP
2. List top-level components (cap: 20)
3. For each component:
   a. Fetch node data (auto-layout, constraints, fills, strokes, effects)
   b. Extract design tokens (colors, spacing, typography, radii, shadows)
   c. Build region tree (frame hierarchy with layout properties)
   d. Detect variants (component sets, boolean properties, instance swaps)
   e. Write VSM to tmp/arc/{id}/vsm/{name}.json
   f. Generate DCD from VSM → tmp/arc/{id}/design/{name}.md
4. Generate _index.md listing all DCDs
5. Generate contracts.md from plan data requirements + Figma annotations
```

### VSM-to-DCD Transformation

```javascript
// VSM is the structured intermediate format (JSON)
// DCD is the human-readable output (Markdown + YAML frontmatter)
function generateDCD(vsm, planContext) {
  return {
    frontmatter: {
      type: "design-context",
      component: vsm.name,
      figma_url: vsm.figma_url,
      generated_at: new Date().toISOString(),
      vsm_source: vsm.path,
      tokens: extractTokens(vsm),
      fidelity_dimensions: null  // Populated by Phase 5.2
    },
    body: {
      layout_spec: buildRegionTree(vsm.frames),
      token_usage: mapTokensToElements(vsm),
      variant_matrix: buildVariantMatrix(vsm.variants),
      accessibility: deriveA11yRequirements(vsm, planContext),
      implementation_notes: detectStackPatterns(planContext)
    }
  }
}
```

## Consumer Protocol

### Strive Workers (Phase 5 WORK)

Workers receive DCD paths in their task descriptions when design context is available.

```
1. Check if DCD exists for the component being implemented
2. Read DCD frontmatter for token mapping
3. Follow Layout Spec for component structure
4. Implement all variants from Variant Matrix
5. Apply Accessibility Requirements
6. Use Implementation Notes for framework-specific patterns
7. Reference contracts.md for data requirements
```

**Worker integration**: Workers do NOT modify DCDs. They are read-only consumers. If a worker finds a DCD inaccuracy, they log it to their worker-log for Phase 5.2 review.

### Forge Gaze Agents (Phase 1 FORGE)

When `design_sync.enabled === true`, forge gaze agents may reference DCDs from a previous arc run (if available in `tmp/arc/`) to enrich plan sections with design context.

### Code Reviewers (Phase 6 CODE REVIEW)

Reviewers can reference DCDs to validate:
- Token usage matches design spec
- Variant coverage completeness
- Accessibility implementation
- Layout structure alignment

### Phase 5.2 (DESIGN VERIFICATION)

Reads VSM files and compares against implemented components. Produces fidelity scores across 6 dimensions: layout, spacing, typography, color, responsiveness, accessibility.

### Phase 7.6 (DESIGN ITERATION)

Reads design-findings.json from Phase 5.2. Runs screenshot-analyze-fix loops for components below fidelity threshold.

## Skip Conditions

Design package generation is skipped when ANY of these conditions are true:

| Condition | Detection | Skip Behavior |
|-----------|-----------|---------------|
| `design_sync.enabled !== true` | talisman config check | Phase 3 skips entirely |
| No Figma URL in plan | Plan frontmatter scan | Phase 3 skips entirely |
| Figma MCP unavailable | MCP probe failure | Phase 3 skips with warning |
| Backend-only plan | No frontend files in plan task list | Phase 3 skips — no UI components to extract |
| No VSM files produced | Phase 3 completed with 0 outputs | Phase 5.2 skips |
| Fidelity score >= threshold | Phase 5.2 findings check | Phase 7.6 skips |

## Human-Provided Design Context

When Figma MCP is unavailable or the project doesn't use Figma, users can manually create design context:

```
1. Create tmp/arc/{id}/design/{component}.md following the DCD schema above
2. Set type: design-context in frontmatter (required)
3. Omit figma_url and vsm_source (mark as "manual")
4. Populate Layout Spec, Token Usage, and Variant Matrix manually
5. Phase 5.2 will still verify implementation fidelity against manual DCDs
```

**Detection**: Phase 3 checks for pre-existing `tmp/arc/{id}/design/` directory. If DCDs already exist and are valid (have `type: design-context` frontmatter), extraction is skipped and existing DCDs are used as-is.

## Plan References Format

Plans that include design context should reference it in their frontmatter:

```yaml
---
figma_url: "https://www.figma.com/design/AbCdEf/project-name?node-id=0-1"
design_sync:
  components:
    - name: "LoginForm"
      figma_node: "1:234"
    - name: "UserCard"
      figma_node: "1:567"
  tokens_file: "src/tokens/design-tokens.json"  # Optional — existing token file
---
```

When `figma_url` is present in plan frontmatter, Phase 3 activates automatically (if `design_sync.enabled` in talisman).

## Manifest Section

Each DCD includes a machine-readable manifest in its frontmatter for tooling:

```yaml
---
# ... standard DCD frontmatter ...
manifest:
  schema_version: 1
  generator: "arc-phase-design-extraction"
  generator_version: "1.109.0"
  checksum: "sha256:{hash-of-body}"
  regions: 5          # Count of layout regions
  tokens: 12          # Count of unique tokens referenced
  variants: 4         # Count of variant states
  a11y_checks: 6      # Count of accessibility requirements
---
```

The manifest enables:
- **Staleness detection**: Compare checksum on re-run to skip unchanged DCDs
- **Coverage metrics**: Aggregate regions/tokens/variants across all DCDs
- **Quality gates**: Phase 5.2 can flag DCDs with 0 a11y_checks as incomplete
