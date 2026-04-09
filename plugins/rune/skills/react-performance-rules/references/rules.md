# React Performance Rules — Detailed Examples

## 1. Eliminating Waterfalls (CRITICAL)

### `async-parallel`

Never chain independent `await` calls sequentially.

```tsx
// NON-COMPLIANT: Sequential waterfalls — each blocks the next
async function Page() {
  const user = await getUser()        // 200ms
  const posts = await getPosts()      // 300ms
  const comments = await getComments() // 150ms
  // Total: 650ms (sequential)
}

// COMPLIANT: Parallel fetching
async function Page() {
  const [user, posts, comments] = await Promise.all([
    getUser(),     // 200ms
    getPosts(),    // 300ms (runs simultaneously)
    getComments(), // 150ms (runs simultaneously)
  ])
  // Total: 300ms (parallel, bounded by slowest)
}
```

### `async-defer-await`

Start async work before awaiting — assign the promise to a variable.

```tsx
// NON-COMPLIANT: Blocks on auth before starting data fetch
async function Dashboard() {
  const session = await getSession()
  const data = await fetchDashboard(session.userId)
  return <DashboardView data={data} />
}

// COMPLIANT: Start data fetch, then await auth
async function Dashboard() {
  const sessionPromise = getSession()
  const session = await sessionPromise
  const data = await fetchDashboard(session.userId)
  return <DashboardView data={data} />
}
```

### `async-suspense-boundaries`

Wrap async Server Components in `<Suspense>` to enable streaming.

```tsx
// NON-COMPLIANT: Single boundary blocks entire page
async function Page() {
  const data = await slowQuery() // 2s — blocks everything
  return <Layout><Sidebar /><Content data={data} /></Layout>
}

// COMPLIANT: Granular Suspense boundaries
function Page() {
  return (
    <Layout>
      <Sidebar /> {/* Renders immediately */}
      <Suspense fallback={<ContentSkeleton />}>
        <Content /> {/* Streams when ready */}
      </Suspense>
    </Layout>
  )
}
```

### `async-cheap-condition-before-await`

Check cheap conditions before expensive operations.

```tsx
// NON-COMPLIANT: Always runs expensive query
async function UserProfile({ userId }) {
  const profile = await db.query('SELECT * FROM users WHERE id = ?', [userId])
  if (!profile.isPublic) return <Private />
  return <Profile data={profile} />
}

// COMPLIANT: Check cache/cheap condition first
async function UserProfile({ userId }) {
  const isPublic = await cache.get(`user:${userId}:public`)
  if (isPublic === false) return <Private />
  const profile = await db.query('SELECT * FROM users WHERE id = ?', [userId])
  return <Profile data={profile} />
}
```

### `async-api-routes`

Colocate data fetching in Server Components — avoid unnecessary client → API → DB round trips.

```tsx
// NON-COMPLIANT: Client fetches from API route
// app/api/users/route.ts
export async function GET() {
  const users = await db.users.findMany()
  return Response.json(users)
}
// app/users/page.tsx (client component)
const users = await fetch('/api/users').then(r => r.json())

// COMPLIANT: Server Component fetches directly
// app/users/page.tsx (server component)
async function UsersPage() {
  const users = await db.users.findMany() // Direct DB access, no HTTP hop
  return <UserList users={users} />
}
```

## 2. Bundle Size (CRITICAL)

### `bundle-barrel-imports`

Import from specific modules, not barrel files.

```tsx
// NON-COMPLIANT: Barrel import pulls entire library
import { Button } from '@/components'
// ↑ If components/index.ts re-exports 50 components, bundler may include all 50

// COMPLIANT: Direct module import
import { Button } from '@/components/Button'
```

### `bundle-dynamic-imports`

Use dynamic imports for below-fold and modal content.

```tsx
// NON-COMPLIANT: Static import of heavy modal
import { SettingsModal } from './SettingsModal'

// COMPLIANT: Dynamic import — loaded only when opened
const SettingsModal = dynamic(() => import('./SettingsModal'), {
  loading: () => <Spinner />,
})
```

### `bundle-defer-third-party`

Load non-critical third-party scripts after the page is interactive.

```tsx
// NON-COMPLIANT: Analytics blocks page render
import Script from 'next/script'
<Script src="https://analytics.example.com/tracker.js" />

// COMPLIANT: Deferred loading
<Script src="https://analytics.example.com/tracker.js" strategy="afterInteractive" />
```

## 3. Server-Side (HIGH)

### `server-cache-react`

Use React `cache()` for request-scoped memoization.

```tsx
// COMPLIANT: Request-level cache
import { cache } from 'react'

const getUser = cache(async (id: string) => {
  return db.users.findUnique({ where: { id } })
})

// Called in multiple Server Components — only one DB query per request
async function Header() { const user = await getUser(userId) }
async function Sidebar() { const user = await getUser(userId) } // Cached!
```

### `server-no-shared-module-state`

Module-level mutable state is shared across requests in Server Components.

```tsx
// NON-COMPLIANT: Shared mutable state across requests
let requestCount = 0
export async function Page() {
  requestCount++ // Race condition! Leaks between users
}

// COMPLIANT: Use React cache or request-scoped storage
import { cache } from 'react'
const getRequestCount = cache(() => ({ count: 0 }))
```

## 4. Re-render Optimization (MEDIUM)

### `rerender-no-inline-components`

Never define components inside render functions.

```tsx
// NON-COMPLIANT: Component redefined every render — state is LOST
function Parent() {
  const ItemComponent = ({ item }) => <div>{item.name}</div>
  return <List renderItem={ItemComponent} />
}

// COMPLIANT: Component defined outside
const ItemComponent = ({ item }) => <div>{item.name}</div>
function Parent() {
  return <List renderItem={ItemComponent} />
}
```

### `rerender-derived-state`

Compute derived values inline — don't use `useEffect` to sync state.

```tsx
// NON-COMPLIANT: Unnecessary state + effect
const [items, setItems] = useState([])
const [filteredItems, setFilteredItems] = useState([])
useEffect(() => {
  setFilteredItems(items.filter(i => i.active))
}, [items]) // Extra render cycle!

// COMPLIANT: Derive inline
const [items, setItems] = useState([])
const filteredItems = useMemo(() => items.filter(i => i.active), [items])
```

### `rerender-transitions`

Use `useTransition` for non-urgent updates.

```tsx
// COMPLIANT: Search input stays responsive
const [isPending, startTransition] = useTransition()
function handleSearch(query) {
  setInputValue(query) // Urgent: update input immediately
  startTransition(() => {
    setSearchResults(search(query)) // Non-urgent: can be interrupted
  })
}
```

## 5. Rendering (MEDIUM)

### `rendering-content-visibility`

Use CSS `content-visibility: auto` for off-screen content.

```css
/* COMPLIANT: Browser skips rendering for off-screen sections */
.section {
  content-visibility: auto;
  contain-intrinsic-size: auto 500px; /* Estimated height for scroll */
}
```

### `rendering-hydration-no-flicker`

Avoid layout shifts during hydration.

```tsx
// NON-COMPLIANT: Different initial state on server vs client
function ThemeToggle() {
  const [theme, setTheme] = useState(
    typeof window !== 'undefined' ? localStorage.getItem('theme') : 'light'
  )
  // ↑ Server renders 'light', client may render 'dark' → flash!
}

// COMPLIANT: Use cookie or match server state
function ThemeToggle() {
  const theme = use(ThemeContext) // Set from cookie in root layout
}
```

## 6. JS Performance (LOW-MEDIUM)

### `js-set-map-lookups`

Use `Set`/`Map` for frequent lookups.

```tsx
// NON-COMPLIANT: O(n) lookup on every render
const isSelected = selectedIds.includes(item.id) // Array.includes

// COMPLIANT: O(1) lookup
const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds])
const isSelected = selectedSet.has(item.id) // Set.has
```

### `js-batch-dom-css`

Batch DOM reads and writes to avoid layout thrashing.

```tsx
// NON-COMPLIANT: Read-write-read forces 2 layout recalculations
const height1 = el1.offsetHeight  // Read → layout
el2.style.height = height1 + 'px' // Write → invalidate
const height2 = el3.offsetHeight  // Read → layout again!

// COMPLIANT: Batch all reads, then all writes
const height1 = el1.offsetHeight  // Read
const height2 = el3.offsetHeight  // Read (same layout)
el2.style.height = height1 + 'px' // Write
el4.style.height = height2 + 'px' // Write (one recalculation)
```

## 7. Advanced (LOW)

### `advanced-effect-event-deps`

Use `useEffectEvent` to remove unnecessary effect dependencies.

```tsx
// NON-COMPLIANT: Effect re-runs when onVisit changes
useEffect(() => {
  onVisit(url) // onVisit in deps → effect re-runs on every render
}, [url, onVisit])

// COMPLIANT: useEffectEvent removes the dependency
const onVisitEvent = useEffectEvent(onVisit)
useEffect(() => {
  onVisitEvent(url) // onVisitEvent is stable — not a dependency
}, [url])
```

### `advanced-init-once`

Initialize expensive values once, not on every render.

```tsx
// NON-COMPLIANT: Creates Map on every render, discards all but first
const [cache] = useState(() => new Map()) // Works but wasteful pattern

// COMPLIANT: Module-level initialization
const cache = new Map() // Created once at import time

// Or with ref for component-scoped:
const cacheRef = useRef<Map<string, any>>(null)
if (cacheRef.current === null) {
  cacheRef.current = new Map()
}
```
