---
name: design-system-discovery
description: |
  Design system auto-detection — scans repository for installed component libraries,
  token systems, and variant frameworks to build a structured design-system-profile.yaml.
  Provides the discoverDesignSystem() algorithm used by devise, strive, and arc workflows.
  Trigger keywords: shadcn, shadcn/ui, untitled ui, radix ui, design system, design tokens,
  tailwind, css variables, cva, class-variance-authority, styled-components, tailwind v4,
  style-dictionary, token system, component library, design compliance, frontend stack,
  figma tokens, dark mode, ui library, component library detection, design system discovery.
user-invocable: false
disable-model-invocation: false
---

# Design System Discovery

Auto-detects the project's component library, token system, and variant framework.
Called by devise Phase 0.5 (pre-brainstorm), strive worker injection (Phase 1.5), and arc Phase 2.8 (semantic verification).

## Output

Writes `tmp/plans/{timestamp}/design-system-profile.yaml` (session-scoped, ephemeral).
Never writes to `.claude/` — that path is reserved for persistent echoes only.

## discoverDesignSystem(repoRoot, sessionCacheDir)

**Input**: `repoRoot` — repository root path; `sessionCacheDir` — caller-provided session-scoped temp directory (e.g. `tmp/plans/{timestamp}`)
**Output**: `design-system-profile.yaml` (written to `{sessionCacheDir}/`), profile object returned to caller

### Phase 0: Pre-flight

```
// sessionCacheDir is passed by caller (e.g. tmp/plans/{timestamp})
IF {sessionCacheDir}/design-system-profile.yaml EXISTS:
  RETURN cached profile  // Re-use within same session
ELSE:
  BEGIN tiered scan
```

### Phase 1: Tiered Scanning

Scanning proceeds in 3 tiers (Tier 0: root manifests, Tier 1: shallow scan, Tier 2: deep content scan). Each tier is only entered if the previous tier did not yield a conclusive match (confidence >= 0.90). Early exit saves time in well-configured projects.

See [tiered-scanning.md](references/tiered-scanning.md) for the full signal definitions, file lists, and weight assignments per tier.

### Phase 2–3: Signal Aggregation & Confidence

After all tiers, signals are grouped by category (library, token, variant) and confidence is computed using a weighted formula: `confidence = maxWeight * (matchedCount / totalSignals) ^ 0.3`, with a conclusive single-signal shortcut (weight == 1.0 → confidence = 1.0).

See [signal-aggregation.md](references/signal-aggregation.md) for the aggregation categories, confidence formula, worked examples, and threshold table.

**Winner selection**: The library with the highest confidence is `primary_library`.
If two libraries both exceed 0.50, include both (migration edge case — see §Edge Cases).

### Phase 4: Token System Resolution

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

### Phase 5: Variant System Resolution

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

### Phase 6: Component Inventory

```
Glob: {src/,}components/ui/*.tsx  (limit 50)
Glob: {src/,}components/**/*.tsx  (limit 100, exclude ui/ subdirectory)

components.path         = primary component directory
components.naming       = detect: PascalCase | kebab-case | snake_case
components.existing     = deduplicated list of component names (strip .tsx)
components.count        = len(components.existing)
```

### Phase 7: Ancillary Fields

```
accessibility.layer     = "radix" IF @radix-ui/* deps >= 3 ELSE "unknown"
class_merge.utility     = "cn" IF cn() from utils detected ELSE "clsx" IF clsx used ELSE "none"
class_merge.import      = resolved import path of utility
dark_mode.strategy      = "class" IF .dark { ... } in CSS ELSE "media" IF @media (prefers-color-scheme) ELSE "unknown"
dark_mode.class_name    = "dark" (default shadcn/ui) — read from components.json "darkMode" if present
tailwind.version        = "4" | "3" | null
tailwind.config_type    = "js" | "ts" | "css" (v4 inline) | null
tailwind.plugins        = list of tailwind plugins from config
path_alias              = "@" IF tsconfig.json contains "paths": {"@/*": ["./src/*"]} ELSE null
evidence_files          = list of all files that contributed a signal (deduplicated)
```

## Output Schema: design-system-profile.yaml

```yaml
# Written to: tmp/plans/{timestamp}/design-system-profile.yaml
# Generated by: discoverDesignSystem() — do not edit manually

library: shadcn_ui              # Primary library: shadcn_ui | untitled_ui | custom_design_system | unknown
library_version: "0.8.0"       # From components.json "style" or package.json version, null if unknown
confidence: 0.95               # 0.0–1.0 — see confidence formula above

tokens:
  format: tailwind-v4-theme    # tailwind-v4-theme | tailwind-v3-config | style-dictionary | css-variables | unknown
  source_file: app/globals.css # Relative path to token source
  semantic_colors:
    background: "oklch(1 0 0)"
    foreground: "oklch(0.145 0 0)"
    primary: "oklch(0.205 0 0)"
    # ... additional token values
  spacing_scale: []            # List of spacing values, empty if not detected
  border_radius_scale:
    default: "0.625rem"        # --radius from components.json or CSS
  shadow_scale: []             # List of shadow values, empty if not detected

variants:
  system: cva                  # cva | css-in-js | css-modules | unknown
  pattern: class-variance-authority

components:
  path: src/components/ui      # Primary component directory (relative)
  naming: PascalCase           # PascalCase | kebab-case | snake_case
  existing:                    # Discovered component names
    - Button
    - Card
    - Dialog
    - Input
  count: 4

accessibility:
  layer: radix                 # radix | unknown

class_merge:
  utility: cn                  # cn | clsx | none
  import: "@/lib/utils"

dark_mode:
  strategy: class              # class | media | unknown
  class_name: dark

tailwind:
  version: "4"                 # "4" | "3" | null
  config_type: css             # js | ts | css | null
  plugins: []                  # e.g., ["@tailwindcss/typography", "tailwindcss-animate"]

path_alias: "@"                # "@" | null
evidence_files:
  - package.json
  - components.json
  - app/globals.css
```

## Edge Cases

8 edge cases are handled: Monorepo (EC-1), Migration (EC-2), Custom-on-Radix (EC-3), Bare Tailwind (EC-4), Figma Code Connect (EC-5), Storybook-Only (EC-6), CSS Modules (EC-7), RSC (EC-8).

See [edge-cases.md](references/edge-cases.md) for detection criteria and handling rules for each case.

## discoverUIBuilder(sessionCacheDir, repoRoot)

**Input**: `sessionCacheDir` — caller-provided session-scoped temp directory; `repoRoot` — repository root path
**Output**: `builder-profile.yaml` (written to `{sessionCacheDir}/`), builder config object returned to caller or null

Discovers which UI builder MCP is available for the detected design system. Called after `discoverDesignSystem()` during devise Phase 0.5 and strive Phase 1.5.

5-step priority cascade: session cache → talisman binding (0.95) → project skill frontmatter (0.90) → plugin skill frontmatter (0.90) → known MCP registry + heuristic (0.50). First match wins.

See [ui-builder-discovery.md](references/ui-builder-discovery.md) for the full algorithm, `parseBuilderFrontmatter()`, known MCP registry, heuristic detection, and `builder-profile.yaml` output schema.

## Integration Points

### devise Phase 0.5 (Pre-Brainstorm)

```
profile = discoverDesignSystem(repoRoot, sessionCacheDir)
IF profile.confidence >= talisman.devise.design_system_discovery.confidence_threshold:
  INJECT profile summary into brainstorm context
  SET brainstorm_context.design_system = profile

// discoverUIBuilder() runs immediately after discoverDesignSystem()
uiBuilder = discoverUIBuilder(sessionCacheDir, repoRoot)
IF uiBuilder is not null:
  INJECT builder summary into brainstorm context
  SET brainstorm_context.ui_builder = uiBuilder
```

### strive Worker Injection (Phase 1.5)

See [strive worker-prompts.md](../strive/references/worker-prompts.md) for the
component constraint injection protocol.

Workers receive a trimmed profile (max `talisman.strive.frontend_component_context.max_profile_lines` lines).

### arc Phase 2.8 Semantic Verification

During semantic verification, the profile validates that implementation code:
- Uses the correct component import paths (`@/components/ui/*` for shadcn/ui)
- Applies the correct variant system (cva() calls, not ad-hoc className strings)
- Respects dark mode strategy (no hardcoded colors, only semantic tokens)

## Configuration

```yaml
# talisman.yml
devise:
  design_system_discovery:
    enabled: true                # Master switch (default: true)
    confidence_threshold: 0.5   # Min confidence to inject profile into context

strive:
  frontend_component_context:
    enabled: true                # Inject profile into strive worker prompts (default: true)
    max_profile_lines: 200       # Cap profile size before injection (default: 200)
    token_cap_lines: 50          # Cap token constraint section (default: 50)

stack_awareness:
  design_compliance: true        # Enable design-system-compliance-reviewer (default: true)
```

## Cross-References

- [stacks](../stacks/SKILL.md) — Stack detection; design system discovery is a sub-layer
- [frontend-design-patterns](../frontend-design-patterns/SKILL.md) — Implementation patterns using the discovered system
- [design-sync](../design-sync/SKILL.md) — Figma design synchronization workflow
- [strive](../strive/SKILL.md) — Worker prompt injection for component constraints
- [untitledui-mcp](../untitledui-mcp/SKILL.md) — Built-in UntitledUI builder skill with `builder-protocol` frontmatter (detected by `discoverUIBuilder()`)
