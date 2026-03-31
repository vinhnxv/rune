---
name: test-browser
description: |
  Standalone browser E2E testing skill. Runs agent-browser tests against changed routes
  from a PR, branch, or current HEAD — without spawning an agent team.

  Supports both frontend AND backend changes: when only backend/API/database files
  change, traces impact forward to discover consuming frontend routes and tests them.
  Pipeline: backend file → API endpoint → frontend consumer → page → route.

  Use when the user says "test browser", "run browser tests", "E2E test my changes",
  "test routes", "browser test PR", "test-browser", "test API changes",
  "test backend impact", or invokes /rune:test-browser.

  Scope input (optional first argument):
    - PR number (e.g., "42") → fetches changed files from gh pr view
    - Branch name (e.g., "feature/login") → diffs against default branch
    - Empty → diffs current HEAD against default branch

  Flags:
    --headed      Show browser window (requires display server)
    --deep        Enable deep testing: interaction, data persistence, visual/layout, UX, workflow continuity
    --max-routes  Cap route count (default 5, auto-capped to 3 with --deep)

  Keywords: browser test, E2E test, agent-browser, standalone test, route test,
  PR test, frontend test, backend test, API test, data flow test, UI verify,
  screenshot, browser automation, backend impact, user flow.

  <example>
  user: "/rune:test-browser 42"
  assistant: "Fetching changed files from PR #42, mapping to routes, running browser tests..."
  </example>

  <example>
  user: "/rune:test-browser feature/auth --headed"
  assistant: "Diffing feature/auth vs main, running headed browser tests on changed routes..."
  </example>

  <example>
  user: "/rune:test-browser --max-routes 3"
  assistant: "Testing current branch changes (capped at 3 routes)..."
  </example>

  <example>
  user: "/rune:test-browser 55"
  assistant: "PR #55 has only backend changes (API controllers, models). Tracing impact to frontend... Found 3 consuming routes: /users, /dashboard, /settings. Running browser tests..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[PR# | branch-name] [--headed] [--deep] [--max-routes N]"
---

# /rune:test-browser — Standalone Browser E2E Testing

Runs browser E2E tests against changed routes without spawning an agent team.
Designed for interactive failure handling during development — no team coordination overhead.

**Load skills**: agent-browser, testing, zsh-compat

```
# ISOLATION CONTRACT
# This skill MUST NOT call TeamCreate, Agent, or Task.
# All execution is inline — no agent teams, no background workers.
# Rationale: standalone mode enables interactive failure recovery and simpler state management.
```

**References**:
- [scope-detection.md](../testing/references/scope-detection.md) — resolveTestScope() algorithm
- [test-discovery.md](../testing/references/test-discovery.md) — diff-scoped route discovery
- [service-startup.md](../testing/references/service-startup.md) — verifyServerWithSnapshot()
- [file-route-mapping.md](../testing/references/file-route-mapping.md) — framework-specific route mapping
- [backend-impact-tracing.md](references/backend-impact-tracing.md) — backend → API → frontend → route tracing
- [deep-testing-layers.md](references/deep-testing-layers.md) — interaction, data persistence, visual, UX, workflow continuity
- [human-gates.md](references/human-gates.md) — OAuth/payment/2FA gate handling
- [failure-handling.md](references/failure-handling.md) — interactive failure recovery

## Argument Parsing

Parse `$ARGUMENTS` before starting:

```
args = $ARGUMENTS.trim().split(/\s+/)

// Flags
headed = args.includes("--headed")
deep = args.includes("--deep")

// --max-routes N
maxRoutesIdx = args.indexOf("--max-routes")
maxRoutes = maxRoutesIdx >= 0 ? parseInt(args[maxRoutesIdx + 1], 10) || 5 : 5

// Scope: first positional arg (not a flag, not the value after --max-routes)
flagsWithValues = ["--max-routes"]
scopeInput = args.filter((a, i) => {
  if (a.startsWith("--")) return false                    // skip flags
  if (i > 0 && flagsWithValues.includes(args[i - 1])) return false  // skip flag values
  return true
})[0] ?? ""

// Validate maxRoutes (injection prevention — must be a positive integer)
if isNaN(maxRoutes) OR maxRoutes < 1 OR maxRoutes > 50:
  maxRoutes = 5
```

## Workflow Overview

| Step | Name | Description |
|------|------|-------------|
| 0 | Installation Guard | Check agent-browser is available |
| 1 | Scope Detection | Resolve changed files via resolveTestScope() |
| 1.5 | Backend Impact Tracing | If backend-only: trace API → frontend consumers → routes |
| 2 | Route Discovery | Map changed files to testable URLs (frontend + traced routes) |
| 3 | Mode Selection | Headed vs headless determination |
| 4 | Server Verification | Confirm dev server is up via verifyServerWithSnapshot |
| 5 | Test Loop | Per-route: navigate → snapshot → core assertions → screenshot |
| 5D | Deep: Interaction | `--deep`: fill forms, click buttons, verify elements respond |
| 5E | Deep: Data Persistence | `--deep`: submit form → navigate away → return → verify data saved |
| 5F | Deep: Visual/Layout | `--deep`: overflow, spacing, touch targets, responsive breakpoints |
| 5G | Deep: UX Logic | `--deep`: empty states, loading, a11y, error handling, destructive actions |
| 5H | Deep: Data Diagnosis | `--deep`: HAR analysis, null/empty column detection, API vs UI root cause |
| 5W | Deep: Workflow Continuity | `--deep`: Create→List→Edit→Save cross-screen CRUD verification |
| 6 | Human Gates | Pause for OAuth/payment/2FA flows (standalone only) |
| 7 | Failure Handling | Offer Fix / Todo / Skip for each failure |
| 8 | Summary Report | Full report: per-route + findings by category + screenshots |

---

## Step 0: Installation Guard

```
result = Bash(`agent-browser --version 2>/dev/null`)
if result is empty OR exit code != 0:
  STOP with message:
    "agent-browser is not installed or not in PATH.
    Install with: npm install -g @vercel/agent-browser
    (Requires explicit user consent for global installation)
    /rune:test-browser cannot proceed without agent-browser."
```

Do NOT auto-install. User consent for global tool installations is mandatory.

## Step 1: Scope Detection

```
scope = resolveTestScope(scopeInput)
// Returns: { files: string[], source: "pr" | "branch" | "current", label: string }
// See references/scope-detection.md for full algorithm.

log INFO: "Test scope: ${scope.label} (${scope.files.length} changed files)"

if scope.files.length == 0:
  WARN: "No diff scope detected — will attempt full-repo E2E discovery (may be slow)"
```

## Step 1.5: Backend Impact Tracing

When the diff contains backend/API/database files, trace their impact to frontend routes.
See [backend-impact-tracing.md](references/backend-impact-tracing.md) for full algorithm.

```
// Classify changed files
classification = classifyChangedFiles(scope.files)
// → { frontend: string[], backend: string[], shared: string[] }

hasFrontend = classification.frontend.length > 0
hasBackend  = classification.backend.length > 0

tracedRoutes = []
traceSource = {}  // route → "frontend" | "backend-direct" | "backend-model" | "backend-service"

if hasBackend:
  log INFO: "Backend files detected (${classification.backend.length}). Tracing impact to frontend..."

  // Layer 1: Extract API endpoints from changed backend files
  endpoints = extractAPIEndpoints(classification.backend)
  log INFO: "API endpoints found: ${endpoints.length > 0 ? endpoints.join(', ') : 'none (will try model/service tracing)'}"

  // Layer 2: Model/migration → endpoint tracing
  modelFiles = classification.backend.filter(f => isModelOrMigration(f))
  if modelFiles.length > 0:
    modelEndpoints = traceModelToEndpoints(modelFiles)
    endpoints = unique([...endpoints, ...modelEndpoints])

  // Layer 3: Service → endpoint tracing
  serviceFiles = classification.backend.filter(f => isServiceFile(f))
  if serviceFiles.length > 0:
    serviceEndpoints = traceServiceToEndpoints(serviceFiles)
    endpoints = unique([...endpoints, ...serviceEndpoints])

  // Layer 4: Fallback — extract resource names from file paths
  if endpoints.length == 0:
    resourceNames = classification.backend.map(f => extractResourceName(f)).filter(Boolean)
    log INFO: "No explicit endpoints. Trying resource name fallback: ${resourceNames.join(', ')}"
    // Use resource names as search terms in frontend consumer discovery
    endpoints = resourceNames.map(name => `/api/${name}`)

  // Discover frontend consumers for all endpoints
  if endpoints.length > 0:
    consumers = discoverFrontendConsumers(endpoints)
    tracedRoutes = unique(consumers.map(c => c.route))
    for each consumer in consumers:
      traceSource[consumer.route] = consumer.confidence ?? "backend-direct"

  if tracedRoutes.length > 0:
    log INFO: "Backend impact traced to ${tracedRoutes.length} frontend route(s): ${tracedRoutes.join(', ')}"
  else if NOT hasFrontend:
    log WARN: "Backend changes detected but no consuming frontend routes found."
    log WARN: "This may mean: (1) API is consumed by external clients only, (2) frontend uses a different API pattern, or (3) the frontend code is in a separate repo."
    // Don't STOP yet — let Step 2 handle the final decision
```

## Step 2: Route Discovery

```
// Map changed files to testable routes using E2E Route Discovery algorithm
// See testing/references/test-discovery.md — "E2E Route Discovery" section
// See testing/references/file-route-mapping.md — framework-specific patterns

// Start with frontend-direct routes
frontendRoutes = []
if hasFrontend:
  frontendRoutes = discoverE2ERoutes(classification.frontend)
  for each route in frontendRoutes:
    traceSource[route] = traceSource[route] ?? "frontend"

// Combine: frontend-direct routes + backend-traced routes (deduplicated)
allRoutes = unique([...frontendRoutes, ...tracedRoutes])

// Cap at maxRoutes (from argument or talisman)
// testingConfig hoisted — single readTalismanSection call for entire skill
testingConfig = readTalismanSection("testing")
talismanMax = testingConfig?.testing?.tiers?.e2e?.max_routes ?? 5
effectiveMax = Math.min(maxRoutes, talismanMax)

// Priority: frontend-direct first, then HIGH confidence traces, then MEDIUM, then LOW
allRoutes = prioritizeRoutes(allRoutes, traceSource)
routes = allRoutes.slice(0, effectiveMax)

if routes.length == 0:
  log WARN: "No testable routes found for changed files."
  log WARN: "Changed files: ${scope.files.join(', ')}"
  if hasBackend AND NOT hasFrontend:
    STOP with message:
      "No frontend routes found that consume the changed backend APIs.
      Possible reasons:
        - The API is consumed by external/mobile clients only
        - Frontend uses a different API calling pattern (check fetch/axios/trpc patterns)
        - Frontend code lives in a separate repository
      Consider running integration tests instead: check test files for API endpoint coverage."
  else:
    STOP with message: "No routes to test. Verify that changed files map to frontend views."

// Log route sources for transparency
for each route in routes:
  source = traceSource[route] ?? "unknown"
  log INFO: "  ${route} (source: ${source})"

log INFO: "Routes to test (${routes.length}): ${routes.join(', ')}"
```

## Step 3: Headed/Headless Mode

```
// Priority: --headed flag > talisman config > headless default
// NOTE: DISPLAY env var intentionally not used — prevents unintended headed mode in CI

if headed:
  mode = "headed"
  modeFlag = "--headed"
else:
  talismanHeaded = testingConfig?.testing?.browser?.headed ?? false

  if talismanHeaded:
    mode = "headed"
    modeFlag = "--headed"
  else:
    mode = "headless"
    modeFlag = ""

log INFO: "Browser mode: ${mode}"

// Warn if headed on a remote/CI machine
if mode == "headed":
  WARN: "--headed mode requires a display server. Do not use on shared/remote machines."
```

## Step 4: Server Verification

```
// Verify the dev server is responding before running tests
// verifyServerWithSnapshot is defined in testing/references/service-startup.md

baseUrl = testingConfig?.testing?.tiers?.e2e?.base_url ?? "http://localhost:3000"
sessionName = `test-browser-${Date.now()}`

verifyResult = verifyServerWithSnapshot(baseUrl, sessionName)
// verifyServerWithSnapshot opens a page, takes a snapshot, and checks for blank/error states.

if verifyResult != "ok":
  // Standalone mode: abort with instructions
  // verifyServerWithSnapshot returns "ok" | "blank" | "error" | "loading" (plain string)
  instructionMap = {
    "error": "The page returned a server error.",
    "blank": "The page appears blank or empty.",
    "loading": "The page did not finish loading."
  }
  STOP with message:
    "Dev server not responding at ${baseUrl}.
    ${instructionMap[verifyResult] ?? 'Unknown verification issue.'}
    Start your server and re-run /rune:test-browser."
```

## Steps 5-8: Test Loop, Deep Testing, Failure Handling, Report

### Smoke Test (always)
Per-route: navigate → wait networkidle → snapshot → human gate check ([human-gates.md](references/human-gates.md)) → core assertions (console errors, blank/error patterns, snapshot length) → screenshot.

### Deep Testing (with `--deep` or `testing.browser.deep: true`)
After smoke passes, 5 additional layers run per route. See [deep-testing-layers.md](references/deep-testing-layers.md) for full algorithms:

| Layer | ID Prefix | What it checks |
|-------|-----------|----------------|
| **Interaction** | `INT-` | Fill forms, click buttons, verify elements respond, link health |
| **Data Persistence** | `DATA-` | Submit → navigate away → return → verify data saved. HAR recording for API call analysis |
| **Visual/Layout** | `VIS-` | Overflow, negative margins, sibling overlap, touch targets (<44px), text truncation, inconsistent spacing, responsive breakpoints (mobile/tablet/desktop) |
| **UX Logic** | `UX-` | Empty states, stuck loading, accessibility (labels, alt text, heading hierarchy, keyboard focus), error state handling, destructive action confirmation |
| **Data Diagnosis** | `DATA-` | Table empty columns (>50% null), null/undefined displayed raw, detail view empty fields, **HAR-based root cause** (API error? API returns null? Empty array?) |

### Workflow Continuity (with `--deep` + 2+ related routes)
After per-route loop, tests cross-screen relationships. See [deep-testing-layers.md](references/deep-testing-layers.md) Layer 5:

| Phase | What it tests |
|-------|---------------|
| **Create → List** | Fill create form → submit → navigate to list → verify data appears |
| **List → Detail/Edit** | Click list item → verify detail page loads with data |
| **Edit → Save → Verify** | Modify field → save → navigate away → return → verify change persisted |

Findings use `FLOW-` prefix with severity `critical` for data flow breaks.

### Failure Handling + Report
Interactive Fix/Todo/Skip per failure ([failure-handling.md](references/failure-handling.md)). Report includes per-route status table, deep findings grouped by category (INT/DATA/VIS/UX/FLOW), severity breakdown, and workflow continuity summary.

See [test-loop-and-report.md](references/test-loop-and-report.md) for the full Step 5 test loop, deep mode activation, and Step 8 report template pseudocode.

## Version Guards for agent-browser Features

Before using version-gated features, check availability:

```
agentBrowserVersion = Bash(`agent-browser --version 2>/dev/null`).trim()
// e.g., "0.15.2" or "agent-browser/0.13.0"
// Parse: extract semver from output

parseVersion(vStr) → { major, minor, patch }
  match = vStr.match(/(\d+)\.(\d+)\.(\d+)/)
  if not match: return { major: 0, minor: 0, patch: 0 }
  return { major: int(match[1]), minor: int(match[2]), patch: int(match[3]) }

v = parseVersion(agentBrowserVersion)

// Feature gates
canAnnotate    = v.minor >= 12  // --annotate flag (v0.12.0+)
canDiff        = v.minor >= 13  // diff subcommand (v0.13.0+)
hasDomainAllow = v.minor >= 15  // AGENT_BROWSER_ALLOWED_DOMAINS (v0.15.0+)
hasAuthVault   = v.minor >= 15  // agent-browser auth save/login (v0.15.0+)
hasContentBounds = v.minor >= 15  // AGENT_BROWSER_CONTENT_BOUNDARIES (v0.15.0+)
```

Use `canAnnotate`, `canDiff`, etc. before calling version-gated commands.
Always fail gracefully (skip the feature, not the entire test run) when gated.

## Key Differences from arc Phase 7.7

| Aspect | /rune:test-browser | arc Phase 7.7 TEST |
|--------|-------------------|--------------------|
| Agent teams | None — inline execution | Yes — 4 testing agents |
| Scope input | PR#, branch, or current | Arc plan scope |
| Failure handling | Interactive (FIX/TODO/SKIP) | Analyst agent |
| Human gates | AskUserQuestion pause | Auto-skip (PARTIAL) |
| Server startup | Must already be running | Auto-detect + start |
| Test tiers | E2E only | Unit + Integration + E2E |
| Parallel execution | No — serial per route | Yes — parallel workers |
| Use case | Development feedback | CI / arc pipeline |

## Talisman Configuration

```yaml
testing:
  max_routes: 5            # Default cap for route testing (auto-capped to 3 with --deep)
  browser:
    headed: false          # Default headless; override with --headed flag
    deep: false            # Default off; override with --deep flag
  human_gates:
    enabled: true          # Set false to auto-skip all gates
  tiers:
    e2e:
      base_url: "http://localhost:3000"  # Override if app runs on different port
```

### Deep Mode Performance

| Mode | Per-route time | Max recommended routes |
|------|---------------|----------------------|
| Smoke only | ~5-10s | 5 (default) |
| `--deep` | ~40-60s | 3 (auto-capped) |
| `--deep` + workflow | ~60-100s per CRUD group | 3 |
