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
    subagent_type: "design-iterator", model: "sonnet",
    name: `design-iter-${i + 1}`, team_name: `arc-design-iter-${id}`,
    prompt: `You are design-iter-${i + 1}. Run screenshot→analyze→fix loop to improve design fidelity.
      Base URL: ${baseUrl}
      Browser session: --session arc-design-${id}
      Max iterations per component: ${maxIterations}
      Fidelity threshold: ${fidelityThreshold}
      Output iteration report to: tmp/arc/${id}/design-iteration-report.md
      [inject agent-browser skill content]
      [inject screenshot-comparison.md content]

## Inner Flame Self-Review Protocol

Before completing your iteration task, execute the Inner Flame self-review:

**Layer 1 (Grounding):** For every fix I applied — did I verify the change by re-reading the file? For every fidelity improvement claimed — do I have evidence (screenshot diff, token scan)? For every file path in my report — did I Read() it?

**Layer 2 (Completeness):** Did I address all non-PASS DES- criteria assigned to me? Did I write iteration evidence to tmp/arc/{id}/design-iteration-evidence-{component}.json? Did I update the iteration report?

**Layer 3 (Self-Adversarial):** Could my fix introduce regressions in other dimensions (F10)? Did I check adjacent components for side effects? Am I reporting genuine improvement or just restating the original finding?`
  })
}

// 8. Monitor
waitForCompletion(`arc-design-iter-${id}`, maxWorkers, {
  timeoutMs: 720_000, pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: Design Iteration"
})

// 9. Close browser sessions
Bash(`agent-browser session list 2>/dev/null | grep -F "arc-design-${id}" && agent-browser close --session "arc-design-${id}" 2>/dev/null || true`)

// 10. Cleanup — standard 5-component pattern (CLAUDE.md compliance)
// 1. Dynamic member discovery
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/arc-design-iter-${id}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  allMembers = Array.from({ length: maxWorkers }, (_, i) => `design-iter-${i + 1}`)
}

// 2a. Force-reply
let confirmedAlive = 0
let confirmedDead = 0
const aliveMembers = []
for (const member of allMembers) {
  try { SendMessage({ type: "message", recipient: member, content: "Acknowledge: workflow completing" }); aliveMembers.push(member) } catch (e) { confirmedDead++ }
}
if (aliveMembers.length > 0) { Bash("sleep 2", { run_in_background: true }) }

// 2c. Send shutdown_request
for (const member of aliveMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Design iteration complete" }); confirmedAlive++ } catch (e) { confirmedDead++ }
}

// 3. Adaptive grace period
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`, { run_in_background: true })
} else {
  Bash("sleep 2", { run_in_background: true })
}

// 4. TeamDelete with retry-with-backoff
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-iteration cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
  Bash(`sleep 5`, { run_in_background: true })
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-iter-${id}/" "$CHOME/tasks/arc-design-iter-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
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

  // 11.1. Generate mend-compatible bridge format (design-convergence.md § Mend-Compatible Bridge Format)
  // Converts FAIL DES- criteria into mend-compatible findings for cross-phase resolution.
  const mendFindings = updatedCriteria
    .filter(c => c.status === "FAIL")
    .map(c => {
      const finding = findings.find(f => `DES-${f.component}-${f.dimension}` === c.id)
      const severity = finding?.severity ?? "MAJOR"
      const priority = (severity === "CRITICAL" || severity === "MAJOR") ? "P1"
        : severity === "MINOR" ? "P2" : "P3"
      return {
        id: c.id,
        prefix: "DES",
        priority,
        title: finding?.title ?? `${c.dimension} issue in ${c.component}`,
        file: finding?.file ?? finding?.source_file ?? null,
        line: finding?.line ?? null,
        evidence: c.evidence,
        fix_suggestion: finding?.fix_suggestion ?? null,
        status: "FAIL",
        resolution: null
      }
    })

  Write(`tmp/arc/${id}/design-findings-mend-compat.json`, JSON.stringify({
    source: "design_verification",
    format_version: "1.0",
    findings: mendFindings
  }, null, 2))

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

// 11.5. Build resolution report (mirrors mend resolution report pattern)
// Compare baseline (matrix-0) vs latest post-iteration matrix (matrix-N) criteria statuses.
const currentIteration = (() => {
  try {
    const conv = JSON.parse(Read(`tmp/arc/${id}/design-convergence-report.json`))
    return Math.max(1, conv.design_convergence?.iterations_used ?? 1)
  } catch (_) { return 1 }
})()
const baselineMatrixPath = `tmp/arc/${id}/design-criteria-matrix-0.json`
const latestMatrixPath = `tmp/arc/${id}/design-criteria-matrix-${currentIteration}.json`

if (exists(baselineMatrixPath) && exists(latestMatrixPath)) {
  const baselineMatrix = JSON.parse(Read(baselineMatrixPath))
  const latestMatrix = JSON.parse(Read(latestMatrixPath))
  const baselineById = Object.fromEntries(baselineMatrix.criteria.map(c => [c.id, c]))
  const resolved = []   // FAIL → PASS
  const regressed = []  // PASS → FAIL (F10)
  const inconclusive = []
  const unresolved = []

  for (const c of latestMatrix.criteria) {
    const prev = baselineById[c.id]
    const prevStatus = prev?.status ?? "FAIL"
    if (prevStatus === "FAIL" && c.status === "PASS") {
      resolved.push(c.id)
    } else if (prevStatus === "PASS" && c.status === "FAIL") {
      regressed.push(c.id)
    } else if (c.status === "INCONCLUSIVE") {
      inconclusive.push(c.id)
    } else if (c.status !== "PASS") {
      unresolved.push(c.id)
    }
  }

  Write(`tmp/arc/${id}/design-resolution-report.json`, JSON.stringify({
    total_criteria: latestMatrix.criteria.length,
    resolved,
    unresolved,
    regressed,
    inconclusive,
    baseline_matrix: baselineMatrixPath,
    latest_matrix: latestMatrixPath,
    iteration: currentIteration,
    timestamp: new Date().toISOString()
  }, null, 2))
} else {
  // Matrices missing — write minimal report with skip reason
  Write(`tmp/arc/${id}/design-resolution-report.json`, JSON.stringify({
    total_criteria: 0,
    resolved: [],
    unresolved: [],
    regressed: [],
    inconclusive: [],
    skip_reason: !exists(baselineMatrixPath) ? "baseline_matrix_missing" : "latest_matrix_missing",
    timestamp: new Date().toISOString()
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
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "design_iteration") |

Recovery: On `--resume`, if design_iteration is `in_progress`, close any stale browser sessions (`agent-browser close --session "arc-design-{id}"`), clean up stale team, and re-run from the beginning. The screenshot→fix loop is idempotent — components are re-evaluated from their current state.
