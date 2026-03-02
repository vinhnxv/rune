# Generic Design System — Component Library Profile

```
profile_schema_version: 1
library: generic
base_primitive: custom (no third-party primitive assumed)
styling: Style Dictionary tokens + CSS Modules or CSS-in-JS
```

This profile applies to custom in-house design systems that do not use shadcn/ui, Untitled UI, or another named library. Use when `discoverDesignSystem()` returns `type: "generic"` or `type: "unknown"`. Patterns here are framework-agnostic and adaptable.

## Design Token System — Style Dictionary

Style Dictionary (Amazon) is the standard tool for managing design tokens in custom systems. Tokens are defined in JSON/YAML and compiled to CSS custom properties, JS constants, or platform-specific formats.

### Token Source Format

```json
// tokens/color.json
{
  "color": {
    "brand": {
      "primary": { "value": "#1a56db", "type": "color" },
      "primary-hover": { "value": "#1e429f", "type": "color" },
      "primary-subtle": { "value": "#ebf5ff", "type": "color" }
    },
    "neutral": {
      "100": { "value": "#f3f4f6", "type": "color" },
      "200": { "value": "#e5e7eb", "type": "color" },
      "500": { "value": "#6b7280", "type": "color" },
      "900": { "value": "#111827", "type": "color" }
    },
    "semantic": {
      "error": { "value": "{color.red.600}", "type": "color" },
      "success": { "value": "{color.green.600}", "type": "color" },
      "warning": { "value": "{color.yellow.500}", "type": "color" }
    }
  }
}
```

```json
// tokens/spacing.json
{
  "spacing": {
    "1": { "value": "4px", "type": "dimension" },
    "2": { "value": "8px", "type": "dimension" },
    "3": { "value": "12px", "type": "dimension" },
    "4": { "value": "16px", "type": "dimension" },
    "6": { "value": "24px", "type": "dimension" },
    "8": { "value": "32px", "type": "dimension" },
    "12": { "value": "48px", "type": "dimension" },
    "16": { "value": "64px", "type": "dimension" }
  }
}
```

### Compiled Output (CSS custom properties)

```css
/* generated/tokens.css */
:root {
  --color-brand-primary: #1a56db;
  --color-brand-primary-hover: #1e429f;
  --color-brand-primary-subtle: #ebf5ff;
  --color-neutral-100: #f3f4f6;
  --color-neutral-900: #111827;
  --color-semantic-error: #dc2626;
  --color-semantic-success: #16a34a;
  --spacing-1: 4px;
  --spacing-2: 8px;
  --spacing-4: 16px;
  --spacing-8: 32px;
}
```

**Rule**: All component code references compiled tokens, never raw values. Design tokens are the single source of truth.

## File Organization — Custom Design System

```
src/
├── design-system/
│   ├── tokens/           ← Style Dictionary source files
│   │   ├── color.json
│   │   ├── spacing.json
│   │   ├── typography.json
│   │   └── radius.json
│   ├── generated/        ← Compiled output (DO NOT edit manually)
│   │   └── tokens.css
│   └── components/       ← Shared primitive components
│       ├── Button/
│       ├── Input/
│       ├── Badge/
│       └── index.ts      ← Barrel export
├── components/           ← Feature/product components that consume design-system
│   ├── UserCard/
│   └── NavigationBar/
└── pages/                ← Page-level compositions
```

## CSS Modules Pattern

CSS Modules provide locally-scoped class names with zero runtime overhead.

```typescript
// Button/Button.tsx
import styles from "./Button.module.css"
import { clsx } from "clsx"

type ButtonVariant = "primary" | "secondary" | "ghost" | "destructive"
type ButtonSize = "sm" | "md" | "lg"

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
  loading?: boolean
}

export function Button({
  variant = "primary",
  size = "md",
  loading = false,
  disabled,
  className,
  children,
  ...props
}: ButtonProps) {
  return (
    <button
      className={clsx(
        styles.button,
        styles[`button--${variant}`],
        styles[`button--${size}`],
        loading && styles["button--loading"],
        className
      )}
      disabled={disabled || loading}
      aria-busy={loading}
      {...props}
    >
      {loading && <span className={styles.spinner} aria-hidden="true" />}
      {children}
    </button>
  )
}
```

```css
/* Button/Button.module.css */
.button {
  display: inline-flex;
  align-items: center;
  gap: var(--spacing-2);
  border-radius: var(--radius-md);
  font-weight: 500;
  cursor: pointer;
  transition: background-color 150ms ease;
}

/* Variants */
.button--primary {
  background-color: var(--color-brand-primary);
  color: #fff;
  border: none;
}
.button--primary:hover:not(:disabled) {
  background-color: var(--color-brand-primary-hover);
}

.button--secondary {
  background-color: transparent;
  color: var(--color-brand-primary);
  border: 1px solid var(--color-brand-primary);
}

.button--ghost {
  background-color: transparent;
  color: var(--color-neutral-900);
  border: none;
}
.button--ghost:hover:not(:disabled) {
  background-color: var(--color-neutral-100);
}

.button--destructive {
  background-color: var(--color-semantic-error);
  color: #fff;
  border: none;
}

/* Sizes */
.button--sm { height: 32px; padding: 0 var(--spacing-3); font-size: 13px; }
.button--md { height: 40px; padding: 0 var(--spacing-4); font-size: 14px; }
.button--lg { height: 48px; padding: 0 var(--spacing-6); font-size: 16px; }

/* States */
.button:disabled { opacity: 0.5; cursor: not-allowed; }
.button--loading { cursor: wait; }
```

## CSS-in-JS Pattern (Styled Components / Emotion)

For CSS-in-JS based systems, use the token layer via `theme` object:

```typescript
// theme.ts — generated from Style Dictionary or manually maintained
export const theme = {
  colors: {
    brand: {
      primary: "var(--color-brand-primary)",
      primaryHover: "var(--color-brand-primary-hover)",
    },
    semantic: {
      error: "var(--color-semantic-error)",
      success: "var(--color-semantic-success)",
    },
  },
  spacing: {
    1: "var(--spacing-1)",
    4: "var(--spacing-4)",
    6: "var(--spacing-6)",
  },
}

// Styled component with theme
import styled, { css } from "styled-components"

const buttonVariants = {
  primary: css`
    background-color: ${({ theme }) => theme.colors.brand.primary};
    color: white;
    &:hover:not(:disabled) {
      background-color: ${({ theme }) => theme.colors.brand.primaryHover};
    }
  `,
  secondary: css`
    background-color: transparent;
    color: ${({ theme }) => theme.colors.brand.primary};
    border: 1px solid ${({ theme }) => theme.colors.brand.primary};
  `,
}

const StyledButton = styled.button<{ variant: ButtonVariant; size: ButtonSize }>`
  display: inline-flex;
  align-items: center;
  cursor: pointer;
  ${({ variant }) => buttonVariants[variant]}
  ${({ size }) => buttonSizes[size]}
`
```

## Generic Variant Pattern

When the project doesn't use CVA or a named variant library, implement variants via an explicit map:

```typescript
// Variant class map — explicit mapping preferred over dynamic class construction
const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: "btn-primary",
  secondary: "btn-secondary",
  ghost: "btn-ghost",
  destructive: "btn-destructive",
}

const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: "btn-sm",
  md: "btn-md",
  lg: "btn-lg",
}

// Usage
function Button({ variant = "primary", size = "md", className, ...props }) {
  return (
    <button
      className={[
        "btn",
        VARIANT_CLASSES[variant],
        SIZE_CLASSES[size],
        className,
      ].filter(Boolean).join(" ")}
      {...props}
    />
  )
}
```

**Rule**: Never use string interpolation for class construction (`btn-${variant}`) — TypeScript cannot verify the interpolated string is a valid class. Use an explicit map.

## Accessibility Primitives

Without Radix UI or React Aria, implement accessibility patterns manually:

```typescript
// Focus trap for modals
import { createFocusTrap } from "focus-trap"

function Modal({ isOpen, onClose, children }) {
  const modalRef = useRef(null)
  const trapRef = useRef(null)

  useEffect(() => {
    if (isOpen && modalRef.current) {
      trapRef.current = createFocusTrap(modalRef.current, {
        escapeDeactivates: true,
        onDeactivate: onClose,
      })
      trapRef.current.activate()
    }
    return () => trapRef.current?.deactivate()
  }, [isOpen, onClose])

  if (!isOpen) return null

  return (
    <div role="dialog" aria-modal="true" aria-label="Dialog" ref={modalRef}>
      {children}
    </div>
  )
}
```

**Minimum accessibility requirements for custom components:**

| Component Type | Required ARIA | Required Keyboard |
|---------------|---------------|-------------------|
| Button | `type` attribute | Space/Enter to activate |
| Modal | `role="dialog"`, `aria-modal="true"`, focus trap | Escape to close |
| Dropdown | `role="listbox"`, `aria-expanded` | Arrow keys to navigate |
| Tab panel | `role="tablist"`, `role="tab"`, `aria-selected` | Arrow keys between tabs |
| Tooltip | `role="tooltip"`, `aria-describedby` | Keyboard accessible trigger |
| Checkbox | Native `<input type="checkbox">` | Space to toggle |

## Dark Mode Implementation

Use `prefers-color-scheme` media query plus a manual override attribute:

```css
/* Default: light */
:root {
  --color-background: #ffffff;
  --color-foreground: #111827;
}

/* System dark mode preference */
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --color-background: #111827;
    --color-foreground: #f9fafb;
  }
}

/* Manual dark mode override */
[data-theme="dark"] {
  --color-background: #111827;
  --color-foreground: #f9fafb;
}
```

## Component Discovery Strategy

When working with an unfamiliar custom design system, use this discovery order:

```
1. Glob("src/design-system/components/*/index.ts") — find component barrel exports
2. Glob("src/components/ui/**/*.tsx") — alternative flat structure
3. Grep("export.*function.*|export.*const.*=.*React.forwardRef", "src/") — find exports
4. Read("package.json") — check if a component library package is used
5. Grep("var(--", "src/") — detect CSS custom property usage (token system exists)
6. Glob("**/tokens/**/*.json", "**/style-dictionary/**") — find token source files
```

## NEVER-Do List

```
NEVER: Use arbitrary values not in the token system
  ✗ padding: 13px (not on the scale)
  ✓ padding: var(--spacing-3)  (12px — nearest token)

NEVER: Build variant maps dynamically with string interpolation
  ✗ className={`btn-${variant}`}  (type-unsafe, hard to grep)
  ✓ VARIANT_CLASSES[variant]  (type-safe, explicit map)

NEVER: Implement focus traps or ARIA roles without testing with a screen reader
  ✗ Rolling a custom dialog without accessibility audit
  ✓ Use focus-trap library + test with VoiceOver/NVDA

NEVER: Hardcode raw hex values in component code
  ✗ color: "#1a56db"
  ✓ color: var(--color-brand-primary)

NEVER: Generate CSS files at runtime (CSS-in-JS without static extraction)
  ✗ Emotion without static extraction in production
  ✓ CSS Modules (zero runtime) or Emotion with Babel plugin extraction

NEVER: Create a new component without searching the design-system barrel first
  ✗ Custom <Spinner> when design-system/components/Spinner exists
  ✓ import { Spinner } from "@/design-system/components"
```

## Cross-References

- [design-system-rules.md](../design-system-rules.md) — Framework-agnostic token and spacing rules
- [design-token-reference.md](../design-token-reference.md) — Token taxonomy and naming conventions
- [component-reuse-strategy.md](../component-reuse-strategy.md) — REUSE > EXTEND > CREATE decision tree
- [accessibility-patterns.md](../accessibility-patterns.md) — Manual ARIA implementation when no primitives available
- [variant-mapping.md](../variant-mapping.md) — Mapping Figma variants to component props
