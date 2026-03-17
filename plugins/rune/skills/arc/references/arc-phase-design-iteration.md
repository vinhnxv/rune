# Phase 7.6: DESIGN ITERATION — Arc Design Sync Integration

Runs screenshot→analyze→fix loop to improve design fidelity after Phase 5.2 DESIGN VERIFICATION.
Gated by `design_sync.enabled` AND `design_sync.iterate_enabled` in talisman.
**Non-blocking** — design phases never halt the pipeline.

**Team**: `arc-design-iter-{id}` (design-iterator workers with agent-browser)
**Tools**: Read, Write, Bash, Agent, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage
**Timeout**: 15 min (PHASE_TIMEOUTS.design_iteration = 900_000)
**Inputs**: id, design findings from Phase 5.2 (`tmp/arc/{id}/design-findings.json`), implemented components
**Outputs**: `tmp/arc/{id}/design-iteration-report.md`, improved implementation commits
**Error handling**: Non-blocking. Skip if no findings from Phase 5.2 or agent-browser unavailable.
**Consumers**: Phase 9 SHIP (design iteration results included in PR body diagnostics)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities
> available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

1. Skip gate — `arcConfig.design_sync?.enabled !== true` → skip
2. Skip gate — `arcConfig.design_sync?.iterate_enabled !== true` → skip
3. Verify design findings exist from Phase 5.2 — skip if none
4. Check agent-browser availability — skip if not installed

## Algorithm

```javascript
updateCheckpoint({ phase: "design_iteration", status: "in_progress", phase_sequence: 7.6, team_name: null })

// 0. Skip gates
const designSyncConfig = arcConfig.design_sync ?? {}
const designSyncEnabled = designSyncConfig.enabled === true
if (!designSyncEnabled) {
  log("Design iteration skipped — design_sync.enabled is false in talisman.")
  updateCheckpoint({ phase: "design_iteration", status: "skipped" })
  return
}

const iterateEnabled = designSyncConfig.iterate_enabled === true
if (!iterateEnabled) {
  log("Design iteration skipped — design_sync.iterate_enabled is false in talisman.")
  updateCheckpoint({ phase: "design_iteration", status: "skipped" })
  return
}

// 1. Check upstream Phase 5.2 ran and has findings
const verificationPhase = checkpoint.phases?.design_verification
if (!verificationPhase || verificationPhase.status === "skipped") {
  log("Design iteration skipped — Phase 5.2 was skipped.")
  updateCheckpoint({ phase: "design_iteration", status: "skipped" })
  return
}

if (!exists(`tmp/arc/${id}/design-findings.json`)) {
  log("Design iteration skipped — no design findings from Phase 5.2.")
  updateCheckpoint({ phase: "design_iteration", status: "skipped" })
  return
}

const findings = JSON.parse(Read(`tmp/arc/${id}/design-findings.json`))
if (findings.length === 0) {
  log("Design iteration skipped — zero findings from Phase 5.2.")
  updateCheckpoint({ phase: "design_iteration", status: "skipped" })
  return
}

// 2. Check agent-browser availability
const agentBrowserAvailable = Bash("agent-browser --version 2>/dev/null && echo 'yes' || echo 'no'").trim() === "yes"
if (!agentBrowserAvailable) {
  warn("Design iteration skipped — agent-browser not installed. Install: npm i -g @vercel/agent-browser")
  updateCheckpoint({ phase: "design_iteration", status: "skipped" })
  return
}

// 3. Configuration
const maxIterations = designSyncConfig.max_iterations ?? 3
const maxWorkers = designSyncConfig.max_iteration_workers ?? 2
const fidelityThreshold = designSyncConfig.fidelity_threshold ?? 80
let baseUrl = designSyncConfig.base_url ?? "http://localhost:3000"

// URL scope restriction (SEC-003): hard-block non-localhost URLs
const urlHost = new URL(baseUrl).hostname
if (urlHost !== 'localhost' && urlHost !== '127.0.0.1') {
  warn(`Design iteration base_url ${baseUrl} is not localhost — overriding to localhost`)
  baseUrl = "http://localhost:3000"
}

// 4. Load design criteria matrix from Phase 5.2 (primary convergence gate)
// Per-criterion PASS/FAIL is the PRIMARY gate; score threshold is SECONDARY.
// See design-convergence.md for the full criteria-based convergence protocol.
const criteriaMatrixPath = `tmp/arc/${id}/design-criteria-matrix-0.json`
let criteriaMatrix = null
if (exists(criteriaMatrixPath)) {
  criteriaMatrix = JSON.parse(Read(criteriaMatrixPath))
}

// 4.1. Primary gate: check DES- criteria status (criteria-based convergence)
if (criteriaMatrix) {
  const actionable = criteriaMatrix.criteria.filter(c => c.status !== "INCONCLUSIVE")
  const nonPass = actionable.filter(c => c.status !== "PASS")
  if (nonPass.length === 0) {
    log(`Design iteration skipped — all DES- criteria PASS (DSR: ${criteriaMatrix.summary.dsr}). Primary gate satisfied.`)
    updateCheckpoint({ phase: "design_iteration", status: "skipped", skip_reason: "all_criteria_pass" })
    return
  }
  log(`Design iteration: ${nonPass.length} DES- criteria non-PASS. Entering convergence loop.`)
}

// 4.2. Secondary gate: group findings by component using score threshold (backward compat)
const findingsByComponent = groupBy(findings.filter(f => f.score < fidelityThreshold), 'component')
const componentsToIterate = Object.keys(findingsByComponent)

if (componentsToIterate.length === 0 && !criteriaMatrix) {
  log(`Design iteration skipped — all components meet fidelity threshold (${fidelityThreshold}).`)
  updateCheckpoint({ phase: "design_iteration", status: "skipped" })
  return
}

// 5. Create iteration team
prePhaseCleanup(checkpoint)
TeamCreate({ team_name: `arc-design-iter-${id}` })

updateCheckpoint({
  phase: "design_iteration", status: "in_progress", phase_sequence: 7.6,
  team_name: `arc-design-iter-${id}`
})

// 6. Create iteration tasks
for (const component of componentsToIterate) {
  TaskCreate({
    subject: `Iterate design fidelity for ${component}`,
    description: `Run screenshot→analyze→fix loop for ${component}. Max ${maxIterations} iterations. Base URL: ${baseUrl}. Findings: ${JSON.stringify(findingsByComponent[component])}`,
    metadata: { phase: "iteration", component, max_iterations: maxIterations }
  })
}

// 7. MCP-First Design Iterator Discovery (v1.171.0+)
let iteratorAgentType = "design-iterator"
try {
  const candidates = agent_search({
    query: "design iteration refinement screenshot fidelity improvement",
    phase: "arc",
    category: "work",
    limit: 5
  })
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")
  const userAgent = candidates?.results?.find(c => c.source === "user" || c.source === "project")
  if (userAgent) iteratorAgentType = userAgent.name
} catch (e) { /* MCP unavailable — use default */ }

// Spawn design-iterator workers with agent-browser
for (let i = 0; i < Math.min(maxWorkers, componentsToIterate.length); i++) {
  Agent({
    subagent_type: "general-purpose", model: "sonnet",
    name: `design-iter-${i + 1}`, team_name: `arc-design-iter-${id}`,
    prompt: `You are design-iter-${i + 1}. Run screenshot→analyze→fix loop to improve design fidelity.
      Base URL: ${baseUrl}
      Browser session: --session arc-design-${id}
      Max iterations per component: ${maxIterations}
      Fidelity threshold: ${fidelityThreshold}
      Output iteration report to: tmp/arc/${id}/design-iteration-report.md
      [inject agent-browser skill content]
      [inject screenshot-comparison.md content]`
  })
}

// 8. Monitor
waitForCompletion(`arc-design-iter-${id}`, maxWorkers, {
  timeoutMs: 720_000, pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: Design Iteration"
})

// 9. Close browser sessions
Bash(`agent-browser session list 2>/dev/null | grep -F "arc-design-${id}" && agent-browser close --session "arc-design-${id}" 2>/dev/null || true`)

// 10. Shutdown workers + cleanup team
for (let i = 0; i < maxWorkers; i++) {
  SendMessage({ type: "shutdown_request", recipient: `design-iter-${i + 1}` })
}
sleep(20_000)

// TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-iteration cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-iter-${id}/" "$CHOME/tasks/arc-design-iter-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// 11. Per-criterion convergence assessment (design-convergence.md protocol)
// Re-evaluate DES- criteria after iteration fixes to detect regression (F10) and stagnation (F17).
if (criteriaMatrix) {
  // Re-run design proofs to update criteria status post-fix
  const updatedCriteria = criteriaMatrix.criteria.map(c => {
    // Each criterion re-evaluated by the design-iterator workers during their fix loop.
    // Read updated status from iteration output if available.
    const updatedFinding = findings.find(f => `DES-${f.component}-${f.dimension}` === c.id)
    const updatedScore = updatedFinding?.updated_score ?? updatedFinding?.score ?? 0
    const newStatus = updatedScore >= fidelityThreshold ? "PASS" : c.status === "INCONCLUSIVE" ? "INCONCLUSIVE" : "FAIL"
    return {
      ...c,
      previous_status: c.status,
      status: newStatus,
      evidence: updatedFinding?.updated_evidence ?? c.evidence
    }
  })

  // Regression detection (F10): criterion was PASS in baseline, now FAIL
  const regressions = updatedCriteria.filter(c => c.previous_status === "PASS" && c.status === "FAIL")
  if (regressions.length > 0) {
    warn(`Design regression (F10): ${regressions.map(r => r.id).join(', ')} regressed from PASS to FAIL`)
  }

  // Stagnation detection (F17): same criteria still failing after iteration
  const prevNonPass = criteriaMatrix.criteria.filter(c => c.status === "FAIL").map(c => c.id).sort()
  const currNonPass = updatedCriteria.filter(c => c.status === "FAIL").map(c => c.id).sort()
  const stagnation = JSON.stringify(prevNonPass) === JSON.stringify(currNonPass) && prevNonPass.length > 0
  if (stagnation) {
    warn(`Design stagnation (F17): same criteria failing after iteration: ${currNonPass.join(', ')}`)
  }

  const actionable = updatedCriteria.filter(c => c.status !== "INCONCLUSIVE")
  const passCount = actionable.filter(c => c.status === "PASS").length
  const dsr = actionable.length > 0 ? passCount / actionable.length : 1.0

  // Write post-iteration criteria matrix
  const postMatrix = {
    iteration: 1,
    timestamp: new Date().toISOString(),
    criteria: updatedCriteria,
    summary: { total: updatedCriteria.length, pass: passCount, fail: currNonPass.length, inconclusive: updatedCriteria.filter(c => c.status === "INCONCLUSIVE").length, dsr },
    regressions: regressions.map(r => r.id),
    stagnation_detected: stagnation
  }
  Write(`tmp/arc/${id}/design-criteria-matrix-1.json`, JSON.stringify(postMatrix, null, 2))

  // Write convergence report
  Write(`tmp/arc/${id}/design-convergence-report.json`, JSON.stringify({
    design_convergence: {
      iterations_used: 1,
      max_iterations: maxIterations,
      exit_reason: currNonPass.length === 0 ? "success" : stagnation ? "stagnation" : "budget_exceeded",
      exit_failure_code: currNonPass.length === 0 ? null : stagnation ? "F17" : "F15",
      final_dsr: dsr,
      first_pass_dsr: criteriaMatrix.summary.dsr,
      regressions_total: regressions.length,
      stagnation_rounds: stagnation ? 1 : 0,
      primary_gate: "criteria",
      secondary_gate_score: fidelityThreshold
    }
  }, null, 2))
}

const iterReport = exists(`tmp/arc/${id}/design-iteration-report.md`)
  ? Read(`tmp/arc/${id}/design-iteration-report.md`) : "No iteration report generated."

updateCheckpoint({
  phase: "design_iteration", status: "completed",
  artifact: `tmp/arc/${id}/design-iteration-report.md`,
  artifact_hash: sha256(iterReport),
  phase_sequence: 7.6, team_name: null,
  components_iterated: componentsToIterate.length,
  dsr: criteriaMatrix ? JSON.parse(Read(`tmp/arc/${id}/design-convergence-report.json`)).design_convergence.final_dsr : null
})
```

## Error Handling

| Error | Recovery |
|-------|----------|
| `design_sync.enabled` is false | Skip phase — status "skipped" |
| No design findings from Phase 5.2 | Skip phase — nothing to iterate on |
| agent-browser unavailable | Skip phase — design iteration requires browser |
| Max iterations reached (3) | Complete with current state, note partial convergence |
| Agent failure | Skip phase — design iteration is non-blocking |

## Crash Recovery

| Resource | Location |
|----------|----------|
| Iteration report | `tmp/arc/{id}/design-iteration-report.md` |
| Browser sessions | `arc-design-{id}` (check `agent-browser session list`) |
| Team config | `$CHOME/teams/arc-design-iter-{id}/` |
| Checkpoint state | `.claude/arc/{id}/checkpoint.json` (phase: "design_iteration") |

Recovery: On `--resume`, if design_iteration is `in_progress`, close any stale browser sessions (`agent-browser close --session "arc-design-{id}"`), clean up stale team, and re-run from the beginning. The screenshot→fix loop is idempotent — components are re-evaluated from their current state.
