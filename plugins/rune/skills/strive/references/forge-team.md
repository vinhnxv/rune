# Phase 1: Forge Team — Inline Implementation

Detailed implementation code for Phase 1 of `/rune:strive`. Called after plan parsing (Phase 0)
and environment setup (Phase 0.5).

## Team Creation

```javascript
// Pre-create guard: teamTransition protocol (see team-sdk/references/engines.md)
// STEP 1: Validate (defense-in-depth)
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid work identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected in work identifier')

// STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
// STEP 3: Filesystem fallback (only when STEP 2 failed)
// STEP 4: TeamCreate with "Already leading" catch-and-recover
// STEP 5: Post-create verification

// Create signal directory for event-driven sync
const signalDir = `tmp/.rune-signals/rune-work-${timestamp}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(extractedTasks.length))
Write(`${signalDir}/inscription.json`, JSON.stringify({
  workflow: "rune-work",
  timestamp: timestamp,
  config_dir: Bash('cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P').trim(),
  owner_pid: Bash('echo $PPID').trim(),
  session_id: sessionId,
  output_dir: `tmp/work/${timestamp}/`,
  teammates: [
    { name: "rune-smith", output_file: "work-summary.md" },
    { name: "trial-forger", output_file: "work-summary.md" }
  ]
}))

// Create output directories (worker-logs replaces todos/ for per-worker session logs)
Bash(`mkdir -p "tmp/work/${timestamp}/patches" "tmp/work/${timestamp}/proposals" "tmp/work/${timestamp}/worker-logs"`)
```

## Complexity-Aware Task Ordering

```javascript
// --- Complexity-aware task ordering (sort before wave computation) ---
// Gate: readTalismanSection("work")?.complexity_ordering?.enabled !== false
//
// Scoring is additive: Score = (fileCount × wFile) + (wTest if test task) + (wRefactor if refactor keyword)
//                             + (wLargeScope if fileCount > 5)
// Tasks are sorted descending by score so highest-complexity tasks start first.
// Score is a relative ranking, not a time estimate — use estimateTaskMinutes() for time budgeting.
// Default weights (overridable via talisman complexity_ordering.weights):
//   wFile=2: cost per touched file — more files → more risk of conflicts
//   wTest=3: test tasks are slightly harder (require understanding existing coverage)
//   wRefactor=5: refactors touch structural patterns and carry high regression risk
//   wLargeScope=3: bonus for >5 files — coordination overhead grows super-linearly
// Used in both scoreTaskComplexity() and estimateTaskMinutes()
const REFACTOR_KEYWORDS = ["refactor", "restructure", "extract", "migrate", "rename", "reorganize"]

const complexityConfig = readTalismanSection("work")?.complexity_ordering
if (complexityConfig?.enabled !== false) {
  const weights = complexityConfig?.weights ?? {}
  const wFile = weights.file_count ?? 2
  const wTest = weights.test ?? 3
  const wRefactor = weights.refactor ?? 5
  const wLargeScope = weights.large_scope ?? 3

  function scoreTaskComplexity(task) {
    const fileCount = (task.fileTargets?.length ?? 0) + (task.dirTargets?.length ?? 0)
    if (fileCount === 0 && !task.subject && !task.description) return 0  // missing metadata → 0

    let estimate = fileCount * wFile
    if (task.type === "test") estimate += wTest
    const text = `${task.subject ?? ''} ${task.description ?? ''}`.toLowerCase()
    if (REFACTOR_KEYWORDS.some(kw => text.includes(kw))) estimate += wRefactor
    if (fileCount > 5) estimate += wLargeScope
    return estimate
  }

  // Score and sort descending (highest complexity first)
  for (const task of extractedTasks) {
    task._complexityScore = scoreTaskComplexity(task)
    log(`COMPLEXITY-SCORE: task #${task.id} "${task.subject}" → ${task._complexityScore}`)
  }
  extractedTasks.sort((a, b) => b._complexityScore - a._complexityScore)
}
```

## Task Time Estimation

```javascript
// --- Task time estimation (stored in metadata for Phase 3 reassignment) ---
function estimateTaskMinutes(task) {
  const fileCount = (task.fileTargets?.length ?? 0) + (task.dirTargets?.length ?? 0)
  let estimate = fileCount <= 2 ? 5 : fileCount <= 5 ? 10 : 15
  if (task.type === "test") estimate = 8
  const text = `${task.subject ?? ''} ${task.description ?? ''}`.toLowerCase()
  if (REFACTOR_KEYWORDS.some(kw => text.includes(kw))) estimate = Math.min(20, Math.round(estimate * 1.5))
  return estimate
}
for (const task of extractedTasks) {
  task.metadata = task.metadata ?? {}
  task.metadata.estimated_minutes = estimateTaskMinutes(task)
}
```

## Wave Configuration and State File

```javascript
// Wave-based execution: bounded batches with fresh worker context
const TASKS_PER_WORKER = talisman?.work?.tasks_per_worker ?? 3
const totalTasks = extractedTasks.length
const maxWorkers = talisman?.work?.max_workers ?? 3
const waveCapacity = maxWorkers * TASKS_PER_WORKER  // e.g. 3 workers * 3 = 9
const totalWaves = Math.ceil(totalTasks / waveCapacity)

// Compute total worker count (scaling logic in worker-prompts.md)
const workerCount = smithCount + forgerCount

// Write state file with session identity for cross-session isolation
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write("tmp/.rune-work-{timestamp}.json", {
  team_name: "rune-work-{timestamp}",
  started: new Date().toISOString(),
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  plan: planPath,
  expected_workers: workerCount,
  total_waves: totalWaves,
  tasks_per_worker: TASKS_PER_WORKER,
  ...(worktreeMode && { worktree_mode: true, waves: [], current_wave: 0, merged_branches: [] })
})
```

## Checkpoint Write (Phase 3 — after each task completion)

Writes a checkpoint file after each task completion during Phase 3 monitoring. Enables `--resume` to skip completed tasks on session restart. Uses atomic tmp+mv write pattern for crash safety.

```javascript
// Checkpoint path: same timestamp directory as the work session
const CHECKPOINT_PATH = `tmp/work/${timestamp}/strive-checkpoint.json`

// In waitForCompletion monitoring loop, after detecting a task completion:
// (Called each poll cycle when a new task transitions to "completed")
function writeStriveCheckpoint(allTasks) {
  const completedTasks = allTasks
    .filter(t => t.status === "completed")
    .map(t => String(t.id))  // Task ID type safety: always String()

  const taskArtifacts = {}
  for (const task of allTasks.filter(t => t.status === "completed")) {
    taskArtifacts[String(task.id)] = {
      files: task.filesModified || [],
      completed_at: task.completedAt || new Date().toISOString(),
      worker: task.owner || "unknown"
    }
  }

  // Platform-portable mtime: try BSD stat first (macOS), fall back to GNU stat (Linux)
  // SEC-006: Validate planPath before shell use
  if (!/^[a-zA-Z0-9._\-\/]+$/.test(planPath) || planPath.includes('..')) {
    throw new Error(`Invalid planPath: ${planPath}`)
  }
  const planMtime = Bash(`stat -f '%m' "${planPath}" 2>/dev/null || stat -c '%Y' "${planPath}" 2>/dev/null`).trim()

  const checkpointData = JSON.stringify({
    plan_path: planPath,
    plan_mtime: planMtime,
    team_name: teamName,
    config_dir: configDir,
    owner_pid: ownerPid,
    session_id: SESSION_ID,  // resolved in Wave Configuration section: `const SESSION_ID = Bash("echo $CLAUDE_SESSION_ID").trim()`
    total_tasks: allTasks.length,
    completed_tasks: completedTasks,
    task_artifacts: taskArtifacts,
    updated_at: Date.now(),
    schema_version: 1
  }, null, 2)

  // Atomic write: tmp file + mv to prevent corrupted checkpoint on crash
  const tmpPath = `${CHECKPOINT_PATH}.tmp`
  Write(tmpPath, checkpointData)
  Bash(`mv "${tmpPath}" "${CHECKPOINT_PATH}"`)
}

// Integration point: call writeStriveCheckpoint from the Phase 3 monitoring loop
// each time TaskList shows a newly completed task (compare previous vs current snapshot)
//
// Example integration in monitor loop:
//   const prevCompleted = new Set(prevSnapshot.filter(t => t.status === "completed").map(t => t.id))
//   const currCompleted = currentTasks.filter(t => t.status === "completed")
//   const newlyCompleted = currCompleted.filter(t => !prevCompleted.has(t.id))
//   if (newlyCompleted.length > 0) {
//     writeStriveCheckpoint(currentTasks)
//   }
```

### Checkpoint Schema (v1)

| Field | Type | Description |
|-------|------|-------------|
| `plan_path` | string | Path to the plan file that was executed |
| `plan_mtime` | string | Plan file modification time at checkpoint write (for drift detection) |
| `team_name` | string | Team name for the work session |
| `config_dir` | string | Resolved CLAUDE_CONFIG_DIR (session isolation) |
| `owner_pid` | string | Claude Code PID via $PPID (session isolation) |
| `session_id` | string | CLAUDE_SESSION_ID (diagnostic) |
| `total_tasks` | number | Total number of tasks in the plan |
| `completed_tasks` | string[] | IDs of completed tasks (always String) |
| `task_artifacts` | object | Per-task artifact map: `{ [taskId]: { files, completed_at, worker } }` |
| `updated_at` | number | Epoch ms of last checkpoint write |
| `schema_version` | number | Always `1` — for future-proofing schema evolution |

### Notes

- **Atomic writes**: The tmp+mv pattern ensures the checkpoint is either fully written or not present — no partial JSON on crash.
- **Task ID type safety**: All task IDs are cast to `String()` at both write (`completed_tasks`) and read (`--resume` detection) boundaries to prevent string-vs-number comparison failures.
- **Session isolation**: `config_dir` + `owner_pid` fields enable `--resume` to skip checkpoints from other sessions.
- **`onCheckpoint` callback**: The `waitForCompletion` API in `monitor-utility.md` supports an `onCheckpoint` callback. If unavailable in the implementation, use polling-based detection as shown in the integration example above (compare previous vs current task snapshots each poll cycle).
