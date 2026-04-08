# Anomaly Detection & Reporting

## Purpose

Capture ALL errors and unusual behavior during browser testing — both **in-scope**
(related to the PR) and **out-of-scope** (discovered incidentally). Anomalies are
collected during flow execution and written as a standalone report plus a section
in the final test report.

Output: `tmp/test-browser-{timestamp}/results/anomalies.md`

## Anomaly Categories

```
ANOMALY CATEGORIES:
  1. CONSOLE-ERROR    — JavaScript errors in browser console
  2. NETWORK-ERROR    — Failed/slow API calls, 4xx/5xx responses
  3. UI-GLITCH        — Visual rendering issues (overflow, overlap, missing elements)
  4. SLOW-RESPONSE    — Pages/API calls taking >3 seconds
  5. UNEXPECTED-REDIRECT — Redirect to unexpected URL (login loop, error page)
  6. STALE-DATA       — Data from previous test case visible when it shouldn't be
  7. BROKEN-LINK      — Internal link leading to 404 or error
  8. ACCESSIBILITY    — Missing labels, broken focus, missing alt text
  9. STATE-LEAK       — State from one test case affecting another
  10. UNHANDLED-ERROR — Uncaught exceptions, unhandled promise rejections
```

**Namespace Isolation**: These anomaly categories are DISTINCT from existing deep
finding prefixes (INT-, DATA-, VIS-, UX-, FLOW- in deep-testing-layers.md). Keep
them in a separate "Anomalies" report section to avoid confusion with DATA-API-ERROR
(existing deep finding) vs NETWORK-ERROR (new anomaly category).

## Severity Mapping

```
SEVERITY MAPPING:
  critical: UNHANDLED-ERROR, STATE-LEAK (data corruption risk)
  high:     CONSOLE-ERROR, NETWORK-ERROR, UNEXPECTED-REDIRECT, BROKEN-LINK
  medium:   UI-GLITCH, STALE-DATA, SLOW-RESPONSE
  low:      ACCESSIBILITY (unless WCAG Level A violation → medium)
```

```
getSeverity(category) → "critical" | "high" | "medium" | "low"

  SEVERITY_MAP = {
    "UNHANDLED-ERROR": "critical",
    "STATE-LEAK": "critical",
    "CONSOLE-ERROR": "high",
    "NETWORK-ERROR": "high",
    "UNEXPECTED-REDIRECT": "high",
    "BROKEN-LINK": "high",
    "UI-GLITCH": "medium",
    "STALE-DATA": "medium",
    "SLOW-RESPONSE": "medium",
    "ACCESSIBILITY": "low"
  }

  return SEVERITY_MAP[category] ?? "medium"
```

## Scope Classification

Determine whether an anomaly is related to the current PR or was discovered
incidentally. Uses multi-signal classification with confidence levels.

```
isErrorRelatedToPR(anomaly, scope) → { inScope: boolean, confidence: "high"|"medium"|"low" }

  // 1. Stack trace match (highest confidence)
  //    If the error stack trace references a file changed in the PR,
  //    it's almost certainly related.
  if anomaly.stack:
    for each file in scope.files:
      if anomaly.stack.includes(file) or anomaly.stack.includes(basename(file)):
        return { inScope: true, confidence: "high" }

  // 2. Module name in error message
  //    If the error message mentions a module/component from a changed file,
  //    it's likely related.
  for each file in scope.files:
    moduleName = extractModuleName(file)
    if moduleName and anomaly.message.toLowerCase().includes(moduleName.toLowerCase()):
      return { inScope: true, confidence: "medium" }

  // 3. Route match — if anomaly route is derived from PR diff
  //    Uses the file-to-route mapping from route discovery.
  if anomaly.route:
    for each file in scope.files:
      expectedRoute = fileToRoute(file)  // reuse route discovery mapping
      if expectedRoute and anomaly.route.includes(expectedRoute):
        return { inScope: true, confidence: "medium" }

  // 4. No match — out of scope
  //    Conservative: avoids false attribution. Better to classify as
  //    out-of-scope than wrongly blame the PR.
  return { inScope: false, confidence: "high" }
```

### Module Name Extraction

```
extractModuleName(filePath) → string | null

  // Extract meaningful module/component name from file path
  //
  // "src/components/Checkout.tsx" → "checkout"
  // "app/models/order.py" → "order"
  // "controllers/payment_controller.rb" → "payment"

  basename = filePath.split("/").pop()
  name = basename
    .replace(/\.(tsx?|jsx?|py|rb|go|php|vue|svelte)$/, "")
    .replace(/_?(controller|service|model|component|view|page|handler)$/i, "")
    .replace(/([A-Z])/g, " $1").trim()  // CamelCase → words
    .toLowerCase()

  return name.length > 2 ? name : null  // skip too-short names
```

## Anomaly Collection During Flow Execution

Anomalies are collected during the flow execution engine (ui-first-flow.md)
and passed to this module for classification and reporting.

```
collectAnomalies(sessionName, testCaseId, route) → Anomaly[]

  anomalies = []

  // 1. Console errors
  consoleOutput = Bash(`agent-browser errors`)
  if consoleOutput.trim():
    for each line in consoleOutput.trim().split("\n"):
      // Classify: unhandled rejection vs regular error vs deprecation
      category = "CONSOLE-ERROR"
      if line.match(/unhandled.*rejection|uncaught/i):
        category = "UNHANDLED-ERROR"

      anomalies.push({
        category: category,
        during: testCaseId,
        route: route,
        message: line.trim(),
        stack: line,  // Console output may include stack
        timestamp: new Date().toISOString()
      })

  // 2. Network errors (from HAR or agent-browser network inspection)
  networkErrors = Bash(`agent-browser eval -b "
    const entries = performance.getEntriesByType('resource');
    const slow = entries.filter(e => e.duration > 3000);
    const errors = [];
    // Check for fetch failures via PerformanceObserver data
    entries.forEach(e => {
      if (e.transferSize === 0 && e.duration > 0 && e.name.includes('/api/')) {
        errors.push({ url: e.name, duration: Math.round(e.duration), type: 'network-error' });
      }
      if (e.duration > 3000 && e.name.includes('/api/')) {
        errors.push({ url: e.name, duration: Math.round(e.duration), type: 'slow-response' });
      }
    });
    JSON.stringify(errors);
  " 2>/dev/null`).trim()

  try:
    networkIssues = JSON.parse(networkErrors)
    for each issue in networkIssues:
      category = issue.type == "slow-response" ? "SLOW-RESPONSE" : "NETWORK-ERROR"
      anomalies.push({
        category: category,
        during: testCaseId,
        route: route,
        message: `${issue.url} — ${issue.duration}ms`,
        timestamp: new Date().toISOString()
      })
  catch: pass  // Network inspection failed, skip

  // 3. Redirect detection
  currentUrl = Bash(`agent-browser eval -b "window.location.href"`).trim()
  expectedUrlBase = route
  if not currentUrl.includes(expectedUrlBase):
    // Check if redirect is expected (e.g., login → dashboard)
    anomalies.push({
      category: "UNEXPECTED-REDIRECT",
      during: testCaseId,
      route: route,
      message: `Expected to be on ${route}, but redirected to ${currentUrl}`,
      timestamp: new Date().toISOString()
    })

  return anomalies
```

## State Leak Detection

Check if data from a previous test case is leaking into the current one.

```
detectStateLeak(testCaseId, previousResults, snapshot) → Anomaly[]

  anomalies = []

  // Check for data from previous test cases visible on current page
  for each [prevId, prevResult] in Object.entries(previousResults):
    if prevResult.createdData:
      for each [key, value] in Object.entries(prevResult.createdData):
        if typeof value == "string" and value.length > 3:
          if snapshot.includes(value):
            anomalies.push({
              category: "STATE-LEAK",
              during: testCaseId,
              route: prevResult.route,
              message: `Data from ${prevId} (${key}: "${value}") visible in ${testCaseId}`,
              in_scope: true,
              timestamp: new Date().toISOString()
            })

  return anomalies
```

## Anomaly Report Generation

```
generateAnomalyReport(allAnomalies, scope, testPlan, timestamp) → string

  // Classify each anomaly as in-scope or out-of-scope
  classified = allAnomalies.map(a => ({
    ...a,
    scope: a.in_scope !== undefined
      ? { inScope: a.in_scope, confidence: "high" }
      : isErrorRelatedToPR(a, scope),
    severity: getSeverity(a.category)
  }))

  // Separate in-scope vs out-of-scope
  inScope = classified.filter(a => a.scope.inScope)
  outOfScope = classified.filter(a => !a.scope.inScope)

  // Sort by severity: critical > high > medium > low
  SEVERITY_ORDER = { critical: 0, high: 1, medium: 2, low: 3 }
  sortBySeverity = (a, b) => (SEVERITY_ORDER[a.severity] ?? 4) - (SEVERITY_ORDER[b.severity] ?? 4)

  inScope.sort(sortBySeverity)
  outOfScope.sort(sortBySeverity)

  lines = []
  lines.push(`# Anomalies Report`)
  lines.push(``)
  lines.push(`**Total**: ${allAnomalies.length} anomalies (${inScope.length} in-scope, ${outOfScope.length} out-of-scope)`)
  lines.push(``)

  // In-scope section (always shown fully)
  lines.push(`## In-Scope (related to PR changes)`)
  lines.push(``)

  if inScope.length == 0:
    lines.push(`No in-scope anomalies detected.`)
  else:
    lines.push(`| # | Severity | Category | During | Route | Description | Confidence |`)
    lines.push(`|---|----------|----------|--------|-------|-------------|------------|`)
    for each [i, a] in inScope.entries():
      lines.push(`| ${i + 1} | **${a.severity}** | ${a.category} | ${a.during} | \`${a.route}\` | ${a.message} | ${a.scope.confidence} |`)
  lines.push(``)

  // Out-of-scope section (capped per category)
  lines.push(`## Out-of-Scope (discovered incidentally)`)
  lines.push(``)

  if outOfScope.length == 0:
    lines.push(`No out-of-scope anomalies detected.`)
  else:
    // Cap at 10 per category
    MAX_PER_CATEGORY = 10
    categorized = groupBy(outOfScope, a => a.category)

    lines.push(`| # | Severity | Category | During | Route | Description |`)
    lines.push(`|---|----------|----------|--------|-------|-------------|`)

    counter = 1
    for each [category, items] in Object.entries(categorized):
      displayed = items.slice(0, MAX_PER_CATEGORY)
      for each a in displayed:
        lines.push(`| ${counter++} | **${a.severity}** | ${a.category} | ${a.during} | \`${a.route}\` | ${a.message} |`)
      if items.length > MAX_PER_CATEGORY:
        remaining = items.length - MAX_PER_CATEGORY
        lines.push(`| | | ${category} | | | ... and ${remaining} more |`)

    lines.push(``)
    lines.push(`> These issues were not introduced by the current PR but were discovered during testing.`)
    lines.push(`> Consider filing separate issues for out-of-scope findings.`)

  lines.push(``)

  // Summary by category
  lines.push(`## Summary by Category`)
  lines.push(``)
  lines.push(`| Category | In-Scope | Out-of-Scope | Severity |`)
  lines.push(`|----------|----------|--------------|----------|`)

  ALL_CATEGORIES = [
    "UNHANDLED-ERROR", "STATE-LEAK", "CONSOLE-ERROR", "NETWORK-ERROR",
    "UNEXPECTED-REDIRECT", "BROKEN-LINK", "UI-GLITCH", "STALE-DATA",
    "SLOW-RESPONSE", "ACCESSIBILITY"
  ]

  for each cat in ALL_CATEGORIES:
    inCount = inScope.filter(a => a.category == cat).length
    outCount = outOfScope.filter(a => a.category == cat).length
    if inCount > 0 or outCount > 0:
      lines.push(`| ${cat} | ${inCount} | ${outCount} | ${getSeverity(cat)} |`)

  // Write report
  reportPath = `tmp/test-browser-${timestamp}/results/anomalies.md`
  Write(reportPath, lines.join("\n"))

  return lines.join("\n")
```

## Helpers

```
groupBy(array, keyFn) → { [key]: item[] }
  result = {}
  for each item in array:
    key = keyFn(item)
    result[key] = result[key] ?? []
    result[key].push(item)
  return result

basename(path) → string
  return path.split("/").pop()
```
