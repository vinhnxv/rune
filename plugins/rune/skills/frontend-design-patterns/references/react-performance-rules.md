# React Performance Rules

Best practices for React performance adapted from Vercel React Best Practices. Used by UX review agents and frontend-design-patterns skill for performance-aware code review.

## Memoization

### PERF-R01: Avoid Unnecessary Re-renders

Use `React.memo` for pure components that receive stable props.

```tsx
// Bad — re-renders on every parent render
function ExpensiveList({ items }: { items: Item[] }) {
  return <ul>{items.map(item => <li key={item.id}>{item.name}</li>)}</ul>
}

// Good — skips re-render when items haven't changed
const ExpensiveList = React.memo(function ExpensiveList({ items }: { items: Item[] }) {
  return <ul>{items.map(item => <li key={item.id}>{item.name}</li>)}</ul>
})
```

### PERF-R02: Memoize Expensive Computations

Use `useMemo` for computations that are expensive and depend on specific values.

```tsx
// Bad — filters on every render
const filtered = items.filter(i => i.category === selected)

// Good — only recomputes when items or selected changes
const filtered = useMemo(() => items.filter(i => i.category === selected), [items, selected])
```

### PERF-R03: Stable Callback References

Use `useCallback` for callbacks passed to memoized children or used in dependency arrays.

```tsx
// Bad — new function every render, breaks child memo
const handleClick = (id: string) => dispatch({ type: 'SELECT', id })

// Good — stable reference
const handleClick = useCallback((id: string) => dispatch({ type: 'SELECT', id }), [dispatch])
```

### PERF-R04: Don't Over-Memoize

Memoization has overhead. Only memoize when there is a measured performance benefit.

| Scenario | Memoize? |
|----------|----------|
| Expensive computation (sort, filter large lists) | Yes — `useMemo` |
| Callback passed to `React.memo` child | Yes — `useCallback` |
| Simple string concatenation | No |
| Inline object/array in JSX | Only if causing re-renders |

## Code Splitting

### PERF-R05: Lazy Load Routes

Use `React.lazy` + `Suspense` for route-level code splitting.

```tsx
// Bad — imports everything upfront
import { Dashboard } from './pages/Dashboard'
import { Settings } from './pages/Settings'

// Good — splits into separate chunks
const Dashboard = lazy(() => import('./pages/Dashboard'))
const Settings = lazy(() => import('./pages/Settings'))
```

### PERF-R06: Dynamic Imports for Heavy Libraries

Import heavy third-party libraries only when needed.

```tsx
// Bad — chart library loaded on initial page load
import { Chart } from 'chart.js'

// Good — loaded when component mounts
const ChartComponent = lazy(() => import('./ChartComponent'))
```

### PERF-R07: Suspense Boundaries

Place `Suspense` boundaries at meaningful UI boundaries, not around every component.

```tsx
// Bad — suspense per component
<Suspense fallback={<Spinner />}><Header /></Suspense>
<Suspense fallback={<Spinner />}><Sidebar /></Suspense>

// Good — suspense at route/section level
<Suspense fallback={<PageSkeleton />}>
  <Route path="/dashboard" element={<Dashboard />} />
</Suspense>
```

## Rendering

### PERF-R08: Stable Keys in Lists

Never use array index as key for lists that can be reordered, filtered, or modified.

```tsx
// Bad — index keys cause incorrect reconciliation
{items.map((item, i) => <Item key={i} data={item} />)}

// Good — stable unique key
{items.map(item => <Item key={item.id} data={item} />)}
```

### PERF-R09: Avoid Inline Object/Array Props

Inline objects and arrays create new references every render.

```tsx
// Bad — new object every render
<Component style={{ margin: 8 }} options={['a', 'b']} />

// Good — stable references
const style = useMemo(() => ({ margin: 8 }), [])
const options = useMemo(() => ['a', 'b'], [])
<Component style={style} options={options} />
```

### PERF-R10: Virtualize Long Lists

Use virtual scrolling for lists with 100+ items.

```tsx
// Bad — renders 10,000 DOM nodes
{items.map(item => <Row key={item.id} data={item} />)}

// Good — only renders visible items
<VirtualList
  height={600}
  itemCount={items.length}
  itemSize={35}
  renderItem={({ index }) => <Row data={items[index]} />}
/>
```

## Images and Assets

### PERF-R11: Lazy Load Images

Use `loading="lazy"` for below-the-fold images.

```tsx
// Bad — all images load immediately
<img src={url} alt={alt} />

// Good — defers loading until near viewport
<img src={url} alt={alt} loading="lazy" />
```

### PERF-R12: Responsive Images

Use `srcSet` and `sizes` for responsive image loading.

```tsx
<img
  src="/hero-800.jpg"
  srcSet="/hero-400.jpg 400w, /hero-800.jpg 800w, /hero-1200.jpg 1200w"
  sizes="(max-width: 600px) 400px, (max-width: 1024px) 800px, 1200px"
  alt="Hero"
/>
```

### PERF-R13: Use next/image or Equivalent

Framework-specific image components handle optimization automatically.

## State Management

### PERF-R14: Colocate State

Keep state as close to where it's used as possible. Lifting state too high causes unnecessary re-renders.

```tsx
// Bad — search state in App re-renders everything
function App() {
  const [search, setSearch] = useState('')
  return <Layout><SearchBar value={search} onChange={setSearch} /><Content /></Layout>
}

// Good — search state in SearchBar
function SearchBar() {
  const [search, setSearch] = useState('')
  return <input value={search} onChange={e => setSearch(e.target.value)} />
}
```

### PERF-R15: Split Context Providers

Split large contexts into separate providers to prevent unnecessary re-renders.

```tsx
// Bad — one context for everything
const AppContext = createContext({ user, theme, locale, notifications })

// Good — split by update frequency
const UserContext = createContext(user)
const ThemeContext = createContext(theme)
const NotificationContext = createContext(notifications)
```

### PERF-R16: Debounce Expensive Updates

Debounce state updates that trigger expensive operations (search, API calls).

```tsx
// Bad — API call on every keystroke
const handleChange = (e) => { setQuery(e.target.value); fetchResults(e.target.value) }

// Good — debounced
const debouncedFetch = useMemo(() => debounce(fetchResults, 300), [fetchResults])
const handleChange = (e) => { setQuery(e.target.value); debouncedFetch(e.target.value) }
```

## Bundle Size

### PERF-R17: Tree-Shakeable Imports

Import only what you need from libraries.

```tsx
// Bad — imports entire library
import _ from 'lodash'
_.debounce(fn, 300)

// Good — imports single function
import debounce from 'lodash/debounce'
debounce(fn, 300)
```

### PERF-R18: Analyze Bundle Size

Monitor bundle size with tools like `@next/bundle-analyzer` or `source-map-explorer`.

| Threshold | Action |
|-----------|--------|
| Initial JS > 200KB | Investigate code splitting |
| Single chunk > 100KB | Consider lazy loading |
| Unused exports > 10% | Check tree shaking |
