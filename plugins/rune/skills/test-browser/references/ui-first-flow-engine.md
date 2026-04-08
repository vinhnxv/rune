# UI-First Flow Execution Engine

Executes test cases through real browser interactions following the dependency chain from
the test plan. All test data is created through the UI — never via direct API calls, SQL,
or seed scripts. Browser session state (cookies, auth tokens) carries forward between flows.

**Key rules**:
- **NEVER** use `fetch()`, `curl`, or direct API calls to create test data
- **NEVER** use SQL/database operations to seed data
- **NEVER** assume data exists — if it's needed, create it through the UI
- **ALWAYS** verify each prerequisite flow completed before proceeding
- **ALWAYS** carry forward browser session state (cookies, auth tokens)

**Contract**:
```
Input:
  - testPlan (from test-plan-generation: test cases with dependency chain)
  - infrastructure (from infrastructure-discovery: base URL, credentials)
  - sessionName (browser session identifier)

Output:
  - Per-test-case results in tmp/test-browser-{timestamp}/results/
  - Screenshots in tmp/test-browser-{timestamp}/screenshots/
  - Session state (credentials created, entities created) carried forward
```

## Flow Execution Algorithm

```
executeUIFirstFlows(testPlan, infrastructure, sessionName, timestamp) → ExecutionResults

  results = {}
  sessionState = {
    credentials: infrastructure.credentials ?? null,
    createdEntities: {},   // track what was created in each flow
    isLoggedIn: false,
    currentUser: null
  }
  allAnomalies = []

  workspacePath = `tmp/test-browser-${timestamp}`

  // ═══════════════════════════════════════════
  // Execute in dependency order
  // ═══════════════════════════════════════════

  for each tcId in testPlan.executionOrder:
    tc = testPlan.testCases.find(t => t.id == tcId)

    log INFO: "Executing ${tc.id}: ${tc.scenario} (${tc.type})"

    // Check dependencies completed
    for each depId in tc.depends_on:
      if results[depId]?.status != "PASS":
        log WARN: "Dependency ${depId} did not pass. ${tc.id} may fail."
        // Don't skip — still attempt, but log the dependency failure

    try:
      // Navigate to route (reusing existing browser session for state)
      fullUrl = infrastructure.base_url + tc.route
      Bash(`agent-browser open "${fullUrl}" ${modeFlag} --session "${sessionName}"`)
      Bash(`agent-browser wait --load networkidle`)
      // SPA hydration fallback — networkidle may not trigger for client-side routing
      Bash(`agent-browser wait 1000`)

      // Take "before" screenshot
      beforeScreenshot = `${workspacePath}/screenshots/${tc.id}-before.png`
      Bash(`mkdir -p "${workspacePath}/screenshots"`)
      Bash(`agent-browser screenshot "${beforeScreenshot}"`)

      // Get initial snapshot
      snapshot = Bash(`agent-browser snapshot -i`)

      // ═══════════════════════════════════════
      // Execute test case steps through UI
      // ═══════════════════════════════════════

      stepResults = executeTestCaseSteps(tc, snapshot, sessionState, sessionName)

      // Take "after" screenshot
      afterScreenshot = `${workspacePath}/screenshots/${tc.id}-after.png`
      Bash(`agent-browser screenshot "${afterScreenshot}"`)

      // Get final snapshot for verification
      finalSnapshot = Bash(`agent-browser snapshot -i`)

      // ═══════════════════════════════════════
      // Verify expected results
      // ═══════════════════════════════════════

      verification = verifyExpectedResults(tc, finalSnapshot, stepResults)

      // Update session state with what was created/achieved
      if tc.type == "prerequisite":
        if tc.scenario.match(/register/i) and verification.passed:
          sessionState.credentials = stepResults.usedCredentials
          sessionState.createdEntities.user = stepResults.createdData
        if tc.scenario.match(/login/i) and verification.passed:
          sessionState.isLoggedIn = true
          sessionState.currentUser = sessionState.credentials?.email

      // ═══════════════════════════════════════
      // Capture anomalies during execution
      // ═══════════════════════════════════════

      // Check console errors (may reveal bugs outside PR scope)
      consoleErrors = Bash(`agent-browser errors`)
      if consoleErrors.trim():
        for each error in consoleErrors.trim().split("\n"):
          allAnomalies.push({
            type: "console-error",
            during: tc.id,
            message: error,
            route: tc.route,
            in_scope: isErrorRelatedToPR(error, scope)
          })

      // Check for slow responses, unexpected redirects, visual glitches
      anomalies = detectAnomalies(tc, finalSnapshot, stepResults)
      allAnomalies.push(...anomalies)

      // Write per-test-case result
      results[tc.id] = {
        status: verification.passed ? "PASS" : "FAIL",
        scenario: tc.scenario,
        type: tc.type,
        route: tc.route,
        steps_completed: stepResults.completedSteps,
        steps_total: tc.steps.length,
        verification: verification,
        screenshots: { before: beforeScreenshot, after: afterScreenshot },
        anomalies: anomalies,
        duration_ms: stepResults.duration_ms
      }

      // Write individual result file
      Write(`${workspacePath}/results/${tc.id}-result.md`, formatTestCaseResult(results[tc.id]))

    catch err:
      // Capture error screenshot
      errorScreenshot = `${workspacePath}/screenshots/${tc.id}-error.png`
      Bash(`agent-browser screenshot "${errorScreenshot}" 2>/dev/null || true`)

      results[tc.id] = {
        status: "ERROR",
        scenario: tc.scenario,
        route: tc.route,
        error: err.message,
        screenshots: { error: errorScreenshot }
      }

      allAnomalies.push({
        type: "execution-error",
        during: tc.id,
        message: err.message,
        route: tc.route,
        in_scope: true
      })

      Write(`${workspacePath}/results/${tc.id}-result.md`, formatTestCaseResult(results[tc.id]))

  return { results, allAnomalies, sessionState }
```

## Test Case Step Execution

The LLM-driven UI interaction engine. Reads the page snapshot, matches form fields to
test plan steps, fills fields, clicks buttons, and verifies results — all through the
real browser.

```
executeTestCaseSteps(tc, snapshot, sessionState, sessionName) → StepResults

  completedSteps = 0
  usedCredentials = null
  createdData = {}
  startTime = Date.now()

  for each step in tc.steps:
    // Refresh snapshot to see current page state
    if completedSteps > 0:
      snapshot = Bash(`agent-browser snapshot -i`)

    // Match step to page elements
    // The LLM reads the snapshot and determines which element to interact with

    if step.action == "fill":
      // Find the matching input element in snapshot
      element = findMatchingElement(snapshot, step.target)

      // Fallback: semantic locators if @e ref matching fails
      if not element:
        semanticResult = Bash(`agent-browser find label "${step.target}" 2>/dev/null`).trim()
        if semanticResult:
          element = parseSemanticResult(semanticResult)

      // Last resort: wait for dynamic content, re-snapshot, retry once
      if not element:
        Bash(`agent-browser wait 2000`)
        snapshot = Bash(`agent-browser snapshot -i`)
        element = findMatchingElement(snapshot, step.target)

      if not element:
        log WARN: "Cannot find element for step: ${step.description}"
        continue

      // Determine value to fill
      value = step.value
      if step.target.match(/email/i) and sessionState.credentials?.email:
        value = sessionState.credentials.email
      if step.target.match(/password/i) and sessionState.credentials?.password:
        value = sessionState.credentials.password
      if not value:
        // Generate unique values per test run to avoid collisions
        // email: test-{timestamp}-{tcId}@example.com
        // password: TestPass1! (satisfies most rules: uppercase, lowercase, number, special)
        // phone: +1555{timestamp.slice(-7)} (E.164 test prefix)
        value = generateTestValue({ type: step.input_type, label: step.target, tcId: tc.id, timestamp })

      Bash(`agent-browser fill ${element.ref} "${value}"`)
      usedCredentials = usedCredentials ?? {}
      if step.target.match(/email/i): usedCredentials.email = value
      if step.target.match(/password/i): usedCredentials.password = value

    if step.action == "click":
      element = findMatchingElement(snapshot, step.target)
      if not element:
        log WARN: "Cannot find clickable element: ${step.description}"
        continue
      Bash(`agent-browser click ${element.ref}`)

    if step.action == "wait":
      Bash(`agent-browser wait --load networkidle`)
      Bash(`agent-browser wait ${step.duration_ms ?? 1000}`)

    if step.action == "verify":
      // Check that expected content/state exists in page
      currentSnapshot = Bash(`agent-browser snapshot -i`)
      if not currentSnapshot.includes(step.expected_content):
        log WARN: "Verification failed at step ${completedSteps + 1}: expected '${step.expected_content}'"

    completedSteps++

  return {
    completedSteps,
    totalSteps: tc.steps.length,
    usedCredentials,
    createdData,
    duration_ms: Date.now() - startTime
  }
```

## Test Value Generation

```
generateTestValue({ type, label, tcId, timestamp }) → string

  // Generate unique, valid test data per run to avoid collisions
  suffix = `${timestamp}-${tcId}`.replace(/[^a-z0-9]/gi, "").slice(-8)

  if type == "email" or label.match(/email/i):
    return `test-${suffix}@example.com`

  if type == "password" or label.match(/password/i):
    // Satisfies common password rules: uppercase, lowercase, number, special char, 8+ chars
    return "TestPass1!"

  if type == "phone" or label.match(/phone|tel/i):
    return `+1555${suffix.slice(-7).padStart(7, "0")}`

  if type == "name" or label.match(/name/i):
    if label.match(/first/i): return "Test"
    if label.match(/last/i): return `User${suffix.slice(-4)}`
    return `TestUser${suffix.slice(-4)}`

  if type == "url" or label.match(/url|website/i):
    return `https://example.com/${suffix}`

  if type == "number" or label.match(/amount|quantity|count/i):
    return "1"

  // Default: short readable string
  return `test-${suffix}`
```

## Element Matching

```
findMatchingElement(snapshot, target) → { ref: string } | null

  // The snapshot from agent-browser contains elements with @e references:
  //   <input @e=42 type="email" placeholder="Enter email">
  //   <button @e=55>Sign Up</button>

  // Strategy: match target description against element attributes
  //   1. Exact label/name match
  //   2. Placeholder text match
  //   3. aria-label match
  //   4. Nearby text (preceding <label> or sibling text)

  // Parse snapshot for interactive elements
  elements = parseSnapshotElements(snapshot)

  for each element in elements:
    if element.label?.toLowerCase() == target.toLowerCase():
      return { ref: `@e=${element.ref}` }
    if element.placeholder?.toLowerCase().includes(target.toLowerCase()):
      return { ref: `@e=${element.ref}` }
    if element.ariaLabel?.toLowerCase().includes(target.toLowerCase()):
      return { ref: `@e=${element.ref}` }
    if element.text?.toLowerCase().includes(target.toLowerCase()):
      return { ref: `@e=${element.ref}` }

  return null


parseSemanticResult(output) → { ref: string } | null

  // agent-browser find returns: "Found: @e=42 <input type='email'>"
  match = output.match(/@e=(\d+)/)
  if match:
    return { ref: `@e=${match[1]}` }
  return null
```

## Result Verification

```
verifyExpectedResults(tc, finalSnapshot, stepResults) → { passed: boolean, details: string[] }

  details = []
  passed = true

  // 1. All steps completed
  if stepResults.completedSteps < stepResults.totalSteps:
    details.push(`Only ${stepResults.completedSteps}/${stepResults.totalSteps} steps completed`)
    passed = false

  // 2. Expected content visible in final snapshot
  if tc.expected:
    // LLM evaluates: does the final page state match the expected outcome?
    // e.g., "Account created, redirected to dashboard" → check for dashboard elements
    // This is intentionally LLM-driven — not string matching — for robustness
    expectedCheck = llmVerifyExpectation(tc.expected, finalSnapshot)
    if not expectedCheck.satisfied:
      details.push(`Expected: "${tc.expected}" — Not satisfied: ${expectedCheck.reason}`)
      passed = false
    else:
      details.push(`Expected: "${tc.expected}" — Verified`)

  // 3. No critical console errors
  consoleErrors = Bash(`agent-browser errors`)
  criticalErrors = consoleErrors.trim().split("\n").filter(e =>
    e.match(/TypeError|ReferenceError|SyntaxError|Uncaught|FATAL/i)
  )
  if criticalErrors.length > 0:
    details.push(`Critical console errors: ${criticalErrors.length}`)
    passed = false

  // 4. Page not in error state
  BLANK_PATTERNS = ["error", "exception", "not found", "503", "500", "502"]
  snapshotLower = finalSnapshot.toLowerCase()
  // Only fail if error patterns appear in prominent page elements (title, h1, main)
  // Avoid false positives from footer text or marketing copy
  if BLANK_PATTERNS.some(p => snapshotLower.slice(0, 500).includes(p)):
    details.push("Page appears to be in error state")
    passed = false

  return { passed, details }
```

## Test Case Result Formatting

```
formatTestCaseResult(result) → string

  statusEmoji = { PASS: "PASS", FAIL: "FAIL", ERROR: "ERROR" }[result.status]

  output = `# ${result.id}: ${result.scenario}

**Status**: ${statusEmoji}
**Type**: ${result.type}
**Route**: ${result.route}
`

  if result.steps_completed != null:
    output += `**Steps**: ${result.steps_completed}/${result.steps_total} completed\n`

  if result.duration_ms:
    output += `**Duration**: ${result.duration_ms}ms\n`

  if result.error:
    output += `\n## Error\n\`\`\`\n${result.error}\n\`\`\`\n`

  if result.verification?.details?.length > 0:
    output += `\n## Verification\n`
    for each detail in result.verification.details:
      output += `- ${detail}\n`

  if result.screenshots:
    output += `\n## Screenshots\n`
    for each [label, path] in Object.entries(result.screenshots):
      output += `- ${label}: ${path}\n`

  if result.anomalies?.length > 0:
    output += `\n## Anomalies\n`
    for each anomaly in result.anomalies:
      output += `- [${anomaly.type}] ${anomaly.message}\n`

  return output
```
