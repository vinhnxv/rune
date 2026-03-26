# Visual-First Protocol

## Principle

The Figma screenshot is the PRIMARY validation source. `figma_inspect_node()` / `get_figma_data()` and
`figma_to_react()` output are SECONDARY — they often miss:
- Interaction states (hover, active, disabled)
- Animations and transitions
- Responsive behavior at different breakpoints
- Nested/overlapping structures
- Floating elements (tooltips, badges, dropdowns)

## Extraction Order (MANDATORY)

1. **Screenshot FIRST** — Create VSM from visual analysis
2. **Metadata SECOND** — `figma_fetch_design()` (Rune) or `get_figma_data(depth=1)` (Framelink) for structure overview
3. **Design context THIRD** — `figma_inspect_node()` (Rune) or `get_figma_data()` (Framelink) for tokens
4. **Reference code LAST** — `figma_to_react()` for intent hints only

Never analyze reference code before creating the VSM.
The VSM is the source of truth for layout, spacing, and hierarchy.

## Region Identification

Scan the screenshot systematically:
- Top-to-bottom (headers -> content -> footers)
- Left-to-right (sidebars -> main -> secondary panels)
- Overlay detection (floating elements, modals, tooltips)

## 4-Level Hierarchy

| Level | Name | Examples |
|-------|------|---------|
| L1 | Page Structure | Header, Sidebar, Main, Footer |
| L2 | Section Analysis | Card groups, Form sections, Table areas |
| L3 | Component Mapping | Individual cards, Form fields, Table rows |
| L4 | Atomic Elements | Text, Icons, Buttons, Badges, Inputs |

## Floating Element Detection (Commonly Missed)

Check for elements that:
- Use absolute/fixed positioning
- Overlap other regions
- Appear on scroll/hover

Document: parent element, position offset, z-index, trigger interaction.

## Output: VSM YAML Structure

See [vsm-spec.md](vsm-spec.md) for the full schema.
