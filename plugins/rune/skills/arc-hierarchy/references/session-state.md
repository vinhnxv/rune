# Session Identity + State File

Resolves session identity (CHOME, PID, session ID) and writes the arc-hierarchy state file with ownership isolation. Checks for conflicting sessions before proceeding.

**Inputs**: `planPath`, `childrenDir`, `noMerge` flag, `--resume` mode flag
**Outputs**: `.claude/arc-hierarchy-loop.local.md` state file with YAML frontmatter
**Preconditions**: Phases 0-4 passed (arguments parsed, plan validated, coherence checked)

## Session Identity Resolution

```javascript
// CHOME pattern: SDK Read() resolves CLAUDE_CONFIG_DIR automatically
// Bash rm/find must use explicit CHOME. See chome-pattern skill.
const configDir = Bash(`CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

const stateFile = ".claude/arc-hierarchy-loop.local.md"

// Check for existing session
const existingState = Read(stateFile)  // null if not found — SDK Read() is safe
if (existingState && /^active:\s*true$/m.test(existingState)) {
  const existingPid = existingState.match(/owner_pid:\s*(\d+)/)?.[1]
  const existingCfg = existingState.match(/config_dir:\s*(.+)/)?.[1]?.trim()

  let ownedByOther = false
  if (existingCfg && existingCfg !== configDir) {
    ownedByOther = true
  } else if (existingPid && /^\d+$/.test(existingPid) && existingPid !== ownerPid) {
    const alive = Bash(`kill -0 ${existingPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") ownedByOther = true
  }

  if (ownedByOther && !resumeMode) {
    error("Another session is already executing arc-hierarchy on this repo.")
    error("Cancel it with /rune:cancel-arc-hierarchy, or use --resume to continue your own session.")
    return
  }
  if (!ownedByOther) {
    warn("Found existing state file from this session. Overwriting (use --resume to continue from current table state).")
  }
}
```

## State File Write

```javascript
// Write state file with session isolation (all three fields required per CLAUDE.md §11)
// BACK-007 FIX: Include `status: active` for stop hook Guard 7 compatibility
// BACK-008 FIX: Include current_child, feature_branch, execution_table_path for stop hook
// These fields are updated as the loop progresses (current_child set before each child arc)
Write(stateFile, `---
active: true
status: active
parent_plan: ${planPath}
children_dir: ${childrenDir}
current_child: ""
feature_branch: ""
execution_table_path: ""
no_merge: ${noMerge}
iteration: 0
max_iterations: ${maxIterations || 0}
total_children: ${children.length}
compact_pending: false
config_dir: ${configDir}
owner_pid: ${ownerPid}
session_id: ${CLAUDE_SESSION_ID || Bash('echo "${RUNE_SESSION_ID:-}"').trim() || 'unknown'}
started_at: "${new Date().toISOString()}"
---

Arc hierarchy loop state. Do not edit manually.
Use /rune:cancel-arc-hierarchy to stop execution.
`)
```
