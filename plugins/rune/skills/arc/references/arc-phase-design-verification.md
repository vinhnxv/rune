# Phase 5.2: DESIGN VERIFICATION — Arc Design Sync Integration

Reviews implementation fidelity against Visual Spec Maps (VSM) produced by Phase 3 (DESIGN EXTRACTION).
Gated by `design_sync.enabled` in talisman. **Non-blocking** — design phases never halt the pipeline.

**Team**: `arc-design-verify-{id}` (design-implementation-reviewer agent)
**Tools**: Read, Write, Task, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage
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
  updateCheckpoint({ phase: "design_verification", status: "skipped" })
  return
}

// 1. Check upstream Phase 3 ran
const extractionPhase = checkpoint.phases?.design_extraction
if (!extractionPhase || extractionPhase.status === "skipped") {
  log("Design verification skipped — Phase 3 (DESIGN EXTRACTION) was skipped.")
  updateCheckpoint({ phase: "design_verification", status: "skipped" })
  return
}

// 2. Verify VSM files exist
const vsmFiles = Bash(`find "tmp/arc/${id}/vsm" -name "*.json" 2>/dev/null`).trim().split('\n').filter(Boolean)
if (vsmFiles.length === 0) {
  warn("Design verification: No VSM files found from Phase 3. Skipping.")
  updateCheckpoint({ phase: "design_verification", status: "skipped" })
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
waitForCompletion(["design-reviewer-1"], { timeoutMs: 360_000 })

// 7. Cleanup
SendMessage({ type: "shutdown_request", recipient: "design-reviewer-1" })
sleep(20_000)

// TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-verification cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-verify-${id}/" "$CHOME/tasks/arc-design-verify-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// 8. Read findings
const findingsExist = exists(`tmp/arc/${id}/design-findings.json`)
const findings = findingsExist ? JSON.parse(Read(`tmp/arc/${id}/design-findings.json`)) : []
const fidelityScore = findings.reduce((sum, f) => sum + (f.score ?? 0), 0) / Math.max(findings.length, 1)

updateCheckpoint({
  phase: "design_verification", status: "completed",
  artifact: `tmp/arc/${id}/design-verification-report.md`,
  artifact_hash: exists(`tmp/arc/${id}/design-verification-report.md`)
    ? sha256(Read(`tmp/arc/${id}/design-verification-report.md`)) : null,
  phase_sequence: 5.2, team_name: null,
  fidelity_score: fidelityScore,
  findings_count: findings.length
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
| Checkpoint state | `.claude/arc/{id}/checkpoint.json` (phase: "design_verification") |

Recovery: On `--resume`, if design_verification is `in_progress`, clean up stale team and re-run from the beginning. Verification is idempotent — report and findings files are overwritten cleanly.
