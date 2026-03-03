# Anti-Slop Guardrails — Detecting AI-Generated Design Patterns

AI-generated UI designs exhibit recognizable patterns that make products feel generic, templated, and lifeless. This reference catalogs these patterns so reviewers can flag them during design fidelity checks. Findings use the `AESTH-SLOP` category prefix.

## What is "Design Slop"?

Design slop is the visual equivalent of AI-generated filler text — technically correct but aesthetically hollow. It occurs when an AI generates UI that:
- Follows structural rules without understanding visual intent
- Uses "safe" defaults that feel generic across every product
- Lacks the intentional asymmetry and personality that human designers apply
- Optimizes for looking "clean" rather than communicating brand identity

## Typography Slop

Flagged as `AESTH-SLOP-TYPO`.

### Red Flags

| Pattern | Why It's Slop | Better Alternative |
|---------|--------------|-------------------|
| Only Inter/Roboto/Arial with no typographic hierarchy | AI defaults to "safe" sans-serif without considering brand voice | Use the project's design system fonts; pair a display font with a body font |
| All headings same weight (everything is `font-semibold`) | No visual hierarchy — headings don't communicate importance | Use weight progression: h1=bold, h2=semibold, h3=medium, body=normal |
| No `letter-spacing` variation across scales | Display text, body text, and captions all use browser defaults | Display: tight (-0.025em), body: normal, caption: wide (0.025em) |
| System fonts used as a "design choice" | `system-ui, sans-serif` is a performance fallback, not a design decision | If using system fonts, do so intentionally and document the reasoning |
| Uniform `text-base` everywhere | One font size fits all — no scale relationship | Use a type scale (e.g., 12/14/16/18/20/24/30/36) with clear roles |
| No `leading` (line-height) variation | Tight text in paragraphs, loose text in headings — reversed from best practice | Headings: leading-tight (1.2), Body: leading-relaxed (1.6), UI: leading-normal (1.5) |

### Scoring

```
0 slop signals → Clean (no deduction)
1 signal       → Warn (note in findings, -0 points)
2 signals      → Minor (-2 from Typography Quality dimension)
3+ signals     → Major (-5 from Typography Quality dimension)
```

## Layout Slop

Flagged as `AESTH-SLOP-LAYOUT`.

### Red Flags

| Pattern | Why It's Slop | Better Alternative |
|---------|--------------|-------------------|
| Symmetrical 3-column grid on every section | The "AI landing page" pattern — features, testimonials, pricing all in identical grids | Vary column counts, use asymmetric layouts for visual interest |
| Uniform card sizes with identical padding | Everything in neat, identical boxes — no visual hierarchy | Vary card sizes to emphasize primary content; use featured/hero cards |
| No visual anchor — every element competes equally | Without a focal point, users scan randomly instead of following intent | Establish one dominant element per viewport (hero, feature highlight) |
| 12px/16px/24px monotonous spacing | Same rhythm everywhere — no tension or grouping | Use a spacing scale with intentional variation (8/12/16/24/32/48/64) |
| Centered everything | All text and content centered, including paragraphs | Center headings and CTAs; left-align body text and lists |
| Identical section structure repeating | Hero → Features (3-col) → Testimonials (3-col) → CTA → Footer | Break the pattern: asymmetric feature sections, full-bleed images, alternating layouts |

### Scoring

```
0 slop signals → Clean (no deduction)
1 signal       → Warn (note in findings, -0 points)
2 signals      → Minor (-2 from Layout Personality dimension)
3+ signals     → Major (-5 from Layout Personality dimension)
```

## Color Slop

Flagged as `AESTH-SLOP-COLOR`.

### Red Flags

| Pattern | Why It's Slop | Better Alternative |
|---------|--------------|-------------------|
| Purple/blue gradient on white background | The "AI product" look — used by every generated landing page | Use the project's brand palette; gradients should serve a purpose |
| Arbitrary decorative colors with no semantic meaning | Random accent colors that don't map to actions or states | Every color should have a role: primary (action), destructive (danger), muted (secondary) |
| Every CTA is the same blue regardless of importance | No hierarchy between primary action, secondary action, and tertiary link | Primary: filled button, Secondary: outline, Tertiary: ghost/link |
| No color temperature variation | All cool (blues/purples) or all warm (oranges/reds) with no contrast | Mix warm accents with cool neutrals (or vice versa) for visual depth |
| Gradient used as decoration rather than function | Gradients on backgrounds, cards, buttons with no communicative purpose | Use gradients sparingly: hero sections, brand elements, or data visualization |
| Over-reliance on opacity for state changes | `bg-primary/90`, `bg-primary/80`, `bg-primary/70` — lazy state differentiation | Use distinct color steps from the palette (primary-dark, primary-light) |

### Scoring

```
0 slop signals → Clean (no deduction)
1 signal       → Warn (note in findings, -0 points)
2 signals      → Minor (-2 from Color Coherence dimension)
3+ signals     → Major (-5 from Color Coherence dimension)
```

## Interaction Slop

Flagged as `AESTH-SLOP-INTERACT`.

### Red Flags

| Pattern | Why It's Slop | Better Alternative |
|---------|--------------|-------------------|
| No hover states | Elements feel dead — no visual feedback on interaction | Every clickable element needs a hover state (minimum: color change) |
| `transition-all` on everything | Lazy animation — transitions properties that shouldn't animate (layout shifts) | Use specific properties: `transition-colors`, `transition-transform`, `transition-opacity` |
| Browser-default focus rings | Generic blue outline that clashes with design system | Custom focus ring using `ring-2 ring-ring ring-offset-2 outline-none` |
| Missing loading/empty/error states | Only the happy path is designed | Design all four core states (loading, error, empty, success) |
| Uniform transition duration | Everything at 200ms — no variation for interaction type | Hover: 100-150ms, active: 50-75ms, modals: 200ms, exits: 150ms |
| No `prefers-reduced-motion` handling | Animations play regardless of user preferences | Wrap non-essential animations in `motion-safe:` or `motion-reduce:` |

### Scoring

```
0 slop signals → Clean (no deduction)
1 signal       → Warn (note in findings, -0 points)
2 signals      → Minor (-2 from Micro-Interaction dimension)
3+ signals     → Major (-5 from Micro-Interaction dimension)
```

## Compound Slop Score

Aggregate scoring across all four categories. Used by the aesthetic-quality-reviewer agent.

```
Total slop signals counted across all categories:
  0-1  → SLOP_CLEAN     — No action needed
  2-4  → SLOP_MINOR     — Advisory notes, no blocking
  5-8  → SLOP_MODERATE  — Findings reported, deductions applied
  9+   → SLOP_SEVERE    — Major finding, blocks design approval
```

### Scoring Integration

The anti-slop score is factored into the aesthetic quality review as a **penalty** applied after dimensional scoring:

```
Final Aesthetic Score = (Weighted Dimensional Score) - (Slop Penalty)

Where Slop Penalty:
  SLOP_CLEAN    →  0 points
  SLOP_MINOR    →  0 points (advisory only)
  SLOP_MODERATE →  5 points
  SLOP_SEVERE   → 15 points
```

## Detection Algorithm

For reviewers and automated agents:

```
For each implemented component:
  1. SCAN typography
     - Check font-family diversity (> 1 font OR intentional single-font design system)
     - Check heading weight variation (at least 2 distinct weights)
     - Check letter-spacing usage (at least 1 non-default value)
     Count violations → typography_slop_count

  2. SCAN layout
     - Check for 3-column grid repetition (same layout in > 2 sections)
     - Check card size variation (at least 1 featured/hero variant)
     - Check spacing scale diversity (at least 4 distinct spacing values)
     Count violations → layout_slop_count

  3. SCAN color
     - Check for purple/blue gradient usage (flag if no brand justification)
     - Check CTA color hierarchy (primary vs secondary differentiation)
     - Check color temperature mix (warm + cool present)
     Count violations → color_slop_count

  4. SCAN interactions
     - Check hover state presence on clickable elements
     - Check for transition-all usage (should be < 20% of transitions)
     - Check focus ring customization (not browser default)
     - Check motion-reduce handling (prefers-reduced-motion respected)
     Count violations → interaction_slop_count

  5. AGGREGATE
     total = typography + layout + color + interaction
     Classify: CLEAN / MINOR / MODERATE / SEVERE
```

## Exceptions

Not every "slop signal" is actually slop. Document exceptions when they apply:

| Signal | Valid Exception |
|--------|---------------|
| Single font family | Design system explicitly uses one font (e.g., Vercel uses Geist exclusively) |
| 3-column grid | Content genuinely warrants equal-weight columns (comparison tables, pricing tiers) |
| Purple/blue gradient | Brand palette is purple/blue (documented in design tokens) |
| `transition-all` | Component has 4+ properties changing simultaneously (rare but valid) |
| No hover states | Touch-only mobile component (but desktop variant must have them) |

When an exception applies, note it as `AESTH-SLOP-EXEMPT` with the justification.

## Cross-References

- [design-system-rules.md](design-system-rules.md) — Design system conventions and personality
- [design-token-reference.md](design-token-reference.md) — Token values for color, spacing, typography
- [accessibility-patterns.md](accessibility-patterns.md) — Focus ring requirements (non-slop focus styling)
- [micro-design-protocol.md](micro-design-protocol.md) — Interactive state and transition specifications
