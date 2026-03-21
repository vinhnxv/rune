# File Ownership and Task Pool (Phase 1)

## Task Pool Creation

1. Extract file targets (`fileTargets`, `dirTargets`) per task from plan
2. Classify risk tiers — see [risk-tiers.md](../../roundtable-circle/references/risk-tiers.md)
3. Detect overlapping file ownership via set intersection (O(n²) cap: 200 targets)
4. Serialize conflicting tasks via `blockedBy` links
5. Create task pool via `TaskCreate` with quality contract embedded in description
6. Link dependencies using mapped IDs — see [dependency-patterns.md](dependency-patterns.md) for named patterns and anti-patterns
7. Compute wave groupings (worktree mode only) using DFS depth algorithm
8. Write `task_ownership` to inscription.json for runtime enforcement (SEC-STRIVE-001)

### Subtask Ownership (v2.5.0+)

When task decomposition is active, subtasks inherit ownership from decomposition output:

- Each subtask gets its own `file_targets` from the LLM decomposition
- Subtask IDs use format `{parentId}-sub-{index}` (e.g., `1-sub-1`, `1-sub-2`)
- `inscription.json` task_ownership includes subtask entries alongside parent entries
- `blockedBy` links auto-generated between subtasks with overlapping targets
- `validate-strive-worker-paths.sh` resolves subtask IDs via the same flat-union allowlist

```javascript
// When building task_ownership for inscription.json:
for (const task of expandedTasks) {
  const taskId = task.parent_task_id
    ? `${task.parent_task_id}-sub-${task.id.split('-sub-')[1]}`
    : String(task.id)
  taskOwnership[taskId] = {
    owner: null,  // assigned during claim
    files: task.file_targets || [],
    dirs: task.dir_targets || []
  }
}
```

## Runtime File Ownership Enforcement (SEC-STRIVE-001)

After creating the task pool, write `task_ownership` to `inscription.json` mapping each task to its file/dir targets. The `validate-strive-worker-paths.sh` PreToolUse hook reads this at runtime to block writes outside assigned scope.

```javascript
// Build task_ownership mapping for inscription.json
const taskOwnership = {}
for (const task of extractedTasks) {
  const targets = extractFileTargets(task)
  if (targets.files.length > 0 || targets.dirs.length > 0) {
    taskOwnership[task.id] = {
      owner: task.assignedWorker || "unassigned",
      files: targets.files,
      dirs: targets.dirs
    }
  }
  // Tasks with no extractable targets are unrestricted (not added to task_ownership)
}
```

### Inscription Format

```json
{
  "workflow": "rune-work",
  "timestamp": "20260225-015124",
  "task_ownership": {
    "task-1": { "owner": "rune-smith-1", "files": ["src/auth.ts"], "dirs": ["src/auth/"] },
    "task-2": { "owner": "rune-smith-2", "files": ["src/api/users.ts"], "dirs": ["src/api/"] }
  }
}
```

The hook uses a **flat union** approach: all tasks' file targets are merged into one allowlist. This means worker-A can write to worker-B's files, but files NOT in ANY task's target list are blocked. Talisman `work.unrestricted_shared_files` array is appended to every task's allowlist (for shared config files like `package.json`).

## Dynamic File Lock Signals

Runtime file lock layer that complements static `blockedBy` serialization. Gated by `work.file_lock_signals.enabled` (default: `true`).

### How It Works

Workers write signal files to `tmp/.rune-signals/{team}/{worker-name}-files.json` before starting implementation. Each signal declares which files the worker is actively modifying. Other workers check for overlapping locks before claiming a task:

```json
{
  "worker": "rune-smith-w0-1",
  "task_id": "3",
  "files": ["src/auth.ts", "src/auth/middleware.ts"],
  "timestamp": 1709568000000
}
```

**Lifecycle**: Signal file is created at step 4.8 (after ownership check, before file reads) and deleted at step 8.5/9.5 (after task completion or ward failure).

### TOCTOU Mitigation

The check-then-write pattern is inherently subject to time-of-check-to-time-of-use (TOCTOU) races. Mitigations:

1. **Static serialization first**: `blockedBy` links (Phase 1) catch most overlaps at planning time. File lock signals are a second layer for dynamic overlap that static analysis missed.
2. **Atomic signal writes**: Workers write signal files atomically (write to temp file + rename).
3. **Conservative conflict resolution**: On conflict, the worker defers (releases task) rather than proceeding. False positives (unnecessary deferrals) are preferred over false negatives (concurrent edits).
   > **Note:** At 5+ workers, dual-defer retry storms become more likely. Consider exponential backoff jitter (30s → 45s → 60s) for large plans. Current retry cycle is 3 × 30s = 90s minimum. This is a deliberate trade-off: correctness (no concurrent edits) is prioritized over throughput (retry overhead). With fewer than 5 workers the collision probability is low enough that fixed 30s retries are acceptable.
4. **Idempotent release**: Workers delete their own signal file on both success and failure paths.

### Stale Lock Prevention

The orchestrator's Phase 3 monitoring loop includes a stale lock scan that sweeps `tmp/.rune-signals/{team}/*-files.json`. Signals older than `work.file_lock_signals.stale_threshold_ms` (default: 600000ms / 10 minutes) are deleted.

> **Threshold rationale:** The default `stale_threshold_ms` of 600000 (10 minutes) acts as a filesystem janitor for crashed workers, not a real-time safety net. A worker that crashes leaves its signal file behind; the janitor sweeps it up on the next monitoring cycle. For tighter protection against long-running workers blocking tasks, reduce to 180000 (3 minutes = 1 long task + buffer). The 10-minute default is conservative to avoid false positives on slow I/O or temporarily hung workers. Adjust via `work.file_lock_signals.stale_threshold_ms` in `talisman.yml`.

This handles:

- Worker crashes (signal file left behind without cleanup)
- Workers that exceed their runtime budget and get force-shutdown
- Orphaned signals from previous waves

### Talisman Configuration

```yaml
work:
  file_lock_signals:
    enabled: true                # default: true
    stale_threshold_ms: 600000   # default: 10 minutes
```

## File Ownership Pre-Check (Phase 1.7a)

Runs AFTER `extractFileTargets()` completes for all tasks (step 1) and BEFORE user confirmation (`AskUserQuestion`). Detects file ownership conflicts at planning time and auto-serializes via `blockedBy` — catching collisions before workers are spawned.

**Precondition**: `extractFileTargets()` must have populated `task.fileTargets` and `task.dirTargets` for all tasks before this phase runs.

**Defense-in-depth**: This is the first layer of conflict prevention. Dynamic file lock signals (Phase 2-3) remain active as the second layer for runtime conflicts that static analysis cannot predict.

### Step 1: Build Ownership Graph

```javascript
/**
 * Build maps of file/dir paths to the tasks that target them.
 * Pure data function — no mutations to tasks.
 */
function buildOwnershipGraph(tasks) {
  const fileToTasks = {}  // Map<filePath, taskId[]>
  const dirToTasks = {}   // Map<dirPath, taskId[]>

  // Load unrestricted shared files from talisman (excluded from conflict detection)
  const unrestrictedFiles = new Set(
    readTalismanSection("work")?.unrestricted_shared_files || []
  )

  for (const task of tasks) {
    const taskId = String(task.id)

    for (const file of (task.fileTargets || [])) {
      if (unrestrictedFiles.has(file)) continue  // skip shared files (package.json, etc.)
      fileToTasks[file] = fileToTasks[file] || []
      fileToTasks[file].push(taskId)
    }

    for (const dir of (task.dirTargets || [])) {
      // Normalize: ensure dir ends with "/" for consistent prefix matching
      const normalizedDir = dir.endsWith("/") ? dir : dir + "/"
      dirToTasks[normalizedDir] = dirToTasks[normalizedDir] || []
      dirToTasks[normalizedDir].push(taskId)
    }
  }

  return { fileToTasks, dirToTasks }
}
```

### Step 2: Detect and Resolve Conflicts

```javascript
/**
 * Detect file ownership conflicts and auto-serialize via blockedBy.
 * Uses atomic apply-after-validate: accumulates all proposed blockedBy
 * additions, validates the combined graph for cycles, then applies atomically.
 */
function detectAndResolveConflicts(graph, tasks) {
  const { fileToTasks, dirToTasks } = graph
  const conflicts = []

  // Detect direct file conflicts (2+ tasks share the same file)
  for (const [file, taskIds] of Object.entries(fileToTasks)) {
    if (taskIds.length > 1) {
      conflicts.push({
        type: "file",
        path: file,
        tasks: taskIds,
        resolution: null
      })
    }
  }

  // Detect dir-file overlaps: task A targets src/auth/, task B targets src/auth/middleware.ts
  for (const [dir, dirTaskIds] of Object.entries(dirToTasks)) {
    for (const [file, fileTaskIds] of Object.entries(fileToTasks)) {
      if (file.startsWith(dir)) {  // dir already normalized with trailing "/"
        const overlapping = dirTaskIds.filter(id => !fileTaskIds.includes(id))
        if (overlapping.length > 0) {
          conflicts.push({
            type: "dir-file-overlap",
            dir: dir,
            file: file,
            tasks: [...new Set([...dirTaskIds, ...fileTaskIds])],
            resolution: null
          })
        }
      }
    }
  }

  if (conflicts.length === 0) return { conflicts, applied: false }

  // Build task lookup for riskTier comparison
  const taskMap = {}
  for (const task of tasks) {
    taskMap[String(task.id)] = task
  }

  // --- Atomic apply-after-validate ---
  // Phase A: Accumulate all proposed blockedBy additions WITHOUT applying
  const proposedEdges = []  // Array of { from: taskId, to: taskId } (to is blockedBy from)

  for (const conflict of conflicts) {
    const taskIds = conflict.tasks
    // Sort by riskTier descending (higher risk first), then by task.id for determinism
    const sorted = [...taskIds].sort((a, b) => {
      const tierA = taskMap[a]?.riskTier ?? 0
      const tierB = taskMap[b]?.riskTier ?? 0
      if (tierB !== tierA) return tierB - tierA  // higher tier first
      return a.localeCompare(b)  // deterministic secondary sort
    })

    // Chain serialization: A → B → C (sequential, not fan-out)
    for (let i = 1; i < sorted.length; i++) {
      const first = sorted[i - 1]
      const second = sorted[i]
      // "second" is blocked by "first" (first must complete before second starts)
      proposedEdges.push({ from: first, to: second })
      conflict.resolution = "serialized"
      conflict.order = sorted.join(" → ")
    }
  }

  // Phase B: Validate combined graph for cycles BEFORE applying any edges
  // Build adjacency list: blockedBy means "to" waits for "from"
  const adjList = {}  // task -> tasks it's blocked by (existing + proposed)
  for (const task of tasks) {
    const tid = String(task.id)
    adjList[tid] = new Set((task.blockedBy || []).map(id => String(id)))
  }
  // Add proposed edges
  for (const edge of proposedEdges) {
    if (!adjList[edge.to]) adjList[edge.to] = new Set()
    adjList[edge.to].add(edge.from)
  }

  // Cycle detection via DFS
  const visited = new Set()
  const inStack = new Set()
  let hasCycle = false

  function dfs(node) {
    if (inStack.has(node)) { hasCycle = true; return }
    if (visited.has(node)) return
    visited.add(node)
    inStack.add(node)
    for (const dep of (adjList[node] || [])) {
      dfs(dep)
      if (hasCycle) return
    }
    inStack.delete(node)
  }

  for (const taskId of Object.keys(adjList)) {
    dfs(taskId)
    if (hasCycle) break
  }

  if (hasCycle) {
    log("WARNING: Auto-serialization would create circular dependency. Skipping conflict resolution — manual review needed.")
    for (const conflict of conflicts) {
      conflict.resolution = "skipped-cycle-risk"
    }
    return { conflicts, applied: false }
  }

  // Phase C: Apply all edges atomically (graph validated as acyclic)
  for (const edge of proposedEdges) {
    const targetTask = taskMap[edge.to]
    if (targetTask) {
      targetTask.blockedBy = targetTask.blockedBy || []
      if (!targetTask.blockedBy.map(id => String(id)).includes(edge.from)) {
        targetTask.blockedBy.push(edge.from)
      }
    }
  }

  // Warn when chain length >= 3 (performance degradation)
  for (const conflict of conflicts) {
    if (conflict.tasks.length >= 3) {
      log(`WARNING: ${conflict.tasks.length} tasks share ${conflict.path || conflict.file} — consider merging tasks for parallelism.`)
    }
  }

  return { conflicts, applied: true }
}
```

### Step 3: Format Conflict Summary

```javascript
/**
 * Format conflicts for display in the user confirmation dialog.
 * Returns empty string if no conflicts detected.
 */
function formatConflictSummary(conflicts) {
  if (conflicts.length === 0) return ""

  const lines = [
    `Detected ${conflicts.length} file ownership conflict(s) — auto-serialized via blockedBy:`,
    ""
  ]

  for (const conflict of conflicts) {
    const path = conflict.path || conflict.file || `${conflict.dir} (dir overlap)`
    const resolution = conflict.resolution === "serialized"
      ? `serialized: ${conflict.order}`
      : conflict.resolution || "unresolved"
    lines.push(`  - ${path}: tasks ${conflict.tasks.join(", ")} → ${resolution}`)
  }

  // Dynamic-lock caveat: pre-check only covers plan-declared targets
  const planConflictCount = conflicts.filter(c => c.resolution === "serialized").length
  if (planConflictCount > 0) {
    lines.push("")
    lines.push(`Note: ${planConflictCount} plan-declared conflict(s) detected. Additional runtime conflicts handled by dynamic lock signals.`)
  }

  return lines.join("\n")
}
```

### Integration

```javascript
// Phase 1.7a: File Ownership Pre-Check
// Called AFTER extractFileTargets() for all tasks, BEFORE AskUserQuestion confirmation

const graph = buildOwnershipGraph(extractedTasks)
const { conflicts, applied } = detectAndResolveConflicts(graph, extractedTasks)
const conflictSummary = formatConflictSummary(conflicts)

// Inject into confirmation dialog if conflicts exist
if (conflictSummary) {
  // Append to the task confirmation prompt shown via AskUserQuestion
  confirmationContext += "\n\n" + conflictSummary
}
```

### Edge Cases

| Edge Case | Handling |
|-----------|----------|
| No file targets extracted | `buildOwnershipGraph` returns empty maps → no conflicts → pre-check skipped |
| `unrestricted_shared_files` (package.json) | Excluded from `fileToTasks` map — no conflict generated |
| 3+ tasks share same file | Chain serialization: A → B → C with warning to consider merging |
| Circular dependency from auto-serialization | Atomic apply-after-validate catches cycles → skips resolution with warning |
| Equal riskTier across tasks | Secondary sort by `task.id` (string comparison) for determinism |
| Dir target without trailing slash | Normalized in `buildOwnershipGraph`: append "/" before prefix matching |
| Manual blockedBy + auto-serialization creates deadlock | Cycle detection includes existing `blockedBy` edges in the graph |
| `fileTargets` not yet populated | **Precondition**: `extractFileTargets()` must run first (documented above) |
| > 200 file targets | Existing O(n²) cap in Task Pool Creation step 3 (detection) applies — truncate at 200 targets |
| 5+ tasks share same file | Chain length warning: "Consider merging these tasks" |
| Subtask with `parent_task_id` | Treated as a first-class task — `fileTargets` and `blockedBy` already set by `runTaskDecomposition()`. No special-casing in `buildOwnershipGraph`. |
| Subtask overlaps sibling subtask | Caught by `validateSubtaskFileOverlap()` in task-decomposition.md BEFORE this phase runs. Additional safety: `detectAndResolveConflicts()` handles any missed overlaps via `blockedBy`. |

## Subtask Ownership (Phase 1.1 Integration)

When `work.task_decomposition.enabled` is true, `runTaskDecomposition()` (see
[task-decomposition.md](task-decomposition.md)) replaces COMPOSITE tasks with subtasks
before this phase runs. Each subtask has:

- `id`: `"{parent_id}-sub-{N}"` (e.g., `"3-sub-1"`, `"3-sub-2"`)
- `parent_task_id`: original task ID for traceability
- `fileTargets`: non-overlapping file list (validated by `validateSubtaskFileOverlap`)
- `blockedBy`: parent's `blockedBy` + any intra-subtask dependencies

The existing `buildOwnershipGraph()` and `detectAndResolveConflicts()` functions
handle subtasks identically to top-level tasks — no code changes needed. Subtask
IDs appear naturally in `task_ownership` in inscription.json:

```json
{
  "task_ownership": {
    "3-sub-1": { "owner": "rune-smith-1", "files": ["src/api/users.ts"], "dirs": [], "parent_task_id": "3" },
    "3-sub-2": { "owner": "rune-smith-2", "files": ["src/services/user.ts"], "dirs": [], "parent_task_id": "3" }
  }
}
```

The `validate-strive-worker-paths.sh` hook uses a flat union of all `files[]` arrays
regardless of whether the task is a top-level or subtask — no hook changes needed.

## Quality Contract

Embedded in every task description:

```
Quality requirements (mandatory):
- Type annotations on ALL function signatures (params + return types)
- Use `from __future__ import annotations` at top of every Python file
- Docstrings on all public functions, classes, and modules
- Specific exception types (no bare except, no broad Exception catch)
- Tests must cover edge cases (empty input, None values, type mismatches)
```
