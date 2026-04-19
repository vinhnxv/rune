# Monitor Utility — Parameterized Polling for Agent Teams

> Shared polling utility used by all 7 Rune commands (`appraise`, `audit`, `strive`, `mend`, `devise`, `forge`, `arc`). Each command calls `waitForCompletion` with its own configuration instead of inlining a polling loop. ~147 lines of polling logic across 7 commands collapse into a single parameterized reference.

## Table of Contents

- [Function Signature](#function-signature)
- [Pseudocode](#pseudocode)
- [Checkpoint Reporting](#checkpoint-reporting)
- [Per-Command Configuration](#per-command-configuration)
- [Usage Example](#usage-example)
- [Notes](#notes)

## Function Signature

### Contract

| Field | Description |
|-------|-------------|
| **Inputs** | `teamName` (string) — active team name; `expectedCount` (number) — total tasks to monitor; `opts` (object) — per-command configuration (see table below, includes optional `onCheckpoint` callback) |
| **Outputs** | `{ completed: Task[], incomplete: Task[], timedOut: boolean }` |
| **Preconditions** | Team exists (`TeamCreate` already called), tasks already created via `TaskCreate` |
| **Error handling** | `TaskList()` errors propagate naturally (no retry in Phase 1). Timeout produces partial results, never throws. |

```
waitForCompletion(teamName, expectedCount, opts):
  opts.pollIntervalMs       // Polling interval (default: 30_000)
  opts.staleWarnMs          // Warn threshold for in_progress tasks (default: 300_000)
  opts.timeoutMs            // Total timeout — OPTIONAL (undefined = no timeout)
  opts.autoReleaseMs        // Auto-release stale tasks — OPTIONAL (undefined = no auto-release)
  opts.label                // Display label for log messages (e.g., "Review", "Work")
  opts.onCheckpoint         // Milestone callback — OPTIONAL (undefined = no checkpoint reporting)
```

## Pseudocode

```javascript
function waitForCompletion(teamName, expectedCount, opts) {
  const {
    pollIntervalMs = 30_000,
    staleWarnMs = 300_000,
    timeoutMs,                // undefined = skip timeout check
    autoReleaseMs,            // undefined = no auto-release
    label = "Monitor",
    onCheckpoint              // undefined = no checkpoint reporting
  } = opts

  const startTime = Date.now()
  const milestones = [25, 50, 75, 100]
  let lastMilestone = 0       // tracks highest milestone already reported
  let checkpointCount = 0
  const reportedBlockerIds = new Set()  // tracks stale task IDs already reported as blockers
  const taskStartTimes = {}   // taskId -> timestamp when first seen in_progress

  while (true) {
    const tasks = TaskList()
    const completed = tasks.filter(t => t.status === "completed")
    const inProgress = tasks.filter(t => t.status === "in_progress")

    // Derive task.stale: elapsed ms since task entered in_progress
    for (const t of inProgress) {
      if (!taskStartTimes[t.id]) taskStartTimes[t.id] = Date.now()
      t.stale = Date.now() - taskStartTimes[t.id]
    }
    // Clean up completed tasks from tracking maps
    for (const t of completed) {
      delete taskStartTimes[t.id]
      reportedBlockerIds.delete(t.id)
    }

    log(`${label} progress: ${completed.length}/${expectedCount} tasks`)

    // All done
    if (completed.length >= expectedCount) {
      // Fire 100% checkpoint if callback provided and not yet reported
      if (onCheckpoint && lastMilestone < 100) {
        checkpointCount++
        onCheckpoint({
          n: checkpointCount, label, completed: completed.length,
          total: expectedCount, percentage: 100,
          active: [], blockers: [], decision: "COMPLETE"
        })
      }
      return { completed, incomplete: [], timedOut: false }
    }

    // Checkpoint reporting (milestone-based, NOT every poll cycle)
    if (onCheckpoint) {
      const percentage = Math.floor((completed.length / expectedCount) * 100)
      const staleTasks = inProgress.filter(t => t.stale > staleWarnMs)
      const nextMilestone = milestones.find(m => m > lastMilestone && percentage >= m)
      const hasNewBlocker = staleTasks.some(t => !reportedBlockerIds.has(t.id))

      if (nextMilestone || hasNewBlocker) {
        checkpointCount++
        lastMilestone = nextMilestone || lastMilestone
        if (hasNewBlocker) staleTasks.forEach(t => reportedBlockerIds.add(t.id))
        const decision = staleTasks.length > 0 ? "INVESTIGATE" : "CONTINUE"
        onCheckpoint({
          n: checkpointCount,
          label,
          completed: completed.length,
          total: expectedCount,
          percentage,
          active: inProgress.map(t => t.subject),
          blockers: staleTasks.map(t => `#${t.id} ${t.subject} (stale >${Math.floor(t.stale / 60_000)}min)`),
          decision
        })
      }
    }

    // Stale detection
    for (const task of inProgress) {
      if (autoReleaseMs && task.stale > autoReleaseMs) {
        warn(`${label}: task #${task.id} stalled (>${autoReleaseMs / 60_000}min) — auto-releasing`)
        TaskUpdate({ taskId: task.id, owner: "", status: "pending" })
        delete taskStartTimes[task.id]
      } else if (task.stale > staleWarnMs) {
        warn(`${label}: task #${task.id} may be stalled (>${staleWarnMs / 60_000}min)`)
      }
    }

    // Stuck-teammate detection (activity file-based)
    // track-teammate-activity.sh (PostToolUse hook) writes epoch timestamps to
    // tmp/.rune-signals/{team}/.activity-{agent}. If an activity file is older
    // than teammate_stuck_threshold (talisman, default 180s / 3 min), the teammate
    // may be hung — warn the orchestrator.
    const stuckThreshold = talisman.teammate_stuck_threshold || 180  // seconds
    const activityDir = `tmp/.rune-signals/${teamName}`
    for (const task of inProgress) {
      const agentName = task.owner  // agent name from task assignment
      if (!agentName) continue
      const activityFile = `${activityDir}/.activity-${agentName}`
      if (exists(activityFile)) {
        const actMtime = stat_mtime(activityFile)  // Unix epoch
        const actAge = Math.floor(Date.now() / 1000) - actMtime
        if (actAge > stuckThreshold) {
          warn(`${label}: teammate ${agentName} (task #${task.id}) no tool activity for >${Math.floor(actAge / 60)}min — may be stuck`)
        }
      }
    }

    // Timeout check (only if timeoutMs is defined)
    if (timeoutMs !== undefined && Date.now() - startTime > timeoutMs) {
      warn(`${label} timeout reached (${timeoutMs / 60_000} min). Collecting partial results.`)
      // Final sweep
      const finalTasks = TaskList()
      return {
        completed: finalTasks.filter(t => t.status === "completed"),
        incomplete: finalTasks.filter(t => t.status !== "completed"),
        timedOut: true
      }
    }

    Bash(`sleep ${pollIntervalMs / 1000}`, { run_in_background: true })
    // Agent is notified when sleep completes, then loop continues
  }
}
```

## Checkpoint Reporting

When `onCheckpoint` is provided, `waitForCompletion` emits structured progress reports at significant milestones rather than every poll cycle. This gives the user visibility into long-running workflows without noise.

### Display Triggers

Checkpoints fire when **either** condition is met:
1. **Milestone crossing** — completed percentage crosses 25%, 50%, 75%, or 100%
2. **Blocker detection** — a stalled task (> `staleWarnMs`) is detected after the last milestone

Each milestone fires at most once. The 100% checkpoint fires on completion.

### Checkpoint Template

```markdown
## Checkpoint {N} — {workflow_label}
Progress: {completed}/{total} ({percentage}%)
Active: {in_progress task subjects}
Blockers: {stalled tasks > staleWarnMs, or omit if none}
Decision: {CONTINUE | INVESTIGATE | COMPLETE}
```

### Decision Values

| Decision | Condition | Action |
|----------|-----------|--------|
| `CONTINUE` | No blockers, progress normal | Keep polling |
| `COMPLETE` | All tasks finished successfully | Return final results |
| `INVESTIGATE` | Stalled task detected | Log warning, check if auto-release applies |

### Future Decision Values

The following values are planned but **not yet emitted** by the pseudocode:

| Decision | Condition | Planned Action |
|----------|-----------|----------------|
| `ADJUST` | > 75% complete, minor issues | Consider scope reduction |
| `ESCALATE` | Multiple stalls or repeated blocker | Alert user via `AskUserQuestion` |

### Callback Signature

The `onCheckpoint` callback receives a single object:

```
onCheckpoint({ n, label, completed, total, percentage, active, blockers, decision })
```

| Field | Type | Description |
|-------|------|-------------|
| `n` | number | Checkpoint sequence number (1-indexed) |
| `label` | string | Workflow label (e.g., "Work", "Review") |
| `completed` | number | Count of completed tasks |
| `total` | number | Total expected tasks |
| `percentage` | number | Integer percentage (0-100) |
| `active` | string[] | Subjects of in_progress tasks |
| `blockers` | string[] | Descriptions of stalled tasks (empty if none) |
| `decision` | string | One of: CONTINUE, COMPLETE, INVESTIGATE |

### Cross-References

- [Standing Orders](standing-orders.md) — SO-5 (Ember Overload) may trigger ESCALATE
- [Damage Control](../../rune-orchestration/references/damage-control.md) — DC-3 (Fading Ash) for stalled agent recovery
- [Risk Tiers](risk-tiers.md) — Tier 2+ tasks warrant closer checkpoint attention

## Per-Command Configuration

Each command passes its own `opts` to `waitForCompletion`:

| Command | `timeoutMs` | `staleWarnMs` | `autoReleaseMs` | `pollIntervalMs` | `label` | `onCheckpoint` |
|---------|-------------|---------------|-----------------|-------------------|---------|----------------|
| `appraise` (standard) | 600,000 (10 min) | 300,000 (5 min) | — | 30,000 (30s) | `"Review"` | — |
| `appraise` (shard reviewers) | 600,000 (10 min) | 300,000 (5 min) | — | 30,000 (30s) | `"Shard review (N shards)"` | — |
| `appraise` (cross-shard sentinel) | 180,000 (3 min) | 90,000 (90s) | — | 30,000 (30s) | `"Cross-shard analysis"` | — |
| `audit` | 900,000 (15 min) | 300,000 (5 min) | — | 30,000 (30s) | `"Audit"` | — |
| `strive` | 1,800,000 (30 min) | 300,000 (5 min) | 600,000 (10 min) | 30,000 (30s) | `"Work"` | Yes (milestone) |
| `mend` | 900,000 (15 min) ‡ | 300,000 (5 min) | 600,000 (10 min) | 30,000 (30s) | `"Mend"` | — |
| `devise` | 1,800,000 (30 min) | 300,000 (5 min) | — | 30,000 (30s) | `"Plan Research"` | — |
| `forge` | 1,200,000 (20 min) | 300,000 (5 min) | 300,000 (5 min)* | 30,000 (30s) | `"Forge"` | — |
| `arc` | Per-phase (varies) | 300,000 (5 min) | — | 30,000 (30s) | `"Arc: {phase}"` | Planned |

‡ **Mend timeout override**: When called from arc with `--timeout <ms>`, inner polling timeout is derived: `timeout - SETUP_BUDGET(5m) - MEND_EXTRA_BUDGET(3m)`, minimum 120,000ms. On arc retry rounds, this reduces from 15 min to ~5 min. See mend.md Flags.

**Key differences**:
- `appraise` and `audit` have no `autoReleaseMs` because each Ash produces unique findings that cannot be reclaimed by another Ash.
- `strive` and `mend` enable auto-release because their tasks are fungible (any worker can pick up a released task).
- `forge` enables auto-release (5 min) because enrichment tasks are reassignable. *When `staleWarnMs === autoReleaseMs` (as in forge), warn and release fire on the same poll tick — this is by design since forge's stale detection and release are a single action.
- `devise` has a 30-minute `timeoutMs` (1,800,000ms) — covers the longest research phase (external research + validation) with margin. Previously had no timeout, which risked indefinite hangs if a research agent stalled without triggering stale detection.
- `forge` has a 20-minute `timeoutMs` (`FORGE_TIMEOUT = 1_200_000` in forge.md) — enrichment sessions have a hard upper bound.
- `arc` uses `PHASE_TIMEOUTS` from its constants (see `arc SKILL.md`) which vary per phase. Phase outer timeout = inner polling timeout + `SETUP_BUDGET` (5 min) + optional `MEND_EXTRA_BUDGET` (3 min). The inner timeout is the real enforcement — `checkArcTimeout()` only runs between phases.
- **Signal-path compatibility**: When the Phase 2 fast path is active, `onCheckpoint` is not evaluated. `autoReleaseMs` is now supported via a hybrid check: when elapsed time exceeds the threshold, the fast path issues ONE `TaskList()` call to detect and reassign stalled tasks — preserving near-zero token cost while recovering stalled workers. Commands without these features (`review`, `audit`) behave identically on either path.

### Wave-Aware Monitoring

When `depth=deep` activates wave scheduling, `waitForCompletion` is called once per wave with that wave's timeout allocation (from `distributeTimeouts`). The orchestrator manages the wave loop externally — `waitForCompletion` itself is unchanged.

**Per-wave signal directory:** Signal files from completed waves are cleaned up between waves. The shared directory name stays the same across all waves — no per-wave suffix is used. Signal files are cleared, `.expected` is rewritten with the new wave's agent count, and done files use the pattern `{task_id}.done` (matching on-task-completed.sh runtime).

```javascript
// Wave-aware signal setup (between waves)
Bash(`find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(wave.agents.length))
// .readonly-active marker persists across waves (review/audit teams stay read-only)
```

**Timeout per wave:** Each wave receives its allocated timeout from `distributeTimeouts()`, plus any carry-forward from prior waves that completed early. See [wave-scheduling.md](wave-scheduling.md) for the carry-forward algorithm.

## Usage Example

```javascript
// In appraise/SKILL.md Phase 4:
const result = waitForCompletion(teamName, ashCount, {
  timeoutMs: 600_000,
  staleWarnMs: 300_000,
  pollIntervalMs: 30_000,
  label: "Review"
})

if (result.timedOut) {
  log(`Review completed with partial results: ${result.completed.length}/${ashCount} Ashes`)
}

// In devise/SKILL.md Monitor Research (30 min timeout):
const result = waitForCompletion(teamName, researchTaskCount, {
  timeoutMs: 1_800_000,
  staleWarnMs: 300_000,
  pollIntervalMs: 30_000,
  label: "Plan Research"
})

// In strive/SKILL.md Phase 3 (with auto-release + optional checkpoint reporting):
const result = waitForCompletion(teamName, taskCount, {
  timeoutMs: 1_800_000,
  staleWarnMs: 300_000,
  autoReleaseMs: 600_000,
  pollIntervalMs: 30_000,
  label: "Work",
  // onCheckpoint is optional — omit to disable milestone reporting
  onCheckpoint: (cp) => {
    log(`## Checkpoint ${cp.n} — ${cp.label}`)
    log(`Progress: ${cp.completed}/${cp.total} (${cp.percentage}%)`)
    log(`Active: ${cp.active.join(", ") || "none"}`)
    if (cp.blockers.length) log(`Blockers: ${cp.blockers.join(", ")}`)
    log(`Decision: ${cp.decision}`)
  }
})
```

## Notes

- **Timeout is optional**: When `timeoutMs` is `undefined`, the loop runs until all tasks complete. All current commands now define a `timeoutMs` as a safety net against indefinite hangs.
- **Auto-release is optional**: When `autoReleaseMs` is `undefined`, stale tasks only produce warnings. This matches `appraise` and `audit` where Ash findings are non-fungible.
- **No retry logic**: `TaskList()` errors propagate naturally. Retry logic is out of scope for Phase 1.
- **Final sweep**: On timeout, a final `TaskList()` call captures any tasks that completed during the last poll interval. This matches the existing pattern in `appraise.md`, `audit.md`, `strive.md`, and `mend.md`.
- **Arc per-phase budgets**: Arc does not call `waitForCompletion` directly with a single timeout. Instead, each delegated phase (strive, appraise, mend, audit) uses its own inner timeout. Arc wraps these with a safety-net phase timeout (`PHASE_TIMEOUTS`) plus the global `calculateDynamicTimeout(tier)` ceiling (162-240 min depending on convergence tier; see arc SKILL.md).
- **Checkpoint reporting is optional**: When `onCheckpoint` is `undefined`, no milestone tracking occurs. Existing callers without `onCheckpoint` get identical behavior. Currently used by `strive`. Arc integration is planned but not yet wired.
- **zsh reserved variable names**: When translating pseudocode to Bash commands, **NEVER use `status` as a shell variable name**. In zsh (macOS default shell), `$status` is a read-only built-in (equivalent to `$?`). Assigning to it causes `(eval):1: read-only variable: status`. Use alternative names like `task_status`, `tstat`, or `completion_status` instead. Other zsh reserved names to avoid: `pipestatus`, `ERRNO`, `signals`.
- **Polling loop parameters MUST match config**: When translating `waitForCompletion` to Bash, the loop parameters MUST be derived from the configured values — not invented. Use the formula: `maxIterations = ceil(timeoutMs / pollIntervalMs)` and `sleepSeconds = pollIntervalMs / 1000`. For example, mend with `timeoutMs: 900_000` and `pollIntervalMs: 30_000` → `maxIterations=30, sleep 30`. Never use arbitrary iteration counts or sleep intervals that don't match the per-command configuration table above.
- **Polling enforcement hook**: `enforce-polling.sh` (POLL-001) blocks `sleep+echo` anti-patterns at runtime during active Rune workflows. The `polling-guard` skill provides background knowledge for the correct monitoring loop pattern. Together, these form a 3-layer enforcement pyramid (hook + skill + text warnings) that prevents the LLM from improvising sleep-based monitoring proxies.
- **Stuck-teammate detection**: The polling loop checks activity files written by `track-teammate-activity.sh` (PostToolUse:Bash|Write|Edit hook). Each teammate's last tool call timestamp is written atomically to `tmp/.rune-signals/{team}/.activity-{agent}`. If the file's mtime exceeds `teammate_stuck_threshold` (talisman config, default 180s / 3 min), the orchestrator warns about the potentially stuck teammate. This complements task-level stale detection (`staleWarnMs`) with tool-level liveness — a task may not be stale by time, but its agent may have stopped making tool calls.
- **`estimated_minutes` task metadata**: Set by `estimateTaskMinutes()` during `TaskCreate` in Phase 0 (task decomposition). Each task receives an `estimated_minutes` field in its metadata based on complexity heuristics (file count, test presence, refactoring scope). This value is consumed by Phase 3 smart reassignment to determine when a task has exceeded its expected duration (`elapsed > estimated_minutes * reassignment.multiplier`), and by `computeExpectedWaveTime()` to calculate per-wave wall-clock estimates (F12 fix). Default: `5` minutes when not set.

## Phase 2: Event-Driven Fast Path

> Added in Phase 2 (BRIDGE). When `TaskCompleted` hooks write filesystem signal files, the monitor can detect completion via a 5-second filesystem check instead of a 30-second `TaskList()` API poll — reducing token cost to near-zero per monitoring cycle (~99.8% reduction). The fast path activates automatically when a signal directory exists; otherwise, the Phase 1 polling fallback runs unchanged.

### How It Works

```text
TaskCompleted hook fires
    ↓
scripts/on-task-completed.sh writes signal file to tmp/.rune-signals/{team}/
    ↓
Monitor checks signal files (5s interval, filesystem read — near-zero token cost)
    ↓
All signals present (.all-done sentinel) → proceed
    ↓
(Fallback: if no signal directory exists → Phase 1 TaskList polling at 30s)
```

### Signal Directory Setup (Orchestrator Responsibility)

Before spawning Ashes, the orchestrator (Tarnished) must create the signal directory and expected-count file. If this setup is skipped, the monitor automatically falls back to Phase 1 polling.

```javascript
// Pseudocode — added to each command BEFORE spawning Ashes
const signalDir = `tmp/.rune-signals/${teamName}`

// Clear stale signals from any crashed previous run
// NOTE: Uses mkdir -p + find -delete (not rm -rf + mkdir) to avoid TOCTOU race
// where a symlink could be created between remove and recreate.
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)

// Write expected task count — read by on-task-completed.sh
Write(`${signalDir}/.expected`, String(expectedTaskCount))

// Write inscription — read by on-teammate-idle.sh for quality gates
Write(`${signalDir}/inscription.json`, JSON.stringify({
  workflow: "rune-review",  // or rune-work, rune-plan, etc.
  timestamp: timestamp,
  output_dir: `tmp/reviews/${identifier}/`,
  teammates: [
    { name: "forge-warden", output_file: "forge-warden.md" },
    // ... per command configuration
  ]
}))

// SEC-001: Write readonly marker for review/audit teams.
// This marker is checked by enforce-readonly.sh (PreToolUse hook) to block
// Write/Edit/Bash/NotebookEdit for subagents when a review/audit team is active.
// Only review and audit workflows write this marker — work/mend/plan do NOT.
if (workflow === "rune-review" || workflow === "rune-audit") {
  Write(`${signalDir}/.readonly-active`, "active")
}
```

### 3-Signal Fusion (durable-first completion detection, v2.58.0+)

`countCompletedAgents()` is the durable-first counter used by `waitForCompletion`. It fuses THREE sources — any one reaching `expectedCount` is success:

| Priority | Source | Location | Lifetime |
|----------|--------|----------|----------|
| S1 | Arc-scoped sentinel files (durable, HIGHEST) | `tmp/arc/{arcId}/.done/*.done` | Survives `TeamDelete` |
| S2 | Phase-specific artifact files (durable) | e.g. `tmp/arc/{arcId}/qa/{phase}-verdict.json` | Survives `TeamDelete` |
| S3 | Team-scoped signal files (ephemeral, fast-path) | `tmp/.rune-signals/{teamName}/*.done` | Deleted with team |

**Why durable-first**: `postPhaseCleanup()` runs `TeamDelete` which deletes `tmp/.rune-signals/{teamName}/` between the agent's final `TaskUpdate(completed)` and the leader's next poll. Team-scoped signals (S3) are ephemeral from the leader's perspective. Arc-scoped artifacts (S1, S2) are durable and survive team teardown — they are the authoritative source of truth.

```javascript
// Count completed agents via 3-signal fusion.
// Returns the MAX across all three sources — any one reaching expectedCount = success.
// Backward compat: when arcId is not provided, falls back to team-signal-only (S3).
function countCompletedAgents(teamName, arcId, expectedAgents) {
  // S1: arc-scoped durable sentinels (highest priority — survives TeamDelete)
  let sentinelCount = 0
  if (arcId) {
    const sentinelDir = `tmp/arc/${arcId}/.done`
    sentinelCount = exists(sentinelDir) ? Glob(`${sentinelDir}/*.done`).length : 0
  }

  // S2: direct artifact presence for known phases (e.g., QA verdict, TOME, inspect report)
  // Only meaningful when expectedAgents includes phase-level artifact hints.
  let artifactCount = 0
  if (arcId && Array.isArray(expectedAgents)) {
    artifactCount = countExpectedArtifacts(arcId, expectedAgents)
  }

  // S3: team-scoped ephemeral signals (legacy fast-path — may be deleted with team)
  const teamSignalDir = `tmp/.rune-signals/${teamName}`
  const teamSignalCount = exists(teamSignalDir)
    ? Glob(`${teamSignalDir}/*.done`).length
    : 0

  // Return MAX — any single source at expectedCount is sufficient evidence
  return Math.max(sentinelCount, artifactCount, teamSignalCount)
}

// countExpectedArtifacts: inspect known phase artifact locations.
// Returns a count of distinct artifacts that exist. Agents are responsible for
// writing their artifact to a canonical location per the Completion Contract.
function countExpectedArtifacts(arcId, expectedAgents) {
  const qaArtifacts = Glob(`tmp/arc/${arcId}/qa/*-verdict.json`).length
  const findings = Glob(`tmp/arc/${arcId}/*-findings.md`).length
  const reviews = Glob(`tmp/arc/${arcId}/reviews/*-verdict.md`).length
  return qaArtifacts + findings + reviews
}
```

**Contract with agents**: phase agents MUST write a sentinel to `tmp/arc/{arcId}/.done/{agent-name}.done` with a one-line JSON payload:
```json
{"agent":"work-qa-verifier","status":"completed","verdict_path":"tmp/arc/{id}/qa/work-verdict.json","timestamp":"<ISO8601>"}
```
See `arc-phase-qa-gate.md` Completion Contract section for the full agent-side obligation.

### Dual-Path Pseudocode

The `waitForCompletion` function from Phase 1 gains a dual-path upgrade. The signal path is chosen when `tmp/.rune-signals/{teamName}/` exists; otherwise the existing polling path runs unchanged.

> **3-Signal Fusion integration**: Callers that pass `arcId` and `expectedAgents` in `opts` get durable-first detection via `countCompletedAgents()`. When `opts.arcId` is absent, the function falls back to current team-signal-only behaviour (backward compat).

```javascript
function waitForCompletion(teamName, expectedCount, opts) {
  const {
    pollIntervalMs = 30_000,
    staleWarnMs = 300_000,
    timeoutMs,
    autoReleaseMs,
    label = "Monitor",
    onCheckpoint
  } = opts

  const startTime = Date.now()
  const signalDir = `tmp/.rune-signals/${teamName}`
  let useSignals = exists(signalDir) && exists(`${signalDir}/.expected`)

  if (useSignals) {
    // ═══ FAST PATH: Filesystem signals (5s interval, near-zero token cost) ═══
    // Token cost per check: 0 (filesystem existence check, not API call)
    // Final TaskList() call on completion: ~100 tokens (one-time)
    //
    // Known limitation (Phase 2 BRIDGE): The fast path currently omits:
    //   - Stale detection (no taskStartTimes tracking or staleWarnMs checks)
    //   - Checkpoint reporting (no onCheckpoint / milestone callbacks)
    // These features only run in the Phase 1 polling fallback.
    // Phase 3 will unify both paths so stale detection and checkpoint
    // reporting work in event-driven mode as well.
    //
    // HYBRID autoReleaseMs (v2.5.0): When autoReleaseMs is configured AND
    // elapsed time exceeds the threshold, the fast path falls back to ONE
    // TaskList() call per cycle to check for stale in-progress tasks needing
    // reassignment. This preserves the near-zero token cost of signal-based
    // monitoring while recovering stalled tasks in work/mend/forge workflows.
    // Commands unaffected: review, audit (no autoRelease/checkpoint configured)
    log(`${label}: Signal directory detected — event-driven monitoring (5s interval)`)
    let iteration = 0

    while (true) {
      iteration++

      // Check .all-done sentinel (written atomically by on-task-completed.sh)
      if (exists(`${signalDir}/.all-done`)) {
        let meta
        try {
          meta = JSON.parse(Read(`${signalDir}/.all-done`))
        } catch (err) {
          warn(`${label}: .all-done file corrupted, falling back to TaskList polling`)
          break  // Exit fast-path loop — falls through to Phase 1 polling below
        }
        log(`${label}: All ${meta.total} signals received at ${meta.completed_at}`)
        const finalTasks = TaskList()
        return {
          completed: finalTasks.filter(t => t.status === "completed"),
          incomplete: finalTasks.filter(t => t.status !== "completed"),
          timedOut: false
        }
      }

      // Timeout check
      if (timeoutMs !== undefined && Date.now() - startTime > timeoutMs) {
        const doneCount = Glob(`${signalDir}/*.done`).length
        warn(`${label}: Timeout after ${timeoutMs / 60_000} min. ${doneCount}/${expectedCount} signals received.`)
        const finalTasks = TaskList()
        return {
          completed: finalTasks.filter(t => t.status === "completed"),
          incomplete: finalTasks.filter(t => t.status !== "completed"),
          timedOut: true
        }
      }

      // Hybrid autoReleaseMs check (v2.5.0): when autoReleaseMs is configured
      // and elapsed time exceeds the threshold, issue ONE TaskList() call to
      // detect and reassign stale in-progress tasks. This adds ~100 tokens
      // per triggered check (not every cycle) while preserving signal-based
      // near-zero cost for normal operation.
      if (autoReleaseMs && Date.now() - startTime > autoReleaseMs) {
        const tasks = TaskList()
        const inProgress = tasks.filter(t => t.status === "in_progress")
        for (const task of inProgress) {
          if (!taskStartTimes[task.id]) taskStartTimes[task.id] = Date.now()
          const elapsed = Date.now() - taskStartTimes[task.id]
          if (elapsed > autoReleaseMs) {
            warn(`${label}: task #${task.id} stalled (>${autoReleaseMs / 60_000}min) — auto-releasing`)
            TaskUpdate({ taskId: task.id, owner: "", status: "pending" })
            delete taskStartTimes[task.id]
          }
        }
      }

      // Progress logging every 3rd check (~15s), plus first iteration
      if (iteration === 1 || iteration % 3 === 0) {
        const doneCount = Glob(`${signalDir}/*.done`).length
        log(`${label}: Progress: ${doneCount}/${expectedCount} tasks signaled`)
      }

      sleep(5_000)  // 5s — filesystem check, not API call
    }

    // Fast-path loop exited via break (corrupted .all-done) — fall through to polling
    log(`${label}: Fast path exited — switching to Phase 1 polling fallback`)
  }

  // ═══ FALLBACK: Phase 1 polling (30s interval, TaskList API calls) ═══
  // Reached when: (a) no signal directory exists, or (b) fast-path broke out due to error
  log(`${label}: TaskList polling active (${pollIntervalMs / 1000}s interval)`)
  // ... (existing Phase 1 pseudocode from above runs unchanged) ...
}
```

### Security Considerations (Phase 2)

When implementing the signal-based fast path:
1. **Path validation**: Canonicalize CWD via `realpath` before constructing signal paths
2. **Atomic writes**: Use `mv -n` (noclobber) to prevent symlink attacks
3. **Input sanitization**: Validate team name matches `^[a-zA-Z0-9_-]+$`

See `scripts/on-task-completed.sh` for reference implementation.

### Performance Characteristics

| Metric | Phase 1 (Polling) | Phase 2 (Signals) |
|--------|-------------------|-------------------|
| Check interval | 30s | 5s |
| Token cost per check | ~500 (TaskList API) | 0 (filesystem read) |
| Average detection latency | ~15s | ~2.5s |
| Final TaskList call | Every check | Once on completion (~100 tokens) |
| Scales with agent count | O(N) per check | O(1) per check (single `.all-done` existence check) |

### Signal Cleanup

Signal directories are cleaned:
1. **Per-workflow:** In Phase 7 (Cleanup), after `TeamDelete`:
   ```bash
   rm -rf "tmp/.rune-signals/${teamName}"
   ```
2. **Global:** Via `/rune:rest`:
   ```bash
   rm -rf tmp/.rune-signals/ 2>/dev/null
   ```

### Concurrency Notes

- **Atomic writes**: Hook script uses `tmp + mv` pattern — monitor never sees incomplete signal files
- **TOCTOU in `.all-done`**: SAFE — sentinel is written atomically by the hook, not computed by the monitor
- **Concurrent hook invocations**: SAFE — each writes to a unique `{task_id}.done` file (no shared state)
- **Multiple concurrent workflows**: SAFE — team-name-scoped signal directories prevent cross-workflow interference

### Stability Trigger

Phase 2 was activated in v1.23.0. Stability is tracked across releases (assessed manually via CHANGELOG.md regression entries at release time) — 3+ consecutive releases with zero hook-related regressions confirms production readiness.

## Seal Convention

Every Ash MUST emit a `<seal>TASK_NAME_COMPLETE</seal>` tag as the **last line** of its output. This enables deterministic completion detection by `on-teammate-idle.sh` and the monitor utility.

### Canonical Seal Tags

| Agent Type | Seal Tag |
|------------|----------|
| Forge agents (enrichment) | `<seal>ENRICHMENT_COMPLETE</seal>` |
| Review agents (Ashes) | `<seal>REVIEW_COMPLETE</seal>` |

### Detection

The `on-teammate-idle.sh` hook checks for seals using:

```bash
grep -qE "^SEAL:|<seal>[A-Z_]+</seal>"
```

Only the **last** seal tag in the output is authoritative — earlier tags from intermediate steps are ignored.

### Backward Compatibility

The bare `<seal>TAG</seal>` format is the canonical form. The legacy `SEAL:` prefix format is still recognized for backward compatibility. New agents should always use the `<seal>` tag form.

## References

- [Inscription Schema](inscription-schema.md) — Output contract for monitored tasks
- [Task Templates](task-templates.md) — Task creation patterns used before monitoring
- [Wave Scheduling](wave-scheduling.md) — Wave selection, timeout distribution, carry-forward budget
