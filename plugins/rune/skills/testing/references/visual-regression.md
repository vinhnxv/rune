# Visual Regression Protocol — STEP 7 Sub-tier

Conditional visual regression testing embedded in the E2E browser tier (STEP 7).
Uses `agent-browser diff screenshot` (v0.13+) for AI-vision comparison against
committed baselines. Disabled by default — opt-in via talisman.

## Talisman Gate

```
if talismanConfig.testing?.visual_regression?.enabled !== true:
  return  // Skip visual regression — run E2E as before (AC-007)
```

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `testing.visual_regression.enabled` | bool | `false` | Master toggle |
| `testing.visual_regression.baseline_dir` | string | `"tests/baselines"` | Baseline storage directory |
| `testing.visual_regression.threshold` | float | `0.95` | Similarity threshold (0.0–1.0) |
| `testing.visual_regression.update_baselines` | bool | `false` | Capture new baselines instead of comparing |
| `testing.visual_regression.responsive.enabled` | bool | `false` | Enable responsive viewport variants |
| `testing.visual_regression.responsive.viewports` | list | see below | Viewport definitions |

**Threshold semantics**: `threshold` is a *similarity* score (not a difference score).
- `0.95` = 95% visual match required to pass (5% diff tolerance)
- `1.0` = exact match only (even anti-aliasing differences fail)
- `0.0` = everything passes (all diffs allowed)
- Recommended range: `0.85–0.99`. Values below `0.5` are clamped with a WARN.
- This uses AI-vision comparison (`agent-browser diff screenshot`), NOT pixel-level diff.
  Users expecting Percy/Chromatic-style pixel diff should be aware of this distinction.

**Default viewports** (when `responsive.enabled: true`):

```yaml
viewports:
  - { name: "mobile", width: 375, height: 812 }
  - { name: "tablet", width: 768, height: 1024 }
  - { name: "desktop", width: 1920, height: 1080 }
```

Users can add custom viewports (e.g., `{ name: "laptop", width: 1440, height: 900 }`).

## Visual Regression Workflow

Executes within the E2E browser tester agent after each route navigation cycle:

```
visualRegression(route, routeIndex, config):
  baselineDir = config.testing.visual_regression.baseline_dir ?? "tests/baselines"
  threshold = clamp(config.testing.visual_regression.threshold ?? 0.95, 0.5, 1.0)
  updateMode = config.testing.visual_regression.update_baselines === true

  // --- TVAL-004 gate: update_baselines ---
  if updateMode:
    captureBaseline(route, routeIndex, baselineDir)
    return { status: "VISUAL_NEW_BASELINE", reason: "update_baselines mode" }

  // --- Step 1: Capture current screenshot ---
  currentPath = "tmp/arc/{id}/screenshots/route-{routeIndex}.png"
  Bash(`agent-browser screenshot ${currentPath}`)

  // --- Step 2: Check for baseline ---
  baselinePath = "${baselineDir}/route-{routeIndex}-baseline.png"
  baselineExists = Read(baselinePath)  // SDK Read — never Bash("test -f")

  // --- Step 3a: Baseline exists — compare ---
  if baselineExists:
    diffResult = Bash(`agent-browser diff screenshot ${baselinePath} ${currentPath}`)

    // Parse diff result: agent-browser returns similarity score + semantic description
    similarity = parseSimilarity(diffResult)
    semanticDescription = parseDescription(diffResult)
    diffPct = 1.0 - similarity

    if similarity >= threshold:
      return {
        status: "VISUAL_PASS",
        similarity: similarity,
        diff_pct: diffPct,
        description: semanticDescription
      }
    else:
      // Determine intentional vs regression
      return {
        status: "VISUAL_REGRESSION",
        similarity: similarity,
        diff_pct: diffPct,
        description: semanticDescription,
        baseline: baselinePath,
        current: currentPath,
        recommendation: "Review diff — if intentional, run with update_baselines: true"
      }

  // --- Step 3b: No baseline — capture new ---
  else:
    Bash(`cp ${currentPath} ${baselinePath}`)
    return {
      status: "VISUAL_NEW_BASELINE",
      baseline: baselinePath,
      message: "New baseline captured for route-{routeIndex}"
    }
```

## Responsive Variants

When `visual_regression.responsive.enabled: true`:

```
captureResponsiveVariants(route, routeIndex, config):
  // --- TVAL-005 gate: read viewports from config ---
  viewports = config.testing.visual_regression.responsive.viewports ?? [
    { name: "mobile", width: 375, height: 812 },
    { name: "tablet", width: 768, height: 1024 },
    { name: "desktop", width: 1920, height: 1080 }
  ]

  results = []
  for viewport in viewports:
    // Resize viewport
    Bash(`agent-browser eval "window.resizeTo(${viewport.width}, ${viewport.height})"`)

    // Wait for reflow
    Bash(`agent-browser wait --load networkidle`)

    // Capture and compare for this viewport
    variantResult = visualRegression(
      route, "{routeIndex}-{viewport.name}", config
    )
    results.push({ viewport: viewport.name, ...variantResult })

  return results
```

## Baseline Management

### First Run (No Baselines)

1. Screenshots captured as baseline candidates in `${baseline_dir}/`
2. All routes marked `VISUAL_NEW_BASELINE`
3. Report advises: "Commit baselines to git to enable regression detection"

### Subsequent Runs

1. Compare each screenshot against committed baseline
2. Report diff percentage and semantic description
3. `VISUAL_PASS` or `VISUAL_REGRESSION` per route

### Baseline Update

Explicit via talisman flag — NEVER auto-update:

```yaml
# In talisman.yml — set temporarily, then revert
testing:
  visual_regression:
    update_baselines: true   # Captures new baselines instead of comparing
```

Or via CLI: `/rune:test-browser --update-baselines`

### Storage & Git

- Baselines committed to git in `${baseline_dir}/`
- Auto-detect total baseline size during STEP 7:

```
checkBaselineSize(baselineDir):
  totalSize = Bash(`du -sb ${baselineDir} 2>/dev/null | cut -f1`)
  if totalSize > 5_000_000:  // 5MB
    WARN: "Baseline directory exceeds 5MB (${totalSize} bytes)."
    WARN: "Consider adding .gitattributes LFS entry for ${baselineDir}/**/*.png"
```

- Add `.gitattributes` entry when total exceeds 5MB:
  ```
  tests/baselines/**/*.png filter=lfs diff=lfs merge=lfs -text
  ```

### Branching Strategy

- **Main branch** baselines are the source of truth
- Feature branches use their own baselines (captured on first run)
- After merge: rebase and re-run visual tests to realign baselines
- Binary PNG files do not auto-merge — `git diff --check` on baseline files

**Stale baseline detection**: When a feature branch's baselines are older than the
main branch baselines, emit WARN: "Baselines may be stale — consider rebasing."

## Intentional Change vs Regression

The test report distinguishes between intentional changes and regressions:

| Status | Meaning | Report Display |
|--------|---------|----------------|
| `VISUAL_PASS` | Screenshot matches baseline within threshold | Green — no action |
| `VISUAL_NEW_BASELINE` | No baseline existed — new one captured | Blue — review and commit |
| `VISUAL_REGRESSION` | Screenshot differs beyond threshold | Red — review required |

For `VISUAL_REGRESSION` findings, the report includes:
- Side-by-side baseline vs current screenshot paths
- Similarity score and diff percentage
- Semantic description of changes (from AI-vision comparison)
- Recommendation: "If intentional, run with `update_baselines: true`"

## Design Token Compliance Sub-section

When `design_sync.enabled: true` AND `visual_regression.enabled: true`, the visual
regression sub-tier includes a design token compliance check. See
[design-token-check.md](design-token-check.md) for the full algorithm.

## Accessibility Check Sub-section

When `testing.accessibility.enabled: true`, the visual regression sub-tier includes
an accessibility audit using axe-core. See
[accessibility-check.md](accessibility-check.md) for the full protocol.

## Output Format

Visual regression results are appended to the per-route E2E result file:

```markdown
### Visual Regression: Route {N}

| Viewport | Status | Similarity | Diff % | Description |
|----------|--------|------------|--------|-------------|
| default  | VISUAL_PASS | 0.97 | 3% | Minor font rendering difference |
| mobile   | VISUAL_REGRESSION | 0.82 | 18% | Navigation menu collapsed differently |

Baseline: tests/baselines/route-1-baseline.png
Current: tmp/arc/{id}/screenshots/route-1.png
```

Aggregate visual regression summary in `tmp/arc/{id}/test-results-e2e.md`:

```markdown
## Visual Regression Summary
- Routes with visual tests: {N}
- Passed: {N}, Regression: {N}, New baseline: {N}
- Responsive variants tested: {N}

<!-- SEAL: visual-regression-complete -->
```

## Security Notes

- Screenshots are local files only — never uploaded or transmitted
- Baseline paths validated against `SAFE_PATH_PATTERN` (no `..` traversal)
- `agent-browser diff screenshot` runs locally — no external API calls
- Element count caps and content boundary scoping enforced by SEC-005
  (see [design-token-check.md](design-token-check.md))

## Integration Points

- **STEP 7 (E2E)**: Visual regression runs as a sub-step within E2E browser testing
- **STEP 9 (Report)**: Visual diff section added to test report template
- **STEP 9.5 (History)**: Visual regression results included in history entries
- **Test report template**: See [test-report-template.md](test-report-template.md)
- **E2E browser tester agent**: See [registry/testing/e2e-browser-tester.md](../../../../registry/testing/e2e-browser-tester.md)

## TVAL References

| ID | Key | Status |
|----|-----|--------|
| TVAL-004 | `visual_regression.update_baselines` | Gated in workflow above |
| TVAL-005 | `responsive.viewports` | Gated — reads from config, not hardcoded |
