# Prototype Code Conventions

## General Rules

- All generated `.tsx` files MUST include the header comment:
  ```typescript
  // PROTOTYPE — adapt before production use
  ```
- Import real library components (from `library-match.tsx`), NOT hand-rolled HTML
- Props interface exported for downstream consumers
- No inline styles — Tailwind only
- Responsive: mobile-first with `sm:` / `md:` / `lg:` breakpoints

## Language & Framework

- **React** with **TypeScript** — explicit type annotations on all props and return types
- **Tailwind CSS v4** for styling — semantic colors (`text-foreground`, `bg-background`), spacing scale (`gap-4`, `p-6`)
- Functional components only (no class components)
- Named exports (not default exports)

## File Naming

| Type | Convention | Example |
|------|-----------|---------|
| Component directory | kebab-case | `user-profile/` |
| Component file | `prototype.tsx` | `user-profile/prototype.tsx` |
| Story file | `prototype.stories.tsx` | `user-profile/prototype.stories.tsx` |
| Figma reference | `figma-reference.tsx` | `user-profile/figma-reference.tsx` |
| Library match | `library-match.tsx` | `user-profile/library-match.tsx` |
| Mapping metadata | `mapping.json` | `user-profile/mapping.json` |

## Component Structure

```typescript
// PROTOTYPE — adapt before production use

import { Button } from '@untitledui/button'
import { Card, CardHeader, CardContent } from '@untitledui/card'

export interface UserProfileProps {
  name: string
  email: string
  avatarUrl?: string
  isLoading?: boolean
  error?: string
  onEdit?: () => void
}

export function UserProfile({
  name,
  email,
  avatarUrl,
  isLoading = false,
  error,
  onEdit,
}: UserProfileProps) {
  if (isLoading) {
    return <div className="animate-pulse rounded-lg bg-muted h-48 w-full" />
  }

  if (error) {
    return <div className="text-destructive p-4">{error}</div>
  }

  return (
    <Card className="w-full max-w-sm">
      <CardHeader className="flex items-center gap-3">
        {avatarUrl && (
          <img
            src={avatarUrl}
            alt={name}
            className="h-12 w-12 rounded-full object-cover"
          />
        )}
        <div>
          <h3 className="text-lg font-semibold text-foreground">{name}</h3>
          <p className="text-sm text-muted-foreground">{email}</p>
        </div>
      </CardHeader>
      <CardContent>
        <Button variant="outline" size="sm" onClick={onEdit}>
          Edit Profile
        </Button>
      </CardContent>
    </Card>
  )
}
```

## Storybook Stories (CSF3 Format)

All prototypes MUST have a companion `.stories.tsx` file using Component Story Format 3:

```typescript
import type { Meta, StoryObj } from '@storybook/react'
import { UserProfile } from './prototype'

const meta = {
  title: 'Prototypes/UserProfile',
  component: UserProfile,
  tags: ['autodocs'],
} satisfies Meta<typeof UserProfile>

export default meta
type Story = StoryObj<typeof meta>

export const Default: Story = {
  args: {
    name: 'Jane Doe',
    email: 'jane@example.com',
    avatarUrl: '/placeholder-avatar.png',
  },
}

export const Loading: Story = {
  args: {
    ...Default.args,
    isLoading: true,
  },
}

export const Error: Story = {
  args: {
    ...Default.args,
    error: 'Failed to load profile',
  },
}

export const Empty: Story = {
  args: {
    name: '',
    email: '',
  },
}

export const Disabled: Story = {
  args: {
    ...Default.args,
    onEdit: undefined,
  },
}
```

### Required Stories

Every prototype MUST include these baseline stories:

| Story | Purpose | Args Pattern |
|-------|---------|-------------|
| `Default` | Happy path with realistic data | All required props + common optionals |
| `Loading` | Loading/skeleton state | `isLoading: true` |
| `Error` | Error state display | `error: 'descriptive message'` |
| `Empty` | Empty/no-data state | Empty arrays, blank strings |
| `Disabled` | Disabled interaction state | `disabled: true` or handlers removed |

### Full-Page Composition Story

When >= 3 components are extracted from a Figma screen, a **full-page composition** component MUST be generated that imports and composes all sub-components into a single screen layout. This component:

- Uses `layout: "fullscreen"` in its story metadata
- Imports all sibling prototype components via relative paths (`../ComponentName/prototype`)
- Preserves the exact layout hierarchy from the Figma design (flex direction, gaps, padding)
- Is the **default story opened in the browser** (Phase 4.5 auto-detects it)
- Has `Primary` as the default story showing the full screen with all sub-components

```typescript
// Full-page composition pattern
import type { Meta, StoryObj } from '@storybook/react'
import FullPageComponent from './prototype'

const meta = {
  title: 'Prototypes/FullPageComponent',
  component: FullPageComponent,
  parameters: {
    layout: 'fullscreen',  // REQUIRED for full-page compositions
    backgrounds: { default: 'page', values: [{ name: 'page', value: '#f3f5f9' }] },
  },
  tags: ['autodocs'],
} satisfies Meta<typeof FullPageComponent>

export default meta
type Story = StoryObj<typeof meta>

// Primary = full screen with all defaults from Figma
export const Primary: Story = {}

// Additional variants with different prop combinations
export const SimplifiedLayout: Story = { args: { showRightColumn: false, ... } }
```

### Phase 3.5 Additional Stories (UX Flow Mapping)

When UX flow mapping runs, these additional stories are generated:

**Data state stories:**
- `WithData` — populated with realistic mock data
- `EmptyState` — zero items, empty collections
- `LoadingState` — skeleton/spinner during fetch
- `ErrorState` — API failure with retry option

**Interaction stories:**
- `SubmitLoading` — form submission in progress
- `ValidationErrors` — form with validation errors shown
- `ModalOpen` — modal/dialog in open state

## Tailwind Conventions

### Colors
Use semantic color tokens, not raw values:
- `text-foreground` / `text-muted-foreground` (not `text-gray-900`)
- `bg-background` / `bg-muted` (not `bg-white`)
- `border-border` (not `border-gray-200`)
- `text-destructive` for errors
- `text-primary` for actions

### Spacing
Use the spacing scale consistently:
- `gap-2` / `gap-3` / `gap-4` for flex/grid gaps
- `p-4` / `p-6` for padding
- `space-y-2` / `space-y-4` for vertical rhythm

### Responsive
Mobile-first with breakpoint modifiers:
```typescript
<div className="flex flex-col gap-4 sm:flex-row sm:items-center md:gap-6 lg:max-w-4xl">
```

Breakpoint usage:
- Default (no prefix): mobile (< 640px)
- `sm:` — small screens (>= 640px)
- `md:` — medium screens (>= 768px)
- `lg:` — large screens (>= 1024px)

## Import Rules

1. Import from library packages detected in Phase 2 (e.g., `@untitledui/*`)
2. Never import from `figma-reference.tsx` — it is a reference only
3. Group imports: library components first, then icons, then local utilities
4. Use the exact component API from `library-match.tsx` — do not invent props
5. Import style is determined by the adapter (see §Library-Specific Import Patterns below)

## Library-Specific Import Patterns

Import paths and component composition vary by adapter. The `selectAdapter()` function
(see [library-adapters.md](../../design-system-discovery/references/library-adapters.md))
determines which pattern to use based on `designContext.synthesis_strategy`.

### UntitledUI (`importStyle: "relative"`)

```typescript
// Components: relative-path package imports
import { Button } from '@untitledui/button'
import { Card, CardHeader, CardContent } from '@untitledui/card'
import { Input } from '@untitledui/input'

// Icons: named exports from @untitledui/icons
import { ArrowLeft, ChevronDown, Search } from '@untitledui/icons'
```

**Composability**: flat (props-based). Components use prop variants, not subcomponent nesting.
- Variants via `color` prop: `<Button color="primary">` / `<Button color="error">`
- Sizes via `size` prop: `<Input size="md">` / `<Input size="lg">`
- States via boolean props: `disabled={true}`, `loading={true}`

### shadcn/ui (`importStyle: "barrel"`)

```typescript
// Components: barrel imports from @/components/ui/
import { Button } from '@/components/ui/button'
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card'
import { Input } from '@/components/ui/input'

// Icons: named exports from lucide-react
import { ArrowLeft, ChevronDown, Search } from 'lucide-react'
```

**Composability**: compound (subcomponents). Components use nested composition.
- Variants via `variant` prop: `<Button variant="default">` / `<Button variant="destructive">`
- Sizes via `size` prop: `<Button size="default">` / `<Button size="lg">`
- States via boolean props or data attributes: `disabled`, `data-state="open"`

### Tailwind Fallback (`importStyle: "none"`)

```typescript
// No library imports — raw HTML elements with Tailwind classes
// Icons: inline SVG extracted from Figma reference
```

**Composability**: inline (className-based). No external component library.
- All styling via Tailwind utility classes
- Use semantic color tokens (`text-foreground`, `bg-background`) per §Tailwind Conventions

## Adapter-Aware Synthesis Rules

When `synthesis_strategy` is `"library"`:
1. **Extract Semantic IR** from `figma-reference.tsx` using `extractSemanticIR()` — produces `SemanticComponent[]` with type, intent, size, state, icons
2. **Map IR to adapter** — look up `adapter.types[irComp.type]` for the type mapping
3. **Resolve variants** — `irComp.intent` maps to `typeMapping.variants[intent]` (e.g., `"destructive"` → `"error"` for UntitledUI, `"destructive"` for shadcn)
4. **Resolve icons** — use `resolveIconName()` fallback chain: adapter icon map → Figma name sanitize → generic fallback
5. **Resolve state** — `irComp.state` maps to `typeMapping.stateProps[state]` (e.g., `"disabled"` → `disabled={true}`)
6. **Preserve layout intent** — flex direction, gaps, and padding from `figma-reference.tsx` are preserved in the prototype wrapper

When `synthesis_strategy` is `"hybrid"`:
1. Use Tailwind CSS for all styling (no library component imports)
2. Apply library naming conventions for className composition (e.g., shadcn-style semantic tokens)
3. Icons remain inline SVG from Figma reference

When `synthesis_strategy` is `"tailwind"`:
1. Use raw `figma-reference.tsx` output with Tailwind styling as-is
2. No library translation — preserve Figma's generated className structure
3. Apply §Tailwind Conventions for semantic color tokens and spacing
