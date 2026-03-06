# Web Interface Rules

Adapted from Vercel Web Interface Guidelines. Covers semantic HTML, keyboard accessibility, touch targets, responsive breakpoints, animation performance, reduced motion preferences, and color-blind safe palettes.

Each rule includes: ID, title, check instruction, code example, and WCAG level where applicable.

## Semantic HTML

| ID | Rule | Check Instruction | WCAG |
|----|------|-------------------|------|
| WIR-01 | Use semantic elements | Replace generic `<div>` wrappers with `<main>`, `<nav>`, `<header>`, `<footer>`, `<aside>`, `<section>`, `<article>` | 1.3.1 A |
| WIR-02 | Buttons for actions | Replace `<div onClick>` and `<span onClick>` with `<button>` | 4.1.2 A |
| WIR-03 | Links for navigation | Use `<a href>` for page navigation, not `<button>` with router.push | 2.1.1 A |
| WIR-04 | Heading hierarchy | Use `<h1>`-`<h6>` in order without skipping levels | 1.3.1 A |
| WIR-05 | Form labels | Every input has an associated `<label>` (htmlFor or wrapping) | 1.3.1 A |
| WIR-06 | Lists for lists | Use `<ul>`/`<ol>` for list content, not `<div>` repetitions | 1.3.1 A |
| WIR-07 | Tables for data | Use `<table>` with `<thead>`/`<tbody>`/`<th>` for tabular data | 1.3.1 A |

## Keyboard Accessibility

### Focus Management

| ID | Rule | Check Instruction | WCAG |
|----|------|-------------------|------|
| WIR-10 | Visible focus | All focusable elements have a visible focus indicator (`:focus-visible`) | 2.4.7 AA |
| WIR-11 | Focus order | Tab order follows visual reading order (no positive tabindex) | 2.4.3 A |
| WIR-12 | No focus traps | User can always Tab out of any component (except modals) | 2.1.2 A |
| WIR-13 | Focus restoration | After closing modal/dialog, focus returns to trigger element | 2.4.3 A |
| WIR-14 | Skip links | Large pages have "Skip to main content" link as first focusable element | 2.4.1 A |

### Keyboard Shortcuts

| ID | Rule | Check Instruction | WCAG |
|----|------|-------------------|------|
| WIR-15 | Escape to close | Modals, dropdowns, and overlays close on Escape key | 2.1.1 A |
| WIR-16 | Enter to activate | Buttons and links activate on Enter (native behavior preserved) | 2.1.1 A |
| WIR-17 | Arrow keys for groups | Tab groups, radio groups, and menus use arrow key navigation | 2.1.1 A |
| WIR-18 | No keyboard conflicts | Custom shortcuts do not override browser or OS defaults | -- |

### Tab Order Rules

```
Correct tab order:
1. Skip link → 2. Navigation → 3. Main content → 4. Sidebar → 5. Footer

Code signals to check:
- tabindex="0" only on non-interactive elements that need focus
- No tabindex > 0 (disrupts natural order)
- tabindex="-1" for programmatic focus only
- Role-based focus management for composite widgets
```

## Touch Targets

| ID | Rule | Size | Check Instruction | WCAG |
|----|------|------|-------------------|------|
| WIR-20 | Minimum touch target | 44x44px | Interactive elements (buttons, links, inputs) have at least 44px in both dimensions | 2.5.5 AAA |
| WIR-21 | Recommended touch target | 48x48px | Primary action buttons should be 48px for comfortable tapping | -- |
| WIR-22 | Touch target spacing | 8px minimum | Adjacent interactive elements have at least 8px gap to prevent mis-taps | 2.5.8 AA |
| WIR-23 | Inline link targets | Full text height | Links within text have sufficient line-height for tapping | -- |

### Touch Target Code Check

```
Check for:
- Buttons/links with padding < 10px (likely < 44px target)
- Icon-only buttons without sufficient padding
- Close/dismiss buttons that are tiny (< 32px is a violation)
- Checkbox/radio inputs without label wrapping (tiny native control)

Fix patterns:
- Add padding to reach 44px minimum
- Use min-height/min-width: 44px on interactive elements
- Wrap checkboxes/radios in clickable <label>
- Increase spacing between compact list actions
```

## Responsive Breakpoints

### Standard Breakpoints

| Name | Width | Target |
|------|-------|--------|
| xs | < 480px | Small phones |
| sm | >= 480px | Large phones |
| md | >= 768px | Tablets |
| lg | >= 1024px | Small desktops |
| xl | >= 1280px | Large desktops |
| 2xl | >= 1536px | Ultra-wide |

### Responsive Rules

| ID | Rule | Check Instruction |
|----|------|-------------------|
| WIR-30 | Mobile-first CSS | Media queries use `min-width` (mobile-first), not `max-width` |
| WIR-31 | No horizontal scroll | Content doesn't overflow horizontally at any breakpoint |
| WIR-32 | Readable text at all sizes | Font size >= 14px on mobile, line length <= 75 characters on desktop |
| WIR-33 | Responsive images | Images use `srcset`, `sizes`, or CSS `object-fit` |
| WIR-34 | Responsive navigation | Navigation adapts to mobile (hamburger, bottom nav, or drawer) |
| WIR-35 | Responsive tables | Tables use horizontal scroll or card layout on mobile |

### Content Reflow

```
At narrow viewpoints:
- Multi-column layouts collapse to single column
- Side-by-side buttons stack vertically
- Horizontal navigation becomes hamburger menu
- Table views switch to card/list views
- Long forms switch to single-column layout
```

## Animation Performance

### CSS vs JavaScript Animation

| Pattern | Use CSS | Use JavaScript |
|---------|---------|---------------|
| Simple transitions (opacity, transform) | Yes | No |
| Scroll-driven animations | Yes (scroll-timeline) | Intersection Observer |
| Complex choreography | No | Yes (WAAPI or requestAnimationFrame) |
| Spring physics | No | Yes (framer-motion, react-spring) |
| Layout animations (FLIP) | No | Yes |

### Performance Rules

| ID | Rule | Check Instruction |
|----|------|-------------------|
| WIR-40 | GPU-friendly properties | Animate only `transform` and `opacity` (avoid `width`, `height`, `top`, `left`) |
| WIR-41 | Will-change sparingly | Use `will-change` only on elements about to animate, remove after |
| WIR-42 | 60fps target | Animations should not cause frame drops (no layout thrashing in loops) |
| WIR-43 | Duration limits | UI transitions: 150-300ms. Complex animations: 300-500ms. Never > 1s for UI feedback |
| WIR-44 | Easing functions | Use ease-out for enter, ease-in for exit, ease-in-out for state changes |

## Reduced Motion

| ID | Rule | Check Instruction | WCAG |
|----|------|-------------------|------|
| WIR-50 | Respect prefers-reduced-motion | All animations have `prefers-reduced-motion: reduce` media query | 2.3.3 AAA |
| WIR-51 | Essential motion preserved | Reduced motion mode replaces animation with instant state change (not removal) | -- |
| WIR-52 | No auto-play animation | Auto-playing animations have pause/stop controls | 2.2.2 A |
| WIR-53 | No parallax by default | Parallax scrolling effects disabled in reduced-motion mode | 2.3.3 AAA |

### Reduced Motion Pattern

```css
/* Base: animated */
.element {
  transition: transform 300ms ease-out;
}

/* Reduced: instant */
@media (prefers-reduced-motion: reduce) {
  .element {
    transition: none;
  }
}
```

```js
// JavaScript detection
const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
```

## Color-Blind Safe Palettes

### Safe Color Combinations

| Purpose | Safe Colors | Avoid |
|---------|------------|-------|
| Status indicators | Blue + Orange + Gray | Red vs Green alone |
| Data visualization | Blue, Orange, Teal, Purple, Gray | Red/Green pairs |
| Error vs Success | Red + icon vs Green + icon | Color-only difference |
| Links | Underline + color change | Color-only (especially blue on blue) |

### Pattern Supplements

```
Always pair color with at least one of:
- Shape (checkmark for success, X for error, triangle for warning)
- Text label ("Success", "Error", "Warning")
- Pattern or texture (striped, dotted for charts)
- Position (error messages positioned near the field, not just colored)
```

### Color Vision Deficiency Statistics

```
Affect ~8% of males, ~0.5% of females:
- Deuteranomaly (most common): reduced green sensitivity
- Protanomaly: reduced red sensitivity
- Tritanomaly (rare): reduced blue sensitivity
- Monochromacy (very rare): no color vision

Test tools: Chrome DevTools > Rendering > Emulate vision deficiency
```
