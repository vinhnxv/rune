# Accessibility Check Protocol — STEP 7 Sub-tier

Optional accessibility audit embedded in the E2E browser tier using axe-core.
Runs after visual regression (if enabled) on each navigated route. Disabled by default.

## Gate

```
if talismanConfig.testing?.accessibility?.enabled !== true:
  return  // Skip accessibility check (AC-007)
```

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `testing.accessibility.enabled` | bool | `false` | Master toggle |
| `testing.accessibility.level` | string | `"AA"` | WCAG level: `A`, `AA`, `AAA` |
| `testing.accessibility.axe_path` | string | `null` | Override local axe-core path |

## Dependency

axe-core must be installed as a **local** dependency:

```bash
npm install --save-dev axe-core
```

**SEC-006**: axe-core is loaded from local `node_modules` ONLY. No external CDN
loading — this violates the localhost-only policy enforced by the E2E browser tester.

## Execution Algorithm

```
runAccessibilityCheck(route, config):
  // Resolve axe-core path
  axePath = config.testing.accessibility.axe_path
            ?? "./node_modules/axe-core/axe.min.js"

  // Map WCAG level to axe tag set
  level = config.testing.accessibility.level ?? "AA"
  axeTags = resolveAxeTags(level)

  // Inject axe-core via agent-browser eval (SEC-006: local only)
  injectScript = `
    agent-browser eval --stdin <<'EOF'
    (() => {
      return new Promise((resolve) => {
        const script = document.createElement('script');
        script.src = '${axePath}';
        document.head.appendChild(script);

        script.onload = () => {
          axe.run({
            runOnly: { type: 'tag', values: ${JSON.stringify(axeTags)} }
          }).then(results => {
            resolve(JSON.stringify({
              violations: results.violations.map(v => ({
                id: v.id,
                impact: v.impact,
                description: v.description,
                help: v.help,
                helpUrl: v.helpUrl,
                nodes: v.nodes.length
              })),
              passes: results.passes.length,
              incomplete: results.incomplete.length,
              inapplicable: results.inapplicable.length
            }));
          });
        };

        script.onerror = () => {
          resolve(JSON.stringify({
            error: "axe_not_installed",
            message: "axe-core not found at ${axePath}. "
                     + "Run: npm install --save-dev axe-core"
          }));
        };
      });
    })();
    EOF
  `

  result = Bash(injectScript)
  parsed = JSON.parse(result)

  if parsed.error === "axe_not_installed":
    WARN: parsed.message
    return { status: "SKIP", reason: "axe-core not installed" }

  return parsed

resolveAxeTags(level):
  switch level:
    case "A":   return ["wcag2a"]
    case "AA":  return ["wcag2a", "wcag2aa"]
    case "AAA": return ["wcag2a", "wcag2aa", "wcag2aaa"]
    default:    return ["wcag2a", "wcag2aa"]  // Default to AA
```

## Report Format

Violations are grouped by impact level (critical > serious > moderate > minor):

```markdown
### Accessibility Audit: Route {N}

**WCAG Level**: AA | **axe-core**: local

| Impact | Count | Top Violation |
|--------|-------|---------------|
| critical | 1 | Images must have alternate text (image-alt) |
| serious | 3 | Form elements must have labels (label) |
| moderate | 2 | Links must have discernible text (link-name) |
| minor | 0 | — |

**Total**: 6 violations, 42 passes, 3 incomplete

**Critical violations (must fix):**
- `image-alt`: Images must have alternate text (2 nodes) — [docs](https://dequeuniversity.com/rules/axe/4.7/image-alt)
- `color-contrast`: Elements must have sufficient color contrast (1 node) — [docs](https://dequeuniversity.com/rules/axe/4.7/color-contrast)
```

## Integration with Test Report

The accessibility section is included in the test report as an optional sub-section
within the E2E results. It appears after the visual regression section (if both are
enabled). See [test-report-template.md](test-report-template.md).

## Aggregate Output

After all routes complete, accessibility summary in `tmp/arc/{id}/test-results-e2e.md`:

```markdown
## Accessibility Summary
- Routes audited: {N}
- Total violations: {N} (critical: {N}, serious: {N}, moderate: {N}, minor: {N})
- Total passes: {N}
- WCAG level: {AA}
```

## Error Handling

| Condition | Action |
|-----------|--------|
| axe-core not installed | WARN with install instructions, skip check |
| `axe.run()` timeout | WARN, skip check for this route, continue |
| Script injection failure | WARN, skip check for this route, continue |
| Zero violations | Report as clean pass (not an error) |

## Security Notes

- **SEC-006**: axe-core loaded from local `node_modules` only — never from CDN
- No data leaves the local machine
- axe-core results are untrusted input (TRUTHBINDING applies)
- The `axe_path` config value is validated against `SAFE_PATH_PATTERN` (no `..`)
