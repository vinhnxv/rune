---
name: rune:cancel-arc-issues
description: |
  Cancel an active arc-issues batch loop. Removes the state file so the Stop hook
  allows the session to end after the current arc completes.

  <example>
  user: "/rune:cancel-arc-issues"
  assistant: "Arc issues loop cancelled at iteration 2/4."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Bash
  - Glob
---

# /rune:cancel-arc-issues — Cancel Active Arc Issues Loop

Removes the arc-issues loop state file (`.claude/arc-issues-loop.local.md`), stopping the Stop hook from re-injecting the next arc prompt. The currently-running arc will finish normally, but no further issues will be started.

## Steps

### 1. Check for Active Loop

```javascript
const stateFile = '.claude/arc-issues-loop.local.md'
const exists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
```

If `"no"`: Report "No active arc-issues loop found." and exit.

### 2. Read Current State and Check Ownership

```javascript
const content = Read(stateFile)
// Parse YAML frontmatter for iteration, total_plans, and ownership
const iterationMatch = content.match(/iteration:\s*(\d+)/)
const totalMatch = content.match(/total_plans:\s*(\d+)/)
const iteration = iterationMatch ? iterationMatch[1] : '?'
const totalPlans = totalMatch ? totalMatch[1] : '?'

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
  if (alive === 'alive') {
    foreignSession = true
  }
}

if (foreignSession) {
  warn('WARNING: This batch was started by another session.')
  warn(`  Owner PID: ${ownerPid || 'unknown'}, Config dir: ${storedConfigDir || 'unknown'}`)
  // Still allow cancellation — user might intentionally cancel from another terminal
}
```

### 3. Remove State File

```javascript
Bash('rm -f .claude/arc-issues-loop.local.md')
```

### 4. Report

```
Arc issues loop cancelled at iteration {iteration}/{totalPlans}.

The current arc run will finish normally.
No further issues will be started.

To see batch progress: Read tmp/gh-issues/batch-progress.json
To resume later: /rune:arc-issues --resume
```

### 5. Delegate to Cancel-Arc (Optional)

If the user also wants to cancel the currently-running arc:

```
To also cancel the current arc run: /rune:cancel-arc
```
