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

Scanning proceeds in tiers. Each tier is only entered if the previous tier did not yield a
conclusive match (confidence >= 0.90). Early exit saves time in well-configured projects.

#### Tier 0 — Root Manifests (target: ~2 tool calls)

Read these files if present (Read() only — no Bash, no filesystem walk):

```
package.json         → scan dependencies + devDependencies
package-lock.json    → detect lock-file format (v2/v3 → npm >=7)
yarn.lock            → yarn presence signal
pnpm-lock.yaml       → pnpm presence signal
bun.lockb            → bun presence signal
tailwind.config.js   → tailwind v3 config
tailwind.config.ts   → tailwind v3 config (TS variant)
postcss.config.js    → postcss plugins (tailwindcss, autoprefixer)
components.json      → shadcn/ui canonical marker (HIGHEST PRIORITY)
```

Signals from Tier 0:
- `components.json` present AND (`$schema` matches shadcn/ui OR `style` field is `"default"` OR `"new-york"` OR `aliases.ui` field exists OR `aliases.components` field exists) → `shadcn_ui` signal (weight: 1.0, conclusive alone). Without at least one of those schema markers, treat components.json as ambiguous (weight: 0.50).
- `@shadcn/ui` or `shadcn-ui` in package.json deps → `shadcn_ui` signal (weight: 0.85)
- `@untitled-ui/*` in package.json deps → `untitled_ui` signal (weight: 1.0, conclusive alone)
- `tailwindcss` in deps with version `^4.*` → `tailwind_v4_theme` token signal
- `tailwindcss` in deps with version `^3.*` → `tailwind_v3_config` token signal
- `class-variance-authority` or `cva` in deps → `cva` variant signal
- `styled-components` in deps → `styled_components` variant signal
- `@emotion/styled` in deps → `styled_components` variant signal (direct CSS-in-JS authoring)
- `@emotion/react` in deps (without `@emotion/styled`) → `css_in_js_transitive` note only; do NOT assign `styled_components` signal (transitive peer dep, not authoring pattern)
- `style-dictionary` in deps → `style_dictionary` token signal
- `@radix-ui/*` packages count → if >=3 → `custom_design_system` signal (weight: 0.6)

#### Tier 1 — Shallow Scan (target: ~5 tool calls)

Read these files and directories (Read() only, no recursive walk):

```
src/lib/utils.ts          → shadcn/ui canonical cn() utility location
src/components/ui/        → list directory (Glob: src/components/ui/*.tsx)
components/ui/            → list directory (Glob: components/ui/*.tsx)
app/globals.css           → CSS variable declarations, @layer base
styles/globals.css        → CSS variable declarations
globals.css               → CSS variable declarations
src/index.css             → Tailwind v4 @import "tailwindcss" detection
app/layout.tsx            → className patterns, font loading
src/styles/tokens/        → style-dictionary output directory
tokens/                   → design token source
design-tokens/            → design token source (alternate naming)
```

Signals from Tier 1:
- `src/components/ui/` exists with >=3 .tsx files → `shadcn_ui` signal (weight: 0.60 max when no components.json confirmed). Upgrade to 0.90 ONLY if `cn()` from `@/lib/utils` is also detected (see next bullet).
- `components/ui/` exists with >=3 .tsx files → `shadcn_ui` signal (weight: 0.55 max when no components.json confirmed). Upgrade to 0.85 if `cn()` from `@/lib/utils` is also detected.
- `cn()` import from `@/lib/utils` in any scanned file → `shadcn_ui` signal (weight: 0.80, and upgrades ui/ directory weight as noted above)
- CSS file contains `--background:`, `--foreground:`, `--primary:` variables → `css_variables` token signal
- CSS file contains `@layer base { :root {` → `css_variables` token signal (weight: 0.90)
- `@import "tailwindcss"` in CSS → `tailwind_v4_theme` token signal (v4 marker)
- `@theme {` block in CSS → `tailwind_v4_theme` token signal (v4 inline tokens)
- `tokens/` or `design-tokens/` directory exists → `style_dictionary` token signal (weight: 0.70)
- `@untitled-ui/icons-react` import anywhere → `untitled_ui` signal (weight: 0.95)

#### Tier 2 — Deep Content Scan (target: ~20 tool calls)

Only entered when Tier 0 + Tier 1 did not yield conclusive match (confidence < 0.60).
Read up to 10 source files matching `**/*.{tsx,ts,css}` (excluding node_modules, .next, dist).

```
Glob: src/**/*.tsx (limit 10 files by mtime, newest first)
Glob: src/**/*.css (limit 5 files)
Glob: src/components/**/*.ts (limit 5 files)
```

Signals from Tier 2:
- Import of `Button`, `Card`, `Dialog` etc. from `@/components/ui/*` → `shadcn_ui` signal (weight: 0.75)
- `cva(` call pattern in source → `cva` variant signal
- CSS custom property usage `var(--color-*)` → `css_variables` token signal
- `StyleSheet.create` or template literals with CSS → `styled_components` variant signal
- `tw\`...\`` or `twMerge(` calls → `tailwind_v3_config` or `tailwind_v4_theme` token signal
- Figma token imports or `figma.variables` references → `style_dictionary` token signal
- Storybook story files (`*.stories.tsx`) count >= 5 → `storybook_only` edge case signal

### Phase 2: Signal Aggregation

After all tiers, group collected signals by category:

```
library_signals    = { shadcn_ui: [], untitled_ui: [], custom_design_system: [] }
token_signals      = { css_variables: [], tailwind_v4_theme: [], tailwind_v3_config: [], style_dictionary: [] }
variant_signals    = { cva: [], css_classes: [], styled_components: [] }
```

### Phase 3: Confidence Computation

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

### EC-1: Monorepo

**Detection**: Multiple `package.json` at depth 2 (e.g., `apps/web/package.json`, `packages/ui/package.json`).

**Handling**:
- Scan each `package.json` independently
- Use the workspace that contains the most frontend dependencies as primary
- Set `monorepo: true` and `workspace_root: apps/web` in profile
- Component paths are relative to the detected workspace root

**Known failure modes**:
- **No clear primary workspace**: If two workspaces tie on frontend dep count, pick the one containing `next.config.*` or `vite.config.*`. If still ambiguous, pick alphabetically first and set `monorepo_ambiguous: true` in profile.
- **Shared component package** (`packages/ui/`): Components may live in a sibling package, not the app workspace. If no ui/ directory found under primary workspace, also scan `packages/ui/` and `packages/design-system/` and merge signals.
- **Workspace-specific tailwind**: Each workspace may have its own `tailwind.config.*`. Use the config from the detected primary workspace; note others in `evidence_files`.
- **Glob depth limit**: Do not traverse deeper than depth 3 for `package.json` discovery — avoid scanning `node_modules` nested packages.

### EC-2: Migration (Two Design Systems Coexist)

**Detection**: Two distinct library signals both exceed 0.50 confidence.

**Handling**:
- Set `library` to the higher-confidence system
- Set `migrating_from` to the lower-confidence system
- Add `migration: true` flag in profile
- Workers should prefer the primary library for new components, note legacy components

### EC-3: Custom-on-Radix (No shadcn/ui, Direct Radix Usage)

**Detection**: `@radix-ui/*` count >= 5 in package.json, but `components.json` absent, and shadcn confidence < 0.60.

**Handling**:
- Set `library: custom_design_system`
- Set `accessibility.layer: radix`
- Confidence set to `custom_design_system` score (typically 0.60–0.75)
- Note in profile: "Custom component library built on Radix UI primitives"

### EC-4: Bare Tailwind (No Component Library)

**Detection**: `tailwindcss` present, no library signals above 0.50.

**Handling**:
- Set `library: unknown`
- Set `confidence: 0.05` for library (distinguishes "scanned and found no library" from `0.0` which means "no scan was performed or no signals fired at all")
- Token system still populated from tailwind config
- Workers advised: no reuse opportunities, create from scratch

### EC-5: Figma Code Connect

**Detection**: `@figma/code-connect` in package.json deps OR `*.figma.tsx` files present.

**Handling**:
- Add `figma_code_connect: true` to profile
- Workers should use Code Connect stubs as implementation starting points
- Note: Figma tokens may be auto-synced — check `tokens/` for generated output

### EC-6: Storybook-Only (No Runtime Component Library)

**Detection**: `@storybook/*` in deps, >=5 `*.stories.tsx` files, but no library signals above 0.50.

**Handling**:
- Set `library: unknown` (Storybook is a documentation tool, not a component library)
- Add `storybook: true` to profile
- Add `storybook_story_count: N` to profile
- Workers can use stories as component API reference

### EC-7: CSS Modules (No Tailwind, No CSS-in-JS)

**Detection**: `*.module.css` files exist, no tailwind signal, no styled-components signal.

**Handling**:
- Set `variants.system: css-modules`
- Set `tokens.format: css-variables` if CSS custom properties detected
- Workers should follow CSS Modules naming conventions
- Do NOT suggest Tailwind classes in generated code

### EC-8: RSC (React Server Components)

**Detection**: `app/` directory exists (Next.js App Router), `server-only` package in deps, or `"use client"` directives in source files.

**Handling**:
- Add `rsc: true` to profile
- Add `rsc_boundary_pattern: "use client"` to profile
- Workers must respect RSC boundaries: avoid hooks, event handlers, and browser APIs in Server Components
- Component constraint injection (strive Phase 1.5) includes RSC boundary reminder

## Integration Points

### devise Phase 0.5 (Pre-Brainstorm)

```
profile = discoverDesignSystem(repoRoot)
IF profile.confidence >= talisman.devise.design_system_discovery.confidence_threshold:
  INJECT profile summary into brainstorm context
  SET brainstorm_context.design_system = profile
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
