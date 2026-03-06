# React Composition Rules

Composition patterns for building maintainable React components. Adapted from Vercel Composition Patterns. Used by UX review agents and frontend-design-patterns skill.

## Compound Components

### When to Use

Use compound components when a set of components share implicit state and must be used together.

```tsx
// Good — compound component pattern
<Select value={selected} onChange={setSelected}>
  <Select.Trigger>{selected}</Select.Trigger>
  <Select.Content>
    <Select.Item value="a">Option A</Select.Item>
    <Select.Item value="b">Option B</Select.Item>
  </Select.Content>
</Select>

// Bad — prop-drilling everything
<Select
  value={selected}
  onChange={setSelected}
  options={[{ value: 'a', label: 'Option A' }, { value: 'b', label: 'Option B' }]}
  triggerLabel={selected}
/>
```

### Implementation Pattern

```tsx
const SelectContext = createContext<SelectContextType | null>(null)

function Select({ value, onChange, children }: SelectProps) {
  return (
    <SelectContext.Provider value={{ value, onChange }}>
      {children}
    </SelectContext.Provider>
  )
}

function SelectItem({ value, children }: SelectItemProps) {
  const ctx = useContext(SelectContext)
  if (!ctx) throw new Error('SelectItem must be used within Select')
  return <button onClick={() => ctx.onChange(value)}>{children}</button>
}

Select.Trigger = SelectTrigger
Select.Content = SelectContent
Select.Item = SelectItem
```

## Children Pattern

### Prefer Children Over Render Props

Use `children` for simple content injection. Reserve render props for when the child needs data from the parent.

```tsx
// Good — simple content injection
<Card>
  <Card.Header>Title</Card.Header>
  <Card.Body>Content here</Card.Body>
</Card>

// Only use render props when child needs parent data
<DataTable data={rows}>
  {({ row, index }) => <TableRow key={row.id} row={row} isEven={index % 2 === 0} />}
</DataTable>
```

## Render Props

### When to Use

Use render props when the consumer needs data or behavior from the provider.

```tsx
// Good — consumer needs mouse position data
<MouseTracker>
  {({ x, y }) => <Tooltip style={{ left: x, top: y }}>Cursor here</Tooltip>}
</MouseTracker>

// Pattern
function MouseTracker({ children }: { children: (pos: { x: number; y: number }) => ReactNode }) {
  const [pos, setPos] = useState({ x: 0, y: 0 })
  return <div onMouseMove={e => setPos({ x: e.clientX, y: e.clientY })}>{children(pos)}</div>
}
```

## Slot Pattern

### Named Slots via Props

Use typed props for named content slots when the layout is fixed but content varies.

```tsx
// Good — explicit slots
interface PageLayoutProps {
  header: ReactNode
  sidebar: ReactNode
  children: ReactNode
  footer?: ReactNode
}

function PageLayout({ header, sidebar, children, footer }: PageLayoutProps) {
  return (
    <div className="grid grid-cols-[240px_1fr] grid-rows-[auto_1fr_auto]">
      <header className="col-span-2">{header}</header>
      <aside>{sidebar}</aside>
      <main>{children}</main>
      {footer && <footer className="col-span-2">{footer}</footer>}
    </div>
  )
}
```

## Container/Presentational Split

### Separation of Concerns

Separate data fetching/logic (container) from rendering (presentational).

```tsx
// Container — handles data and state
function UserProfileContainer({ userId }: { userId: string }) {
  const { data: user, isLoading, error } = useUser(userId)
  if (isLoading) return <ProfileSkeleton />
  if (error) return <ErrorMessage error={error} />
  return <UserProfileView user={user} />
}

// Presentational — pure rendering, easy to test
function UserProfileView({ user }: { user: User }) {
  return (
    <div className="flex items-center gap-4">
      <Avatar src={user.avatar} alt={user.name} />
      <div>
        <h2 className="text-lg font-semibold">{user.name}</h2>
        <p className="text-muted-foreground">{user.email}</p>
      </div>
    </div>
  )
}
```

### When to Split

| Signal | Action |
|--------|--------|
| Component has both `useQuery`/`fetch` and JSX | Split |
| Component > 150 lines | Consider splitting |
| Same UI with different data sources | Split (reuse presentational) |
| Component is only JSX + props | Keep as-is (already presentational) |

## Context Provider Pattern

### Compose Providers

Use a provider composition pattern to avoid deep nesting.

```tsx
// Bad — pyramid of doom
<AuthProvider>
  <ThemeProvider>
    <I18nProvider>
      <NotificationProvider>
        <App />
      </NotificationProvider>
    </I18nProvider>
  </ThemeProvider>
</AuthProvider>

// Good — compose helper
function ComposeProviders({ providers, children }: ComposeProps) {
  return providers.reduceRight(
    (acc, Provider) => <Provider>{acc}</Provider>,
    children
  )
}

<ComposeProviders providers={[AuthProvider, ThemeProvider, I18nProvider, NotificationProvider]}>
  <App />
</ComposeProviders>
```

## Anti-Patterns

### COMP-A01: Prop Drilling

More than 3 levels of prop passing indicates a need for context or composition.

### COMP-A02: God Components

Components over 300 lines that handle multiple concerns should be decomposed.

### COMP-A03: Boolean Prop Explosion

More than 3 boolean props controlling variants suggests a compound component or polymorphic pattern.

```tsx
// Bad — boolean explosion
<Button primary large outlined disabled loading />

// Good — variant prop
<Button variant="primary" size="lg" state="loading" />
```

### COMP-A04: Conditional Rendering Spaghetti

Deeply nested ternaries indicate a need for component extraction.

```tsx
// Bad
{isAuth ? (isPremium ? <PremiumDashboard /> : <FreeDashboard />) : <LoginPage />}

// Good
function DashboardRouter() {
  if (!isAuth) return <LoginPage />
  if (isPremium) return <PremiumDashboard />
  return <FreeDashboard />
}
```

### COMP-A05: Wrapper Hell

Wrapping components purely for styling suggests the inner component lacks proper variant support.

```tsx
// Bad — wrapper just for margin
function MarginedCard({ children }) {
  return <div className="mt-4"><Card>{children}</Card></div>
}

// Good — Card accepts className
<Card className="mt-4">{children}</Card>
```
