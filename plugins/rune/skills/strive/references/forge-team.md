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

> ⚠️ **EXECUTION REQUIRED**: The code blocks below are NOT reference-only pseudocode.
> The orchestrator MUST execute every `Write()` and `Bash()` call in this section.
> Task files, scope files, prompt files, and the delegation manifest MUST physically exist
> in `tmp/work/{timestamp}/` before any `Agent()` call is made.
> Missing files = workers have no spec = silent delegation failures (root cause this plan fixes).

## Task File Creation (Discipline Bridge)

```javascript
// After extractedTasks is populated (parse-plan.md output) with metadata
// and BEFORE worker spawning begins — write physical task files.
// Schema: task-file-format.md (canonical source)
// Directory: tasks/ (NOT task-briefs/) per spec alignment

// Create tasks directory
// AC-8: Graceful degradation — wrap mkdir in try/catch
try {
  Bash(`mkdir -p "tmp/work/${timestamp}/tasks"`)
} catch (e) {
  warn(`Failed to create tasks directory: ${e.message}. Task files will be skipped — workers use inline prompts as fallback.`)
}

let taskFilesCreated = 0
let taskFilesFailed = []

for (const task of extractedTasks) {
  const taskId = String(task.id)  // FLAW-008: normalize to String at every boundary
  const taskCriteria = taskCriteriaMap[taskId] || taskCriteriaMap[task.id] || []
  const fileTargets = task.fileTargets || []

  // RUIN-004 FIX: Sanitize task.description for YAML frontmatter safety
  // Escape YAML special characters to prevent content injection
  const sanitizedDescription = (task.description ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')

  const taskFileContent = [
    '---',
    `task_id: "${taskId}"`,
    `plan_file: "${planPath}"`,
    `plan_section: "### Task ${taskId}"`,
    `status: PENDING`,
    `assigned_to: null`,
    `iteration: 0`,
    `risk_tier: ${task.riskTier ?? 1}`,
    `proof_count: ${taskCriteria.length}`,
    `created_at: "${new Date().toISOString()}"`,
    `updated_at: "${new Date().toISOString()}"`,
    `completed_at: null`,
    '---',
    '',
    '## Source',
    '',
    task.description,  // Full task description (plan section verbatim — unescaped for readability in body)
    '',
    '## Acceptance Criteria',
    '',
    ...taskCriteria.map(c => [
      `- id: ${c.id}`,
      `  text: "${c.text}"`,
      `  proof: ${c.proof}`,
      `  args: ${JSON.stringify(c.args)}`,
      ''
    ].join('\n')),
    '## File Targets',
    '',
    ...fileTargets.map(f => `- ${f}`),
    '',
    '## Context',
    '',
    shardContext || 'No additional context.',
    '',
    '## Worker Report',
    '',
    '_To be filled by assigned worker._',
  ].join('\n')

  // AC-8: Graceful degradation — wrap Write() in try/catch, log warning, continue
  try {
    Write(`tmp/work/${timestamp}/tasks/task-${taskId}.md`, taskFileContent)
    taskFilesCreated++
  } catch (e) {
    warn(`Failed to write task file task-${taskId}.md: ${e.message}`)
    taskFilesFailed.push(taskId)
  }
}

log(`Created ${taskFilesCreated}/${extractedTasks.length} task files in tmp/work/${timestamp}/tasks/`)
if (taskFilesFailed.length > 0) {
  warn(`Failed task files: ${taskFilesFailed.join(', ')}. Workers will use inline prompts for these tasks.`)
}
```

**Key design decisions**:
- Uses `tasks/` directory to match `task-file-format.md` schema (line 13) and all 3 spec files
- Task ID normalized to `String()` at entry point (`FLAW-008`) — both for the map lookup and filename
- Dual-key lookup (`taskCriteriaMap[taskId] || taskCriteriaMap[task.id]`) handles maps keyed by either type
- Task file uses FULL task description (not truncated to 2000 chars) — the file IS the context
- `task-file-format.md` schema is the canonical source — this code follows it exactly
- Task files are the SUPERSET — `TaskCreate()` descriptions can reference task file path instead of embedding full content

## Worker Scope Files

Write per-worker scope files BEFORE spawning any `Agent()`. One file per worker in
`tmp/work/{timestamp}/scopes/{worker-name}.md` (AC-3). Uses `scopes/` directory — not `context/` —
to avoid namespace collision with existing arc artifacts (E1 concern).

```javascript
// plannedWorkers is computed in worker-prompts.md:
// Array of { name, tasks, fileTargets, blockedFiles, nonGoals }
// AC-8: Graceful degradation — wrap mkdir in try/catch
try {
  Bash(`mkdir -p "tmp/work/${timestamp}/scopes"`)
} catch (e) {
  warn(`Failed to create scopes directory: ${e.message}. Scope files will be skipped.`)
}

let scopeFilesCreated = 0

for (const worker of plannedWorkers) {
  const { name, tasks, fileTargets, blockedFiles, nonGoals } = worker

  const scopeContent = [
    `# Worker Scope: ${name}`,
    ``,
    `## Identity`,
    ``,
    `- **Worker**: ${name}`,
    `- **Timestamp**: ${timestamp}`,
    ``,
    `## Assigned Tasks`,
    ``,
    ...tasks.map(t => `- Task ${t.id}: ${t.subject}`),
    ``,
    `## File Targets`,
    ``,
    ...fileTargets.map(f => `- ${f}`),
    ``,
    `## Blocked Files (Do NOT Modify)`,
    ``,
    ...(blockedFiles.length > 0 ? blockedFiles.map(f => `- ${f}`) : ['_None_']),
    ``,
    `## Non-Goals`,
    ``,
    ...(nonGoals.length > 0 ? nonGoals.map(g => `- ${g}`) : ['_None specified_']),
  ].join('\n')

  // AC-8: Graceful degradation — wrap Write() in try/catch, log warning, continue
  try {
    Write(`tmp/work/${timestamp}/scopes/${name}.md`, scopeContent)
    scopeFilesCreated++
  } catch (e) {
    warn(`Failed to write scope file ${name}.md: ${e.message}`)
  }
}

log(`Created ${scopeFilesCreated}/${plannedWorkers.length} scope files in tmp/work/${timestamp}/scopes/`)
```

**Verification**: `Glob("tmp/work/${timestamp}/scopes/*.md").length === plannedWorkers.length`

## Worker Prompt Files

Write final prompt content to file BEFORE each `Agent()` call (AC-2). Enables debugging,
auditability, and scope verification. Path: `tmp/work/{timestamp}/prompts/{worker-name}.md`.

```javascript
// promptContent = full spawn prompt string built by worker-prompts.md buildWorkerPrompt()
// AC-8: Graceful degradation — wrap mkdir in try/catch
try {
  Bash(`mkdir -p "tmp/work/${timestamp}/prompts"`)
} catch (e) {
  warn(`Failed to create prompts directory: ${e.message}. Prompt files will be skipped.`)
}

let promptFilesCreated = 0

for (const worker of plannedWorkers) {
  const { name, promptContent } = worker
  // AC-8: Graceful degradation — wrap Write() in try/catch, log warning, continue
  try {
    Write(`tmp/work/${timestamp}/prompts/${name}.md`, promptContent)
    promptFilesCreated++
  } catch (e) {
    warn(`Failed to write prompt file ${name}.md: ${e.message}`)
  }
}

log(`Created ${promptFilesCreated}/${plannedWorkers.length} prompt files in tmp/work/${timestamp}/prompts/`)
```

**Verification**: `Glob("tmp/work/${timestamp}/prompts/*.md").length === plannedWorkers.length`

## Delegation Manifest

Write a single JSON manifest BEFORE any `Agent()` spawn (AC-6). Single source of truth for what
was delegated to whom. Path: `tmp/work/{timestamp}/delegation-manifest.json`.

```javascript
const manifest = {
  created_at: new Date().toISOString(),
  timestamp: timestamp,
  workers: plannedWorkers.map(worker => ({
    name: worker.name,
    tasks: worker.tasks.map(t => String(t.id)),
    file_targets: worker.fileTargets,
    scope_file: `tmp/work/${timestamp}/scopes/${worker.name}.md`,
    prompt_file: `tmp/work/${timestamp}/prompts/${worker.name}.md`,
  })),
  task_count: extractedTasks.length,
  worker_count: plannedWorkers.length,
}

// AC-8: Graceful degradation — delegation manifest is advisory (not read by workers).
// Wrap in try/catch so failure doesn't crash the pipeline.
try {
  Write(`tmp/work/${timestamp}/delegation-manifest.json`, JSON.stringify(manifest, null, 2))
  log(`Delegation manifest written: tmp/work/${timestamp}/delegation-manifest.json`)
} catch (e) {
  warn(`Failed to write delegation manifest: ${e.message}. This is advisory-only — workers are not affected.`)
}
```

**Verification**: `Read("tmp/work/${timestamp}/delegation-manifest.json")` — parse JSON, confirm `workers` array length matches `plannedWorkers.length`.

## TaskCreate with Task File Reference

```javascript
// Updated TaskCreate: reference task file instead of embedding full description.
// Task file is the single source of truth — TaskCreate becomes pointer + summary.
// This eliminates the 2000-char truncation problem in the SDK task description.

for (const task of extractedTasks) {
  const taskId = String(task.id)  // FLAW-008: normalize to String at every boundary
  const taskCriteria = taskCriteriaMap[taskId] || taskCriteriaMap[task.id] || []

  TaskCreate({
    subject: `Task ${taskId}: ${task.subject}`,
    description: [
      `**Task File**: tmp/work/${timestamp}/tasks/task-${taskId}.md`,
      `**Read the task file FIRST** — it contains your full spec, acceptance criteria, and file targets.`,
      '',
      `**Summary**: ${task.subject}`,
      `**Risk Tier**: ${task.riskTier ?? 1}`,
      `**Proof Count**: ${taskCriteria.length} criteria`,
      `**File Targets**: ${(task.fileTargets || []).join(', ')}`,
    ].join('\n'),
    metadata: {
      task_file: `tmp/work/${timestamp}/tasks/task-${taskId}.md`,
      estimated_minutes: task.metadata?.estimated_minutes ?? 10
    }
  })
}
```

**Rationale**: Task file is the single source of truth. TaskCreate description becomes a pointer + summary, not the full content. This eliminates the 2000-char truncation problem. The `task_file` metadata field enables downstream tools (workers, hooks) to locate the full spec programmatically.

## Adaptive maxTurns Scaling

```javascript
// Adaptive maxTurns based on task complexity (v1.180.0+)
// Used when spawning workers to give complex tasks more room to complete.
// Replaces static maxTurns: 60 with a data-driven value.
function calculateAdaptiveMaxTurns(task) {
  const base = 60  // Default maxTurns for rune-smith
  const fileCount = task.fileTargets?.length ?? 0
  const criteriaCount = task.acceptanceCriteria?.length ?? 0

  // Scale: +5 turns per file beyond 3, +3 turns per criterion beyond 2
  const fileBonus = Math.max(0, fileCount - 3) * 5
  const criteriaBonus = Math.max(0, criteriaCount - 2) * 3

  // Cap at 120 turns (2x default) to prevent runaway agents
  return Math.min(base + fileBonus + criteriaBonus, 120)
}
```

> **Note**: When spawning workers via `Agent()`, use `calculateAdaptiveMaxTurns(task)` for the
> `maxTurns` parameter instead of the static default. This ensures complex tasks (many files or
> acceptance criteria) get sufficient turns while simple tasks stay bounded at the base of 60.

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
