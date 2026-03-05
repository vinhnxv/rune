---
name: rune:team-delegate
description: |
  Task delegation dashboard for managing team workload, assignments, and messaging.
  Works with standalone teams from /rune:team-spawn and workflow-spawned teams.

  <example>
  user: "/rune:team-delegate"
  assistant: "Delegation Dashboard: 2 unassigned tasks, 1 idle member..."
  </example>

  <example>
  user: "/rune:team-delegate --assign 3=ward-sentinel"
  assistant: "Task #3 assigned to ward-sentinel."
  </example>

  <example>
  user: "/rune:team-delegate --message ward-sentinel 'Focus on auth module security'"
  assistant: "Message sent to ward-sentinel."
  </example>
user-invocable: true
disable-model-invocation: true
argument-hint: "[--assign id=member] [--message member 'text'] [--create 'subject']"
allowed-tools:
  - TaskCreate
  - TaskList
  - TaskUpdate
  - TaskGet
  - SendMessage
  - Read
  - Bash
  - Glob
  - AskUserQuestion
---

# /rune:team-delegate -- Task Delegation Dashboard

Manage team workload, assign tasks, send messages to teammates, and create new tasks. Shows a delegation dashboard by default.

## Usage

```
/rune:team-delegate                             # Show delegation dashboard
/rune:team-delegate --assign 3=ward-sentinel    # Assign task #3 to ward-sentinel
/rune:team-delegate --message ward-sentinel 'Focus on auth module'
/rune:team-delegate --create 'Review auth module security'
```

## Steps

### Step 1: Parse Arguments

```javascript
const args = "$ARGUMENTS"
const assignMatch = args.match(/--assign\s+(\d+)=(\S+)/)
const messageMatch = args.match(/--message\s+(\S+)\s+'([^']+)'/)
const createMatch = args.match(/--create\s+'([^']+)'/)
```

### Step 2: Discover Active Team (Session-Owned)

```javascript
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// Discover state files -- filter by session ownership (CDX-SEM-005)
const stateFiles = Glob("tmp/.rune-*.json") || []
const activeStates = stateFiles
  .map(f => { try { return { path: f, state: JSON.parse(Read(f)) } } catch { return null } })
  .filter(Boolean)
  .filter(s => s.state.status === "active")
  .filter(s => {
    // Session ownership: MUST match current session (CDX-SEM-005)
    if (s.state.config_dir && s.state.config_dir !== configDir) return false
    if (s.state.owner_pid && /^\d+$/.test(s.state.owner_pid) && s.state.owner_pid !== ownerPid) {
      const alive = Bash(`kill -0 ${s.state.owner_pid} 2>/dev/null && echo alive`).trim()
      if (alive === "alive") return false  // Another live session owns this
    }
    return true
  })
  .sort((a, b) => new Date(b.state.started) - new Date(a.state.started))

if (activeStates.length === 0) {
  error("No active team found in current session.")
  log("Spawn a team first with /rune:team-spawn")
  return
}

let target
if (activeStates.length === 1) {
  target = activeStates[0]
} else {
  const choice = AskUserQuestion({
    questions: [{
      question: "Multiple active teams. Which to manage?",
      header: "Team",
      options: activeStates.map(s => ({
        label: s.state.team_name,
        description: `Preset: ${s.state.preset || s.state.workflow || "unknown"}, Started: ${s.state.started}`
      })),
      multiSelect: false
    }]
  })
  target = activeStates.find(s => choice.includes(s.state.team_name)) || activeStates[0]
}

const team_name = target.state.team_name

// SEC-4: validate team name
if (!team_name || !/^[a-zA-Z0-9_-]+$/.test(team_name)) {
  error("Invalid or missing team name.")
  return
}
```

### Step 3: Action -- Assign Task

```javascript
if (assignMatch) {
  const taskId = assignMatch[1]
  const memberName = assignMatch[2]

  // Validate taskId (CDX-SEM-006: numeric only)
  if (!/^\d+$/.test(taskId)) {
    error("Invalid task ID. Must be a number.")
    return
  }

  // SEC-4: validate member name
  if (!/^[a-zA-Z0-9_-]+$/.test(memberName)) {
    error("Invalid member name. Must match [a-zA-Z0-9_-]+.")
    return
  }

  // Verify task exists before assigning
  try {
    const task = TaskGet({ taskId })
    if (!task) {
      error(`Task #${taskId} not found.`)
      return
    }
  } catch (e) {
    error(`Task #${taskId} not found.`)
    return
  }

  // Verify member exists in team
  let teamMembers = []
  try {
    const teamConfig = JSON.parse(Read(`${CHOME}/teams/${team_name}/config.json`))
    teamMembers = (teamConfig.members || []).map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
  } catch (e) { /* proceed anyway -- member may still be valid */ }

  if (teamMembers.length > 0 && !teamMembers.includes(memberName)) {
    warn(`"${memberName}" not found in team config. Available: ${teamMembers.join(", ")}`)
    // Proceed anyway -- team config may be stale
  }

  TaskUpdate({ taskId, owner: memberName, status: "in_progress" })
  SendMessage({
    type: "message",
    recipient: memberName,
    content: `You've been assigned task #${taskId}. Please begin work.`
  })
  return `Task #${taskId} assigned to ${memberName}.`
}
```

### Step 4: Action -- Send Message

```javascript
if (messageMatch) {
  const memberName = messageMatch[1]
  const content = messageMatch[2]

  // SEC-4: validate member name
  if (!/^[a-zA-Z0-9_-]+$/.test(memberName)) {
    error("Invalid member name. Must match [a-zA-Z0-9_-]+.")
    return
  }

  SendMessage({
    type: "message",
    recipient: memberName,
    content: content
  })
  return `Message sent to ${memberName}.`
}
```

### Step 5: Action -- Create Task

```javascript
if (createMatch) {
  const subject = createMatch[1]

  TaskCreate({
    subject: subject,
    description: subject,
    activeForm: "Waiting for assignment"
  })
  return `Task created: "${subject}". Use --assign to assign it to a teammate.`
}
```

### Step 6: Default -- Delegation Dashboard

```javascript
const tasks = TaskList() || []

// Read team members
let members = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${team_name}/config.json`))
  members = (teamConfig.members || []).map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  warn("Could not read team config for member list.")
}

// Categorize tasks
const unassigned = tasks.filter(t => !t.owner && t.status === "pending")
const inProgress = tasks.filter(t => t.status === "in_progress")
const completed = tasks.filter(t => t.status === "completed")
const pending = tasks.filter(t => t.status === "pending")

// Compute member workloads
const memberWorkloads = members.map(name => {
  const memberTasks = tasks.filter(t => t.owner === name)
  const memberInProgress = memberTasks.filter(t => t.status === "in_progress")
  const memberPending = memberTasks.filter(t => t.status === "pending")
  const memberCompleted = memberTasks.filter(t => t.status === "completed")
  const isIdle = memberInProgress.length === 0 && memberPending.length === 0
  return { name, total: memberTasks.length, inProgress: memberInProgress.length, pending: memberPending.length, completed: memberCompleted.length, isIdle }
})

const idleMembers = memberWorkloads.filter(m => m.isIdle)

// Suggestions
const suggestions = []
if (unassigned.length > 0 && idleMembers.length > 0) {
  for (let i = 0; i < Math.min(unassigned.length, idleMembers.length); i++) {
    suggestions.push(`Assign #${unassigned[i].id} to ${idleMembers[i].name} (idle)`)
  }
} else if (unassigned.length > 0) {
  const lowestWorkload = memberWorkloads.sort((a, b) => a.total - b.total)[0]
  if (lowestWorkload) {
    suggestions.push(`Assign #${unassigned[0].id} to ${lowestWorkload.name} (lowest workload)`)
  }
}

// Render dashboard
log(`
/rune:team-delegate
Delegation Dashboard: ${team_name}
===================================================

Progress: ${completed.length}/${tasks.length} tasks completed

Unassigned Tasks (${unassigned.length}):
${unassigned.map(t => `  #${t.id}  ${t.subject}`).join("\n") || "  (none)"}

Member Workloads:
${memberWorkloads.map(m =>
  `  ${m.name.padEnd(22)} ${m.total} task${m.total !== 1 ? "s" : ""}` +
  ` (${m.inProgress} active, ${m.pending} pending, ${m.completed} done)` +
  (m.isIdle ? "  ** IDLE **" : "")
).join("\n") || "  (no members found)"}

${suggestions.length > 0 ? `Suggestions:\n${suggestions.map(s => `  - ${s}`).join("\n")}` : ""}

Actions:
  /rune:team-delegate --assign <id>=<member>
  /rune:team-delegate --message <member> '<text>'
  /rune:team-delegate --create '<task subject>'
===================================================
`)
```

## Security Requirements

- **CDX-SEM-005**: Session ownership filter -- only discovers teams owned by current session
- **CDX-SEM-006**: Task IDs validated with `/^\d+$/` before TaskUpdate
- **SEC-4**: Member names validated against `/^[a-zA-Z0-9_-]+$/`
- **CHOME pattern**: Uses `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` for config resolution
- **Task existence check**: TaskGet validates taskId exists before TaskUpdate

## Notes

- Dashboard is the default action (no flags)
- All actions require an active team in the current session
- Cross-session delegation is blocked by design (CDX-SEM-005)
- Member verification uses team config but proceeds even if config is stale
- Suggestions are computed from workload analysis (idle members prioritized)
