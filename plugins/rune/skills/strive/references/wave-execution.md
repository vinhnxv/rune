# Wave-Based Execution (Phase 2)

## Wave Capacity Calculation

Wave capacity determines how many tasks run per wave. Derived from talisman config:

```javascript
const TASKS_PER_WORKER = talisman?.work?.tasks_per_worker ?? 3
const maxWorkers = talisman?.work?.max_workers ?? 3
const waveCapacity = Math.max(1, (maxWorkers ?? 3) * (TASKS_PER_WORKER ?? 3))  // e.g. 3 workers * 3 = 9; Math.max(1,...) guards against zero division on next line
const totalWaves = Math.ceil(totalTasks / waveCapacity)
```

The last wave may contain fewer tasks than `waveCapacity` (remainder from the division). The `slice()` call handles this naturally since it clamps to array bounds.

## Adaptive Wave Sizing

Instead of using a static `workerCount = maxWorkers` for every wave, the orchestrator dynamically computes the number of workers per wave based on remaining tasks and feedback from prior waves.

**Gate**: Adaptive wave sizing is enabled by default and can be disabled via `readTalismanSection("work")?.adaptive_wave?.enabled !== false`.

### `computeWaveWorkerCount(remainingTasks, maxWorkers, tasksPerWorker, prevWaveMetrics, talisman)`

<!--
  Worked example — Adaptive Wave Sizing Feedback Loop:

  Setup: maxWorkers=3, tasksPerWorker=3, failureThreshold=0.3, speedThreshold=0.5, minWorkers=1

  Wave 1 (first wave, prevWaveMetrics=null):
    - baseCount = min(3, ceil(9/3)) = min(3, 3) = 3
    - prevWaveMetrics is null → skip feedback adjustment
    - adjustedCount = 3
    - finalCount = clamp(3, [1, 3]) = 3           → spawn 3 workers
    - Wave 1 result: 1 of 3 tasks completed (failureRate=0.67, completionRatio=0.33)

  Wave 2 (prevWaveMetrics = { failureRate: 0.67, completionRatio: 0.33 }):
    - baseCount = min(3, ceil(6/3)) = min(3, 2) = 2
    - failureRate 0.67 > failureThreshold 0.30 → shrink: adjustedCount = 2 - 1 = 1
    - finalCount = clamp(1, [1, 3]) = 1           → spawn 1 worker (reduced due to failures)
    - Wave 2 result: 1 of 1 tasks completed (failureRate=0.0, completionRatio=1.0)

  Wave 3 (prevWaveMetrics = { failureRate: 0.0, completionRatio: 1.0 }):
    - baseCount = min(3, ceil(5/3)) = min(3, 2) = 2
    - failureRate 0.0 not > 0.3; completionRatio 1.0 not < 0.5 → no adjustment
    - finalCount = clamp(2, [1, 3]) = 2           → spawn 2 workers

  Key insight: per-wave metrics (collected from waveTasks after each wave via collectWaveMetrics)
  are NOT aggregated across waves. Each wave's prevWaveMetrics reflects only the immediately
  preceding wave, enabling fast adaptation to transient failures or slowdowns.
-->

```javascript
function computeWaveWorkerCount(remainingTasks, maxWorkers, tasksPerWorker, prevWaveMetrics, talisman) {
  const adaptiveConfig = readTalismanSection("work")?.adaptive_wave ?? {}
  if (adaptiveConfig.enabled === false) {
    return maxWorkers  // Disabled — fall back to static sizing
  }

  const failureThreshold = adaptiveConfig.failure_threshold ?? 0.3
  const speedThreshold = adaptiveConfig.speed_threshold ?? 0.5
  const minWorkers = adaptiveConfig.min_workers ?? 1

  // Base count: only as many workers as needed for remaining tasks
  let baseCount = Math.min(maxWorkers, Math.ceil(remainingTasks / tasksPerWorker))

  // Feedback loop: adjust based on previous wave performance
  // Explicit null/undefined guard — prevWaveMetrics is null on the first wave
  let adjustedCount = baseCount
  if (prevWaveMetrics !== null && prevWaveMetrics !== undefined) {
    if (prevWaveMetrics.failureRate > failureThreshold) {
      // High failure rate — shrink by 1 to reduce contention/resource pressure
      adjustedCount = baseCount - 1
      log(`WAVE-ADAPT: Shrinking workers by 1 (failureRate=${prevWaveMetrics.failureRate.toFixed(2)} > ${failureThreshold})`)
    } else if (prevWaveMetrics.completionRatio < speedThreshold) {
      // Low completion ratio — grow by 1 to increase parallelism
      adjustedCount = baseCount + 1
      log(`WAVE-ADAPT: Growing workers by 1 (completionRatio=${prevWaveMetrics.completionRatio.toFixed(2)} < ${speedThreshold})`)
    }
  }

  // Clamp to [minWorkers, maxWorkers]
  const prevAdjusted = adjustedCount
  const finalCount = Math.max(minWorkers, Math.min(maxWorkers, adjustedCount))
  if (finalCount !== prevAdjusted) {
    log(`WAVE-ADAPT: workerCount clamped from ${prevAdjusted} to ${finalCount} (min=${minWorkers}, max=${maxWorkers})`)
  }
  log(`WAVE-ADAPT: workerCount=${finalCount} (base=${baseCount}, remaining=${remainingTasks})`)
  return finalCount
}
```

### `collectWaveMetrics(waveTasks)`

Called after each wave completes to gather performance data for the feedback loop.

```javascript
function collectWaveMetrics(waveTasks) {
  // Guard: return zeroed metrics if waveTasks is null/undefined/empty to prevent NaN propagation
  if (!waveTasks || waveTasks.length === 0) {
    return { totalTasks: 0, completedCount: 0, failedCount: 0, failureRate: 0, completionRatio: 1 }
  }

  const completed = waveTasks.filter(t => t.status === "completed")
  const failed = waveTasks.filter(t => t.status !== "completed")

  const metrics = {
    totalTasks: waveTasks.length,
    completedCount: completed.length,
    failedCount: failed.length,
    failureRate: waveTasks.length > 0 ? failed.length / waveTasks.length : 0,
    completionRatio: waveTasks.length > 0 ? completed.length / waveTasks.length : 1,
  }

  log(`WAVE-METRICS[]: tasks=${metrics.totalTasks} completed=${metrics.completedCount} failed=${metrics.failedCount} failureRate=${metrics.failureRate.toFixed(2)} completionRatio=${metrics.completionRatio.toFixed(2)}`)
  return metrics
}
```

### Circuit Breaker (F6)

If 3 consecutive waves have a 100% failure rate (`failureRate === 1.0`), the orchestrator aborts the wave loop to prevent infinite retry loops on systemic failures.

```javascript
let consecutiveFullFailures = 0

// Inside wave loop, after collectWaveMetrics:
if (waveMetrics.failureRate === 1.0) {
  consecutiveFullFailures++
  if (consecutiveFullFailures >= 3) {
    warn(`WAVE-ADAPT: Circuit breaker tripped — 3 consecutive 100%-failure waves. Aborting wave loop.`)
    break  // Exit wave loop, proceed to Phase 4 cleanup
  }
} else {
  consecutiveFullFailures = 0  // Reset on any partial success
}
```

### Expected Wave Time (F12 Fix)

`expectedWaveTime` should be calculated as the **per-worker task sum** (sum of estimated times for tasks assigned to each worker), not the max of all tasks across all workers. This reflects the actual wall-clock time of a wave, which is bounded by the slowest worker's total workload.

```javascript
// CORRECT: Per-worker task sum (wall-clock = slowest worker)
function computeExpectedWaveTime(waveTasks, workerCount) {
  const workerLoads = Array.from({ length: workerCount }, () => 0)
  for (let i = 0; i < waveTasks.length; i++) {
    const workerIdx = i % workerCount
    workerLoads[workerIdx] += waveTasks[i].estimated_minutes ?? 5
  }
  return Math.max(...workerLoads)  // Slowest worker determines wave time
}

// WRONG (F12): max of ALL tasks (ignores parallelism)
// const expectedWaveTime = Math.max(...waveTasks.map(t => t.estimated_minutes ?? 5))

// NOTE: expectedWaveTime is computed but currently has no downstream consumer.
// Consider wiring to timeout allocation (e.g. timeoutMs = expectedWaveTime * 60_000 * 1.5)
// or removing to avoid maintaining dead logic.
```

## Execution Loop

When `totalWaves > 1`, workers are spawned per-wave with bounded task assignments. Each wave:
1. Slice tasks for this wave from the priority-ordered list
2. Distribute tasks across workers via `TaskUpdate({ owner })`
3. Spawn fresh workers (named `rune-smith-w{wave}-{idx}`)
4. Monitor this wave via `waitForCompletion` with `taskFilter`
5. Shutdown workers after wave completes
6. Apply commits via commit broker
7. Proceed to next wave

**Single-wave optimization**: When `totalWaves === 1`, all tasks are assigned upfront and the existing behavior applies (no wave overhead).

```javascript
// Guard: skip wave loop entirely if no tasks
if (priorityOrderedTasks.length === 0) {
  // No tasks to execute — proceed to Phase 4 (commit/cleanup)
  return
}

// Adaptive wave sizing state
let prevWaveMetrics = null
let consecutiveFullFailures = 0

// Track all spawned worker names (including wave-based names) for Phase 6 fallback cleanup.
// When config.json dynamic discovery fails, this array ensures wave-named workers
// (e.g., rune-smith-w0-1, rune-smith-w1-2) are included in shutdown — not just base names.
const spawnedWorkerNames = []

// Wave loop (Phase 2: Summon + Phase 3: Monitor)
for (let wave = 0; wave < totalWaves; wave++) {
  const waveStart = wave * waveCapacity
  const waveTasks = priorityOrderedTasks.slice(waveStart, waveStart + waveCapacity)
  const remainingTasks = priorityOrderedTasks.length - waveStart

  // Adaptive worker count (replaces static workerCount = maxWorkers)
  const workerCount = computeWaveWorkerCount(
    remainingTasks, maxWorkers, TASKS_PER_WORKER, prevWaveMetrics, talisman
  )

  // Expected wave time (F12 fix: per-worker task sum, not max of all tasks)
  const expectedWaveTime = computeExpectedWaveTime(waveTasks, workerCount)

  // Distribute tasks to workers for this wave
  for (let i = 0; i < waveTasks.length; i++) {
    const workerIdx = i % workerCount
    const workerName = totalWaves === 1
      ? `rune-smith-${workerIdx + 1}`
      : `rune-smith-w${wave}-${workerIdx + 1}`
    TaskUpdate({ taskId: waveTasks[i].id, owner: workerName })
  }

  // Spawn fresh workers for this wave
  // Workers receive pre-assigned tasks (no dynamic claiming)
  // See worker-prompts.md for wave-aware prompt template

  // Per-worker artifact tracking (non-blocking — skip if library unavailable)
  // Records each worker's initial system prompt as input.md for debugging/inspection
  for (let i = 0; i < workerCount; i++) {
    const workerName = totalWaves === 1
      ? `rune-smith-${i + 1}`
      : `rune-smith-w${wave}-${i + 1}`
    spawnedWorkerNames.push(workerName)
    try {
      const _wkRunDir = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/run-artifacts.sh 2>/dev/null && type rune_artifact_init &>/dev/null && rune_artifact_init "work" "${timestamp}" "${workerName}" "${teamName}"`)?.trim() || null
      if (_wkRunDir) {
        Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/run-artifacts.sh 2>/dev/null && rune_artifact_write_input "${_wkRunDir}" "Worker system prompt for ${workerName} (see worker-prompts.md)"`)
      }
    } catch (e) { /* artifact tracking is non-blocking */ }
  }

  // Monitor this wave
  waitForCompletion(teamName, waveTasks.length, {
    timeoutMs: totalWaves === 1 ? 1_800_000 : 600_000,  // 30 min single / 10 min per wave
    staleWarnMs: 300_000,
    pollIntervalMs: 30_000,
    label: `Work wave ${wave + 1}/${totalWaves}`,
    taskFilter: waveTasks.map(t => t.id)
  })

  // Collect wave metrics for adaptive sizing feedback loop
  prevWaveMetrics = collectWaveMetrics(waveTasks)

  // Circuit breaker (F6): abort after 3 consecutive 100%-failure waves
  if (prevWaveMetrics.failureRate === 1.0) {
    consecutiveFullFailures++
    if (consecutiveFullFailures >= 3) {
      warn(`WAVE-ADAPT: Circuit breaker tripped — 3 consecutive 100%-failure waves. Aborting wave loop.`)
      break  // Exit wave loop, proceed to Phase 4 cleanup
    }
  } else {
    consecutiveFullFailures = 0  // Reset on any partial success
  }

  // Apply commits for this wave via commit broker
  commitBroker(waveTasks)

  // Shutdown wave workers before next wave
  if (wave < totalWaves - 1) {
    shutdownWaveWorkers(wave)
  }
}
```

## Security

**SEC-002**: Sanitize plan content before interpolation into worker prompts using `sanitizePlanContent()` (strips HTML comments, code fences, image/link injection, markdown headings, Truthbinding markers, YAML frontmatter, inline HTML tags, and truncates to 8000 chars).

**Non-goals extraction (v1.57.0+)**: Before summoning workers, extract `non_goals` from plan YAML frontmatter and present in worker prompts as nonce-bounded data blocks.

## Worktree Mode: Wave-Based Worker Spawning

When `worktreeMode === true`, workers are spawned per-wave instead of all at once. Each worker gets `isolation: "worktree"`. Workers commit directly (one commit per task) and store their branch in task metadata. Do NOT push. Do NOT merge. The Tarnished handles merging via the merge broker.

See [worktree-merge.md](worktree-merge.md) for the merge broker called between waves.
