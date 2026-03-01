# Phase 7.7: TEST — Full Algorithm

3-tier QA gate on converged code: unit → integration → E2E/browser.

**Team**: `arc-test-{id}` (self-managed)
**Tools**: Read, Glob, Grep, Bash (+ agent-browser via Bash for E2E)
**Timeout**: Dynamic — 15 min without E2E (inner 10m + 5m setup), 40 min with E2E (inner 35m + 5m setup)
**Inputs**: id, converged code on feature branch, enriched-plan.md, gap-analysis.md, resolution-report.md
**Outputs**: `tmp/arc/{id}/test-report.md` + screenshots in `tmp/arc/{id}/screenshots/`
**Error handling**: Non-blocking (WARN). Test results feed into audit but never halt pipeline.
**Consumers**: SKILL.md (Phase 7.7 stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Model Routing (Strict Enforcement)

| Role | Model | When |
|------|-------|------|
| Orchestration (STEP 0-4, 9-10) | Opus (team lead) | Always |
| Test strategy (STEP 1.5) | Opus (team lead) | Always |
| Unit test runner | Sonnet | STEP 5 |
| Integration test runner | Sonnet | STEP 6 |
| E2E browser tester | Sonnet | STEP 7 |
| Failure analyst | Opus (inherit) | STEP 8, only if failures |

Team lead NEVER runs `agent-browser` CLI or test commands directly.

## Algorithm

```javascript
// ═══════════════════════════════════════════════════════
// STEP 0: PRE-FLIGHT GUARDS
// ═══════════════════════════════════════════════════════

// Defense-in-depth: id validated at arc init — re-assert here for phase-local safety
if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error(`Phase 7.7: unsafe id value: "${id}"`)

const noTestFlag = checkpoint.flags?.no_test === true
if (noTestFlag) {
  Write(`tmp/arc/${id}/test-report.md`, "Phase 7.7 skipped: --no-test flag set.\n<!-- SEAL: test-report-complete -->")
  updateCheckpoint({ phase: "test", status: "skipped" })
  return
}

// Detect PR number from checkpoint or gh CLI for scope resolution
// See testing/references/scope-detection.md for full resolveTestScope() algorithm
const prFromCheckpoint = checkpoint.pr_number ? String(checkpoint.pr_number) : ""
const prFromGh = prFromCheckpoint || Bash("gh pr view --json number --jq '.number' 2>/dev/null").trim()
const scopeInput = prFromGh || ""  // "" → falls through to current-branch diff in resolveTestScope

const { files: diffFiles, scopeLabel } = resolveTestScope(scopeInput)
// resolveTestScope: { files: string[], source: "pr"|"branch"|"current", label: string }
// Defined in testing/references/scope-detection.md — shared with /rune:test-browser

if (diffFiles.length === 0) {
  Write(`tmp/arc/${id}/test-report.md`, `Phase 7.7 skipped: No changed files (scope: ${scopeLabel}).\n<!-- SEAL: test-report-complete -->`)
  updateCheckpoint({ phase: "test", status: "skipped", scope_label: scopeLabel })
  return
}

// Log resolved scope for downstream aggregation and test report header
warn(`Phase 7.7 scope: ${scopeLabel} (${diffFiles.length} files)`)

// Read talisman testing config
const testingConfig = talisman?.testing ?? { enabled: true }
if (testingConfig.enabled === false) {
  Write(`tmp/arc/${id}/test-report.md`, "Phase 7.7 skipped: testing.enabled=false in talisman.\n<!-- SEAL: test-report-complete -->")
  updateCheckpoint({ phase: "test", status: "skipped" })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 1: SCOPE DETECTION (file classification)
// ═══════════════════════════════════════════════════════

// diffFiles already resolved by resolveTestScope() in STEP 0 — see testing/references/scope-detection.md
// Classify files via Rune Gaze (backend/frontend/config/test)
// Cap at top 50 changed files for classification
const filesToClassify = diffFiles.slice(0, 50)
const backendExts = talisman?.['rune-gaze']?.backend_extensions ?? ['.py', '.go', '.rs', '.rb']
const frontendExts = talisman?.['rune-gaze']?.frontend_extensions ?? ['.tsx', '.ts', '.jsx']

const backendFiles = filesToClassify.filter(f => backendExts.some(e => f.endsWith(e)))
const frontendFiles = filesToClassify.filter(f =>
  frontendExts.some(e => f.endsWith(e)) && !f.includes('test') && !f.includes('spec')
)
const testFiles = filesToClassify.filter(f => f.includes('test') || f.includes('spec'))
const has_frontend = frontendFiles.length > 0

// Determine active tiers
const unitEnabled = testingConfig.tiers?.unit?.enabled !== false
const integrationEnabled = testingConfig.tiers?.integration?.enabled !== false
const e2eEnabled = testingConfig.tiers?.e2e?.enabled !== false && has_frontend
const testTiersActive = unitEnabled || integrationEnabled || e2eEnabled
const activeTiers = []  // populated as each tier completes

if (!testTiersActive) {
  Write(`tmp/arc/${id}/test-report.md`, "Phase 7.7 skipped: No testable changes detected.\n<!-- SEAL: test-report-complete -->")
  updateCheckpoint({ phase: "test", status: "skipped" })
  return
}

// Compute test/implementation ratio
const uncoveredImplementations = backendFiles.filter(f => {
  // Check if corresponding test file exists
  const testVariants = generateTestPaths(f)  // from test-discovery.md algorithm
  return !testVariants.some(t => exists(t))
})

// ═══════════════════════════════════════════════════════
// STEP 1.5: TEST STRATEGY GENERATION
// ═══════════════════════════════════════════════════════

// Team lead (Opus) generates strategy document BEFORE any test execution
// Strategy is the instruction document for all downstream test runners
const strategy = generateTestStrategy({
  diffFiles, backendFiles, frontendFiles, testFiles,
  has_frontend, enrichedPlan: Read(`tmp/arc/${id}/enriched-plan.md`),
  tiers: { unit: unitEnabled, integration: integrationEnabled, e2e: e2eEnabled },
  uncoveredImplementations, scopeLabel
})
Write(`tmp/arc/${id}/test-strategy.md`, strategy)

// ═══════════════════════════════════════════════════════
// STEP 2: TEST DISCOVERY
// ═══════════════════════════════════════════════════════

// See testing/references/test-discovery.md for full algorithm
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
const unitTests = discoverUnitTests(diffFiles).filter(p => SAFE_PATH_PATTERN.test(p))
const integrationTests = discoverIntegrationTests(diffFiles).filter(p => SAFE_PATH_PATTERN.test(p))
const e2eRoutes = has_frontend ? discoverE2ERoutes(frontendFiles).filter(r => SAFE_PATH_PATTERN.test(r)) : []

// ═══════════════════════════════════════════════════════
// STEP 3: SERVICE STARTUP (conditional)
// ═══════════════════════════════════════════════════════

// See testing/references/service-startup.md for full protocol
let servicesHealthy = false
let dockerStarted = false  // Track Docker startup for STEP 10 cleanup
if (integrationEnabled || e2eEnabled) {
  const startResult = startServices(testingConfig)
  servicesHealthy = startResult.healthy
  dockerStarted = startResult.dockerStarted  // true when docker compose was used
  // If health check fails → skip integration/E2E, unit still runs
  if (!servicesHealthy) {
    warn("Services not healthy — skipping integration/E2E tiers")
  }
  // T4: Verify screenshot dir is not a symlink BEFORE creating (SEC-004: prevent TOCTOU race)
  const screenshotDir = `tmp/arc/${id}/screenshots`
  if (Bash(`test -L "${screenshotDir}" && echo symlink`).trim() === 'symlink') {
    Bash(`rm -f "${screenshotDir}"`)
    warn("Screenshot directory was a symlink — removed before creation")
  }
  Bash(`mkdir -p "${screenshotDir}"`)
  // Post-create verify: ensure it's still a real directory (defense-in-depth)
  if (Bash(`test -L "${screenshotDir}" && echo symlink`).trim() === 'symlink') {
    throw new Error(`Screenshot directory is a symlink after creation — aborting (possible race condition)`)
  }
}

// ═══════════════════════════════════════════════════════
// STEP 4: TEAM CREATION
// ═══════════════════════════════════════════════════════

prePhaseCleanup(checkpoint)  // Evict stale arc-test-{id} teams (EC-4.2)
TeamCreate({ team_name: `arc-test-${id}` })
const phaseStart = Date.now()
const innerBudget = has_frontend ? 2_100_000 : 600_000  // 35m with E2E, 10m without
function remainingBudget() { return innerBudget - (Date.now() - phaseStart) }

updateCheckpoint({
  phase: "test", status: "in_progress", phase_sequence: 7.7,
  team_name: `arc-test-${id}`,
  tiers_run: [], pass_rate: null, coverage_pct: null, has_frontend
})

// ═══════════════════════════════════════════════════════
// STEP 5: TIER 1 — UNIT TESTS
// ═══════════════════════════════════════════════════════

if (unitEnabled && unitTests.length > 0) {
  // Spawn unit-test-runner teammate
  Agent({
    subagent_type: "general-purpose", model: resolveModelForAgent("unit-test-runner", talisman),  // Cost tier mapping
    name: "unit-test-runner", team_name: `arc-test-${id}`,
    prompt: `You are unit-test-runner. Run these unit tests: ${unitTests.join(', ')}
      Output to: tmp/arc/${id}/test-results-unit.md
      Strategy: ${Read(`tmp/arc/${id}/test-strategy.md`)}
      [inject agent unit-test-runner.md content]`
  })
  waitForCompletion(["unit-test-runner"], {
    timeoutMs: Math.min(180_000, remainingBudget())
  })
  activeTiers.push('unit')
}

// ═══════════════════════════════════════════════════════
// STEP 6: TIER 2 — INTEGRATION TESTS (after unit)
// ═══════════════════════════════════════════════════════

if (integrationEnabled && servicesHealthy && integrationTests.length > 0) {
  Agent({
    subagent_type: "general-purpose", model: resolveModelForAgent("integration-test-runner", talisman),  // Cost tier mapping
    name: "integration-test-runner", team_name: `arc-test-${id}`,
    prompt: `You are integration-test-runner. Run integration tests.
      Output to: tmp/arc/${id}/test-results-integration.md
      Strategy: ${Read(`tmp/arc/${id}/test-strategy.md`)}
      [inject agent integration-test-runner.md content]`
  })
  waitForCompletion(["integration-test-runner"], {
    timeoutMs: Math.min(240_000, remainingBudget())
  })
  activeTiers.push('integration')
}

// ═══════════════════════════════════════════════════════
// STEP 7: TIER 3 — E2E/BROWSER TESTS (after integration)
// ═══════════════════════════════════════════════════════

const agentBrowserAvailable = Bash("agent-browser --version 2>/dev/null && echo 'yes' || echo 'no'").trim() === "yes"

if (e2eEnabled && servicesHealthy && agentBrowserAvailable && e2eRoutes.length > 0) {
  const maxRoutes = testingConfig.tiers?.e2e?.max_routes ?? 3
  const routesToTest = e2eRoutes.slice(0, maxRoutes)
  let baseUrl = testingConfig.tiers?.e2e?.base_url ?? "http://localhost:3000"

  // URL scope restriction (T10): hard-block non-localhost URLs (SEC-003)
  const urlHost = new URL(baseUrl).hostname
  if (urlHost !== 'localhost' && urlHost !== '127.0.0.1') {
    warn(`E2E base_url ${baseUrl} is not localhost — overriding to localhost`)
    baseUrl = "http://localhost:3000"
  }

  // BROWSER ISOLATION: ALL browser work on dedicated teammate
  Agent({
    subagent_type: "general-purpose", model: resolveModelForAgent("e2e-browser-tester", talisman),  // Cost tier mapping
    name: "e2e-browser-tester", team_name: `arc-test-${id}`,
    prompt: `You are e2e-browser-tester. Test these routes: ${routesToTest.join(', ')}
      Base URL: ${baseUrl}
      Session: --session arc-e2e-${id}
      Output per route to: tmp/arc/${id}/e2e-route-{N}-result.md
      Aggregate to: tmp/arc/${id}/test-results-e2e.md
      Screenshots to: tmp/arc/${id}/screenshots/
      Remaining budget: ${remainingBudget()}ms. Skip routes if cumulative time exceeds this budget.
      Strategy: ${Read(`tmp/arc/${id}/test-strategy.md`)}
      [inject agent-browser skill content]
      [inject agent e2e-browser-tester.md content]`
  })

  // timeout config is in milliseconds (default 300_000ms = 5min per route)
  const e2eTimeout = (testingConfig.tiers?.e2e?.timeout_ms ?? 300_000) * routesToTest.length
  waitForCompletion(["e2e-browser-tester"], {
    timeoutMs: Math.min(e2eTimeout + 60_000, remainingBudget())
  })
  activeTiers.push('e2e')
} else if (e2eEnabled && !agentBrowserAvailable) {
  warn("agent-browser not installed — skipping E2E tier. Install: npm i -g @anthropic-ai/agent-browser")
}

// ═══════════════════════════════════════════════════════
// STEP 8: FAILURE ANALYSIS (conditional — Opus, 3-min deadline)
// ═══════════════════════════════════════════════════════

const hasFailures = checkForFailures(`tmp/arc/${id}/test-results-*.md`)

if (hasFailures && remainingBudget() > 180_000) {
  Agent({
    subagent_type: "general-purpose", model: resolveModelForAgent("test-failure-analyst", talisman),  // Cost tier mapping (exception: elevated model)
    name: "test-failure-analyst", team_name: `arc-test-${id}`,
    prompt: `You are test-failure-analyst. Analyze failures in:
      - tmp/arc/${id}/test-results-unit.md
      - tmp/arc/${id}/test-results-integration.md
      - tmp/arc/${id}/test-results-e2e.md
      Truncate input: first 200 + last 50 lines per file.
      Hard deadline: 3 minutes.
      [inject agent test-failure-analyst.md content]`
  })
  waitForCompletion(["test-failure-analyst"], {
    timeoutMs: Math.min(180_000, remainingBudget())
  })
}

// ═══════════════════════════════════════════════════════
// STEP 9: GENERATE TEST REPORT
// ═══════════════════════════════════════════════════════

// Reserve last 60s for STEPS 9-10
// Aggregate per-tier files (authoritative — NOT checkpoint files)
// See testing/references/test-report-template.md for format
const report = aggregateTestReport({
  id, tiersRun: activeTiers,
  unitResults: exists(`tmp/arc/${id}/test-results-unit.md`) ? Read(`tmp/arc/${id}/test-results-unit.md`) : null,
  integrationResults: exists(`tmp/arc/${id}/test-results-integration.md`) ? Read(`tmp/arc/${id}/test-results-integration.md`) : null,
  e2eResults: exists(`tmp/arc/${id}/test-results-e2e.md`) ? Read(`tmp/arc/${id}/test-results-e2e.md`) : null,
  strategy: Read(`tmp/arc/${id}/test-strategy.md`),
  uncoveredImplementations, scopeLabel
})

Write(`tmp/arc/${id}/test-report.md`, report + "\n<!-- SEAL: test-report-complete -->")

// ═══════════════════════════════════════════════════════
// STEP 10: CLEANUP (correct ordering — prevents deadlocks)
// ═══════════════════════════════════════════════════════

// 1. Shutdown teammates FIRST (30s max wait)
SendMessage({ type: "shutdown_request", recipient: "unit-test-runner" })
SendMessage({ type: "shutdown_request", recipient: "integration-test-runner" })
SendMessage({ type: "shutdown_request", recipient: "e2e-browser-tester" })
SendMessage({ type: "shutdown_request", recipient: "test-failure-analyst" })
sleep(30_000)  // Wait for shutdown acknowledgment

// 2. Close browser sessions (teammates already closed)
// SEC-001 FIX: Use grep -F for literal matching and quote --session argument
Bash(`agent-browser session list 2>/dev/null | grep -F "arc-e2e-${id}" && agent-browser close --session "arc-e2e-${id}" 2>/dev/null || true`)

// 3. Stop Docker
if (dockerStarted) {
  Bash(`docker compose down --timeout 10 --remove-orphans 2>/dev/null || true`)
  // Fallback: kill by container IDs (SEC-005: validate hex IDs before shell interpolation)
  if (exists(`tmp/arc/${id}/docker-containers.json`)) {
    const containerIds = JSON.parse(Read(`tmp/arc/${id}/docker-containers.json`))
      .map(c => c.ID).filter(cid => /^[a-f0-9]{12,64}$/.test(cid))
    if (containerIds.length > 0) {
      Bash(`docker kill ${containerIds.join(' ')} 2>/dev/null || true`)
    }
  }
}

// 4. TeamDelete with retry-with-backoff (3 attempts: 0s, 5s, 10s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`test cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-test-${id}/" "$CHOME/tasks/arc-test-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// 5. Update checkpoint
updateCheckpoint({
  phase: "test", status: "completed",
  artifact: `tmp/arc/${id}/test-report.md`,
  artifact_hash: sha256(Read(`tmp/arc/${id}/test-report.md`)),
  phase_sequence: 7.7,
  team_name: `arc-test-${id}`,
  tiers_run: activeTiers,
  pass_rate: computePassRate(report),
  coverage_pct: computeDiffCoverage(report),
  has_frontend, scope_label: scopeLabel
})
```

## Crash Recovery

If this phase crashes before cleanup:

| Resource | Location |
|----------|----------|
| Team config | `$CHOME/teams/arc-test-{id}/` (where `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`) |
| Task list | `$CHOME/tasks/arc-test-{id}/` (where `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`) |
| Browser sessions | `arc-e2e-{id}` (check `agent-browser session list`) |
| Docker containers | `tmp/arc/{id}/docker-containers.json` |
| Screenshots | `tmp/arc/{id}/screenshots/` |

Recovery: `prePhaseCleanup()` handles team/task cleanup before phase, `postPhaseCleanup()` handles cleanup after. See [arc-phase-cleanup.md](arc-phase-cleanup.md). Docker containers auto-stop on Docker daemon restart. Browser sessions time out after 5 minutes of inactivity.

---

<!-- Phase 7.8 is intentionally embedded in this file rather than extracted to a separate
     arc-phase-test-coverage-critique.md. It is a lightweight Codex-only sub-phase that always
     runs immediately after Phase 7.7 test execution, and separating it would add file overhead
     without improving discoverability. -->
## Phase 7.8: TEST COVERAGE CRITIQUE (Codex cross-model, v1.51.0)

Runs after Phase 7.7 TEST completes. Inline Codex integration — no team, orchestrator-only.

**Team**: None (orchestrator-only)
**Tools**: Read, Write, Bash (codex-exec.sh)
**Timeout**: 10 min (600s Codex exec + overhead)
**Inputs**: `tmp/arc/{id}/test-report.md`, git diff
**Outputs**: `tmp/arc/{id}/test-critique.md`
**Error handling**: Non-blocking. CDX-TEST findings are advisory — `test_critique_needs_attention` flag is set but never auto-fails the pipeline.

### Detection Gate

4-condition canonical pattern + cascade circuit breaker (5th condition):
1. `detectCodex()` — CLI available and authenticated
2. `!codexDisabled` — `talisman.codex.disabled !== true`
3. `testCritiqueEnabled` — `talisman.codex.test_coverage_critique.enabled !== false` (default ON)
4. `workflowIncluded` — `"arc"` in `talisman.codex.workflows` (NOT `"work"` — arc phases register under `"arc"`)
5. `!cascade_warning` — cascade circuit breaker not tripped

### Config

| Key | Default | Range |
|-----|---------|-------|
| `codex.test_coverage_critique.enabled` | `true` | boolean |
| `codex.test_coverage_critique.timeout` | `600` | 300-900s |
| `codex.test_coverage_critique.reasoning` | `"xhigh"` | medium/high/xhigh |

### CDX-TEST Finding Format

```
CDX-TEST-001: [CRITICAL] Missing edge case — empty input array not tested in sort()
  Category: Missing edge case
  Suggested test: test_sort_empty_array() → expect([])

CDX-TEST-002: [HIGH] Brittle pattern — test relies on exact timestamp matching
  Category: Brittle pattern
  Suggested fix: Use time range assertion instead of exact match
```

### Checkpoint Integration

When CRITICAL findings detected:
```javascript
checkpoint.test_critique_needs_attention = true
```

This flag is informational — human reviews during pre-ship (Phase 8.5). It does NOT trigger auto-remediation.
