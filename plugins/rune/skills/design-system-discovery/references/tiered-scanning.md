# Tiered Scanning Algorithm

Scanning proceeds in tiers. Each tier is only entered if the previous tier did not yield a
conclusive match (confidence >= 0.90). Early exit saves time in well-configured projects.

## Tier 0 — Root Manifests (target: ~2 tool calls)

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

## Tier 1 — Shallow Scan (target: ~5 tool calls)

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

## Tier 2 — Deep Content Scan (target: ~20 tool calls)

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

## discoverFrontendStack(repoRoot)

Extends the existing `detectTypeScriptStack()` with version extraction, build tool detection,
and CSS framework version detection. Called during design-prototype Phase 0 to build Layer 1
of the 3-layer detection pipeline.

**Input**: `repoRoot` — repository root path
**Output**: frontend stack profile object (see schema below)

Uses `discover*` naming to match existing codebase convention (`discoverDesignSystem()`,
`discoverUIBuilder()`). Unlike `detectTypeScriptStack()` which returns a generic stack
structure, this function returns a design-pipeline-specific frontend profile.

### Algorithm

```
// Pseudocode — NOT implementation code
function discoverFrontendStack(repoRoot):
  pkg = Read(repoRoot + "/package.json")
  IF pkg is null OR pkg is empty:
    RETURN {
      framework: null, framework_version: null,
      build_tool: null,
      css_framework: "tailwind", css_version: 4,
      confidence: 0.0,
      evidence: []
    }

  deps = merge(pkg.dependencies ?? {}, pkg.devDependencies ?? {})
  evidence = ["package.json"]

  // --- Framework detection with version ---
  framework = null
  framework_version = null

  IF deps.has("next"):
    framework = "nextjs"
    framework_version = extractMajor(deps["next"])
  ELIF deps.has("react"):
    framework = "react"
    framework_version = extractMajor(deps["react"])
  ELIF deps.has("vue"):
    framework = "vuejs"
    framework_version = extractMajor(deps["vue"])
  ELIF deps.has("nuxt"):
    framework = "nuxt"
    framework_version = extractMajor(deps["nuxt"])
  ELIF deps.has("svelte"):
    framework = "svelte"
    framework_version = extractMajor(deps["svelte"])

  // --- Build tool detection ---
  build_tool = null
  IF deps.has("vite") OR deps.has("@vitejs/plugin-react"):
    build_tool = "vite"
    evidence.push("vite")
  ELIF Glob(repoRoot + "/next.config.*").length > 0:
    build_tool = "next"
    evidence.push("next.config.*")
  ELIF deps.has("webpack"):
    build_tool = "webpack"

  // --- CSS framework detection with version ---
  css_framework = null
  css_version = null

  IF deps.has("tailwindcss"):
    css_framework = "tailwind"
    css_version = extractMajor(deps["tailwindcss"])
    // Cross-reference with Tier 0/1 signals for higher confidence
    IF Glob(repoRoot + "/tailwind.config.*").length > 0:
      evidence.push("tailwind.config.*")
      IF css_version is null:
        css_version = 3  // Config file presence implies v3 (v4 uses CSS-based config)
    IF fileContains(repoRoot + "/src/index.css", '@import "tailwindcss"'):
      evidence.push("src/index.css")
      css_version = 4  // @import "tailwindcss" is v4 marker (overrides version string)
    IF fileContains(repoRoot + "/app/globals.css", '@import "tailwindcss"'):
      evidence.push("app/globals.css")
      css_version = 4
  ELIF deps.has("styled-components"):
    css_framework = "styled-components"
  ELIF deps.has("@emotion/styled"):
    css_framework = "emotion"

  // --- Confidence scoring ---
  // Follows existing stacks convention: 0.40 (extension-only) to 0.95 (multiple evidence)
  evidence_count = evidence.length
  IF evidence_count >= 3 AND framework is not null:
    confidence = 0.95
  ELIF evidence_count >= 2 AND framework is not null:
    confidence = 0.85
  ELIF evidence_count >= 1 AND framework is not null:
    confidence = 0.70
  ELIF evidence_count >= 1:
    confidence = 0.50  // package.json found but no framework
  ELSE:
    confidence = 0.0

  RETURN {
    framework: framework,              // "react" | "nextjs" | "vuejs" | "nuxt" | "svelte" | null
    framework_version: framework_version,  // Major version number (integer) or null
    build_tool: build_tool,            // "vite" | "next" | "webpack" | null
    css_framework: css_framework,      // "tailwind" | "styled-components" | "emotion" | null
    css_version: css_version,          // Major version number (integer) or null
    confidence: confidence,            // 0.0–1.0 numeric (matches existing convention)
    evidence: evidence                 // List of files that contributed signals
  }
```

### extractMajor(versionString)

Extracts the major version number from a semver version string as found in `package.json`.

```
// Pseudocode — NOT implementation code
function extractMajor(versionString):
  // Handle common version range prefixes: ^, ~, >=, >, =, ||, spaces
  // Examples: "^14.2.0" → 14, "~3.4.1" → 3, ">=18.0.0" → 18, "4.0.0-beta.1" → 4
  IF versionString is null OR versionString is empty:
    RETURN null

  // Strip leading range operators and whitespace
  cleaned = versionString.replace(/^[\^~>=\s|]+/, "")

  // Extract first sequence of digits
  match = cleaned.match(/^(\d+)/)
  IF match is null:
    RETURN null

  RETURN parseInt(match[1])
```

### Default Fallback

When `discoverFrontendStack()` cannot detect any framework or CSS framework, the
design-prototype pipeline uses this default:

```yaml
# Fallback when no frontend stack detected
framework: null
framework_version: null
build_tool: null
css_framework: "tailwind"
css_version: 4
confidence: 0.0
evidence: []
```

This ensures the pipeline always has a valid CSS framework target. Tailwind v4 is the
default because it is the output format of `figma-to-react`.

### Output Schema

```yaml
# Layer 1 output — flat fields (no wrapper key)
# Wrapper key "stack:" belongs in DesignContext only (see design-context.md)
framework: "react"                # react | nextjs | vuejs | nuxt | svelte | null
framework_version: 18             # Major version number (integer) or null
build_tool: "vite"                # vite | next | webpack | null
css_framework: "tailwind"         # tailwind | styled-components | emotion | null
css_version: 4                    # Major version (integer) — Tailwind v3 vs v4 matters
confidence: 0.95                  # 0.0–1.0 numeric score
evidence:                         # Files that contributed signals
  - package.json
  - vite.config.ts
  - tailwind.config.ts
```

### Relationship to detectTypeScriptStack()

`detectTypeScriptStack()` (in `stacks/references/detection.md`) is the general-purpose
TypeScript stack detector. It returns `{ language, frameworks[], databases[], libraries[],
tooling[] }` — a broad inventory.

`discoverFrontendStack()` is a focused frontend-stack profiler for the design pipeline.
It adds:
- **Version extraction** — major version from `package.json` semver strings
- **Build tool detection** — vite/next/webpack
- **CSS framework versioning** — Tailwind v3 vs v4 (affects class syntax and config format)
- **Design-pipeline-specific confidence** — 0.0–1.0 numeric score

Both functions read `package.json` but serve different consumers. When both run in the
same session, `discoverFrontendStack()` reuses Tier 0 signals already gathered by
`discoverDesignSystem()` if available.
