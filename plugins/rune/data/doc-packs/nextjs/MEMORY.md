# Next.js Doc Pack

## Etched — Next.js: App Router Patterns (2026-03-01)

**Source**: `doc-pack:nextjs@1.0.0`
**Category**: pattern

### Server vs Client Components
- Default is Server Component — add `"use client"` only when needed
- Client needed for: `useState`, `useEffect`, `onClick`, browser APIs
- Server needed for: direct DB access, secrets, heavy computation, `async` component
- Boundary rule: push `"use client"` as deep as possible in the component tree

### File Conventions
- `page.tsx` — route page (only file that makes a route publicly accessible)
- `layout.tsx` — shared wrapper (persists across navigations, does NOT re-render)
- `loading.tsx` — Suspense fallback (automatic streaming)
- `error.tsx` — error boundary (must be `"use client"`)
- `not-found.tsx` — 404 page (triggered by `notFound()`)
- `route.ts` — API route handler (GET, POST, PUT, DELETE exports)

## Etched — Next.js: Data Fetching Strategies (2026-03-01)

**Source**: `doc-pack:nextjs@1.0.0`
**Category**: pattern

### Server-Side Data
- `fetch()` in Server Components is extended with caching: `fetch(url, { cache: 'force-cache' })`
- `cache: 'no-store'` for real-time data (equivalent to `getServerSideProps`)
- `next: { revalidate: 3600 }` for ISR (Incremental Static Regeneration)
- `unstable_cache()` for non-fetch data (DB queries, external APIs)

### Caching Gotchas
- Default `fetch()` caches indefinitely in production — always set explicit cache strategy
- `revalidatePath('/path')` and `revalidateTag('tag')` for on-demand revalidation
- `cookies()` and `headers()` make the entire route dynamic — no caching
- Parallel data fetching: use `Promise.all([fetch1(), fetch2()])` — avoid waterfalls

## Etched — Next.js: Rendering and Performance (2026-03-01)

**Source**: `doc-pack:nextjs@1.0.0`
**Category**: pattern

### Streaming and Suspense
- Wrap slow components in `<Suspense fallback={<Loading />}>` for streaming
- `loading.tsx` creates automatic Suspense boundary at route level
- Partial prerendering (PPR): static shell + dynamic holes — opt-in per route
- `generateStaticParams()` for static generation of dynamic routes at build time

### Image and Font Optimization
- `next/image`: always use — handles lazy loading, sizing, format conversion
- `next/font`: load fonts at build time — no layout shift, self-hosted
- `next/font/google` — auto-subsets Google Fonts, zero external requests at runtime
- Set `sizes` prop on images for responsive behavior: `sizes="(max-width: 768px) 100vw, 50vw"`

### Common Anti-Patterns
- Do NOT use `useEffect` for data fetching — use Server Components instead
- Do NOT put `"use client"` at the top of every file — defeats RSC benefits
- Do NOT use `getServerSideProps` / `getStaticProps` in App Router — use `fetch()` or `unstable_cache()`
- Do NOT import server-only modules in Client Components — use `server-only` package guard
- Avoid deeply nested `layout.tsx` — each adds to the rendering waterfall
