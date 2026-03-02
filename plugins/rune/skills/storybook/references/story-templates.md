# Story Templates — Framework-Specific Patterns

## React (TypeScript)

```typescript
import type { Meta, StoryObj } from '@storybook/react'
import { ComponentName } from './ComponentName'

const meta = {
  title: 'Category/ComponentName',
  component: ComponentName,
  tags: ['autodocs'],
  args: {
    // Default props
  },
} satisfies Meta<typeof ComponentName>

export default meta
type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const WithData: Story = {
  args: {
    data: [
      { id: '1', name: 'Item One', status: 'active' },
      { id: '2', name: 'Item Two', status: 'pending' },
    ],
  },
}

export const Loading: Story = {
  args: { isLoading: true },
}

export const Error: Story = {
  args: { error: new Error('Failed to load data') },
}

export const Empty: Story = {
  args: { data: [] },
}
```

## Vue 3

```typescript
import type { Meta, StoryObj } from '@storybook/vue3'
import ComponentName from './ComponentName.vue'

const meta: Meta<typeof ComponentName> = {
  title: 'Category/ComponentName',
  component: ComponentName,
  tags: ['autodocs'],
  args: {
    // Default props
  },
}

export default meta
type Story = StoryObj<typeof ComponentName>

export const Default: Story = {}

export const WithSlot: Story = {
  render: (args) => ({
    components: { ComponentName },
    setup() { return { args } },
    template: '<ComponentName v-bind="args">Slot content</ComponentName>',
  }),
}
```

## Svelte

```typescript
import type { Meta, StoryObj } from '@storybook/svelte'
import ComponentName from './ComponentName.svelte'

const meta = {
  title: 'Category/ComponentName',
  component: ComponentName,
  tags: ['autodocs'],
} satisfies Meta<typeof ComponentName>

export default meta
type Story = StoryObj<typeof meta>

export const Default: Story = {
  args: {
    // Props
  },
}
```

## Angular

```typescript
import type { Meta, StoryObj } from '@storybook/angular'
import { ComponentNameComponent } from './component-name.component'

const meta: Meta<ComponentNameComponent> = {
  title: 'Category/ComponentName',
  component: ComponentNameComponent,
  tags: ['autodocs'],
}

export default meta
type Story = StoryObj<ComponentNameComponent>

export const Default: Story = {
  args: {
    // Inputs
  },
}
```

## Common Patterns

### Provider Decorator (React)

```typescript
const meta = {
  decorators: [
    (Story) => (
      <QueryClientProvider client={queryClient}>
        <ThemeProvider theme={lightTheme}>
          <Story />
        </ThemeProvider>
      </QueryClientProvider>
    ),
  ],
} satisfies Meta<typeof ComponentName>
```

### Responsive Stories

```typescript
export const Mobile: Story = {
  parameters: {
    viewport: { defaultViewport: 'mobile1' },
    layout: 'fullscreen',
  },
}

export const Tablet: Story = {
  parameters: {
    viewport: { defaultViewport: 'tablet' },
  },
}
```

### Mock Data Factory

```typescript
const createMockItem = (overrides = {}) => ({
  id: crypto.randomUUID(),
  name: 'Test Item',
  status: 'active' as const,
  createdAt: new Date().toISOString(),
  ...overrides,
})

export const WithManyItems: Story = {
  args: {
    items: Array.from({ length: 20 }, (_, i) =>
      createMockItem({ name: `Item ${i + 1}` })
    ),
  },
}
```

### Interaction Test

```typescript
import { within, userEvent, expect } from '@storybook/test'

export const Clicked: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await userEvent.click(canvas.getByRole('button'))
    await expect(canvas.getByText('Clicked!')).toBeVisible()
  },
}
```
