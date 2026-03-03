# Design Token Compliance Algorithm

Design token compliance check embedded in the E2E visual regression sub-tier.
Extracts computed styles from the rendered page and compares against token definitions
to detect hardcoded values that should use design tokens.

## Gate

```
if talismanConfig.design_sync?.enabled !== true:
  return  // design_sync must be enabled

if talismanConfig.testing?.visual_regression?.enabled !== true:
  return  // visual regression must also be enabled
```

Both `design_sync.enabled` AND `visual_regression.enabled` must be true.

## Token File Detection

```
detectTokenFiles(projectRoot):
  patterns = [
    "tokens.json",                    // Style Dictionary format
    "src/tokens/**/*.json",           // Nested token files
    "tailwind.config.*",              // Tailwind theme tokens
    "src/styles/variables.css",       // CSS custom properties
    "src/styles/variables.scss",      // SCSS variables
    "theme.config.*",                 // Generic theme config
    "design-tokens/**/*.json"         // Design token directory
  ]

  tokenFiles = []
  for pattern in patterns:
    matches = Glob(pattern)
    tokenFiles.push(...matches)

  if tokenFiles.length === 0:
    INFO: "No token definition files found. Skipping design token compliance."
    return null

  return tokenFiles
```

## Token Definition Parsing

```
parseTokenDefinitions(tokenFiles):
  definitions = { colors: [], spacing: [], typography: [] }

  for file in tokenFiles:
    content = Read(file)

    if file.endsWith(".json"):
      // Style Dictionary / custom JSON format
      parsed = JSON.parse(content)
      extractJSONTokens(parsed, definitions)

    if file.endsWith(".css") or file.endsWith(".scss"):
      // CSS custom properties: --color-primary: #3b82f6;
      for line matching /--([a-z-]+):\s*(.+);/:
        categorize(line.varName, line.value, definitions)

    if file.match(/tailwind\.config/):
      // Tailwind theme: extract from theme.extend.colors, spacing, etc.
      extractTailwindTokens(content, definitions)

  return definitions
```

## Value Extraction via agent-browser

Extracts computed CSS values from the rendered page with security constraints.

### SEC-005 Constraints

| Constraint | Value | Rationale |
|------------|-------|-----------|
| Element count cap | 5000 | Prevent OOM on large DOM trees |
| Content boundary | `AGENT_BROWSER_CONTENT_BOUNDARIES` or `body` | Scope to meaningful content |
| Value truncation | 200 chars per value | Prevent exfiltration of long attribute strings |
| Colors cap | 100 unique values | Bounded output size |
| Spacing cap | 100 unique values | Bounded output size |
| Typography cap | 50 unique values | Bounded output size |

### Extraction Algorithm

```
extractRenderedTokens(route):
  extractScript = `
    agent-browser eval --stdin <<'EOF'
    (() => {
      const boundary = document.querySelector(
        '${AGENT_BROWSER_CONTENT_BOUNDARIES || "body"}'
      );
      const els = boundary
        ? boundary.querySelectorAll('*')
        : document.querySelectorAll('*');

      // SEC-005: Element count cap
      if (els.length > 5000) {
        return JSON.stringify({
          error: "too_many_elements",
          count: els.length,
          message: "DOM has more than 5000 elements. Narrow content boundary."
        });
      }

      const tokens = {
        colors: new Set(),
        spacing: new Set(),
        typography: new Set()
      };

      // SEC-005: Value truncation helper
      const truncate = (v) =>
        typeof v === 'string' ? v.slice(0, 200) : String(v).slice(0, 200);

      els.forEach(el => {
        const s = window.getComputedStyle(el);

        // Colors
        tokens.colors.add(truncate(s.color));
        tokens.colors.add(truncate(s.backgroundColor));
        tokens.colors.add(truncate(s.borderColor));

        // Spacing
        tokens.spacing.add(truncate(s.padding));
        tokens.spacing.add(truncate(s.margin));
        tokens.spacing.add(truncate(s.gap));

        // Typography
        tokens.typography.add(truncate(s.fontFamily));
        tokens.typography.add(truncate(s.fontSize));
        tokens.typography.add(truncate(s.fontWeight));
        tokens.typography.add(truncate(s.lineHeight));
      });

      return JSON.stringify({
        // SEC-005: Output size caps
        colors: [...tokens.colors].slice(0, 100),
        spacing: [...tokens.spacing].slice(0, 100),
        typography: [...tokens.typography].slice(0, 50)
      });
    })();
    EOF
  `

  result = Bash(extractScript)
  parsed = JSON.parse(result)

  if parsed.error === "too_many_elements":
    WARN: "Page has ${parsed.count} elements (cap: 5000). "
          "Set AGENT_BROWSER_CONTENT_BOUNDARIES to narrow scope."
    return null

  return parsed
```

## Comparison Algorithm

```
compareTokenCompliance(extracted, definitions):
  report = {
    matching: [],     // Values that match a defined token
    hardcoded: [],    // Values that SHOULD use a token but don't
    unknown: []       // Values not in token system (may be intentional)
  }

  for category in ["colors", "spacing", "typography"]:
    definedValues = definitions[category].map(t => t.value)

    for value in extracted[category]:
      // Skip transparent, inherit, initial, auto (browser defaults)
      if isDefaultValue(value): continue

      match = findClosestToken(value, definitions[category])
      if match.exact:
        report.matching.push({
          category, value,
          token: match.tokenName
        })
      elif match.close:
        report.hardcoded.push({
          category, value,
          suggestion: match.tokenName,
          distance: match.distance
        })
      else:
        report.unknown.push({ category, value })

  return report

isDefaultValue(value):
  return value in [
    "transparent", "inherit", "initial", "unset", "auto",
    "normal", "none", "0px", "rgba(0, 0, 0, 0)"
  ]
```

## Report Format

Token compliance results are appended to the visual regression report section:

```markdown
### Design Token Compliance: Route {N}

**Token files analyzed**: tokens.json, tailwind.config.ts

| Category | Matching | Hardcoded | Unknown |
|----------|----------|-----------|---------|
| Colors | 12 | 3 | 2 |
| Spacing | 8 | 5 | 1 |
| Typography | 4 | 1 | 0 |

**Hardcoded values requiring attention:**
| Value | Category | Suggested Token | Distance |
|-------|----------|-----------------|----------|
| `#333333` | colors | `--color-text-secondary` | close |
| `16px` | spacing | `--spacing-md` | exact category |
| `14px` | typography | `--font-size-sm` | close |
```

## Integration with Test Report

The design token compliance section is included in the test report when both gates
are active. It appears within the Visual Regression section, after the per-route
visual diff results. See [test-report-template.md](test-report-template.md).

## Error Handling

| Condition | Action |
|-----------|--------|
| No token files found | Skip with INFO — not an error |
| `too_many_elements` | WARN + skip extraction for this route |
| Token file parse error | WARN + skip that file, continue with others |
| `agent-browser eval` timeout | WARN + skip compliance check for this route |
| Empty extracted values | WARN + report as "no styles extracted" |
