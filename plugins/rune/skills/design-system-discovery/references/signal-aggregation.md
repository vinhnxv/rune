# Signal Aggregation and Confidence Computation

## Phase 2: Signal Aggregation

After all tiers, group collected signals by category:

```
library_signals    = { shadcn_ui: [], untitled_ui: [], custom_design_system: [] }
token_signals      = { css_variables: [], tailwind_v4_theme: [], tailwind_v3_config: [], style_dictionary: [] }
variant_signals    = { cva: [], css_classes: [], styled_components: [] }
```

## Phase 3: Confidence Computation

**Step 1: Conclusive single-signal shortcut**

Before running the formula, check for conclusive signals (weight == 1.0):

```
IF any signal for a library has weight == 1.0:
  confidence = 1.0  // Skip formula; early-exit with high confidence
  RETURN confidence
```

**Step 2: Aggregated formula (no conclusive signal)**

```
matchedCount  = number of distinct signals that fired
totalSignals  = total possible signals for this library (see table below)
maxWeight     = highest individual signal weight that fired

confidence = maxWeight * (matchedCount / totalSignals) ^ 0.3

NaN guard: IF matchedCount == 0 OR totalSignals == 0:
  confidence = 0.0
```

Signal totals per library:

| Library                | totalSignals |
|------------------------|-------------|
| shadcn_ui              | 6           |
| untitled_ui            | 3           |
| custom_design_system   | 5           |

**Worked examples** (formula only — conclusive shortcut already handled):

| Scenario | matchedCount | totalSignals | maxWeight | confidence | Result |
|----------|-------------|--------------|-----------|------------|--------|
| components.json validated | conclusive shortcut | — | 1.0 | 1.0 | High |
| ui/ dir (3+ tsx) + cn() (no components.json) | 2 | 6 | 0.80 | 0.80 × (2/6)^0.3 ≈ 0.56 | Medium |
| ui/ dir only (no components.json, no cn()) | 1 | 6 | 0.60 | 0.60 × (1/6)^0.3 ≈ 0.35 | Low — do not include |
| package.json dep + ui/ dir + cn() | 3 | 6 | 0.85 | 0.85 × (3/6)^0.3 ≈ 0.67 | Medium |
| package.json dep + ui/ dir + cn() + Tier 2 imports | 4 | 6 | 0.85 | 0.85 × (4/6)^0.3 ≈ 0.74 | Medium-high |

**Confidence thresholds**:

| Confidence | Interpretation |
|------------|---------------|
| >= 0.90    | High — conclusive, single winner |
| 0.70–0.89  | Medium-high — likely match, include in profile |
| 0.50–0.69  | Medium — include with lower certainty |
| < 0.50     | Low — do not include as primary library |

**Winner selection**: The library with the highest confidence is `primary_library`.
If two libraries both exceed 0.50, include both (migration edge case — see edge-cases.md).

## Phase 4: Token System Resolution

```
IF tailwind_v4_theme signals fired:
  tokens.format = "tailwind-v4-theme"
  tokens.source_file = CSS file containing @theme block
ELSE IF tailwind_v3_config signals fired:
  tokens.format = "tailwind-v3-config"
  tokens.source_file = tailwind.config.{js,ts}
ELSE IF style_dictionary signals fired:
  tokens.format = "style-dictionary"
  tokens.source_file = tokens/ or design-tokens/ directory
ELSE IF css_variables signals fired:
  tokens.format = "css-variables"
  tokens.source_file = globals.css or app/globals.css
ELSE:
  tokens.format = "unknown"
  tokens.source_file = null
```

Extract token values from source_file if readable:
- `semantic_colors`: CSS variables named `--color-*`, `--background`, `--foreground`, `--primary`, `--secondary`, `--muted`, `--accent`, `--destructive`
- `spacing_scale`: CSS variables named `--spacing-*` or Tailwind `spacing` config values
- `border_radius_scale`: CSS variables `--radius-*` or Tailwind `borderRadius` config
- `shadow_scale`: CSS variables `--shadow-*` or Tailwind `boxShadow` config

## Phase 5: Variant System Resolution

```
IF cva signals fired:
  variants.system = "cva"
  variants.pattern = "class-variance-authority"
ELSE IF styled_components signals fired:
  variants.system = "css-in-js"
  variants.pattern = "styled-components"
ELSE IF css_classes signals fired:
  variants.system = "css-modules"
  variants.pattern = "css-modules"
ELSE:
  variants.system = "unknown"
  variants.pattern = null
```

## Phase 5.5: Domain Signal Aggregation

Domain inference uses a separate signal category with its own confidence formula.
Unlike library/token/variant signals (which use `maxWeight * (matchedCount / totalSignals) ^ 0.3`),
domain signals use proportional weighting: `confidence = sum(matched_weights) / sum(all_weights)`.

```
domain_signals = {
  keywords: { weight: 0.4 },   // File/directory name keyword matches
  routes:   { weight: 0.3 },   // URL route pattern matches
  deps:     { weight: 0.2 },   // Package dependency matches
  readme:   { weight: 0.1 }    // README.md phrase matches
}
```

**Confidence formula** (domain-specific):

```
matched_weights = sum of weights for sources that matched the winning domain
all_weights     = 0.4 + 0.3 + 0.2 + 0.1 = 1.0

confidence = matched_weights / all_weights
```

**Worked example — SaaS project with 3/4 signals**:

| Source | Weight | Matched? | Domain |
|--------|--------|----------|--------|
| keywords | 0.4 | Yes — "dashboard", "tenant", "subscription" found | saas |
| routes | 0.3 | Yes — /dashboard, /settings, /billing routes | saas |
| deps | 0.2 | No — no saas-specific deps | — |
| readme | 0.1 | Yes — "multi-tenant SaaS" in README | saas |

```
matched_weights = 0.4 + 0.3 + 0.0 + 0.1 = 0.8
confidence = 0.8 / 1.0 = 0.80
Result: domain = "saas", confidence = 0.80 (>= 0.70 threshold → accepted)
```

**Threshold**: >= 0.70 → domain used for downstream recommendations. < 0.70 → "general" fallback.

See [domain-inference.md](domain-inference.md) for the full algorithm, domain registry, signal maps, and edge cases.
