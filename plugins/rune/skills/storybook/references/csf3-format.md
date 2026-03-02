# CSF3 Story Format — Authoring Guide

Component Story Format 3 (CSF3) is the standard story format since Storybook 7+.

## Structure

```typescript
// Button.stories.tsx
import type { Meta, StoryObj } from '@storybook/react'
import { Button } from './Button'

const meta = {
  title: 'Components/Button',
  component: Button,
  tags: ['autodocs'],
  argTypes: {
    variant: { control: 'select', options: ['primary', 'secondary', 'ghost'] },
    size: { control: 'select', options: ['sm', 'md', 'lg'] },
    disabled: { control: 'boolean' },
  },
  args: {
    children: 'Click me',
  },
} satisfies Meta<typeof Button>

export default meta
type Story = StoryObj<typeof meta>
```

## Story Exports

Each named export is a story:

```typescript
export const Default: Story = {}

export const Primary: Story = {
  args: { variant: 'primary' },
}

export const Loading: Story = {
  args: { isLoading: true },
}

export const Disabled: Story = {
  args: { disabled: true },
}
```

## Key Conventions

### Meta Object (Default Export)

| Field | Required | Purpose |
|-------|----------|---------|
| `title` | Recommended | Sidebar path (e.g., `Components/Button`) |
| `component` | Yes | The component being documented |
| `tags` | Optional | `['autodocs']` enables auto-generated docs |
| `argTypes` | Optional | Controls configuration for Storybook UI |
| `args` | Optional | Default args applied to all stories |
| `decorators` | Optional | Wrapper components (providers, layout) |
| `parameters` | Optional | Story-level configuration |

### Story Object (Named Exports)

| Field | Purpose |
|-------|---------|
| `args` | Props passed to the component |
| `render` | Custom render function (only when needed) |
| `play` | Interaction test function |
| `decorators` | Story-specific decorators |
| `parameters` | Story-specific parameters |

## Decorators

Wrap stories with providers, themes, or layout:

```typescript
const meta = {
  decorators: [
    (Story) => (
      <ThemeProvider>
        <div style={{ padding: '1rem' }}>
          <Story />
        </div>
      </ThemeProvider>
    ),
  ],
} satisfies Meta<typeof Button>
```

## Responsive Testing

Configure viewport parameters:

```typescript
export const Mobile: Story = {
  parameters: {
    viewport: { defaultViewport: 'mobile1' },
  },
}
```

## State Coverage Pattern

Every interactive component should have these stories:

1. **Default** — standard rendering
2. **WithData** — populated with realistic data
3. **Loading** — loading/skeleton state
4. **Error** — error state rendering
5. **Empty** — empty/no-data state
6. **Disabled** — disabled interaction state

## TypeScript Best Practices

- Use `satisfies Meta<typeof Component>` for type checking
- Define `type Story = StoryObj<typeof meta>` after meta
- Use `args` objects, not inline render functions
- Keep stories declarative — avoid side effects in story files
