# UntitledUI Doc Pack

## Etched — UntitledUI: Component Conventions (2026-03-01)

**Source**: `doc-pack:untitledui@1.0.0`
**Category**: pattern

### Naming and Import Patterns
- Components use `Aria*` prefix for React Aria integration: `AriaButton`, `AriaDialog`
- Import from package: `import { AriaButton } from '@untitledui/react'`
- Compound component pattern: `<AriaSelect><AriaSelectTrigger /><AriaSelectContent /></AriaSelect>`
- File naming: kebab-case (`aria-button.tsx`), component naming: PascalCase (`AriaButton`)

### Variant and Size Props
- Standard sizes: `xs`, `sm`, `md`, `lg`, `xl`, `2xl`
- Standard variants: `primary`, `secondary`, `tertiary`, `link`, `destructive`
- Use `size` and `variant` props consistently across all components
- Custom variants: extend via `className` merge — do NOT create wrapper components

## Etched — UntitledUI: Design Token System (2026-03-01)

**Source**: `doc-pack:untitledui@1.0.0`
**Category**: pattern

### Token Architecture
- Semantic color tokens: `--color-fg-primary`, `--color-bg-secondary`, `--color-border-primary`
- Spacing scale: 4px base — `--spacing-1` (4px), `--spacing-2` (8px), `--spacing-4` (16px)
- Typography: `--font-size-sm` (14px), `--font-size-md` (16px), `--font-weight-semibold` (600)
- Radius: `--radius-sm` (6px), `--radius-md` (8px), `--radius-lg` (12px)

### Tailwind v4 Integration
- Tokens defined in `@theme` block — auto-generates Tailwind utilities
- `bg-bg-secondary` maps to `var(--color-bg-secondary)` — semantic naming
- Dark mode: tokens swap values automatically via `.dark` class
- Use semantic tokens (`text-fg-primary`) — never raw colors (`text-gray-900`)

## Etched — UntitledUI: Figma-to-Code Mapping (2026-03-01)

**Source**: `doc-pack:untitledui@1.0.0`
**Category**: pattern

### Component Matching
- Figma component names map 1:1 to React components: `Button` → `AriaButton`
- Figma variants map to props: `Size=lg, Hierarchy=Secondary` → `<AriaButton size="lg" variant="secondary">`
- Icons: use Figma icon names directly with UntitledUI icon set
- Auto-layout in Figma = `flex` in code — gap values match spacing tokens

### Implementation Rules
- REUSE existing UntitledUI components before creating custom ones
- EXTEND via `className` prop for minor adjustments
- CREATE new components only when no UntitledUI equivalent exists
- Always check MCP tools first: `search_components("button")` before building custom

### Accessibility
- React Aria provides built-in keyboard navigation and ARIA attributes
- Do NOT add redundant `aria-*` attributes — React Aria handles them
- Focus management: `<FocusScope>` for modal/dialog focus trapping
- Screen reader: `<VisuallyHidden>` for accessible labels without visual text
