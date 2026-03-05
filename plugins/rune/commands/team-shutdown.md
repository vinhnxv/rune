---
name: rune:team-shutdown
description: |
  Gracefully shut down an active agent team and clean up resources.
  Wraps team-sdk TeamEngine.shutdown() and cleanup().
  For standalone teams spawned via /rune:team-spawn. Workflow teams should use their
  respective /rune:cancel-* commands instead.

  <example>
  user: "/rune:team-shutdown"
  assistant: "Shutting down team rune-custom-1772612283000..."
  </example>

  <example>
  user: "/rune:team-shutdown --force"
  assistant: "Force shutdown -- skipping grace period..."
  </example>
user-invocable: true
disable-model-invocation: true
argument-hint: "[--force]"
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
  - AskUserQuestion
---

# /rune:team-shutdown -- Graceful Team Shutdown

Gracefully shut down an active agent team and clean up resources. For standalone teams only -- workflow teams should use their respective `/rune:cancel-*` commands.

## Usage

```
/rune:team-shutdown           # Shutdown with grace period
/rune:team-shutdown --force   # Skip grace period (in-progress work may be lost)
```

## Steps

### Step 1: Parse Arguments

```javascript
const args = "$ARGUMENTS"
// Word-boundary match for --force flag (not .includes)
const forceFlag = /\b--force\b/.test(args)
```

### Step 2: Discover Active Team

```javascript
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// Discover state files
const stateFiles = Glob("tmp/.rune-*.json") || []
const activeStates = stateFiles
  .map(f => { try { return { path: f, state: JSON.parse(Read(f)) } } catch { return null } })
  .filter(Boolean)
  .filter(s => s.state.status === "active")
  .map(s => {
    // Session ownership detection
    const isForeign = (s.state.config_dir && s.state.config_dir !== configDir) ||
      (s.state.owner_pid && /^\d+$/.test(s.state.owner_pid) && s.state.owner_pid !== ownerPid &&
       Bash(`kill -0 ${s.state.owner_pid} 2>/dev/null && echo alive`).trim() === "alive")

    // Detect workflow type from state file name
    const workflowMatch = s.path.match(/tmp\/\.rune-(review|audit|work|plan|mend|debug|forge|dispatch|handle)-/)
    const workflowType = workflowMatch ? workflowMatch[1] : null

    return { ...s, isForeign, workflowType }
  })
  .sort((a, b) => new Date(b.state.started) - new Date(a.state.started))

if (activeStates.length === 0) {
  log("No active team to shutdown.")
  return
}
```

### Step 3: Select Team and Validate

```javascript
let target

if (activeStates.length === 1) {
  target = activeStates[0]
} else {
  // Multiple active -- ask user which to shutdown
  const choice = AskUserQuestion({
    questions: [{
      question: "Multiple active teams found. Which to shutdown?",
      header: "Team",
      options: activeStates.map(s => ({
        label: s.state.team_name + (s.isForeign ? " (other session)" : "") + (s.workflowType ? ` [${s.workflowType}]` : ""),
        description: `Started: ${s.state.started}, Preset: ${s.state.preset || s.workflowType || "unknown"}`
      })),
      multiSelect: false
    }]
  })
  target = activeStates.find(s => choice.includes(s.state.team_name)) || activeStates[0]
}

const team_name = target.state.team_name
const stateFilePath = target.path

// SEC-4: validate team name
if (!team_name || !/^[a-zA-Z0-9_-]+$/.test(team_name)) {
  error("Invalid or missing team name -- cannot shutdown.")
  return
}

// Refuse workflow-spawned teams -- direct to appropriate cancel command
if (target.workflowType && target.state.workflow !== "standalone") {
  const cancelCommands = {
    review: "/rune:cancel-review",
    audit: "/rune:cancel-audit",
    work: "/rune:cancel-review (or wait for strive to complete)",
    plan: "(wait for devise to complete)",
    mend: "(wait for mend to complete)",
    debug: "(wait for debug to complete)",
    forge: "(wait for forge to complete)",
    dispatch: "/rune:status (to check dispatch progress)"
  }
  const suggestion = cancelCommands[target.workflowType] || "/rune:cancel-*"
  error(`Team "${team_name}" was spawned by the ${target.workflowType} workflow.`)
  log(`Use ${suggestion} to cancel workflow teams.`)
  log("/rune:team-shutdown is for standalone teams created via /rune:team-spawn.")
  return
}

// Foreign session warning (warn, don't block)
if (target.isForeign) {
  warn(`WARNING: This team (${team_name}) appears to belong to another active session (PID: ${target.state.owner_pid}). Cancelling may disrupt that session's workflow. Proceeding anyway.`)
}
```

### Step 4: Pre-Shutdown Check

```javascript
const tasks = TaskList() || []
const inProgress = tasks.filter(t => t.status === "in_progress")

if (inProgress.length > 0 && !forceFlag) {
  const choice = AskUserQuestion({
    questions: [{
      question: `${inProgress.length} task(s) still in progress. Proceed with shutdown?`,
      header: "Warning",
      options: [
        { label: "Proceed", description: "Send shutdown request -- agents will finish current work" },
        { label: "Force shutdown", description: "Skip grace period -- in-progress work may be lost" },
        { label: "Cancel", description: "Keep team running" }
      ],
      multiSelect: false
    }]
  })
  // If "Cancel": return
  // If "Force shutdown": skip grace period below
}
```

### Step 5: Shutdown (5-Component Protocol)

```javascript
// ── 1. Dynamic member discovery ──
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${team_name}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  warn("Could not read team config -- attempting TeamDelete directly")
}

// ── 2. Send shutdown_request to all members ──
for (const member of allMembers) {
  SendMessage({
    type: "shutdown_request",
    recipient: member,
    content: "Team shutdown requested by user via /rune:team-shutdown"
  })
}

// ── 3. Grace period (skip if --force) ──
if (allMembers.length > 0 && !forceFlag) {
  Bash(`sleep 15`)
}

// ── 4. TeamDelete with retry-with-backoff (3 attempts: 0s, 5s, 10s) ──
// SEC-4: team_name already validated above
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) {
    warn(`TeamDelete attempt ${attempt + 1} -- retrying in ${CLEANUP_DELAYS[attempt] / 1000}s...`)
    Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  }
  try {
    TeamDelete()
    cleanupTeamDeleteSucceeded = true
    break
  } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) {
      warn(`TeamDelete failed after ${CLEANUP_DELAYS.length} attempts. Using filesystem fallback.`)
    }
  }
}

// ── 5. Filesystem fallback (only if TeamDelete never succeeded -- QUAL-012) ──
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${team_name}/" "$CHOME/tasks/${team_name}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort -- clear SDK leadership state */ }
}
```

### Step 6: Post-Shutdown Cleanup

```javascript
// Update state file to completed
if (stateFilePath) {
  try {
    const state = JSON.parse(Read(stateFilePath))
    Write(stateFilePath, JSON.stringify({
      ...state,
      status: "completed",
      completed_at: new Date().toISOString()
    }))
  } catch (e) { /* non-blocking */ }
}

// Clean signal directory
Bash(`rm -rf "tmp/.rune-signals/${team_name}" 2>/dev/null`)
```

### Step 7: Report

```
Team "${team_name}" shutdown complete.

Members shut down: ${allMembers.length}
Tasks completed: ${tasks.filter(t => t.status === "completed").length}/${tasks.length}

Any partial results remain in tmp/ for inspection.
```

## Security Requirements

- **SEC-4**: Team/member names validated against `/^[a-zA-Z0-9_-]+$/`
- **Session isolation**: Ownership check via `config_dir` + `owner_pid` (with `kill -0` liveness)
- **CHOME pattern**: Uses `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` for config resolution
- **QUAL-012**: Filesystem fallback gated on `!cleanupTeamDeleteSucceeded`
- **Workflow guard**: Refuses to shutdown workflow-spawned teams (directs to `/rune:cancel-*`)
- **`--force` parsing**: Word-boundary regex match (`/\b--force\b/`), not `.includes()`

## Notes

- Only shuts down standalone teams (workflow: "standalone")
- Workflow teams (review, work, plan, etc.) are refused with guidance to the correct cancel command
- Foreign session teams trigger a warning but are not blocked
- State file updated to "completed" (not "cancelled" -- this is a graceful shutdown, not an abort)
