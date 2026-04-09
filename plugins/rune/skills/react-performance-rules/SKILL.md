---
name: react-performance-rules
description: |
  React and Next.js performance optimization rules — 69 rules across 8 categories
  prioritized by impact. Covers waterfall elimination, bundle optimization,
  server/client rendering, re-render prevention, and advanced patterns.
  Trigger keywords: React performance, Next.js optimization, bundle size,
  re-render, waterfall, suspense, dynamic import, memo, useMemo, useCallback.
user-invocable: false
disable-model-invocation: false
---

# React Performance Rules

69 rules for React and Next.js performance, organized by priority category. Each rule includes rationale, non-compliant example, and compliant fix.

## When This Loads

Auto-loaded by the Stacks context router when:
- `react` or `next` detected in `package.json`
- Changed files touch React components (`.tsx`, `.jsx`)
- Review/work/forge workflows involve React code

## Rule Categories (Priority Order)

### 1. Eliminating Waterfalls (CRITICAL)

Sequential async calls that block rendering. The highest-impact optimization category.

| Rule | Summary |
|------|---------|
| `async-parallel` | Use `Promise.all` for independent fetches — never sequential `await` |
| `async-defer-await` | Start async work before `await`-ing — assign promise to variable first |
| `async-suspense-boundaries` | Wrap async components in `<Suspense>` to enable parallel streaming |
| `async-cheap-condition-before-await` | Check cheap conditions before expensive awaits to avoid unnecessary work |
| `async-dependencies` | Model data dependencies explicitly — fetch dependents in parallel where possible |
| `async-api-routes` | Colocate data fetching in Server Components — avoid client→API→DB round trips |

### 2. Bundle Size (CRITICAL)

Every kilobyte impacts Time to Interactive. Tree-shaking alone is not enough.

| Rule | Summary |
|------|---------|
| `bundle-barrel-imports` | Import from specific modules, not barrel `index.ts` files — barrels defeat tree-shaking |
| `bundle-dynamic-imports` | Use `next/dynamic` or `React.lazy` for below-fold and modal content |
| `bundle-defer-third-party` | Load analytics, chat widgets, and non-critical scripts with `defer` or `afterInteractive` |
| `bundle-conditional` | Dynamic-import code paths that depend on feature flags or user roles |
| `bundle-preload` | Use `<link rel="preload">` for critical resources discovered late in the page load |

### 3. Server-Side (HIGH)

Maximize work done on the server to minimize client JavaScript.

| Rule | Summary |
|------|---------|
| `server-cache-react` | Use React `cache()` for request-level memoization of expensive computations |
| `server-parallel-fetching` | Fetch independent data sources in parallel with `Promise.all` in Server Components |
| `server-after-nonblocking` | Use `after()` (Next.js) for analytics/logging that shouldn't block response |
| `server-no-shared-module-state` | Never store mutable state in module scope — Server Components may share instances |
| `server-serialization` | Only pass serializable props from Server to Client Components |
| `server-hoist-static-io` | Move static data fetches to the highest possible Server Component in the tree |

### 4. Client-Side Data (MEDIUM-HIGH)

Optimize data patterns on the client where server rendering isn't possible.

| Rule | Summary |
|------|---------|
| `client-swr-dedup` | Use SWR/React Query for automatic request deduplication and cache |
| `client-event-listeners` | Clean up event listeners in `useEffect` return — prevent memory leaks |
| `client-passive-event-listeners` | Use `{ passive: true }` for scroll/touch listeners — prevents jank |

### 5. Re-render Optimization (MEDIUM)

Prevent unnecessary re-renders that waste CPU cycles and cause visual jank.

| Rule | Summary |
|------|---------|
| `rerender-no-inline-components` | Never define components inside other components — causes remount on every render |
| `rerender-memo` | Use `React.memo` for expensive components that receive stable props |
| `rerender-dependencies` | Stabilize `useMemo`/`useCallback` dependencies — avoid objects/arrays as deps |
| `rerender-derived-state` | Compute derived values inline — don't sync state with `useEffect` |
| `rerender-transitions` | Use `useTransition` for non-urgent state updates (search, filters, tabs) |
| `rerender-use-deferred-value` | Use `useDeferredValue` to deprioritize expensive child tree re-renders |
| `rerender-split-combined-hooks` | Split hooks that combine unrelated state — prevents cascading re-renders |

### 6. Rendering (MEDIUM)

Optimize the rendering pipeline itself.

| Rule | Summary |
|------|---------|
| `rendering-content-visibility` | Use CSS `content-visibility: auto` for off-screen sections |
| `rendering-hydration-no-flicker` | Avoid layout shifts during hydration — match server and client initial state |
| `rendering-conditional-render` | Use `display: none` or `hidden` for toggle UI — avoid mount/unmount cycles for persistent state |
| `rendering-resource-hints` | Add `preconnect`, `dns-prefetch` for known third-party origins |
| `rendering-activity` | Use React `<Activity>` (experimental) for keep-alive patterns |

### 7. JS Performance (LOW-MEDIUM)

Micro-optimizations that matter at scale.

| Rule | Summary |
|------|---------|
| `js-set-map-lookups` | Use `Set`/`Map` for frequent lookups instead of `Array.includes`/`find` |
| `js-early-exit` | Return early from functions to avoid unnecessary computation |
| `js-flatmap-filter` | Use `flatMap` to combine `map` + `filter` in a single pass |
| `js-batch-dom-css` | Batch DOM reads/writes — avoid interleaved read-write-read layout thrashing |

### 8. Advanced (LOW)

Niche patterns for specific scenarios.

| Rule | Summary |
|------|---------|
| `advanced-effect-event-deps` | Use `useEffectEvent` to remove unnecessary effect dependencies |
| `advanced-init-once` | Use module-level or `useRef` for one-time initialization — not `useState` + `useEffect` |

## Full Rule Details

See [rules.md](references/rules.md) for complete examples with non-compliant/compliant code patterns.
