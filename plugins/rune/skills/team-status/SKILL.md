---
name: team-status
description: |
  Display monitoring dashboard for active agent teams. Shows members,
  task progress, completion percentage, and health indicators.
  Use when you want to check what's running or diagnose stuck workflows.
  Keywords: team status, team dashboard, check progress, team management, monitor.

  <example>
  user: "/rune:team-status"
  assistant: "Scanning for active Rune teams..."
  </example>

  <example>
  user: "/rune:team-status rune-review-abc1234"
  assistant: "Checking status for team rune-review-abc1234..."
  </example>

user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, TaskList, TaskGet
argument-hint: "[team-name]"
---

# /rune:team-status — Team Monitoring Dashboard

Display a live status dashboard for active Rune agent teams, including members, task progress, completion percentage, and health indicators.

## Usage

```
/rune:team-status [team-name]
```

- `team-name`: Optional. Filter to a specific team. If omitted, shows all active teams in the current session.

## Protocol

### Step 1 — Resolve Session Identity

```javascript
const CHOME = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
const filterTeam = $ARGUMENTS[0] || null

// SEC-4: Validate team name if provided
if (filterTeam && !/^[a-zA-Z0-9_-]+$/.test(filterTeam)) {
  error(`Invalid team name "${filterTeam}". Must match [a-zA-Z0-9_-]+.`)
  return
}
```

### Step 2 — Discover Active Teams

Scan for active workflow state files AND SDK handle files. Both legacy inline teams and SDK-managed teams are supported.

```javascript
// Discover legacy state files (tmp/.rune-{workflow}-{id}.json)
const legacyStateFiles = Glob("tmp/.rune-*.json") || []

// Discover SDK handle files (tmp/.rune-handle-*.json) — future
const sdkHandleFiles = Glob("tmp/.rune-handle-*.json") || []

const allStateFiles = [...legacyStateFiles, ...sdkHandleFiles]

if (allStateFiles.length === 0) {
  log("No active Rune teams found.")
  log("Start a workflow with /rune:appraise, /rune:strive, /rune:devise, etc.")
  return
}
```

### Step 3 — Filter and Validate State Files

```javascript
const activeTeams = []

for (const stateFile of allStateFiles) {
  let state
  try {
    state = JSON.parse(Read(stateFile))
  } catch {
    continue  // Skip corrupt state files
  }

  // Session ownership check: config_dir must match
  if (state.config_dir && state.config_dir !== CHOME) {
    continue  // Belongs to another session/config
  }

  // PID liveness check: owner_pid must be alive
  if (state.owner_pid) {
    const pidAlive = Bash(`kill -0 ${state.owner_pid} 2>/dev/null && echo alive || echo dead`).trim()
    if (pidAlive === "dead") {
      // Orphaned state file — report but mark as orphan
      state._orphan = true
    }
  }

  // Filter by team name if specified
  if (filterTeam && state.team_name !== filterTeam) {
    continue
  }

  // Skip completed/cancelled/failed workflows
  if (["completed", "cancelled", "failed"].includes(state.status)) {
    continue
  }

  activeTeams.push({ stateFile, state })
}

if (activeTeams.length === 0) {
  if (filterTeam) {
    log(`No active team found matching "${filterTeam}".`)
  } else {
    log("No active Rune teams in current session.")
  }
  return
}
```

### Step 4 — Gather Team Details

For each active team, read the team config and task list.

```javascript
for (const { stateFile, state } of activeTeams) {
  const teamName = state.team_name

  // SEC-4: Validate team name before path construction
  if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) {
    warn(`Skipping team with invalid name: ${teamName}`)
    continue
  }

  // Read team config (may not exist if team was cleaned up)
  let teamConfig = null
  try {
    teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  } catch {
    // Team config missing — team may have been deleted
  }

  // Read task list
  let tasks = []
  try {
    tasks = TaskList()
  } catch {
    // TaskList may fail if team was deleted
  }

  // Read signal directory for fast progress check
  const signalDir = `tmp/.rune-signals/${teamName}`
  const signalFiles = Glob(`${signalDir}/*.done`) || []

  // Detect workflow type from state file name
  const workflowMatch = stateFile.match(/tmp\/\.rune-(review|work|plan|mend|debug|audit|forge|dispatch|handle)-/)
  const workflowType = workflowMatch ? workflowMatch[1] : "unknown"

  // Compute duration
  const startedAt = state.started || state.started_at
  const durationMs = startedAt ? Date.now() - new Date(startedAt).getTime() : 0
  const durationMin = Math.round(durationMs / 60_000)

  // Compute task progress
  const completedTasks = tasks.filter(t => t.status === "completed")
  const inProgressTasks = tasks.filter(t => t.status === "in_progress")
  const pendingTasks = tasks.filter(t => t.status === "pending")
  const totalTasks = tasks.length || state.expected_task_count || state.expected_workers || 0
  const completedCount = completedTasks.length
  const progressPercent = totalTasks > 0 ? Math.round((completedCount / totalTasks) * 100) : 0

  // Health indicators
  const staleThresholdMs = 5 * 60 * 1000  // 5 min default staleWarnMs
  const staleTasks = inProgressTasks.filter(t => {
    // Estimate stale from task metadata or duration
    return durationMs > staleThresholdMs && inProgressTasks.length > 0
  })

  // Members from team config
  const members = teamConfig?.members
    ? teamConfig.members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
    : []

  // Render dashboard for this team
  renderTeamDashboard({
    teamName, workflowType, state, startedAt, durationMin,
    members, tasks, completedCount, totalTasks, progressPercent,
    inProgressTasks, pendingTasks, signalFiles, staleTasks
  })
}
```

### Step 5 — Render Dashboard

```
function renderTeamDashboard(info) {
  const {
    teamName, workflowType, state, startedAt, durationMin,
    members, completedCount, totalTasks, progressPercent,
    inProgressTasks, pendingTasks, signalFiles, staleTasks
  } = info

  // Build progress bar (20 chars wide)
  const filled = Math.round(progressPercent / 5)
  const empty = 20 - filled
  const bar = "█".repeat(filled) + "░".repeat(empty)

  // Health status
  let healthLabel = "healthy"
  if (state._orphan) healthLabel = "ORPHAN (owner PID dead)"
  else if (staleTasks.length > 0) healthLabel = `WARNING (${staleTasks.length} stale)`
  else if (durationMin > 30 && progressPercent < 50) healthLabel = "SLOW"

  log(`
/rune:team-status
═══════════════════════════════════════════════
Team:       ${teamName}
Workflow:   ${workflowType}
Started:    ${startedAt || "unknown"}
Duration:   ${durationMin} min
Health:     ${healthLabel}

Progress:   ${completedCount}/${totalTasks} tasks
            [${bar}] ${progressPercent}%

Members:    ${members.length > 0 ? members.join(", ") : "(unavailable)"}
───────────────────────────────────────────────
In progress (${inProgressTasks.length}):
${inProgressTasks.map(t => `  - #${t.id} ${t.subject} (${t.owner || "unassigned"})`).join("\n") || "  (none)"}

Pending (${pendingTasks.length}):
${pendingTasks.map(t => `  - #${t.id} ${t.subject}`).join("\n") || "  (none)"}

Signals:    ${signalFiles.length} done files
═══════════════════════════════════════════════
`)
}
```

### Step 6 — Orphan Advisory

If any teams have dead owner PIDs, advise on cleanup:

```javascript
const orphanTeams = activeTeams.filter(t => t.state._orphan)
if (orphanTeams.length > 0) {
  warn(`Found ${orphanTeams.length} orphaned team(s) with dead owner PIDs.`)
  warn("These teams belong to a crashed or exited session.")
  warn("Run /rune:rest to clean up, or manually remove state files from tmp/.")
}
```

## State File Patterns

The command discovers teams via two file patterns:

| Pattern | Source | Description |
|---------|--------|-------------|
| `tmp/.rune-review-{id}.json` | appraise | Code review team |
| `tmp/.rune-audit-{id}.json` | audit | Full codebase audit team |
| `tmp/.rune-work-{id}.json` | strive | Work execution team |
| `tmp/.rune-plan-{id}.json` | devise | Planning/research team |
| `tmp/.rune-mend-{id}.json` | mend | Finding resolution team |
| `tmp/.rune-debug-{id}.json` | debug | Hypothesis investigation team |
| `tmp/.rune-forge-{id}.json` | forge | Enrichment team |
| `tmp/.rune-dispatch-{id}.json` | strive --background | Background dispatch |
| `tmp/.rune-handle-{id}.json` | team-sdk (future) | SDK-managed team handle |

## Security Requirements

- **SEC-4**: Validate all team names against `/^[a-zA-Z0-9_-]+$/` before path construction
- **Path traversal guard**: Never construct paths with unvalidated user input
- **Session isolation**: Filter state files by `config_dir` and `owner_pid` liveness
- **CHOME pattern**: Use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` for config resolution

## Cross-References

- [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) — Polling and monitoring patterns
- [monitoring.md](../team-sdk/references/monitoring.md) — SDK monitoring utilities
- [presets.md](../team-sdk/references/presets.md) — Team preset definitions
