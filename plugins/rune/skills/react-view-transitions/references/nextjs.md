# View Transitions — Next.js Integration

## Enable View Transitions

Add the experimental flag in `next.config.js`:

```js
// next.config.js
/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: {
    viewTransition: true,
  },
}
```

## App Router Integration

### Layout-Level Transitions

Wrap page content in `<ViewTransition>` inside your layout:

```tsx
// app/layout.tsx
import { ViewTransition } from 'react'

export default function RootLayout({ children }) {
  return (
    <html>
      <body>
        <nav>{/* Navigation — persists across transitions */}</nav>
        <ViewTransition default="none" enter="fade-in" exit="fade-out">
          {children}
        </ViewTransition>
      </body>
    </html>
  )
}
```

### Page-Level Transitions

For page-specific animations:

```tsx
// app/photos/page.tsx
import { ViewTransition } from 'react'

export default function PhotosPage({ photos }) {
  return (
    <div className="grid">
      {photos.map(photo => (
        <ViewTransition key={photo.id} name={`photo-${photo.id}`}>
          <Link href={`/photos/${photo.id}`}>
            <img src={photo.thumb} />
          </Link>
        </ViewTransition>
      ))}
    </div>
  )
}

// app/photos/[id]/page.tsx
export default function PhotoDetail({ params }) {
  const photo = await getPhoto(params.id)
  return (
    <ViewTransition name={`photo-${photo.id}`}>
      <img src={photo.full} className="w-full" />
    </ViewTransition>
  )
}
```

### Directional Navigation

Use `addTransitionType` with `startTransition` for directional animations:

```tsx
'use client'
import { startTransition, addTransitionType } from 'react'
import { useRouter } from 'next/navigation'

function NavigationLink({ href, direction, children }) {
  const router = useRouter()

  function handleClick(e) {
    e.preventDefault()
    startTransition(() => {
      addTransitionType(direction) // 'forward' or 'back'
      router.push(href)
    })
  }

  return <a href={href} onClick={handleClick}>{children}</a>
}
```

### Loading States with Suspense

View Transitions integrate with Next.js loading states:

```tsx
// app/dashboard/loading.tsx
export default function DashboardLoading() {
  return <DashboardSkeleton />
}

// app/dashboard/page.tsx — ViewTransition animates the Suspense reveal
```

The `<ViewTransition>` wrapping the page in the layout automatically animates the transition from `loading.tsx` fallback to the actual page content.

## Server Components Compatibility

- `<ViewTransition>` works in both Server and Client Components
- `addTransitionType` requires a Client Component (uses `startTransition`)
- Shared element `name` props work across Server Component boundaries

## CSS Setup

Add view transition styles to your global CSS:

```css
/* app/globals.css */

/* Disable default browser crossfade — let React manage it */
::view-transition-old(root),
::view-transition-new(root) {
  animation: none;
}

/* Page transition animations */
.fade-in::view-transition-new(*) {
  animation: fade-in 200ms ease-in;
}

.fade-out::view-transition-old(*) {
  animation: fade-out 200ms ease-out;
}

/* Respect user preferences */
@media (prefers-reduced-motion: reduce) {
  ::view-transition-old(*),
  ::view-transition-new(*) {
    animation: none !important;
  }
}
```

## Limitations with Next.js

1. **`<Link>` prefetching**: Prefetched routes load instantly, which may make transitions too fast. Set `prefetch={false}` for routes where you want visible transitions.
2. **Route groups**: ViewTransition names must be unique across all mounted routes — shared names in different route groups can conflict.
3. **Parallel routes**: Each parallel slot can have its own ViewTransition. Coordinate naming carefully.
4. **Intercepting routes**: Modal-style intercepted routes work well with scale-in/out transitions. Use `presentation: 'modal'` naming convention.
