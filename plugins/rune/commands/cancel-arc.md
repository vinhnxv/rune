---
name: rune:cancel-arc
description: |
  Cancel an active arc pipeline and gracefully shutdown all phase teammates.
  Completed phase artifacts are preserved. Only the currently-active phase is cancelled.

  Use --status to inspect arc pipeline health without cancelling (runs rune-status.sh).
  Use --list-active to list all active arc-related state files without cancelling anything.
user-invocable: true
disable-model-invocation: true
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
| `--list-active` | List all active arc-related state files without cancelling anything. Early return. |

## Step -1. Handle --status Flag (Early Return)

```javascript
const args = "$ARGUMENTS"
if (args.includes('--status')) {
  const output = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/rune-status.sh"`)
  // Display output and return — no cancellation
  return output
}
```

If `--status` is detected, run `rune-status.sh` and display its output. Do not proceed with cancellation.

## Step -0.5. Handle --list-active Flag (Early Return)

```javascript
const args = "$ARGUMENTS"
if (args.includes('--list-active')) {
  const STATE_FILES = [
    ".rune/arc-phase-loop.local.md",
    ".rune/arc-batch-loop.local.md",
    ".rune/arc-hierarchy-loop.local.md",
    ".rune/arc-issues-loop.local.md",
  ]
  const currentCfg = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let found = []
  for (const sf of STATE_FILES) {
    const exists = Bash(`test -f "${sf}" && echo "yes" || echo "no"`).trim()
    if (exists !== "yes") continue

    const content = Read(sf)
    const ownerPidMatch = content.match(/owner_pid:\s*(\d+)/)
    const configDirMatch = content.match(/config_dir:\s*(.+)/)
    const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
    const storedCfg = configDirMatch ? configDirMatch[1].trim() : null

    let ownership = "this session"
    if (storedCfg && storedCfg !== currentCfg) {
      ownership = `other session (config: ${storedCfg})`
    } else if (ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
      const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
      ownership = alive === "alive" ? `other live session (PID: ${ownerPid})` : `dead session (PID: ${ownerPid})`
    }
    found.push(`  ${sf}  [${ownership}]`)
  }

  // Also report active arc checkpoints
  const checkpoints = Bash(`ls .rune/arc/*/checkpoint.json 2>/dev/null || true`).trim()
  if (checkpoints) {
    for (const cp of checkpoints.split("\n").filter(Boolean)) {
      found.push(`  ${cp}  [arc checkpoint]`)
    }
  }

  if (found.length === 0) {
    return "No active arc-related state files found."
  }
  return `Active arc-related state files:\n${found.join("\n")}`
}
```

If `--list-active` is detected, list active state files with ownership info and return — no cancellation.

<!-- v3.0.0-alpha.1: --variant=batch|hierarchy|issues handling removed.
     `/rune:cancel-arc-batch`, `/rune:cancel-arc-hierarchy`, `/rune:cancel-arc-issues`
     and the parent commands they aliased were deleted in alpha.1. -->

## Steps

### 0. Cancel Arc Phase Loop State File

```javascript
// Check for active arc-phase loop state file (innermost loop — check first)
const phaseStateFile = ".rune/arc-phase-loop.local.md"
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
    const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
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

<!-- v3.0.0-alpha.1: arc-batch / arc-hierarchy / arc-issues sub-cancellation removed.
     Those parent commands no longer exist; their state files are no longer written. -->

### 1. Find Active Arc

```bash
# Find active arc checkpoint files
ls .rune/arc/*/checkpoint.json 2>/dev/null
```

If no active arc found: "No active arc pipeline to cancel."

### 2. Read Checkpoint

```javascript
checkpoint = Read(".rune/arc/{id}/checkpoint.json")

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
    // v3.0.0-alpha.6 (Day 5 C4a): plan_refine absorbed into plan_review.
    verification: null,       // Orchestrator-only phase, no team
    work: null,               // Delegated (v1.28.0) -- team name from checkpoint
    gap_analysis: null,       // Orchestrator-only phase, no team
    // v3.0.0-alpha.6 (Day 5 C4d): verify_mend absorbed into mend_qa post-step.
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

// Orchestrator-only phases (verification, gap_analysis) have no team — plan_refine,
// verify_mend, deploy_verify, pre_ship_validation were absorbed in v3.0.0-alpha.6 (Day 5).
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
| **VERIFICATION** (Phase 2.7) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **WORK** (Phase 5) | Shutdown work team — broadcast cancellation, send shutdown requests to all rune-smith workers |
| **GAP ANALYSIS** (Phase 5.5) | No-op — orchestrator-only, no team to cancel. Skip to Step 4 |
| **CODE REVIEW** (Phase 6) | Delegate to `/rune:cancel-review` logic — broadcast, shutdown Ash, cleanup |
| **MEND** (Phase 7) | Shutdown mend team — broadcast cancellation, send shutdown requests to all mend-fixer workers |
| **TEST** (Phase 7.7) | Shutdown test team (`arc-test-{id}`) — broadcast cancellation, send shutdown requests. Cleanup test state files (`tmp/.rune-test-*.json`) |
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
  // FALLBACK: static worst-case member list for common arc phase agents.
  // Safe to send shutdown_request to absent members — SendMessage is a no-op for unknown names.
  warn("Could not read/parse team config — using static fallback member list")
  allMembers = [
    // Plan review agents
    "scroll-reviewer", "decree-arbiter", "knowledge-keeper", "veil-piercer-plan",
    "evidence-verifier",
    // Inspect/gap analysis agents (base agents — mode-variant files consolidated in v3.0.0-alpha.2)
    "grace-warden", "ruin-prophet", "sight-oracle", "vigil-keeper",
    "verdict-binder", "gap-fixer",
    // Code review agents (delegated to appraise — unlikely here but safe)
    "forge-warden", "ward-sentinel", "pattern-weaver", "veil-piercer",
    "glyph-scribe", "runebinder",
    // Test agents
    ...Array.from({length: 6}, (_, i) => `batch-runner-${i + 1}`),
    // Mend agents
    ...Array.from({length: 8}, (_, i) => `mend-fixer-${i + 1}`),
    // QA verifier (consolidated to single phase-qa-verifier in v3.0.0 Day-2 — replaces 7 specialist verifiers)
    "phase-qa-verifier",
  ]
}

// Step 1: Force-reply — put all teammates in message-processing state (GitHub #31389)
const aliveMembers = []
for (const member of allMembers) {
  try {
    SendMessage({ type: "message", recipient: member, content: "Acknowledge: arc pipeline cancelling" })
    aliveMembers.push(member)
  } catch (e) { /* member already exited */ }
}

// Step 2: Brief pause for tool-call completion
if (aliveMembers.length > 0) { Bash("sleep 2", { run_in_background: true }) }

// Step 3: Send shutdown_request to alive members
for (const member of aliveMembers) {
  try {
    SendMessage({
      type: "shutdown_request",
      recipient: member,
      content: "Arc pipeline cancelled by user"
    })
  } catch (e) { /* member exited between steps */ }
}
```

#### 3c. Grace Period (adaptive)

Let teammates process shutdown_request and deregister before TeamDelete.

```javascript
if (aliveMembers.length > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, aliveMembers.length * 5))}`, { run_in_background: true })
} else {
  Bash("sleep 2", { run_in_background: true })
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
  // TeamDelete with retry-with-backoff (4 attempts: 0s, 3s, 6s, 10s = 19s total)
  const RETRY_DELAYS = [0, 3000, 6000, 10000]
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
      Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
      Bash(`sleep 3`, { run_in_background: true })
      Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -KILL "$pid" 2>/dev/null ;; esac; done`)
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
Write(`.rune/arc/${id}/checkpoint.json`, checkpoint)

// Release workflow lock (arc acquires "arc" lock at preflight)
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "arc"`)
```

### 5. Preserve Completed Artifacts

Do NOT delete any files from completed phases:
- `.rune/arc/{id}/` directory is preserved
- `tmp/` output from completed phases is preserved
- Only the in-progress phase's team resources are cleaned up

### 6. Report

```javascript
// PHASE_LABELS mirrors the live PHASE_ORDER (19 phases as of v3.0.0-alpha.6).
// Removed in alpha.1+: design_*, semantic_verification, task_decomposition, storybook_verification,
// ux_verification, browser_test*, test_coverage_critique, release_quality_check,
// goldmask_verification, goldmask_correlation, bot_review_wait, pr_comment_resolution.
// Absorbed in alpha.6 (Day 5): plan_refine→plan_review, drift_review→work,
// inspect_fix+verify_inspect→inspect, verify_mend→mend_qa post-step,
// deploy_verify removed + pre_ship_validation→ship.
const PHASE_LABELS = {
  forge: '1 (FORGE)', forge_qa: '1.5 (FORGE QA)',
  plan_review: '2 (PLAN REVIEW)', verification: '2.7 (VERIFICATION)',
  work: '5 (WORK)', work_qa: '5.1 (WORK QA)',
  gap_analysis: '5.5 (GAP ANALYSIS)', gap_analysis_qa: '5.6 (GAP ANALYSIS QA)', gap_remediation: '5.8 (GAP REMEDIATION)',
  inspect: '5.9 (INSPECT)',
  code_review: '6 (CODE REVIEW)', code_review_qa: '6.5 (CODE REVIEW QA)',
  verify: '6.7 (VERIFY)',
  mend: '7 (MEND)', mend_qa: '7.3 (MEND QA)',
  test: '7.7 (TEST)', test_qa: '7.8 (TEST QA)',
  ship: '9 (SHIP)', merge: '9.5 (MERGE)'
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
report += `\nArtifacts remain in: .rune/arc/${id}/\nTo resume: /rune:arc --resume`
```

## Notes

- Only the currently-active phase is cancelled — completed phases are untouched
- All team resources (Agent Teams) are fully cleaned up
- Checkpoint file is updated to reflect cancellation, enabling `--resume` later
- Pending and in-progress tasks are deleted to prevent orphaned work
- If the arc has multiple active checkpoints, cancel the most recent one
