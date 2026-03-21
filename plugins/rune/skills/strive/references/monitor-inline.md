# Phase 3: Monitor — Inline Blocks

Inline monitoring blocks that run each poll cycle during Phase 3 of `/rune:strive`.
These are checked sequentially: signal checks → smart reassignment → stale lock scan → stuck worker detection.

## Signal Checks (Per Poll Cycle)

Two signal checks run inside the monitoring loop, checked each poll cycle after `TaskList`:

```javascript
// Check for context-critical shutdown signal (Layer 1)
const shutdownSignal = (() => {
  try {
    const sessionId = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
    const signalPath = `tmp/.rune-shutdown-signal-${sessionId}.json`
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "context_warning"
  } catch { return false }
})()

if (shutdownSignal) {
  warn("CTX-WARNING: Context pressure detected. Initiating early teammate shutdown.")
  goto_cleanup = true
  break
}

// Check for "all tasks done" signal from TeammateIdle hook (Layer 4)
const allDoneSignal = (() => {
  try {
    Read(`tmp/.rune-signals/${teamName}/all-tasks-done`)
    return true
  } catch { return false }
})()

if (allDoneSignal) {
  break
}

// Check for force_shutdown signal from guard-context-critical.sh (Layer 3)
const forceShutdownSignal = (() => {
  try {
    const sessionId = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
    const signalPath = `tmp/.rune-force-shutdown-${sessionId}.json`
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "force_shutdown"
  } catch { return false }
})()

if (forceShutdownSignal) {
  warn("FORCE SHUTDOWN: Context critically low. Sending shutdown_request to ALL workers.")
  // Send shutdown_request to all workers
  for (const worker of activeWorkers) {
    SendMessage({ type: "shutdown_request", recipient: worker.name, content: "Context critically low — emergency shutdown." })
  }
  goto_cleanup = true
  break
}
```

## Smart Reassignment (Per Poll Cycle)

Check whether in-progress tasks have exceeded their estimated time and reassign to idle workers. Runs per poll cycle, BEFORE stuck worker detection. Gated by `work.reassignment.enabled` (default: `true`).

```javascript
// --- Smart reassignment (per poll cycle, before stuck worker detection) ---
const reassignConfig = readTalismanSection("work")?.reassignment
if (reassignConfig?.enabled !== false) {
  const multiplier = reassignConfig?.multiplier ?? 2.0
  const graceSeconds = reassignConfig?.grace_seconds ?? 60

  const tasks = TaskList()
  const idleWorkers = Object.keys(workerSpawnTimes).filter(w =>
    !tasks.some(t => t.owner === w && t.status === "in_progress")
  )

  for (const task of tasks) {
    if (task.status !== "in_progress") continue
    const estimatedMin = task.metadata?.estimated_minutes ?? 10
    const elapsed = Date.now() - (task.metadata?.claimed_at ?? Date.now())
    const thresholdMs = multiplier * estimatedMin * 60_000

    // F15: max 2 reassignments per task
    const reassignCount = task.metadata?.reassignment_count ?? 0
    if (reassignCount >= 2) continue

    if (elapsed > thresholdMs) {
      if (!task.metadata?.reassignment_warned) {
        // First trigger: warn and set grace period
        log(`REASSIGN-CHECK: task #${task.id} exceeded ${multiplier}x estimate (${estimatedMin}min). Sending progress check.`)
        SendMessage({ type: "message", recipient: task.owner, content: `Progress check: task #${task.id} has exceeded its time estimate. Please report status.`, summary: `Progress check for task #${task.id}` })
        TaskUpdate({ taskId: task.id, metadata: { reassignment_warned: true, warned_at: Date.now() } })
      } else {
        // Grace period elapsed — re-read task status (F8 fix)
        const freshTask = TaskGet(task.id)
        if (freshTask.status === "in_progress") {
          const warnedAt = task.metadata?.warned_at ?? 0
          if (Date.now() - warnedAt > graceSeconds * 1000 && idleWorkers.length > 0) {
            log(`REASSIGN-FORCE: task #${task.id} still in_progress after grace period. Force-releasing.`)
            // F9: clear reassignment metadata on release
            TaskUpdate({
              taskId: task.id,
              status: "pending",
              owner: "",
              metadata: { reassignment_warned: null, warned_at: null, reassignment_count: reassignCount + 1 }
            })
            // Clean up file lock signal for the released task's worker
            try {
              Bash(`rm -f "tmp/.rune-signals/${teamName}/${task.owner}-files.json"`)
            } catch {}
          }
        }
      }
    }
  }
}
```

## Stale File Lock Scan (Per Poll Cycle)

Sweep `tmp/.rune-signals/{team}/*-files.json` for stale lock signals. Runs per poll cycle after smart reassignment. See [file-ownership.md](file-ownership.md) for signal format.

```javascript
// --- Stale lock scan (F1) ---
const staleLockThreshold = readTalismanSection("work")?.file_lock_signals?.stale_threshold_ms ?? 600_000
try {
  const lockFiles = Glob(`tmp/.rune-signals/${teamName}/*-files.json`)
  for (const lockFile of lockFiles) {
    try {
      const signal = JSON.parse(Read(lockFile))
      if (signal.timestamp && Date.now() - signal.timestamp > staleLockThreshold) {
        Bash(`rm -f "${lockFile}"`)
        warn(`Stale file lock removed: ${lockFile} (age: ${Math.round((Date.now() - signal.timestamp) / 60000)}min)`)
      }
    } catch {} // skip malformed signals
  }
} catch {} // no lock files — nothing to scan
```

## Stuck Worker Detection (Per Poll Cycle)

Track worker spawn times and enforce `max_runtime_minutes` (default: 20). Workers exceeding the runtime budget receive a `shutdown_request` and have their tasks released for reclaim.

**Setup**: In Phase 2, record spawn timestamps:
```javascript
// After spawning each worker in Phase 2:
const workerSpawnTimes = {}  // Map<workerName, Date>
// When spawning:
workerSpawnTimes[workerName] = Date.now()
```

**Detection** (runs per poll cycle in Phase 3, after signal checks):
```javascript
const maxRuntimeMinutes = readTalismanSection("teammate_lifecycle")?.max_runtime_minutes ?? 20
const maxRuntimeMs = maxRuntimeMinutes * 60 * 1000

for (const [workerName, spawnTime] of Object.entries(workerSpawnTimes)) {
  const elapsed = Date.now() - spawnTime
  if (elapsed > maxRuntimeMs) {
    // ── Semantic activity check (before stuck declaration) ──
    // If worker's JSONL shows productive activity, skip stuck action.
    // Prevents false positives when activity file is stale but worker is productive.
    const sessionJsonl = Bash(`bash "\${CLAUDE_PLUGIN_ROOT}/scripts/lib/find-teammate-session.sh" "${workerName}" "${teamName}" 2>/dev/null`).trim()
    if (sessionJsonl) {
      const stateResult = Bash(`bash "\${CLAUDE_PLUGIN_ROOT}/scripts/lib/detect-activity-state.sh" "${sessionJsonl}" 2>/dev/null`).trim()
      try {
        const state = JSON.parse(stateResult)
        switch (state.state) {
          case "WORKING":
            warn(`${workerName}: runtime exceeded but JSONL shows WORKING — skipping stuck action`)
            continue  // Skip stuck handling for this worker
          case "ERROR_LOOP":
            SendMessage({ to: workerName, message: `You appear stuck in an error loop (${state.details}). Try a different approach.`, summary: `Error loop hint for ${workerName}` })
            break
          case "RETRY_LOOP":
            SendMessage({ to: workerName, message: `You're retrying the same action repeatedly (${state.details}). Step back and reconsider.`, summary: `Retry loop hint for ${workerName}` })
            break
          case "PERMISSION_LOOP":
            warn(`${workerName}: stuck in permission dialog loop — may need human intervention`)
            break
          case "RATE_LIMITED":
            warn(`${workerName}: rate limited — extending stuck threshold`)
            continue  // Don't penalize for API limits
        }
      } catch (e) { /* Parse error — fall through to stuck handling */ }
    }
    warn(`STUCK WORKER: ${workerName} exceeded ${maxRuntimeMinutes}min runtime (${Math.round(elapsed/60000)}min). Sending shutdown_request.`)
    SendMessage({ type: "shutdown_request", recipient: workerName, content: `Runtime budget exceeded (${maxRuntimeMinutes}min). Shutting down.` })
    // Release any in_progress task owned by this worker
    const tasks = TaskList()
    for (const task of tasks) {
      if (task.owner === workerName && task.status === "in_progress") {
        TaskUpdate({ taskId: task.id, status: "pending", owner: "" })
        warn(`Released task #${task.id} from stuck worker ${workerName}`)
      }
    }
    delete workerSpawnTimes[workerName]  // Don't re-trigger
  }
}
```

### Stuck Worker Detection Config

| Setting | Default | Description |
|---------|---------|-------------|
| `teammate_lifecycle.max_runtime_minutes` | `20` | Workers exceeding this runtime receive a `shutdown_request` and have their tasks released for reclaim |

**Tuning guidance**:
- Default `20` minutes is appropriate for most implementation tasks
- Set to `999` to effectively disable stuck worker detection (useful when tasks are known to be long-running)
- Reduce to `10` for resource-constrained environments where you want faster reclaim of stalled tasks

**Wave-aware monitoring (worktree mode)**: Sequential waves, each monitored independently via `waitForCompletion` with `taskFilter`, merge broker runs between waves. Per-wave timeout: 10 minutes.
