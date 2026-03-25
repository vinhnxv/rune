# Design Token Mapping — Color Snapping and Auto-Layout Conversion

Algorithms for mapping Figma design values to project design tokens and Tailwind utilities.

## Color Snapping Algorithm — Three-Layer Token Architecture

Map Figma fill/stroke colors to the nearest design system token using a three-layer
resolution cascade. Each layer adds semantic richness; the first match wins.

### Step 1: Extract Figma Color (Primitive Values)

```
Figma provides RGBA as floats [0.0, 1.0]:
  R: 0.267, G: 0.533, B: 0.933, A: 1.0
Convert to 8-bit:
  R: 68, G: 136, B: 238 → #4488EE
```

### Step 2: Three-Layer Token Resolution

Resolution proceeds through three layers. The first layer to produce a match
within snap distance wins. If no layer matches, the Tailwind palette fallback
(Step 3) applies.

#### Layer 1 — Primitive Tokens (Raw Design Values)

Raw color values extracted directly from Figma fills, strokes, and effects.
These are the unprocessed design values before any semantic mapping.

```
Source: Figma node properties (fills, strokes, effects)
Format: hex (#4488EE) or rgba(68, 136, 238, 1.0)
Usage:  Direct color values — no semantic meaning attached
```

#### Layer 2 — Semantic Tokens (Purpose Aliases)

Purpose-driven token names sourced from the project's design system profile.
Maps raw values to semantic roles like "brand-primary", "text-secondary",
"surface-elevated". Defined in `design-system-profile.yaml`.

```
Source: design-system-profile.yaml → semantic_tokens section
        CSS custom properties (globals.css, variables.css)
        Tailwind config (tailwind.config.js/ts → theme.colors)
        Token file (tokens.json, design-tokens.yaml)

Resolution:
  1. For each project token, convert token value to RGB
  2. Compute distance to the extracted Figma color:
       dist = sqrt((r1-r2)^2 + (g1-g2)^2 + (b1-b2)^2)
  3. If min_distance == 0 → exact match (use semantic token)
     If min_distance <= snap_distance (default: 20) → snap to nearest
     If min_distance > snap_distance → fall through to Layer 3

Example:
  Figma #7F56D9 → project token "brand-primary" (distance: 0)
  Result: bg-primary (shadcn) or bg-brand-solid (UntitledUI)
```

#### Layer 3 — Component Tokens (Library Adapter Maps)

Library-specific token mappings provided by the UI component library adapter.
These map design values to the library's own token vocabulary (e.g., UntitledUI
color scales, shadcn CSS variables).

```
Source: Library adapter maps (passed by caller, NOT read from YAML)
        Framework token maps ({framework}-token-map.yaml)

Resolution:
  1. For each library token, convert to RGB
  2. Compute distance to the extracted Figma color
  3. If min_distance <= snap_distance → use library token
     If min_distance > snap_distance → fall through to Tailwind fallback

Example:
  Figma #7F56D9 → library token "brand-600" (distance: 3.2)
  Result: bg-brand-600
```

### Step 3: Tailwind Palette Fallback

If no layer matches within snap distance, snap to the Tailwind default palette.
This preserves existing behavior as the final safety net.

```
22 color palettes: slate, gray, zinc, neutral, stone,
  red, orange, amber, yellow, lime, green, emerald, teal,
  cyan, sky, blue, indigo, violet, purple, fuchsia, pink, rose

Each palette has 11 shades: 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950

Total: 242 reference colors to snap against
```

### Resolution Summary

```
Input: Figma RGBA → #4488EE

Layer 1 (Primitive):  Raw hex value extracted               → always available
Layer 2 (Semantic):   project_tokens lookup (if provided)   → first match wins
Layer 3 (Component):  library_tokens lookup (if provided)   → second match wins
Fallback:             Tailwind palette snap                 → guaranteed result
```

### Snap Distance Reference

| Distance | Interpretation |
|----------|---------------|
| 0 | Exact match |
| 1-10 | Near-identical (rounding/antialiasing) |
| 11-20 | Close match (acceptable snap) |
| 21-40 | Visible difference (flag for review) |
| >40 | Different color (mark unmatched) |

## Auto-Layout to Flexbox Conversion

### Direction

| Figma | CSS | Tailwind |
|-------|-----|----------|
| HORIZONTAL | flex-direction: row | flex-row |
| VERTICAL | flex-direction: column | flex-col |
| WRAP (v5) | flex-wrap: wrap | flex-wrap |

### Alignment (Primary Axis)

| Figma | CSS | Tailwind |
|-------|-----|----------|
| MIN | justify-content: flex-start | justify-start |
| CENTER | justify-content: center | justify-center |
| MAX | justify-content: flex-end | justify-end |
| SPACE_BETWEEN | justify-content: space-between | justify-between |

### Alignment (Cross Axis)

| Figma | CSS | Tailwind |
|-------|-----|----------|
| MIN | align-items: flex-start | items-start |
| CENTER | align-items: center | items-center |
| MAX | align-items: flex-end | items-end |
| STRETCH | align-items: stretch | items-stretch |
| BASELINE | align-items: baseline | items-baseline |

### Spacing

| Figma Property | CSS | Tailwind Pattern |
|---------------|-----|-----------------|
| itemSpacing | gap | gap-{n} |
| paddingTop | padding-top | pt-{n} |
| paddingRight | padding-right | pr-{n} |
| paddingBottom | padding-bottom | pb-{n} |
| paddingLeft | padding-left | pl-{n} |
| Equal padding (all same) | padding | p-{n} |
| Symmetric (top=bottom, left=right) | padding | py-{n} px-{n} |

### Sizing

| Figma | Meaning | CSS | Tailwind |
|-------|---------|-----|----------|
| FIXED | Explicit dimension | width: {n}px | w-{n} or w-[{n}px] |
| FILL | Expand to fill parent | flex: 1 1 0% | flex-1 |
| HUG | Shrink to content | width: fit-content | w-fit |

## Typography Mapping

| Figma Property | CSS | Tailwind |
|---------------|-----|----------|
| fontFamily | font-family | font-{name} |
| fontSize (12) | font-size: 12px | text-xs |
| fontSize (14) | font-size: 14px | text-sm |
| fontSize (16) | font-size: 16px | text-base |
| fontSize (18) | font-size: 18px | text-lg |
| fontSize (20) | font-size: 20px | text-xl |
| fontSize (24) | font-size: 24px | text-2xl |
| fontWeight (400) | font-weight: 400 | font-normal |
| fontWeight (500) | font-weight: 500 | font-medium |
| fontWeight (600) | font-weight: 600 | font-semibold |
| fontWeight (700) | font-weight: 700 | font-bold |
| lineHeight (1.2) | line-height: 1.2 | leading-tight |
| lineHeight (1.5) | line-height: 1.5 | leading-normal |
| lineHeight (1.75) | line-height: 1.75 | leading-relaxed |

## Shadow Mapping

| Figma Effect | Tailwind |
|-------------|----------|
| No shadow | shadow-none |
| Blur 2-4, spread 0, offset 1-2 | shadow-sm |
| Blur 6-8, spread 0, offset 2-4 | shadow-md |
| Blur 10-15, spread 0, offset 4-6 | shadow-lg |
| Blur 20-25, spread 0, offset 8-10 | shadow-xl |
| Inner shadow | shadow-inner |

## Cross-References

- [vsm-spec.md](vsm-spec.md) — Where token mappings are recorded
- [phase1-design-extraction.md](phase1-design-extraction.md) — Extraction pipeline
