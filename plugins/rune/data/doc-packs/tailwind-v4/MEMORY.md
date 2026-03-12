# Tailwind CSS v4 Doc Pack

## Etched — Tailwind v4: CSS-First Configuration (2026-03-11)

**Source**: `doc-pack:tailwind-v4@1.0.0`
**Category**: pattern

### Configuration Migration (v3 to v4)

- `tailwind.config.js` is replaced by CSS-based config in your main stylesheet
- Use `@theme` directive instead of `theme.extend` in JS config
- Use `@plugin` directive instead of `plugins: []` array in JS config
- Use `@source` directive instead of `content: []` array in JS config
- PostCSS plugin changes: `tailwindcss` replaces `@tailwindcss/postcss` v3

### CSS-First Config Example

```css
@import "tailwindcss";
@theme {
  --color-brand: #3b82f6;
  --font-display: "Inter", sans-serif;
  --breakpoint-3xl: 1920px;
}
```

### Key Differences from v3

- No more `@tailwind base/components/utilities` — single `@import "tailwindcss"` replaces all three
- `@apply` still works but CSS-native approach preferred: use `@theme` + custom properties
- JIT is the only mode — no AOT/safelist needed
- Arbitrary values `[color:red]` syntax unchanged

## Etched — Tailwind v4: New Color System (2026-03-11)

**Source**: `doc-pack:tailwind-v4@1.0.0`
**Category**: pattern

### OKLCH Color Space

- v4 defaults to OKLCH for generated color palettes — perceptually uniform
- Custom colors: use any CSS color format (`hex`, `rgb`, `hsl`, `oklch`)
- Opacity modifier still works: `bg-brand/50` for 50% opacity
- `currentColor` keyword works in theme: `--color-current: currentColor`

### Dark Mode

- `dark:` variant works the same as v3
- Prefer `@media (prefers-color-scheme: dark)` in `@theme` for token-level dark mode
- Class-based dark mode: add `@variant dark (&:where(.dark, .dark *))` in CSS

## Etched — Tailwind v4: Utility and Variant Changes (2026-03-11)

**Source**: `doc-pack:tailwind-v4@1.0.0`
**Category**: pattern

### New Utilities in v4

- `text-wrap-balance` — typographic balancing for headings
- `size-*` — sets both width and height simultaneously
- `field-sizing-content` — auto-resizing textareas without JS
- Container queries: `@container` / `@sm:` / `@md:` built-in (no plugin needed)

### Breaking Changes

- `ring-*` defaults changed: `ring` now uses `box-shadow` instead of outline
- `border-opacity-*`, `text-opacity-*` removed — use slash syntax: `border-black/50`
- `transform` utility removed — transforms are always applied when transform properties are set
- Renamed: `flex-grow` to `grow`, `flex-shrink` to `shrink` (v3 names still work as aliases)

### Migration Gotchas

- Check for `@tailwind` directives — must be replaced with `@import "tailwindcss"`
- Custom plugins using `addUtilities()` JS API need migration to CSS `@utility` directive
- `screens` config becomes `--breakpoint-*` theme variables
- `safelist` concept removed — use `@source` for explicit content paths
