---
name: rune:cancel-arc
description: |
  Cancel an active arc pipeline and gracefully shutdown all phase teammates.
  Completed phase artifacts are preserved. Only the currently-active phase is cancelled.

  Use --status to inspect arc pipeline health without cancelling (runs rune-status.sh).

  <example>
  user: "/rune:cancel-arc"
  assistant: "The Tarnished halts the arc..."
  </example>

  <example>
  user: "/rune:cancel-arc --status"
  assistant: "Displays arc pipeline status report without cancelling."
  </example>
user-invocable: true
allowed-tools:
  - TaskList
  - TaskUpdate
  - TaskGet
  - TeamDelete
  - SendMessage
  - Read
  - Write
  - Bash
  - Glob
---

# /rune:cancel-arc — Cancel Active Arc Pipeline

Cancel an active arc pipeline and gracefully shutdown all phase teammates. Completed phase artifacts are preserved.

## Flags

| Flag | Description |
|------|-------------|
| `--status` | Display arc pipeline diagnostic status without cancelling. Runs `rune-status.sh` and returns. |

## Step -1. Handle --status Flag (Early Return)

```javascript
const args = "$ARGUMENTS"
if (args.includes('--status')) {
  const output = Bash(`"${CLAUDE_PLUGIN_ROOT}/scripts/rune-status.sh"`)
  // Display output and return — no cancellation
  return output
}
```

If `--status` is detected, run `rune-status.sh` and display its output. Do not proceed with cancellation.

## Steps

### 0. Cancel Arc Phase Loop and Arc-Batch Loop (if active and owned by this session)

```javascript
// Check for active arc-phase loop state file (innermost loop — check first)
const phaseStateFile = ".claude/arc-phase-loop.local.md"
const phaseExists = Bash(`test -f "${phaseStateFile}" && echo "yes" || echo "no"`).trim()

if (phaseExists === "yes") {
  const phaseContent = Read(phaseStateFile)
  const ownerPidMatch = phaseContent.match(/owner_pid:\s*(\d+)/)
  const configDirMatch = phaseContent.match(/config_dir:\s*(.+)/)
  const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
  const storedCfg = configDirMatch ? configDirMatch[1].trim() : null
  const currentCfg = Bash(`cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let isOwner = true
  if (storedCfg && storedCfg !== currentCfg) isOwner = false
  if (isOwner && ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
    const alive = Bash(`kill -0 ${ownerPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") isOwner = false
  }

  if (isOwner) {
    // Set cancellation flags instead of deleting the file
    // This allows recovery hooks to detect the cancellation
    const updatedContent = phaseContent.replace(/user_cancelled:\s*false/, 'user_cancelled: true')
      .replace(/cancel_reason:\s*null/, 'cancel_reason: "user_request"')
      .replace(/cancelled_at:\s*null/, `cancelled_at: "${new Date().toISOString()}"`)
      .replace(/stop_reason:\s*null/, 'stop_reason: "user_cancel"')
    Write(phaseStateFile, updatedContent)
    log("Arc phase loop cancelled (user_cancelled flag set)")
  } else {
    warn(`Arc phase loop belongs to another session (PID: ${ownerPid}). Skipping.`)
  }
}
```

#### Cancel Arc-Batch Loop (if active and owned by this session)

```javascript
// Check for active arc-batch loop state file
const batchStateFile = ".claude/arc-batch-loop.local.md"
const batchExists = Bash(`test -f "${batchStateFile}" && echo "yes" || echo "no"`).trim()

if (batchExists === "yes") {
  // Read iteration info and ownership before removing
  const batchContent = Read(batchStateFile)
  const iterMatch = batchContent.match(/iteration:\s*(\d+)/)
  const totalMatch = batchContent.match(/total_plans:\s*(\d+)/)
  const iteration = iterMatch ? iterMatch[1] : "?"
  const total = totalMatch ? totalMatch[1] : "?"

  // Check ownership — don't cancel another session's batch silently
  const ownerPidMatch = batchContent.match(/owner_pid:\s*(\d+)/)
  const configDirMatch = batchContent.match(/config_dir:\s*(.+)/)
  const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
  const storedCfg = configDirMatch ? configDirMatch[1].trim() : null
  const currentCfg = Bash(`cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let isOwner = true
  if (storedCfg && storedCfg !== currentCfg) isOwner = false
  if (isOwner && ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
    const alive = Bash(`kill -0 ${ownerPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") isOwner = false
  }

  if (isOwner) {
    // Remove state file to stop the batch loop
    Bash('rm -f .claude/arc-batch-loop.local.md')
    log(`Arc-batch loop also cancelled (was at iteration ${iteration}/${total})`)
  } else {
    warn(`Arc-batch loop belongs to another session (PID: ${ownerPid}). Skipping batch cancellation.`)
    warn("Use /rune:cancel-arc-batch from the owning session to cancel it.")
  }
}
```

### 1. Find Active Arc

```bash
# Find active arc checkpoint files
ls .claude/arc/*/checkpoint.json 2>/dev/null
```

If no active arc found: "No active arc pipeline to cancel."

### 2. Read Checkpoint

```javascript
checkpoint = Read(".claude/arc/{id}/checkpoint.json")

// Validate arc id from checkpoint before using in path construction
if (!/^arc-[a-zA-Z0-9_-]+$/.test(id)) throw new Error("Invalid arc id")

// Derive current phase — checkpoint has no `current_phase` field,
// scan phases object for the one with status "in_progress"
const [current_phase, phase_info] = Object.entries(checkpoint.phases)
  .find(([_, v]) => v.status === "in_progress") || [null, null]

phase_status = phase_info?.status

// Resolve team name from checkpoint (set by arc orchestrator when phase started)
let phase_team = phase_info?.team_name
if (!phase_team) {
  // Fallback for older checkpoints without team_name field
  const legacyMap = {
    forge: null,              // Pre-v1.28.2: inline forge had no team. v1.28.2+: checkpoint.team_name preferred; state file fallback at line 74
    plan_review: `arc-plan-review-${id}`,
    plan_refine: null,        // Orchestrator-only phase, no team
    verification: null,       // Orchestrator-only phase, no team
    work: null,               // Delegated (v1.28.0) -- team name from checkpoint
    gap_analysis: null,       // Orchestrator-only phase, no team
    verify_mend: null,        // Orchestrator-only phase, no team (convergence gate)
    code_review: null,        // Delegated (v1.28.0) -- team name from checkpoint
    mend: `arc-mend-${id}`,
  }
  phase_team = legacyMap[current_phase]
}

// Secondary fallback — discover team from state file for all delegated phases
if (phase_team === null && current_phase) {
  const typeMap = {
    forge: "forge", work: "work",
    code_review: "review", mend: "mend"
  }
  const type = typeMap[current_phase]
  if (type) {
    // BACK-004 FIX: Best-effort fallback — Glob order is arbitrary. First active match is used.
    // Primary team discovery is checkpoint.team_name above; this is degraded-mode recovery.
    const stateFiles = Glob(`tmp/.rune-${type}-*.json`)
    for (const f of stateFiles) {
      try {
        const stateData = JSON.parse(Read(f))
        const teamPattern = new RegExp(`^rune-${type}-[a-zA-Z0-9_-]+$`)
        if (stateData.status === "active" && stateData.team_name && teamPattern.test(stateData.team_name)) {
          phase_team = stateData.team_name
          break
        }
      } catch (e) { /* state file corrupted -- skip */ }
    }
  }
}

// Orchestrator-only phases (plan_refine, verification, gap_analysis, verify_mend) have no team.
// Skip team cancellation (Steps 3a-3d), go directly to Step 4.
if (phase_team === null || phase_team === undefined) {
  // No team to cancel — update checkpoint directly (Step 4)
}
```

If no phase has `status === "in_progress"`: "No active phase to cancel. Arc is idle or completed."

### 3. Cancel Current Phase

Delegate cancellation based on the currently-active phase:

| Phase | Action |
|-------|--------|
| **FORGE** (Phase 1) | Shutdown research team — broadcast cancellation, send shutdown requests |
| **PLAN REVIEW** (Phase 2) | Shutdown decree-arbiter review team |
| **PLAN REFINEMENT** (Phase 2.5) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **VERIFICATION** (Phase 2.7) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **WORK** (Phase 5) | Shutdown work team — broadcast cancellation, send shutdown requests to all rune-smith workers |
| **GAP ANALYSIS** (Phase 5.5) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **GOLDMASK VERIFICATION** (Phase 5.7) | Shutdown goldmask team (`goldmask-*`) — broadcast cancellation, send shutdown requests. Cleanup goldmask state files (`tmp/.rune-goldmask-*.json`) |
| **CODE REVIEW** (Phase 6) | Delegate to `/rune:cancel-review` logic — broadcast, shutdown Ash, cleanup |
| **MEND** (Phase 7) | Shutdown mend team — broadcast cancellation, send shutdown requests to all mend-fixer workers |
| **VERIFY MEND** (Phase 7.5) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **TEST** (Phase 7.7) | Shutdown test team (`arc-test-{id}`) — broadcast cancellation, send shutdown requests. Cleanup test state files (`tmp/.rune-test-*.json`) |
| **PRE-SHIP VALIDATION** (Phase 8.5) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **SHIP** (Phase 9) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **MERGE** (Phase 9.5) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
<!-- Phase 8 (AUDIT) removed in v1.67.0 — audit phases no longer exist in the arc pipeline -->

#### 3a. Broadcast Cancellation

```javascript
SendMessage({
  type: "broadcast",
  content: "Arc pipeline cancelled by user. Please finish current work and shutdown.",
  summary: "Arc cancelled"
})
```

#### 3b. Shutdown All Teammates

```javascript
// Read task list and cancel pending tasks
tasks = TaskList()
for (const task of tasks) {
  if (task.status === "pending" || task.status === "in_progress") {
    TaskUpdate({ taskId: task.id, status: "deleted" })
  }
}

// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// Read team config to discover active teammates — with fallback if config is missing/corrupt
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${phase_team}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: attempt TeamDelete directly — config may be missing or corrupt
  warn("Could not read/parse team config — attempting TeamDelete directly")
  allMembers = []
}

for (const member of allMembers) {
  SendMessage({
    type: "shutdown_request",
    recipient: member,
    content: "Arc pipeline cancelled by user"
  })
}
```

#### 3c. Grace Period (20s)

Let teammates process shutdown_request and deregister before TeamDelete.

```javascript
if (allMembers.length > 0) {
  Bash(`sleep 20`)
}
```

#### 3d. Delete Team

```javascript
// phase_team resolved in Step 2 from checkpoint.phases[current_phase].team_name
// (with legacy fallback for older checkpoints)
// SEC-003 FIX: Validate phase_team early + skip retry loop for null phase_team
if (phase_team && !/^[a-zA-Z0-9_-]+$/.test(phase_team)) throw new Error("Invalid phase_team")
if (phase_team && phase_team.includes('..')) throw new Error('Path traversal detected in phase_team')
if (phase_team) {
  // TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
  const RETRY_DELAYS = [0, 5000, 10000, 15000]
  let cleanupTeamDeleteSucceeded = false
  for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
    if (attempt > 0) {
      warn(`Cancel cleanup: TeamDelete attempt ${attempt + 1} failed, retrying in ${RETRY_DELAYS[attempt]/1000}s...`)
      Bash(`sleep ${RETRY_DELAYS[attempt] / 1000}`)
    }
    try {
      TeamDelete()
      cleanupTeamDeleteSucceeded = true
      break
    } catch (e) {
      if (attempt === RETRY_DELAYS.length - 1) {
        warn(`Cancel cleanup: TeamDelete failed after ${RETRY_DELAYS.length} attempts. Using filesystem fallback.`)
      }
    }
  }
  // Process-level kill — terminate orphaned teammate processes (step 5a)
  if (!cleanupTeamDeleteSucceeded) {
    const ownerPid = Bash(`echo $PPID`).trim()
    if (ownerPid && /^\d+$/.test(ownerPid)) {
      Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
      Bash(`sleep 3`)
      Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
    }
  }
  // Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
  // SEC-003: phase_team validated above — contains only [a-zA-Z0-9_-]
  if (!cleanupTeamDeleteSucceeded) {
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${phase_team}/" "$CHOME/tasks/${phase_team}/" 2>/dev/null`)
    try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
  }
} // end if (phase_team)
```

### 4. Update Checkpoint

```bash
# Update checkpoint.json — mark current phase as cancelled
# Read current checkpoint, update phase status, write back
```

Update the checkpoint so that:
- `phases[{current_phase}].status` = `"cancelled"` (where `current_phase` is derived from scanning `phases` for `"in_progress"`)
- `phases[{current_phase}].cancelled_at` = ISO timestamp
- Overall arc status remains intact (not "completed")

#### 4b. Set Cancellation Fields (Schema v22)

```javascript
// Set user cancellation tracking fields
checkpoint.user_cancelled = true
checkpoint.cancel_reason = "user_requested"
checkpoint.cancelled_at = new Date().toISOString()
checkpoint.stop_reason = "cancel-arc command invoked"
Write(`.claude/arc/${id}/checkpoint.json`, checkpoint)
```

### 5. Preserve Completed Artifacts

Do NOT delete any files from completed phases:
- `.claude/arc/{id}/` directory is preserved
- `tmp/` output from completed phases is preserved
- Only the in-progress phase's team resources are cleaned up

### 6. Report

```javascript
// Dynamically iterate PHASE_ORDER for the report (no hardcoded phase names)
const PHASE_LABELS = {
  forge: '1 (FORGE)', plan_review: '2 (PLAN REVIEW)', plan_refine: '2.5 (PLAN REFINEMENT)',
  verification: '2.7 (VERIFICATION)', semantic_verification: '2.8 (SEMANTIC VERIFICATION)',
  design_extraction: '3 (DESIGN EXTRACTION)', design_prototype: '3.2 (DESIGN PROTOTYPE)', task_decomposition: '4.5 (TASK DECOMPOSITION)',
  work: '5 (WORK)', design_verification: '5.2 (DESIGN VERIFICATION)',
  gap_analysis: '5.5 (GAP ANALYSIS)', codex_gap_analysis: '5.6 (CODEX GAP ANALYSIS)',
  gap_remediation: '5.8 (GAP REMEDIATION)', goldmask_verification: '5.7 (GOLDMASK VERIFICATION)',
  code_review: '6 (CODE REVIEW)', goldmask_correlation: '6.5 (GOLDMASK CORRELATION)',
  mend: '7 (MEND)', verify_mend: '7.5 (VERIFY MEND)', design_iteration: '7.6 (DESIGN ITERATION)',
  test: '7.7 (TEST)', test_coverage_critique: '7.8 (TEST COVERAGE CRITIQUE)',
  pre_ship_validation: '8.5 (PRE-SHIP VALIDATION)', release_quality_check: '8.55 (RELEASE QUALITY CHECK)',
  ship: '9 (SHIP)', bot_review_wait: '9.1 (BOT REVIEW WAIT)',
  pr_comment_resolution: '9.2 (PR COMMENT RESOLUTION)', merge: '9.5 (MERGE)'
}

let report = `Arc pipeline cancelled.\n\n`
report += `Phase ${PHASE_LABELS[current_phase] || current_phase} was in progress — cancelled.\n`
report += `Completed phases preserved:\n`
for (const phaseName of PHASE_ORDER) {
  const p = checkpoint.phases[phaseName]
  if (p) {
    report += `- Phase ${PHASE_LABELS[phaseName]}: ${p.status}\n`
  }
}
report += `\nArtifacts remain in: .claude/arc/${id}/\nTo resume: /rune:arc --resume`
```

## Notes

- Only the currently-active phase is cancelled — completed phases are untouched
- All team resources (Agent Teams) are fully cleaned up
- Checkpoint file is updated to reflect cancellation, enabling `--resume` later
- Pending and in-progress tasks are deleted to prevent orphaned work
- If the arc has multiple active checkpoints, cancel the most recent one
