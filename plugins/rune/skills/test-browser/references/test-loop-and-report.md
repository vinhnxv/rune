# Step 5: Per-Route Test Loop + Step 8: Summary Report

## Deep Mode Activation

```
// Resolve deep mode: flag > talisman > auto for backend traces
talismanDeep = testingConfig?.testing?.browser?.deep ?? false
shouldRunDeep = deep || talismanDeep

// Auto-cap max routes for deep testing
if shouldRunDeep and effectiveMax > 3:
  log INFO: "Deep mode active — capping max routes to 3 (was ${effectiveMax})"
  effectiveMax = 3
  routes = routes.slice(0, 3)
```

## Step 5: Per-Route Test Loop

```
routeResults = {}
allDeepFindings = []  // collected across all routes for the report

for each route in routes:
  log INFO: "Testing route: ${route}"
  fullUrl = baseUrl + route

  // Per-route deep activation: always deep for backend-traced routes
  routeDeep = shouldRunDeep || traceSource[route]?.startsWith("backend")

  try:
    // Navigate
    Bash(`agent-browser open "${fullUrl}" ${modeFlag} --session "${sessionName}"`)
    Bash(`agent-browser wait --load networkidle`)

    // Initial snapshot
    snapshot = Bash(`agent-browser snapshot -i`)

    // Step 6 embedded: Human gate check (before assertions)
    gate = detectHumanGate(route, snapshot)
    // See references/human-gates.md for gate detection algorithm
    if gate is not null:
      gateResult = executeHumanGate(gate, route, standalone=true)
      if gateResult == "aborted":
        break  // Exit route loop entirely
      if gateResult == "skipped":
        routeResults[route] = { status: "PARTIAL", reason: "Human gate: ${gate.label}" }
        continue
      // gateResult == "completed" → re-snapshot and continue assertions
      snapshot = Bash(`agent-browser snapshot -i`)

    // Core assertions (always run)
    consoleErrors = Bash(`agent-browser errors`)
    errorCount = consoleErrors.trim() == "" ? 0 : consoleErrors.trim().split("\n").length

    // Verify: page loaded (not blank/error state)
    BLANK_PATTERNS = ["error", "exception", "not found", "503", "500", "502", "404"]
    snapshotLower = snapshot.toLowerCase()
    hasErrorContent = BLANK_PATTERNS.some(p => snapshotLower.includes(p))

    // Pass criteria:
    //   - Console errors == 0
    //   - Snapshot length > 50 characters
    //   - No error-state content
    smokePassed = (errorCount == 0 AND snapshot.length > 50 AND NOT hasErrorContent)

    // Screenshot (always — for pass documentation and failure diagnosis)
    screenshotPath = `tmp/test-browser/${sessionName}/${route.replace(/\//g, "-").replace(/^-/, "")}.png`
    Bash(`mkdir -p "$(dirname "${screenshotPath}")"`)
    Bash(`agent-browser screenshot "${screenshotPath}"`)

    // ============================
    // DEEP TESTING LAYERS (Step 5D-5H)
    // See references/deep-testing-layers.md for full algorithm
    // ============================

    routeFindings = []

    if routeDeep and smokePassed:
      log INFO: "  Running deep tests for ${route}..."

      // Step 5D: Interaction Testing (Layer 1)
      interactionFindings = runInteractionTests(route, snapshot, sessionName)
      routeFindings.push(...interactionFindings)

      // Step 5E: Data Persistence (Layer 2)
      persistenceFindings = runDataPersistenceTests(route, snapshot, sessionName)
      routeFindings.push(...persistenceFindings)

      // Step 5F: Visual/Layout Inspection (Layer 3)
      visualFindings = runVisualInspection(route, sessionName)
      routeFindings.push(...visualFindings)

      // Step 5G: UX Logic Inspection (Layer 4)
      uxFindings = runUXInspection(route, snapshot, sessionName)
      routeFindings.push(...uxFindings)

      // Step 5H: Data Diagnosis (see below)
      diagnosisFindings = runDataDiagnosis(route, snapshot, sessionName)
      routeFindings.push(...diagnosisFindings)

      allDeepFindings.push(...routeFindings.map(f => ({ ...f, route })))

    // Determine overall route status
    criticalFindings = routeFindings.filter(f => f.severity == "critical" || f.severity == "high")

    if not smokePassed:
      failure = {
        type: hasErrorContent ? "assertion" : (errorCount > 0 ? "console-error" : "blank-page"),
        message: hasErrorContent
          ? "Error content detected in page"
          : (errorCount > 0 ? `${errorCount} JS console errors` : "Page appears blank"),
        route: fullUrl,
        step: 5,
        consoleErrors: consoleErrors.trim().split("\n").filter(Boolean),
        snapshotText: snapshot
      }

      // Step 7: Failure handling (interactive in standalone mode)
      // See references/failure-handling.md
      result = handleFailure(route, failure, sessionName, standalone=true)
      if result == "fixed":
        routeResults[route] = { status: "PASS", note: "Fixed inline", screenshot: screenshotPath, findings: routeFindings }
      else if result == "todo-created":
        routeResults[route] = { status: "FAIL", note: "Todo created", screenshot: screenshotPath, findings: routeFindings }
      else:
        routeResults[route] = { status: "FAIL", note: "Skipped", screenshot: screenshotPath, findings: routeFindings }

    else if criticalFindings.length > 0:
      routeResults[route] = {
        status: "WARN",
        note: "${criticalFindings.length} deep finding(s)",
        screenshot: screenshotPath,
        findings: routeFindings
      }
    else:
      routeResults[route] = {
        status: "PASS",
        screenshot: screenshotPath,
        findings: routeFindings,
        note: routeFindings.length > 0 ? "${routeFindings.length} minor finding(s)" : ""
      }

  catch err:
    routeResults[route] = { status: "ERROR", reason: err.message }

// ============================
// Step 5W: Cross-Screen Workflow Continuity (Layer 5)
// Runs AFTER per-route loop — tests relationships between routes
// ============================

workflowFindings = []
if shouldRunDeep:
  routeGroups = detectCRUDGroups(routes)
  if routeGroups.length > 0:
    log INFO: "Running cross-screen workflow tests for ${routeGroups.length} CRUD group(s)..."
    workflowFindings = runWorkflowContinuityTests(routeGroups, sessionName, baseUrl)
    allDeepFindings.push(...workflowFindings)

// Close session
Bash(`agent-browser close --session "${sessionName}" 2>/dev/null || true`)
```

## Step 5H: Data Diagnosis

When a page has tables, lists, or data displays, diagnose WHY cells/fields might be
empty — is it the API returning null, the UI not rendering, or the data not existing?

```
runDataDiagnosis(route, snapshot, sessionName) → DiagnosisResult[]

  findings = []

  // 1. Detect data display elements (tables, lists, cards with data)
  dataReport = Bash(`agent-browser eval -b "
    const results = { tables: [], lists: [], fields: [] };

    // === TABLE ANALYSIS ===
    document.querySelectorAll('table').forEach((table, ti) => {
      const headers = Array.from(table.querySelectorAll('thead th, thead td'))
        .map(th => th.textContent.trim());
      const rows = Array.from(table.querySelectorAll('tbody tr'));
      const emptyCols = {};  // column index → count of empty cells

      rows.forEach(row => {
        const cells = Array.from(row.querySelectorAll('td'));
        cells.forEach((cell, ci) => {
          const text = cell.textContent.trim();
          const hasChild = cell.querySelector('img, svg, canvas, video');
          if (!text && !hasChild) {
            emptyCols[ci] = (emptyCols[ci] || 0) + 1;
          }
        });
      });

      // Flag columns where >50% of cells are empty
      const emptyColDetails = [];
      for (const [col, count] of Object.entries(emptyCols)) {
        if (count >= rows.length * 0.5 && rows.length > 0) {
          emptyColDetails.push({
            column: parseInt(col),
            header: headers[parseInt(col)] || 'column ' + col,
            emptyCount: count,
            totalRows: rows.length,
            percent: Math.round(count / rows.length * 100)
          });
        }
      }

      if (emptyColDetails.length > 0) {
        results.tables.push({
          index: ti,
          totalRows: rows.length,
          totalCols: headers.length || (rows[0]?.querySelectorAll('td').length || 0),
          emptyCols: emptyColDetails
        });
      }
    });

    // === LIST/CARD ANALYSIS ===
    document.querySelectorAll('[class*=card], [class*=item], [role=listitem]').forEach(card => {
      const textContent = card.textContent.trim();
      const children = Array.from(card.children);

      // Find placeholder/null indicators
      const nullIndicators = ['null', 'undefined', 'N/A', 'n/a', '--', '—', 'NaN', 'loading...'];
      const foundNulls = [];
      children.forEach(child => {
        const text = child.textContent.trim();
        if (nullIndicators.some(n => text === n || text === '')) {
          foundNulls.push({
            tag: child.tagName.toLowerCase(),
            class: child.className?.substring?.(0, 30) || '',
            text: text || '(empty)'
          });
        }
      });

      if (foundNulls.length > 0) {
        results.lists.push({ nullElements: foundNulls });
      }
    });

    // === DETAIL VIEW FIELD ANALYSIS ===
    // Common patterns: label + value pairs (dt/dd, th/td, .label/.value)
    const pairs = [];
    document.querySelectorAll('dl').forEach(dl => {
      const dts = dl.querySelectorAll('dt');
      dts.forEach(dt => {
        const dd = dt.nextElementSibling;
        if (dd && dd.tagName === 'DD') {
          const val = dd.textContent.trim();
          if (!val || val === 'null' || val === 'undefined' || val === '-' || val === 'N/A') {
            pairs.push({ label: dt.textContent.trim(), value: val || '(empty)' });
          }
        }
      });
    });
    if (pairs.length > 0) results.fields = pairs;

    JSON.stringify(results);
  "`)

  try:
    dataState = JSON.parse(dataReport)
  catch:
    return findings  // page has no structured data — skip

  // 2. Diagnose table empty columns
  for each table in dataState.tables:
    for each emptyCol in table.emptyCols:
      // Root cause analysis: check HAR for API response
      apiDiagnosis = diagnoseEmptyColumn(emptyCol, route, sessionName)

      findings.push({
        id: "DATA-EMPTY-COLUMN",
        severity: "high",
        message: "Table column '${emptyCol.header}' is ${emptyCol.percent}% empty (${emptyCol.emptyCount}/${emptyCol.totalRows} rows)",
        diagnosis: apiDiagnosis,
        route: route
      })

  // 3. Diagnose null/undefined values in lists/cards
  for each listItem in dataState.lists:
    for each nullEl in listItem.nullElements:
      findings.push({
        id: "DATA-NULL-DISPLAY",
        severity: "medium",
        message: "Null/empty value displayed: '${nullEl.text}' in ${nullEl.tag}.${nullEl.class}",
        note: "Raw null/undefined should not be visible to users — use fallback display"
      })

  // 4. Diagnose empty detail view fields
  for each field in dataState.fields:
    findings.push({
      id: "DATA-FIELD-EMPTY",
      severity: "medium",
      message: "Detail field '${field.label}' shows '${field.value}' — data may not be loaded or field is null in API response",
      route: route
    })

  // 5. HAR-based root cause analysis (if HAR was recorded)
  harPath = `tmp/test-browser/${sessionName}/har-${route.replace(/\//g, "-")}.har`
  harExists = Bash(`test -f "${harPath}" && echo "yes" || echo "no"`)

  if harExists == "yes":
    harAnalysis = analyzeHARForDataIssues(harPath, route)
    findings.push(...harAnalysis)

  return findings
```

### HAR-Based Root Cause Analysis

```
analyzeHARForDataIssues(harPath, route) → DiagnosisResult[]

  findings = []

  // Read HAR file and analyze API responses
  harContent = Read(harPath)
  try:
    har = JSON.parse(harContent)
  catch:
    return []

  for each entry in har.log.entries:
    request = entry.request
    response = entry.response

    // Skip non-API requests (static assets, etc.)
    if not request.url.includes("/api/") and not request.url.includes("/graphql"):
      continue

    // Check for error responses
    if response.status >= 400:
      findings.push({
        id: "DATA-API-ERROR",
        severity: "high",
        message: "API ${request.method} ${request.url} returned ${response.status}",
        note: "This may explain missing data on the page",
        apiDetails: {
          method: request.method,
          url: request.url,
          status: response.status,
          statusText: response.statusText
        }
      })

    // Check for null fields in successful responses
    if response.status >= 200 and response.status < 300:
      body = response.content?.text
      if body:
        try:
          data = JSON.parse(body)
          nullFields = findNullFields(data, "")
          if nullFields.length > 0:
            findings.push({
              id: "DATA-API-NULL-FIELDS",
              severity: "medium",
              message: "API ${request.url} returns ${nullFields.length} null/empty field(s): ${nullFields.slice(0, 5).join(', ')}",
              note: "Root cause is in the API/database — the UI correctly displays what the API returns",
              nullFields: nullFields.slice(0, 10)
            })
        catch: pass

    // Check for empty array responses (could explain empty tables)
    if response.status == 200:
      body = response.content?.text
      if body:
        try:
          data = JSON.parse(body)
          arrayData = data.data ?? data.results ?? data.items ?? data
          if Array.isArray(arrayData) and arrayData.length == 0:
            findings.push({
              id: "DATA-API-EMPTY-LIST",
              severity: "medium",
              message: "API ${request.url} returns an empty array — table/list will appear empty",
              note: "Check if: (1) data exists in database, (2) query filters are correct, (3) pagination params are valid"
            })
        catch: pass

  return findings

// Helper: recursively find null/empty fields in JSON
findNullFields(obj, prefix) → string[]
  nulls = []
  if obj == null or obj == undefined:
    return [prefix || "root"]
  if typeof obj != "object": return []
  for each [key, value] in Object.entries(obj):
    path = prefix ? "${prefix}.${key}" : key
    if value == null or value == undefined or value === "":
      nulls.push(path)
    else if typeof value == "object" and not Array.isArray(value):
      nulls.push(...findNullFields(value, path))
  return nulls
```

## Step 8: Summary Report

```
// Build markdown table
lines = [
  `# /rune:test-browser — Test Report`,
  ``,
  `**Scope**: ${scope.label}`,
  `**Mode**: ${mode}${shouldRunDeep ? " + DEEP" : ""}`,
  `**Base URL**: ${baseUrl}`,
  `**Routes tested**: ${routes.length} (max: ${effectiveMax})`,
  ``,
  `## Route Results`,
  ``,
  `| Route | Source | Status | Notes |`,
  `|-------|--------|--------|-------|`,
]

for each [route, result] in routeResults:
  notes = result.note ?? result.reason ?? ""
  source = traceSource[route] ?? "frontend"
  sourceLabel = {
    "frontend": "frontend",
    "backend-direct": "API trace",
    "backend-model": "model trace",
    "backend-service": "service trace",
  }[source] ?? source
  lines.push(`| \`${route}\` | ${sourceLabel} | **${result.status}** | ${notes} |`)

// Stats
passed = Object.values(routeResults).filter(r => r.status == "PASS").length
warned = Object.values(routeResults).filter(r => r.status == "WARN").length
failed = Object.values(routeResults).filter(r => r.status == "FAIL").length
partial = Object.values(routeResults).filter(r => r.status == "PARTIAL").length
errors  = Object.values(routeResults).filter(r => r.status == "ERROR").length

lines.push(``)
lines.push(`**Results**: ${passed} pass / ${warned} warn / ${failed} fail / ${partial} partial / ${errors} error`)

// Backend impact summary
tracedCount = Object.values(traceSource).filter(s => s.startsWith("backend")).length
if tracedCount > 0:
  lines.push(``)
  lines.push(`**Backend impact**: ${tracedCount} route(s) discovered via API/model/service tracing`)
  backendFiles = classification.backend.slice(0, 5).join(", ")
  if classification.backend.length > 5:
    backendFiles += `, ... (+${classification.backend.length - 5} more)`
  lines.push(`> Changed backend files: ${backendFiles}`)

// ============================
// DEEP FINDINGS REPORT
// ============================

if allDeepFindings.length > 0:
  lines.push(``)
  lines.push(`## Deep Testing Findings`)
  lines.push(``)

  // Group findings by category
  CATEGORIES = {
    "INT": { label: "Interaction", icon: "click" },
    "DATA": { label: "Data & Persistence", icon: "database" },
    "VIS": { label: "Visual & Layout", icon: "layout" },
    "UX": { label: "UX Logic", icon: "ux" },
    "FLOW": { label: "Workflow Continuity", icon: "flow" },
  }

  for each [prefix, meta] in CATEGORIES:
    categoryFindings = allDeepFindings.filter(f => f.id.startsWith(prefix + "-"))
    if categoryFindings.length == 0: continue

    critical = categoryFindings.filter(f => f.severity == "critical").length
    high = categoryFindings.filter(f => f.severity == "high").length
    medium = categoryFindings.filter(f => f.severity == "medium").length
    low = categoryFindings.filter(f => f.severity == "low").length

    lines.push(`### ${meta.label} (${categoryFindings.length} finding(s))`)
    lines.push(``)
    lines.push(`| ID | Severity | Route | Description |`)
    lines.push(`|----|----------|-------|-------------|`)

    // Sort: critical > high > medium > low
    sorted = categoryFindings.sort((a, b) => {
      order = { critical: 0, high: 1, medium: 2, low: 3 }
      return (order[a.severity] ?? 4) - (order[b.severity] ?? 4)
    })

    for each finding in sorted:
      desc = finding.message
      if finding.diagnosis: desc += ` — ${finding.diagnosis}`
      if finding.note: desc += ` (${finding.note})`
      lines.push(`| \`${finding.id}\` | **${finding.severity}** | \`${finding.route}\` | ${desc} |`)

    lines.push(``)

  // Summary stats for deep findings
  totalCritical = allDeepFindings.filter(f => f.severity == "critical").length
  totalHigh = allDeepFindings.filter(f => f.severity == "high").length
  totalMedium = allDeepFindings.filter(f => f.severity == "medium").length
  totalLow = allDeepFindings.filter(f => f.severity == "low").length

  lines.push(`**Deep findings total**: ${allDeepFindings.length} (${totalCritical} critical, ${totalHigh} high, ${totalMedium} medium, ${totalLow} low)`)

// Workflow continuity summary
if workflowFindings.length > 0:
  lines.push(``)
  lines.push(`## Workflow Continuity`)
  lines.push(``)
  flowCritical = workflowFindings.filter(f => f.severity == "critical")
  if flowCritical.length > 0:
    lines.push(`**CRITICAL**: ${flowCritical.length} cross-screen data flow issue(s) detected:`)
    for each f in flowCritical:
      lines.push(`- ${f.message}`)
  lines.push(``)
  lines.push(`> Tested ${routeGroups.length} CRUD group(s) across ${routes.length} route(s)`)

// Human gate summary
gatedRoutes = Object.entries(routeResults).filter(([_, r]) => r.reason?.includes("Human gate"))
if gatedRoutes.length > 0:
  lines.push(``)
  lines.push(`**Human gates**: ${gatedRoutes.length} route(s) required out-of-band verification`)
  lines.push(`> Note: AskUserQuestion has no timeout — gate pauses block indefinitely if unattended.`)

lines.push(``)
lines.push(`**Screenshots**: tmp/test-browser/${sessionName}/`)

report = lines.join("\n")
log INFO: report
```
