# Phase 3.3: STORYBOOK VERIFICATION — Component Visual Verification

Verifies UI components via Storybook stories using hybrid MCP + agent-browser approach.
Two modes: Design Fidelity (with VSM) and UI Quality Audit (without Figma).
Gated by `storybook.enabled` in talisman. **Non-blocking** — never halts pipeline.

**Team**: `arc-storybook-{id}` (storybook-reviewer + storybook-fixer workers)
**Timeout**: 15 min (PHASE_TIMEOUTS.storybook_verification = 900_000)
**Inputs**: id, implemented component files from Phase 5 (WORK), VSM files (optional)
**Outputs**: `tmp/arc/{id}/storybook-verification/`, `tmp/arc/{id}/storybook-report.md`
**Error handling**: Non-blocking. Skip if Storybook not detected. Server unavailable → skip.
**Consumers**: Phase 5.2 DESIGN VERIFICATION, Phase 7.7 TEST (storybook coverage in diagnostics)

## Algorithm

```javascript
// Stamp phase start time
checkpoint.phases.storybook_verification.started_at = new Date().toISOString()
Write(checkpointPath, checkpoint)

// readTalismanSection: "misc"
const misc = readTalismanSection("misc")
const sbConfig = misc?.storybook ?? {}

// 0. Skip gate — storybook is DISABLED by default (opt-in via talisman)
const sbEnabled = sbConfig.enabled === true
if (!sbEnabled) {
  log("Storybook verification skipped — storybook.enabled is false in talisman.")
  checkpoint.phases.storybook_verification.status = "skipped"
  checkpoint.phases.storybook_verification.skip_reason = "disabled"
  checkpoint.phases.storybook_verification.verdict = "SKIPPED"
  checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
  Write(checkpointPath, checkpoint)
  return  // STOP — Stop hook advances to next phase
}

// 1. Detect Storybook — check BOTH project-level and tmp/storybook/ (Rune ephemeral)
const hasPackageJson = (() => {
  try { Read("package.json"); return true } catch { return false }
})()
const hasStorybookDep = hasPackageJson &&
  (JSON.parse(Read("package.json")).devDependencies?.["storybook"] ||
   JSON.parse(Read("package.json")).devDependencies?.["@storybook/react"] ||
   JSON.parse(Read("package.json")).devDependencies?.["@storybook/vue3"])
const hasStorybookConfig = (() => {
  try { Read(".storybook/main.ts"); return true } catch {
    try { Read(".storybook/main.js"); return true } catch { return false }
  }
})()

// Also check for Rune's ephemeral Storybook at tmp/storybook/
const hasRuneStorybook = (() => {
  try { Read("tmp/storybook/package.json"); return true } catch { return false }
})()

if (!hasStorybookDep && !hasStorybookConfig && !hasRuneStorybook) {
  log("Storybook verification skipped — Storybook not detected in project or tmp/storybook/.")
  checkpoint.phases.storybook_verification.status = "skipped"
  checkpoint.phases.storybook_verification.skip_reason = "storybook_not_installed"
  checkpoint.phases.storybook_verification.verdict = "SKIPPED"
  checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
  Write(checkpointPath, checkpoint)
  return
}

// Determine which Storybook to use — prefer tmp/storybook/ when available
const useRuneStorybook = hasRuneStorybook
const storybookRoot = useRuneStorybook ? "tmp/storybook" : "."

// 2. Check work phase ran (need components to verify)
const workPhase = checkpoint.phases?.work
if (!workPhase || workPhase.status === "skipped") {
  log("Storybook verification skipped — Phase 5 (WORK) was skipped.")
  checkpoint.phases.storybook_verification.status = "skipped"
  checkpoint.phases.storybook_verification.skip_reason = "work_phase_skipped"
  checkpoint.phases.storybook_verification.verdict = "SKIPPED"
  checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
  Write(checkpointPath, checkpoint)
  return
}

// 3. Frontend relevance check — skip if no frontend work detected
const FRONTEND_KEYWORDS = /\b(component|frontend|ui|ux|storybook|design|layout|style|css|scss|tailwind|responsive|view|page|screen|widget|template|render)\b/i
const FRONTEND_FILE_EXTENSIONS = /\.(tsx|jsx|vue|svelte|astro|css|scss|sass|less|stories\.\w+)$/

// Signal 1: Check plan content
const planPath = checkpoint.plan_file ?? `tmp/arc/${id}/enriched-plan.md`
const planContent = (() => { try { return Read(planPath) } catch { return "" } })()
const planHasFrontend = FRONTEND_KEYWORDS.test(planContent)

// Signal 2: Check changed files from work phase
const workCommits = workPhase.commits ?? 1
const workDiff = Bash(`git diff --name-only HEAD~${workCommits} HEAD 2>/dev/null`).trim()
const changedFiles = workDiff ? workDiff.split('\n') : []
const hasFrontendFiles = changedFiles.some(f => FRONTEND_FILE_EXTENSIONS.test(f))

if (!planHasFrontend && !hasFrontendFiles) {
  log("Storybook verification skipped — no frontend relevance detected.")
  checkpoint.phases.storybook_verification.status = "skipped"
  checkpoint.phases.storybook_verification.skip_reason = "no_frontend_relevance"
  checkpoint.phases.storybook_verification.verdict = "SKIPPED"
  checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
  Write(checkpointPath, checkpoint)
  return
}

// 4. Verify Storybook server is running
// SEC-SBK-004: Validate port is numeric and in valid range
const sbPort = (() => {
  // BACK-002 FIX: Strict numeric validation before parseInt (rejects "6006xyz")
  const rawPort = String(sbConfig.port ?? 6006)
  if (!/^\d+$/.test(rawPort)) {
    warn("Non-numeric storybook port — using default 6006")
    return 6006
  }
  const p = parseInt(rawPort, 10)
  if (p < 1024 || p > 65535) {
    warn("Storybook port out of range (1024-65535) — using default 6006")
    return 6006
  }
  return p
})()

const sbRunning = Bash(`curl -sf http://localhost:${sbPort} > /dev/null 2>&1 && echo "up" || echo "down"`).trim()
if (sbRunning === "down") {
  if (sbConfig.auto_start === true || useRuneStorybook) {
    if (useRuneStorybook) {
      // Use Rune's bootstrap script to ensure tmp/storybook/ is ready
      // Copy work phase component stories into tmp/storybook/src/components/
      const storyFiles = changedFiles.filter(f => f.endsWith('.stories.tsx'))
      if (storyFiles.length > 0) {
        const bootstrapScript = `${CLAUDE_PLUGIN_ROOT}/scripts/storybook/bootstrap.sh`
        Bash(`cd "${CWD}" && bash "${bootstrapScript}" --story-files ${storyFiles.join(' ')}`)
      }
      Bash(`cd "${CWD}/tmp/storybook" && npm run storybook -- --port ${sbPort} --ci --no-open &`, { timeout: 15000 })
    } else {
      Bash(`npx storybook dev --port ${sbPort} --ci --no-open &`, { timeout: 15000 })
    }
    Bash("sleep 10")  // Wait for server startup
    const recheck = Bash(`curl -sf http://localhost:${sbPort} > /dev/null 2>&1 && echo "up" || echo "down"`).trim()
    if (recheck === "down") {
      warn("Storybook server failed to start. Skipping verification.")
      checkpoint.phases.storybook_verification.status = "skipped"
      checkpoint.phases.storybook_verification.skip_reason = "server_start_failed"
      checkpoint.phases.storybook_verification.verdict = "SKIPPED"
      checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
      Write(checkpointPath, checkpoint)
      return
    }
  } else {
    warn("Storybook server not running. Start with: npx storybook dev --port " + sbPort)
    checkpoint.phases.storybook_verification.status = "skipped"
    checkpoint.phases.storybook_verification.skip_reason = "server_not_running"
    checkpoint.phases.storybook_verification.verdict = "SKIPPED"
    checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
    Write(checkpointPath, checkpoint)
    return
  }
}

// 5. Check agent-browser availability
const agentBrowserAvailable = Bash("command -v agent-browser > /dev/null 2>&1 && echo 'yes' || echo 'no'").trim() === "yes"
if (!agentBrowserAvailable) {
  warn("Storybook verification: agent-browser not installed. Skipping visual checks.")
  // Fall through — continue with MCP-only if possible, otherwise skip
}

// 5.5. Check Storybook MCP addon availability (VEIL-002 FIX)
const hasMcpAddon = hasPackageJson &&
  (JSON.parse(Read("package.json")).devDependencies?.["@storybook/addon-mcp"])
if (!hasMcpAddon) {
  warn("@storybook/addon-mcp not detected — MCP-based story discovery unavailable. Falling back to convention-based discovery.")
}

// 6. Determine verification mode
const vsmFiles = Bash(`find "tmp/arc/${id}/vsm" -name "*.json" 2>/dev/null`).trim()
const mode = vsmFiles ? "design_fidelity" : "ui_quality_audit"

// 7. Discover components to verify
// Strategy: frontend files changed in work phase that have (or should have) stories
const frontendChanges = changedFiles.filter(f => FRONTEND_FILE_EXTENSIONS.test(f))
  .filter(f => !f.includes('.stories.'))  // Exclude story files themselves
  .filter(f => !f.includes('.test.') && !f.includes('.spec.'))  // Exclude test files
const changedComponents = frontendChanges.map(f => ({
  path: f,
  // SEC-SBK-007: Sanitize component name for file paths
  name: f.split('/').pop().replace(/\.[^.]+$/, '').replace(/[^a-zA-Z0-9_-]/g, '_')
}))

if (changedComponents.length === 0) {
  log("Storybook verification skipped — no component files changed in work phase.")
  checkpoint.phases.storybook_verification.status = "skipped"
  checkpoint.phases.storybook_verification.skip_reason = "no_component_changes"
  checkpoint.phases.storybook_verification.verdict = "SKIPPED"
  checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
  Write(checkpointPath, checkpoint)
  return
}

// ── Task Ownership Contract (VEIL-005 FIX) ──
// Workers claim tasks via TaskUpdate({ taskId, owner: workerName, status: "in_progress" }).
// Each task corresponds to one component. Workers self-assign from the unowned pool.
// No two workers should claim the same task — TaskUpdate is atomic per the SDK.
// If a worker stalls (>10 min), autoRelease makes the task claimable by another worker.

// ── Session Isolation (QUAL-006 / DOC-001 FIX) ──
// The team name `arc-storybook-${id}` is scoped by the arc session id.
// Checkpoint fields (started_at, team_name, verdict) are written to the arc checkpoint
// which includes config_dir + owner_pid for cross-session safety.
// prePhaseCleanup() cleans up stale teams from prior sessions before TeamCreate.

// 8. Create team + tasks
prePhaseCleanup(checkpoint)
// SEC-SBK-006: Validate id before shell interpolation
if (!/^[a-zA-Z0-9_-]+$/.test(id)) { error("Invalid arc id"); return }
const teamName = `arc-storybook-${id}`
TeamCreate({ team_name: teamName })
checkpoint.phases.storybook_verification.status = "in_progress"
checkpoint.phases.storybook_verification.team_name = teamName
Write(checkpointPath, checkpoint)

Bash(`mkdir -p "tmp/arc/${id}/storybook-verification"`)

const maxWorkers = Math.min(sbConfig.max_workers ?? 2, changedComponents.length)
const maxRounds = sbConfig.max_rounds ?? 3

for (const component of changedComponents) {
  TaskCreate({
    subject: `Verify: ${component.name}`,
    description: `Storybook verify ${component.path}\nMode: ${mode}\nMax rounds: ${maxRounds}\nStorybook URL: http://localhost:${sbPort}\nOutput: tmp/arc/${id}/storybook-verification/${component.name}.md`,
    activeForm: `Verifying ${component.name}...`
  })
}

// 9. MCP-First Storybook Reviewer Discovery (v1.171.0+)
let storybookAgentType = "storybook-reviewer"
try {
  const candidates = agent_search({
    query: "storybook component verification visual quality review screenshot",
    phase: "arc",
    category: "work",
    limit: 5
  })
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")
  const userAgent = candidates?.results?.find(c =>
    (c.source === "user" || c.source === "project") && c.name !== "storybook-reviewer"
  )
  if (userAgent) storybookAgentType = userAgent.name
} catch (e) { /* MCP unavailable — use default */ }

// Spawn workers
// VEIL-001 FIX: Read agent instructions and inject into prompt
// (agent .md files are NOT auto-injected into general-purpose subagent context)
const agentInstructions = (() => {
  try { return Read("plugins/rune/agents/work/storybook-reviewer.md") } catch { return "" }
})()

for (let i = 1; i <= maxWorkers; i++) {
  Agent({
    subagent_type: "general-purpose",
    name: `storybook-reviewer-${i}`,
    team_name: teamName,
    prompt: `You are storybook-reviewer-${i}.

=== AGENT INSTRUCTIONS ===
${agentInstructions}
=== END AGENT INSTRUCTIONS ===

      Team: ${teamName}
      Mode: ${mode}
      Max rounds: ${maxRounds}
      Storybook URL: http://localhost:${sbPort}
      Agent-browser available: ${agentBrowserAvailable}
      MCP addon available: ${hasMcpAddon}
      ${vsmFiles ? `VSM directory: tmp/arc/${id}/vsm/` : 'No VSM — use UI Quality Audit mode (Mode B heuristic checklist).'}
      Output directory: tmp/arc/${id}/storybook-verification/

      Claim tasks from the task pool, verify each component, and write findings.`
  })
}

// 10. Monitor completion
const result = waitForCompletion(teamName, changedComponents.length, {
  timeoutMs: 720_000,       // 12 min inner timeout
  staleWarnMs: 300_000,     // 5 min
  autoReleaseMs: 600_000,   // 10 min
  pollIntervalMs: 30_000,   // 30 sec
  label: "Storybook Verification"
})

// 11. Aggregate results
const reports = Glob(`tmp/arc/${id}/storybook-verification/*.md`)
let totalScore = 0
let reportCount = 0
let p1Count = 0
let p2Count = 0
const summaryLines = []

for (const report of reports) {
  const content = Read(report)
  // Extract score from report
  const scoreMatch = content.match(/Final Score:\s*(\d+)/)
  if (scoreMatch) {
    totalScore += parseInt(scoreMatch[1])
    reportCount++
  }
  // Count P1/P2 findings
  p1Count += (content.match(/\[P1\]/g) || []).length
  p2Count += (content.match(/\[P2\]/g) || []).length
  summaryLines.push(`- ${report.split('/').pop()}: ${scoreMatch ? scoreMatch[1] + '/100' : 'N/A'}`)
}

const avgScore = reportCount > 0 ? Math.round(totalScore / reportCount) : 0
const fidelityThreshold = sbConfig.fidelity_threshold ?? 85
// VEIL-003 FIX: Explicit timeout verdict — do not mask timeouts as PASS/FAIL
const overallStatus = result.timedOut
  ? "TIMEOUT"
  : avgScore >= fidelityThreshold ? "PASS" : (p1Count > 0 ? "FAIL" : "NEEDS_ATTENTION")

// Write aggregate report
Write(`tmp/arc/${id}/storybook-report.md`, `# Storybook Verification Report

**Mode**: ${mode === "design_fidelity" ? "Design Fidelity" : "UI Quality Audit"}
**Components verified**: ${reportCount}/${changedComponents.length}
**Average score**: ${avgScore}/100
**Threshold**: ${fidelityThreshold}
**Status**: ${overallStatus}
**P1 findings**: ${p1Count}
**P2 findings**: ${p2Count}

## Component Results
${summaryLines.join('\n')}

${result.timedOut ? '\n**WARNING**: Verification timed out. Results may be incomplete.\n' : ''}
`)

log(`Storybook verification: ${overallStatus} (${avgScore}/100, ${p1Count} P1, ${p2Count} P2)`)

// 12. Cleanup (5-component standard pattern)
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  allMembers = Array.from({ length: maxWorkers }, (_, i) => `storybook-reviewer-${i + 1}`)
}

for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Storybook verification complete" })
}

if (allMembers.length > 0) { Bash("sleep 20") }

let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn("cleanup: TeamDelete failed after 4 attempts")
  }
}

// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// 12.5. Discipline Integration — Design Proof Evidence Collection
// When discipline is enabled, run design-specific proofs and write evidence artifacts.
// This integrates the 6 design proof types from execute-discipline-proofs.sh into
// the storybook verification phase for per-component evidence collection.
// readTalismanSection: "settings" → .discipline (standardized across all consumers)
const disciplineConfig = readTalismanSection("settings")?.discipline ?? {}
const disciplineEnabled = disciplineConfig.enabled !== false  // default: true

if (disciplineEnabled && changedComponents.length > 0) {
  // Build discipline criteria from verified components
  const designCriteria = []

  for (const component of changedComponents) {
    // Smoke test: storybook build renders without errors
    designCriteria.push({
      criterion_id: `DES-SBK-${component.name}-smoke`,
      type: "storybook_renders",
      target: component.path,
      command: `npx storybook build --smoke-test`
    })

    // Accessibility scan: axe-core WCAG AA on rendered component
    designCriteria.push({
      criterion_id: `DES-SBK-${component.name}-a11y`,
      type: "axe_passes",
      target: component.path,
      rules: "wcag2aa"
    })

    // Story coverage: verify story file exists for component
    designCriteria.push({
      criterion_id: `DES-SBK-${component.name}-story`,
      type: "story_exists",
      target: component.path,
      variants: []  // populated from VSM if available
    })

    // Token scan: no hardcoded hex colors in component
    designCriteria.push({
      criterion_id: `DES-SBK-${component.name}-tokens`,
      type: "token_scan",
      target: component.path
    })
  }

  // Write criteria file and execute proofs
  const criteriaPath = `tmp/arc/${id}/storybook-verification/design-criteria.json`
  Write(criteriaPath, JSON.stringify(designCriteria, null, 2))

  const proofScript = `${CLAUDE_PLUGIN_ROOT}/scripts/execute-discipline-proofs.sh`
  const proofOutput = Bash(`bash "${proofScript}" "${criteriaPath}" "${CWD}" 2>/dev/null || true`)

  // Write per-check evidence artifact: storybook-verification.json
  const evidencePath = `tmp/arc/${id}/storybook-verification/storybook-verification.json`
  Write(evidencePath, JSON.stringify({
    phase: "storybook_verification",
    arc_id: id,
    timestamp: new Date().toISOString(),
    mode: mode,
    components_verified: changedComponents.length,
    discipline_results: proofOutput ? JSON.parse(proofOutput) : [],
    design_gate: {
      block_on_fail: disciplineConfig.design?.block_on_fail ?? false,
      behavior: (disciplineConfig.design?.block_on_fail ?? false) ? "BLOCK" : "WARN"
    }
  }, null, 2))

  // Non-blocking gate: WARN on failures, configurable via talisman.design.block_on_fail
  const designBlockOnFail = disciplineConfig.design?.block_on_fail ?? false
  if (proofOutput) {
    const proofResults = JSON.parse(proofOutput)
    const proofFailures = proofResults.filter(r => r.result === "FAIL")
    if (proofFailures.length > 0 && designBlockOnFail) {
      warn(`Design discipline: ${proofFailures.length} proof failure(s) — blocking pipeline per design.block_on_fail`)
      checkpoint.phases.storybook_verification.discipline_gate = "BLOCKED"
    } else if (proofFailures.length > 0) {
      warn(`Design discipline: ${proofFailures.length} proof failure(s) — WARN only (design.block_on_fail: false)`)
      checkpoint.phases.storybook_verification.discipline_gate = "WARN"
    } else {
      checkpoint.phases.storybook_verification.discipline_gate = "PASS"
    }
  }
}

// 13. Update checkpoint
checkpoint.phases.storybook_verification.status = "completed"
checkpoint.phases.storybook_verification.completed_at = new Date().toISOString()
checkpoint.phases.storybook_verification.storybook_tier = agentBrowserAvailable ? "full" : "mcp_only"
checkpoint.phases.storybook_verification.score = avgScore
checkpoint.phases.storybook_verification.verdict = overallStatus
const phaseStartMs = new Date(checkpoint.phases.storybook_verification.started_at).getTime()
checkpoint.totals = checkpoint.totals ?? { phase_times: {} }
checkpoint.totals.phase_times.storybook_verification = Date.now() - phaseStartMs
Write(checkpointPath, checkpoint)
// STOP — Stop hook advances to next phase
```
