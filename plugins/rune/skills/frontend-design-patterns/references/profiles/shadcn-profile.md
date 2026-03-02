# shadcn/ui — Component Library Profile

```
profile_schema_version: 1
library: shadcn/ui
base_primitive: Radix UI
styling: Tailwind CSS + CVA
```

shadcn/ui is a collection of copy-paste React components built on Radix UI primitives with Tailwind CSS styling and CVA (class-variance-authority) for variant management. Components are owned by the project — not imported from a package — so they live directly in the codebase and can be freely modified.

## File Organization

```
src/
└── components/
    └── ui/            ← shadcn/ui components live here
        ├── button.tsx
        ├── dialog.tsx
        ├── input.tsx
        ├── badge.tsx
        └── ...
```

**Rule**: All shadcn/ui components belong in `src/components/ui/`. Feature-specific compositions go in `src/components/{feature}/`.

## Core Pattern: Component Structure

Every shadcn/ui component follows this skeleton:

```typescript
import * as React from "react"
import { cn } from "@/lib/utils"

// Optional: CVA for variant management
import { cva, type VariantProps } from "class-variance-authority"

// Variant definitions via CVA
const buttonVariants = cva(
  // Base classes (always applied)
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground shadow hover:bg-primary/90",
        destructive: "bg-destructive text-destructive-foreground shadow-sm hover:bg-destructive/90",
        outline: "border border-input bg-background shadow-sm hover:bg-accent hover:text-accent-foreground",
        secondary: "bg-secondary text-secondary-foreground shadow-sm hover:bg-secondary/80",
        ghost: "hover:bg-accent hover:text-accent-foreground",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default: "h-9 px-4 py-2",
        sm: "h-8 rounded-md px-3 text-xs",
        lg: "h-10 rounded-md px-8",
        icon: "h-9 w-9",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

// Props extend HTML element props + CVA variants
export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean  // Slot/polymorphism flag
}

// forwardRef for ref forwarding
const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"
    return (
      <Comp
        className={cn(buttonVariants({ variant, size, className }))}
        ref={ref}
        {...props}
      />
    )
  }
)
Button.displayName = "Button"

export { Button, buttonVariants }
```

## cn() — Class Merge Utility

`cn()` merges Tailwind classes safely, resolving conflicts (e.g., `p-4` vs `p-2`).

```typescript
// Location: src/lib/utils.ts
import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
```

**Usage rules:**

| Pattern | Correct | Incorrect |
|---------|---------|-----------|
| Merge base + custom | `cn(buttonVariants({ variant }), className)` | `buttonVariants({ variant }) + " " + className` |
| Conditional classes | `cn("base", isActive && "active", { disabled: isDisabled })` | Template literals with ternaries |
| Override Tailwind | `cn("p-4", overridePadding)` — twMerge resolves conflicts | String concatenation (creates duplicates) |

**Rule**: Always pass `className` prop through `cn()` to allow consumer overrides.

## CVA — Variant Definitions

CVA produces a function that generates class strings based on variant props.

```typescript
const badgeVariants = cva(
  // Base classes
  "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold transition-colors focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2",
  {
    variants: {
      variant: {
        default: "border-transparent bg-primary text-primary-foreground hover:bg-primary/80",
        secondary: "border-transparent bg-secondary text-secondary-foreground hover:bg-secondary/80",
        destructive: "border-transparent bg-destructive text-destructive-foreground hover:bg-destructive/90",
        outline: "text-foreground",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
)

// Compound variants: style depends on combination of props
const cardVariants = cva("rounded-lg border", {
  variants: {
    variant: { elevated: "shadow-md", flat: "shadow-none" },
    size: { sm: "p-3", md: "p-6", lg: "p-8" },
  },
  compoundVariants: [
    // elevated + lg gets extra shadow
    { variant: "elevated", size: "lg", class: "shadow-xl" },
  ],
  defaultVariants: {
    variant: "flat",
    size: "md",
  },
})
```

## React.ComponentPropsWithoutRef Pattern

Use `React.ComponentPropsWithoutRef<T>` when you don't forward a ref (simpler than forwardRef when ref isn't needed):

```typescript
export interface CardProps
  extends React.ComponentPropsWithoutRef<"div"> {
  // Additional custom props
  header?: React.ReactNode
}

function Card({ className, header, children, ...props }: CardProps) {
  return (
    <div className={cn("rounded-lg border bg-card text-card-foreground shadow", className)} {...props}>
      {header && <div className="flex flex-col space-y-1.5 p-6">{header}</div>}
      {children}
    </div>
  )
}
```

**Rule**: Use `forwardRef` when consumers might need the DOM ref (interactive elements, form fields). Use `ComponentPropsWithoutRef` for purely presentational wrappers.

## Slot / asChild Polymorphism

The `Slot` component from `@radix-ui/react-slot` merges props onto its child element, enabling polymorphic components without prop drilling.

```typescript
import { Slot } from "@radix-ui/react-slot"

// asChild=false (default): renders as <button>
<Button>Click me</Button>
// → <button class="...">Click me</button>

// asChild=true: merges Button props onto child element
<Button asChild>
  <a href="/dashboard">Dashboard</a>
</Button>
// → <a href="/dashboard" class="...">Dashboard</a>
```

**When to use asChild:**
- Render a button as a router link (`<Link asChild>`)
- Apply button styles to a custom element
- Avoid wrapping elements that break HTML semantics (no `<button>` inside `<button>`)

## Compound Component Pattern

For complex UI with multiple related parts, use compound components with a shared context:

```typescript
// Dialog example (simplified shadcn/ui pattern)
import * as DialogPrimitive from "@radix-ui/react-dialog"
import { cn } from "@/lib/utils"

// Direct re-export of Radix primitives
const Dialog = DialogPrimitive.Root
const DialogTrigger = DialogPrimitive.Trigger
const DialogPortal = DialogPrimitive.Portal
const DialogClose = DialogPrimitive.Close

// Wrapped with custom styles
const DialogOverlay = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Overlay>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Overlay
    ref={ref}
    className={cn(
      "fixed inset-0 z-50 bg-black/80 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0",
      className
    )}
    {...props}
  />
))
DialogOverlay.displayName = DialogPrimitive.Overlay.displayName

const DialogContent = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Content>
>(({ className, children, ...props }, ref) => (
  <DialogPortal>
    <DialogOverlay />
    <DialogPrimitive.Content
      ref={ref}
      className={cn(
        "fixed left-[50%] top-[50%] z-50 grid w-full max-w-lg translate-x-[-50%] translate-y-[-50%] gap-4 border bg-background p-6 shadow-lg duration-200 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[state=closed]:slide-out-to-left-1/2 data-[state=closed]:slide-out-to-top-[48%] data-[state=open]:slide-in-from-left-1/2 data-[state=open]:slide-in-from-top-[48%] sm:rounded-lg",
        className
      )}
      {...props}
    >
      {children}
    </DialogPrimitive.Content>
  </DialogPortal>
))

// Consumer usage
<Dialog>
  <DialogTrigger asChild>
    <Button>Open Dialog</Button>
  </DialogTrigger>
  <DialogContent>
    <DialogHeader>
      <DialogTitle>Are you sure?</DialogTitle>
      <DialogDescription>This action cannot be undone.</DialogDescription>
    </DialogHeader>
    <DialogFooter>
      <DialogClose asChild>
        <Button variant="outline">Cancel</Button>
      </DialogClose>
      <Button onClick={handleConfirm}>Confirm</Button>
    </DialogFooter>
  </DialogContent>
</Dialog>
```

## Import Conventions

```typescript
// shadcn/ui components — path alias
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Badge, badgeVariants } from "@/components/ui/badge"

// Utilities
import { cn } from "@/lib/utils"

// When extending: import CVA types for re-export
import { type VariantProps } from "class-variance-authority"
```

## Dark Mode Implementation

shadcn/ui uses CSS custom properties that switch values based on the `.dark` class on `<html>`:

```css
/* globals.css */
:root {
  --background: 0 0% 100%;
  --foreground: 222.2 84% 4.9%;
  --primary: 222.2 47.4% 11.2%;
  --primary-foreground: 210 40% 98%;
  /* ... */
}

.dark {
  --background: 222.2 84% 4.9%;
  --foreground: 210 40% 98%;
  --primary: 210 40% 98%;
  --primary-foreground: 222.2 47.4% 11.2%;
  /* ... */
}
```

**Rule**: Never hardcode light/dark colors. All color references must go through `var(--token)` or Tailwind's semantic classes (`bg-background`, `text-foreground`, `bg-primary`).

## NEVER-Do List

```
NEVER: String concatenation for class names
  ✗ `${buttonVariants({ variant })} ${className}`
  ✓ cn(buttonVariants({ variant }), className)

NEVER: Inline styles with arbitrary values
  ✗ style={{ padding: '17px', color: '#3b82f6' }}
  ✓ className="p-4 text-primary"

NEVER: Build components from scratch when a shadcn/ui component exists
  ✗ Custom modal with useState + portal + backdrop
  ✓ Import and extend <Dialog> from "@/components/ui/dialog"

NEVER: Hardcode color values
  ✗ className="text-blue-600 dark:text-blue-400"
  ✓ className="text-primary" (resolved by CSS variable)

NEVER: Modify Radix primitive internals
  ✗ Patching @radix-ui/react-dialog source
  ✓ Wrap the DialogContent with your styles

NEVER: Use non-semantic variant values
  ✗ variant="blue" | variant="red"
  ✓ variant="primary" | variant="destructive"
```

## Cross-References

- [variant-mapping.md](../variant-mapping.md) — Figma variants → CVA variant definitions
- [component-reuse-strategy.md](../component-reuse-strategy.md) — When to REUSE vs EXTEND shadcn components
- [design-system-rules.md](../design-system-rules.md) — Token constraints applied through Tailwind
- [accessibility-patterns.md](../accessibility-patterns.md) — WCAG compliance via Radix primitives
