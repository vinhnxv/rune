# Task Decomposition — strive Phase 1.1 Reference

LLM-driven task classification and decomposition. Runs in Phase 1 after
`extractFileTargets()` and `scoreTaskComplexity()` complete, but **before**
`detectAndResolveConflicts()` in file-ownership.md.

See [forge-team.md](forge-team.md) for integration point (Phase 1.1 call site).
See [file-ownership.md](file-ownership.md) for the conflict detection phase that follows.

## Configuration

```yaml
work:
  task_decomposition:
    enabled: true              # Master toggle (default: true)
    complexity_threshold: 5    # Min file count to trigger LLM classification
    max_subtasks: 4            # Max subtasks per composite task (range: 2-4)
    model: "haiku"             # Model for classification/decomposition (haiku = cheap)
```

Read via `readTalismanSection("work")?.task_decomposition`.

## Phase 1.1: Task Decomposition Entry Point

**Inputs**: `extractedTasks` (Array, post `extractFileTargets` + `scoreTaskComplexity`), `workConfig` (object)
**Outputs**: `extractedTasks` — replaced in-place with expanded list (atomic tasks unchanged, composite tasks replaced by their subtasks)
**Error handling**: Any LLM call failure → log warning, keep original task as-is (fail-open)

```javascript
// Phase 1.1: Task Decomposition
// Called after scoreTaskComplexity() completes, before detectAndResolveConflicts()
function runTaskDecomposition(extractedTasks, workConfig) {
  const decompositionConfig = workConfig?.task_decomposition
  const decompositionEnabled = decompositionConfig?.enabled ?? true

  if (!decompositionEnabled) {
    log("DECOMPOSITION: disabled via talisman — skipping")
    return extractedTasks
  }

  const complexityThreshold = decompositionConfig?.complexity_threshold ?? 5
  const maxSubtasks = decompositionConfig?.max_subtasks ?? 4

  log(`DECOMPOSITION: enabled (threshold=${complexityThreshold}, maxSubtasks=${maxSubtasks})`)

  const expandedTasks = []
  for (const task of extractedTasks) {
    const fileCount = (task.fileTargets || []).length
    const dirCount = (task.dirTargets || []).length
    const totalTargets = fileCount + dirCount

    // Fast-path: skip LLM for obviously atomic tasks (<=2 file targets, no multi-layer)
    if (totalTargets <= 2) {
      log(`DECOMPOSITION: task #${task.id} fast-path ATOMIC (${totalTargets} targets)`)
      expandedTasks.push(task)
      continue
    }

    // Heuristic pre-filter: use _complexityScore to skip LLM for medium tasks
    // _complexityScore is already computed by scoreTaskComplexity() — zero duplication
    if (totalTargets < complexityThreshold && !detectMultipleLayers(task.fileTargets || [])) {
      log(`DECOMPOSITION: task #${task.id} heuristic ATOMIC (score=${task._complexityScore}, targets=${totalTargets})`)
      expandedTasks.push(task)
      continue
    }

    // LLM classification: ATOMIC or COMPOSITE
    const classification = classifyTask(task)

    if (classification !== "COMPOSITE") {
      log(`DECOMPOSITION: task #${task.id} LLM-classified ATOMIC`)
      expandedTasks.push(task)
      continue
    }

    // LLM decomposition: split into 2-4 subtasks
    log(`DECOMPOSITION: task #${task.id} is COMPOSITE — decomposing`)
    const subtasks = decomposeTask(task, maxSubtasks)

    if (!subtasks || subtasks.length === 0) {
      log(`DECOMPOSITION: task #${task.id} decomposition returned empty — keeping original`)
      expandedTasks.push(task)
      continue
    }

    // Post-decomposition: assign IDs, parent reference, and inherited blockedBy
    for (let i = 0; i < subtasks.length; i++) {
      const subtask = subtasks[i]
      subtask.parent_task_id = task.id
      subtask.id = `${task.id}-sub-${i + 1}`
      subtask.type = subtask.type ?? task.type
      subtask.metadata = subtask.metadata ?? {}
      // Inherit parent's blockedBy plus any intra-subtask depends_on references
      const parentBlocked = (task.blockedBy || []).map(String)
      const subtaskDepends = (subtask.depends_on || []).map(d => `${task.id}-sub-${d}`)
      subtask.blockedBy = [...new Set([...parentBlocked, ...subtaskDepends])]
      delete subtask.depends_on  // normalize — strive uses blockedBy, not depends_on
    }

    // Post-decomposition validation: detect overlapping fileTargets across subtasks
    const validatedSubtasks = validateSubtaskFileOverlap(subtasks, task)
    log(`DECOMPOSITION: task #${task.id} → ${validatedSubtasks.length} subtasks`)
    expandedTasks.push(...validatedSubtasks)
  }

  return expandedTasks
}
```

## Layer Detection

**Inputs**: `fileTargets` (string[])
**Outputs**: `boolean` — true if targets span multiple architectural layers
**Error handling**: Empty or null input → returns false (fail-open)

```javascript
// Detects whether fileTargets span multiple architectural layers.
// Layers: api/routes, service/logic, model/schema, test, migration, config
// A task touching 2+ layers is a decomposition candidate regardless of file count.
const LAYER_PATTERNS = [
  { name: "api",        pattern: /\/api\/|\/routes?\/|\/controllers?\// },
  { name: "service",    pattern: /\/services?\/|\/handlers?\/|\/usecases?\// },
  { name: "model",      pattern: /\/models?\/|\/schema\/|\/entities?\// },
  { name: "test",       pattern: /\.(test|spec)\.(ts|js|py|go|rb)$|\/tests?\/|\/specs?\// },
  { name: "migration",  pattern: /\/migrations?\// },
  { name: "config",     pattern: /\.(config|env|yml|yaml|toml)\b|\/config\// },
]

function detectMultipleLayers(fileTargets) {
  if (!fileTargets || fileTargets.length === 0) return false
  const matchedLayers = new Set()
  for (const file of fileTargets) {
    for (const layer of LAYER_PATTERNS) {
      if (layer.pattern.test(file)) {
        matchedLayers.add(layer.name)
        break  // Each file counts toward at most one layer (first match wins)
      }
    }
    if (matchedLayers.size >= 2) return true  // Early exit
  }
  return matchedLayers.size >= 2
}
```

## LLM Classification

Uses haiku model for cost efficiency. Classification prompt defaults to ATOMIC —
only split when there is clear evidence of composite structure.

**Inputs**: `task` (object with subject, fileTargets, dirTargets, type)
**Outputs**: `"ATOMIC"` | `"COMPOSITE"` string
**Error handling**: Agent call failure or unrecognized output → return `"ATOMIC"` (fail-open, default safe)

```javascript
function classifyTask(task) {
  const model = readTalismanSection("work")?.task_decomposition?.model ?? "haiku"
  const fileList = (task.fileTargets || []).join(", ") || "(none)"

  const prompt = `You are a task classifier for a multi-agent coding workflow.

Task: "${task.subject}"
File targets: ${fileList}
Task type: ${task.type ?? "impl"}

Classify as ATOMIC (single worker, single concern) or COMPOSITE (should split).
Default to ATOMIC when uncertain. Only classify as COMPOSITE when ALL of:
- Task targets 5+ files across different architectural layers (api + service + model)
- Task description contains "and" connecting genuinely distinct concerns
- Splitting would produce independently deployable units of work

Respond with exactly one word: ATOMIC or COMPOSITE`

  let result = "ATOMIC"
  try {
    // Single-turn haiku call — fast and cheap
    result = Agent({
      subagent_type: "general-purpose",
      model: model,
      prompt: prompt,
      maxTurns: 1,
    }).trim().toUpperCase()
  } catch (e) {
    log(`DECOMPOSITION: classifyTask error for task #${task.id}: ${e.message} — defaulting ATOMIC`)
  }

  return result === "COMPOSITE" ? "COMPOSITE" : "ATOMIC"
}
```

## LLM Decomposition

Splits a COMPOSITE task into 2-4 atomic subtasks with non-overlapping file targets.

**Inputs**: `task` (object), `maxSubtasks` (number, default 4)
**Outputs**: `Array<{subject, fileTargets, dirTargets, depends_on}>` or empty array on failure
**Error handling**: JSON parse failure, empty result, or invalid schema → return [] (keep parent task)

```javascript
function decomposeTask(task, maxSubtasks) {
  const model = readTalismanSection("work")?.task_decomposition?.model ?? "haiku"
  const fileList = JSON.stringify(task.fileTargets || [])

  const prompt = `You are a task decomposer for a multi-agent coding workflow.

Task: "${task.subject}"
Description: ${task.description ?? "(none)"}
File targets: ${fileList}
Task type: ${task.type ?? "impl"}

Split this task into 2 to ${maxSubtasks} atomic subtasks. Each subtask must:
1. Be completable by ONE worker independently in ONE session
2. Have clear file boundaries with NO overlapping fileTargets
3. Have a descriptive subject line starting with a verb
4. List any intra-subtask dependencies via "depends_on" (array of sibling subtask indices, 0-based)

Respond with ONLY a JSON array (no markdown, no explanation):
[{"subject": "...", "fileTargets": [...], "dirTargets": [...], "depends_on": []}]`

  try {
    const raw = Agent({
      subagent_type: "general-purpose",
      model: model,
      prompt: prompt,
      maxTurns: 1,
    }).trim()

    // Strip optional markdown code fence
    const jsonStr = raw.replace(/^```json?\s*/i, "").replace(/\s*```$/, "").trim()
    const parsed = JSON.parse(jsonStr)

    if (!Array.isArray(parsed) || parsed.length < 2) {
      log(`DECOMPOSITION: decomposeTask returned ${parsed.length ?? 0} items — minimum 2 required`)
      return []
    }

    // Validate each subtask has required fields
    return parsed.filter(s => typeof s.subject === "string" && s.subject.length > 0)
  } catch (e) {
    log(`DECOMPOSITION: decomposeTask parse error for task #${task.id}: ${e.message}`)
    return []
  }
}
```

## Subtask File Overlap Validation

Post-decomposition check: if LLM assigned the same file to multiple subtasks,
serialize them via blockedBy rather than allowing concurrent writes.

**Inputs**: `subtasks` (Array), `parentTask` (object, for log context)
**Outputs**: `Array` — subtasks with blockedBy updated to prevent concurrent overlap
**Error handling**: Pure in-memory logic, no I/O — no error path needed

```javascript
function validateSubtaskFileOverlap(subtasks, parentTask) {
  const fileToSubtask = {}  // Map<filePath, subtaskId> — first subtask claiming file wins

  for (const subtask of subtasks) {
    const overlappingOwner = (subtask.fileTargets || []).find(f => fileToSubtask[f])
    if (overlappingOwner) {
      const ownerId = fileToSubtask[overlappingOwner]
      log(`DECOMPOSITION: overlap detected in parent #${parentTask.id}: file "${overlappingOwner}" claimed by both ${ownerId} and ${subtask.id} — serializing`)
      // Serialize: subtask must wait for the first claimer
      subtask.blockedBy = [...new Set([...(subtask.blockedBy || []), ownerId])]
    }
    // Register unclaimed files
    for (const f of (subtask.fileTargets || [])) {
      if (!fileToSubtask[f]) fileToSubtask[f] = subtask.id
    }
  }

  return subtasks
}
```

## inscription.json Re-write (EC-9)

After decomposition expands the task list, inscription.json MUST be re-written
to include subtask entries. The `validate-strive-worker-paths.sh` hook uses a
flat union of all task file targets — subtask entries automatically join the allowlist.

```javascript
// After runTaskDecomposition() returns the expanded list:
// Re-write inscription.json task_ownership with subtask entries
const taskOwnershipExpanded = {}
for (const task of expandedTasks) {
  const targets = { files: task.fileTargets || [], dirs: task.dirTargets || [] }
  if (targets.files.length > 0 || targets.dirs.length > 0) {
    taskOwnershipExpanded[String(task.id)] = {
      owner: task.assignedWorker || "unassigned",
      files: targets.files,
      dirs: targets.dirs,
      parent_task_id: task.parent_task_id ?? null,
    }
  }
}
// Overwrite existing inscription.json (same path as written in forge-team.md Team Creation)
Write(`${signalDir}/inscription.json`, JSON.stringify({
  ...existingInscription,
  task_ownership: taskOwnershipExpanded,
}))
```

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| LLM returns ATOMIC for a 10-file task | Respected — plan author's intent preserved |
| `decomposeTask` returns overlapping fileTargets | `validateSubtaskFileOverlap` serializes via blockedBy |
| `decomposeTask` returns `[]` (failure) | Original parent task kept in expandedTasks |
| `depends_on` references invalid sibling index | `blockedBy` construction skips out-of-range indexes |
| Task has 0 fileTargets | Fast-path ATOMIC (totalTargets <= 2), no LLM call |
| `decomposition.enabled: false` | Full skip, original extractedTasks returned unchanged |
| Subtask inherits blockedBy from parent | Parent's blockedBy always prepended to subtask.blockedBy |
| >4 subtasks returned by LLM | Caller uses `maxSubtasks` in prompt — filter to first maxSubtasks if LLM disobeys |
