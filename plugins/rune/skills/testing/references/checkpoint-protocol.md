# Checkpoint/Resume Protocol — Extended Tier

Defines the checkpoint format, atomic write protocol, heartbeat liveness, and resume
semantics for STEP 7.5 extended-tier test execution.

## Checkpoint JSON Format

Path: `tmp/arc/{id}/extended-checkpoint.json`

```json
{
  "schema_version": 1,
  "run_id": "arc-1772309747014",
  "tier": "extended",
  "started_at": "2026-03-02T12:00:00Z",
  "last_heartbeat": "2026-03-02T12:15:00Z",
  "completed_scenarios": [
    {
      "name": "load-test-login-flow",
      "status": "passed",
      "duration_ms": 180000,
      "completed_at": "2026-03-02T12:03:00Z"
    }
  ],
  "current_scenario": {
    "name": "stress-test-api-endpoints",
    "started_at": "2026-03-02T12:03:00Z",
    "progress_pct": null
  },
  "pending_scenarios": ["soak-test-memory-usage"],
  "partial_results": {
    "passed": 1,
    "failed": 0,
    "in_progress": 1,
    "pending": 1
  }
}
```

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | yes | Format version for compatibility checks (current: 1) |
| `run_id` | string | yes | Arc session ID — must match current session for resume |
| `tier` | string | yes | Always `"extended"` |
| `started_at` | ISO 8601 | yes | When extended tier execution began |
| `last_heartbeat` | ISO 8601 | yes | Last liveness update — used for staleness detection |
| `completed_scenarios` | array | yes | Scenarios that finished (pass or fail) |
| `completed_scenarios[].name` | string | yes | Scenario name (matches scenario.name) |
| `completed_scenarios[].status` | string | yes | `"passed"` or `"failed"` |
| `completed_scenarios[].duration_ms` | integer | yes | Execution time in milliseconds |
| `completed_scenarios[].completed_at` | ISO 8601 | yes | Completion timestamp |
| `current_scenario` | object | nullable | Currently executing scenario, or null if between scenarios |
| `current_scenario.name` | string | yes | Scenario name |
| `current_scenario.started_at` | ISO 8601 | yes | When this scenario started |
| `current_scenario.progress_pct` | integer | nullable | Optional progress indicator (0-100), null if unknown |
| `pending_scenarios` | string[] | yes | Scenario names not yet started |
| `partial_results` | object | yes | Aggregated status counts |

## Atomic Write Protocol

Checkpoint writes MUST be atomic to prevent corruption on crash:

```
writeCheckpoint(id, checkpoint):
  tmpPath = "tmp/arc/${id}/extended-checkpoint.tmp.json"
  finalPath = "tmp/arc/${id}/extended-checkpoint.json"

  // 1. Write to temporary file
  Write(tmpPath, JSON.stringify(checkpoint, null, 2))

  // 2. Atomic rename (mv is atomic on same filesystem)
  Bash(`mv "${tmpPath}" "${finalPath}"`)
```

This ensures readers always see either the old checkpoint or the new one — never a
partial write. The `Write()` + `mv` pattern is the established codebase convention
for crash-safe file updates.

## Heartbeat Protocol

Heartbeat is a **liveness signal** — separate from progress reporting:

```
updateHeartbeat(id, checkpoint):
  checkpoint.last_heartbeat = new Date().toISOString()
  writeCheckpoint(id, checkpoint)
```

### Heartbeat Timing

| Parameter | Source | Default |
|-----------|--------|---------|
| `checkpoint_interval_ms` | `talisman.testing.extended_tier.checkpoint_interval_ms` | 300,000 (5 min) |
| `stale_threshold_multiplier` | `talisman.testing.extended_tier.stale_threshold_multiplier` | 2 |

**Heartbeat schedule**: Updated at every `checkpoint_interval_ms`, regardless of scenario
progress. The runner updates heartbeat even if no scenario has completed since the last
heartbeat.

**Progress updates**: The `completed_scenarios`, `current_scenario`, `pending_scenarios`,
and `partial_results` fields are updated only when a scenario completes or starts. These
are bundled with the heartbeat write — but the heartbeat timestamp is the only field that
changes on a pure liveness update.

### Staleness Detection

The orchestrator detects stalled runners via heartbeat age:

```
isStale(checkpoint, checkpointInterval):
  staleMultiplier = talismanConfig.testing?.extended_tier?.stale_threshold_multiplier ?? 2
  heartbeatAge = Date.now() - Date.parse(checkpoint.last_heartbeat)
  staleThreshold = checkpointInterval * staleMultiplier

  return heartbeatAge > staleThreshold
```

Staleness is confirmed only when ALL three conditions hold:
1. Heartbeat age exceeds `checkpoint_interval_ms * stale_threshold_multiplier`
2. Runner's task status is still `in_progress` (via `TaskList()`)
3. `TeammateIdle` has NOT fired for the runner

This prevents false positives from clock skew, slow I/O, or normal inter-scenario gaps.

## Budget Enforcement

### Budget Clamping

The extended tier budget MUST be clamped to the remaining phase budget to prevent
running past the phase deadline:

```
effectiveBudget = Math.min(extendedBudget, remainingBudget())
```

Where:
- `extendedBudget` = `talisman.testing.extended_tier.timeout_ms` (default: 3,600,000ms = 60min)
- `remainingBudget()` = phase 7.7 inner budget minus time already consumed by STEPS 0-7

### Per-Scenario Timeout

Each scenario has an individual timeout to prevent a single scenario from consuming
the entire budget:

```
max_scenario_duration_ms = scenario.timeout_ms
                        ?? talisman.testing.extended_tier.max_scenario_duration_ms
                        ?? 600_000  // 10 min default
```

If a scenario exceeds its timeout, the runner:
1. Marks it as `"failed"` with reason `"timeout"`
2. Runs teardown for the scenario
3. Writes checkpoint
4. Proceeds to next scenario

### Budget Depletion

```
checkBudget(startedAt, effectiveBudget):
  elapsed = Date.now() - Date.parse(startedAt)
  remaining = effectiveBudget - elapsed

  if remaining <= 0:
    // Budget depleted — stop execution
    writeCheckpoint(id, {
      ...checkpoint,
      current_scenario: null,
      partial_results: { ...partial_results, in_progress: 0 }
    })
    return { depleted: true, remaining: 0 }

  return { depleted: false, remaining }
```

When budget is depleted, the runner writes a final checkpoint with all unfinished
scenarios in `pending_scenarios` and exits gracefully.

## Resume Protocol

### Resume Trigger

Resume occurs when `arc --resume` detects Phase 7.7 was interrupted AND
`extended-checkpoint.json` exists:

```
resumeExtendedTier(id):
  checkpointPath = "tmp/arc/${id}/extended-checkpoint.json"
  checkpoint = readJSON(checkpointPath)

  if !checkpoint:
    return null  // No checkpoint — start fresh

  // 1. Validate run_id matches current session
  if checkpoint.run_id !== currentRunId:
    warn("Checkpoint run_id mismatch. Starting fresh.")
    return null

  // 2. Validate schema_version compatibility
  if checkpoint.schema_version !== CURRENT_SCHEMA_VERSION:
    warn("Checkpoint schema_version ${checkpoint.schema_version} incompatible with current ${CURRENT_SCHEMA_VERSION}. Starting fresh.")
    return null

  // 3. Determine resume point
  return {
    resumeFrom: checkpoint.pending_scenarios,
    partialResults: checkpoint.partial_results,
    completedCount: checkpoint.completed_scenarios.length
  }
```

### Idempotency Requirements

- **Interrupted scenario**: Re-run the interrupted scenario from scratch. Scenarios
  MUST be idempotent — running them twice produces the same result.
- **Completed scenarios**: Skip entirely — their results are in the checkpoint.
- **Teardown on resume**: Always run teardown for the last completed scenario before
  continuing. This ensures clean state for the next scenario.

### Resume Execution Flow

```
executeWithResume(scenarios, checkpoint, budget):
  if checkpoint:
    log("Resuming from checkpoint: ${checkpoint.completed_scenarios.length} completed")
    // Teardown last completed scenario (clean state)
    lastCompleted = checkpoint.completed_scenarios[checkpoint.completed_scenarios.length - 1]
    if lastCompleted:
      runTeardown(lastCompleted.name)
    // Resume from pending
    remainingScenarios = checkpoint.pending_scenarios
    results = checkpoint.partial_results
  else:
    remainingScenarios = scenarios.map(s => s.name)
    results = { passed: 0, failed: 0, in_progress: 0, pending: remainingScenarios.length }

  for scenarioName in remainingScenarios:
    if checkBudget(startedAt, budget).depleted:
      break

    scenario = findScenario(scenarioName)
    results.in_progress = 1
    results.pending -= 1

    // Update checkpoint: starting new scenario
    writeCheckpoint(id, {
      ...checkpoint,
      current_scenario: { name: scenarioName, started_at: now(), progress_pct: null },
      pending_scenarios: remainingScenarios.slice(currentIndex + 1),
      partial_results: results
    })

    // Execute scenario
    result = executeScenario(scenario)

    // Update checkpoint: scenario complete
    results.in_progress = 0
    if result.passed: results.passed += 1
    else: results.failed += 1

    writeCheckpoint(id, {
      ...checkpoint,
      completed_scenarios: [...checkpoint.completed_scenarios, {
        name: scenarioName,
        status: result.passed ? "passed" : "failed",
        duration_ms: result.duration_ms,
        completed_at: now()
      }],
      current_scenario: null,
      pending_scenarios: remainingScenarios.slice(currentIndex + 1),
      partial_results: results
    })
```

## Parallel Scenario Support

Independent scenarios (no shared state, no `depends_on`) can optionally run concurrently:

```
if scenario.parallel === true:
  // Each parallel runner gets its own checkpoint file
  checkpointPath = "tmp/arc/${id}/extended-checkpoint-${scenario.name}.json"
  // After all parallel scenarios complete, aggregate results
  aggregateCheckpoints(id, parallelScenarioNames)
```

### Aggregation

```
aggregateCheckpoints(id, scenarioNames):
  results = { passed: 0, failed: 0 }
  allCompleted = []

  for name in scenarioNames:
    cp = readJSON("tmp/arc/${id}/extended-checkpoint-${name}.json")
    allCompleted.push(...cp.completed_scenarios)
    results.passed += cp.partial_results.passed
    results.failed += cp.partial_results.failed

  // Write merged checkpoint
  writeCheckpoint(id, {
    ...baseCheckpoint,
    completed_scenarios: allCompleted,
    pending_scenarios: [],
    partial_results: results
  })
```

Default is sequential execution. Parallel opt-in via `scenario.parallel: true`.
Max concurrent runners: `talisman.testing.extended_tier.max_concurrent ?? 2`.

## Talisman Configuration

```yaml
testing:
  extended_tier:
    enabled: false                     # Default: disabled (backward-compatible)
    timeout_ms: 3600000                # 60 min default budget
    checkpoint_interval_ms: 300000     # 5 min heartbeat interval
    stale_threshold_multiplier: 2      # 2x interval = stale
    max_scenario_duration_ms: 600000   # 10 min per-scenario cap
    max_concurrent: 2                  # Max parallel scenario runners
```

All configuration keys have defaults matching current behavior (no extended tier = skip).
