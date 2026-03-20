# TeamEngine — Full Implementation

Agent Team lifecycle engine. Implements the ExecutionEngine interface defined in [SKILL.md](../SKILL.md).

> **Consumers** (v1.166.0): This file's `shutdown()` protocol is referenced by 11+ skill cleanup stubs:
> appraise, codex-review, debug, design-sync, devise, forge, goldmask, inspect, mend, resolve-todos, strive.
> Changes to `shutdown()` affect all listed consumers. See each skill's `phase-N-cleanup.md` for the stub.

All pseudocode follows Rune's existing conventions: JavaScript-like syntax with Claude Code tool calls. This is documentation — not executable code.

## createTeam(config) -> TeamHandle

Executes the 6-step teamTransition protocol. Extracted from strive Phase 1, devise Phase -1, and mend Phase 2.

```javascript
function createTeam(config) {
  const { teamName, workflow, identifier, stateFilePrefix, metadata } = config

  // --- STEP 0: Feature flag pre-flight (ATD-002, defense-in-depth) ---
  // The guard-agent-teams-flag.sh hook enforces this at PreToolUse:TeamCreate,
  // but check here too in case the hook is bypassed or not loaded.
  const flagValue = Bash(`echo "\${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}"`).trim()
  if (flagValue !== "1") {
    throw new Error("ATD-002: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is not set to '1'. Enable it in .claude/settings.json or .claude/settings.local.json.")
  }

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

  // --- STEP 1.5: Quick probe — single TeamDelete to detect state ---
  // For fresh sessions with no existing team, this avoids 3 failed retries (~11s latency).
  // The SDK throws specific errors: "not leading" when no team exists vs
  // "members still active" when cleanup is needed.
  // SDK error patterns verified against Claude Code 2.1.63. Update regex if SDK error messages change.
  let teamDeleteSucceeded = false
  let needsRetry = false
  try {
    TeamDelete()
    teamDeleteSucceeded = true  // Succeeded on first try — team existed and was cleaned
  } catch (probeError) {
    if (/not leading|no team/i.test(probeError.message)) {
      // No team to clean — skip remaining retries entirely
      needsRetry = false
    } else if (/members|active/i.test(probeError.message)) {
      // Team exists but has active members — need retry with backoff
      needsRetry = true
    } else {
      // Unknown error — conservative: proceed with retry
      needsRetry = true
    }
  }

  // --- STEP 2: TeamDelete with retry-with-backoff (ONLY if probe indicated need) ---
  // Rationale: Members need time to finish current tool call and approve shutdown.
  // 3s covers most cases; 8s covers complex file writes.
  if (!teamDeleteSucceeded && needsRetry) {
    const RETRY_DELAYS = config.retryDelays ?? [3000, 8000]  // Skip first 0s delay (already done in probe)
    for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
      warn(`teamTransition: TeamDelete retry ${attempt + 1}, waiting ${RETRY_DELAYS[attempt]/1000}s...`)
      Bash(`sleep ${RETRY_DELAYS[attempt] / 1000}`)
      try {
        TeamDelete()
        teamDeleteSucceeded = true
        break
      } catch (e) {
        if (attempt === RETRY_DELAYS.length - 1) {
          warn(`teamTransition: TeamDelete failed after retries. Using filesystem fallback.`)
        }
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
  const sessionId = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
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

  // --- STEP 0: Feature flag pre-flight (ATD-002, defense-in-depth) ---
  // The guard-agent-teams-flag.sh hook enforces this at PreToolUse:TeamCreate,
  // but check here too in case the hook is bypassed or not loaded.
  const flagValue = Bash(`echo "\${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}"`).trim()
  if (flagValue !== "1") {
    throw new Error("ATD-002: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is not set to '1'. Enable it in .claude/settings.json or .claude/settings.local.json.")
  }

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

**IPC token cost rule**: Keep spawn prompt size ≤ 500 tokens. Pass file paths and task IDs — never inline file contents, plan text, or criteria YAML into the `prompt` field. Agents read what they need from disk (Reference Don't Inline principle). See [spec-continuity.md § 8.7](../../discipline/references/spec-continuity.md) for all five IPC principles.

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
    // FALLBACK LAYER 2: Read inscription.json from signal dir (persisted to disk in Phase 2).
    // Catches agent-search MCP discovered agents (registry/, user_agents) that survive
    // compaction — unlike handle.spawnedAgents which is a JS variable in context.
    try {
      const signalDir = `tmp/.rune-signals/${handle.teamName}`
      const inscription = JSON.parse(Read(`${signalDir}/inscription.json`))
      const inscriptionNames = (inscription.teammates || [])
        .map(t => t.name)
        .filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
      if (inscriptionNames.length > 0) {
        allMembers = inscriptionNames
      }
    } catch (e2) { /* inscription also unavailable — fall through to handle */ }

    // FALLBACK LAYER 3: Use spawned agent list from handle (context variable).
    // May be empty after compaction — per-skill stub fallback arrays supplement this.
    if (allMembers.length === 0) {
      allMembers = (handle.spawnedAgents || []).map(a => a.name)
    }
  }

  // --- 2. Send shutdown_request to all members — track delivery failures ---
  // SendMessage throwing = teammate already exited (confirmed dead).
  // SendMessage succeeding = teammate received request (confirmed alive).
  // This is the ONLY reliable liveness signal — pgrep -P cannot detect
  // in-process or tmux teammates (they are not child processes of $PPID).
  let confirmedAlive = 0
  let confirmedDead = 0
  for (const member of allMembers) {
    try {
      SendMessage({
        type: "shutdown_request",
        recipient: member,
        content: `${handle.workflow} workflow complete`
      })
      confirmedAlive++
    } catch (e) {
      // Member already exited — confirmed dead, continue with others
      confirmedDead++
    }
  }

  // --- 3. Adaptive grace period ---
  // Scale based on confirmed-alive members from step 2.
  // When ALL SendMessage calls threw → all dead → minimal SDK propagation pause.
  // When some alive → scale: max(5, alive_count * 5), capped at 20s.
  let gracePeriodUsed = 0
  if (confirmedAlive > 0) {
    gracePeriodUsed = Math.min(20, Math.max(5, confirmedAlive * 5))
    Bash(`sleep ${gracePeriodUsed}`)
  } else {
    // All confirmed dead — skip full grace period.
    // Minimal pause for SDK internal state propagation (deregistration).
    gracePeriodUsed = 2
    Bash(`sleep 2`)
  }

  // --- 4. TeamDelete with retry-with-backoff ---
  // Total budget: adaptive grace (2-20s) + retry (0+3+6+10=19s) = 21-39s max
  // Reduced from [0, 5000, 10000, 15000] (30s) to [0, 3000, 6000, 10000] (19s).
  // Rationale: the adaptive grace period already gave teammates time to deregister.
  // The retry loop only needs to cover SDK-level deregistration lag, not tool completion.
  // NOTE: Do NOT add pgrep-P checks here — SDK member registry is independent of process tree.
  // SEC-9: Re-validate teamName before rm-rf (defense-in-depth)
  if (!/^[a-zA-Z0-9_-]+$/.test(handle.teamName)) {
    throw new Error(`Invalid team_name: ${handle.teamName}`)
  }

  let cleanupTeamDeleteSucceeded = false
  let finalAttempt = 0  // Hoisted for diagnostic access (ASMP-006 fix)
  const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
  for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
    finalAttempt = attempt
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
      Bash(`sleep 5`)
      // SIGKILL survivors — re-verify command name before kill (PID recycling guard)
      Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
    }

    // 5b. Filesystem cleanup
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${handle.teamName}/" "$CHOME/tasks/${handle.teamName}/" 2>/dev/null`)
    try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
  }

  // --- 6. Cleanup diagnostic ---
  // Dual output: warn() for immediate trace + JSON file for post-mortem.
  // Variables hoisted from prior steps: confirmedAlive, confirmedDead,
  // gracePeriodUsed, finalAttempt, cleanupTeamDeleteSucceeded.
  const diagnostic = {
    team_name: handle.teamName,
    workflow: handle.workflow,
    timestamp: new Date().toISOString(),
    cleanup_succeeded: cleanupTeamDeleteSucceeded,
    total_members: allMembers.length,
    confirmed_alive: confirmedAlive,
    confirmed_dead: confirmedDead,
    grace_period_secs: gracePeriodUsed,
    retry_attempts: finalAttempt + 1,
    filesystem_fallback_used: !cleanupTeamDeleteSucceeded,
    owner_pid: handle.ownerPid
  }
  warn(`cleanup diagnostic: ${JSON.stringify(diagnostic)}`)
  try {
    Write(`tmp/.rune-cleanup-${handle.teamName}.json`, JSON.stringify(diagnostic, null, 2))
  } catch (e) {
    // Non-critical — warn() already emitted the diagnostic
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
