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
