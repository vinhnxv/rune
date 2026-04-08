# Phase 7.7.5: Browser Test (Browser E2E Test Execution)

Runs browser E2E tests on changed routes using `agent-browser` CLI. Part of the
browser test convergence loop: `browser_test` → `browser_test_fix` → `verify_browser_test`.

**Team**: `arc-browser-test-{id}` (1+ browser-tester agents, one per route batch)
**Tools**: Read, Write, Glob, Grep, Bash, Agent, TeamCreate, TaskCreate, SendMessage
**Duration**: Max 15 minutes

**Conditional activation**: Only runs when ALL conditions are met:
1. Frontend files detected in the diff (`has_frontend` from Phase 7.7 test checkpoint)
2. `testing.tiers.e2e.enabled !== false` in talisman
3. `agent-browser` CLI is available (`command -v agent-browser`)
4. `--no-test` and `--no-browser-test` flags are NOT set

When skipped, all 3 phases (`browser_test`, `browser_test_fix`, `verify_browser_test`)
get `status: "skipped"` and the pipeline proceeds to `test_coverage_critique`.

## Entry Guard (Skip Cascade)

```javascript
// ═══════════════════════════════════════════════════════
// STEP 0: PRE-FLIGHT GUARDS (skip cascade)
// ═══════════════════════════════════════════════════════

// Guard 1: Check --no-browser-test flag (from skip_map — should already be auto-skipped by stop hook)
if (checkpoint.flags?.no_browser_test === true || checkpoint.flags?.no_test === true) {
  updateCheckpoint({ phase: "browser_test", status: "skipped" })
  // Cascade skip to fix + verify phases
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
  updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
  return
}

// Guard 2: Frontend file detection (reuse has_frontend from Phase 7.7 test checkpoint)
// OPTIMIZATION: Avoid re-scanning diff — Phase 7.7 already stored this
const has_frontend = checkpoint.phases.test?.has_frontend ?? false
if (!has_frontend) {
  updateCheckpoint({ phase: "browser_test", status: "skipped", skip_reason: "no_frontend_files" })
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
  updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
  return
}

// Guard 3: agent-browser availability
const agentBrowserVersion = Bash("agent-browser --version 2>/dev/null || true").trim()
if (!agentBrowserVersion) {
  warn("agent-browser not installed — skipping browser test loop")
  updateCheckpoint({ phase: "browser_test", status: "skipped", skip_reason: "agent_browser_missing" })
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
  updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
  return
}

// Guard 4: Talisman config
const testingConfig = readTalismanSection("testing") ?? {}
const browserTestConfig = testingConfig?.browser ?? {}
if (browserTestConfig.enabled === false || testingConfig?.tiers?.e2e?.enabled === false) {
  updateCheckpoint({ phase: "browser_test", status: "skipped", skip_reason: "talisman_disabled" })
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
  updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
  return
}
```

## STEP 0.5: Infrastructure Discovery

```javascript
// ═══════════════════════════════════════════════════════
// STEP 0.5: INFRASTRUCTURE DISCOVERY
// ═══════════════════════════════════════════════════════

// See references/infrastructure-discovery.md (test-browser skill) for full algorithm
const browserConfig = testingConfig?.browser ?? {}
let infrastructure = null

if (browserConfig.infrastructure_discovery !== false) {
  infrastructure = discoverInfrastructure()
  // infrastructure.base_url overrides talisman default if found
  // infrastructure.credentials available for UI-first flows
  // Write report for checkpoint
  writeInfrastructureReport(infrastructure, `tmp/arc/${id}`)
}

// Resolve base URL: infrastructure discovery > talisman > default
const baseUrl = infrastructure?.base_url ?? testingConfig?.tiers?.e2e?.base_url ?? "http://localhost:3000"

// Read plan file path from parent arc checkpoint for test plan generation
const planPath = checkpoint.plan_path ?? ""
```

## STEP 1: Route Discovery

```javascript
// ═══════════════════════════════════════════════════════
// STEP 1: ROUTE DISCOVERY
// ═══════════════════════════════════════════════════════

// Reuse resolveTestScope() from testing/references/scope-detection.md
const prNumber = checkpoint.pr_number ? String(checkpoint.pr_number) : ""
const scopeInput = prNumber || Bash("gh pr view --json number --jq '.number' 2>/dev/null").trim() || ""
const { files: diffFiles } = resolveTestScope(scopeInput)

// Reuse discoverE2ERoutes() from testing/references/test-discovery.md
const routes = discoverE2ERoutes(diffFiles)
const maxRoutes = browserTestConfig.max_routes ?? testingConfig?.tiers?.e2e?.max_routes ?? 5
const testRoutes = routes.slice(0, maxRoutes)

if (testRoutes.length === 0) {
  warn("No testable routes found for changed frontend files")
  updateCheckpoint({ phase: "browser_test", status: "skipped", skip_reason: "no_routes" })
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
  updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
  return
}
```

## STEP 2.5: Test Plan Generation (Arc Mode)

```javascript
// ═══════════════════════════════════════════════════════
// STEP 2.5: TEST PLAN GENERATION (non-interactive)
// ═══════════════════════════════════════════════════════

// See references/test-plan-generation.md (test-browser skill) for full algorithm
let testPlan = null
const sessionTimestamp = Date.now()

if (browserConfig.test_plan !== false) {
  const scope = { files: diffFiles, source: prNumber ? "pr" : "branch", label: prNumber ? `PR #${prNumber}` : "current" }
  testPlan = generateTestPlan(scope, planPath, infrastructure, testRoutes, sessionTimestamp)
  // Arc mode: skip Step 4.5 (user review) — arc is non-interactive
}
```

## STEP 2: Server Verification

```javascript
// ═══════════════════════════════════════════════════════
// STEP 2: SERVER VERIFICATION
// ═══════════════════════════════════════════════════════

// Reuse verifyServerWithSnapshot() from testing/references/service-startup.md
// baseUrl already resolved in Step 0.5 (infrastructure > talisman > default)
const sessionName = `browser-test-${id}`
const verifyResult = verifyServerWithSnapshot(baseUrl, sessionName)

if (verifyResult !== "ok") {
  // Auto-start attempt (if configured)
  const startCmd = testingConfig?.tiers?.e2e?.start_command
  if (startCmd && browserTestConfig.auto_start_server !== false) {
    Bash(`${startCmd} &`)
    Bash("sleep 5")  // Wait for server startup
    const retryResult = verifyServerWithSnapshot(baseUrl, sessionName)
    if (retryResult !== "ok") {
      warn(`Dev server not responding at ${baseUrl} after auto-start — skipping browser tests`)
      updateCheckpoint({ phase: "browser_test", status: "skipped", skip_reason: "server_unavailable" })
      updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
      updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
      return
    }
  } else {
    warn(`Dev server not responding at ${baseUrl} — skipping browser tests`)
    updateCheckpoint({ phase: "browser_test", status: "skipped", skip_reason: "server_unavailable" })
    updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
    updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
    return
  }
}
```

## STEP 3: Create Team and Spawn Test Agents

```javascript
// ═══════════════════════════════════════════════════════
// STEP 3: CREATE TEAM & SPAWN TEST AGENTS
// ═══════════════════════════════════════════════════════

const teamName = `arc-browser-test-${id}`
TeamCreate({ team_name: teamName })

// Create tasks — one per route batch (max 3 routes per agent)
const ROUTES_PER_AGENT = 3
const routeBatches = chunkArray(testRoutes, ROUTES_PER_AGENT)

for (let i = 0; i < routeBatches.length; i++) {
  TaskCreate({
    subject: `Browser test batch ${i + 1}: ${routeBatches[i].join(', ')}`,
    description: `Test routes: ${routeBatches[i].join(', ')}`
  })
}

// Spawn one agent per batch
for (let i = 0; i < routeBatches.length; i++) {
  const batch = routeBatches[i]
  Agent({
    team_name: teamName,
    name: `browser-tester-${i}`,
    subagent_type: "general-purpose",
    prompt: `You are browser-tester-${i}. Test these routes using agent-browser CLI (headless mode):

Routes: ${batch.map(r => r.replace(/[^a-zA-Z0-9/_.-]/g, '')).join(', ')}
Base URL: ${baseUrl}

For each route:
1. Sanitize route: const safeRoute = route.replace(/[^a-zA-Z0-9/_.-]/g, '')
2. Run: agent-browser open "${baseUrl}${safeRoute}" --headless
3. Check for: console errors, blank pages, error states, broken layouts
4. Take screenshot: agent-browser screenshot --output tmp/arc/${id}/screenshots/browser/${safeRoute.replace(/\//g, '_')}.png

Write results to: tmp/arc/${id}/browser-test-batch-${i}.json
Format: { "results": [{ "route": "/path", "status": "pass"|"fail", "errors": [...], "screenshot": "path" }] }

Claim your task via TaskList + TaskUpdate (status: completed).`
  })
}

// Monitor completion (reuse waitForCompletion pattern)
waitForCompletion(teamName, routeBatches.length, { timeout: 900_000 })
```

## STEP 4: Aggregate Results

```javascript
// ═══════════════════════════════════════════════════════
// STEP 4: AGGREGATE RESULTS
// ═══════════════════════════════════════════════════════

const allResults = []
for (let i = 0; i < routeBatches.length; i++) {
  try {
    const batchResult = JSON.parse(Read(`tmp/arc/${id}/browser-test-batch-${i}.json`))
    allResults.push(...(batchResult.results || []))
  } catch (e) { warn(`Failed to read batch ${i} results: ${e.message}`) }
}

const passed = allResults.filter(r => r.status === "pass")
const failed = allResults.filter(r => r.status === "fail")

// Write aggregated report
Write(`tmp/arc/${id}/browser-test-report.md`, generateBrowserTestReport(allResults))
Write(`tmp/arc/${id}/browser-test-failures.json`, JSON.stringify({
  failures: failed,
  round: checkpoint.browser_test_convergence.round
}))

// Cleanup team — standard 5-component cleanup pattern
// (see arc-phase-cleanup.md for the canonical pattern)
```

## Checkpoint Update

```javascript
updateCheckpoint({
  phase: "browser_test", status: "completed",
  artifact: `tmp/arc/${id}/browser-test-report.md`,
  artifact_hash: sha256(Read(`tmp/arc/${id}/browser-test-report.md`)),
  team_name: teamName,
  routes_tested: allResults.length,
  routes_passed: passed.length,
  routes_failed: failed.length,
  // New fields from enhanced browser testing pipeline
  test_plan_path: testPlan ? `tmp/test-browser-${sessionTimestamp}/test-plan.md` : null,
  test_plan_status: testPlan ? "generated" : "skipped",
  anomalies_count: allAnomalies?.length ?? 0,
  out_of_scope_count: allAnomalies?.filter(a => !a.inScope)?.length ?? 0,
  infrastructure_source: infrastructure ? (infrastructure.infrastructure?.docker_compose?.found ? "docker-compose" : infrastructure.infrastructure?.tunnel?.found ? "tunnel" : "talisman") : "talisman"
})
```

## Crash Recovery

If the phase crashes mid-execution:
- Team `arc-browser-test-{id}` may be orphaned → `arc-phase-cleanup.md` handles via `PHASE_PREFIX_MAP`
- Partial batch results in `tmp/arc/{id}/browser-test-batch-*.json` are safe to re-read on resume
- On resume, the phase re-runs from scratch (stateless agents)

## References

- [scope-detection.md](../../testing/references/scope-detection.md) — `resolveTestScope()`
- [test-discovery.md](../../testing/references/test-discovery.md) — `discoverE2ERoutes()`
- [service-startup.md](../../testing/references/service-startup.md) — `verifyServerWithSnapshot()`
- [arc-phase-constants.md](arc-phase-constants.md) — `BROWSER_TEST_CYCLE_BUDGET`, `MAX_BROWSER_TEST_CYCLES`
- [infrastructure-discovery.md](../../test-browser/references/infrastructure-discovery.md) — `discoverInfrastructure()`
- [test-plan-generation.md](../../test-browser/references/test-plan-generation.md) — `generateTestPlan()`
- [ui-first-flow-engine.md](../../test-browser/references/ui-first-flow-engine.md) — `executeUIFirstFlows()`
- [anomaly-report.md](../../test-browser/references/anomaly-report.md) — anomaly detection + reporting
