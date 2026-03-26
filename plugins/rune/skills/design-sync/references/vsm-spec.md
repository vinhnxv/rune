# Visual Spec Map (VSM) Schema

The VSM is the intermediate representation between Figma design data and code implementation. One VSM file per component.

## Schema Version

```yaml
vsm_schema_version: "1.0"  # single-URL extraction (original)
vsm_schema_version: "1.1"  # multi-URL extraction with variant_sources
vsm_schema_version: "1.2"  # enhanced fidelity: icon inventory, full borders, per-side spacing, separators, stacking context
```

All VSM files MUST include the schema version as the first field in the YAML frontmatter.

**Version compatibility:**
- v1.0 VSMs remain fully valid — all consumers MUST accept both versions.
- v1.1 adds optional fields only — v1.0 consumers MUST guard with `schema_version >= "1.1"` before reading new fields.
- Single-URL fast path: when only 1 Figma URL is present, write v1.0 and omit `variant_sources`.

## Consumer Guard Pattern

Before reading v1.1-only fields, consumers MUST apply this guard:

```javascript
function readVSM(vsmPath):
  vsm = parseYAML(Read(vsmPath))
  // Guard: v1.1+ fields are optional in v1.0 VSMs
  const isV11 = parseFloat(vsm.vsm_schema_version ?? "1.0") >= 1.1
  return {
    ...vsm,
    variant_sources: isV11 ? (vsm.variant_sources ?? []) : [],
    relationship_group: isV11 ? (vsm.relationship_group ?? null) : null,
    relationship_confidence: isV11 ? (vsm.relationship_confidence ?? null) : null,
    // Semantic fields are version-independent (optional in all versions)
    semantic_component_map: vsm.semantic_component_map ?? []
  }
```

Seven required guard checks:
1. `vsm_schema_version` field exists before comparing
2. Default to `"1.0"` if field absent (backward compat)
3. Parse as float before numeric comparison
4. `variant_sources` defaults to `[]` when absent
5. `relationship_group` defaults to `null` when absent
6. `relationship_confidence` defaults to `null` when absent
7. `semantic_component_map` defaults to `[]` when absent (version-independent)

### Consumer Guard Enforcement

**All VSM consumers MUST apply this guard before reading v1.1 fields.** Known consumers:

- **design-analyst** agent (`agents/design-analyst.md`) — reads VSMs to classify relationships and build the relationship graph
- **arc-phase-design-extraction** (`skills/arc/references/arc-phase-design-extraction.md`) — reads and writes VSMs during Phase 3 design extraction
- **strive workers** — read VSMs when performing design-sync implementation tasks

Any new consumer added to the pipeline MUST apply the guard above before accessing `variant_sources`, `relationship_group`, or `relationship_confidence`.

### Generation-Time Validation

Before writing a VSM file, the generator MUST validate the output against the schema. Validation failures are not silent — they must downgrade or abort.

**Required validation checklist (v1.1):**

- [ ] `vsm_schema_version` is present and set to `"1.1"`
- [ ] `variant_sources` array is present and has at least 1 entry
- [ ] Each `variant_sources` entry has `url`, `role`, `node_id`, `state_name`
- [ ] Exactly one `variant_sources` entry has `role: "primary"`
- [ ] `variant_sources[].role` is one of `"primary"` | `"variant"` | `"breakpoint"`
- [ ] `figma_url` matches the primary source URL
- [ ] `relationship_group` matches `/^grp-\d{3}$/` when present
- [ ] `relationship_confidence` is in `[0.0, 1.0]` when present

**On validation failure:**

```javascript
function validateAndWriteVSM(vsm, outputPath):
  errors = validateVSMSchema(vsm)
  if errors.length > 0:
    if canDowngradeToV10(vsm):
      // Single URL present — safe to omit v1.1 fields
      vsm = downgradeToV10(vsm)  // removes variant_sources, relationship_group, relationship_confidence
      vsm.vsm_schema_version = "1.0"
      writeVSM(vsm, outputPath)
    else:
      // Cannot produce a valid VSM — fail the extraction task explicitly
      throw ExtractionError(`VSM validation failed: ${errors.join(", ")}`)
```

`canDowngradeToV10()` returns `true` only when a single Figma URL was processed and no multi-source merge was required.

## File Location

```
tmp/design-sync/{timestamp}/vsm/{component-name}.md  # single-URL
tmp/arc/{id}/vsm/{component-name}.json               # arc pipeline
```

## Full Schema

### v1.0 (Single-URL)

```yaml
---
vsm_schema_version: "1.0"
component_name: "CardComponent"
figma_url: "https://www.figma.com/design/abc123/MyApp?node-id=1-3"
figma_file_key: "abc123"
figma_node_id: "1-3"
extracted_at: "2026-02-25T12:00:00Z"
---

## Token Map

| Property | Figma Value | Design Token | Tailwind | Status |
|----------|------------|-------------|----------|--------|
| Background | #FFFFFF | --color-background | bg-white | matched |

## Region Tree

- **CardRoot** — `<article>`, flex-col, gap-3, p-4, rounded-lg

## Variant Map

| Figma Property | Prop Name | Type | Default | Token Diff |
|---------------|-----------|------|---------|------------|
| Type | variant | "default" \| "featured" | default | featured: border-primary |
```

### v1.1 (Multi-URL — merged same-screen group)

```yaml
---
vsm_schema_version: "1.1"
component_name: "CardComponent"
figma_url: "https://www.figma.com/design/abc123/MyApp?node-id=1-3"
figma_file_key: "abc123"
figma_node_id: "1-3"
extracted_at: "2026-02-25T12:00:00Z"

# v1.1 additions — only present when vsm_schema_version is "1.1"
variant_sources:
  - url: "https://www.figma.com/design/abc123/MyApp?node-id=1-3"
    role: "primary"         # primary | variant | breakpoint
    node_id: "1-3"
    state_name: "Desktop"   # human-readable screen/state label
  - url: "https://www.figma.com/design/abc123/MyApp?node-id=4-7"
    role: "breakpoint"
    node_id: "4-7"
    state_name: "Mobile"
relationship_group: "grp-001"     # group_id from design-analyst relationship graph
relationship_confidence: 0.82     # analyst composite score for the primary pair
---
```

## Section 1: Token Map

Maps every visual property to a design token. v1.2 adds per-side spacing, margin, and full border details.

```markdown
## Token Map

| Property | Figma Value | Design Token | Tailwind | Status |
|----------|------------|-------------|----------|--------|
| Background | #FFFFFF | --color-background | bg-white | matched |
| Text color | #0A0A0A | --color-foreground | text-foreground | matched |
| Padding-top | 16px | --spacing-4 | pt-4 | matched |
| Padding-right | 16px | --spacing-4 | pr-4 | matched |
| Padding-bottom | 8px | --spacing-2 | pb-2 | matched |
| Padding-left | 16px | --spacing-4 | pl-4 | matched |
| Gap | 12px | --spacing-3 | gap-3 | matched |
| Margin-bottom | 24px | --spacing-6 | mb-6 | matched |
| Border-width | 1px | — | border | matched |
| Border-color | #E5E7EB | --color-border | border-border | matched |
| Border-style | solid | — | — | default |
| Border-radius | 8px | --radius-lg | rounded-lg | matched |
| Border-bottom-width | 1px | — | border-b | matched |
| Shadow | 0 1px 3px rgba(0,0,0,0.1) | shadow-sm | shadow-sm | matched |
| Font size | 18px | text-lg | text-lg | matched |
| Font weight | 600 | font-semibold | font-semibold | matched |
| Accent color | #7C3AED | — | — | unmatched |
```

**v1.2 Token Map rules:**
- **Per-side spacing**: When padding/margin differs per side, list each side separately (`pt`, `pr`, `pb`, `pl`). When symmetric, use shorthand (`px`, `py` or `p`).
- **Margin**: Figma has no native margin. Inferred from parent auto-layout gap or absolute positioning offsets. Always include if non-zero.
- **Full borders**: Always include border-width, border-color, border-style (not just radius). When only specific sides have borders (e.g., bottom divider), use `Border-{side}-width`.
- **Separator borders**: Thin LINE/RECTANGLE separators between items should appear as `Border-bottom-width: 1px` on the preceding item OR as a dedicated `<hr>` in Region Tree.

Status values:
- `matched` — exact or snapped token found
- `unmatched` — no token within snap distance (requires manual mapping)
- `off-scale` — value not on standard scale (rounded in Tailwind column)
- `default` — CSS default value (e.g., border-style: solid), no explicit token needed

## Section 2: Region Tree

Hierarchical decomposition of the component structure. v1.2 adds separator nodes, icon nodes, stacking context annotations, and per-side spacing.

```markdown
## Region Tree

- **CardRoot** — `<article>`, flex-col, gap-3, pt-4 pr-4 pb-2 pl-4, rounded-lg, shadow-sm, border border-border
  - **CardImage** — `<img>`, w-full, h-48, object-cover, rounded-t-lg
  - **Separator** — `<hr>`, border-t border-border ← DIVIDER
  - **CardBody** — `<div>`, flex-col, gap-2
    - **CardTitle** — `<h3>`, text-lg, font-semibold, text-foreground
    - **CardDescription** — `<p>`, text-sm, text-muted-foreground, line-clamp-2
  - **Separator** — `<hr>`, border-t border-border ← DIVIDER
  - **CardFooter** — `<div>`, flex-row, justify-between, items-center
    - **CardMeta** — `<span>`, text-xs, text-muted
    - **CardActions** — `<div>`, flex-row, gap-2, relative ← STACKING CONTEXT
      - **ActionButton** — `<button>`, variant=ghost, size=sm
      - **DropdownMenu** — `<div>`, absolute, z-50, top-full, right-0 ← z-index tracked
```

Each node specifies: semantic element, layout classes, sizing, and token references.

**v1.2 Region Tree rules:**
- **Separators**: `LINE` nodes and thin `RECTANGLE` (height≤2px) nodes MUST appear as `**Separator** — <hr>, border-t border-{color}`. NEVER skip or merge into parent.
- **Stacking context**: Nodes with `position: absolute` MUST include `z-{index}` annotation. Parent MUST include `relative` to establish stacking context.
- **Per-side spacing**: When padding differs per side, use `pt-4 pr-4 pb-2 pl-4` instead of `p-4`.
- **Borders**: All nodes with Figma strokes MUST include `border border-{color}` or per-side `border-b border-{color}`.
- **Icons**: See Icon Inventory section below — icons in Region Tree are annotated with `← ICON: {name}`.

Nodes may optionally include a `Semantic Role` annotation to classify their UI purpose:

```markdown
## Region Tree

- **AppRoot** — `<div>`, flex-row
  - Semantic Role: page-layout (0.95)
  - **NavBar** — `<nav>`, flex-row, h-16, bg-background, border-b
    - Semantic Role: navigation (0.98)
  - **MainContent** — `<main>`, flex-1, flex-col
    - Semantic Role: content-area (0.90)
    - **HeroSection** — `<section>`, w-full, py-16, bg-gradient-to-r
      - Semantic Role: hero (0.92)
    - **CardGrid** — `<div>`, grid, grid-cols-3, gap-4
      - Semantic Role: content-list (0.85)
```

The `Semantic Role` line is OPTIONAL. When present, it follows the format: `Semantic Role: {role} ({confidence})` where confidence is in [0.0, 1.0]. Omit for nodes with no clear semantic classification.

## Section 3: Variant Map

Component variants extracted from Figma Component Set.

```markdown
## Variant Map

| Figma Property | Prop Name | Type | Default | Token Diff |
|---------------|-----------|------|---------|------------|
| Type | variant | "default" | "featured" | "compact" | default | featured: border-primary, shadow-md |
| Size | size | "sm" | "md" | "lg" | md | sm: p-2 gap-1, lg: p-6 gap-4 |
| Has Image | — | (boolean structural) | true | false: remove CardImage node |
```

## Section 4: Responsive Spec

Breakpoint-specific behavior.

```markdown
## Responsive Spec

| Breakpoint | Layout Changes |
|-----------|---------------|
| Default (mobile) | Single column, full width, image aspect-ratio auto |
| md (768px) | Two-column grid for card lists |
| lg (1024px) | Three-column grid, max-w-sm per card |
```

## Section 5: Accessibility Requirements

```markdown
## Accessibility

| Requirement | Implementation |
|-------------|---------------|
| Semantic element | `<article>` for card container |
| Focus management | Card should be focusable if clickable (tabIndex=0) |
| Image alt | Required — describe card content |
| Heading level | h3 for card title (assumes within h2 section) |
| Touch target | Action buttons min 44x44px |
| Contrast | Text-foreground on background meets 4.5:1 |
```

## Section 6: Component Dependencies

```markdown
## Dependencies

| Component | Strategy | Notes |
|-----------|----------|-------|
| Button | REUSE | Existing — use variant="ghost" size="sm" |
| Badge | REUSE | Existing — for status indicators |
| Skeleton | REUSE | Existing — for loading state |
```

## Section 7: State Requirements

```markdown
## States

| State | Required | Description |
|-------|----------|-------------|
| Loading | Yes | Skeleton placeholder matching card dimensions |
| Error | Yes | Error message with retry button |
| Empty | Conditional | Only for card list containers, not individual cards |
| Success | Yes | Default rendered state |
```

## Section 8: Micro-Design

Captures interactive states, animations, transitions, and micro-interactions. This section is **optional** — omit it for static-only components, include it when the component has hover/focus/active states or animations.

**When to include**: Any component with interactive states, transitions, scroll behaviors, or compound keyboard interactions.

### 8.1 Interactive States

Per-component state definitions with Tailwind classes for each state.

```yaml
micro_design:
  states:
    Button:
      default:
        bg: "bg-primary"
        text: "text-primary-foreground"
        shadow: "shadow-sm"
      hover:
        bg: "bg-primary/90"
        transform: "none"
        transition: "colors 150ms ease"
      active:
        bg: "bg-primary/80"
        transform: "scale(0.98)"
        transition: "transform 75ms ease"
      focus:
        ring: "ring-2 ring-ring ring-offset-2"
        outline: "outline-none"
      disabled:
        bg: "bg-primary/50"
        cursor: "not-allowed"
        opacity: "0.5"
      loading:
        content: "spinner icon replaces text"
        aria: "aria-busy=true"
        pointer_events: "none"
```

Supported state names: `default`, `hover`, `active`, `focus`, `disabled`, `loading`, `selected`, `error`.

Each state maps CSS/Tailwind properties. The `transition` property within a state describes how to **enter** that state.

### 8.2 Transitions

Global transition catalog — reusable transition definitions referenced by component states.

```yaml
  transitions:
    color_change: "transition-colors duration-150 ease-in-out"
    layout_shift: "transition-all duration-200 ease-out"
    modal_enter: "animate-in fade-in-0 zoom-in-95 duration-200"
    modal_exit: "animate-out fade-out-0 zoom-out-95 duration-150"
    slide_in: "animate-in slide-in-from-right duration-300"
    accordion: "transition-[grid-template-rows] duration-200"
```

Keys are semantic names. Values are Tailwind class strings. Components reference these by key rather than inlining transition definitions.

### 8.3 Scroll Behavior

Scroll-triggered behaviors for the component or its container.

```yaml
  scroll:
    sticky_header:
      trigger: "scroll > 64px"
      effect: "bg-background/80 backdrop-blur-sm border-b"
    infinite_scroll:
      trigger: "intersectionObserver at 200px"
      effect: "load next page"
    parallax: false  # explicitly mark if not used
```

Each entry has:
- `trigger` — scroll condition or IntersectionObserver config
- `effect` — Tailwind classes or behavioral description

Set a key to `false` to explicitly document that a scroll behavior is **not** used (prevents re-investigation on future syncs).

### 8.4 Responsive Interactions

State changes that differ per breakpoint — captures patterns where mobile and desktop have fundamentally different interaction models.

```yaml
  responsive_interactions:
    navigation:
      mobile:
        pattern: "hamburger menu"
        trigger: "click"
        animation: "slide-in-from-left"
      desktop:
        pattern: "horizontal nav bar"
        trigger: "hover dropdown"
        animation: "fade-in"
    sidebar:
      mobile:
        pattern: "overlay drawer"
        trigger: "swipe/click"
        animation: "slide-in-from-left"
      desktop:
        pattern: "persistent sidebar"
        trigger: "always visible"
        animation: "none"
```

Each interaction is keyed by component region. Breakpoints use `mobile` and `desktop` (matching Tailwind `md:` boundary). Add `tablet` if behavior differs at `md` vs `lg`.

### 8.5 Data Attributes

UntitledUI-style data-attribute responsive pattern — documents data attributes used for state-driven styling.

```yaml
  data_attributes:
    "data-loading": "Applied when component is in loading state"
    "data-selected": "Applied when item is selected in a list"
    "data-icon": "Applied to icon elements for size/color inheritance"
    "data-state": "open | closed — used by Radix/shadcn primitives"
    "data-disabled": "Applied when component is non-interactive"
```

Keys are the HTML `data-*` attribute names. Values describe when the attribute is applied. These map to CSS selectors like `[data-loading]:opacity-50`.

### 8.6 Compound Component Interactions

Keyboard and event interactions for compound components (Select, Accordion, Dialog, etc.).

```yaml
  compound_interactions:
    Select:
      trigger:
        event: "click"
        opens: "listbox"
        animation: "fade-in slide-in-from-top-2"
      item:
        event: "click/enter"
        closes: "listbox"
        fires: "onChange"
      keyboard:
        ArrowDown: "next item"
        ArrowUp: "prev item"
        Escape: "close"
        Enter: "select"

    Accordion:
      trigger:
        event: "click"
        toggles: "content panel"
        animation: "accordion height transition"
      keyboard:
        ArrowDown: "next trigger"
        ArrowUp: "prev trigger"
        Home: "first"
        End: "last"
```

Each compound interaction defines:
- `trigger` — the event that opens/toggles the component
- `item` (optional) — events on child items
- `keyboard` — keyboard navigation map (key → behavior)

Keyboard maps follow WAI-ARIA Authoring Practices for the component pattern.

## Section 9: Icon Inventory (v1.2)

Maps every icon in the design to its name, library, size, and color token. Prevents wrong icon implementation.

```markdown
## Icon Inventory

| Region | Icon Name | Library | Size | Color Token | Notes |
|--------|-----------|---------|------|-------------|-------|
| SearchInput.leadingIcon | Search | lucide | 16px | text-muted-foreground | |
| DropdownTrigger.trailingIcon | ChevronDown | lucide | 14px | text-foreground | Rotates on open |
| CloseButton | X | lucide | 16px | text-muted-foreground | |
| StatusBadge.icon | CheckCircle | lucide | 12px | text-success | |
| NavItem.icon | Home | lucide | 20px | text-foreground | Active: text-primary |
```

**Extraction rules:**
- Icon name is inferred from Figma component name (e.g., `Icons/ChevronDown` → `ChevronDown`)
- Library is inferred from project dependencies (`lucide-react`, `@heroicons/react`, `react-icons`)
- If icon name cannot be determined, mark as `unknown` with visual description: `"arrow pointing down, 14px"`
- Icons inside buttons, inputs, and navigation MUST be captured — these are most commonly wrong

## Section 10: Semantic Component Map (OPTIONAL)

Maps design regions to their semantic UI roles, enabling verification that implementation components match the design's intended purpose. This section is **optional** — omit it when semantic classification has not been performed.

**When to include**: When the semantic classifier has been run on the design and produced role assignments with sufficient confidence.

```yaml
semantic_component_map:
  - region: "NavBar"
    semantic_role: "navigation"
    confidence: 0.98
    expected_element: "<nav>"
    expected_patterns:
      - "links or menu items"
      - "logo/brand region"
    notes: "Primary site navigation"
  - region: "HeroSection"
    semantic_role: "hero"
    confidence: 0.92
    expected_element: "<section>"
    expected_patterns:
      - "headline text"
      - "call-to-action button"
      - "background image or gradient"
    notes: "Above-the-fold hero area"
  - region: "CardGrid"
    semantic_role: "content-list"
    confidence: 0.85
    expected_element: "<div> or <ul>"
    expected_patterns:
      - "repeated card items"
      - "grid or flex layout"
    notes: "Repeating content cards"
  - region: "AppFooter"
    semantic_role: "footer"
    confidence: 0.96
    expected_element: "<footer>"
    expected_patterns:
      - "copyright text"
      - "secondary navigation links"
    notes: "Site footer"
```

Each entry in the semantic component map contains:

| Field | Required | Description |
|-------|----------|-------------|
| `region` | Yes | Name of the region node from the Region Tree |
| `semantic_role` | Yes | Classified UI role (e.g., navigation, hero, content-list, footer, sidebar, form, modal) |
| `confidence` | Yes | Classification confidence score in [0.0, 1.0] |
| `expected_element` | No | Suggested semantic HTML element for implementation |
| `expected_patterns` | No | List of expected sub-patterns within this region |
| `notes` | No | Free-text annotation for implementation guidance |

### Consumer Guard Pattern

Before reading the Semantic Component Map, consumers MUST apply this guard:

```javascript
const semantic_component_map = vsm.semantic_component_map ?? []
```

This ensures backward compatibility — VSMs without semantic classification return an empty array.

## Variant Map Merge Algorithm (v1.1 Only)

When a VSM is generated from a same-screen group (multiple `variant_sources`), the
Variant Map merges properties across all source frames:

```javascript
function mergeVariantMaps(sources):
  // 1. Collect all variant property keys across all sources
  allKeys = union(sources.map(s => Object.keys(s.variantMap)))

  // 2. For each key, collect values and token diffs per source
  merged = {}
  for key in allKeys:
    values = sources
      .filter(s => key in s.variantMap)
      .map(s => ({ state_name: s.state_name, ...s.variantMap[key] }))
    merged[key] = { values, merged: true }

  // 3. Classify properties
  for key in merged:
    merged[key].classification = classifyProperty(key, merged[key].values)

  return merged
```

### Implementation Sites

`mergeVariantMaps()` is not defined inline — it is implemented by specific agents and triggered at a defined point in the pipeline:

- **Who implements it**: The `design-analyst` agent (`agents/design-analyst.md`). After classifying the relationship group, the analyst merges the per-source variant maps using this algorithm before writing the final v1.1 VSM.
- **Where it is triggered**: Arc Phase 3 design extraction (`skills/arc/references/arc-phase-design-extraction.md`), specifically after the analyst has completed relationship classification for a same-screen group. The merge occurs before the VSM is written to `tmp/arc/{id}/vsm/{component-name}.json`.
- **Input**: An array of per-source extraction results, each containing a `variantMap` keyed by property name and a `state_name` label.
- **Output**: A merged variant map where each property is annotated with `classification` (`structurally_immutable`, `state_mutable`, or `content_variable`) and a `values` array with per-source entries.

### Property Classification for Diffing

Properties are classified to determine how they should be diffed across sources:

| Classification | Description | Examples |
|---------------|-------------|---------|
| `structurally_immutable` | Same value in all sources — not a variant axis | background color, font family |
| `state_mutable` | Differs across sources — is a variant axis | width (desktop vs mobile), padding |
| `content_variable` | Text/image content — differs by design intent | label text, hero image |

```javascript
function classifyProperty(key, values):
  uniqueTokenValues = new Set(values.map(v => v.token ?? v.value))
  if uniqueTokenValues.size === 1: return "structurally_immutable"
  if key.includes("text") || key.includes("content"): return "content_variable"
  return "state_mutable"
```

Only `state_mutable` properties are surfaced in the merged Variant Map diff column.
`structurally_immutable` properties are listed once. `content_variable` properties
are omitted from the merged map (implementation handles content separately).

## Region Tree Diff Layer (v1.1 Only)

When sources differ structurally (e.g., Desktop adds a sidebar region absent on Mobile),
the Region Tree includes an additive diff layer using node path matching:

```markdown
## Region Tree

- **AppRoot** — `<div>`, flex-row [ALL SOURCES]
  - **Sidebar** — `<aside>`, w-64 [Desktop only] <!-- state_name: Desktop -->
  - **Main** — `<main>`, flex-1 [ALL SOURCES]
    - **Header** — `<header>`, h-16 [ALL SOURCES]
```

**Node path matching**: Nodes are matched by semantic hierarchy (element type + role),
NOT by Figma node IDs (which differ across files). Matching algorithm:

```javascript
function matchNodes(nodesA, nodesB):
  // Match by: element type + auto-layout direction + child count ± 2
  for nodeA in nodesA:
    candidates = nodesB.filter(b =>
      b.elementType == nodeA.elementType AND
      b.layoutMode == nodeA.layoutMode AND
      abs(b.children.length - nodeA.children.length) <= 2
    )
    // Best match: highest structural similarity score
    match = argmax(c in candidates, structuralSimilarity(nodeA, c))
    if match: yield (nodeA, match)
    else: yield (nodeA, null)  // Desktop-only node
```

Unmatched nodes are annotated with `[{state_name} only]` in the Region Tree.

## Validation Rules

```
1. vsm_schema_version MUST be "1.0" or "1.1"
2. figma_url MUST match FIGMA_URL_PATTERN
3. Token Map MUST have at least 1 entry
4. Region Tree MUST have at least 1 root node
5. Every node in Region Tree MUST specify a semantic element
6. Variant Map may be empty (single-variant component)
7. Responsive Spec MUST have at least "Default (mobile)" entry
8. Accessibility section MUST have at least semantic element + contrast entries
9. micro_design section is OPTIONAL — omit for static components
10. If micro_design.states is present, each component MUST have a "default" state
11. If micro_design.compound_interactions is present, each entry MUST have a "keyboard" map
12. micro_design.scroll entries MUST have "trigger" and "effect" keys (or be set to false)
13. micro_design.transitions values MUST be valid Tailwind class strings
// v1.1-only rules (only apply when vsm_schema_version == "1.1")
14. variant_sources MUST be an array with at least 1 entry
15. Each variant_sources entry MUST have url, role, node_id, state_name
16. variant_sources[].role MUST be "primary" | "variant" | "breakpoint"
17. relationship_group MUST match /^grp-\d{3}$/ when present
18. relationship_confidence MUST be in [0.0, 1.0] when present
19. Exactly one variant_sources entry MUST have role: "primary"
// Semantic Component Map rules (apply when semantic_component_map is present)
20. Semantic Component Map is OPTIONAL — omit when semantic classification not performed
21. Each semantic_component_map entry MUST have region, semantic_role, and confidence fields
22. semantic_component_map[].confidence MUST be in [0.0, 1.0]
// v1.2-only rules (enhanced fidelity)
23. Token Map MUST include per-side spacing when padding/margin is asymmetric
24. Token Map MUST include border-width + border-color for nodes with Figma strokes (NOT just radius)
25. Region Tree MUST preserve LINE and thin RECTANGLE nodes as Separator — NEVER skip
26. Region Tree MUST annotate absolute-positioned nodes with z-index
27. Icon Inventory is REQUIRED when icons are present in the design — NEVER omit
28. Each Icon Inventory entry MUST have region, icon_name (or "unknown"), size, and color_token
```
