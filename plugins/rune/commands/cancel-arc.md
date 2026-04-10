---
name: rune:cancel-arc
description: |
  Cancel an active arc pipeline and gracefully shutdown all phase teammates.
  Completed phase artifacts are preserved. Only the currently-active phase is cancelled.

  Also cancels arc-batch, arc-hierarchy, and arc-issues loop state files owned by this session.

  Use --status to inspect arc pipeline health without cancelling (runs rune-status.sh).
  Use --list-active to list all active arc-related state files without cancelling anything.
  Use --variant=batch|hierarchy|issues to cancel only a specific loop type (thin alias support).

  <example>
  user: "/rune:cancel-arc"
  assistant: "The Tarnished halts the arc..."
  </example>

  <example>
  user: "/rune:cancel-arc --status"
  assistant: "Displays arc pipeline status report without cancelling."
  </example>

  <example>
  user: "/rune:cancel-arc --list-active"
  assistant: "Lists all active arc-related state files owned by this session."
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

Also cancels arc-batch, arc-hierarchy, and arc-issues loop state files owned by this session.

## Flags

| Flag | Description |
|------|-------------|
| `--status` | Display arc pipeline diagnostic status without cancelling. Runs `rune-status.sh` and returns. |
| `--list-active` | List all active arc-related state files without cancelling anything. Early return. |
| `--variant=batch` | Cancel only the arc-batch loop (thin alias — same as `/rune:cancel-arc-batch`). |
| `--variant=hierarchy` | Cancel only the arc-hierarchy loop (thin alias — same as `/rune:cancel-arc-hierarchy`). |
| `--variant=issues` | Cancel only the arc-issues loop (thin alias — same as `/rune:cancel-arc-issues`). |

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

## Step -0.3. Handle --variant Flag (Thin Alias Support, Early Return)

```javascript
const args = "$ARGUMENTS"
const variantMatch = args.match(/--variant=(\w+)/)
const variant = variantMatch ? variantMatch[1].toLowerCase() : null

if (variant === "batch") {
  // Cancel only the arc-batch loop — delete state file (same logic as Step 0 batch section)
  _cancelBatchOnly()
  return
}
if (variant === "hierarchy") {
  // Cancel only the arc-hierarchy loop — mark as cancelled, don't delete
  _cancelHierarchyOnly()
  return
}
if (variant === "issues") {
  // Cancel only the arc-issues loop — delete state file
  _cancelIssuesOnly()
  return
}
```

When `--variant` is set, only the matching loop type is cancelled. The arc pipeline itself is not touched.

**`_cancelHierarchyOnly()` logic:**

```javascript
function _cancelHierarchyOnly() {
  const stateFile = ".rune/arc-hierarchy-loop.local.md"
  const exists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
  if (exists !== "yes") {
    log("No active arc-hierarchy loop found.")
    return
  }
  const content = Read(stateFile)
  const ownerPidMatch = content.match(/owner_pid:\s*(\d+)/)
  const configDirMatch = content.match(/config_dir:\s*(.+)/)
  const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
  const storedCfg = configDirMatch ? configDirMatch[1].trim() : null
  const currentCfg = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let foreignSession = false
  if (storedCfg && storedCfg !== currentCfg) {
    foreignSession = true
  } else if (ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
    const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") foreignSession = true
  }
  if (foreignSession) {
    warn(`Arc-hierarchy loop belongs to another session (PID: ${ownerPid}). Skipping.`)
    return
  }

  // Preserve EXEC_TABLE_JSON — mark cancelled, don't delete
  const cancelled = content
    .replace(/^active:\s*true/m, "active: false")
    .replace(/^---/, `---\ncancelled: true\ncancelled_at: "${new Date().toISOString()}"`)
  Write(stateFile, cancelled)

  const parentPlanMatch = content.match(/parent_plan:\s*(.+)/)
  const parentPlanRaw = parentPlanMatch ? parentPlanMatch[1].trim() : "unknown"
  const parentPlan = /^[a-zA-Z0-9._\/-]+$/.test(parentPlanRaw) ? parentPlanRaw : "unknown"
  log(`Arc hierarchy loop cancelled. Parent plan: ${parentPlan}`)
  log("The current child arc run (if any) will finish normally. No further child plans will be executed.")
  log(`To see what was completed: Read the execution table in ${parentPlan}`)
  log("To also cancel the currently-running child arc: /rune:cancel-arc")
}
```

**`_cancelIssuesOnly()` logic:**

```javascript
function _cancelIssuesOnly() {
  const stateFile = ".rune/arc-issues-loop.local.md"
  const exists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
  if (exists !== "yes") {
    log("No active arc-issues loop found.")
    return
  }
  const content = Read(stateFile)
  const iterMatch = content.match(/iteration:\s*(\d+)/)
  const totalMatch = content.match(/total_plans:\s*(\d+)/)
  const iteration = iterMatch ? iterMatch[1] : "?"
  const totalPlans = totalMatch ? totalMatch[1] : "?"
  const ownerPidMatch = content.match(/owner_pid:\s*(\d+)/)
  const configDirMatch = content.match(/config_dir:\s*(.+)/)
  const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
  const storedCfg = configDirMatch ? configDirMatch[1].trim() : null
  const currentCfg = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let foreignSession = false
  if (storedCfg && storedCfg !== currentCfg) {
    foreignSession = true
  } else if (ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
    const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") foreignSession = true
  }
  if (foreignSession) {
    warn(`Arc-issues loop belongs to another session (PID: ${ownerPid}). Skipping.`)
    return
  }

  Bash("rm -f .rune/arc-issues-loop.local.md")
  log(`Arc issues loop cancelled at iteration ${iteration}/${totalPlans}.`)
  log("The current arc run will finish normally. No further issues will be started.")
  log("To see batch progress: Read tmp/gh-issues/batch-progress.json")
  log("To also cancel the current arc run: /rune:cancel-arc")
}
```

**`_cancelBatchOnly()` logic:**

```javascript
function _cancelBatchOnly() {
  const stateFile = ".rune/arc-batch-loop.local.md"
  const exists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
  if (exists !== "yes") {
    log("No active arc-batch loop found.")
    return
  }
  const content = Read(stateFile)
  const iterMatch = content.match(/iteration:\s*(\d+)/)
  const totalMatch = content.match(/total_plans:\s*(\d+)/)
  const iteration = iterMatch ? iterMatch[1] : "?"
  const total = totalMatch ? totalMatch[1] : "?"
  const ownerPidMatch = content.match(/owner_pid:\s*(\d+)/)
  const configDirMatch = content.match(/config_dir:\s*(.+)/)
  const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
  const storedCfg = configDirMatch ? configDirMatch[1].trim() : null
  const currentCfg = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let foreignSession = false
  if (storedCfg && storedCfg !== currentCfg) {
    foreignSession = true
  } else if (ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
    const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") foreignSession = true
  }
  if (foreignSession) {
    warn(`Arc-batch loop belongs to another session (PID: ${ownerPid}). Skipping.`)
    return
  }

  Bash("rm -f .rune/arc-batch-loop.local.md")
  log(`Arc batch loop cancelled at iteration ${iteration}/${total}.`)
  log("The current arc run will finish normally. No further plans will be started.")
  log("To also cancel the current arc run: /rune:cancel-arc")
}
```

## Steps

### 0. Cancel Arc Loop State Files (Phase → Batch → Hierarchy → Issues, innermost first)

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

#### Cancel Arc-Batch Loop (if active and owned by this session)

```javascript
// Check for active arc-batch loop state file
const batchStateFile = ".rune/arc-batch-loop.local.md"
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
    const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") isOwner = false
  }

  if (isOwner) {
    // Remove state file to stop the batch loop
    Bash('rm -f .rune/arc-batch-loop.local.md')
    log(`Arc-batch loop also cancelled (was at iteration ${iteration}/${total})`)
  } else {
    warn(`Arc-batch loop belongs to another session (PID: ${ownerPid}). Skipping batch cancellation.`)
    warn("Use /rune:cancel-arc-batch from the owning session to cancel it.")
  }
}
```

#### Cancel Arc-Hierarchy Loop (if active and owned by this session)

```javascript
// Check for active arc-hierarchy loop state file
const hierarchyStateFile = ".rune/arc-hierarchy-loop.local.md"
const hierarchyExists = Bash(`test -f "${hierarchyStateFile}" && echo "yes" || echo "no"`).trim()

if (hierarchyExists === "yes") {
  const hierarchyContent = Read(hierarchyStateFile)
  const ownerPidMatch = hierarchyContent.match(/owner_pid:\s*(\d+)/)
  const configDirMatch = hierarchyContent.match(/config_dir:\s*(.+)/)
  const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
  const storedCfg = configDirMatch ? configDirMatch[1].trim() : null
  const currentCfg = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let isOwner = true
  if (storedCfg && storedCfg !== currentCfg) isOwner = false
  if (isOwner && ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
    const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") isOwner = false
  }

  if (isOwner) {
    // Mark cancelled — do NOT delete (EXEC_TABLE_JSON must be preserved for resume)
    const cancelledContent = hierarchyContent
      .replace(/^active:\s*true/m, "active: false")
      .replace(/^---/, `---\ncancelled: true\ncancelled_at: "${new Date().toISOString()}"`)
    Write(hierarchyStateFile, cancelledContent)
    log("Arc-hierarchy loop also cancelled (marked active: false; state file preserved for resume)")
  } else {
    warn(`Arc-hierarchy loop belongs to another session (PID: ${ownerPid}). Skipping.`)
    warn("Use /rune:cancel-arc-hierarchy from the owning session to cancel it.")
  }
}
```

#### Cancel Arc-Issues Loop (if active and owned by this session)

```javascript
// Check for active arc-issues loop state file
const issuesStateFile = ".rune/arc-issues-loop.local.md"
const issuesExists = Bash(`test -f "${issuesStateFile}" && echo "yes" || echo "no"`).trim()

if (issuesExists === "yes") {
  const issuesContent = Read(issuesStateFile)
  const iterMatch = issuesContent.match(/iteration:\s*(\d+)/)
  const totalMatch = issuesContent.match(/total_plans:\s*(\d+)/)
  const issuesIteration = iterMatch ? iterMatch[1] : "?"
  const issuesTotal = totalMatch ? totalMatch[1] : "?"

  const ownerPidMatch = issuesContent.match(/owner_pid:\s*(\d+)/)
  const configDirMatch = issuesContent.match(/config_dir:\s*(.+)/)
  const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
  const storedCfg = configDirMatch ? configDirMatch[1].trim() : null
  const currentCfg = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
  const currentPid = Bash(`echo $PPID`).trim()

  let isOwner = true
  if (storedCfg && storedCfg !== currentCfg) isOwner = false
  if (isOwner && ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
    const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") isOwner = false
  }

  if (isOwner) {
    // Remove state file to stop the issues loop (same as batch — Stop hook checks for file presence)
    Bash("rm -f .rune/arc-issues-loop.local.md")
    log(`Arc-issues loop also cancelled (was at iteration ${issuesIteration}/${issuesTotal})`)
  } else {
    warn(`Arc-issues loop belongs to another session (PID: ${ownerPid}). Skipping.`)
    warn("Use /rune:cancel-arc-issues from the owning session to cancel it.")
  }
}
```

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
  // FALLBACK: static worst-case member list for common arc phase agents.
  // Safe to send shutdown_request to absent members — SendMessage is a no-op for unknown names.
  warn("Could not read/parse team config — using static fallback member list")
  allMembers = [
    // Plan review agents
    "scroll-reviewer", "decree-arbiter", "knowledge-keeper", "veil-piercer-plan",
    "evidence-verifier", "codex-plan-reviewer",
    // Inspect/gap analysis agents
    "grace-warden", "ruin-prophet", "sight-oracle", "vigil-keeper",
    "grace-warden-inspect", "ruin-prophet-inspect", "sight-oracle-inspect", "vigil-keeper-inspect",
    "verdict-binder", "gap-fixer",
    // Code review agents (delegated to appraise — unlikely here but safe)
    "forge-warden", "ward-sentinel", "pattern-weaver", "veil-piercer",
    "glyph-scribe", "knowledge-keeper", "runebinder",
    // Test agents
    ...Array.from({length: 6}, (_, i) => `batch-runner-${i + 1}`),
    // Mend agents
    ...Array.from({length: 8}, (_, i) => `mend-fixer-${i + 1}`),
    // QA verifier (single agent per gate)
    "qa-forge-verifier", "qa-work-verifier", "qa-code_review-verifier",
    "qa-mend-verifier", "qa-test-verifier", "qa-gap_analysis-verifier"
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
report += `\nArtifacts remain in: .rune/arc/${id}/\nTo resume: /rune:arc --resume`
```

## Notes

- Only the currently-active phase is cancelled — completed phases are untouched
- All team resources (Agent Teams) are fully cleaned up
- Checkpoint file is updated to reflect cancellation, enabling `--resume` later
- Pending and in-progress tasks are deleted to prevent orphaned work
- If the arc has multiple active checkpoints, cancel the most recent one
