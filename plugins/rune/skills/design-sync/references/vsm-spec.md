# Visual Spec Map (VSM) Schema

The VSM is the intermediate representation between Figma design data and code implementation. One VSM file per component.

## Schema Version

```yaml
vsm_schema_version: "1.0"
```

All VSM files MUST include the schema version as the first field in the YAML frontmatter.

## File Location

```
tmp/design-sync/{timestamp}/vsm/{component-name}.md
```

## Full Schema

```yaml
---
vsm_schema_version: "1.0"
component_name: "CardComponent"
figma_url: "https://www.figma.com/design/abc123/MyApp?node-id=1-3"
figma_file_key: "abc123"
figma_node_id: "1-3"
extracted_at: "2026-02-25T12:00:00Z"
---
```

## Section 1: Token Map

Maps every visual property to a design token.

```markdown
## Token Map

| Property | Figma Value | Design Token | Tailwind | Status |
|----------|------------|-------------|----------|--------|
| Background | #FFFFFF | --color-background | bg-white | matched |
| Text color | #0A0A0A | --color-foreground | text-foreground | matched |
| Padding | 16px | --spacing-4 | p-4 | matched |
| Gap | 12px | --spacing-3 | gap-3 | matched |
| Border radius | 8px | --radius-lg | rounded-lg | matched |
| Shadow | 0 1px 3px rgba(0,0,0,0.1) | shadow-sm | shadow-sm | matched |
| Font size | 18px | text-lg | text-lg | matched |
| Font weight | 600 | font-semibold | font-semibold | matched |
| Accent color | #7C3AED | — | — | unmatched |
```

Status values:
- `matched` — exact or snapped token found
- `unmatched` — no token within snap distance (requires manual mapping)
- `off-scale` — value not on standard scale (rounded in Tailwind column)

## Section 2: Region Tree

Hierarchical decomposition of the component structure.

```markdown
## Region Tree

- **CardRoot** — `<article>`, flex-col, gap-3, p-4, rounded-lg, shadow-sm
  - **CardImage** — `<img>`, w-full, h-48, object-cover, rounded-t-lg
  - **CardBody** — `<div>`, flex-col, gap-2
    - **CardTitle** — `<h3>`, text-lg, font-semibold, text-foreground
    - **CardDescription** — `<p>`, text-sm, text-muted-foreground, line-clamp-2
  - **CardFooter** — `<div>`, flex-row, justify-between, items-center
    - **CardMeta** — `<span>`, text-xs, text-muted
    - **CardActions** — `<div>`, flex-row, gap-2
      - **ActionButton** — `<button>`, variant=ghost, size=sm
```

Each node specifies: semantic element, layout classes, sizing, and token references.

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

## Validation Rules

```
1. vsm_schema_version MUST be "1.0"
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
```
