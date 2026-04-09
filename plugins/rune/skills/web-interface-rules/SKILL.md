---
name: web-interface-rules
description: |
  Web interface quality rules — 100+ code-level UI/UX/accessibility rules
  across 15 categories. Covers accessibility (ARIA, semantic HTML, keyboard),
  forms (autocomplete, validation, paste), animation (reduced-motion, compositor),
  typography, performance (virtualization, layout reads), dark mode, i18n, and
  anti-patterns to flag. Based on Vercel Web Interface Guidelines.
  Trigger keywords: accessibility, a11y, ARIA, forms, animation, typography,
  dark mode, i18n, focus states, touch targets, web interface, UI quality.
user-invocable: false
disable-model-invocation: false
---

# Web Interface Rules

100+ code-level rules for building high-quality web interfaces. Every rule is actionable at the code level — not abstract principles but specific patterns to enforce and anti-patterns to flag.

## When This Loads

Auto-loaded by the Stacks context router when:
- Changed files touch `components/`, `pages/`, `views/`, `styles/`, or `ui/` directories
- Any frontend framework detected (React, Vue, Next.js, Svelte, Vite)
- Review/work/forge workflows involve UI implementation

## Rule Categories

### 1. Accessibility

Accessible interfaces are not optional. These rules prevent the most common WCAG failures.

- **`a11y-icon-buttons`**: Icon-only buttons MUST have `aria-label`. Screen readers announce nothing without it.
- **`a11y-semantic-html`**: Use `<nav>`, `<main>`, `<aside>`, `<article>`, `<section>` — not `<div>` with roles.
- **`a11y-skip-link`**: Add a skip-to-content link as the first focusable element for keyboard users.
- **`a11y-heading-hierarchy`**: Headings must follow sequential order (`h1` → `h2` → `h3`). Never skip levels.
- **`a11y-aria-live`**: Use `aria-live="polite"` for async content updates (toast notifications, search results).
- **`a11y-alt-text`**: Decorative images use `alt=""`. Informative images describe the content, not the element.
- **`a11y-color-contrast`**: Text must meet WCAG AA contrast ratios (4.5:1 normal, 3:1 large text).

### 2. Focus States

Visible focus indicators are a legal requirement (WCAG 2.4.7) and a usability necessity.

- **`focus-visible-ring`**: Every interactive element must have a visible focus indicator. Never `outline: none` without a replacement.
- **`focus-visible-over-focus`**: Use `:focus-visible` instead of `:focus` — shows ring for keyboard, hides for mouse.
- **`focus-within-group`**: Use `:focus-within` on container elements for group focus styling (dropdown menus, card actions).
- **`focus-trap-modals`**: Trap focus inside modals and dialogs. Use `inert` on background content.

### 3. Forms

Forms are where users give you their data. Respect their time.

- **`form-autocomplete`**: Set `autocomplete` attribute on all inputs (`name`, `email`, `tel`, `address-*`, `cc-*`).
- **`form-input-type`**: Use correct `type` (`email`, `tel`, `url`, `number`) and `inputmode` (`numeric`, `decimal`, `search`).
- **`form-never-block-paste`**: NEVER use `onPaste={e => e.preventDefault()}`. Users paste passwords, addresses, and codes.
- **`form-inline-errors`**: Show validation errors inline next to the field — not in alerts or toasts.
- **`form-unsaved-changes`**: Warn before navigating away from forms with unsaved changes (`beforeunload`).
- **`form-submit-feedback`**: Disable submit button and show loading state during async submission.

### 4. Animation

Animations should enhance, not obstruct. Always provide escape hatches.

- **`anim-reduced-motion`**: Wrap all animations in `@media (prefers-reduced-motion: no-preference)`. Provide static fallback.
- **`anim-compositor-only`**: Animate `transform` and `opacity` only — these run on the GPU compositor. Never animate `width`, `height`, `top`, `left`, `margin`, or `padding`.
- **`anim-no-transition-all`**: Never use `transition: all`. Specify exact properties: `transition: transform 200ms, opacity 200ms`.
- **`anim-interruptible`**: Animations triggered by user interaction must be interruptible — don't block input during transitions.
- **`anim-duration-reasonable`**: Keep transition durations between 150ms–400ms. Longer feels sluggish, shorter is jarring.

### 5. Typography

Text is the primary interface. Handle it with care.

- **`typo-ellipsis`**: Use `text-overflow: ellipsis` with `overflow: hidden` and `white-space: nowrap` for single-line truncation.
- **`typo-curly-quotes`**: Use `"` `"` `'` `'` (curly quotes) in visible text — not `"` `'` (straight quotes).
- **`typo-non-breaking-spaces`**: Use `&nbsp;` between numbers and units (`100&nbsp;kg`), and between short prepositions and following words.
- **`typo-tabular-nums`**: Use `font-variant-numeric: tabular-nums` for numbers in tables, prices, and countdowns.
- **`typo-text-wrap-balance`**: Use `text-wrap: balance` for headings and short text blocks to even out line lengths.

### 6. Content Handling

Content is unpredictable. Handle all lengths and states.

- **`content-overflow`**: Always plan for text overflow — use `truncate`, `line-clamp`, or `break-words` depending on context.
- **`content-empty-states`**: Every list, table, and search result needs an empty state — never show a blank area.
- **`content-min-w-0`**: Add `min-w-0` to flex children that contain text — prevents flex items from overflowing their container.
- **`content-skeleton-loading`**: Use skeleton screens for loading states — not spinners. Match the layout of the content that will load.

### 7. Images

Images are often the heaviest assets. Handle them explicitly.

- **`img-dimensions`**: Always set explicit `width` and `height` (or `aspect-ratio`) to prevent layout shifts (CLS).
- **`img-lazy-loading`**: Use `loading="lazy"` for below-fold images. Use `loading="eager"` or `fetchpriority="high"` for hero images.
- **`img-priority-hints`**: Use `fetchpriority="high"` for LCP images. Combine with `preload` for maximum impact.

### 8. Performance

Performance is a feature. These rules prevent the most common client-side bottlenecks.

- **`perf-virtualize`**: Virtualize lists/grids with >50 items. Use `react-window`, `@tanstack/virtual`, or framework equivalent.
- **`perf-no-layout-reads`**: Never read layout properties (`offsetHeight`, `getBoundingClientRect`) inside render or animation loops.
- **`perf-preconnect`**: Add `<link rel="preconnect">` for known third-party origins (fonts, analytics, CDNs).

### 9. Navigation & State

The URL is the user's bookmark. Respect it.

- **`nav-url-reflects-state`**: Filters, search queries, pagination, and tabs should be reflected in the URL.
- **`nav-proper-links`**: Use `<a>` or framework `<Link>` for navigation — never `<div onClick>` or `<span onClick>`.
- **`nav-deep-linking`**: Support deep linking to specific views, modals, and states via URL parameters or hash.
- **`nav-confirm-destructive`**: Require confirmation for destructive actions (delete, discard, reset). Use a dialog, not `window.confirm`.

### 10. Touch & Interaction

Touch interfaces have different constraints than mouse interfaces.

- **`touch-manipulation`**: Use `touch-action: manipulation` to eliminate 300ms tap delay on touch devices.
- **`touch-overscroll`**: Use `overscroll-behavior: contain` on scrollable containers to prevent scroll chaining.
- **`touch-min-target`**: Interactive elements must be at least 44×44px (WCAG 2.5.8).
- **`touch-drag-handling`**: Use `user-select: none` on drag handles. Restore selection on drop.

### 11. Safe Areas

Modern devices have notches, rounded corners, and dynamic islands.

- **`safe-area-insets`**: Use `env(safe-area-inset-*)` for fixed/sticky elements. Apply via `padding` or `margin`.
- **`safe-area-viewport`**: Use `viewport-fit=cover` in the viewport meta tag to enable safe area insets.

### 12. Dark Mode

Dark mode is expected. Ship it correctly.

- **`dark-color-scheme`**: Set `color-scheme: dark light` in CSS and `<meta name="color-scheme">` in HTML.
- **`dark-theme-color`**: Set `<meta name="theme-color">` with `media` attribute for both light and dark values.
- **`dark-native-selects`**: Native `<select>`, `<input>`, `<textarea>` inherit `color-scheme` — verify they look correct in both modes.

### 13. i18n

Internationalization is not just translation. Formats and layouts change too.

- **`i18n-date-format`**: Use `Intl.DateTimeFormat` — never hardcode date formats like `MM/DD/YYYY`.
- **`i18n-number-format`**: Use `Intl.NumberFormat` for currencies, percentages, and large numbers.
- **`i18n-translate-no`**: Use `translate="no"` on brand names, code snippets, and technical identifiers.
- **`i18n-dir-attribute`**: Support `dir="rtl"` for right-to-left languages. Use logical CSS properties (`margin-inline-start` over `margin-left`).

### 14. Hydration Safety

SSR/SSG hydration mismatches cause invisible bugs that are hard to track down.

- **`hydration-controlled-inputs`**: Controlled inputs must have the same initial value on server and client.
- **`hydration-date-time`**: Dates and times differ between server and client timezones. Use `suppressHydrationWarning` or defer to client.
- **`hydration-browser-apis`**: Guard `window`, `document`, `localStorage` access behind `useEffect` or `typeof window !== 'undefined'`.

### 15. Anti-Patterns (Flag These)

Patterns that must be flagged in code review — they indicate accessibility violations, usability bugs, or performance issues.

- **`anti-user-scalable-no`**: Flag `user-scalable=no` in viewport meta — prevents zooming for visually impaired users.
- **`anti-paste-prevention`**: Flag `onPaste={e => e.preventDefault()}` — blocks password managers and assistive tech.
- **`anti-outline-none`**: Flag `outline: none` or `outline: 0` without a visible replacement focus indicator.
- **`anti-div-onclick`**: Flag `<div onClick>` or `<span onClick>` for interactive elements — use `<button>` or `<a>`.
- **`anti-img-no-dimensions`**: Flag `<img>` without `width`/`height` or `aspect-ratio` — causes layout shifts.
- **`anti-autofocus-overuse`**: Flag `autoFocus` on elements that aren't the primary action — disrupts screen reader flow.

## Full Rule Details

See [rules.md](references/rules.md) for complete examples with non-compliant/compliant code patterns.
