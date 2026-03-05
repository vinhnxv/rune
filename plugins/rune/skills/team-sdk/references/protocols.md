# Shared Protocols

Four protocols shared across all team lifecycle operations. These protocols are consumed by the TeamEngine methods in [engines.md](engines.md) and by inline fallback code in consuming skills.

## 1. Session Isolation Protocol

Every workflow state file MUST include three session identity fields to prevent cross-session interference. This is a CRITICAL requirement — different Claude Code sessions working on the same repo MUST NOT interfere with each other.

### Identity Triple

| Field | Source | Purpose |
|-------|--------|---------|
| `config_dir` | Resolved `CLAUDE_CONFIG_DIR` (absolute path) | Installation isolation (multi-account) |
| `owner_pid` | `$PPID` (Claude Code process PID) | Session isolation (liveness via `kill -0`) |
| `session_id` | `${CLAUDE_SESSION_ID}` (skill substitution) | Diagnostic correlation (not verifiable in bash) |

### Writing Session Identity

```javascript
// Resolve once at workflow start, store on TeamHandle
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

// Include in state file
Write(stateFile, {
  // ... workflow fields ...
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}"
})
```

### verifyOwnership(stateFile) -> boolean

Hook scripts and cancel commands MUST verify ownership before acting on state files.

```javascript
function verifyOwnership(stateFile) {
  try {
    const state = JSON.parse(Read(stateFile))

    // 1. Check config_dir matches current session
    const currentCfg = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
    if (state.config_dir && state.config_dir !== currentCfg) {
      return false  // Different installation — skip silently
    }

    // 2. Check owner_pid matches $PPID (with kill -0 liveness check)
    const currentPid = Bash(`echo $PPID`).trim()
    if (state.owner_pid && state.owner_pid !== currentPid) {
      // Check if the owning process is still alive
      const isAlive = Bash(`kill -0 ${state.owner_pid} 2>/dev/null && echo alive || echo dead`).trim()
      if (isAlive === "alive") {
        return false  // Different live session owns this — skip
      }
      // Owner PID is dead → orphan recovery is safe
      return true
    }

    return true  // Same session or no ownership info (legacy)
  } catch (e) {
    return false  // State file missing or malformed
  }
}
```

### Ownership Decision Matrix

| config_dir match? | owner_pid match? | PID alive? | Action |
|-------------------|-----------------|------------|--------|
| Yes | Yes | N/A | Own state — act normally |
| Yes | No | Yes | Foreign live session — skip silently |
| Yes | No | No | Orphan — safe to clean up |
| No | N/A | N/A | Different installation — skip silently |

### Shell Script Pattern

For hook scripts (bash), use `resolve-session-identity.sh`:

```bash
# Source session identity resolver
source "${SCRIPT_DIR}/resolve-session-identity.sh"

# Read state file
state_cfg=$(jq -r '.config_dir // empty' "$state_file")
state_pid=$(jq -r '.owner_pid // empty' "$state_file")

# Check config_dir
if [[ -n "$state_cfg" && "$state_cfg" != "$RUNE_CURRENT_CFG" ]]; then
  exit 0  # Different installation — skip
fi

# Check owner_pid
if [[ -n "$state_pid" && "$state_pid" != "$PPID" ]]; then
  if rune_pid_alive "$state_pid"; then
    exit 0  # Different live session — skip
  fi
  # Dead PID → orphan recovery
fi
```

## 2. Workflow Lock Protocol

Advisory file-based locking for cross-command coordination. Prevents conflicting workflows from running simultaneously (e.g., two `strive` instances editing the same files).

### Lock Classes

| Class | Conflict Matrix | Used By |
|-------|----------------|---------|
| `writer` | Conflicts with other `writer` locks | strive, mend |
| `planner` | Advisory only — warns but never blocks | devise |
| `reader` | No conflicts | appraise, audit, inspect |

### Acquire Lock

```javascript
// Check for conflicts before acquiring
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "${lockClass}"`)

if (lockConflicts.includes("CONFLICT")) {
  // Writer conflicts are hard — require user confirmation
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
} else if (lockConflicts.includes("ADVISORY")) {
  // Planner conflicts are soft — inform but don't block
  warn(`Active workflow(s) detected:\n${lockConflicts}`)
}

// Acquire the lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "${workflow}" "${lockClass}"`)
```

### Release Lock

```javascript
// Release at cleanup (after shutdown, before state file update)
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "${workflow}"`)
```

### Lock File Location

Locks live at `tmp/.rune-locks/{workflow}/meta.json`. The `workflow-lock.sh` library handles all file operations, PID validation, and conflict detection. Locks are advisory — they do not prevent execution, only warn.

### Emergency Lock Release

```javascript
// Release ALL locks owned by this PID (crash recovery)
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_all_locks`)
```

## 3. Signal Detection Protocol

File-based signals in `tmp/.rune-signals/` enable fast completion detection without polling overhead. Used by Phase 3 monitoring loops and hook scripts.

### Signal Directory Structure

```
tmp/.rune-signals/
  {teamName}/
    .expected         # Total expected task count (written at team creation)
    inscription.json  # Team manifest with teammate names and output expectations
    all-tasks-done    # Written by on-task-completed.sh when all tasks complete
    {worker}-files.json  # File lock signals (strive file ownership)
  .echo-dirty         # Written by annotate-hook.sh when echo files change
```

### Setup Signals (in createTeam)

```javascript
const signalDir = `tmp/.rune-signals/${teamName}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(expectedTaskCount))
Write(`${signalDir}/inscription.json`, JSON.stringify({
  workflow: workflowName,
  timestamp: identifier,
  output_dir: outputDir,
  teammates: specs.map(s => ({
    name: s.name,
    output_file: s.outputFile || "output.md"
  }))
}))
```

### Check Signals (in monitor loop)

Three signal checks run per poll cycle after `TaskList`:

```javascript
// Signal 1: Context-critical shutdown (Layer 1)
// Written by guard-context-critical.sh when token usage exceeds warning threshold
const shutdownSignal = (() => {
  try {
    const sessionId = Bash(`echo "$CLAUDE_SESSION_ID"`).trim()
    const signalPath = `tmp/.rune-shutdown-signal-${sessionId}.json`
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "context_warning"
  } catch { return false }
})()
if (shutdownSignal) {
  warn("CTX-WARNING: Context pressure detected. Initiating early teammate shutdown.")
  break  // Exit monitor loop, proceed to shutdown
}

// Signal 2: All tasks done (Layer 4)
// Written by on-task-completed.sh hook when completed count matches .expected
const allDoneSignal = (() => {
  try {
    Read(`tmp/.rune-signals/${teamName}/all-tasks-done`)
    return true
  } catch { return false }
})()
if (allDoneSignal) {
  break  // Fast-path exit — skip remaining poll cycles
}

// Signal 3: Force shutdown (Layer 3)
// Written by guard-context-critical.sh when token usage exceeds critical threshold
const forceShutdownSignal = (() => {
  try {
    const sessionId = Bash(`echo "$CLAUDE_SESSION_ID"`).trim()
    const signalPath = `tmp/.rune-force-shutdown-${sessionId}.json`
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "force_shutdown"
  } catch { return false }
})()
if (forceShutdownSignal) {
  warn("FORCE SHUTDOWN: Context critically low. Emergency shutdown.")
  // Send shutdown_request to ALL workers before breaking
  for (const worker of activeWorkers) {
    SendMessage({
      type: "shutdown_request",
      recipient: worker.name,
      content: "Context critically low - emergency shutdown."
    })
  }
  break
}
```

### Signal Cleanup

Signal directories are cleaned up by `TeamEngine.cleanup()` after shutdown:

```javascript
Bash(`rm -rf "tmp/.rune-signals/${handle.teamName}" 2>/dev/null`)
```

## 4. Handle Serialization Protocol

Persists the TeamHandle to a JSON file so it can be recovered after context compaction. Without this, the workflow loses its team reference and cannot perform cleanup.

### Serialize (automatic — embedded in state file)

The TeamHandle fields are stored within the workflow state file (written by `createTeam` Step 6). No separate serialization step is needed — the state file IS the serialized handle.

### recoverHandle(workflow, identifier) -> TeamHandle | null

Reconstructs a TeamHandle from the state file after compaction or session resume.

```javascript
function recoverHandle(workflow, identifier) {
  // 1. Locate state file by convention
  const prefixMap = {
    strive:   "tmp/.rune-work",
    devise:   "tmp/.rune-plan",
    mend:     "tmp/.rune-mend",
    appraise: "tmp/.rune-review",
    audit:    "tmp/.rune-audit",
    forge:    "tmp/.rune-forge"
  }
  const prefix = prefixMap[workflow]
  if (!prefix) return null

  const stateFile = `${prefix}-${identifier}.json`

  // 2. Read and validate state file
  let state
  try {
    state = JSON.parse(Read(stateFile))
  } catch (e) {
    return null  // State file missing or malformed
  }

  // 3. Verify ownership
  if (state.status !== "active") {
    return null  // Workflow already completed or cancelled
  }

  // 4. Reconstruct handle
  return {
    teamName:     state.team_name,
    workflow:     workflow,
    identifier:   identifier,
    configDir:    state.config_dir,
    ownerPid:     state.owner_pid,
    sessionId:    state.session_id,
    stateFile:    stateFile,
    createdAt:    state.started,
    spawnedAgents: []  // Lost after compaction — dynamic discovery compensates
  }
}
```

### Compaction Recovery Flow

After compaction, workflows use the pre-compact checkpoint (saved by `pre-compact-checkpoint.sh`) to recover:

1. `session-compact-recovery.sh` hook fires on `SessionStart:compact`
2. Hook reads `tmp/.rune-compact-checkpoint.json` (saved by `pre-compact-checkpoint.sh`)
3. Checkpoint contains team name, task list snapshot, and workflow phase
4. Re-injected as `additionalContext` — Claude sees the team state
5. Workflow calls `recoverHandle()` to reconstruct the TeamHandle
6. Correlation guard: verify team dir still exists before proceeding

```javascript
// On compaction recovery:
const checkpoint = JSON.parse(Read("tmp/.rune-compact-checkpoint.json"))
const handle = recoverHandle(checkpoint.workflow, checkpoint.identifier)
if (handle) {
  // Verify team still exists
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamExists = Bash(`test -f "${CHOME}/teams/${handle.teamName}/config.json" && echo yes || echo no`).trim()
  if (teamExists === "yes") {
    // Resume from current phase
    const tasks = TaskList()
    // ... continue workflow ...
  } else {
    warn("Team directory missing after compaction — workflow cannot resume.")
  }
}
```

### State File Prefix Map

| Workflow | Prefix | Team Name Format |
|----------|--------|-----------------|
| strive | `tmp/.rune-work` | `rune-work-{timestamp}` |
| devise | `tmp/.rune-plan` | `rune-plan-{timestamp}` |
| mend | `tmp/.rune-mend` | `rune-mend-{id}` |
| appraise | `tmp/.rune-review` | `rune-review-{identifier}` |
| audit | `tmp/.rune-audit` | `rune-audit-{identifier}` |
| forge | `tmp/.rune-forge` | `rune-forge-{id}` |

### Staleness Detection

State files with `status === "active"` may represent crashed (orphaned) workflows. Use the 30-minute staleness threshold:

```javascript
const ORPHAN_STALE_THRESHOLD = 1_800_000  // 30 minutes (ms)

function isStale(startedTimestamp) {
  return Date.now() - new Date(startedTimestamp).getTime() > ORPHAN_STALE_THRESHOLD
}

// NaN guard: missing/malformed `started` is treated as stale (conservative)
```

See [engines.md](engines.md) § cleanup for the full orphan recovery documentation and the three-layer recovery architecture.
