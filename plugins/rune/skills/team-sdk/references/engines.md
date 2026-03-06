# TeamEngine — Full Implementation

Agent Team lifecycle engine. Implements the ExecutionEngine interface defined in [SKILL.md](../SKILL.md).

All pseudocode follows Rune's existing conventions: JavaScript-like syntax with Claude Code tool calls. This is documentation — not executable code.

## createTeam(config) -> TeamHandle

Executes the 6-step teamTransition protocol. Extracted from strive Phase 1, devise Phase -1, and mend Phase 2.

```javascript
function createTeam(config) {
  const { teamName, workflow, identifier, stateFilePrefix, metadata } = config

  // --- STEP 1: Validate (defense-in-depth) ---
  if (!/^[a-zA-Z0-9_-]+$/.test(identifier)) {
    throw new Error(`Invalid identifier: ${identifier}`)
  }
  if (identifier.includes('..')) {
    throw new Error('Path traversal detected in identifier')
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) {
    throw new Error(`Invalid team name: ${teamName}`)
  }

  // --- STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s) ---
  // Rationale: Members need time to finish current tool call and approve shutdown.
  // 3s covers most cases; 8s covers complex file writes. Total max 11s wait.
  let teamDeleteSucceeded = false
  const RETRY_DELAYS = config.retryDelays ?? [0, 3000, 8000]  // Faster cadence than shutdown() [0,5s,10s] — pre-create recovery prioritizes speed
  for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
    if (attempt > 0) {
      warn(`teamTransition: TeamDelete attempt ${attempt + 1} failed, retrying in ${RETRY_DELAYS[attempt]/1000}s...`)
      Bash(`sleep ${RETRY_DELAYS[attempt] / 1000}`)
    }
    try {
      TeamDelete()
      teamDeleteSucceeded = true
      break
    } catch (e) {
      if (attempt === RETRY_DELAYS.length - 1) {
        warn(`teamTransition: TeamDelete failed after ${RETRY_DELAYS.length} attempts. Using filesystem fallback.`)
      }
    }
  }

  // --- STEP 3: Filesystem fallback (only when STEP 2 failed) ---
  // CDX-003 FIX: Gate behind !teamDeleteSucceeded to prevent cross-workflow scan
  // from wiping concurrent workflows when TeamDelete already succeeded cleanly.
  if (!teamDeleteSucceeded && !config.skipPreCreateGuard) {
    // Scoped cleanup — only remove THIS team's dirs
    // CHOME: Must use CLAUDE_CONFIG_DIR pattern for multi-account support
    // SEC-001: Re-validate teamName before rm-rf (defense-in-depth)
    if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) throw new Error(`Invalid teamName for cleanup: ${teamName}`)
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
    try { TeamDelete() } catch (e2) { /* proceed to TeamCreate */ }
  }

  // --- STEP 4: TeamCreate with "Already leading" catch-and-recover ---
  // Match: "Already leading" — centralized string match for SDK error detection
  try {
    TeamCreate({ team_name: teamName })
  } catch (createError) {
    if (/already leading/i.test(createError.message)) {
      warn(`teamTransition: Leadership state leak detected. Attempting final cleanup.`)
      try { TeamDelete() } catch (e) { /* exhausted */ }
      // SEC-001: Re-validate teamName before rm-rf (defense-in-depth)
      if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) throw new Error(`Invalid teamName for cleanup: ${teamName}`)
      Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
      try {
        TeamCreate({ team_name: teamName })
      } catch (finalError) {
        if (config.fallbackOnFailure) {
          warn(`teamTransition failed — degrading to local execution.`)
          return null
        }
        throw new Error(`teamTransition failed: unable to create team after exhausting all cleanup strategies. Run /rune:rest --heal to manually clean up, then retry. (${finalError.message})`)
      }
    } else {
      throw createError
    }
  }

  // --- STEP 5: Post-create verification ---
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -f "$CHOME/teams/${teamName}/config.json" || echo "WARN: config.json not found after TeamCreate"`)

  // --- STEP 6: Write state file with session isolation fields ---
  // CRITICAL: This state file activates the ATE-1 hook (enforce-teams.sh) which blocks
  // bare Agent calls without team_name. Without this file, agents spawn as local subagents
  // instead of Agent Team teammates, causing context explosion.
  // IMPORTANT: Steps 4-6 must complete atomically before any Agent() calls.
  // spawnAgent() is only called after createTeam() returns, so this race
  // does not manifest for SDK-mediated workflows.
  const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
  const ownerPid = Bash(`echo $PPID`).trim()
  const sessionId = Bash(`echo "\${CLAUDE_SESSION_ID:-}"`).trim()
  const stateFile = `${stateFilePrefix}-${identifier}.json`

  Write(stateFile, {
    team_name: teamName,
    started: new Date().toISOString(),
    status: "active",
    config_dir: configDir,
    owner_pid: ownerPid,
    session_id: sessionId,
    ...metadata
  })

  return {
    teamName,
    workflow,
    identifier,
    configDir,
    ownerPid,
    sessionId,
    stateFile,
    createdAt: new Date().toISOString(),
    spawnedAgents: []  // Populated by spawnAgent/spawnWave
  }
}
```

## ensureTeam(config) -> TeamHandle

Idempotent team creation. Safe to call multiple times — checks if team already exists and belongs to current session before creating. Used by auto-bootstrap pattern and compaction recovery.

```javascript
function ensureTeam(config) {
  // Idempotent team creation — safe to call multiple times.
  // If team already exists AND belongs to current session, returns recovered handle.
  // If team doesn't exist, calls createTeam().
  // If team exists but belongs to different session, calls createTeam() (which cleans up first).

  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const configPath = `${CHOME}/teams/${config.teamName}/config.json`

  // Check if team already exists
  try {
    const teamConfig = Read(configPath)
    if (teamConfig) {
      // Team exists — check if it's ours (session isolation)
      const stateFile = `${config.stateFilePrefix}-${config.identifier}.json`
      try {
        const state = JSON.parse(Read(stateFile))
        if (state.status === "active" && state.owner_pid === Bash(`echo $PPID`).trim()) {
          // Note: PID reuse within a single session's lifetime is astronomically unlikely.
          // Adding session_id as a secondary check would close this theoretical gap.
          // Our team, our session — recover handle
          return {
            teamName: config.teamName,
            workflow: config.workflow,
            identifier: config.identifier,
            configDir: state.config_dir,
            ownerPid: state.owner_pid,
            sessionId: state.session_id,
            stateFile,
            createdAt: state.started,
            spawnedAgents: []  // Cannot recover spawned list — fresh start
          }
        }
      } catch (e) {
        // State file missing or corrupted — fall through to createTeam()
      }
    }
  } catch (e) {
    // Team dir doesn't exist — fall through to createTeam()
  }

  // Team doesn't exist or belongs to another session — create fresh
  return createTeam(config)
}
```

## spawnAgent(handle, spec) -> AgentRef

Spawns a single teammate. ATE-1 compliant: always includes `team_name` and uses `subagent_type: "general-purpose"`. Accepts either a TeamHandle or a config object (auto-bootstrap).

```javascript
function spawnAgent(handleOrConfig, spec) {
  // Auto-bootstrap: accept either a TeamHandle or a config object.
  // If config object (no createdAt field), call ensureTeam() first.
  let handle = handleOrConfig
  if (!handleOrConfig.createdAt) {
    // This is a config object, not a handle — auto-bootstrap
    handle = ensureTeam(handleOrConfig)
    if (!handle) {
      throw new Error("Auto-bootstrap failed: ensureTeam() returned null. Check team-sdk logs.")
    }
  }

  const {
    name, prompt, taskSubject, taskDescription,
    activeForm, tools, maxTurns, metadata
  } = spec

  // SEC-4: validate agent name
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    throw new Error(`Invalid agent name: ${name}`)
  }

  // Create task for the agent to claim
  const taskOpts = {
    subject: taskSubject,
    description: taskDescription || taskSubject,
    activeForm: activeForm || `Running ${name}`
  }
  if (metadata) taskOpts.metadata = metadata

  TaskCreate(taskOpts)

  // Spawn agent into team
  Agent({
    name: name,
    subagent_type: "general-purpose",
    team_name: handle.teamName,
    prompt: prompt,
    ...(tools && { tools }),
    ...(maxTurns && { maxTurns })
  })

  const ref = {
    name,
    taskId: null,  // Resolved after TaskList
    spawnedAt: Date.now()
  }

  // Track spawned agent on handle for cleanup fallback
  handle.spawnedAgents.push(ref)
  return ref
}
```

## spawnWave(handle, specs) -> AgentRef[]

Batch spawns for wave-based execution. Creates all tasks first, then spawns agents. Used by strive (worker waves) and mend (fixer waves). Accepts either a TeamHandle or a config object (auto-bootstrap).

```javascript
function spawnWave(handleOrConfig, specs) {
  // Auto-bootstrap: accept either a TeamHandle or a config object.
  // If config object (no createdAt field), call ensureTeam() first.
  let handle = handleOrConfig
  if (!handleOrConfig.createdAt) {
    handle = ensureTeam(handleOrConfig)
    if (!handle) {
      throw new Error("Auto-bootstrap failed: ensureTeam() returned null. Check team-sdk logs.")
    }
  }

  const refs = []

  // Create all tasks first (ordering matters for dependency chains)
  for (const spec of specs) {
    if (!/^[a-zA-Z0-9_-]+$/.test(spec.name)) {
      throw new Error(`Invalid agent name: ${spec.name}`)
    }

    const taskOpts = {
      subject: spec.taskSubject,
      description: spec.taskDescription || spec.taskSubject,
      activeForm: spec.activeForm || `Running ${spec.name}`
    }
    if (spec.metadata) taskOpts.metadata = spec.metadata
    if (spec.blockedBy) taskOpts.blockedBy = spec.blockedBy

    TaskCreate(taskOpts)
  }

  // Spawn all agents (parallelizable — no dependencies between spawns)
  for (const spec of specs) {
    Agent({
      name: spec.name,
      subagent_type: "general-purpose",
      team_name: handle.teamName,
      prompt: spec.prompt,
      ...(spec.tools && { tools: spec.tools }),
      ...(spec.maxTurns && { maxTurns: spec.maxTurns })
    })

    const ref = {
      name: spec.name,
      taskId: null,
      spawnedAt: Date.now()
    }
    refs.push(ref)
    handle.spawnedAgents.push(ref)
  }

  return refs
}
```

## shutdownWave(handle) -> void

Shuts down the current wave's agents without tearing down the team. Called between waves in strive and mend.

```javascript
function shutdownWave(handle) {
  // 1. Discover current wave members from team config
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  let waveMembers = []
  try {
    const teamConfig = JSON.parse(Read(`${CHOME}/teams/${handle.teamName}/config.json`))
    const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
    waveMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
  } catch (e) {
    // Fallback: use recently spawned agents from handle
    waveMembers = handle.spawnedAgents
      .filter(a => Date.now() - a.spawnedAt < 1_800_000)  // 30 min recency
      .map(a => a.name)
  }

  // 2. Send shutdown_request to all wave members
  for (const member of waveMembers) {
    SendMessage({
      type: "shutdown_request",
      recipient: member,
      content: "Wave complete. Shutting down for next wave."
    })
  }

  // 3. Grace period — let teammates deregister
  if (waveMembers.length > 0) {
    Bash(`sleep 20`)
  }

  // 4. Clean up completed tasks (prepare pool for next wave)
  const tasks = TaskList()
  for (const task of tasks) {
    if (task.status === "completed") {
      TaskUpdate({ taskId: task.id, status: "deleted" })
    }
  }
}
```

## monitor(handle, opts) -> MonitorResult

Wraps the shared `waitForCompletion` utility from [monitor-utility.md](../../roundtable-circle/references/monitor-utility.md). Adds signal checks inline per poll cycle.

```javascript
function monitor(handle, opts) {
  const {
    timeoutMs,
    staleWarnMs = 300_000,
    autoReleaseMs,
    pollIntervalMs = 30_000,
    label = "Monitor",
    taskFilter,
    onCheckpoint
  } = opts

  // Delegate to shared polling utility
  const result = waitForCompletion(handle.teamName, opts.expectedCount, {
    timeoutMs,
    staleWarnMs,
    autoReleaseMs,
    pollIntervalMs,
    label,
    onCheckpoint
  })

  return result
}
```

**Signal checks**: The monitor loop also checks for completion and shutdown signals per poll cycle. See [monitoring.md](monitoring.md) for the three signal check patterns (context-critical shutdown, all-tasks-done, force shutdown).

## sendMessage(handle, msg) -> void

Thin wrapper with SEC-4 validation.

```javascript
function sendMessage(handle, msg) {
  const { type, recipient, content, summary } = msg

  // SEC-4: validate recipient name
  if (recipient && !/^[a-zA-Z0-9_-]+$/.test(recipient)) {
    throw new Error(`Invalid recipient name: ${recipient}`)
  }

  SendMessage({
    type,
    ...(recipient && { recipient }),
    content,
    ...(summary && { summary })
  })
}
```

## shutdown(handle) -> void

5-component cleanup protocol. Extracted from strive Phase 6, devise Phase 6, mend Phase 7. This is the canonical cleanup sequence — all workflows MUST follow this order.

```javascript
function shutdown(handle) {
  // Guard: handle may be null after compaction or fallback failure
  if (!handle || !handle.teamName) {
    warn("shutdown() called with null/incomplete handle — skipping")
    return
  }

  // --- 1. Dynamic member discovery ---
  // Read team config to find ALL teammates (not just those we spawned)
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  let allMembers = []
  try {
    const teamConfig = JSON.parse(Read(`${CHOME}/teams/${handle.teamName}/config.json`))
    const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
    allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
  } catch (e) {
    // FALLBACK: config.json read failed — use spawned agent list from handle.
    // This includes wave-based names (rune-smith-w0-1, mend-fixer-w1-2, etc.).
    allMembers = handle.spawnedAgents.map(a => a.name)
  }

  // --- 2. Send shutdown_request to all discovered members ---
  for (const member of allMembers) {
    SendMessage({
      type: "shutdown_request",
      recipient: member,
      content: `${handle.workflow} workflow complete`
    })
  }

  // --- 3. Grace period — let teammates deregister before TeamDelete ---
  // Without this, TeamDelete fires before teammates approve shutdown
  // → "active members" error. 20s covers most cases including slow tool calls.
  // Increased from 15s to 20s: teammates in mid-Write/Edit often need 15-18s to finish.
  if (allMembers.length > 0) {
    Bash(`sleep 20`)
  }

  // --- 4. TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s) ---
  // Total budget: 20s grace + 30s retry = 50s max
  // Added 4th attempt: some teammates take >25s to deregister after complex tool calls.
  // SEC-9: Re-validate teamName before rm-rf (defense-in-depth)
  if (!/^[a-zA-Z0-9_-]+$/.test(handle.teamName)) {
    throw new Error(`Invalid team_name: ${handle.teamName}`)
  }

  let cleanupTeamDeleteSucceeded = false
  const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
  for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
    if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
    try {
      TeamDelete()
      cleanupTeamDeleteSucceeded = true
      break
    } catch (e) {
      if (attempt === CLEANUP_DELAYS.length - 1) {
        warn(`cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
      }
    }
  }

  // --- 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012) ---
  if (!cleanupTeamDeleteSucceeded) {
    // 5a. Process-level kill: terminate lingering teammate processes before filesystem cleanup.
    // When TeamDelete fails, teammates are likely still running. Filesystem cleanup alone
    // leaves zombie processes that hold file locks and consume resources.
    // pgrep -P finds children of the Claude Code process (our session).
    const ownerPid = handle.ownerPid || Bash(`echo $PPID`).trim()
    if (ownerPid && /^\d+$/.test(ownerPid)) {
      // SIGTERM first — give teammates a chance to exit cleanly
      Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
      Bash(`sleep 3`)
      // SIGKILL survivors — re-verify command name before kill (PID recycling guard)
      Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
    }

    // 5b. Filesystem cleanup
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${handle.teamName}/" "$CHOME/tasks/${handle.teamName}/" 2>/dev/null`)
    try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
  }
}
```

## cleanup(handle) -> void

Post-shutdown state management. Called after `shutdown()`.

```javascript
function cleanup(handle) {
  // Guard: handle may be null after compaction or fallback failure
  if (!handle) {
    warn("cleanup() called with null handle — skipping")
    return
  }

  // 1. Update state file to completed (preserve session identity fields)
  if (handle.stateFile) {
    try {
      const state = JSON.parse(Read(handle.stateFile))
      Write(handle.stateFile, {
        ...state,
        status: "completed"
      })
    } catch (e) {
      warn(`cleanup: state file update failed for ${handle.stateFile}: ${e.message}`)
    }
  }

  // 2. Release workflow lock
  // Assumes CWD is project root — stable in Claude Code sessions.
  // After compaction recovery, CWD could theoretically differ.
  if (handle.workflow) {
    const CWD = Bash(`pwd`).trim()
    Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "${handle.workflow}"`)
  }

  // 3. Clean up signal directory (non-blocking)
  if (handle.teamName) {
    try {
      Bash(`rm -rf "tmp/.rune-signals/${handle.teamName}" 2>/dev/null`)
    } catch (e) { /* non-blocking */ }
  }
}
```

## getStatus(handle) -> TeamStatus

Returns current team status for diagnostics and the `/rune:team-status` command.

```javascript
function getStatus(handle) {
  if (!handle || !handle.teamName) {
    return { teamName: "unknown", members: [], tasks: [], stateFile: {}, healthy: false }
  }

  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

  // Read team config
  let members = []
  let healthy = false
  try {
    const teamConfig = JSON.parse(Read(`${CHOME}/teams/${handle.teamName}/config.json`))
    members = Array.isArray(teamConfig.members) ? teamConfig.members : []
    healthy = true
  } catch (e) {
    // Team dir missing or config.json unreadable
    healthy = false
  }

  // Read task list
  let tasks = []
  try {
    tasks = TaskList()
  } catch (e) {
    // No active team — tasks unavailable
  }

  // Read state file
  let stateFile = {}
  try {
    stateFile = JSON.parse(Read(handle.stateFile))
  } catch (e) { /* state file missing or malformed */ }

  return {
    teamName: handle.teamName,
    members: members.map(m => ({
      name: m.name,
      status: m.status || "unknown"
    })),
    tasks: tasks.map(t => ({
      id: t.id,
      subject: t.subject,
      status: t.status,
      owner: t.owner || ""
    })),
    stateFile,
    healthy
  }
}
```

## Error Recovery

### Compaction Recovery

After compaction, the TeamHandle is lost from context. The workflow must reconstruct it from the state file. See [protocols.md](protocols.md) for `recoverHandle()`.

### Crash Recovery

Three independent layers catch orphaned teams from different crash scenarios:

| Layer | Trigger | Catches |
|-------|---------|---------|
| Arc Resume Pre-Flight | `arc --resume` | Same-session orphans |
| `/rune:rest --heal` | User command | Cross-session orphans |
| Arc Pre-Flight Stale Scan | Any `arc` invocation | Stale arc-prefixed teams |

See [protocols.md](protocols.md) § Handle Serialization Protocol for full orphan recovery documentation.

### Common Errors

| Error | Cause | Recovery |
|-------|-------|----------|
| "Already leading team" | Previous TeamDelete failed | Step 4 catch-and-recover in createTeam |
| "Cannot cleanup team with N active members" | Teammates still deregistering | Grace period + retry-with-backoff in shutdown |
| State file missing after compaction | Context lost | recoverHandle() from protocols.md |
| Zombie team directory | TeamDelete succeeded but rm-rf skipped | verify-team-cleanup.sh hook (TLC-002) |
