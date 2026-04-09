---
name: react-composition-patterns
description: |
  React composition patterns that scale — compound components, state lifting,
  explicit variants, and React 19 API changes. Use to eliminate boolean prop
  proliferation and build flexible component APIs.
  Trigger keywords: compound component, boolean props, composition, render props,
  context provider, React 19, forwardRef, use hook, component architecture.
user-invocable: false
disable-model-invocation: false
---

# React Composition Patterns

Patterns for building scalable React component APIs. Focused on eliminating boolean prop proliferation and leveraging React 19 primitives.

## When This Loads

Auto-loaded by the Stacks context router when:
- `react` >= 19 or `next` >= 15 detected in `package.json`
- Changed files involve component architecture (shared components, design system)
- Review/work/forge workflows involve component API design

## Rules

### `architecture-avoid-boolean-props`

**Problem**: Boolean props create an exponential matrix of states. A component with 5 boolean props has 32 possible combinations — most are invalid.

```tsx
// NON-COMPLIANT: Boolean prop explosion
<Button primary large outline disabled loading />
// Which combinations are valid? primary + outline? loading + disabled?
```

```tsx
// COMPLIANT: Composition with explicit variants
<Button variant="primary" size="lg">
  <Button.Spinner />
  Submit
</Button>
```

**Rule**: When a component accumulates 3+ boolean appearance props, refactor to variant-based or compound component API.

### `architecture-compound-components`

**Problem**: Complex components with deeply nested configuration props become unwieldy and inflexible.

```tsx
// NON-COMPLIANT: Prop drilling configuration
<Select
  options={options}
  renderOption={renderOption}
  renderGroup={renderGroup}
  onSelect={onSelect}
  filterFn={filterFn}
  groupBy={groupBy}
/>
```

```tsx
// COMPLIANT: Compound component with shared context
<Select onSelect={onSelect}>
  <Select.Search filter={filterFn} />
  <Select.Group label="Fruits">
    <Select.Option value="apple">Apple</Select.Option>
    <Select.Option value="banana">Banana</Select.Option>
  </Select.Group>
</Select>
```

**Rule**: Use compound components when the parent manages shared state and children need flexible arrangement.

### `state-decouple-implementation`

**Problem**: Coupling state management with UI rendering makes components rigid and hard to test.

```tsx
// NON-COMPLIANT: State and UI tightly coupled
function Accordion() {
  const [openIndex, setOpenIndex] = useState(-1)
  return (
    <div>
      {items.map((item, i) => (
        <div key={i} onClick={() => setOpenIndex(i === openIndex ? -1 : i)}>
          {item.title}
          {i === openIndex && <div>{item.content}</div>}
        </div>
      ))}
    </div>
  )
}
```

```tsx
// COMPLIANT: State in provider, UI in components
function AccordionProvider({ children }) {
  const [openIndex, setOpenIndex] = useState(-1)
  const toggle = useCallback((i) => setOpenIndex(prev => prev === i ? -1 : i), [])
  return (
    <AccordionContext value={{ openIndex, toggle }}>
      {children}
    </AccordionContext>
  )
}
```

**Rule**: Providers manage state and expose actions. UI components consume context and render.

### `state-context-interface`

**Problem**: Context values with inconsistent shapes make consumers fragile.

```tsx
// COMPLIANT: Generic context shape
interface ContextValue<T> {
  state: T                          // Current state
  actions: Record<string, Function> // Available mutations
  metadata: {                       // Derived/computed info
    isLoading: boolean
    error: Error | null
    isDirty: boolean
  }
}
```

**Rule**: Standardize context interfaces around `{ state, actions, metadata }` for predictable consumer code.

### `state-lift-state`

**Problem**: Sibling components that need to communicate often resort to global state or event buses.

```tsx
// NON-COMPLIANT: Sibling communication via global state
const searchStore = create((set) => ({ query: '', setQuery: set }))
function SearchInput() { /* writes to store */ }
function SearchResults() { /* reads from store */ }
```

```tsx
// COMPLIANT: Lift state to nearest shared parent
function SearchPage() {
  const [query, setQuery] = useState('')
  return (
    <>
      <SearchInput value={query} onChange={setQuery} />
      <SearchResults query={query} />
    </>
  )
}
```

**Rule**: Lift state to the nearest common ancestor before reaching for global state management.

### `patterns-explicit-variants`

**Problem**: Boolean mode props create implicit, hard-to-discover component variations.

```tsx
// NON-COMPLIANT: Boolean modes
<Card compact={true} horizontal={true} />
```

```tsx
// COMPLIANT: Explicit variant components
<Card.Compact />
<Card.Horizontal />
// Or with variant prop:
<Card variant="compact" layout="horizontal" />
```

**Rule**: Create named variant components or use discriminated union variant props instead of boolean mode flags.

### `patterns-children-over-render-props`

**Problem**: `renderX` props fragment the component API and reduce composability.

```tsx
// NON-COMPLIANT: Render prop proliferation
<List
  renderItem={renderItem}
  renderEmpty={renderEmpty}
  renderHeader={renderHeader}
  renderFooter={renderFooter}
/>
```

```tsx
// COMPLIANT: Children composition with slots
<List>
  <List.Header>My Items</List.Header>
  {items.map(item => <List.Item key={item.id}>{item.name}</List.Item>)}
  <List.Empty>No items found</List.Empty>
  <List.Footer>Showing {items.length} items</List.Footer>
</List>
```

**Rule**: Prefer children composition and slot components over `renderX` props. Reserve render props for cases where the parent must pass computed data to the child.

### `react19-no-forwardref`

**Problem**: React 19 makes `forwardRef` unnecessary and adds the `use()` hook.

```tsx
// NON-COMPLIANT (React 19): Unnecessary forwardRef wrapper
const Input = forwardRef<HTMLInputElement, Props>((props, ref) => (
  <input ref={ref} {...props} />
))
```

```tsx
// COMPLIANT (React 19): ref is a regular prop
function Input({ ref, ...props }: Props & { ref?: Ref<HTMLInputElement> }) {
  return <input ref={ref} {...props} />
}
```

```tsx
// NON-COMPLIANT (React 19): useContext
const theme = useContext(ThemeContext)
```

```tsx
// COMPLIANT (React 19): use() hook
const theme = use(ThemeContext)
// Also works with promises:
const data = use(fetchData())
```

**Rule**: In React 19+ codebases, use `ref` as a regular prop (no `forwardRef`) and `use()` instead of `useContext()`.
