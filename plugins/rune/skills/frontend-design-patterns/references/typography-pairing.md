# Typography Pairing Reference — Proven Heading/Body Font Combinations

Curated font pairings for production frontend projects. All fonts listed are freely available on Google Fonts. Each pairing includes rationale, recommended context, and Tailwind CSS configuration.

## How to Use This Reference

1. **Identify your project context** (SaaS, editorial, creative, e-commerce, documentation)
2. **Select a pairing** from the context-specific recommendations or the full catalog
3. **Copy the Tailwind config** into your `tailwind.config.js` or `@theme` block
4. **Cross-reference** your `talisman.yml` `brand.typography` section if configured

## Context Recommendations

Quick lookup for common project types:

| Context | Recommended Pair | Heading | Body | Rationale |
|---------|-----------------|---------|------|-----------|
| SaaS / Dashboard | Inter / Inter | Inter | Inter | Neutral, highly legible at all sizes, excellent tabular figures for data-heavy UIs |
| Editorial / Blog | Playfair Display / Source Sans 3 | Playfair Display | Source Sans 3 | Serif/sans contrast creates visual hierarchy; Source Sans 3 optimized for long-form reading |
| Creative / Portfolio | Space Grotesk / DM Sans | Space Grotesk | DM Sans | Geometric personality in headings, clean geometric body text with generous x-height |
| E-commerce | Montserrat / Open Sans | Montserrat | Open Sans | Strong heading presence for product names, Open Sans is universally legible for descriptions and prices |
| Documentation | JetBrains Mono / IBM Plex Sans | JetBrains Mono | IBM Plex Sans | Monospace headings signal technical content, IBM Plex Sans has excellent readability and multilingual support |

## Full Pairing Catalog (16 pairings)

### 1. Inter / Inter (Single-Family)

- **Classification**: Sans-serif / Sans-serif
- **Rationale**: Variable font with dedicated optical sizes. Headings use tighter letter-spacing and heavier weights; body uses regular weight. Eliminates font-loading overhead by using a single family.
- **Best for**: SaaS dashboards, admin panels, data-heavy applications
- **x-height**: Tall (0.536 of cap height) — excellent screen readability

```js
// tailwind.config.js
fontFamily: {
  heading: ['"Inter"', 'system-ui', 'sans-serif'],
  body: ['"Inter"', 'system-ui', 'sans-serif'],
}
```

### 2. Playfair Display / Source Sans 3

- **Classification**: Serif (display) / Sans-serif (text)
- **Rationale**: High contrast between ornate serif headings and clean sans body. Playfair's large x-height pairs well with Source Sans 3's open letterforms.
- **Best for**: Editorial, blogs, content-heavy marketing sites
- **Style harmony**: Transitional serif meets humanist sans — both share open counters

```js
fontFamily: {
  heading: ['"Playfair Display"', 'Georgia', 'serif'],
  body: ['"Source Sans 3"', 'system-ui', 'sans-serif'],
}
```

### 3. Space Grotesk / DM Sans

- **Classification**: Sans-serif (geometric) / Sans-serif (geometric)
- **Rationale**: Both geometric but Space Grotesk has more personality through quirky letterforms (single-story 'a', curved 'y'). DM Sans provides a calmer reading experience for body text.
- **Best for**: Creative portfolios, design agencies, startup landing pages
- **Style harmony**: Shared geometric DNA with differentiated personality

```js
fontFamily: {
  heading: ['"Space Grotesk"', 'system-ui', 'sans-serif'],
  body: ['"DM Sans"', 'system-ui', 'sans-serif'],
}
```

### 4. Montserrat / Open Sans

- **Classification**: Sans-serif (geometric) / Sans-serif (humanist)
- **Rationale**: Montserrat's bold weights are commanding for product titles and CTAs. Open Sans is one of the most legible screen fonts, with neutral personality that doesn't compete with headings.
- **Best for**: E-commerce, product pages, marketing sites
- **x-height**: Both have tall x-heights for excellent scan-ability

```js
fontFamily: {
  heading: ['"Montserrat"', 'system-ui', 'sans-serif'],
  body: ['"Open Sans"', 'system-ui', 'sans-serif'],
}
```

### 5. JetBrains Mono / IBM Plex Sans

- **Classification**: Monospace / Sans-serif (humanist)
- **Rationale**: Monospace headings immediately signal technical/developer content. IBM Plex Sans provides excellent readability with extensive language support (100+ languages).
- **Best for**: Documentation sites, developer tools, technical blogs
- **Contrast**: Fixed-width vs proportional creates strong visual hierarchy

```js
fontFamily: {
  heading: ['"JetBrains Mono"', 'ui-monospace', 'monospace'],
  body: ['"IBM Plex Sans"', 'system-ui', 'sans-serif'],
}
```

### 6. Outfit / Nunito Sans

- **Classification**: Sans-serif (geometric) / Sans-serif (rounded humanist)
- **Rationale**: Outfit's clean geometry with rounded terminals pairs with Nunito Sans's warmth. Both are modern variable fonts with full weight ranges.
- **Best for**: Health/wellness apps, educational platforms, friendly SaaS
- **Style harmony**: Shared roundness and approachability

```js
fontFamily: {
  heading: ['"Outfit"', 'system-ui', 'sans-serif'],
  body: ['"Nunito Sans"', 'system-ui', 'sans-serif'],
}
```

### 7. Plus Jakarta Sans / Plus Jakarta Sans (Single-Family)

- **Classification**: Sans-serif (geometric-humanist hybrid)
- **Rationale**: Modern variable font with crisp geometry and subtle humanist touches. Bold weights are distinctive for headings while regular weight is highly legible. Single family keeps font loading fast.
- **Best for**: Fintech, modern SaaS, clean corporate sites
- **x-height**: Generous — designed specifically for screen interfaces

```js
fontFamily: {
  heading: ['"Plus Jakarta Sans"', 'system-ui', 'sans-serif'],
  body: ['"Plus Jakarta Sans"', 'system-ui', 'sans-serif'],
}
```

### 8. Fraunces / Commissioner

- **Classification**: Serif (display, variable) / Sans-serif (variable)
- **Rationale**: Fraunces is a "soft serif" with optical size and wonk axes, giving headings a distinctive editorial character. Commissioner's geometric clarity balances the heading personality.
- **Best for**: Magazine-style sites, brand storytelling, luxury products
- **Style harmony**: Both variable fonts with wide stylistic range

```js
fontFamily: {
  heading: ['"Fraunces"', 'Georgia', 'serif'],
  body: ['"Commissioner"', 'system-ui', 'sans-serif'],
}
```

### 9. Sora / Work Sans

- **Classification**: Sans-serif (geometric) / Sans-serif (grotesque)
- **Rationale**: Sora's precise geometry gives headings a tech-forward feel. Work Sans's slightly wider letterforms provide comfortable body text reading.
- **Best for**: Tech company sites, API documentation, developer platforms
- **x-height**: Both designed for screen-first readability

```js
fontFamily: {
  heading: ['"Sora"', 'system-ui', 'sans-serif'],
  body: ['"Work Sans"', 'system-ui', 'sans-serif'],
}
```

### 10. Libre Baskerville / Lato

- **Classification**: Serif (transitional) / Sans-serif (humanist)
- **Rationale**: Classic serif/sans contrast. Libre Baskerville's refined serifs bring authority to headings. Lato's semi-rounded details soften the formality for body text.
- **Best for**: Law firms, academic sites, institutional content
- **Contrast**: Traditional authority (serif) meets modern warmth (sans)

```js
fontFamily: {
  heading: ['"Libre Baskerville"', 'Georgia', 'serif'],
  body: ['"Lato"', 'system-ui', 'sans-serif'],
}
```

### 11. Manrope / Inter

- **Classification**: Sans-serif (geometric-grotesque) / Sans-serif (neo-grotesque)
- **Rationale**: Manrope's wider letterforms and distinctive character give headings visual weight. Inter provides a familiar, tested body text experience.
- **Best for**: Design system documentation, component libraries, Storybook sites
- **Style harmony**: Both designed for UI — Manrope for display, Inter for text

```js
fontFamily: {
  heading: ['"Manrope"', 'system-ui', 'sans-serif'],
  body: ['"Inter"', 'system-ui', 'sans-serif'],
}
```

### 12. Bitter / Source Sans 3

- **Classification**: Slab serif / Sans-serif (humanist)
- **Rationale**: Bitter's slab serifs are designed for screen reading and add tactile weight to headings. Source Sans 3 balances with clean, open body text.
- **Best for**: News sites, content platforms, recipe/lifestyle blogs
- **Contrast**: Slab serif weight vs clean sans — strong hierarchy

```js
fontFamily: {
  heading: ['"Bitter"', 'Georgia', 'serif'],
  body: ['"Source Sans 3"', 'system-ui', 'sans-serif'],
}
```

### 13. Figtree / Figtree (Single-Family)

- **Classification**: Sans-serif (geometric-friendly)
- **Rationale**: Designed by Erik Kennedy specifically for UI. Friendly geometric shapes with excellent legibility across all weights. Variable font with minimal file size.
- **Best for**: Startup products, mobile apps, onboarding flows
- **x-height**: Optimized for small sizes — great for mobile

```js
fontFamily: {
  heading: ['"Figtree"', 'system-ui', 'sans-serif'],
  body: ['"Figtree"', 'system-ui', 'sans-serif'],
}
```

### 14. Poppins / Roboto

- **Classification**: Sans-serif (geometric) / Sans-serif (neo-grotesque)
- **Rationale**: Poppins's perfectly circular letterforms create bold, eye-catching headings. Roboto's mechanical precision provides excellent body text readability at all sizes.
- **Best for**: Material Design projects, Android-first apps, general-purpose web
- **x-height**: Both have tall x-heights optimized for screens

```js
fontFamily: {
  heading: ['"Poppins"', 'system-ui', 'sans-serif'],
  body: ['"Roboto"', 'system-ui', 'sans-serif'],
}
```

### 15. DM Serif Display / DM Sans

- **Classification**: Serif (display) / Sans-serif (geometric)
- **Rationale**: From the same DM family — guaranteed visual harmony. DM Serif Display provides elegant, high-contrast headings while DM Sans keeps body text geometric and clean.
- **Best for**: Fashion, hospitality, upscale brands, event sites
- **Style harmony**: Same designer (Colophon Foundry) — shared proportions

```js
fontFamily: {
  heading: ['"DM Serif Display"', 'Georgia', 'serif'],
  body: ['"DM Sans"', 'system-ui', 'sans-serif'],
}
```

### 16. Geist / Geist Mono

- **Classification**: Sans-serif (neo-grotesque) / Monospace
- **Rationale**: Vercel's Geist family is purpose-built for developer interfaces. Sans for UI elements and prose, Mono for code blocks and technical data. Tight metrics reduce visual noise.
- **Best for**: Next.js apps, developer dashboards, Vercel-style projects
- **Note**: Available via `@vercel/font` or self-hosted — check Google Fonts availability before using CDN link

```js
fontFamily: {
  heading: ['"Geist"', 'system-ui', 'sans-serif'],
  body: ['"Geist"', 'system-ui', 'sans-serif'],
  mono: ['"Geist Mono"', 'ui-monospace', 'monospace'],
}
```

## Pairing Principles

When selecting or evaluating a font pair, consider these dimensions:

### Contrast

The heading and body fonts should differ enough to create visual hierarchy. Pairing two fonts that are too similar wastes a font load without adding distinction.

- **Strong contrast**: Serif heading + sans body (Playfair Display / Source Sans 3)
- **Moderate contrast**: Two different sans classifications (Space Grotesk / DM Sans)
- **Subtle contrast**: Same family, different weights (Inter / Inter)

### x-Height Compatibility

Fonts with similar x-heights appear proportionally harmonious when set side-by-side. Mismatched x-heights create visual jarring at the heading/body boundary.

### Style Harmony

Fonts from the same historical tradition or design philosophy pair naturally:
- **Geometric + geometric**: Space Grotesk / DM Sans
- **Humanist + humanist**: Source Sans 3 / Lato
- **Same foundry**: DM Serif Display / DM Sans (Colophon)

### Performance Budget

- **1 variable font** (single-family pair): ~30-60KB (best performance)
- **2 variable fonts**: ~60-120KB (acceptable)
- **2 static fonts, 4 weights each**: ~100-200KB (use `font-display: swap`)
- Target: total web font payload under 150KB

## Tailwind CSS v4 Integration

For Tailwind v4 projects using `@theme`:

```css
@import "tailwindcss";

@theme {
  --font-heading: "Playfair Display", Georgia, serif;
  --font-body: "Source Sans 3", system-ui, sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, monospace;
}
```

Usage in markup:

```html
<h1 class="font-heading text-4xl font-bold">Article Title</h1>
<p class="font-body text-base">Body text content...</p>
<code class="font-mono text-sm">const x = 42;</code>
```

## Talisman Configuration

When a project has `brand.typography` configured in `talisman.yml`, use those values as the primary source of truth:

```yaml
# .rune/talisman.yml
brand:
  typography:
    heading_font: "Playfair Display"
    body_font: "Source Sans 3"
    mono_font: "JetBrains Mono"
    scale: "modular"  # modular | linear
```

**Resolution order**: `talisman.yml` `brand.typography` > project's existing font config > this reference guide. If talisman specifies fonts, agents should use those exact fonts rather than recommending alternatives from this guide.
