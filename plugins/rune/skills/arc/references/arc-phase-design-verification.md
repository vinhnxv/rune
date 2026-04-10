# Phase 5.2: DESIGN VERIFICATION — Arc Design Sync Integration

Reviews implementation fidelity against Visual Spec Maps (VSM) produced by Phase 3 (DESIGN EXTRACTION).
Gated by `design_sync.enabled` in talisman. **Non-blocking** — design phases never halt the pipeline.

**Team**: `arc-design-verify-{id}` (design-implementation-reviewer agent)
**Tools**: Read, Write, Agent, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage
**Timeout**: 8 min (PHASE_TIMEOUTS.design_verification = 480_000)
**Inputs**: id, VSM files from Phase 3 (`tmp/arc/{id}/vsm/`), implemented component files
**Outputs**: `tmp/arc/{id}/design-verification-report.md`, `tmp/arc/{id}/design-findings.json`
**Error handling**: Non-blocking. Skip if no VSM files from Phase 3. Reviewer failure → skip with warning.
**Consumers**: Phase 7.6 DESIGN ITERATION (reads findings), WORK phase workers (consult findings for fixes)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities
> available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

1. Skip gate — `arcConfig.design_sync?.enabled !== true` → skip
2. Verify VSM files exist from Phase 3 — skip if none found
3. Check design_extraction phase status — skip if "skipped"

## Algorithm

```javascript
updateCheckpoint({ phase: "design_verification", status: "in_progress", phase_sequence: 5.2, team_name: null })

// 0. Skip gate — design sync is DISABLED by default (opt-in via talisman)
const designSyncConfig = arcConfig.design_sync ?? {}
const designSyncEnabled = designSyncConfig.enabled === true
if (!designSyncEnabled) {
  log("Design verification skipped — design_sync.enabled is false in talisman.")
  updateCheckpoint({ phase: "design_verification", status: "skipped", skip_reason: "design_sync_disabled" })
  return
}

// 1. Check upstream Phase 3 ran
const extractionPhase = checkpoint.phases?.design_extraction
if (!extractionPhase || extractionPhase.status === "skipped") {
  log("Design verification skipped — Phase 3 (DESIGN EXTRACTION) was skipped.")
  updateCheckpoint({ phase: "design_verification", status: "skipped", skip_reason: "design_extraction_skipped" })
  return
}

// 2. Verify VSM files exist
const vsmFiles = Bash(`find "tmp/arc/${id}/vsm" -name "*.json" 2>/dev/null`).trim().split('\n').filter(Boolean)
if (vsmFiles.length === 0) {
  warn("Design verification: No VSM files found from Phase 3. Skipping.")
  updateCheckpoint({ phase: "design_verification", status: "skipped", skip_reason: "no_vsm_files" })
  return
}

// 3. Create verification team
prePhaseCleanup(checkpoint)
TeamCreate({ team_name: `arc-design-verify-${id}` })

updateCheckpoint({
  phase: "design_verification", status: "in_progress", phase_sequence: 5.2,
  team_name: `arc-design-verify-${id}`
})

// 4. Create review tasks (one per VSM)
for (const vsm of vsmFiles) {
  TaskCreate({
    subject: `Review fidelity for ${vsm}`,
    description: `Compare implementation against VSM at ${vsm}. Score 6 dimensions: tokens, layout, responsive, a11y, variants, states. Output findings to tmp/arc/${id}/design-findings-${vsm}.json`,
    metadata: { phase: "verification", vsm_path: vsm }
  })
}

// 5. Spawn design-implementation-reviewer
Agent({
  subagent_type: "general-purpose", model: "sonnet",
  name: "design-reviewer-1", team_name: `arc-design-verify-${id}`,
  prompt: `You are design-reviewer-1. Review design fidelity of implemented components against VSM files.
    VSM directory: tmp/arc/${id}/vsm/
    Output findings to: tmp/arc/${id}/design-findings.json
    Summary report to: tmp/arc/${id}/design-verification-report.md
    [inject fidelity-scoring.md content]`
})

// 6. Monitor
waitForCompletion(`arc-design-verify-${id}`, 1, { timeoutMs: 360_000, pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: Design Verification" })

// 7. Cleanup — standard 5-component pattern (CLAUDE.md compliance)
// 1. Dynamic member discovery
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/arc-design-verify-${id}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  allMembers = ["design-reviewer-1"]
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
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Design verification complete" }); confirmedAlive++ } catch (e) { confirmedDead++ }
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
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-verification cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
  Bash(`sleep 5`, { run_in_background: true })
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-verify-${id}/" "$CHOME/tasks/arc-design-verify-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// 7.5. Mandatory artifact check (mirrors WRK-ART pattern)
const reportExists = exists(`tmp/arc/${id}/design-verification-report.md`)
const findingsFileExists = exists(`tmp/arc/${id}/design-findings.json`)

if (!reportExists || !findingsFileExists) {
  warn(`Design verification: Missing mandatory artifacts. Report: ${reportExists}, Findings: ${findingsFileExists}`)
  // Write empty-but-present artifacts to prevent downstream parse errors
  if (!reportExists) {
    Write(`tmp/arc/${id}/design-verification-report.md`, `# Design Verification Report\n\n**Status**: INCOMPLETE — reviewer agent failed to produce output.\n**Action**: Manual design review recommended.\n`)
  }
  if (!findingsFileExists) {
    Write(`tmp/arc/${id}/design-findings.json`, '[]')
  }
  updateCheckpoint({
    phase: "design_verification", status: "completed",
    artifact_incomplete: true,
    missing_artifacts: [!reportExists && "report", !findingsFileExists && "findings"].filter(Boolean)
  })
}

// 8. Read findings
const findingsExist = exists(`tmp/arc/${id}/design-findings.json`)
const findings = findingsExist ? JSON.parse(Read(`tmp/arc/${id}/design-findings.json`)) : []
const fidelityScore = findings.reduce((sum, f) => sum + (f.score ?? 0), 0) / Math.max(findings.length, 1)

// 8.5. Build DES-prefixed per-criterion evidence matrix (design-convergence.md input)
// Each finding is classified with a DES- criterion ID for convergence tracking.
const designCriteriaMatrix = {
  iteration: 0,  // baseline (pre-convergence)
  timestamp: new Date().toISOString(),
  criteria: findings.map(f => ({
    id: `DES-${f.component}-${f.dimension}`,
    component: f.component,
    dimension: f.dimension,
    status: (f.score ?? 0) >= (designSyncConfig.fidelity_threshold ?? 80) ? "PASS" : "FAIL",
    proof_type: f.proof_type ?? "fidelity_review",
    evidence: f.evidence ?? f.summary ?? "",
    failure_code: (f.score ?? 0) >= (designSyncConfig.fidelity_threshold ?? 80) ? null : "F3",
    previous_status: null
  })),
  summary: {
    total: findings.length,
    pass: findings.filter(f => (f.score ?? 0) >= (designSyncConfig.fidelity_threshold ?? 80)).length,
    fail: findings.filter(f => (f.score ?? 0) < (designSyncConfig.fidelity_threshold ?? 80)).length,
    inconclusive: 0,
    dsr: findings.length > 0
      ? findings.filter(f => (f.score ?? 0) >= (designSyncConfig.fidelity_threshold ?? 80)).length / findings.length
      : 1.0
  }
}
Write(`tmp/arc/${id}/design-criteria-matrix-0.json`, JSON.stringify(designCriteriaMatrix, null, 2))

updateCheckpoint({
  phase: "design_verification", status: "completed",
  artifact: `tmp/arc/${id}/design-verification-report.md`,
  artifact_hash: exists(`tmp/arc/${id}/design-verification-report.md`)
    ? sha256(Read(`tmp/arc/${id}/design-verification-report.md`)) : null,
  phase_sequence: 5.2, team_name: null,
  fidelity_score: fidelityScore,
  findings_count: findings.length,
  des_criteria_count: designCriteriaMatrix.criteria.length,
  des_pass_count: designCriteriaMatrix.summary.pass,
  dsr: designCriteriaMatrix.summary.dsr
})
```

## Error Handling

| Error | Recovery |
|-------|----------|
| `design_sync.enabled` is false | Skip phase — status "skipped" |
| No VSM files from Phase 3 | Skip phase — nothing to verify |
| Reviewer agent failure | Skip phase — design verification is non-blocking |
| Fidelity score unavailable | Skip with warning — manual review recommended |

## Crash Recovery

| Resource | Location |
|----------|----------|
| Design verification report | `tmp/arc/{id}/design-verification-report.md` |
| Design findings | `tmp/arc/{id}/design-findings.json` |
| Team config | `$CHOME/teams/arc-design-verify-{id}/` |
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "design_verification") |

Recovery: On `--resume`, if design_verification is `in_progress`, clean up stale team and re-run from the beginning. Verification is idempotent — report and findings files are overwritten cleanly.
