---
name: rune:cancel-arc-hierarchy
description: |
  Cancel an active arc-hierarchy execution loop. Reads the session state file,
  verifies ownership, and marks the loop as cancelled so the next child arc
  invocation does not proceed.

  <example>
  user: "/rune:cancel-arc-hierarchy"
  assistant: "Arc hierarchy loop cancelled. Currently executing child [03] will finish normally."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
---

# /rune:cancel-arc-hierarchy — Cancel Active Arc Hierarchy Loop

Stops the `arc-hierarchy` orchestration loop by marking the state file as cancelled. The currently-executing child arc (if any) will finish normally, but no further children will be started.

## Steps

### 1. Check for Active State File

```javascript
const stateFile = ".claude/arc-hierarchy-loop.local.md"
const exists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
```

If `"no"`: Report "No active arc-hierarchy loop found." and exit.

### 2. Read State and Verify Session Ownership

```javascript
const content = Read(stateFile)

// Parse YAML frontmatter fields
const parentPlanMatch = content.match(/parent_plan:\s*(.+)/)
const configDirMatch = content.match(/config_dir:\s*(.+)/)
const ownerPidMatch = content.match(/owner_pid:\s*(\d+)/)

// SEC-009 FIX: Validate parentPlan path to prevent display injection
const parentPlanRaw = parentPlanMatch ? parentPlanMatch[1].trim() : "unknown"
const parentPlan = /^[a-zA-Z0-9._\/-]+$/.test(parentPlanRaw) ? parentPlanRaw : "unknown"
const storedConfigDir = configDirMatch ? configDirMatch[1].trim() : null
const ownerPid = ownerPidMatch ? ownerPidMatch[1].trim() : null

// Resolve current session identity
const currentConfigDir = Bash(`CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
const currentPid = Bash(`echo $PPID`).trim()

// Session ownership check
let foreignSession = false
if (storedConfigDir && storedConfigDir !== currentConfigDir) {
  foreignSession = true
} else if (ownerPid && /^\d+$/.test(ownerPid) && ownerPid !== currentPid) {
  // SEC-002 FIX: Quote ownerPid to prevent shell injection (already regex-validated above)
  const alive = Bash(`kill -0 "${ownerPid}" 2>/dev/null && echo "alive" || echo "dead"`).trim()
  if (alive === "alive") {
    foreignSession = true
  }
}

if (foreignSession) {
  warn("WARNING: This arc-hierarchy loop was started by another session.")
  warn(`  Owner PID: ${ownerPid || "unknown"}, Config dir: ${storedConfigDir || "unknown"}`)
  warn("  Proceeding with cancellation at your explicit request.")
}
```

### 3. Mark State as Cancelled

Write `active: false` and `cancelled: true` into the state file so the orchestration loop detects cancellation on next iteration check.

```javascript
// Replace the active: true line in the YAML frontmatter
const cancelled = content.replace(/^active:\s*true/m, "active: false")
  .replace(/^---/, `---\ncancelled: true\ncancelled_at: "${new Date().toISOString()}"`)

Write(stateFile, cancelled)
```

### 4. Report

```
Arc hierarchy loop cancelled.

Parent plan: {parentPlan}

The current child arc run (if any) will finish normally.
No further child plans will be executed.

To see what was completed: Read the execution table in {parentPlan}
To resume later: /rune:arc-hierarchy {parentPlan} --resume
```

### 5. Offer to Cancel Current Child Arc (Optional)

If the user also wants to stop the currently-running child arc:

```
To also cancel the currently-running child arc: /rune:cancel-arc
```
