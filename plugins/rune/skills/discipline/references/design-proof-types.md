# Design Proof Types Reference

Design-specific proof types for verifying implementation fidelity against design specifications (VSM/DCD). These 6 proof types complement the 8 code proof types defined in [proof-schema.md](proof-schema.md).

Source: Discipline Engineering — Shard 9: Design Discipline.

---

## Verification Layers

Design verification is organized into three layers based on automation capability:

| Layer | Coverage | Proof Types | Characteristics |
|-------|----------|-------------|----------------|
| **Machine-verifiable** | ~60% | `token_scan`, `story_exists`, `storybook_renders`, `axe_passes` | Deterministic, binary results. No tooling = INCONCLUSIVE (F4) |
| **Semantic-verifiable** | ~30% | `screenshot_diff`, `responsive_check` | Threshold-based comparison. Requires agent-browser |
| **Human-only** | ~10% | (not automated) | Aesthetic quality, brand consistency, interaction polish |

Discipline Engineering applies to the top 90%. The bottom 10% remains human judgment — acknowledged, not automated.

---

## Proof Type Definitions

### `token_scan`

```yaml
type: token_scan
target: "src/components/Button.tsx"
token_source: "tmp/arc/{id}/vsm/{component}.json"
expected: true
```

**Mechanism**: Regex scan for hardcoded visual values (hex colors, pixel values, raw font sizes) in component files. Checks that implementation uses design tokens instead of hardcoded values.

**Inputs**:
- `target`: Component file path (`.tsx`, `.jsx`, `.css`, `.scss`, `.vue`)
- `token_source`: VSM file containing expected design tokens (optional — used to build allowlist)

**Outputs**:
- `PASS`: No hardcoded visual values found outside token system
- `FAIL`: Hardcoded values detected (lists offending lines)

**Reliability**: HIGH — deterministic regex scan.

**Scan patterns**:
- Hex colors: `#[0-9a-fA-F]{3,8}` (excludes CSS custom property references like `var(--color-primary)`)
- Raw pixel values: `\b\d+px\b` in style attributes (excludes Tailwind utility classes like `p-4`, `text-sm`)
- Raw font sizes: `font-size:\s*\d+` outside token references
- Hardcoded shadows: `box-shadow:\s*\d+` outside token references

**Exclusions** (not flagged as violations):
- CSS custom property references: `var(--*)`, `theme(*)`
- Tailwind utility classes: `className="p-4 text-lg bg-primary"`
- CSS-in-JS token references: `theme.colors.primary`, `tokens.spacing.md`
- SVG internal values: `viewBox`, `d=` path data, `stroke-width` in SVG elements
- Media query breakpoints: `@media (min-width: 768px)` — configurable, not token violations

**Example usage**:
```yaml
DES-color-tokens:
  text: "Button component uses design tokens for all color values"
  proof: token_scan
  args:
    target: "src/components/Button.tsx"
    token_source: "tmp/arc/abc123/vsm/Button.json"
```

---

### `axe_passes`

```yaml
type: axe_passes
target: "src/components/Button"
story_pattern: "**/*.stories.{tsx,jsx}"
rules: "wcag2aa"
expected: true
```

**Mechanism**: axe-core accessibility scan on rendered component (via Storybook or agent-browser). Checks WCAG 2.1 AA compliance including contrast ratios, ARIA labels, roles, and touch targets.

**Inputs**:
- `target`: Component directory or file path
- `story_pattern`: Glob for Storybook story files (default: `**/*.stories.{tsx,jsx}`)
- `rules`: axe-core ruleset (default: `wcag2aa`)

**Outputs**:
- `PASS`: No accessibility violations detected
- `FAIL`: Violations found (lists violation IDs, impacted elements, and severity)
- `INCONCLUSIVE` (F4): axe-core or Storybook not available

**Reliability**: HIGH — industry-standard tool with well-defined rules.

**Graceful degradation**: When Storybook or axe-core is not installed, the proof returns INCONCLUSIVE with `failure_code: "F4"` and `evidence: "tool not available: axe-core"`. INCONCLUSIVE does not count against DSR.

**Example usage**:
```yaml
DES-a11y-button:
  text: "Button component meets WCAG 2.1 AA accessibility standards"
  proof: axe_passes
  args:
    target: "src/components/Button"
    rules: "wcag2aa"
```

---

### `story_exists`

```yaml
type: story_exists
target: "src/components/Button"
variants: ["primary", "secondary", "ghost", "disabled", "loading"]
story_pattern: "**/*.stories.{tsx,jsx,ts,js}"
expected: true
```

**Mechanism**: Check that Storybook story files exist for a component and its variants. Verifies every Figma variant has a corresponding story.

**Inputs**:
- `target`: Component directory or file path
- `variants`: List of expected variant names (from DCD variant matrix)
- `story_pattern`: Glob for story file discovery (default: `**/*.stories.{tsx,jsx,ts,js}`)

**Outputs**:
- `PASS`: Story file exists AND contains exports for all listed variants
- `FAIL`: Missing story file or missing variant exports (lists missing variants)

**Reliability**: HIGH — file existence and pattern matching are deterministic.

**Variant detection**: Scans story exports for named exports matching variant names (e.g., `export const Primary`, `export const Disabled`). Case-insensitive matching.

**Example usage**:
```yaml
DES-story-coverage:
  text: "Button has Storybook stories for all design variants"
  proof: story_exists
  args:
    target: "src/components/Button"
    variants: ["primary", "secondary", "ghost", "disabled", "loading"]
```

---

### `storybook_renders`

```yaml
type: storybook_renders
target: "src/components/Button"
command: "npx storybook build --smoke-test"
expected: true
```

**Mechanism**: Storybook build smoke test or individual story render attempt. Verifies the component renders without JavaScript errors.

**Inputs**:
- `target`: Component directory or file path
- `command`: Build command (default: `npx storybook build --smoke-test`). Can also use story-specific render commands.

**Outputs**:
- `PASS`: Storybook build/render completes without errors (exit code 0)
- `FAIL`: Build/render fails with errors (captures stderr)
- `INCONCLUSIVE` (F4): Storybook not installed in the project

**Reliability**: HIGH — build success is binary (exit code 0 or non-zero).

**Graceful degradation**: Uses `command -v npx` and checks for `storybook` in `package.json` dependencies. Returns INCONCLUSIVE if Storybook is not available.

**Example usage**:
```yaml
DES-renders-clean:
  text: "Button component renders in Storybook without errors"
  proof: storybook_renders
  args:
    target: "src/components/Button"
```

---

### `screenshot_diff`

```yaml
type: screenshot_diff
target: "src/components/Button"
reference: "tmp/arc/{id}/vsm/{component}-reference.png"
threshold: 5
breakpoints: [375, 768, 1024, 1440]
expected: true
```

**Mechanism**: Visual diff between Figma reference screenshot and rendered component screenshot (via agent-browser). Pixel comparison with configurable tolerance threshold.

**Inputs**:
- `target`: Component to screenshot (rendered in Storybook or standalone)
- `reference`: Reference screenshot path (from Figma export or previous approved render)
- `threshold`: Maximum allowed pixel difference percentage (default: 5%)
- `breakpoints`: Viewport widths for responsive screenshots (optional)

**Outputs**:
- `PASS`: Pixel difference below threshold at all breakpoints
- `FAIL`: Pixel difference exceeds threshold (reports percentage and diff image path)
- `INCONCLUSIVE` (F4): agent-browser not available

**Reliability**: MEDIUM — pixel comparison is accurate but threshold-based. Anti-aliasing, font rendering, and sub-pixel differences can cause false positives.

**Configuration**: The default 5% threshold balances fidelity with rendering variance. Configurable via `design_sync.discipline.screenshot_threshold` in talisman.

**Graceful degradation**: Requires agent-browser for screenshot capture. Returns INCONCLUSIVE when browser automation is unavailable.

**Example usage**:
```yaml
DES-fidelity-button:
  text: "Button implementation matches Figma design within 5% pixel tolerance"
  proof: screenshot_diff
  args:
    target: "src/components/Button"
    reference: "tmp/arc/abc123/vsm/Button-reference.png"
    threshold: 5
```

---

### `responsive_check`

```yaml
type: responsive_check
target: "src/components/Button"
breakpoints: [375, 768, 1024, 1440]
checks: ["no_overflow", "no_truncation", "layout_adapts"]
expected: true
```

**Mechanism**: DOM inspection at defined viewport breakpoints via agent-browser. Checks that the component layout adapts correctly at each breakpoint without overflow, truncation, or layout breakage.

**Inputs**:
- `target`: Component to inspect (rendered in browser)
- `breakpoints`: Viewport widths to test (default: `[375, 768, 1024, 1440]`)
- `checks`: Responsive checks to perform:
  - `no_overflow`: No horizontal scrollbar, no elements exceeding viewport width
  - `no_truncation`: No text truncation without `text-overflow: ellipsis`
  - `layout_adapts`: Layout changes at breakpoints (e.g., column → stack)

**Outputs**:
- `PASS`: All checks pass at all breakpoints
- `FAIL`: Check failures at specific breakpoints (reports which check, which breakpoint, which element)
- `INCONCLUSIVE` (F4): agent-browser not available

**Reliability**: MEDIUM — DOM inspection is accurate but requires a running browser. Some layout behaviors are difficult to detect via DOM alone.

**Graceful degradation**: Requires agent-browser for viewport manipulation and DOM inspection. Returns INCONCLUSIVE when browser automation is unavailable.

**Example usage**:
```yaml
DES-responsive-button:
  text: "Button component adapts layout correctly at all breakpoints"
  proof: responsive_check
  args:
    target: "src/components/Button"
    breakpoints: [375, 768, 1024, 1440]
    checks: ["no_overflow", "layout_adapts"]
```

---

## Design Proof Selection Decision Tree

Use this tree to select the correct design proof type for a DES-prefixed acceptance criterion.

```
WHAT DESIGN DIMENSION DOES THE CRITERION VERIFY?
│
├── COLOR / SPACING / TYPOGRAPHY (token compliance)?
│   └── token_scan — regex scan for hardcoded visual values
│
├── ACCESSIBILITY (WCAG compliance)?
│   ├── Is axe-core / Storybook available?
│   │   ├── YES → axe_passes — automated accessibility scan
│   │   └── NO → INCONCLUSIVE (F4) — degrade gracefully
│   └── (Alternatively: pattern_matches for ARIA attributes in source)
│
├── VARIANT COVERAGE (all design states implemented)?
│   └── story_exists — check story file + variant exports
│
├── RENDER INTEGRITY (component builds without errors)?
│   ├── Is Storybook available?
│   │   ├── YES → storybook_renders — smoke test build
│   │   └── NO → INCONCLUSIVE (F4) — degrade gracefully
│
├── VISUAL FIDELITY (matches Figma design)?
│   ├── Is agent-browser available?
│   │   ├── YES → screenshot_diff — pixel comparison with threshold
│   │   └── NO → INCONCLUSIVE (F4) — degrade gracefully
│
└── RESPONSIVE LAYOUT (adapts at breakpoints)?
    ├── Is agent-browser available?
    │   ├── YES → responsive_check — DOM inspection at breakpoints
    │   └── NO → INCONCLUSIVE (F4) — degrade gracefully
```

**Dimension-to-proof mapping summary**:

| Fidelity Dimension | Primary Proof | Fallback | Reliability |
|--------------------|--------------|----------|-------------|
| Token compliance (color, spacing, typography) | `token_scan` | — | HIGH |
| Accessibility | `axe_passes` | `pattern_matches` (ARIA attrs) | HIGH |
| Variant coverage | `story_exists` | — | HIGH |
| Render integrity | `storybook_renders` | — | HIGH |
| Visual fidelity | `screenshot_diff` | `semantic_match` (judge model) | MEDIUM |
| Responsive layout | `responsive_check` | `semantic_match` (judge model) | MEDIUM |

---

## DCD Acceptance Criteria Format

Design acceptance criteria are stored in the DCD (Design Context Document) YAML frontmatter under the `acceptance_criteria` field. They follow the same structure as plan-level criteria for consistency with the proof executor input format.

### Schema

```yaml
---
# ... standard DCD frontmatter (type, component, tokens, fidelity_dimensions) ...
acceptance_criteria:
  - id: "DES-{component}-{dimension}"
    text: "Human-readable description of what is verified"
    proof: token_scan | axe_passes | story_exists | storybook_renders | screenshot_diff | responsive_check
    args:
      target: "path/to/component"
      # ... proof-type-specific arguments ...
    dimension: color | spacing | typography | accessibility | variant_coverage | responsive | fidelity
---
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | YES | Unique identifier. Format: `DES-{component}-{dimension}` (e.g., `DES-Button-color-tokens`) |
| `text` | string | YES | Human-readable criterion description |
| `proof` | string | YES | One of the 6 design proof types or existing code proof types |
| `args` | object | YES | Proof-type-specific arguments (target, patterns, thresholds) |
| `dimension` | string | YES | Fidelity dimension being verified. One of: `color`, `spacing`, `typography`, `accessibility`, `variant_coverage`, `responsive`, `fidelity` |

### Example: Full DCD with Acceptance Criteria

```yaml
---
type: design-context
component: "Button"
figma_url: "https://www.figma.com/design/abc123/App?node-id=1-234"
generated_at: "2026-03-16T10:00:00Z"
vsm_source: "tmp/arc/abc123/vsm/Button.json"
tokens:
  colors:
    - name: "primary"
      value: "#1A73E8"
      usage: "CTA buttons"
  spacing:
    - name: "sm"
      value: "8px"
acceptance_criteria:
  - id: "DES-Button-color-tokens"
    text: "Button uses design tokens for all color values (no hardcoded hex)"
    proof: token_scan
    args:
      target: "src/components/Button.tsx"
      token_source: "tmp/arc/abc123/vsm/Button.json"
    dimension: color
  - id: "DES-Button-a11y"
    text: "Button meets WCAG 2.1 AA accessibility standards"
    proof: axe_passes
    args:
      target: "src/components/Button"
      rules: "wcag2aa"
    dimension: accessibility
  - id: "DES-Button-variants"
    text: "Button has stories for all Figma variants: primary, secondary, ghost, disabled, loading"
    proof: story_exists
    args:
      target: "src/components/Button"
      variants: ["primary", "secondary", "ghost", "disabled", "loading"]
    dimension: variant_coverage
  - id: "DES-Button-renders"
    text: "Button renders in Storybook without errors"
    proof: storybook_renders
    args:
      target: "src/components/Button"
    dimension: fidelity
  - id: "DES-Button-fidelity"
    text: "Button matches Figma design within 5% pixel tolerance"
    proof: screenshot_diff
    args:
      target: "src/components/Button"
      reference: "tmp/arc/abc123/vsm/Button-reference.png"
      threshold: 5
    dimension: fidelity
  - id: "DES-Button-responsive"
    text: "Button adapts layout at mobile (375px) and tablet (768px) breakpoints"
    proof: responsive_check
    args:
      target: "src/components/Button"
      breakpoints: [375, 768, 1024, 1440]
      checks: ["no_overflow", "layout_adapts"]
    dimension: responsive
fidelity_dimensions:
  layout: null
  spacing: null
  typography: null
  color: null
  responsiveness: null
  accessibility: null
---
```

### Criteria Generation from VSM

Acceptance criteria are auto-generated from VSM data during DCD creation (Phase 3 design extraction). The generation logic maps VSM content to criteria:

| VSM Section | Generated Criteria | Proof Type |
|-------------|-------------------|------------|
| `tokens.colors[]` | Token compliance per color | `token_scan` |
| `tokens.spacing[]` | Token compliance per spacing | `token_scan` |
| `tokens.typography[]` | Token compliance per font | `token_scan` |
| `variants[]` | Story exists per variant | `story_exists` |
| Component exists | Renders without error | `storybook_renders` |
| `accessibility` | WCAG AA compliance | `axe_passes` |
| `responsive.breakpoints[]` | Layout adapts per breakpoint | `responsive_check` |
| Design reference | Visual fidelity match | `screenshot_diff` |

The `acceptance_criteria` field is **optional** for backward compatibility. Existing DCDs without criteria continue to work — they just lack per-criterion evidence trails. The `acceptance_criteria` field is populated during DCD generation when `design_sync.discipline.enabled` is not explicitly `false` (default: enabled when `design_sync.enabled` is `true`). Set `design_sync.discipline.enabled: false` in talisman.yml to opt out.

---

## Evidence Artifact Format

Design proof evidence follows the same JSON format as code proof evidence (see [proof-schema.md](proof-schema.md)):

```json
{
  "criterion_id": "DES-Button-color-tokens",
  "result": "PASS",
  "evidence": "No hardcoded hex colors found in src/components/Button.tsx (scanned 45 lines, 0 violations)",
  "timestamp": "2026-03-16T12:00:00Z",
  "failure_code": null,
  "dimension": "color"
}
```

Design evidence includes an additional `dimension` field for aggregation into per-dimension fidelity scores.

Artifacts are persisted to: `tmp/work/{timestamp}/evidence/{task-id}/{criterion_id}.json`

---

## See Also

- [proof-schema.md](proof-schema.md) — code proof types, evidence format, execution model
- [evidence-convention.md](evidence-convention.md) — evidence collection and storage conventions
- `../../arc/references/arc-phase-design-package.md` — DCD schema and generation protocol
- `../../design-sync/SKILL.md` — design synchronization pipeline
