# Phase 5.1: DRIFT REVIEW — Full Algorithm

Review drift signals from strive workers. Inline phase — no team creation.

**Team**: None (orchestrator-only, inline phase)
**Tools**: Read, Glob, Write
**Timeout**: 2 min (PHASE_TIMEOUTS.drift_review = 120_000)
**Inputs**: id (string), work phase timestamp
**Outputs**: tmp/arc/{id}/drift-review-report.md (or skipped if no signals)
**Error handling**: Non-blocking — skip on error (non-critical advisory phase)

## Algorithm

```javascript
updateCheckpoint({ phase: "drift_review", status: "in_progress", phase_sequence: 5.1, team_name: null })

// Discover drift signals from work phase
const workDir = checkpoint.phases.work?.artifact?.replace(/\/[^\/]+$/, '')
const driftFiles = workDir ? Glob(`${workDir}/drift-signals/*-drift.json`) : []

// Filter by session ownership
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
const ownedSignals = []

for (const file of driftFiles) {
  try {
    const signal = JSON.parse(Read(file))
    // Session isolation: only process signals from this session
    if (signal.config_dir !== configDir) continue
    if (signal.owner_pid && signal.owner_pid !== ownerPid) {
      // Check if owning PID is still alive
      const alive = Bash(`kill -0 ${signal.owner_pid} 2>/dev/null && echo alive || echo dead`).trim()
      if (alive === "alive") continue  // belongs to another live session
    }
    ownedSignals.push(signal)
  } catch (e) {
    warn(`Failed to parse drift signal: ${file}`)
  }
}

if (ownedSignals.length === 0) {
  updateCheckpoint({ phase: "drift_review", status: "skipped", phase_sequence: 5.1, team_name: null })
  return  // Zero overhead — no signals
}

// Categorize by severity
const blockers = ownedSignals.filter(s => s.severity === "blocks_task")
const workarounds = ownedSignals.filter(s => s.severity === "workaround_applied")
const cosmetic = ownedSignals.filter(s => s.severity === "cosmetic")

// Handle blockers — present to user
if (blockers.length > 0) {
  const blockerList = blockers.map(b =>
    `- Task ${b.task_id} (${b.type}): Plan says "${b.plan_says}" but ${b.reality}`
  ).join("\n")

  AskUserQuestion({
    question: `${blockers.length} drift signal(s) indicate plan-reality mismatch that blocked tasks:\n${blockerList}\n\nOptions:\n1. Continue — workers applied workarounds where possible\n2. Halt — fix plan and resume with /rune:arc --resume`,
    header: "Drift Signals"
  })
}

// Write drift review report
const report = `# Drift Review Report\n\n` +
  `Signals: ${ownedSignals.length} (${blockers.length} blockers, ${workarounds.length} workarounds, ${cosmetic.length} cosmetic)\n\n` +
  ownedSignals.map(s => `## ${s.task_id} — ${s.type} (${s.severity})\n- Plan: ${s.plan_says}\n- Reality: ${s.reality}`).join("\n\n")
Write(`tmp/arc/${id}/drift-review-report.md`, report)

updateCheckpoint({
  phase: "drift_review", status: "completed",
  artifact: `tmp/arc/${id}/drift-review-report.md`,
  phase_sequence: 5.1, team_name: null
})
```
