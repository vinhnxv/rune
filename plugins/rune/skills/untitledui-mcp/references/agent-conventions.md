# UntitledUI Code Conventions

Adapted from the official UntitledUI AGENT.md. These conventions are injected into
Rune worker prompts when UntitledUI is the active UI builder.

## Architecture Foundation

- **React 19.1.1** with TypeScript
- **Tailwind CSS v4.1** for styling
- **React Aria Components** as the accessibility and behavior foundation
- All components follow the **compound component pattern** (e.g., `Select.Item`, `Select.ComboBox`)

## Development Commands

```bash
npm run dev        # Start Vite dev server (http://localhost:5173)
npm run build      # Production build
```

## Authentication & Access Tiers

UntitledUI MCP supports 3 authentication modes. The access tier determines which
components and templates are available to agents.

### `UNTITLEDUI_ACCESS_TOKEN` Environment Variable

This is the UntitledUI PRO API key. When set, agents gain access to all PRO
components, page templates, and shared assets. The value is the same API key
used in `Authorization: Bearer <key>` headers and the per-call `key` parameter.

```bash
# Set in shell profile or .env
export UNTITLEDUI_ACCESS_TOKEN="your-api-key-here"
```

**MCP server setup**:
```bash
# OAuth (recommended — auto-handles login flow, no env var needed):
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp

# API key (explicit — passes UNTITLEDUI_ACCESS_TOKEN as Bearer token):
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp \
  --header "Authorization: Bearer $UNTITLEDUI_ACCESS_TOKEN"
```

### Access Tier Detection

Agents determine the access tier at runtime based on MCP tool response:

| Tier | Detection | Available |
|------|-----------|-----------|
| **PRO** | `UNTITLEDUI_ACCESS_TOKEN` set OR OAuth authenticated | All 6 tools, all categories, page templates |
| **Free** | MCP server configured, no auth | `search_components`, `list_components`, `get_component` (base only), `get_component_bundle` (free only) |
| **None** | No `untitledui` MCP server | Fall back to Tailwind + conventions from this file |

### Agent Behavior by Tier

```
PRO tier:
  1. search_components("query") → match found
  2. get_component("Name") → full source code
  3. get_page_templates() → browse page layouts (PRO exclusive)
  4. Customize with project conventions

Free tier:
  1. search_components("query") → match found
  2. get_component("Name") → success (base) OR auth error (PRO-only)
  3. Auth error → build from scratch with Tailwind + conventions below
  4. NEVER retry with fabricated keys

None tier (no MCP):
  1. Skip MCP tool calls entirely
  2. Build components from scratch using Tailwind + conventions below
  3. Follow import patterns, semantic colors, and kebab-case naming
```

### Per-Call `key` Parameter

All UntitledUI MCP tools accept an optional `key` parameter as an alternative
to OAuth. When `UNTITLEDUI_ACCESS_TOKEN` is available, agents MAY pass it:

```typescript
// Agent tool call with explicit key
search_components({ query: "sidebar navigation", key: process.env.UNTITLEDUI_ACCESS_TOKEN })
get_component({ name: "SidebarNavigation", key: process.env.UNTITLEDUI_ACCESS_TOKEN })
```

**Important**: Agents MUST NOT hardcode, fabricate, or guess API keys. If no token
is available and a PRO component is needed, fall back to conventions-guided Tailwind.

## Import Conventions

### React Aria — CRITICAL: `Aria*` Prefix Required

All imports from `react-aria-components` MUST be prefixed with `Aria*`:

```typescript
// CORRECT
import { Button as AriaButton, TextField as AriaTextField } from "react-aria-components";

// WRONG — causes naming conflicts with UntitledUI components
import { Button, TextField } from "react-aria-components";
```

### Component Imports

```typescript
// Base components
import { Button } from "@/components/base/buttons/button";
import { Input } from "@/components/base/input/input";
import { Select } from "@/components/base/select/select";
import { Checkbox } from "@/components/base/checkbox/checkbox";
import { Badge, BadgeWithDot, BadgeWithIcon } from "@/components/base/badges/badges";
import { Avatar } from "@/components/base/avatar/avatar";
import { FeaturedIcon } from "@/components/foundations/featured-icon/featured-icon";
```

### Icon Imports

```typescript
// Free icons (1,100+ line-style)
import { Home01, Settings01, ChevronDown } from "@untitledui/icons";

// File icons
import { FileTypeDoc } from "@untitledui/file-icons";

// PRO icons (4,600+ in 4 styles) — requires PRO subscription
import { Home01 } from "@untitledui-pro/icons";           // Line (default)
import { Home01 } from "@untitledui-pro/icons/duocolor";   // Duocolor
import { Home01 } from "@untitledui-pro/icons/duotone";    // Duotone
import { Home01 } from "@untitledui-pro/icons/solid";      // Solid
```

## File Naming — Kebab-Case Only

ALL files must be named in kebab-case:

```
date-picker.tsx       # correct
user-profile.tsx      # correct
api-client.ts         # correct

DatePicker.tsx        # WRONG
userProfile.tsx       # WRONG
apiClient.ts          # WRONG
```

Applies to: `.tsx`, `.jsx`, `.ts`, `.js`, `.css`, `.test.ts`, `.spec.tsx`

## Project Structure

```
src/
├── components/
│   ├── base/              # Core UI: Button, Input, Select, Checkbox, Badge, etc.
│   ├── application/       # Complex: DatePicker, Modal, Table, Tabs, Pagination
│   ├── foundations/        # Design tokens, FeaturedIcon, icons, logos
│   ├── marketing/          # Landing pages, CTAs, testimonials, pricing
│   └── shared-assets/      # Login, signup, 404 pages (PRO)
├── hooks/                  # Custom React hooks
├── pages/                  # Route components
├── providers/              # React context providers
├── styles/                 # Global styles and theme
├── types/                  # TypeScript type definitions
└── utils/                  # Utilities (cx, sortCx, isReactComponent)
```

## Styling Rules

### Semantic Colors ONLY — Never Raw Tailwind

```
text-primary           # CORRECT — semantic
text-gray-900          # WRONG — raw Tailwind

bg-brand-solid         # CORRECT — semantic
bg-blue-700            # WRONG — raw Tailwind

border-secondary       # CORRECT — semantic
border-gray-200        # WRONG — raw Tailwind

fg-brand-primary       # CORRECT — semantic foreground
text-purple-600        # WRONG — raw Tailwind
```

### Key Semantic Color Classes

**Text**: `text-primary`, `text-secondary`, `text-tertiary`, `text-quaternary`, `text-disabled`, `text-placeholder`, `text-brand-primary`, `text-brand-secondary`, `text-error-primary`, `text-warning-primary`, `text-success-primary`

**Background**: `bg-primary`, `bg-secondary`, `bg-tertiary`, `bg-active`, `bg-disabled`, `bg-overlay`, `bg-brand-primary`, `bg-brand-solid`, `bg-brand-section`, `bg-error-primary`, `bg-error-solid`, `bg-warning-primary`, `bg-success-primary`

**Border**: `border-primary`, `border-secondary`, `border-tertiary`, `border-disabled`, `border-brand`, `border-error`

**Foreground**: `fg-primary`, `fg-secondary`, `fg-tertiary`, `fg-quaternary`, `fg-disabled`, `fg-brand-primary`, `fg-error-primary`, `fg-success-primary`

### Style Organization with `sortCx`

```typescript
export const styles = sortCx({
  common: {
    root: "base-classes-here",
    icon: "icon-classes-here",
  },
  sizes: {
    sm: { root: "small-size-classes" },
    md: { root: "medium-size-classes" },
  },
  colors: {
    primary: { root: "primary-color-classes" },
    secondary: { root: "secondary-color-classes" },
  },
});
```

### CSS Transitions

Default transition for hover states and small UI changes:
```typescript
className="transition duration-100 ease-linear"
```

## Icon Usage Rules

### As Component Reference (Preferred)

```typescript
<Button iconLeading={ChevronDown}>Options</Button>
<Button iconTrailing={ArrowRight}>Next</Button>
```

### As JSX Element — MUST Include `data-icon`

```typescript
<Button iconLeading={<ChevronDown data-icon className="size-4" />}>Options</Button>
```

### Standalone Icons

```typescript
<Home01 className="size-5 text-fg-secondary" />
<Home01 className="size-5" strokeWidth={2} aria-hidden="true" />
```

### Icon Sizes

- `size-4` (16px) — small contexts, buttons
- `size-5` (20px) — default
- `size-6` (24px) — large/emphasis

## Common Component Props Pattern

```typescript
interface CommonProps {
  size?: "sm" | "md" | "lg";
  isDisabled?: boolean;
  isLoading?: boolean;
}
```

### Button

```typescript
<Button size="md" color="primary" iconLeading={Check}>Save</Button>
<Button isLoading showTextWhileLoading>Submitting...</Button>
<Button color="primary-destructive" iconLeading={Trash02}>Delete</Button>
```

Colors: `primary`, `secondary`, `tertiary`, `link-gray`, `link-color`, `primary-destructive`, `secondary-destructive`, `tertiary-destructive`, `link-destructive`

**Link pattern** — no dedicated Link component; use Button with `href`:
```typescript
<Button href="/dashboard" color="link-color">View Dashboard</Button>
```

### Input

```typescript
<Input label="Email" placeholder="olivia@untitledui.com" icon={Mail01} isRequired />
<Input label="Email" isInvalid hint="Please enter a valid email" />
```

### Select

```typescript
<Select label="Team member" placeholder="Select" items={users}>
  {(item) => <Select.Item id={item.id} supportingText={item.email}>{item.name}</Select.Item>}
</Select>

// With search (ComboBox)
<Select.ComboBox label="Search" items={users}>
  {(item) => <Select.Item id={item.id}>{item.name}</Select.Item>}
</Select.ComboBox>
```

### Compound Component Pattern

```typescript
const Select = SelectComponent as typeof SelectComponent & {
  Item: typeof SelectItem;
  ComboBox: typeof ComboBox;
};
Select.Item = SelectItem;
Select.ComboBox = ComboBox;
```

### FeaturedIcon

```typescript
<FeaturedIcon icon={CheckCircle} color="success" theme="light" size="lg" />
// Themes: light, gradient, dark, modern (gray only), modern-neue (gray only), outline
```

### Badge

```typescript
<Badge color="brand" size="md">New</Badge>
<BadgeWithDot color="success" type="pill-color">Active</BadgeWithDot>
<BadgeWithIcon iconLeading={ArrowUp} color="success">12%</BadgeWithIcon>
```

### Avatar

```typescript
<Avatar src="/avatar.jpg" alt="User" size="md" status="online" />
<Avatar initials="OR" size="lg" />  // Fallback
<AvatarLabelGroup src="/avatar.jpg" title="Olivia Rhye" subtitle="olivia@example.com" />
```

## Brand Color Customization

Modify `src/styles/theme.css` → `--color-brand-*` variables (scale from 25 to 950):
```css
--color-brand-500: rgb(158 119 237);   /* Base brand color */
--color-brand-600: rgb(127 86 217);    /* Primary interactive */
```

## Validation Checklist

Before completing any UntitledUI component implementation:

- [ ] No raw Tailwind colors (`text-gray-*`, `bg-blue-*`) — use semantic classes
- [ ] All `react-aria-components` imports use `Aria*` prefix
- [ ] All file names are kebab-case
- [ ] All icon JSX elements include `data-icon` attribute
- [ ] Button icons use `iconLeading`/`iconTrailing` — never as children
- [ ] Components in correct directory (base/, application/, foundations/, marketing/)
- [ ] Proper size variants (`sm`, `md`, `lg`) where applicable
- [ ] State props used correctly (`isDisabled`, `isLoading`, `isInvalid`, `isRequired`)
