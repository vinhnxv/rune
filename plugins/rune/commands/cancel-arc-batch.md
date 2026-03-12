---
name: rune:cancel-arc-batch
description: |
  Cancel an active arc batch loop. Removes the state file so the Stop hook
  allows the session to end after the current arc completes.

  <example>
  user: "/rune:cancel-arc-batch"
  assistant: "Arc batch loop cancelled at iteration 2/4."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
---

# /rune:cancel-arc-batch — Cancel Active Arc Batch Loop

Removes the batch loop state file (`.claude/arc-batch-loop.local.md`), stopping the Stop hook from re-injecting the next arc prompt. The currently-running arc will finish normally, but no further plans will be started.

## Steps

### 1. Check for Active Batch Loop

```javascript
const stateFile = ".claude/arc-batch-loop.local.md"
const exists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
```

If `"no"`: Report "No active arc batch loop found." and exit.

### 2. Read Current State and Check Ownership

```javascript
const content = Read(stateFile)
// Parse YAML frontmatter for iteration, total_plans, and ownership
const iterationMatch = content.match(/iteration:\s*(\d+)/)
const totalMatch = content.match(/total_plans:\s*(\d+)/)
const iteration = iterationMatch ? iterationMatch[1] : "?"
const totalPlans = totalMatch ? totalMatch[1] : "?"

// Check if this batch belongs to another session
const ownerPidMatch = content.match(/owner_pid:\s*(\d+)/)
const configDirMatch = content.match(/config_dir:\s*(.+)/)
const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null
const storedConfigDir = configDirMatch ? configDirMatch[1].trim() : null
const currentConfigDir = Bash(`cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const currentPid = Bash(`echo $PPID`).trim()

let foreignSession = false
if (storedConfigDir && storedConfigDir !== currentConfigDir) {
  foreignSession = true
} else if (ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
  const alive = Bash(`kill -0 ${ownerPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
  if (alive === "alive") {
    foreignSession = true
  }
}

if (foreignSession) {
  warn("WARNING: This batch was started by another session.")
  warn(`  Owner PID: ${ownerPid || "unknown"}, Config dir: ${storedConfigDir || "unknown"}`)
  // Still allow cancellation — user might intentionally want to cancel from another terminal
}
```

### 2.5. Mark In-Progress Plan as Cancelled

Without this step, the currently-running plan stays `in_progress` in the progress file forever — the Stop hook won't fire (state file removed), and `--resume` only picks up `pending` plans.

```javascript
const progressFile = "tmp/arc-batch/batch-progress.json"
if (Bash(`test -f "${progressFile}" && echo "yes" || echo "no"`).trim() === "yes") {
  try {
    const progress = JSON.parse(Read(progressFile))
    const inProgressPlan = progress.plans.find(p => p.status === "in_progress")
    if (inProgressPlan) {
      inProgressPlan.status = "cancelled"
      inProgressPlan.cancelled_at = new Date().toISOString()
      progress.updated_at = new Date().toISOString()
      Write(progressFile, JSON.stringify(progress, null, 2))
    }
  } catch (e) {
    // Progress file unreadable — proceed with state file removal anyway
  }
}
```

### 3. Remove State File

```javascript
Bash('rm -f .claude/arc-batch-loop.local.md')
```

### 4. Report

```
Arc batch loop cancelled at iteration {iteration}/{totalPlans}.

The current arc run will finish normally.
No further plans will be started.

To see batch progress: Read tmp/arc-batch/batch-progress.json
To resume later: /rune:arc-batch --resume
```

### 5. Delegate to Cancel-Arc (Optional)

If the user also wants to cancel the currently-running arc:

```
To also cancel the current arc run: /rune:cancel-arc
```
