# Session Identity + State File

Resolves session identity (CHOME, PID, session ID) and writes the arc-hierarchy state file with ownership isolation. Checks for conflicting sessions before proceeding.

**Inputs**: `planPath`, `childrenDir`, `noMerge` flag, `--resume` mode flag, `arcPassthroughFlags` (array of validated flag strings)
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

  if (ownedByOther) {
    if (!resumeMode) {
      error("Another session is already executing arc-hierarchy on this repo.")
      error("Cancel it with /rune:cancel-arc-hierarchy, or use --resume to continue your own session.")
      return
    }

    // ── RESUME GUARD: Validate before allowing bypass ──
    // --resume only allows bypass when:
    // 1. config_dir matches (same installation)
    // 2. Owner PID is dead (orphan recovery)
    if (existingCfg && existingCfg !== configDir) {
      error(`Cannot resume: hierarchy belongs to different config dir`)
      error(`  Stored:  ${existingCfg}`)
      error(`  Current: ${configDir}`)
      error(`Delete .claude/arc-hierarchy-loop.local.md manually to force-claim.`)
      return
    }

    // SEC-1: Numeric PID guard before kill -0 interpolation
    if (existingPid && /^\d+$/.test(existingPid)) {
      const alive = Bash(`kill -0 ${existingPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
      if (alive === 'alive') {
        error(`Cannot resume: hierarchy is owned by live PID ${existingPid} in a different session.`)
        error(`Cancel it with /rune:cancel-arc-hierarchy, or wait for it to finish.`)
        return
      }
      warn(`Previous hierarchy owner (PID ${existingPid}) is dead. Claiming ownership for resume.`)
    }

    // ── TRANSIENT STATE RESET (G3 race mitigation) ──
    // Quick-patch: reset compact_pending before state file rewrite
    const patchedState = existingState.replace(/compact_pending:\s*true/, 'compact_pending: false')
    if (patchedState !== existingState) {
      Write(stateFile, patchedState)
      warn('Reset stale compact_pending in state file.')
    }
  }

  if (!ownedByOther && !resumeMode) {
    warn("Found existing state file from this session. Overwriting (use --resume to continue from current table state).")
  }

  // ── BRANCH GUARD: Verify feature branch matches on resume ──
  if (resumeMode && existingState) {
    const storedBranch = existingState.match(/feature_branch:\s*(.+)/)?.[1]?.trim()
    if (storedBranch && storedBranch !== '') {
      const currentBranch = Bash('git branch --show-current 2>/dev/null').trim()
      if (currentBranch !== storedBranch) {
        error(`Cannot resume: hierarchy expects feature branch "${storedBranch}"`)
        error(`  Current branch: ${currentBranch}`)
        error(`  Run: git checkout ${storedBranch}`)
        return
      }
    }
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
arc_passthrough_flags: ${arcPassthroughFlags.join(' ')}
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
// NOTE: arc_passthrough_flags is read by the Stop hook via get_field().
// Empty string when no passthrough flags were specified (backward compat).
// Each flag is validated against ARC_HIERARCHY_ALLOWED_FLAGS before storage.
// --no-pr is always hardcoded in the stop hook (never stored in state file).
```
