# Untitled UI — Component Library Profile

```
profile_schema_version: 1
library: Untitled UI
base_primitive: CSS custom properties / design tokens
styling: Tailwind CSS v4.1 + CSS custom properties (design tokens)
```

> **Canonical Implementation Reference**: For code patterns (imports, variants, styling), see [`agent-conventions.md`](../../untitledui-mcp/references/agent-conventions.md). This profile focuses on design token semantics and Figma variable mapping.

Untitled UI is a large-scale Figma design system + React component library built on CSS custom properties (design tokens) for theming and a 5-tier directory structure for organizing components by use case. It provides production-ready components with comprehensive CSS variable-driven theming and React Aria integration for accessible interactive primitives.

## File Organization — 5-Tier Directory

```
src/
└── components/
    ├── base/              ← Tier 1: Atoms and primitives (Button, Input, Badge, Avatar)
    │   ├── buttons/
    │   │   ├── button.tsx
    │   │   └── index.ts
    │   └── ...
    ├── application/       ← Tier 2: Molecules and organisms for app UI (Modal, DataTable, Sidebar)
    │   ├── modal/
    │   ├── data-table/
    │   └── ...
    ├── foundations/        ← Tier 3: Design tokens, FeaturedIcon, icons, logos
    │   ├── featured-icon/
    │   └── ...
    ├── marketing/         ← Tier 4: Page sections for landing/marketing pages (Hero, PricingCard, Testimonial)
    │   ├── hero/
    │   ├── pricing-card/
    │   └── ...
    └── shared-assets/     ← Tier 5: Login, signup, 404 pages (PRO)
        ├── login/
        └── ...
```

**Tier rules:**
- `base/` components have zero business logic — pure UI primitives
- `application/` components may read from stores or context but do not fetch data
- `foundations/` contains design infrastructure — tokens, icons, logos, featured-icon
- `marketing/` components are typically static or CMS-driven; avoid shared state coupling
- `shared-assets/` contains full page layouts (login, signup, 404) — PRO tier only

## CSS Variable Token System

Untitled UI tokens use `--fg-` (foreground) and `--bg-` (background) prefix conventions:

```css
/* tokens.css */
:root {
  /* Foreground tokens */
  --fg-primary: #101828;          /* Primary text */
  --fg-secondary: #344054;        /* Secondary text */
  --fg-tertiary: #475467;         /* Tertiary/placeholder text */
  --fg-quaternary: #667085;       /* Disabled text */
  --fg-white: #ffffff;            /* Text on dark surfaces */
  --fg-brand-primary: #7F56D9;    /* Brand-colored text */
  --fg-error: #D92D20;            /* Error state text */
  --fg-warning: #DC6803;          /* Warning state text */
  --fg-success: #039855;          /* Success state text */

  /* Background tokens */
  --bg-primary: #ffffff;          /* Primary surface */
  --bg-secondary: #f9fafb;        /* Slightly elevated surface */
  --bg-tertiary: #f2f4f7;         /* Input backgrounds, subtle areas */
  --bg-quaternary: #e4e7ec;       /* Disabled backgrounds */
  --bg-brand-primary: #7F56D9;    /* Brand-colored backgrounds */
  --bg-error-primary: #FEF3F2;    /* Error surface tint */
  --bg-success-primary: #ECFDF3;  /* Success surface tint */

  /* Border tokens */
  --border-primary: #d0d5dd;
  --border-secondary: #e4e7ec;
  --border-error: #FDA29B;

  /* Spacing scale */
  --spacing-xs: 4px;
  --spacing-sm: 8px;
  --spacing-md: 16px;
  --spacing-lg: 24px;
  --spacing-xl: 32px;
  --spacing-2xl: 48px;
  --spacing-3xl: 64px;
}

/* Dark mode token override — applied via Tailwind dark: class-based mode */
.dark {
  --fg-primary: #f9fafb;
  --fg-secondary: #e4e7ec;
  --bg-primary: #0c111d;
  --bg-secondary: #161b26;
  --bg-tertiary: #1f242f;
  --border-primary: #333741;
}
```

**Token naming convention:**

| Pattern | Meaning | Example |
|---------|---------|---------|
| `--fg-{role}` | Foreground/text color | `--fg-primary`, `--fg-error` |
| `--bg-{role}` | Background color | `--bg-primary`, `--bg-brand-primary` |
| `--border-{role}` | Border color | `--border-primary`, `--border-error` |
| `--spacing-{size}` | Spacing scale | `--spacing-md`, `--spacing-xl` |
| `--radius-{size}` | Border radius | `--radius-sm`, `--radius-xl` |

## React Aria Integration

Untitled UI uses React Aria hooks for accessible behavior and React Aria Components for composable primitives.

**CRITICAL — `Aria*` Prefix Convention**: All imports from `react-aria-components` MUST be aliased with the `Aria*` prefix to avoid naming conflicts with UntitledUI's own components (e.g., `import { Button as AriaButton } from "react-aria-components"`). See [`agent-conventions.md`](../../untitledui-mcp/references/agent-conventions.md) for the full import pattern.

### React Aria Hooks

```typescript
import { useButton } from "@react-aria/button"
import { useDialog } from "@react-aria/dialog"
import { useFocusTrap } from "@react-aria/focus"
import { useOverlay, usePreventScroll, useModal } from "@react-aria/overlays"
import { useTextField } from "@react-aria/textfield"
import { useCheckbox } from "@react-aria/checkbox"
import { useSelect } from "@react-aria/select"

// useButton example — accessible button behavior
function Button({ children, onPress, isDisabled, ...props }) {
  const ref = useRef(null)
  const { buttonProps } = useButton({ children, onPress, isDisabled, ...props }, ref)
  return (
    <button
      {...buttonProps}
      ref={ref}
      className={cn("btn", isDisabled && "btn--disabled")}
    >
      {children}
    </button>
  )
}
```

### React Aria Components (RAC)

Newer Untitled UI versions use React Aria Components for a higher-level API:

```typescript
import {
  Button,
  Dialog,
  DialogTrigger,
  Heading,
  Modal,
  ModalOverlay,
} from "react-aria-components"

// Dialog with React Aria Components
function AlertDialog({ title, children, onConfirm }) {
  return (
    <DialogTrigger>
      <Button>Open Alert</Button>
      <ModalOverlay className="modal-overlay">
        <Modal className="modal">
          <Dialog>
            {({ close }) => (
              <>
                <Heading slot="title">{title}</Heading>
                <div className="dialog-body">{children}</div>
                <div className="dialog-footer">
                  <Button onPress={close}>Cancel</Button>
                  <Button onPress={() => { onConfirm(); close() }}>Confirm</Button>
                </div>
              </>
            )}
          </Dialog>
        </Modal>
      </ModalOverlay>
    </DialogTrigger>
  )
}
```

**Rule**: Always use React Aria hooks or components for interactive elements. Never build custom focus traps, keyboard handlers, or ARIA state management from scratch.

## Variant Patterns

For component variant patterns, see the canonical reference: [`agent-conventions.md`](../../untitledui-mcp/references/agent-conventions.md) (sortCx pattern with Tailwind utilities). Untitled UI uses the `sortCx()` utility for organizing variant styles with semantic Tailwind classes — not BEM-style CSS Modules.

## Import Conventions

```typescript
// Base components (kebab-case paths)
import { Button } from "@/components/base/buttons/button"
import { Input } from "@/components/base/input/input"
import { Badge } from "@/components/base/badges/badges"

// Application components
import { Modal } from "@/components/application/modal/modal"
import { DataTable } from "@/components/application/data-table/data-table"

// Foundations
import { FeaturedIcon } from "@/components/foundations/featured-icon/featured-icon"

// Marketing components
import { Hero } from "@/components/marketing/hero/hero"

// React Aria — MUST use Aria* prefix to avoid naming conflicts
import { Button as AriaButton } from "react-aria-components"
import { TextField as AriaTextField } from "react-aria-components"

// React Aria hooks (no prefix needed — hooks don't conflict)
import { useButton } from "@react-aria/button"
import { useDialog } from "@react-aria/dialog"
```

## Dark Mode Implementation

Untitled UI uses Tailwind's class-based dark mode (`dark:` variant). Add the `dark` class to the `<html>` element to activate dark mode. Semantic color tokens switch automatically via Tailwind's `@theme` configuration — no manual CSS variable overrides needed.

```typescript
// Theme toggle — class-based dark mode
function toggleTheme() {
  document.documentElement.classList.toggle("dark")
}
```

**Rule**: Use Tailwind `dark:` variant with semantic color classes (e.g., `dark:bg-primary`, `dark:text-primary`). The semantic tokens already resolve to correct dark mode values. Do NOT use raw `[data-theme="dark"]` attribute selectors — the Tailwind v4.1 stack uses class-based dark mode.

## Figma Variable Mapping

Untitled UI Figma variables map directly to CSS tokens:

| Figma Variable | CSS Token | Usage |
|---------------|-----------|-------|
| `fg/primary` | `--fg-primary` | Primary text |
| `bg/primary` | `--bg-primary` | Primary surface |
| `bg/brand/primary` | `--bg-brand-primary` | Brand buttons |
| `border/primary` | `--border-primary` | Input borders |
| `spacing/md` | `--spacing-md` | Standard padding |

## NEVER-Do List

```
NEVER: Use raw Tailwind color utilities (use semantic classes instead)
  ✗ className="text-purple-600"
  ✓ className="text-brand-primary" or className="fg-brand-primary"

NEVER: Build custom focus traps or keyboard handling
  ✗ Custom onKeyDown event for Escape/Tab in modals
  ✓ useDialog() + useModal() from @react-aria/overlays

NEVER: Put application components in base/ or vice versa
  ✗ base/UserProfileCard (has business logic)
  ✓ application/UserProfileCard

NEVER: Override dark mode with media queries instead of dark: variant
  ✗ @media (prefers-color-scheme: dark) in component CSS
  ✓ Use Tailwind dark: variant with semantic classes

NEVER: Import react-aria-components without Aria* prefix
  ✗ import { Button } from "react-aria-components"
  ✓ import { Button as AriaButton } from "react-aria-components"

NEVER: Use px values directly — use spacing tokens
  ✗ padding: 16px
  ✓ padding: var(--spacing-md) or className="p-md"
```

## Cross-References

- [accessibility-patterns.md](../accessibility-patterns.md) — WCAG 2.1 AA requirements (React Aria fulfills most)
- [design-token-reference.md](../design-token-reference.md) — Token patterns applicable to CSS variable systems
- [variant-mapping.md](../variant-mapping.md) — Figma variant → CSS class mapping
- [component-reuse-strategy.md](../component-reuse-strategy.md) — REUSE > EXTEND > CREATE in the 5-tier structure
