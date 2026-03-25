# Semantic Token Resolver — Figma to Framework Token Mapping

Maps Figma design tokens to framework-specific semantic token names. Goes beyond raw Tailwind palette snapping (which maps `#7F56D9` to `purple-600`) to produce framework-native semantic references (`bg-brand-solid` for UntitledUI, `bg-primary` for shadcn).

## Three-Layer Token Architecture

The resolver operates within a three-layer token architecture that separates
concerns from raw values to framework-specific tokens:

| Layer | Name | Source | Purpose |
|-------|------|--------|---------|
| 1 | **Primitive** | Figma node properties | Raw design values (hex, rgba) |
| 2 | **Semantic** | `design-system-profile.yaml`, project tokens | Purpose aliases (brand-primary, surface-elevated) |
| 3 | **Component** | Library adapter maps | Framework-native tokens (bg-primary, bg-brand-solid) |
| — | **Fallback** | Tailwind default palette | Safety net when no layer matches |

This resolver primarily operates at **Layer 3** (Component), consuming Layer 1
primitive values and Layer 2 semantic context to produce framework-native output.
The `build_token_mapping()` function in `style_builder.py` accepts `project_tokens`
(Layer 2) and `library_tokens` (Layer 3) as optional parameters, keeping the
resolution pipeline pure and caller-driven.

See [design-token-mapping.md](../../design-sync/references/design-token-mapping.md) for
the full three-layer algorithm specification.

## Resolution Algorithm

The resolver uses a 4-step cascade. First match wins. Steps 1-3 correspond to
Layer 2 (Semantic) and Layer 3 (Component) token lookups; step 4 is the
Tailwind palette fallback.

```
Input:  Figma color value (hex/rgba), Figma style name (optional),
        design-system-profile.yaml (detected framework + token source),
        project_tokens (Layer 2 — optional, passed by caller),
        library_tokens (Layer 3 — optional, passed by caller)
Output: Framework-specific semantic token name

Resolution order:

1. EXACT MATCH — Figma color value matches a token definition exactly
   - Check project_tokens (Layer 2) first, then library_tokens (Layer 3)
   - shadcn: parse globals.css :root and :dark blocks for oklch values
   - UntitledUI: parse theme.css @theme block for RGB/oklch values
   - Compare in the token's native color space (no conversion needed)
   - Result: direct semantic token name (e.g., "bg-primary")

2. SEMANTIC MATCH — Figma style name matches a token mapping
   - Uses framework token maps (shadcn-token-map.yaml, untitled-ui-token-map.yaml)
   - Figma style "Brand/Primary" → "bg-primary" (shadcn) or "bg-brand-solid" (UntitledUI)
   - Normalizes Figma style names: strip library prefix, lowercase, "/" as separator
   - Result: mapped semantic token name

3. CLOSEST MATCH — Within snap distance threshold
   - Check project_tokens (Layer 2) first, then library_tokens (Layer 3)
   - Find the nearest semantic token by color distance
   - shadcn (oklch): use Delta-E (CIE 2000) metric — NOT RGB Euclidean distance
   - UntitledUI (oklch/rgb): use Delta-E (CIE 2000) for oklch tokens, RGB distance for legacy
   - generic (hex/hsl): use RGB Euclidean distance as fallback
   - Only accept if distance < snap_threshold (configurable)
   - Result: nearest semantic token name

4. PALETTE FALLBACK — No semantic match found
   - Snap to nearest Tailwind palette color (current default behavior)
   - Result: raw Tailwind class (e.g., "bg-purple-600")
   - Flag as "unresolved" for design-system-compliance-reviewer
```

### Why Delta-E (CIE 2000) for oklch

RGB Euclidean distance is perceptually non-uniform: two colors that appear very different to the human eye can have small RGB distances, and vice versa. shadcn v2 uses oklch color format, which is designed for perceptual uniformity. Delta-E (CIE 2000) is the standard perceptual color difference metric that accounts for:

- Lightness sensitivity variations across the range
- Chroma-dependent hue weighting
- The parametric correction factors (k_L, k_C, k_H)

```
Delta-E calculation (CIE 2000):
  Input:  two oklch colors (L, C, h)
  1. Convert oklch → CIELAB (L*, a*, b*)
  2. Compute Delta-L', Delta-C', Delta-H'
  3. Apply rotation term R_T for blue-purple region correction
  4. Compute: sqrt( (DL'/k_L*S_L)^2 + (DC'/k_C*S_C)^2 + (DH'/k_H*S_H)^2 + R_T*(DC'/k_C*S_C)*(DH'/k_H*S_H) )

  Thresholds:
    < 1.0  — imperceptible difference (exact match)
    < 3.0  — barely perceptible (safe snap)
    < 5.0  — noticeable but acceptable (snap with warning)
    >= 5.0 — clearly different (do not snap, fall through to palette)
```

### Snap Distance Configuration

```yaml
# In design-system-profile.yaml or talisman.yml
token_resolver:
  snap_threshold:
    delta_e: 3.0          # CIE 2000 threshold for oklch (default: 3.0)
    rgb_distance: 20      # Euclidean RGB threshold for hex/hsl (default: 20)
  warn_threshold:
    delta_e: 5.0          # Warn but still snap for oklch (default: 5.0)
    rgb_distance: 35      # Warn but still snap for hex/hsl (default: 35)
  palette_fallback: true  # Enable Tailwind palette fallback (default: true)
```

## Framework Token Maps

Separate YAML files map Figma design intents to framework-specific token names. These files are stored alongside the resolver spec.

### Token Map Structure

```yaml
# {framework}-token-map.yaml
schema: "rune-token-map/v1"
framework: "shadcn | untitled-ui | generic"
version: "2.0"

# Maps Figma intent → framework CSS class
semantic_mapping:
  "figma/intent/path": "framework-class-name"

# Maps Figma color style name patterns to intents
style_patterns:
  - pattern: "Brand/*"
    intent_prefix: "bg/brand"
  - pattern: "Neutral/*"
    intent_prefix: "bg/neutral"
```

### shadcn Token Map (summary)

Maps ~25 Figma intents to shadcn token classes:

| Category | Figma Intent | shadcn Token |
|----------|-------------|--------------|
| Text | `text/primary` | `text-foreground` |
| Text | `text/secondary` | `text-muted-foreground` |
| Text | `text/brand` | `text-primary` |
| Text | `text/error` | `text-destructive` |
| Background | `bg/primary` | `bg-background` |
| Background | `bg/secondary` | `bg-secondary` |
| Background | `bg/brand` | `bg-primary` |
| Background | `bg/muted` | `bg-muted` |
| Background | `bg/error` | `bg-destructive` |
| Border | `border/default` | `border-border` |
| Border | `border/brand` | `border-primary` |
| Border | `border/error` | `border-destructive` |

Full mapping: [shadcn-token-map.yaml](profiles/shadcn-token-map.yaml)

### UntitledUI Token Map (summary)

Maps 40+ Figma intents with deeper semantic depth:

| Category | Figma Intent | UntitledUI Token |
|----------|-------------|-----------------|
| Text | `text/primary` | `text-primary` |
| Text | `text/secondary` | `text-secondary` |
| Text | `text/tertiary` | `text-tertiary` |
| Text | `text/brand/primary` | `text-brand-primary` |
| Text | `text/error` | `text-error-primary` |
| Text | `text/disabled` | `text-disabled` |
| Background | `bg/primary` | `bg-primary` |
| Background | `bg/brand` | `bg-brand-solid` |
| Background | `bg/error` | `bg-error-primary` |
| Foreground | `fg/primary` | `fg-primary` |
| Foreground | `fg/brand` | `fg-brand-secondary` |
| Border | `border/default` | `border-primary` |
| Border | `border/brand` | `border-brand` |
| Border | `border/error` | `border-error` |

Full mapping: [untitled-ui-token-map.yaml](profiles/untitled-ui-token-map.yaml)

## Integration with figma-to-react MCP

The token resolver runs as a **post-processing step** in the design-sync pipeline:

```
figma-to-react MCP output    →    Token Resolver    →    Final code
(raw Tailwind classes)             (semantic swap)        (framework tokens)

Pipeline position:
1. figma_to_react() generates React + Tailwind code
2. Token resolver post-processes the output:
   a. Parse generated className strings
   b. For each color/bg/border/text class:
      - Extract the Tailwind class (e.g., "bg-purple-600")
      - Reverse-lookup: Tailwind class → hex value
      - Run resolution algorithm against framework token map
      - Replace with semantic token if match found
   c. Reassemble className strings
3. Write post-processed code to disk
```

### Post-Processing Example

```
Before (figma-to-react output):
  <button className="bg-[#7F56D9] text-white px-4 py-2 rounded-lg">

After (shadcn token resolution):
  <button className="bg-primary text-primary-foreground px-4 py-2 rounded-lg">

After (UntitledUI token resolution):
  <button className="bg-brand-solid text-white px-4 py-2 rounded-lg">
```

### Handling Arbitrary Values

When figma-to-react emits arbitrary Tailwind values (e.g., `bg-[#7F56D9]`), the resolver:

1. Extracts the hex value from the bracket notation
2. Runs the 4-step resolution cascade
3. Replaces with semantic token if resolved
4. Keeps the arbitrary value if unresolved (flagged for review)

## Resolution Logging

Every resolution decision is logged for audit:

```json
{
  "input": "#7F56D9",
  "figma_style": "Brand/Primary",
  "resolution_step": "SEMANTIC_MATCH",
  "output": "bg-primary",
  "distance": null,
  "framework": "shadcn",
  "confidence": "high"
}
```

```json
{
  "input": "#8B5CF6",
  "figma_style": null,
  "resolution_step": "CLOSEST_MATCH",
  "output": "bg-primary",
  "distance": { "metric": "delta_e_2000", "value": 2.3 },
  "framework": "shadcn",
  "confidence": "medium"
}
```

```json
{
  "input": "#FF6B35",
  "figma_style": null,
  "resolution_step": "PALETTE_FALLBACK",
  "output": "bg-orange-500",
  "distance": { "metric": "rgb_euclidean", "value": 42 },
  "framework": "shadcn",
  "confidence": "low",
  "flagged": true
}
```

## Error Handling

| Failure Mode | Fallback |
|-------------|----------|
| Token map file missing | Fall through to PALETTE_FALLBACK for all colors |
| design-system-profile.yaml missing | Use generic resolution (RGB distance only) |
| CSS/theme file unparseable | Skip EXACT_MATCH step, continue with SEMANTIC_MATCH |
| oklch conversion failure | Fall back to RGB distance for that color |
| All steps fail | Keep original figma-to-react output, flag for manual review |

## Cross-References

- [component-registry-spec.md](component-registry-spec.md) — Registry tokens boundary that resolver must satisfy
- [design-token-reference.md](design-token-reference.md) — Figma to CSS/Tailwind mapping fundamentals
- [design-system-rules.md](design-system-rules.md) — Token constraints and enforcement rules
- [framework-codegen-profiles.md](framework-codegen-profiles.md) — Framework-specific code generation rules
