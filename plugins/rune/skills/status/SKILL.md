---
name: status
description: |
  Display monitoring dashboard for active Rune agent teams and any
  background-dispatched workers. Shows team members, task progress,
  completion percentage, health indicators, pending questions, and
  dispatch state. Use when checking what's running, diagnosing stuck
  workflows, or auditing dispatch progress.
  Keywords: status, team status, dashboard, check progress, monitor,
  team management, dispatch, background workers.
user-invocable: true
allowed-tools: Read, Glob, Grep, Bash, TaskList, TaskGet
argument-hint: "[timestamp | team-name]"
---

# /rune:status — Rune Status Dashboard

Display a live status dashboard for active Rune agent teams (review, audit, work, plan, mend, debug, forge, dispatch) plus detailed reporting for any background-dispatched workers.

## Usage

```
/rune:status                 # Show all active teams + dispatch summaries in this session
/rune:status <team-name>     # Filter to a specific team
/rune:status <timestamp>     # Show detailed background-dispatch report
```

- `team-name`: Optional. Filter to a specific team (e.g., `rune-review-1234`). Matches `state.team_name`.
- `timestamp`: Optional. Dispatch timestamp from `/rune:strive --background` (e.g., `20260226-014500`). Triggers the detailed dispatch report with pending-question detection.

## Protocol

### Step 1 — Resolve Session Identity and Argument

```javascript
const CHOME = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
const arg = $ARGUMENTS[0] || null

// Classify argument: timestamp vs team-name
let dispatchTimestamp = null
let filterTeam = null
if (arg) {
  if (/^\d{8}-\d{6}$/.test(arg)) {
    dispatchTimestamp = arg  // YYYYMMDD-HHMMSS shape → dispatch mode
  } else if (/^[a-zA-Z0-9_-]+$/.test(arg)) {
    filterTeam = arg         // SEC-4-validated name → team filter
  } else {
    error(`Invalid argument "${arg}". Expected timestamp (YYYYMMDD-HHMMSS) or team name ([a-zA-Z0-9_-]+).`)
    return
  }
}
```

### Step 2 — Discover Active Teams

Scan for active workflow state files. Both legacy inline teams and SDK-managed teams are supported.

```javascript
const legacyStateFiles = Glob("tmp/.rune-*.json") || []
const sdkHandleFiles = Glob("tmp/.rune-handle-*.json") || []
const allStateFiles = [...legacyStateFiles, ...sdkHandleFiles]

if (allStateFiles.length === 0 && !dispatchTimestamp) {
  log("No active Rune teams found in this session.")
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
    continue
  }

  // PID liveness check: owner_pid must be alive
  if (state.owner_pid) {
    const pidAlive = Bash(`kill -0 ${state.owner_pid} 2>/dev/null && echo alive || echo dead`).trim()
    if (pidAlive === "dead") {
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

if (activeTeams.length === 0 && !dispatchTimestamp) {
  if (filterTeam) {
    log(`No active team found matching "${filterTeam}".`)
  } else {
    log("No active Rune teams in current session.")
  }
  return
}
```

### Step 4 — Render Team Dashboards

For each active team, read team config and tasks, then render the dashboard.

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
  try { tasks = TaskList() } catch {}

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
  const staleTasks = inProgressTasks.filter(t => durationMs > staleThresholdMs && inProgressTasks.length > 0)

  // Members from team config
  const members = teamConfig?.members
    ? teamConfig.members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
    : []

  renderTeamDashboard({
    teamName, workflowType, state, startedAt, durationMin,
    members, completedCount, totalTasks, progressPercent,
    inProgressTasks, pendingTasks, signalFiles, staleTasks
  })
}
```

```javascript
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
/rune:status — Team: ${teamName}
═══════════════════════════════════════════════
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

### Step 5 — Orphan Advisory

If any teams have dead owner PIDs, advise on cleanup:

```javascript
const orphanTeams = activeTeams.filter(t => t.state._orphan)
if (orphanTeams.length > 0) {
  warn(`Found ${orphanTeams.length} orphaned team(s) with dead owner PIDs.`)
  warn("These teams belong to a crashed or exited session.")
  warn("Run /rune:rest to clean up, or manually remove state files from tmp/.")
}
```

### Step 6 — Detailed Background-Dispatch Report (Optional)

Runs only when `dispatchTimestamp` is set (user passed a `YYYYMMDD-HHMMSS` arg). Resolves the dispatch state file, scans the signal directory for live progress, detects pending questions written by background workers, and reports stale workers.

```javascript
if (!dispatchTimestamp) return

// SEC-004: Validate already performed in Step 1
const stateFile = `tmp/.rune-dispatch-${dispatchTimestamp}.json`
const stateRaw = Read(stateFile)
if (!stateRaw) {
  log(`Dispatch state file not found: ${stateFile}`)
  log("The dispatch may have completed. Run /rune:strive --collect to gather results.")
  return
}

let state
try { state = JSON.parse(stateRaw) }
catch (e) { error(`Dispatch state file is corrupt: ${stateFile}`); return }

// SEC-009: Validate state.timestamp before any path construction
if (state.timestamp && !/^\d{8}-\d{6}$/.test(state.timestamp)) {
  error(`Invalid timestamp format in state file: ${state.timestamp}`)
  return
}

if (state.config_dir && state.config_dir !== CHOME) {
  warn(`Dispatch belongs to a different config dir (${state.config_dir}). Showing read-only status.`)
}

// Stale dispatch detection (>2h)
const dispatchAge = Date.now() - new Date(state.started_at).getTime()
const TWO_HOURS_MS = 2 * 60 * 60 * 1000
if (dispatchAge > TWO_HOURS_MS) {
  warn(`Dispatch started ${Math.round(dispatchAge / 3600000 * 10) / 10}h ago — may be stale.`)
  warn(`Consider running /rune:strive --collect ${state.timestamp} to gather partial results.`)
}

// Signal directory for live progress (PERF-002)
const signalDir = `tmp/.rune-signals/${state.team_name}/`
const signalFiles = Glob(`${signalDir}*.done`) || []
const completedFromSignals = signalFiles.length

// Pending questions (workers cannot use AskUserQuestion in background mode)
const questionFiles = Glob(`tmp/work/${state.timestamp}/questions/*.question`) || []
const unansweredQuestions = questionFiles.filter(f => {
  const answerFile = f.replace('.question', '.answer')
  return !fileExists(answerFile)
})

// Stale worker detection (PERF-003)
const workerLogs = Glob(`tmp/work/${state.timestamp}/worker-logs/*.md`) || []
const staleWorkers = []
const WORKER_STALE_MS = 15 * 60 * 1000

for (const logFile of workerLogs) {
  const mtime = parseInt(Bash(`stat -f "%m" "${logFile}" 2>/dev/null || stat -c "%Y" "${logFile}" 2>/dev/null`).trim(), 10) * 1000
  if (Date.now() - mtime > WORKER_STALE_MS) {
    const rawName = logFile.split('/').pop().replace('.md', '')
    const safeName = rawName.replace(/[^a-zA-Z0-9_-]/g, '_')  // SEC-003
    staleWorkers.push(safeName)
  }
}

if (staleWorkers.length > 0) {
  warn(`Stale workers detected (no activity >15min): ${staleWorkers.join(', ')}`)
}

log(`
/rune:status — Dispatch: ${state.timestamp}
═══════════════════════════════════════════════
Team:       ${state.team_name}
Started:    ${state.started_at}
Plan:       ${state.plan_path}

Progress:   ${completedFromSignals}/${state.expected_task_count} tasks complete
            [████████░░░░░░░░] ${Math.round(completedFromSignals/state.expected_task_count*100)}%

Workers:    ${state.worker_count} spawned, ${staleWorkers.length} stale
───────────────────────────────────────────────
Pending questions: ${unansweredQuestions.length}
${unansweredQuestions.map(f => `  ? ${Read(f).trim()}`).join('\n') || '  (none)'}
───────────────────────────────────────────────
${dispatchAge > TWO_HOURS_MS ? '⚠ WARNING: Dispatch is >2h old — may be stale' : 'Status: active'}
═══════════════════════════════════════════════
`)
```

### Answering Pending Questions

When pending questions are detected in dispatch mode, answer them by writing `.answer` files:

```bash
# Write answer to a pending question
echo "Use the existing auth module" > tmp/work/{timestamp}/questions/{task-id}.answer
```

Or use `/rune:strive --collect {timestamp}` once the dispatch is complete to gather results.

## State File Patterns

The command discovers teams via these state-file patterns:

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
- **SEC-003**: Sanitize worker names from filenames before display (`[^a-zA-Z0-9_-]/g, '_'`)
- **SEC-004**: Validate timestamp format (`\d{8}-\d{6}`) before path construction
- **SEC-005**: Dispatch signal directory created with `mkdir -m 700` — owner-only access
- **SEC-006**: Question cap — workers may ask at most 3 questions per task before auto-resolving
- **SEC-009**: Validate `state.timestamp` from state-file content before path construction
- **Path traversal guard**: Never construct paths with unvalidated user input
- **Session isolation**: Filter state files by `config_dir` and `owner_pid` liveness
- **CHOME pattern**: Use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` for config resolution (see plugin CLAUDE.md Core Rule #17)

## Cross-References

- [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) — Polling and monitoring patterns
- [monitoring.md](../team-sdk/references/monitoring.md) — SDK monitoring utilities
- [presets.md](../team-sdk/references/presets.md) — Team preset definitions
- [background-dispatch.md](../strive/references/background-dispatch.md) — Full background dispatch documentation
