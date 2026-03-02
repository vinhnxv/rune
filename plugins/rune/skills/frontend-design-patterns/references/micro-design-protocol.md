# Micro-Design Detail Protocol — Interactive States, Transitions, and Keyboard Interactions

Micro-design details are the interactive behaviors that distinguish a polished component from a static mockup: hover effects, focus rings, transitions, scroll behaviors, and keyboard navigation. This protocol defines how to capture, map, and verify these details during design-to-code workflows.

## Interactive State Mapping

Every interactive component has multiple visual states. Map each Figma state variant to its CSS/Tailwind implementation.

### Standard States

| State | Figma Source | Tailwind Prefix | ARIA |
|-------|-------------|-----------------|------|
| Default | Base variant | (none) | — |
| Hover | Hover variant or prototype | `hover:` | — |
| Active/Pressed | Pressed variant or prototype | `active:` | — |
| Focus | Focus variant | `focus-visible:` | — |
| Disabled | Disabled variant | `disabled:` + class overrides | `aria-disabled="true"` |
| Loading | Loading variant | (conditional classes) | `aria-busy="true"` |
| Selected | Selected variant | `data-[state=selected]:` | `aria-selected="true"` |
| Error | Error variant | `data-[invalid]:` | `aria-invalid="true"` |

**Rule**: Always use `focus-visible:` instead of `focus:` for keyboard focus indicators. This prevents focus rings from appearing on mouse clicks while keeping them for keyboard navigation.

### State-to-Class Mapping Algorithm

```
For each component in the Figma file:
  1. Identify all state variants (check Component Set properties)
  2. For each state variant:
     a. Diff visual properties against the default state
     b. Map each changed property to a Tailwind class
     c. Apply the correct state prefix (hover:, active:, etc.)
  3. Verify disabled state includes:
     - Reduced opacity (opacity-50 or similar)
     - cursor-not-allowed
     - aria-disabled="true"
  4. Verify focus state includes:
     - Visible focus ring (ring-2 ring-ring ring-offset-2)
     - outline-none (removes default browser outline)
```

### Per-State Property Reference

| Property | Default → Hover | Default → Active | Default → Disabled |
|----------|----------------|------------------|-------------------|
| Background | Darken 10% or add opacity | Darken 20% | Add opacity-50 |
| Transform | none | scale(0.98) | none |
| Shadow | Increase | Decrease or remove | Remove |
| Cursor | pointer | pointer | not-allowed |
| Opacity | 1 | 1 | 0.5 |
| Border | May add or change color | May darken | Muted color |

## Transition Catalog

Standard transition definitions for common interaction patterns. Use these as defaults when Figma does not specify explicit animation values.

### Standard Transitions

| Name | Tailwind Classes | Use Case |
|------|-----------------|----------|
| `color_change` | `transition-colors duration-150 ease-in-out` | Background, text, border color changes on hover/focus |
| `layout_shift` | `transition-all duration-200 ease-out` | Size, padding, margin changes |
| `transform` | `transition-transform duration-75 ease-in` | Scale on active/pressed |
| `opacity` | `transition-opacity duration-200 ease-in-out` | Fade in/out |
| `modal_enter` | `animate-in fade-in-0 zoom-in-95 duration-200` | Dialog/modal opening |
| `modal_exit` | `animate-out fade-out-0 zoom-out-95 duration-150` | Dialog/modal closing |
| `slide_in` | `animate-in slide-in-from-right duration-300` | Drawer/panel entering |
| `slide_out` | `animate-out slide-out-to-right duration-200` | Drawer/panel exiting |
| `accordion` | `transition-[grid-template-rows] duration-200` | Expand/collapse content |
| `dropdown` | `animate-in fade-in-0 slide-in-from-top-2 duration-200` | Dropdown menu opening |
| `tooltip` | `animate-in fade-in-0 duration-150` | Tooltip appearing |

### Transition Selection Rules

```
When generating transition recommendations:
  1. Color-only changes → transition-colors (NOT transition-all)
  2. Size/transform changes → transition-transform
  3. Combined changes → transition-all (last resort, higher GPU cost)
  4. Enter animations → use animate-in with appropriate origin
  5. Exit animations → use animate-out, 25% shorter duration than enter
  6. Accordion/expand → use grid-template-rows trick for smooth height
  7. Never animate width/height directly — use transform: scale or grid
```

### Duration Guidelines

| Interaction Type | Duration | Reasoning |
|-----------------|----------|-----------|
| Hover state change | 100-150ms | Must feel instant |
| Focus ring | 0ms (immediate) | Accessibility — no delay |
| Active/pressed | 50-75ms | Tactile feedback |
| Dropdown open | 150-200ms | Perceivable but fast |
| Modal open | 200ms | Noticeable entrance |
| Modal close | 150ms | Exit should be faster |
| Page transition | 200-300ms | Smooth but not sluggish |
| Skeleton shimmer | 1500-2000ms | Slow loop, low urgency |

## Scroll Behaviors

Document scroll-triggered behaviors that affect component appearance or behavior.

### Sticky Header Pattern

```
Trigger: scroll position > header height (typically 64px)
Effect:
  - Add: bg-background/80 backdrop-blur-sm border-b
  - Use: IntersectionObserver on sentinel element
  - Tailwind: sticky top-0 z-50
Implementation:
  const [isSticky, setIsSticky] = useState(false)
  // Use IntersectionObserver, NOT scroll event listener
```

### Infinite Scroll Pattern

```
Trigger: IntersectionObserver on sentinel 200px before viewport edge
Effect: Load next page of data
Requirements:
  - Show loading skeleton at bottom during fetch
  - Handle "no more data" terminal state
  - Preserve scroll position on back navigation
  - aria-live="polite" on new content region
```

### Parallax

```
Default: false (explicitly document non-use)
When present:
  - Use transform: translateY() with will-change: transform
  - Respect prefers-reduced-motion: reduce → disable parallax
  - Never use on mobile (performance, accessibility)
```

## Responsive Interactions

Interactions that fundamentally differ between mobile and desktop breakpoints. These go beyond simple layout changes (which are in the Responsive Spec section of the VSM).

### Navigation Patterns

| Breakpoint | Pattern | Trigger | Animation |
|-----------|---------|---------|-----------|
| Mobile (< md) | Hamburger menu | Click/tap | slide-in-from-left |
| Desktop (>= md) | Horizontal nav bar | Hover dropdown | fade-in |

### Sidebar Patterns

| Breakpoint | Pattern | Trigger | Animation |
|-----------|---------|---------|-----------|
| Mobile (< md) | Overlay drawer | Swipe or click | slide-in-from-left |
| Desktop (>= md) | Persistent sidebar | Always visible | none |
| Desktop collapsible | Icon-only rail | Click toggle | transition-[width] |

### When to Document Responsive Interactions

```
Include responsive_interactions when:
  - A component has DIFFERENT interaction patterns per breakpoint
  - Mobile uses touch gestures that desktop does not
  - Desktop uses hover states that mobile replaces with tap

Do NOT include when:
  - Only layout changes (columns, spacing) — use Responsive Spec instead
  - Same interaction pattern at all breakpoints, just resized
```

## Data-Attribute Responsive Pattern

UntitledUI uses data attributes for state-driven styling. Document these when the design system uses this pattern.

### Common Data Attributes

| Attribute | Purpose | CSS Selector | Example |
|-----------|---------|-------------|---------|
| `data-state` | Open/closed for Radix primitives | `[data-state=open]:` | Accordion, Dialog |
| `data-loading` | Loading state indicator | `[data-loading]:opacity-50` | Any async component |
| `data-selected` | Selection state | `[data-selected]:bg-accent` | List items, tabs |
| `data-disabled` | Non-interactive state | `[data-disabled]:pointer-events-none` | Form fields |
| `data-icon` | Icon element marker | `[data-icon]:size-4` | Icon size inheritance |
| `data-orientation` | Horizontal/vertical layout | `[data-orientation=vertical]:flex-col` | Separator, Tabs |
| `data-side` | Popover/tooltip position | `[data-side=top]:animate-slide-down` | Popover, Tooltip |

### Tailwind v4 Data Attribute Syntax

```
Tailwind v4 supports data attribute variants natively:

  data-[state=open]:rotate-180     → [data-state="open"] .rotate-180
  data-[loading]:animate-pulse     → [data-loading] .animate-pulse
  data-[selected]:bg-accent        → [data-selected] .bg-accent

No plugin or custom variant needed.
```

## Compound Component Keyboard Interactions

Compound components (Select, Accordion, Dialog, Tabs, etc.) require specific keyboard navigation patterns. These MUST follow WAI-ARIA Authoring Practices.

### Select / Combobox

| Key | Action |
|-----|--------|
| Enter / Space | Open listbox (when trigger focused) |
| ArrowDown | Move to next option |
| ArrowUp | Move to previous option |
| Home | Move to first option |
| End | Move to last option |
| Escape | Close listbox, return focus to trigger |
| Type-ahead | Jump to option starting with typed character(s) |

```
ARIA requirements:
  - Trigger: role="combobox" aria-expanded="true/false" aria-haspopup="listbox"
  - Listbox: role="listbox"
  - Options: role="option" aria-selected="true/false"
  - Active descendant: aria-activedescendant={id}
```

### Accordion

| Key | Action |
|-----|--------|
| Enter / Space | Toggle content panel |
| ArrowDown | Move focus to next trigger |
| ArrowUp | Move focus to previous trigger |
| Home | Move focus to first trigger |
| End | Move focus to last trigger |

```
ARIA requirements:
  - Trigger: role="button" (or <button>) aria-expanded="true/false" aria-controls={panel-id}
  - Panel: role="region" aria-labelledby={trigger-id}
```

### Dialog / Modal

| Key | Action |
|-----|--------|
| Tab | Cycle focus within dialog (trap focus) |
| Shift+Tab | Cycle focus backward |
| Escape | Close dialog, return focus to trigger |

```
ARIA requirements:
  - Container: role="dialog" aria-modal="true" aria-labelledby={title-id}
  - Focus trap: first focusable element on open, return to trigger on close
  - Inert: content behind dialog must be aria-hidden="true"
```

### Tabs

| Key | Action |
|-----|--------|
| ArrowRight | Activate next tab (horizontal) |
| ArrowLeft | Activate previous tab (horizontal) |
| ArrowDown | Activate next tab (vertical) |
| ArrowUp | Activate previous tab (vertical) |
| Home | Activate first tab |
| End | Activate last tab |

```
ARIA requirements:
  - Tab list: role="tablist"
  - Tab: role="tab" aria-selected="true/false" aria-controls={panel-id}
  - Panel: role="tabpanel" aria-labelledby={tab-id}
```

### Tooltip

| Key | Action |
|-----|--------|
| Focus (Tab) | Show tooltip |
| Escape | Dismiss tooltip |
| Blur | Hide tooltip |

```
ARIA requirements:
  - Trigger: aria-describedby={tooltip-id}
  - Tooltip: role="tooltip"
  - Delay: 300-500ms before showing (avoid flash on fast tab-through)
```

## Extraction Algorithm

How to extract micro-design details from Figma during design-sync workflows.

```
Micro-Design Extraction (Step 4 — after token/region/variant extraction):

1. INSPECT state variants
   For each component, check the Figma Component Set for state properties:
   - Look for properties named: State, Status, Interaction, Mode
   - Common values: Default, Hover, Pressed, Focused, Disabled, Loading
   - If no state property exists, check for prototype interactions

2. MAP states to Tailwind
   For each state variant found:
   a. Run visual diff against the default variant
   b. Map each changed property:
      - Background color change → hover:bg-{token}
      - Border change → hover:border-{token}
      - Shadow change → hover:shadow-{token}
      - Opacity change → hover:opacity-{value}
      - Transform change → hover:scale-{value}
   c. Apply prefix based on state name:
      - Hover → hover:
      - Pressed/Active → active:
      - Focused → focus-visible:
      - Disabled → class-based (no prefix, conditional render)

3. GENERATE transition recommendations
   Based on which properties change between states:
   - Color only → transition-colors duration-150
   - Transform → transition-transform duration-75
   - Multiple properties → transition-all duration-200
   - Enter/exit → animate-in / animate-out patterns

4. DETECT compound interactions
   Check component description for keywords:
   - "dropdown", "select", "combobox" → Select keyboard map
   - "accordion", "collapse", "expand" → Accordion keyboard map
   - "dialog", "modal", "overlay" → Dialog keyboard map
   - "tabs", "tab group" → Tabs keyboard map

5. WRITE micro_design section to VSM
   Output the collected data as the micro_design section
   following the VSM schema (Section 8).
```

## Verification Checklist

When reviewing micro-design implementation, verify:

```
States:
  [ ] Every interactive element has hover + focus-visible states
  [ ] Disabled state uses aria-disabled (not just HTML disabled)
  [ ] Focus ring is visible with sufficient contrast (3:1 minimum)
  [ ] Active/pressed state provides tactile feedback

Transitions:
  [ ] Hover transitions use transition-colors (not transition-all)
  [ ] No transition on focus ring (must be immediate)
  [ ] Exit animations are 25% shorter than enter animations
  [ ] prefers-reduced-motion disables non-essential animations

Keyboard:
  [ ] Compound components implement full WAI-ARIA keyboard map
  [ ] Focus is trapped in modals/dialogs
  [ ] Escape closes all overlay components
  [ ] Tab order follows visual layout

Scroll:
  [ ] Sticky elements use IntersectionObserver (not scroll events)
  [ ] Infinite scroll has terminal state handling
  [ ] Parallax respects prefers-reduced-motion
```

## Cross-References

- [vsm-spec.md (Section 8)](../../design-sync/references/vsm-spec.md) — VSM micro_design schema definition
- [accessibility-patterns.md](accessibility-patterns.md) — ARIA attributes and focus management
- [state-and-error-handling.md](state-and-error-handling.md) — UI state patterns (loading, error, empty)
- [responsive-patterns.md](responsive-patterns.md) — Breakpoint-specific layout patterns
