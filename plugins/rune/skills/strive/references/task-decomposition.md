# Task Decomposition — strive Phase 0.5 Reference

LLM-driven task classification and decomposition. Runs after plan parsing (Phase 0), before file ownership assignment (Phase 1).

**Inputs**: `parsedTasks` (array from parse-plan.md), talisman work config
**Outputs**: `expandedTasks` (array — same size or larger than input)
**Error handling**: LLM timeout → classify as ATOMIC (safe default). Parse failure → keep original task.

## Configuration

```javascript
// readTalismanSection: "work"
const workConfig = readTalismanSection("work")
const decompositionEnabled = workConfig?.task_decomposition?.enabled ?? true
const complexityThreshold = workConfig?.task_decomposition?.complexity_threshold ?? 5
const maxSubtasks = workConfig?.task_decomposition?.max_subtasks ?? 4
const classificationModel = workConfig?.task_decomposition?.model ?? "haiku"
```

## Algorithm

```javascript
// Phase 0.5: Task Decomposition (after parse, before ownership assignment)
// Ref: parse-plan.md → extractTasks() produces parsedTasks
// Ref: file-ownership.md → consumes expandedTasks for ownership graph

if (!decompositionEnabled) {
  // Skip decomposition entirely, pass parsedTasks through unchanged
  expandedTasks = parsedTasks
  return expandedTasks
}

const expandedTasks = []
for (const task of parsedTasks) {
  // EC-7 Guard: skip classification for subtasks and gap tasks
  // Subtasks (from prior decomposition) and gap tasks (from discipline loop)
  // are always atomic — never re-decompose them
  if (task.parent_task_id || (task.id && String(task.id).startsWith("gap-"))) {
    expandedTasks.push(task)
    continue
  }

  const fileTargets = task.file_targets || []
  const fileCount = fileTargets.length
  const hasMultipleLayers = detectMultipleLayers(fileTargets)

  // Fast-path: skip LLM for obviously atomic tasks (<=2 files, single layer)
  if (fileCount <= 2 && !hasMultipleLayers) {
    expandedTasks.push(task)
    continue
  }

  // Heuristic pre-filter: below threshold and single layer → atomic
  if (fileCount < complexityThreshold && !hasMultipleLayers) {
    expandedTasks.push(task)
    continue
  }

  // LLM classification — use haiku for cost efficiency
  const classification = classifyTask(task)

  if (classification === "ATOMIC") {
    expandedTasks.push(task)
    continue
  }

  // LLM decomposition for COMPOSITE tasks
  const subtasks = decomposeTask(task, maxSubtasks)

  // SEC-003 FIX: Validate LLM-generated file_targets against path traversal
  // Security pattern: SAFE_FILE_PATH — see security-patterns.md
  const SAFE_FILE_PATH = /^[a-zA-Z0-9._\-\/]+$/
  for (const st of subtasks) {
    st.file_targets = (st.file_targets || []).filter(fp =>
      SAFE_FILE_PATH.test(fp) && !fp.includes('..') && !fp.startsWith('/')
    )
  }

  // Post-decomposition validation (EC-2): detect overlapping file targets
  const validated = validateSubtaskOverlaps(subtasks)

  // Assign parent reference and IDs
  for (let i = 0; i < validated.length; i++) {
    validated[i].parent_task_id = task.id
    validated[i].id = `${task.id}-sub-${i + 1}`
    // Inherit parent's blockedBy + subtask-specific depends_on
    // BACK-001 FIX: Resolve depends_on 0-based indices to actual subtask IDs
    // depends_on contains indices into the validated array, not task IDs
    const resolvedDeps = (validated[i].depends_on || []).map(depIdx => {
      if (typeof depIdx === 'number' && depIdx >= 0 && depIdx < validated.length) {
        return `${task.id}-sub-${depIdx + 1}`  // Convert index to subtask ID
      }
      return String(depIdx)  // Pass through if already a string ID
    })
    validated[i].blockedBy = [
      ...(task.blockedBy || []),
      ...resolvedDeps
    ]
    // Inherit parent's type if not set
    validated[i].type = validated[i].type || task.type
  }

  // Import dependency scanning (EC-3)
  scanImportDependencies(validated)

  expandedTasks.push(...validated)
}
```

## Layer Detection

```javascript
/**
 * Detect if file targets span 2+ architectural layers.
 * Uses path pattern matching — no AST required.
 *
 * @param {string[]} fileTargets - Array of file paths from the task
 * @returns {boolean} true if targets span multiple layers
 */
function detectMultipleLayers(fileTargets) {
  if (!fileTargets || fileTargets.length === 0) return false

  // Architectural layer patterns (order does not matter)
  const layerPatterns = [
    /\/(api|apis)\//,
    /\/(routes?|routers?)\//,
    /\/(services?|usecases?)\//,
    /\/(models?|entities|domain)\//,
    /\/(middleware|interceptors?)\//,
    /\/(utils?|helpers?|lib)\//,
    /\/(controllers?|handlers?)\//,
    /\/(repositories|repos?|dal)\//,
    /\/(views?|pages?|components?)\//,
    /\/(schemas?|validators?|dtos?)\//,
  ]

  const matchedLayers = new Set()
  for (const file of fileTargets) {
    for (let i = 0; i < layerPatterns.length; i++) {
      if (layerPatterns[i].test(file)) {
        matchedLayers.add(i)
      }
    }
  }

  return matchedLayers.size >= 2
}
```

## Classification

```javascript
/**
 * Classify a task as ATOMIC or COMPOSITE using lightweight LLM call.
 * Defaults to ATOMIC on any failure — safe default avoids over-fragmentation.
 *
 * @param {object} task - Parsed task with subject, file_targets, type
 * @returns {string} "ATOMIC" or "COMPOSITE"
 */
function classifyTask(task) {
  // SEC-001 FIX: Sanitize untrusted task fields before LLM prompt injection
  // task.subject originates from plan content (untrusted) — strip injection vectors
  const sanitize = (s) => String(s || "")
    .replace(/[\r\n]+/g, " ")        // Collapse newlines (prevent prompt line injection)
    .replace(/```[\s\S]*?```/g, "")   // Strip code fences
    .replace(/<[^>]*>/g, "")          // Strip HTML/XML tags
    .replace(/`[^`]+`/g, "")          // Strip inline code
    .slice(0, 200)                     // Cap length
    .trim()

  const safeSubject = sanitize(task.subject)
  const safeTargets = (task.file_targets || [])
    .filter(fp => /^[a-zA-Z0-9._\-\/]+$/.test(fp) && !fp.includes('..'))
    .slice(0, 20)

  const prompt = `You are a task classifier for a coding workflow.

Task: "${safeSubject}"
File targets: ${JSON.stringify(safeTargets)}
Type: ${task.type || "impl"}

Classify as ATOMIC (one worker, single concern) or COMPOSITE (should split).
Default to ATOMIC when uncertain. Only classify as COMPOSITE when:
- Task targets 5+ files across different architectural layers
- Task description contains "and" connecting distinct concerns
- Task involves both creation AND testing of multiple components

Respond with exactly one word: ATOMIC or COMPOSITE`

  try {
    // Agent() call with haiku model, 1-turn max for cost efficiency
    // classificationModel is read from talisman (default: "haiku")
    const result = Agent({
      prompt: prompt,
      model: classificationModel,
      maxTurns: 1,
      description: "Classify task complexity"
    })

    const trimmed = result.trim().toUpperCase()
    if (trimmed === "COMPOSITE" || trimmed === "ATOMIC") {
      return trimmed
    }
    // Unexpected response → default ATOMIC
    return "ATOMIC"
  } catch (e) {
    // LLM timeout or error → safe default
    warn(`Task classification failed for "${task.subject}": ${e.message}`)
    return "ATOMIC"
  }
}
```

## Decomposition

```javascript
/**
 * Decompose a COMPOSITE task into 2-N atomic subtasks using LLM.
 * On parse failure, returns the original task unchanged.
 *
 * @param {object} task - The composite task to split
 * @param {number} maxSubtasks - Maximum number of subtasks (from talisman config)
 * @returns {object[]} Array of subtask objects
 */
function decomposeTask(task, maxSubtasks) {
  const prompt = `You are a task decomposer for a coding workflow.

Original task: "${task.subject}"
File targets: ${JSON.stringify(task.file_targets || [])}
Type: ${task.type || "impl"}
Max subtasks: ${maxSubtasks}

Split this task into 2-${maxSubtasks} atomic subtasks. Each subtask MUST:
1. Be completable by one worker independently
2. Have clear file boundaries (NO overlapping file targets between subtasks)
3. Have a descriptive subject line
4. List any dependencies on other subtasks by index (0-based)

Return ONLY a JSON array:
[{"subject": "...", "file_targets": ["..."], "depends_on": [], "type": "impl|test"}]`

  try {
    const result = Agent({
      prompt: prompt,
      model: classificationModel,
      maxTurns: 1,
      description: "Decompose composite task"
    })

    // Parse JSON from LLM response — extract array from potential markdown fencing
    const jsonMatch = result.match(/\[[\s\S]*\]/)
    if (!jsonMatch) {
      warn(`Decomposition returned no JSON for "${task.subject}" — keeping original`)
      return [task]
    }

    const subtasks = JSON.parse(jsonMatch[0])

    // Validate structure
    if (!Array.isArray(subtasks) || subtasks.length < 2) {
      warn(`Decomposition returned <2 subtasks for "${task.subject}" — keeping original`)
      return [task]
    }

    // Cap at maxSubtasks
    return subtasks.slice(0, maxSubtasks)
  } catch (e) {
    // Parse failure or LLM error → keep original task
    warn(`Task decomposition failed for "${task.subject}": ${e.message}`)
    return [task]
  }
}
```

## Post-Decomposition Overlap Validation

```javascript
/**
 * Validate that decomposed subtasks have non-overlapping file targets.
 * If overlaps are found, serialize via depends_on links (same approach
 * as file-ownership.md conflict resolution).
 *
 * @param {object[]} subtasks - Array of subtask objects from decomposeTask()
 * @returns {object[]} Validated subtasks with overlap conflicts resolved
 */
function validateSubtaskOverlaps(subtasks) {
  const fileToSubtask = {}  // Map<filePath, subtaskIndex[]>

  for (let i = 0; i < subtasks.length; i++) {
    for (const file of (subtasks[i].file_targets || [])) {
      fileToSubtask[file] = fileToSubtask[file] || []
      fileToSubtask[file].push(i)
    }
  }

  // Detect overlaps and add depends_on links to serialize
  for (const [file, indices] of Object.entries(fileToSubtask)) {
    if (indices.length > 1) {
      // Chain serialization: subtask[1] depends on subtask[0], subtask[2] on subtask[1], etc.
      for (let j = 1; j < indices.length; j++) {
        const laterIdx = indices[j]
        const earlierIdx = indices[j - 1]
        subtasks[laterIdx].depends_on = subtasks[laterIdx].depends_on || []
        if (!subtasks[laterIdx].depends_on.includes(earlierIdx)) {
          subtasks[laterIdx].depends_on.push(earlierIdx)
        }
      }
    }
  }

  return subtasks
}
```

## Import Dependency Scanning

```javascript
/**
 * Scan subtask file targets for import dependencies between subtasks.
 * If subtask B's files import from subtask A's files, auto-add depends_on link.
 * Uses grep for import patterns — no full AST required.
 *
 * This catches implicit dependencies the LLM may not have declared (EC-3).
 *
 * @param {object[]} subtasks - Array of subtask objects (mutated in-place)
 */
function scanImportDependencies(subtasks) {
  // Build map: file path → subtask index (for owned files only)
  const fileOwner = {}
  for (let i = 0; i < subtasks.length; i++) {
    for (const file of (subtasks[i].file_targets || [])) {
      fileOwner[file] = i
    }
  }

  // For each subtask, check if its files import from another subtask's files
  for (let i = 0; i < subtasks.length; i++) {
    for (const file of (subtasks[i].file_targets || [])) {
      // Scan existing file for import patterns (only if file already exists)
      try {
        // Grep for common import patterns:
        // import ... from './path'  (JS/TS)
        // from path import ...      (Python)
        // use path::...             (Rust)
        const importResults = Grep({
          pattern: "(?:import .+ from ['\"]|from .+ import|use .+::)",
          path: file,
          output_mode: "content"
        })

        if (!importResults) continue

        // Check if any import path resolves to another subtask's file
        for (const [otherFile, ownerIdx] of Object.entries(fileOwner)) {
          if (ownerIdx === i) continue  // skip self-references
          // Simplified path matching: check if import line references the other file's basename
          const otherBasename = otherFile.replace(/.*\//, "").replace(/\.[^.]+$/, "")
          if (importResults.includes(otherBasename)) {
            subtasks[i].depends_on = subtasks[i].depends_on || []
            if (!subtasks[i].depends_on.includes(ownerIdx)) {
              subtasks[i].depends_on.push(ownerIdx)
            }
          }
        }
      } catch (e) {
        // File may not exist yet (new file) — skip silently
        continue
      }
    }
  }
}
```

## Integration

```javascript
// Called from parse-plan.md after extractTasks() completes
// Before file-ownership.md buildOwnershipGraph()

// Phase 0: parse-plan.md → parsedTasks
// Phase 0.5: task-decomposition.md → expandedTasks (this file)
// Phase 1: file-ownership.md → ownership graph from expandedTasks

const expandedTasks = runDecomposition(parsedTasks, workConfig)

// Log decomposition results for debugging
const originalCount = parsedTasks.length
const expandedCount = expandedTasks.length
if (expandedCount > originalCount) {
  log(`Task decomposition: ${originalCount} tasks → ${expandedCount} tasks (${expandedCount - originalCount} subtasks created)`)
}

// Pass expandedTasks to file-ownership.md for Phase 1
```

## Error Handling

| Scenario | Handling | Fallback |
|----------|----------|----------|
| LLM timeout during classification | Catch error, log warning | Classify as ATOMIC |
| LLM timeout during decomposition | Catch error, log warning | Keep original task |
| LLM returns invalid classification | Check for exact "ATOMIC"/"COMPOSITE" match | Default to ATOMIC |
| LLM returns non-JSON decomposition | Regex extraction fails | Keep original task |
| LLM returns <2 subtasks | Array length check | Keep original task |
| Subtask file targets overlap | Chain serialization via `depends_on` | Serialized execution |
| Import dependency scan fails | File may not exist yet | Skip silently |
| Decomposition disabled in talisman | `enabled: false` check | Pass-through (no-op) |
| Gap task or subtask re-enters decomposition | `parent_task_id` / `gap-` prefix guard (EC-7) | Skip, classify as ATOMIC |
| `file_targets` is empty or missing | `fileCount === 0` → fast-path | Classify as ATOMIC |

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Task with no file targets | Fast-path: 0 files ≤ 2, skip classification |
| Task with exactly `complexityThreshold` files | Enters LLM classification (threshold is inclusive) |
| LLM generates more subtasks than `maxSubtasks` | Sliced to `maxSubtasks` via `.slice(0, maxSubtasks)` |
| Single-file task targeting a barrel file (index.ts) | `detectMultipleLayers` checks path patterns, barrel files don't match layer patterns → ATOMIC |
| Subtask depends_on references use 0-based index | Resolved to subtask IDs (`{parent}-sub-{N+1}`) after decomposition |
| Convergence loop re-runs decomposition | EC-7 guard skips tasks with `parent_task_id` or `gap-` prefix |
| All tasks are already atomic (small plan) | Fast-path exits for all → `expandedTasks === parsedTasks` (no LLM calls) |
| Task type is "test" (trial-forger) | Inherits parent type; classification still applies — test tasks can also be composite |
