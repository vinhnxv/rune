# Step 5: Per-Route Test Loop + Step 8: Summary Report

## Step 5: Per-Route Test Loop

```
routeResults = {}

for each route in routes:
  log INFO: "Testing route: ${route}"
  fullUrl = baseUrl + route

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

    // Core assertions
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
    passed = (errorCount == 0 AND snapshot.length > 50 AND NOT hasErrorContent)

    // Screenshot (always — for pass documentation and failure diagnosis)
    screenshotPath = `tmp/test-browser/${sessionName}/${route.replace(/\//g, "-").replace(/^-/, "")}.png`
    Bash(`mkdir -p "$(dirname "${screenshotPath}")"`)
    Bash(`agent-browser screenshot "${screenshotPath}"`)

    if passed:
      routeResults[route] = { status: "PASS", screenshot: screenshotPath }
    else:
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
        routeResults[route] = { status: "PASS", note: "Fixed inline", screenshot: screenshotPath }
      else if result == "todo-created":
        routeResults[route] = { status: "FAIL", note: "Todo created", screenshot: screenshotPath }
      else:
        routeResults[route] = { status: "FAIL", note: "Skipped", screenshot: screenshotPath }

  catch err:
    routeResults[route] = { status: "ERROR", reason: err.message }

// Close session
Bash(`agent-browser close --session "${sessionName}" 2>/dev/null || true`)
```

## Step 8: Summary Report

```
// Build markdown table
lines = [
  `# /rune:test-browser — Test Report`,
  ``,
  `**Scope**: ${scope.label}`,
  `**Mode**: ${mode}`,
  `**Base URL**: ${baseUrl}`,
  `**Routes tested**: ${routes.length} (max: ${effectiveMax})`,
  ``,
  `| Route | Status | Notes |`,
  `|-------|--------|-------|`,
]

for each [route, result] in routeResults:
  notes = result.note ?? result.reason ?? ""
  lines.push(`| \`${route}\` | **${result.status}** | ${notes} |`)

// Stats
passed = Object.values(routeResults).filter(r => r.status == "PASS").length
failed = Object.values(routeResults).filter(r => r.status == "FAIL").length
partial = Object.values(routeResults).filter(r => r.status == "PARTIAL").length
errors  = Object.values(routeResults).filter(r => r.status == "ERROR").length

lines.push(``)
lines.push(`**Results**: ${passed} pass / ${failed} fail / ${partial} partial / ${errors} error`)

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
