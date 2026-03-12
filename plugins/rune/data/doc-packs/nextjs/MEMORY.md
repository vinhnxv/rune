# Next.js Doc Pack

## Etched — Next.js: App Router Core Patterns (2026-03-11)

**Source**: `doc-pack:nextjs@1.0.0`
**Category**: pattern

### File Conventions

- `page.tsx` — route UI (only file that makes a route publicly accessible)
- `layout.tsx` — shared UI that wraps child routes (preserved across navigation)
- `loading.tsx` — instant loading UI via React Suspense boundary
- `error.tsx` — error boundary with reset capability (must be client component)
- `not-found.tsx` — 404 UI triggered by `notFound()` function
- `route.ts` — API route handler (cannot coexist with `page.tsx` in same directory)

### Server vs Client Components Decision Tree

- Default: all components are Server Components (RSC) — no `"use client"` needed
- Add `"use client"` ONLY when you need: `useState`, `useEffect`, `onClick`, browser APIs
- Server Components can import Client Components, NOT vice versa
- Pass Server Component as `children` prop to Client Components for composition

### Data Fetching

- Server Components: use `async/await` directly — `const data = await fetch(url)`
- Fetch requests are automatically deduplicated within a render pass
- Use `cache()` from React for expensive computations in Server Components
- Client-side: use `useSWR` or `@tanstack/react-query`, NOT `useEffect` + `fetch`

## Etched — Next.js: Caching and Revalidation (2026-03-11)

**Source**: `doc-pack:nextjs@1.0.0`
**Category**: pattern

### Caching Layers

- **Request Memoization**: auto-deduplicates `fetch` in same render — free, no config
- **Data Cache**: persists `fetch` results across requests — default ON for `fetch()`
- **Full Route Cache**: pre-renders static routes at build time — opt out with `dynamic = "force-dynamic"`
- **Router Cache**: client-side cache of visited routes — 30s for dynamic, 5min for static

### Revalidation Strategies

- Time-based: `fetch(url, { next: { revalidate: 3600 } })` — seconds
- On-demand: `revalidatePath('/path')` or `revalidateTag('tag')` in Server Actions
- Opt out: `fetch(url, { cache: 'no-store' })` or segment-level `dynamic = "force-dynamic"`

### Common Caching Pitfalls

- `cookies()` or `headers()` in a route makes the entire route dynamic
- `searchParams` in page props makes the page dynamic — use `loading.tsx` for good UX
- POST requests in Route Handlers are NOT cached (correct default)
- `revalidatePath` revalidates all segments under that path, not just the exact path

## Etched — Next.js: Server Actions and Mutations (2026-03-11)

**Source**: `doc-pack:nextjs@1.0.0`
**Category**: pattern

### Server Action Patterns

- Define with `"use server"` at top of function or file
- Can be used in `<form action={serverAction}>` — works without JS (progressive enhancement)
- Return values via `useActionState()` hook for form state management
- Call `revalidatePath()` or `revalidateTag()` after mutations to update cached data

### Best Practices

- Validate inputs with Zod in Server Actions — never trust client data
- Use `redirect()` for post-mutation navigation (throws internally, call outside try/catch)
- Prefer Server Actions over API Routes for mutations — type-safe, no manual fetch
- Use `useTransition()` for non-form mutations to get pending state
