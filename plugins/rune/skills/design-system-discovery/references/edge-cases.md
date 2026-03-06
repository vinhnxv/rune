# Edge Cases

## EC-1: Monorepo

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

## EC-2: Migration (Two Design Systems Coexist)

**Detection**: Two distinct library signals both exceed 0.50 confidence.

**Handling**:
- Set `library` to the higher-confidence system
- Set `migrating_from` to the lower-confidence system
- Add `migration: true` flag in profile
- Workers should prefer the primary library for new components, note legacy components

## EC-3: Custom-on-Radix (No shadcn/ui, Direct Radix Usage)

**Detection**: `@radix-ui/*` count >= 5 in package.json, but `components.json` absent, and shadcn confidence < 0.60.

**Handling**:
- Set `library: custom_design_system`
- Set `accessibility.layer: radix`
- Confidence set to `custom_design_system` score (typically 0.60–0.75)
- Note in profile: "Custom component library built on Radix UI primitives"

## EC-4: Bare Tailwind (No Component Library)

**Detection**: `tailwindcss` present, no library signals above 0.50.

**Handling**:
- Set `library: unknown`
- Set `confidence: 0.05` for library (distinguishes "scanned and found no library" from `0.0` which means "no scan was performed or no signals fired at all")
- Token system still populated from tailwind config
- Workers advised: no reuse opportunities, create from scratch

## EC-5: Figma Code Connect

**Detection**: `@figma/code-connect` in package.json deps OR `*.figma.tsx` files present.

**Handling**:
- Add `figma_code_connect: true` to profile
- Workers should use Code Connect stubs as implementation starting points
- Note: Figma tokens may be auto-synced — check `tokens/` for generated output

## EC-6: Storybook-Only (No Runtime Component Library)

**Detection**: `@storybook/*` in deps, >=5 `*.stories.tsx` files, but no library signals above 0.50.

**Handling**:
- Set `library: unknown` (Storybook is a documentation tool, not a component library)
- Add `storybook: true` to profile
- Add `storybook_story_count: N` to profile
- Workers can use stories as component API reference

## EC-7: CSS Modules (No Tailwind, No CSS-in-JS)

**Detection**: `*.module.css` files exist, no tailwind signal, no styled-components signal.

**Handling**:
- Set `variants.system: css-modules`
- Set `tokens.format: css-variables` if CSS custom properties detected
- Workers should follow CSS Modules naming conventions
- Do NOT suggest Tailwind classes in generated code

## EC-8: RSC (React Server Components)

**Detection**: `app/` directory exists (Next.js App Router), `server-only` package in deps, or `"use client"` directives in source files.

**Handling**:
- Add `rsc: true` to profile
- Add `rsc_boundary_pattern: "use client"` to profile
- Workers must respect RSC boundaries: avoid hooks, event handlers, and browser APIs in Server Components
- Component constraint injection (strive Phase 1.5) includes RSC boundary reminder
