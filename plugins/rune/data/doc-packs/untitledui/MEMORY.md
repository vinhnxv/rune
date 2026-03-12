# UntitledUI Doc Pack

## Etched — UntitledUI: Component Conventions (2026-03-11)

**Source**: `doc-pack:untitledui@1.0.0`
**Category**: pattern

### Naming and Imports

- Components use `Aria*` prefix (React Aria foundation): `AriaButton`, `AriaDialog`
- Import from package root: `import { AriaButton } from "@untitledui/react"`
- Compound components: `AriaTable.Header`, `AriaTable.Row`, `AriaTable.Cell`
- Icons: `import { HomeIcon } from "@untitledui/icons"` — separate package

### Component API Patterns

- All components accept `size` prop: `"xs" | "sm" | "md" | "lg" | "xl" | "2xl"`
- All components accept `variant` prop for visual style
- Slots pattern for composition: `<AriaButton startIcon={<HomeIcon />}>`
- `asChild` prop for custom element rendering (like Radix primitives)

### Style System

- Built on Tailwind CSS v4.1 with semantic color tokens
- Class merging: use `cn()` utility — components accept `className` prop
- Colors are semantic: `primary`, `secondary`, `error`, `warning`, `success`
- No inline styles — all customization via Tailwind classes or CSS variables

## Etched — UntitledUI: Design Token System (2026-03-11)

**Source**: `doc-pack:untitledui@1.0.0`
**Category**: pattern

### Token Categories

- **Color**: `--color-primary-*`, `--color-gray-*`, `--color-error-*` (50-950 scale)
- **Spacing**: `--spacing-*` follows 4px grid: `xs=4px`, `sm=8px`, `md=12px`, `lg=16px`
- **Typography**: `--font-size-*`, `--font-weight-*`, `--line-height-*`
- **Shadows**: `--shadow-xs` through `--shadow-3xl` for elevation levels
- **Radius**: `--radius-*` from `none` to `full`

### Using Tokens in Code

- Tokens map to Tailwind utilities: `text-primary-600`, `p-spacing-md`, `shadow-lg`
- Override at theme level in CSS: `@theme { --color-primary-600: oklch(0.55 0.2 250); }`
- Dark mode tokens: defined as separate set, auto-applied via `.dark` class
- Typography scale: `display-2xl` through `text-xs` with matching line-height

### Figma-to-Code Mapping

- Figma auto-layout maps to `flex` with `gap-*` utilities
- Figma fill maps to `w-full` or `flex-1`
- Figma fixed dimensions map to `w-[Npx]` `h-[Npx]` (use sparingly)
- Figma component variants map to React props: `variant`, `size`, `state`

## Etched — UntitledUI: Variant and Size Patterns (2026-03-11)

**Source**: `doc-pack:untitledui@1.0.0`
**Category**: pattern

### Button Variants

| Variant | Use Case |
|---------|----------|
| `primary` | Primary actions (submit, save, confirm) |
| `secondary` | Secondary actions alongside primary |
| `tertiary` | Low-emphasis actions (cancel, back) |
| `link` | Inline text-style actions |
| `destructive` | Dangerous actions (delete, remove) |

### Size Scale

- `xs`: Compact UI, table actions, inline controls
- `sm`: Secondary buttons, form controls, tight layouts
- `md`: Default — most buttons and inputs
- `lg`: Hero sections, prominent CTAs
- `xl`/`2xl`: Marketing pages, onboarding flows

### State Handling

- Components handle `hover`, `focus`, `active`, `disabled` states internally
- `isLoading` prop: shows spinner, disables interaction, preserves width
- `isDisabled` prop: applies disabled styling and `aria-disabled`
- Focus visible: keyboard focus ring uses `--color-primary-*` tokens
