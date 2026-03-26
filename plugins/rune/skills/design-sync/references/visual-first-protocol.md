# Visual-First Protocol

## Principle

The Figma screenshot is the PRIMARY validation source. MCP tool outputs (`get_figma_data()` / `figma_inspect_node()` /
`figma_to_react()`) are SECONDARY — they often miss:
- Interaction states (hover, active, disabled)
- Animations and transitions
- Responsive behavior at different breakpoints
- Nested/overlapping structures
- Floating elements (tooltips, badges, dropdowns)

## Extraction Order (MANDATORY)

1. **Screenshot FIRST** — Create VSM from visual analysis
2. **Metadata SECOND** — `get_figma_data()` (Framelink, preferred) or `figma_fetch_design()` (Rune) for structure overview
3. **Design context THIRD** — `figma_inspect_node()` (Rune-only, graceful skip) for deep tokens/effects
4. **Reference code LAST** — `figma_to_react()` (Rune-only, graceful skip) for intent hints only

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
