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
| Batch test runners | Sonnet | STEP 5 — all types (unit/contract/integration/e2e/extended) |
| Fix agent (rune-smith) | Sonnet | STEP 5 fix loop, only if batch fails |

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
// STEP 0.5: SCENARIO DISCOVERY
// ═══════════════════════════════════════════════════════

// Gate: testing.scenarios.enabled (default true)
// See testing/references/scenario-schema.md for YAML scenario format
const scenariosEnabled = testingConfig.scenarios?.enabled !== false
let scenarios = []

if (scenariosEnabled) {
  const scenarioFiles = Glob(".rune/test-scenarios/*.yml")
  const maxPerRun = testingConfig.scenarios?.max_per_run ?? 50

  for (const scenarioFile of scenarioFiles) {
    try {
      const raw = Read(scenarioFile)
      const parsed = parseYAML(raw)  // dispatcher-provided utility
      // Validate against scenario schema (scenario-schema.md)
      if (!parsed.name || !parsed.tier) {
        warn(`Scenario file ${scenarioFile} missing required fields — skipping`)
        continue
      }
      scenarios.push(parsed)
    } catch (e) {
      warn(`Failed to parse scenario file ${scenarioFile}: ${e.message} — skipping`)
    }
  }

  // Filter by active tiers — only include scenarios whose tier will run
  // Lightweight frontend detection for scenario filtering (full classification in STEP 1)
  const frontendExtsPrecheck = talisman?.['rune-gaze']?.frontend_extensions ?? ['.tsx', '.ts', '.jsx']
  const has_frontend_precheck = diffFiles.some(f =>
    frontendExtsPrecheck.some(e => f.endsWith(e)) && !f.includes('test') && !f.includes('spec')
  )
  scenarios = scenarios.filter(s => {
    if (s.tier === 'unit') return true  // unitEnabled checked later in STEP 1
    if (s.tier === 'integration') return true
    if (s.tier === 'e2e') return has_frontend_precheck  // pre-check: e2e requires frontend
    if (s.tier === 'extended') return testingConfig.extended_tier?.enabled !== false
    if (s.tier === 'contract') return testingConfig.contract?.enabled !== false
    if (s.tier === 'visual') {
      // visual requires frontend AND explicit opt-in (disabled by default)
      if (!has_frontend_precheck) {
        warn(`Scenario "${s.name}" skipped: tier=visual requires frontend files (none detected)`)
        return false
      }
      if (testingConfig.visual_regression?.enabled !== true) {
        warn(`Scenario "${s.name}" skipped: tier=visual requires testing.visual_regression.enabled=true`)
        return false
      }
      return true
    }
    warn(`Scenario "${s.name}" skipped: unknown tier "${s.tier}"`)
    return false
  })

  // Cap at max_per_run
  if (scenarios.length > maxPerRun) {
    warn(`Scenario count (${scenarios.length}) exceeds max_per_run (${maxPerRun}) — truncating`)
    scenarios = scenarios.slice(0, maxPerRun)
  }

  warn(`Scenario discovery: ${scenarios.length} scenario(s) found across ${scenarioFiles.length} file(s)`)
}
// Output: scenarios[] — fed into STEP 1.5 generateTestStrategy()

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
const activeTiers = []    // populated when a tier passes (for pass_rate scope)
const executedTiers = []  // DEEP-007: populated for ALL executed tiers (for tiers_run)

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
// Includes scenarios[] from STEP 0.5 — merged with auto-discovered tests in each tier
//
// DISCIPLINE INTEGRATION — Echo-back for test strategy (AC-8.4.1):
// Test runners MUST echo-back their test strategy before execution:
// "I will verify: AC-X via unit test, AC-Y via integration test, AC-Z has no test (WARN)"
// This lets the orchestrator detect misalignment BEFORE tests run.
//
// DISCIPLINE INTEGRATION — Plan context for failure analyst (AC-8.4.6):
// The plan_file_path from checkpoint is passed to failure analysts so they can
// identify "test fails because criterion AC-X was never implemented" — not just
// "test fails on line Y". This transforms the analyst from code debugger to
// spec compliance verifier. When an unimplemented criterion causes a test failure,
// the analyst reports the specific AC-X that was never implemented.

// --- generateTestStrategy() definition ---
// Synthesizes a markdown strategy document from scope, plan, and scenario inputs.
// See testing/references/test-strategy-template.md for the 6-section output format.
function generateTestStrategy({
  diffFiles, backendFiles, frontendFiles, testFiles,
  has_frontend, enrichedPlan, tiers,
  uncoveredImplementations, scopeLabel,
  scenarios, planFilePath
}) {
  let md = ""

  // Section 1: Scope Summary
  // Extract 1-3 key change bullets from the enriched plan (first 3 non-empty lines after "## Summary" or first heading)
  const keyChanges = extractKeyChanges(enrichedPlan, 3)  // dispatcher utility — returns string[]
  md += `## Scope Summary\n`
  md += `- **Scope**: ${scopeLabel}\n`
  md += `- **Changed files**: ${diffFiles.length} total (${backendFiles.length} backend, ${frontendFiles.length} frontend, ${testFiles.length} tests)\n`
  md += `- **Has frontend**: ${has_frontend}\n`
  md += `- **Key changes**:\n`
  for (const change of keyChanges) {
    md += `  - ${change}\n`
  }
  if (planFilePath) {
    md += `- **Plan reference**: ${planFilePath}\n`
  }
  md += `\n`

  // Section 2: Tier Configuration
  md += `## Active Tiers\n`
  md += `| Tier | Enabled | Rationale |\n`
  md += `|------|---------|----------|\n`
  md += `| unit | ${tiers.unit} | ${tiers.unit ? "Backend/frontend changes detected" : "No testable implementation files"} |\n`
  md += `| integration | ${tiers.integration} | ${tiers.integration ? "Service interaction changes detected" : "No integration-level changes or services unhealthy"} |\n`
  md += `| e2e | ${tiers.e2e} | ${tiers.e2e ? "Frontend changes require browser verification" : "No frontend files or E2E disabled"} |\n`
  md += `| contract | ${tiers.contract ?? false} | ${tiers.contract ? "API contract scenarios or OpenAPI spec present" : "No contract scenarios or spec"} |\n`
  md += `| extended | ${tiers.extended ?? false} | ${tiers.extended ? "Extended tier enabled and budget remaining" : "Extended tier disabled or budget exhausted"} |\n`
  md += `\n`

  // Section 3: Test Files Per Tier
  // Classify each existing test file into a tier based on path conventions
  // (e.g., "integration/" → integration, "e2e/" → e2e, default → unit)
  const tierMap = { unit: [], integration: [], e2e: [], contract: [], extended: [] }
  for (const tf of testFiles) {
    if (/\be2e\b|\/e2e\/|\.e2e\./.test(tf)) tierMap.e2e.push(tf)
    else if (/\bintegration\b|\/integration\//.test(tf)) tierMap.integration.push(tf)
    else if (/\bcontract\b|\/contract\//.test(tf)) tierMap.contract.push(tf)
    else tierMap.unit.push(tf)
  }
  // Inject scenario-driven test targets into their respective tiers
  for (const scenario of scenarios) {
    const target = `[scenario: ${scenario.name}] ${(scenario.target_files || []).join(", ")}`
    if (tierMap[scenario.tier]) tierMap[scenario.tier].push(target)
  }
  md += `## Test File Assignment\n`
  for (const [tier, files] of Object.entries(tierMap)) {
    md += `### ${tier.charAt(0).toUpperCase() + tier.slice(1)}\n`
    if (files.length === 0) {
      md += `- (none)\n`
    } else {
      for (const f of files) md += `- ${f}\n`
    }
  }
  md += `\n`

  // Section 4: Uncovered Implementation Files
  md += `## Uncovered Files\n`
  md += `| File | Suggested test path | Priority |\n`
  md += `|------|-------------------|----------|\n`
  if (uncoveredImplementations.length === 0) {
    md += `| (all files covered) | — | — |\n`
  } else {
    for (const file of uncoveredImplementations) {
      const suggestedTest = generateTestPaths(file)[0] || "tests/test_" + file.split("/").pop()
      // Priority: high if file is in a core/auth/api path, medium otherwise
      const priority = /\b(core|auth|api|security|payment)\b/i.test(file) ? "high" : "medium"
      md += `| ${file} | ${suggestedTest} | ${priority} |\n`
    }
  }
  md += `\n`

  // Section 5: Scenario Integration
  md += `## Scenarios\n`
  md += `| ID | Description | Tier | Target files |\n`
  md += `|----|-------------|------|-------------|\n`
  if (scenarios.length === 0) {
    md += `| (none) | — | — | — |\n`
  } else {
    for (let i = 0; i < scenarios.length; i++) {
      const s = scenarios[i]
      const targets = (s.target_files || []).join(", ") || "(auto-discover)"
      md += `| S${i + 1} | ${s.name} | ${s.tier} | ${targets} |\n`
    }
  }
  md += `\n`

  // Section 6: Risk Areas
  // Heuristic: files with many dependents (imports), recent churn, or in core paths are high risk
  const riskFiles = diffFiles
    .filter(f => !f.includes("test") && !f.includes("spec"))
    .map(f => {
      let risk = "low"
      let reason = "Standard change"
      if (/\b(core|auth|api|security|payment|session|middleware)\b/i.test(f)) {
        risk = "high"; reason = "Core path — many dependents likely"
      } else if (uncoveredImplementations.includes(f)) {
        risk = "medium"; reason = "No test coverage for this file"
      }
      return { file: f, risk, reason }
    })
    .filter(r => r.risk !== "low")  // Only report medium+ risk
  md += `## Risk Areas\n`
  md += `| File | Risk | Reason |\n`
  md += `|------|------|--------|\n`
  if (riskFiles.length === 0) {
    md += `| (no elevated risk areas) | — | — |\n`
  } else {
    for (const r of riskFiles) {
      md += `| ${r.file} | ${r.risk} | ${r.reason} |\n`
    }
  }

  return md
}

const planFilePath = checkpoint.plan_file
const strategy = generateTestStrategy({
  diffFiles, backendFiles, frontendFiles, testFiles,
  has_frontend, enrichedPlan: Read(`tmp/arc/${id}/enriched-plan.md`),
  tiers: { unit: unitEnabled, integration: integrationEnabled, e2e: e2eEnabled },
  uncoveredImplementations, scopeLabel,
  scenarios,  // STEP 0.5 output: injected so runners can merge scenario-driven tests
              // with auto-discovered tests. See testing/references/scenario-schema.md.
  planFilePath  // Plan context for spec-aware test strategy and failure analysis
})
Write(`tmp/arc/${id}/test-strategy.md`, strategy)

// Verification guard: test-strategy.md MUST exist before STEP 2
// Context pressure may cause the Write above to be skipped silently.
// This guard ensures a minimal fallback strategy is always available
// for downstream test runners (AC: TST-ART-03 reliability fix).
const strategyExists = exists(`tmp/arc/${id}/test-strategy.md`)
if (!strategyExists) {
  warn("STEP 1.5: test-strategy.md was not written — generating minimal fallback")
  const fallbackStrategy = `# Test Strategy (Fallback)\n\n` +
    `> **Note**: This is a minimal fallback strategy generated because the primary strategy ` +
    `generation was skipped under context pressure. Downstream runners should treat this as ` +
    `degraded mode.\n\n` +
    `## Scope\n- ${diffFiles.length} changed files (${scopeLabel})\n\n` +
    `## Tiers\n- Unit: ${unitEnabled}\n- Integration: ${integrationEnabled}\n- E2E: ${e2eEnabled}\n`
  Write(`tmp/arc/${id}/test-strategy.md`, fallbackStrategy)
}

// ═══════════════════════════════════════════════════════
// STEP 2: TEST DISCOVERY + PRE-SCAN VALIDATION
// ═══════════════════════════════════════════════════════

// See testing/references/test-discovery.md for full algorithm
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
const unitTests = discoverUnitTests(diffFiles).filter(p => SAFE_PATH_PATTERN.test(p))
const integrationTests = discoverIntegrationTests(diffFiles).filter(p => SAFE_PATH_PATTERN.test(p))
const e2eRoutes = has_frontend ? discoverE2ERoutes(frontendFiles).filter(r => SAFE_PATH_PATTERN.test(r)) : []
// For E2E sub-tiers (visual regression, accessibility, design token compliance),
// see testing/references/visual-regression.md

// ── PRE-SCAN VALIDATION CHECKLIST ──
// Verify test files actually exist before creating batches.
// Prevents wasted agent spawns on deleted/moved test files.
const preScanResults = {
  checklist: [],
  valid_unit: [],
  valid_integration: [],
  valid_e2e: [],
  missing_files: [],
  framework_detected: {},
  scan_timestamp: new Date().toISOString()
}

// 1. Verify each discovered test file exists on disk
for (const testFile of unitTests) {
  if (exists(testFile)) {
    preScanResults.valid_unit.push(testFile)
  } else {
    preScanResults.missing_files.push({ file: testFile, tier: "unit" })
    warn(`Pre-scan: unit test file missing: ${testFile}`)
  }
}
for (const testFile of integrationTests) {
  if (exists(testFile)) {
    preScanResults.valid_integration.push(testFile)
  } else {
    preScanResults.missing_files.push({ file: testFile, tier: "integration" })
  }
}
preScanResults.valid_e2e = e2eRoutes  // Routes are virtual — no file existence check

// 2. Detect test frameworks per component (for correct runner selection)
const componentDirs = [...new Set([
  ...preScanResults.valid_unit.map(f => f.split("/")[0]),
  ...preScanResults.valid_integration.map(f => f.split("/")[0])
])]
for (const dir of componentDirs) {
  if (exists(`${dir}/pytest.ini`) || exists(`${dir}/pyproject.toml`)) {
    preScanResults.framework_detected[dir] = "pytest"
  } else if (exists(`${dir}/vitest.config.ts`) || exists(`${dir}/vitest.config.js`)) {
    preScanResults.framework_detected[dir] = "vitest"
  } else if (exists(`${dir}/jest.config.ts`) || exists(`${dir}/jest.config.js`)) {
    preScanResults.framework_detected[dir] = "jest"
  } else if (exists(`${dir}/package.json`)) {
    const pkg = Read(`${dir}/package.json`)
    if (pkg.includes('"vitest"')) preScanResults.framework_detected[dir] = "vitest"
    else if (pkg.includes('"jest"')) preScanResults.framework_detected[dir] = "jest"
  }
}

// 3. Build pre-scan checklist (pass/fail for each check)
preScanResults.checklist = [
  { check: "Unit test files exist", pass: preScanResults.valid_unit.length > 0 || unitTests.length === 0, detail: `${preScanResults.valid_unit.length}/${unitTests.length} valid` },
  { check: "Integration test files exist", pass: preScanResults.valid_integration.length > 0 || integrationTests.length === 0, detail: `${preScanResults.valid_integration.length}/${integrationTests.length} valid` },
  { check: "E2E routes discovered", pass: preScanResults.valid_e2e.length > 0 || !has_frontend, detail: `${preScanResults.valid_e2e.length} routes` },
  { check: "Test framework detected", pass: Object.keys(preScanResults.framework_detected).length > 0, detail: JSON.stringify(preScanResults.framework_detected) },
  { check: "No missing test files", pass: preScanResults.missing_files.length === 0, detail: preScanResults.missing_files.length > 0 ? `${preScanResults.missing_files.length} missing` : "all present" },
]

// 4. Write pre-scan report (persists across turns for final report aggregation)
Write(`tmp/arc/${id}/test-pre-scan.json`, JSON.stringify(preScanResults, null, 2))

// Use validated file lists for batch generation (skip missing files)
const validUnitTests = preScanResults.valid_unit
const validIntegrationTests = preScanResults.valid_integration

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
    // Structured warning for downstream phase correlation and test report
    const healthWarning = {
      type: "service_health_warning",
      skipped_tiers: ["integration", "e2e"],
      reason: "services_unhealthy",
      health_result: startResult,
      timestamp: new Date().toISOString()
    }
    Write(`tmp/arc/${id}/service-health-warning.json`, JSON.stringify(healthWarning, null, 2))
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
const testTeamName = `arc-test-${id}`
TeamCreate({ team_name: testTeamName })
// CLEAN-003 FIX: Track every spawned teammate name so the STEP 10 cleanup
// fallback can shut them down even if the config.json read fails. Batch
// runner and fixer names are computed dynamically from nextBatch.id /
// nextBatch.fix_attempts, so a hardcoded fallback array is impossible.
const spawnedAgentNames = []
const phaseStart = Date.now()
const innerBudget = has_frontend ? 2_100_000 : 600_000  // 35m with E2E, 10m without
function remainingBudget() { return innerBudget - (Date.now() - phaseStart) }

updateCheckpoint({
  phase: "test", status: "in_progress", phase_sequence: 7.7,
  team_name: testTeamName,
  tiers_run: [], pass_rate: null, coverage_pct: null, has_frontend
})

// ═══════════════════════════════════════════════════════
// STEP 5: GENERATE TESTING PLAN + EXECUTE BATCHES
// ═══════════════════════════════════════════════════════

// See testing/references/batch-execution.md for full algorithm
// See testing/references/testing-plan-schema.md for JSON schema

// Define contract and extended variables (required for plan generation)
const contractEnabled = testingConfig.contract?.enabled !== false
const contractScenarios = scenarios.filter(s => s.tier === 'contract')
const openApiSpecExists = exists('openapi.yml') || exists('openapi.yaml') || exists('openapi.json')
  || exists('swagger.yml') || exists('swagger.yaml')
const contractGate = contractEnabled && (contractScenarios.length > 0 || openApiSpecExists)
const extendedEnabled = testingConfig.extended_tier?.enabled === true
const extendedScenarios = scenarios.filter(s => s.tier === 'extended')

// STEP 5.1: Generate testing plan (or resume from checkpoint)
// resumeOrCreate() re-runs "running"/"fixing" batches as "pending" — idempotent resume
// Batch ordering: unit → contract → integration → e2e → extended
const testingPlan = resumeOrCreate(id, testingConfig, {
  diffFiles, unitTests, integrationTests, e2eRoutes,
  contractScenarios, extendedScenarios,
  activeTiers: {
    unit: unitEnabled,
    integration: integrationEnabled && servicesHealthy,
    e2e: e2eEnabled && servicesHealthy,
    contract: contractGate,
    extended: extendedEnabled && remainingBudget() > 120_000
  }
})
Write(`tmp/arc/${id}/testing-plan.md`, renderTestingPlanMarkdown(testingPlan))

// For E2E sub-tier execution protocols (visual regression, accessibility, design token compliance),
// see testing/references/visual-regression.md which chains to accessibility-check.md and design-token-check.md

// STEP 5.2: Execute batches sequentially (foreground agents — blocking calls, zero idle risk)
const batchConfig = testingPlan.config
let batchesExecuted = 0

for (const batch of testingPlan.batches) {
  // Skip already-terminal batches (idempotent resume)
  if (batch.status === "passed" || batch.status === "failed" || batch.status === "skipped") continue

  // Safety cap — prevent infinite re-injection
  if (batchesExecuted >= (batchConfig.max_batch_iterations ?? MAX_BATCH_ITERATIONS)) {
    batch.status = "skipped"
    batch.skip_reason = "max_iterations_reached"
    batch.completed_at = new Date().toISOString()  // DEEP-011: terminal state needs completed_at
    testingPlan.summary.skipped += 1  // DEEP-003: increment skipped counter
    writeCheckpoint(id, testingPlan)
    break
  }

  // Budget check — skip remaining batches if budget exhausted
  if (remainingBudget() < HARD_BATCH_TIMEOUT_MS) {
    batch.status = "skipped"
    batch.skip_reason = "budget_exhausted"
    batch.completed_at = new Date().toISOString()  // DEEP-011: terminal state needs completed_at
    testingPlan.summary.skipped += 1  // DEEP-003: increment skipped counter
    writeCheckpoint(id, testingPlan)
    continue
  }

  // Context-aware early exit: check remaining context % before each batch.
  // Long-running test phases (10-35 min) consume massive context from agent
  // spawns, strategy reads, and result aggregation. If context is critically low,
  // skip remaining batches and proceed to report generation + checkpoint update
  // to prevent silent arc death from context exhaustion.
  // Reads bridge file written by rune-statusline.sh (Notification:statusline hook).
  const contextBridge = `${process.env.TMPDIR || '/tmp'}/rune-ctx-${process.env.CLAUDE_SESSION_ID}.json`
  if (exists(contextBridge)) {
    try {
      const bridgeData = JSON.parse(Read(contextBridge))
      const remainingPct = bridgeData.remaining_percentage ?? 100
      if (remainingPct < 30) {
        warn(`Context critically low (${remainingPct}% remaining) — skipping remaining test batches to preserve context for report + cleanup`)
        batch.status = "skipped"
        batch.skip_reason = "context_exhaustion"
        batch.completed_at = new Date().toISOString()
        testingPlan.summary.skipped += 1
        writeCheckpoint(id, testingPlan)
        // Skip ALL remaining pending batches (not just this one)
        for (const remaining of testingPlan.batches) {
          if (remaining.status === "pending") {
            remaining.status = "skipped"
            remaining.skip_reason = "context_exhaustion"
            remaining.completed_at = new Date().toISOString()
            testingPlan.summary.skipped += 1
          }
        }
        writeCheckpoint(id, testingPlan)
        break  // Exit batch loop — proceed to STEP 9 report generation
      }
    } catch (e) { /* bridge unavailable or stale — continue normally */ }
  }

  // ═══════════════════════════════════════════════════════
  // ONE BATCH PER TURN — Stop Hook Driven Execution
  // ═══════════════════════════════════════════════════════
  //
  // ARCHITECTURE (v2.10.8):
  // Each batch runs in its OWN Claude Code turn via the Stop hook sub-loop
  // (_check_test_batches in arc-phase-stop-hook.sh). This ensures:
  //   1. Each batch agent has a FRESH context window (no accumulation)
  //   2. Team lead's context stays clean between batches
  //   3. Context compaction can happen between batches
  //   4. Long test suites (400+ files, 15-20 min) won't exhaust context
  //
  // Flow: Lead executes ONE batch → writes checkpoint → STOPS responding →
  //       Stop hook reads testing-plan.json → finds next pending batch →
  //       re-injects batch-specific prompt → new turn starts
  //
  // Only the FIRST pending batch is executed per turn.
  // The loop exits after one batch — the stop hook handles continuation.

  const nextBatch = batch  // First pending batch from the for-loop
  nextBatch.status = "running"
  nextBatch.started_at = new Date().toISOString()
  writeCheckpoint(id, testingPlan)

  // Component-aware batch label for task visibility
  const batchLabel = nextBatch.label ?? `${nextBatch.type}-batch-${nextBatch.id}`
  const componentHint = nextBatch.component && nextBatch.component !== "root"
    ? `Component: ${nextBatch.component} (run tests from ${nextBatch.component}/ directory)\n      `
    : ""

  // TEAM-002: TaskCreate BEFORE Agent() — required by Iron Law
  TaskCreate({
    subject: `Batch ${nextBatch.id}: ${batchLabel} (${nextBatch.files.length} files)`,
    description: `Run ${nextBatch.type} tests [${nextBatch.component ?? "root"}]: ${nextBatch.files.join(', ')}`
  })

  // Foreground agent — runs in teammate's own context window, NOT the lead's
  const resultPath = `tmp/arc/${id}/test-results-${nextBatch.type}-batch-${nextBatch.id}.md`
  spawnedAgentNames.push(`batch-runner-${nextBatch.id}`)  // CLEAN-003 FIX
  Agent({
    team_name: testTeamName,
    name: `batch-runner-${nextBatch.id}`,
    subagent_type: resolveRunnerAgentType(nextBatch.type),
    model: resolveModelForAgent(`${nextBatch.type}-test-runner`, talisman),
    run_in_background: false,  // Blocking — agent completes before lead continues
    prompt: `Run these ${nextBatch.type} tests: ${nextBatch.files.join(', ')}
      ${componentHint}Output to: ${resultPath}
      Strategy: ${Read(`tmp/arc/${id}/test-strategy.md`)}
      DISCIPLINE: Before running tests, echo-back your test strategy at the top of your output:
        "I will verify: AC-X via [test type]: [test name], AC-Y via [test type]: [test name], AC-Z has no test (WARN)"
        Map each acceptance criterion from the strategy to the specific test that verifies it.
      IMPORTANT: Include <!-- STATUS: PASS --> if all tests pass, or <!-- STATUS: FAIL --> with details.
      If tests fail, include the FULL error output so the fix agent can diagnose.
      When done, claim your task via TaskList + TaskUpdate (status: "completed").`
  })

  // Lightweight result classification — only read STATUS marker, not full content
  // This prevents the lead from ingesting large test outputs into its context
  const resultExists = exists(resultPath)
  let passed = false
  if (resultExists) {
    // Use Grep to check for STATUS marker without reading full file into context
    const statusLines = Grep({ pattern: "<!-- STATUS: (PASS|FAIL) -->", path: resultPath, output_mode: "content" })
    passed = statusLines.includes("<!-- STATUS: PASS -->")
  }

  // Fix loop — spawn fixer teammate if batch failed (up to max_fix_retries)
  // Each fix attempt also runs as a separate agent to keep lead context clean
  if (!passed && resultExists) {
    const maxRetries = batchConfig.max_fix_retries ?? 2

    // Read only the failure summary (first 50 lines) — not the entire output
    const failureSummary = Read(resultPath, { limit: 50 })

    // F-code classification: infra (F8) vs implementation (F3) failures
    const infraPatterns = /\b(ImportError|ModuleNotFoundError|ConnectionRefused|ECONNREFUSED|ENOENT|timeout|setUp|tearDown|fixture|docker|port\s+\d+|cannot\s+connect)\b/i
    const fCode = infraPatterns.test(failureSummary) ? 'F8' : 'F3'
    warn(`Batch ${nextBatch.id} failure classified as ${fCode} (${fCode === 'F8' ? 'infra/test broken' : 'implementation wrong'})`)

    // F17 (CONVERGENCE_STAGNATION): check if same failure persists from previous attempt
    const prevSignaturePath = `tmp/arc/${id}/batch-${nextBatch.id}-failure-sig.txt`
    const rawSignature = (failureSummary.match(/FAIL:?\s*(.{0,200})/)?.[1] || '')
      .replace(/:\d+/g, ':N').replace(/\/[\w./-]+\.\w+/g, '').replace(/\d{4}-\d{2}-\d{2}/g, '').trim()

    let stagnated = false
    if (exists(prevSignaturePath)) {
      const prevSig = Read(prevSignaturePath).trim()
      if (prevSig === rawSignature) {
        warn(`F17 CONVERGENCE_STAGNATION: batch ${nextBatch.id} — same assertion failed across fix attempts. Skipping further retries.`)
        stagnated = true
      }
    }
    Write(prevSignaturePath, rawSignature)

    if (!stagnated && (nextBatch.fix_attempts ?? 0) < maxRetries) {
      // Mark as fixing — stop hook will re-inject this batch after fix
      nextBatch.status = "fixing"
      nextBatch.fix_attempts = (nextBatch.fix_attempts ?? 0) + 1
      writeCheckpoint(id, testingPlan)

      // Spawn fixer agent (separate context — doesn't pollute lead)
      TaskCreate({
        subject: `Fix batch ${nextBatch.id} attempt ${nextBatch.fix_attempts}: ${nextBatch.type}`,
        description: `Read failure details from ${resultPath} and apply code fixes`
      })
      spawnedAgentNames.push(`batch-fixer-${nextBatch.id}-fix-${nextBatch.fix_attempts}`)  // CLEAN-003 FIX
      Agent({
        team_name: testTeamName,
        name: `batch-fixer-${nextBatch.id}-fix-${nextBatch.fix_attempts}`,
        subagent_type: "rune:work:rune-smith",
        model: resolveModelForAgent("rune-smith", talisman),
        run_in_background: false,
        prompt: `Read the test failure details from ${resultPath} and fix the failing code.
          Files under test: ${nextBatch.files.join(', ')}
          Apply targeted Edit() fixes to resolve the failures.
          When done, claim your task via TaskList + TaskUpdate (status: "completed").`
      })

      // Mark batch back to pending — stop hook will re-run it on next turn
      nextBatch.status = "pending"
      writeCheckpoint(id, testingPlan)

      // STOP responding here — stop hook will re-inject this batch for re-run
      // This gives the fixed code a fresh context for the retry
      break  // Exit batch loop — stop hook continues
    }
  }

  // Finalize batch status (only if not sent back for fixing)
  if (nextBatch.status === "running") {
    nextBatch.status = passed ? "passed" : "failed"
    nextBatch.completed_at = new Date().toISOString()
    nextBatch.result_path = resultPath
    testingPlan.summary.completed += 1
    if (!passed) testingPlan.summary.failed += 1
    executedTiers.push(nextBatch.type)
    if (passed) activeTiers.push(nextBatch.type)
    writeCheckpoint(id, testingPlan)

    // Write per-batch evidence
    const batchResult = resultExists ? Read(resultPath, { limit: 100 }) : ""
    writeBatchEvidence(id, nextBatch, batchResult, nextBatch.fix_attempts > 0 ? { attempts: nextBatch.fix_attempts } : null)
  }

  // STOP responding — the Stop hook (_check_test_batches) will:
  //   1. Read testing-plan.json
  //   2. Find next pending batch
  //   3. Re-inject batch-specific prompt in a NEW Claude Code turn
  //   4. Each turn gets fresh context → no accumulation
  // If no more pending batches → stop hook triggers finalization
  break  // Exit the for-loop — only ONE batch per turn
}

// ── EARLY EXIT: If there are still pending batches, STOP here ──
// Do NOT proceed to STEP 9 (report) or STEP 10 (cleanup) until ALL batches are done.
// The stop hook will re-inject for the next batch. STEP 9-10 only run during
// the finalization turn (triggered by stop hook when no pending batches remain).
const hasPendingBatches = testingPlan.batches.some(b =>
  b.status === "pending" || b.status === "running" || b.status === "fixing"
)

// Update checkpoint with progress for stop hook continuation
Write(`tmp/arc/${id}/testing-plan.md`, renderTestingPlanMarkdown(testingPlan))

updateCheckpoint({
  phase: "test", status: "in_progress",
  testing_plan_batches_total: testingPlan.summary.total_batches,
  testing_plan_batches_completed: testingPlan.summary.completed,
  testing_plan_has_pending: hasPendingBatches
})

if (hasPendingBatches) {
  // More batches remain — STOP here. The stop hook will re-inject for the next batch.
  // Do NOT proceed to STEP 9 (report) or STEP 10 (cleanup/TeamDelete).
  return  // Early exit — stop hook continues the batch loop
}

// ═══════════════════════════════════════════════════════
// STEP 9: GENERATE TEST REPORT (only runs when ALL batches are done)
// ═══════════════════════════════════════════════════════

// Reserve last 60s for STEPS 9-10
// Read completed batch results from testing-plan.json (authoritative checkpoint)
// See testing/references/test-report-template.md for report format
const completedPlan = exists(`tmp/arc/${id}/testing-plan.json`)
  ? JSON.parse(Read(`tmp/arc/${id}/testing-plan.json`))
  : { batches: [], summary: { total_batches: 0, completed: 0, failed: 0, skipped: 0 } }

// Collect per-tier results from individual batch result files
const tierResults = {}
for (const batch of completedPlan.batches) {
  if (!tierResults[batch.type]) tierResults[batch.type] = []
  if (batch.result_path && exists(batch.result_path)) {
    tierResults[batch.type].push(Read(batch.result_path))
  }
}

const report = aggregateTestReport({
  id, tiersRun: [...new Set(executedTiers)],  // DEEP-007: use executedTiers (all tiers, not just passed)
  unitResults: tierResults.unit?.join('\n\n---\n\n') ?? null,
  integrationResults: tierResults.integration?.join('\n\n---\n\n') ?? null,
  e2eResults: tierResults.e2e?.join('\n\n---\n\n') ?? null,
  strategy: Read(`tmp/arc/${id}/test-strategy.md`),
  uncoveredImplementations, scopeLabel,
  batchSummary: completedPlan.summary  // passed/failed/skipped counts per plan
})

Write(`tmp/arc/${id}/test-report.md`, report + "\n<!-- SEAL: test-report-complete -->")

// ═══════════════════════════════════════════════════════
// STEP 9.05: EVIDENCE WRITES (inline, no agent spawn)
// ═══════════════════════════════════════════════════════

// Collect batch evidence records written during execution loop (see testing/references/evidence-protocol.md)
// Evidence files are written by writeBatchEvidence() during the batch execution loop (STEP 5).
// Here we collect them and write the cumulative failure journal.
const evidenceRecords = []
for (const batch of completedPlan.batches) {
  const evidencePath = `tmp/arc/${id}/evidence/batch-${batch.id}-evidence.json`
  if (exists(evidencePath)) {
    try {
      evidenceRecords.push(JSON.parse(Read(evidencePath)))
    } catch (e) {
      warn(`Failed to read evidence for batch ${batch.id}: ${e.message}`)
    }
  }
}

// Write cumulative failure journal (see testing/references/evidence-protocol.md)
if (evidenceRecords.length > 0) {
  writeFailureJournal(id, evidenceRecords)
  warn(`Evidence: ${evidenceRecords.length} batch record(s), failure journal written`)
}

// ═══════════════════════════════════════════════════════
// STEP 9.1: PRODUCTION READINESS CHECK (inline, no agent spawn)
// ═══════════════════════════════════════════════════════

// Gate: testing.production_readiness.enabled
// Inline scan — team lead only. Appends section to test-report.md.
const productionReadinessEnabled = testingConfig.production_readiness?.enabled !== false

if (productionReadinessEnabled) {
  const prChecks = []

  // 1. Scan for mock/fake/stub patterns in src/ (not test files)
  // Use Grep — not Bash — to avoid ZSH NOMATCH on glob patterns
  const mockPatterns = ['TODO(mock)', 'FIXME(fake)', 'os.environ.get.*TODO', 'stub_', 'fake_', 'mock_']
  for (const pattern of mockPatterns) {
    const mockHits = Grep({ pattern, path: 'src/', glob: '**/*.{ts,tsx,py,go,rs,rb}', output_mode: 'files_with_matches' })
    if (mockHits.length > 0) {
      prChecks.push(`WARN: mock/stub pattern "${pattern}" found in src/ (${mockHits.length} file(s)) — verify not production code`)
    }
  }

  // 2. Validate referenced env vars exist
  const requiredEnvVars = testingConfig.production_readiness?.required_env_vars ?? []
  for (const envVar of requiredEnvVars) {
    const envResult = Bash(`printenv "${envVar}" >/dev/null 2>&1 && echo "set" || echo "missing"`)
    if (envResult.trim() === 'missing') {
      prChecks.push(`WARN: Required env var ${envVar} is not set`)
    }
  }

  // 3. Check health endpoints
  const healthEndpoints = testingConfig.production_readiness?.health_endpoints ?? []
  for (const endpoint of healthEndpoints) {
    // SEC: validate URL is localhost only (mirrors STEP 7 SEC-003 guard)
    try {
      const epHost = new URL(endpoint).hostname
      if (epHost !== 'localhost' && epHost !== '127.0.0.1') {
        prChecks.push(`SKIP: health endpoint ${endpoint} is not localhost — skipped for security`)
        continue
      }
    } catch (e) {
      prChecks.push(`SKIP: health endpoint ${endpoint} is not a valid URL — skipped`)
      continue
    }
    const healthResult = Bash(`curl -sf --max-time 5 "${endpoint}" >/dev/null 2>&1 && echo "healthy" || echo "unhealthy"`)
    if (healthResult.trim() !== 'healthy') {
      prChecks.push(`WARN: Health endpoint ${endpoint} returned non-200 or timed out`)
    }
  }

  // Append production readiness section to test-report.md (non-blocking)
  if (prChecks.length > 0) {
    const prSection = `\n## Production Readiness Check\n${prChecks.map(c => `- ${c}`).join('\n')}\n`
    Write(`tmp/arc/${id}/test-report.md`, Read(`tmp/arc/${id}/test-report.md`) + prSection)
    warn(`Production readiness: ${prChecks.length} item(s) flagged — see test-report.md`)
  } else {
    const prSection = `\n## Production Readiness Check\n- All checks passed\n`
    Write(`tmp/arc/${id}/test-report.md`, Read(`tmp/arc/${id}/test-report.md`) + prSection)
  }
}

// ═══════════════════════════════════════════════════════
// STEP 9.5: HISTORY PERSISTENCE (inline, no agent spawn)
// ═══════════════════════════════════════════════════════

// Gate: testing.history.enabled (default true)
// See testing/references/history-protocol.md for persistence format
// See testing/references/regression-detection.md for regression threshold logic
const historyEnabled = testingConfig.history?.enabled !== false

if (historyEnabled) {
  const historyDir = `.rune/test-history`
  Bash(`mkdir -p "${historyDir}"`)

  const maxEntries = testingConfig.history?.max_entries ?? 50
  const passRateDropThreshold = testingConfig.history?.pass_rate_drop_threshold ?? 0.05  // 5% drop

  // DEEP-004 FIX: Compute tier breakdown from per-batch results (not non-existent per-tier files)
  const tierBreakdown = {}
  for (const batch of completedPlan.batches) {
    if (!tierBreakdown[batch.type]) {
      tierBreakdown[batch.type] = { pass: 0, fail: 0, duration_ms: 0 }
    }
    if (batch.result_path && exists(batch.result_path)) {
      tierBreakdown[batch.type].pass += countPatternInFile(batch.result_path, /PASS|✓|passed/gi)
      tierBreakdown[batch.type].fail += countPatternInFile(batch.result_path, /FAIL|✗|failed/gi)
    }
    // Compute duration from batch timestamps
    if (batch.started_at && batch.completed_at) {
      tierBreakdown[batch.type].duration_ms += new Date(batch.completed_at) - new Date(batch.started_at)
    }
  }

  // Compute flaky scores from history (see testing/references/flaky-detection.md)
  const flakyScores = computeFlakyScores(historyDir, activeTiers)

  let historyEntry = {
    id, timestamp: new Date().toISOString(),
    scope_label: scopeLabel,
    pass_rate: computePassRate(report),
    coverage_pct: computeDiffCoverage(report),
    tiers_run: [...new Set(executedTiers)],  // DEEP-007 consistency: use executedTiers (all ran), not activeTiers (only passed)
    tier_breakdown: tierBreakdown,
    flaky_scores: flakyScores,
    pr_number: prFromGh || null
  }

  // Enrich with batch-level data (see testing/references/history-protocol.md enrichWithBatchData)
  historyEntry = enrichWithBatchData(historyEntry, completedPlan, evidenceRecords)

  // Append to rolling history (JSON lines format)
  const historyFile = `${historyDir}/test-history.jsonl`
  const existingHistory = exists(historyFile)
    ? Read(historyFile).trim().split('\n').filter(Boolean).map(l => JSON.parse(l))
    : []

  existingHistory.push(historyEntry)

  // Rolling window — keep last maxEntries
  const trimmedHistory = existingHistory.slice(-maxEntries)
  Write(historyFile, trimmedHistory.map(e => JSON.stringify(e)).join('\n') + '\n')

  // Regression threshold check (see testing/references/regression-detection.md)
  if (trimmedHistory.length >= 2) {
    const previousEntry = trimmedHistory[trimmedHistory.length - 2]
    const currentPassRate = historyEntry.pass_rate ?? 0
    const previousPassRate = previousEntry.pass_rate ?? 0
    const passRateDrop = previousPassRate - currentPassRate

    if (passRateDrop > passRateDropThreshold) {
      warn(`Test regression detected: pass rate dropped ${(passRateDrop * 100).toFixed(1)}% (${(previousPassRate * 100).toFixed(1)}% → ${(currentPassRate * 100).toFixed(1)}%). Threshold: ${(passRateDropThreshold * 100).toFixed(1)}%`)
      updateCheckpoint({ test_regression_detected: true, regression_pass_rate_drop: passRateDrop })
    }
  }

  // NOTE: Batch-level regression signals (duration, fix rate, failure signatures) are
  // deferred until sufficient history data validates threshold ranges. The batch-level
  // fields persisted above enable future detection. See regression-detection.md.

  warn(`Test history persisted to ${historyFile} (${trimmedHistory.length}/${maxEntries} entries)`)
}

// ═══════════════════════════════════════════════════════
// STEP 10: CLEANUP (correct ordering — prevents deadlocks)
// ═══════════════════════════════════════════════════════

// 1. All batch runners are foreground (blocking) — completed before reaching cleanup.
// No shutdown_request needed. Brief SDK propagation pause only.
// CLEAN-003 FIX: Best-effort shutdown for any still-alive teammates from
// early-exit paths (e.g., stop-hook re-entry during batch-mode tests).
// The foreground-only assumption holds for the standard path, but batch-mode
// early exits at the iteration cap (stop hook reinjection) can leave live
// teammates before we reach cleanup. Sending shutdown_request to absent
// members is a documented safe no-op.
for (const name of spawnedAgentNames) {
  try { SendMessage({ type: "shutdown_request", recipient: name, content: "Test phase complete" }) } catch (e) { /* already gone */ }
}
Bash("sleep 2", { run_in_background: true })

// 2. Close browser sessions (teammates already completed — foreground)
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

// 4. TeamDelete with retry-with-backoff (4 attempts: 0s, 3s, 6s, 10s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`test cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  // CLEAN-003 FIX: Process-level kill before filesystem rm-rf, so that
  // live batch-runner/fixer agents with dynamically-computed names are
  // terminated even when config.json is gone. MCP-PROTECT-003 guard via
  // --stdio filter. Pair of SIGTERM then SIGKILL matches other phase files.
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
  Bash(`sleep 5`, { run_in_background: true })
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${testTeamName}/" "$CHOME/tasks/${testTeamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// 5. Update checkpoint
updateCheckpoint({
  phase: "test", status: "completed",
  artifact: `tmp/arc/${id}/test-report.md`,
  artifact_hash: sha256(Read(`tmp/arc/${id}/test-report.md`)),
  phase_sequence: 7.7,
  team_name: testTeamName,
  tiers_run: [...new Set(executedTiers)],  // DEEP-007: all executed tiers, not just passed
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
| Testing plan / checkpoint | `tmp/arc/{id}/testing-plan.json` (plan + state combined) |
| Browser sessions | `arc-e2e-{id}` (check `agent-browser session list`) |
| Docker containers | `tmp/arc/{id}/docker-containers.json` |
| Screenshots | `tmp/arc/{id}/screenshots/` |
| Test history | `.rune/test-history/test-history.jsonl` |
| Batch results | `tmp/arc/{id}/test-results-batch-{N}.md` (one per batch) |

Recovery: `prePhaseCleanup()` handles team/task cleanup before phase, `postPhaseCleanup()` handles cleanup after. See [arc-phase-cleanup.md](arc-phase-cleanup.md). Docker containers auto-stop on Docker daemon restart. Browser sessions time out after 5 minutes of inactivity.

---

<!-- Phase 7.8 (TEST COVERAGE CRITIQUE) has been extracted to arc-phase-test-coverage-critique.md
     to reduce file size and eliminate LLM disambiguation overhead. See that file for the full algorithm. -->

## Execution Log Integration

Phase-specific execution logging for QA gate verification. The Tarnished writes one entry per manifest step.

```javascript
// At phase start — initialize execution log
Bash(`mkdir -p "tmp/arc/${id}/execution-logs"`)
const executionLog = {
  phase: "test",
  manifest: "qa-manifests/test.yaml",
  started_at: new Date().toISOString(),
  steps: [],
  skipped_steps: []
}

// After each step — record completion
executionLog.steps.push({
  id: "TST-STEP-{NN}",
  status: "completed",  // or "skipped"
  started_at: stepStartTs,
  completed_at: new Date().toISOString(),
  artifact_produced: artifactPath || null,
  notes: ""
})

// For skipped steps (conditional steps that didn't execute)
executionLog.skipped_steps.push({
  id: "TST-STEP-{NN}",
  reason: "condition not met: {description}"
})

// At phase end (BEFORE updateCheckpoint)
executionLog.completed_at = new Date().toISOString()
executionLog.completed_steps = executionLog.steps.length
executionLog.total_steps = 14  // from manifest
executionLog.skipped_count = executionLog.skipped_steps.length
executionLog.completion_pct = Math.round((executionLog.completed_steps / executionLog.total_steps) * 100)
Write(`tmp/arc/${id}/execution-logs/test-execution.json`, JSON.stringify(executionLog, null, 2))
```
