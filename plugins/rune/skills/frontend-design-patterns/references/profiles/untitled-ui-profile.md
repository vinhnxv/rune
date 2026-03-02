# Untitled UI — Component Library Profile

```
profile_schema_version: 1
library: Untitled UI
base_primitive: React Aria (Adobe)
styling: CSS custom properties + CSS Modules / Tailwind
```

Untitled UI is a large-scale Figma design system + React component library built on React Aria (Adobe's accessibility primitives). It provides production-ready components with comprehensive accessibility baked in, CSS variable-driven theming, and a 3-tier directory structure for organizing components by use case.

## File Organization — 3-Tier Directory

```
src/
└── components/
    ├── base/            ← Tier 1: Atoms and primitives (Button, Input, Badge, Avatar)
    │   ├── Button/
    │   │   ├── Button.tsx
    │   │   ├── Button.module.css
    │   │   └── index.ts
    │   └── ...
    ├── application/     ← Tier 2: Molecules and organisms for app UI (Modal, DataTable, Sidebar)
    │   ├── Modal/
    │   ├── DataTable/
    │   └── ...
    └── marketing/       ← Tier 3: Page sections for landing/marketing pages (Hero, PricingCard, Testimonial)
        ├── Hero/
        ├── PricingCard/
        └── ...
```

**Tier rules:**
- `base/` components have zero business logic — pure UI primitives
- `application/` components may read from stores or context but do not fetch data
- `marketing/` components are typically static or CMS-driven; avoid shared state coupling

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

/* Dark mode token override */
[data-theme="dark"] {
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

## Variant Patterns via CSS Classes

Untitled UI uses CSS class-based variants instead of CVA (the library predates CVA adoption):

```css
/* Button.module.css */
.btn {
  display: inline-flex;
  align-items: center;
  gap: var(--spacing-xs);
  border-radius: var(--radius-md);
  font-weight: 600;
  cursor: pointer;
  transition: background-color 150ms, border-color 150ms, box-shadow 150ms;
}

/* Variant: primary */
.btn--primary {
  background-color: var(--bg-brand-primary);
  color: var(--fg-white);
  border: 1px solid var(--bg-brand-primary);
}
.btn--primary:hover {
  background-color: #6941c6;
  border-color: #6941c6;
}

/* Variant: secondary-color */
.btn--secondary-color {
  background-color: var(--bg-primary);
  color: var(--fg-brand-primary);
  border: 1px solid var(--border-primary);
}

/* Variant: destructive */
.btn--destructive {
  background-color: #D92D20;
  color: var(--fg-white);
}

/* Size: sm */
.btn--sm {
  height: 36px;
  padding: 0 var(--spacing-sm);
  font-size: 14px;
}

/* Size: md */
.btn--md {
  height: 40px;
  padding: 0 var(--spacing-md);
  font-size: 14px;
}

/* Size: lg */
.btn--lg {
  height: 44px;
  padding: 0 var(--spacing-lg);
  font-size: 16px;
}
```

```typescript
// Component usage
function Button({ variant = "primary", size = "md", className, children, ...props }) {
  return (
    <button
      className={cn(
        styles.btn,
        styles[`btn--${variant}`],
        styles[`btn--${size}`],
        className
      )}
      {...props}
    >
      {children}
    </button>
  )
}
```

## Import Conventions

```typescript
// Base components
import { Button } from "@/components/base/Button"
import { Input } from "@/components/base/Input"
import { Badge } from "@/components/base/Badge"

// Application components
import { Modal } from "@/components/application/Modal"
import { DataTable } from "@/components/application/DataTable"

// Marketing components
import { Hero } from "@/components/marketing/Hero"

// Styles (CSS Modules)
import styles from "./Button.module.css"

// React Aria
import { useButton } from "@react-aria/button"
import { useDialog } from "@react-aria/dialog"
```

## Dark Mode Implementation

Toggle `data-theme="dark"` on the `<html>` element. CSS variables switch automatically:

```typescript
// Theme toggle
function toggleTheme() {
  const html = document.documentElement
  const current = html.getAttribute("data-theme")
  html.setAttribute("data-theme", current === "dark" ? "light" : "dark")
}

// CSS: color-scheme for native OS integration
:root { color-scheme: light; }
[data-theme="dark"] { color-scheme: dark; }
```

**Rule**: Never use `className="dark:text-white"` Tailwind dark variants — Untitled UI uses `data-theme` attribute, not `.dark` class prefix.

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
NEVER: Use Tailwind color utilities directly (use CSS variables instead)
  ✗ className="text-purple-600"
  ✓ style={{ color: "var(--fg-brand-primary)" }} or className={styles.brandText}

NEVER: Build custom focus traps or keyboard handling
  ✗ Custom onKeyDown event for Escape/Tab in modals
  ✓ useDialog() + useModal() from @react-aria/overlays

NEVER: Put application components in base/ or vice versa
  ✗ base/UserProfileCard (has business logic)
  ✓ application/UserProfileCard

NEVER: Override dark mode with media queries instead of data-theme
  ✗ @media (prefers-color-scheme: dark) in component CSS
  ✓ [data-theme="dark"] .component { ... }

NEVER: Use px values directly — use spacing tokens
  ✗ padding: 16px
  ✓ padding: var(--spacing-md)
```

## Cross-References

- [accessibility-patterns.md](../accessibility-patterns.md) — WCAG 2.1 AA requirements (React Aria fulfills most)
- [design-token-reference.md](../design-token-reference.md) — Token patterns applicable to CSS variable systems
- [variant-mapping.md](../variant-mapping.md) — Figma variant → CSS class mapping
- [component-reuse-strategy.md](../component-reuse-strategy.md) — REUSE > EXTEND > CREATE in the 3-tier structure
