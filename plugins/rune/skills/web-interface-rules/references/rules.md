# Web Interface Rules — Detailed Examples

## 1. Accessibility

### `a11y-icon-buttons`

```html
<!-- NON-COMPLIANT: Screen reader announces nothing -->
<button><svg>...</svg></button>

<!-- COMPLIANT: Announces "Close dialog" -->
<button aria-label="Close dialog"><svg aria-hidden="true">...</svg></button>
```

### `a11y-semantic-html`

```html
<!-- NON-COMPLIANT: Divs with roles -->
<div role="navigation"><div role="main"><div role="complementary">

<!-- COMPLIANT: Semantic elements -->
<nav><main><aside>
```

### `a11y-skip-link`

```html
<!-- First focusable element in the page -->
<a href="#main-content" class="sr-only focus:not-sr-only">Skip to content</a>
<!-- ... navigation ... -->
<main id="main-content">
```

### `a11y-heading-hierarchy`

```html
<!-- NON-COMPLIANT: Skips h2 -->
<h1>Page Title</h1>
<h3>Section</h3>

<!-- COMPLIANT: Sequential -->
<h1>Page Title</h1>
<h2>Section</h2>
<h3>Subsection</h3>
```

### `a11y-aria-live`

```tsx
// Announce search results count to screen readers
<div aria-live="polite" aria-atomic="true">
  {results.length} results found
</div>
```

## 2. Focus States

### `focus-visible-ring`

```css
/* NON-COMPLIANT: Removes focus indicator entirely */
button:focus { outline: none; }

/* COMPLIANT: Keyboard-only visible focus ring */
button:focus-visible {
  outline: 2px solid var(--focus-ring);
  outline-offset: 2px;
}
```

### `focus-trap-modals`

```tsx
// COMPLIANT: Use inert on background content
function Modal({ isOpen, children }) {
  return (
    <>
      <div inert={isOpen || undefined}>{/* page content */}</div>
      {isOpen && <dialog open>{children}</dialog>}
    </>
  )
}
```

## 3. Forms

### `form-autocomplete`

```html
<!-- NON-COMPLIANT: No autocomplete hints -->
<input type="text" name="name" />
<input type="text" name="email" />

<!-- COMPLIANT: Browser can autofill -->
<input type="text" name="name" autocomplete="name" />
<input type="email" name="email" autocomplete="email" />
<input type="tel" name="phone" autocomplete="tel" inputmode="tel" />
```

### `form-never-block-paste`

```tsx
// NON-COMPLIANT: Blocks password managers
<input
  type="password"
  onPaste={(e) => e.preventDefault()} // ← NEVER do this
/>

// COMPLIANT: Allow paste on all inputs
<input type="password" />
```

### `form-unsaved-changes`

```tsx
// COMPLIANT: Warn on navigation
useEffect(() => {
  if (!isDirty) return
  const handler = (e: BeforeUnloadEvent) => {
    e.preventDefault()
    e.returnValue = '' // Required for Chrome
  }
  window.addEventListener('beforeunload', handler)
  return () => window.removeEventListener('beforeunload', handler)
}, [isDirty])
```

## 4. Animation

### `anim-reduced-motion`

```css
/* COMPLIANT: Respect user preference */
.fade-in {
  opacity: 0;
}

@media (prefers-reduced-motion: no-preference) {
  .fade-in {
    animation: fadeIn 300ms ease-out forwards;
  }
}

@media (prefers-reduced-motion: reduce) {
  .fade-in {
    opacity: 1; /* Skip animation, show immediately */
  }
}
```

### `anim-compositor-only`

```css
/* NON-COMPLIANT: Animates layout properties */
.expand {
  transition: width 300ms, height 300ms, padding 300ms;
}

/* COMPLIANT: Compositor-only properties */
.expand {
  transition: transform 300ms, opacity 300ms;
}
```

### `anim-no-transition-all`

```css
/* NON-COMPLIANT: Transitions everything including layout */
.card { transition: all 200ms; }

/* COMPLIANT: Explicit properties */
.card { transition: background-color 200ms, box-shadow 200ms; }
```

## 5. Typography

### `typo-tabular-nums`

```css
/* COMPLIANT: Numbers align in columns */
.price, .counter, .table-cell {
  font-variant-numeric: tabular-nums;
}
```

### `typo-text-wrap-balance`

```css
/* COMPLIANT: Even line lengths for headings */
h1, h2, h3 {
  text-wrap: balance;
}
```

## 6. Content Handling

### `content-min-w-0`

```css
/* NON-COMPLIANT: Text overflows flex container */
.flex-child { /* default min-width: auto */ }

/* COMPLIANT: Allows text truncation in flex children */
.flex-child { min-width: 0; }
```

### `content-empty-states`

```tsx
// COMPLIANT: Every data list has an empty state
function UserList({ users }) {
  if (users.length === 0) {
    return (
      <div className="text-center py-12">
        <p className="text-muted">No users found</p>
        <Button onClick={onInvite}>Invite someone</Button>
      </div>
    )
  }
  return <ul>{users.map(u => <UserItem key={u.id} user={u} />)}</ul>
}
```

## 7. Images

### `img-dimensions`

```html
<!-- NON-COMPLIANT: No dimensions — causes CLS -->
<img src="/photo.jpg" alt="Team photo" />

<!-- COMPLIANT: Explicit dimensions prevent layout shift -->
<img src="/photo.jpg" alt="Team photo" width="800" height="600" />

<!-- Also compliant: CSS aspect-ratio -->
<img src="/photo.jpg" alt="Team photo" style="aspect-ratio: 4/3; width: 100%;" />
```

## 8. Navigation & State

### `nav-url-reflects-state`

```tsx
// NON-COMPLIANT: State only in React
const [tab, setTab] = useState('overview')

// COMPLIANT: State in URL — shareable, bookmarkable
const searchParams = useSearchParams()
const tab = searchParams.get('tab') ?? 'overview'
function setTab(value: string) {
  const params = new URLSearchParams(searchParams)
  params.set('tab', value)
  router.push(`?${params}`)
}
```

### `nav-proper-links`

```tsx
// NON-COMPLIANT: Breaks right-click, cmd+click, screen readers
<div onClick={() => router.push('/settings')} className="link">
  Settings
</div>

// COMPLIANT: Proper link semantics
<Link href="/settings">Settings</Link>
```

## 9. Touch & Interaction

### `touch-manipulation`

```css
/* Eliminate 300ms tap delay on mobile */
button, a, [role="button"] {
  touch-action: manipulation;
}
```

### `touch-min-target`

```css
/* COMPLIANT: WCAG 2.5.8 minimum target size */
.icon-button {
  min-width: 44px;
  min-height: 44px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
```

## 10. Dark Mode

### `dark-color-scheme`

```css
/* COMPLIANT: Tells browser about supported color schemes */
:root { color-scheme: light dark; }
```

```html
<!-- COMPLIANT: Theme color adapts to color scheme -->
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)" />
<meta name="theme-color" content="#0a0a0a" media="(prefers-color-scheme: dark)" />
```

## 11. i18n

### `i18n-date-format`

```tsx
// NON-COMPLIANT: Hardcoded US format
const formatted = `${date.getMonth() + 1}/${date.getDate()}/${date.getFullYear()}`

// COMPLIANT: Locale-aware
const formatted = new Intl.DateTimeFormat(locale, {
  year: 'numeric', month: 'short', day: 'numeric'
}).format(date)
```

### `i18n-number-format`

```tsx
// NON-COMPLIANT: Hardcoded format
const price = `$${amount.toFixed(2)}`

// COMPLIANT: Locale-aware currency
const price = new Intl.NumberFormat(locale, {
  style: 'currency', currency: 'USD'
}).format(amount)
```

## 12. Hydration Safety

### `hydration-browser-apis`

```tsx
// NON-COMPLIANT: Server has no window
function Theme() {
  const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches
  return <div className={isDark ? 'dark' : 'light'} />
}

// COMPLIANT: Defer to client
function Theme() {
  const [isDark, setIsDark] = useState(false)
  useEffect(() => {
    setIsDark(window.matchMedia('(prefers-color-scheme: dark)').matches)
  }, [])
  return <div className={isDark ? 'dark' : 'light'} />
}
```

## 13. Anti-Patterns

### `anti-user-scalable-no`

```html
<!-- NON-COMPLIANT: Prevents zooming — WCAG violation -->
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no" />

<!-- COMPLIANT: Allow zooming -->
<meta name="viewport" content="width=device-width, initial-scale=1" />
```

### `anti-outline-none`

```css
/* NON-COMPLIANT: Removes focus indicator with no replacement */
*:focus { outline: none; }

/* COMPLIANT: Custom focus indicator */
*:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
}
```

### `anti-div-onclick`

```tsx
// NON-COMPLIANT: Not keyboard accessible, no role, no focus
<div onClick={handleClick}>Click me</div>

// COMPLIANT: Semantic, accessible, focusable
<button onClick={handleClick}>Click me</button>
```
