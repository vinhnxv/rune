# Monitoring Patterns — Team Progress and Health Tracking

> Extracted monitoring patterns from Roundtable Circle's `waitForCompletion()`. The SDK provides these as reusable utilities so each workflow does not inline its own polling loop.

## Table of Contents

- [waitForCompletion()](#waitforcompletion)
- [Stale Detection](#stale-detection)
- [Signal-Based Fast Completion](#signal-based-fast-completion)
- [Context-Critical Shutdown Detection](#context-critical-shutdown-detection)
- [Stuck Worker Detection](#stuck-worker-detection)
- [Smart Reassignment](#smart-reassignment)
- [Anti-Patterns](#anti-patterns)

## waitForCompletion()

Parameterized polling loop that monitors team task progress. All Rune workflows call this single function with per-workflow configuration instead of inlining their own polling loops.

### Contract

| Field | Description |
|-------|-------------|
| **Inputs** | `teamName` (string), `expectedCount` (number), `opts` (configuration) |
| **Outputs** | `{ completed: Task[], incomplete: Task[], timedOut: boolean }` |
| **Preconditions** | Team exists, tasks created |
| **Error handling** | TaskList errors propagate. Timeout returns partial results, never throws. |

### Configuration

```
waitForCompletion(teamName, expectedCount, opts):
  opts.pollIntervalMs       // Polling interval (default: 30_000)
  opts.staleWarnMs          // Warn threshold for in_progress tasks (default: 300_000)
  opts.timeoutMs            // Total timeout — OPTIONAL (undefined = no timeout)
  opts.autoReleaseMs        // Auto-release stale tasks — OPTIONAL (undefined = no auto-release)
  opts.label                // Display label for log messages
  opts.onCheckpoint         // Milestone callback — OPTIONAL
```

### Core Loop

```
function waitForCompletion(teamName, expectedCount, opts) {
  const startTime = Date.now()
  const taskStartTimes = {}

  while (true) {
    const tasks = TaskList()
    const completed = tasks.filter(t => t.status === "completed")
    const inProgress = tasks.filter(t => t.status === "in_progress")

    // Track stale durations
    for (const t of inProgress) {
      if (!taskStartTimes[t.id]) taskStartTimes[t.id] = Date.now()
      t.stale = Date.now() - taskStartTimes[t.id]
    }

    // All done
    if (completed.length >= expectedCount) {
      return { completed, incomplete: [], timedOut: false }
    }

    // Stale detection (see below)
    // Auto-release (see below)
    // Checkpoint reporting (see below)

    // Timeout check
    if (opts.timeoutMs && Date.now() - startTime > opts.timeoutMs) {
      const finalTasks = TaskList()
      return {
        completed: finalTasks.filter(t => t.status === "completed"),
        incomplete: finalTasks.filter(t => t.status !== "completed"),
        timedOut: true
      }
    }

    sleep(opts.pollIntervalMs)
  }
}
```

### Per-Preset Configuration

Values sourced from [presets.md](presets.md) and [monitor-utility.md](../../roundtable-circle/references/monitor-utility.md):

| Preset | `timeoutMs` | `staleWarnMs` | `autoReleaseMs` | `label` | `onCheckpoint` |
|--------|-------------|---------------|-----------------|---------|----------------|
| review | 600,000 (10 min) | 300,000 | -- | "Review" | -- |
| work | 1,800,000 (30 min) | 300,000 | 600,000 (10 min) | "Work" | Yes |
| plan | -- (none) | 300,000 | -- | "Plan Research" | -- |
| fix | 900,000 (15 min) | 300,000 | 600,000 (10 min) | "Mend" | -- |
| debug | 600,000 (10 min) | 300,000 | -- | "Debug" | -- |
| audit | 900,000 (15 min) | 300,000 | -- | "Audit" | -- |
| forge | 1,200,000 (20 min) | 300,000 | 300,000 (5 min) | "Forge" | -- |

**All presets use `pollIntervalMs: 30_000` (30 seconds).**

Key differences:
- `review` and `audit`: no `autoReleaseMs` — each Ash produces unique findings (non-fungible)
- `work` and `fix`: `autoReleaseMs` enabled — tasks are fungible (any worker can pick up a released task)
- `plan`: no `timeoutMs` — research runs until all tasks complete or stale detection intervenes
- `forge`: `staleWarnMs === autoReleaseMs` (5 min) — warn and release fire on the same tick (by design)

### Loop Parameter Derivation

When translating `waitForCompletion` to concrete execution:

```
maxIterations = ceil(timeoutMs / pollIntervalMs)
sleepSeconds  = pollIntervalMs / 1000
```

Example: mend with `timeoutMs: 900_000` and `pollIntervalMs: 30_000`:
- `maxIterations = 30`
- `sleepSeconds = 30`

Never use arbitrary iteration counts or sleep intervals.

## Stale Detection

Tasks that remain `in_progress` beyond `staleWarnMs` are flagged as stale.

```
for (const task of inProgress) {
  if (opts.autoReleaseMs && task.stale > opts.autoReleaseMs) {
    warn(`${opts.label}: task #${task.id} stalled — auto-releasing`)
    TaskUpdate({ taskId: task.id, owner: "", status: "pending" })
  } else if (task.stale > opts.staleWarnMs) {
    warn(`${opts.label}: task #${task.id} may be stalled`)
  }
}
```

### Behavior by Preset

| Preset | On stale warn | On auto-release threshold |
|--------|---------------|---------------------------|
| review, audit, debug | Log warning only | N/A (no auto-release) |
| work, fix | Log warning | Release task to pool (owner="", status="pending") |
| forge | Warn + release on same tick | Release enrichment task |

## Signal-Based Fast Completion

When `TaskCompleted` hooks write filesystem signal files, the monitor detects completion via filesystem checks (5-second interval) instead of 30-second API polling — reducing token cost to near-zero.

### Signal Directory Structure

```
tmp/.rune-signals/{teamName}/
  .expected           # Expected task count (written by orchestrator)
  .all-done           # Sentinel — all tasks completed (written by on-task-completed.sh)
  .readonly-active    # SEC-001 marker (review/audit only)
  inscription.json    # Output contract
  {task_id}.done      # Per-task completion signal
```

### Setup (Orchestrator Responsibility)

Before spawning agents, the orchestrator creates the signal directory:

```
const signalDir = `tmp/.rune-signals/${teamName}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(expectedTaskCount))
Write(`${signalDir}/inscription.json`, JSON.stringify({
  workflow: presetName,
  timestamp: timestamp,
  output_dir: outputDir,
  teammates: agentList
}))
```

### Dual-Path Detection

The fast path activates automatically when a signal directory exists:

```
const signalDir = `tmp/.rune-signals/${teamName}`
let useSignals = exists(signalDir) && exists(`${signalDir}/.expected`)

if (useSignals) {
  // FAST PATH: 5s filesystem checks
  while (true) {
    if (exists(`${signalDir}/.all-done`)) {
      const finalTasks = TaskList()  // One-time API call
      return { completed, incomplete: [], timedOut: false }
    }
    // Timeout check
    if (opts.timeoutMs && Date.now() - startTime > opts.timeoutMs) {
      return partial results
    }
    sleep(5_000)
  }
}
// FALLBACK: Phase 1 TaskList polling (30s interval)
```

### Performance

| Metric | Polling (Phase 1) | Signals (Phase 2) |
|--------|-------------------|-------------------|
| Check interval | 30s | 5s |
| Token cost per check | ~500 (TaskList API) | 0 (filesystem read) |
| Detection latency | ~15s average | ~2.5s average |
| Final TaskList call | Every check | Once on completion |

### Signal Cleanup

Signal directories are cleaned in Phase 7 (Cleanup):

```
rm -rf "tmp/.rune-signals/${teamName}"
```

Global cleanup via `/rune:rest`:

```
rm -rf tmp/.rune-signals/ 2>/dev/null
```

## Context-Critical Shutdown Detection

Three layers detect when context window pressure requires early team shutdown:

### Layer 1: Orchestrator Poll Check

The orchestrator checks for shutdown signals each poll cycle:

```
function checkShutdownSignal(sessionId) {
  const signalPath = `tmp/.rune-shutdown-signal-${sessionId}.json`
  try {
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "context_warning"
  } catch {
    return false
  }
}
```

### Layer 2: Signal File from Guard Hook

`guard-context-critical.sh` (CTX-GUARD-001) writes signal files at token thresholds:

| Threshold | Remaining | Action |
|-----------|-----------|--------|
| Caution | 40% | Advisory only |
| Warning | 35% | Writes `context_warning` signal |
| Critical | 25% | Hard DENY on TeamCreate/Agent + `force_shutdown` signal |

### Layer 3: Force Shutdown

At critical threshold, the guard hook blocks new agent spawning entirely:

```
function checkForceShutdown(sessionId) {
  const signalPath = `tmp/.rune-shutdown-signal-${sessionId}.json`
  try {
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "force_shutdown"
  } catch {
    return false
  }
}
```

When force_shutdown is detected, the orchestrator must immediately:
1. Stop spawning new agents
2. Send `shutdown_request` to all active teammates
3. Collect partial results from completed tasks
4. Run cleanup

## Stuck Worker Detection

Workers that exceed `max_runtime_minutes` (from talisman) are flagged for intervention.

```
// Per poll cycle, after TaskList
for (const task of inProgress) {
  const maxMinutes = talisman?.work?.max_runtime_minutes ?? 30
  const elapsedMinutes = task.stale / 60_000

  if (elapsedMinutes > maxMinutes) {
    warn(`Worker for task #${task.id} exceeded max runtime (${maxMinutes}min)`)
    // Send progress check to worker via SendMessage
    // If no response after next poll cycle, consider auto-release
  }
}
```

## Smart Reassignment

Reassigns overdue tasks to idle workers. Runs per poll cycle, BEFORE stuck worker detection. Gated by `work.reassignment.enabled` (default: `true`).

### Configuration

```yaml
# talisman.yml
work:
  reassignment:
    enabled: true
    multiplier: 2.0       # Threshold = multiplier * estimated_minutes
    grace_seconds: 60     # Grace period after threshold before reassignment
```

### Algorithm

```
const reassignConfig = readTalismanSection("work")?.reassignment
if (reassignConfig?.enabled !== false) {
  const multiplier = reassignConfig?.multiplier ?? 2.0
  const graceSeconds = reassignConfig?.grace_seconds ?? 60

  for (const task of inProgress) {
    const estimatedMin = task.metadata?.estimated_minutes ?? 5
    const elapsedMs = task.stale
    const thresholdMs = multiplier * estimatedMin * 60_000

    if (elapsedMs > thresholdMs + graceSeconds * 1000) {
      const reassignCount = task.metadata?.reassignment_count ?? 0
      if (reassignCount >= 2) {
        // Max 2 reassignments per task — escalate instead
        warn(`Task #${task.id} hit reassignment cap (2). Escalating.`)
        continue
      }

      // First time: send progress check (warning)
      if (!task.metadata?.reassignment_warned) {
        SendMessage(task.owner, "Progress check: are you blocked?")
        TaskUpdate({ taskId: task.id, metadata: { reassignment_warned: true } })
        continue
      }

      // Second time: actually reassign
      TaskUpdate({
        taskId: task.id,
        owner: "",
        status: "pending",
        metadata: { reassignment_count: reassignCount + 1, reassignment_warned: false }
      })
    }
  }
}
```

### Safeguards

- **Max 2 reassignments per task** — prevents infinite reassignment loops
- **Warning before reassignment** — worker gets one poll cycle to respond
- **Grace period** — `grace_seconds` buffer after threshold before action
- **Only for fungible presets** — work and fix presets (not review/audit/debug)

## Anti-Patterns

### NEVER: Sleep+Echo Monitoring

```
// WRONG — provides zero visibility into task progress
Bash("sleep 30 && echo poll check")
```

This pattern is blocked at runtime by `enforce-polling.sh` (POLL-001).

### ALWAYS: TaskList-Based Polling

```
// CORRECT — actual task status check
TaskList()   // Check status
sleep(30)    // Wait
TaskList()   // Check again
```

The correct sequence per cycle: `TaskList()` -> count completed -> check stale/timeout -> `sleep(pollIntervalMs / 1000)` -> repeat.

### NEVER: Arbitrary Poll Intervals

```
// WRONG — using made-up intervals
sleep(45)    // Not from config
sleep(60)    // Not from config
```

Always derive from config: `pollIntervalMs / 1000`. All presets use 30 seconds.

### NEVER: Raw Glob in Bash for Signal Checks

```
// WRONG — zsh NOMATCH failure when no signals exist
Bash("ls tmp/.rune-signals/rune-work-*/*.done")
```

Use `Glob()` tool for file discovery, then iterate resolved paths.

## Checkpoint Reporting

When `onCheckpoint` is provided, `waitForCompletion` emits structured progress reports at milestones (25%, 50%, 75%, 100%) rather than every poll cycle.

### Triggers

Checkpoints fire when either condition is met:
1. **Milestone crossing** — completed percentage crosses 25%, 50%, 75%, 100%
2. **Blocker detection** — a stalled task (> `staleWarnMs`) is detected after the last milestone

### Template

```markdown
## Checkpoint {N} — {label}
Progress: {completed}/{total} ({percentage}%)
Active: {in_progress task subjects}
Blockers: {stalled tasks, or omit if none}
Decision: {CONTINUE | INVESTIGATE | COMPLETE}
```

### Decision Values

| Decision | Condition | Action |
|----------|-----------|--------|
| CONTINUE | No blockers, progress normal | Keep polling |
| COMPLETE | All tasks finished | Return final results |
| INVESTIGATE | Stalled task detected | Log warning, check auto-release |

Currently only `work` preset uses `onCheckpoint`. Arc integration is planned.

## Cross-References

- [monitor-utility.md](../../roundtable-circle/references/monitor-utility.md) — Source of truth for waitForCompletion pseudocode
- [presets.md](presets.md) — Per-preset monitoring configuration
- [wave-scheduling.md](../../roundtable-circle/references/wave-scheduling.md) — Wave-aware monitoring
- [protocols.md](protocols.md) — Cleanup protocol after monitoring completes
