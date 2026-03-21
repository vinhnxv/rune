# Sibling Context — strive Phase 2 Reference

Sibling awareness injection into worker spawn prompts. Gives each worker visibility into what other workers are concurrently implementing, preventing duplication and enabling cross-task imports.

**Inputs**: `currentTask` (object), `allTasks` (array), `taskOwnership` (object from inscription.json)
**Outputs**: sibling context markdown string (or empty string if no siblings)
**Error handling**: Missing ownership data → skip sibling (show subject only, no files). Empty task list → return empty string.

## Configuration

```javascript
// readTalismanSection: "work"
const workConfig = readTalismanSection("work")
const siblingEnabled = workConfig?.sibling_awareness?.enabled ?? true
const maxSiblingFiles = workConfig?.sibling_awareness?.max_sibling_files ?? 5
const maxSiblingTasks = workConfig?.sibling_awareness?.max_sibling_tasks ?? 10
```

## buildSiblingContext()

```javascript
/**
 * Build sibling context string for injection into worker spawn prompts.
 * Shows other workers' tasks and file assignments so the current worker
 * knows what's being worked on concurrently.
 *
 * @param {object} currentTask - The task being assigned to this worker
 * @param {object[]} allTasks - All tasks in the task pool
 * @param {object} taskOwnership - Map from task ID to {owner, files, dirs} (from inscription.json)
 * @returns {string} Markdown sibling context block, or empty string if disabled/no siblings
 */
function buildSiblingContext(currentTask, allTasks, taskOwnership) {
  if (!siblingEnabled) return ""

  // Filter to active siblings: not the current task, not completed
  let siblings = allTasks
    .filter(t => t.id !== currentTask.id && t.status !== "completed")
    .map(t => ({
      id: t.id,
      subject: t.subject,
      files: (taskOwnership[String(t.id)]?.files || []).slice(0, maxSiblingFiles),
      dirs: taskOwnership[String(t.id)]?.dirs || [],
      owner: taskOwnership[String(t.id)]?.owner || "unassigned",
      type: t.type || "impl"
    }))

  if (siblings.length === 0) return ""

  // EC-5: Cap sibling count to prevent token explosion
  // Sort by file proximity to current task before truncating
  if (siblings.length > maxSiblingTasks) {
    siblings = sortByFileProximity(siblings, currentTask, taskOwnership)
    siblings = siblings.slice(0, maxSiblingTasks)
  }

  // Build the current task's file list for the "YOU are assigned" line
  const currentFiles = taskOwnership[String(currentTask.id)]?.files || []

  // SEC-002 FIX: Sanitize untrusted task subjects before prompt injection
  // Task subjects originate from plan content — strip injection vectors
  const sanitize = (s) => String(s || "")
    .replace(/[\r\n]+/g, " ")
    .replace(/```[\s\S]*?```/g, "")
    .replace(/<[^>]*>/g, "")
    .replace(/`[^`]+`/g, "")
    .slice(0, 150)
    .trim()

  // Build markdown context block
  const siblingLines = siblings.map(s => {
    const fileList = s.files.length > 0 ? s.files.join(", ") : "(no files assigned)"
    return `- ${s.owner}: "${sanitize(s.subject)}" → files: ${fileList}`
  })

  return `
## Sibling Context (DO NOT DUPLICATE)

Other workers are concurrently implementing:
${siblingLines.join("\n")}

YOU are assigned: "${sanitize(currentTask.subject)}" → files: ${currentFiles.join(", ") || "(no files assigned)"}

RULES:
- Do NOT modify files assigned to other workers
- If you need an interface/type from another worker's domain, import it — do not redefine
- If you discover an unplanned dependency, note it in your Worker Report as SIBLING_DEP
`
}
```

## File Proximity Sorting

```javascript
/**
 * Sort siblings by number of shared path segments with currentTask's file_targets.
 * Siblings with more file path overlap are more relevant (closer architectural area).
 * Used when sibling count exceeds maxSiblingTasks (EC-5 token cap).
 *
 * @param {object[]} siblings - Sibling task objects with files array
 * @param {object} currentTask - The current worker's task
 * @param {object} taskOwnership - Ownership map for file lookup
 * @returns {object[]} Siblings sorted by proximity (most relevant first)
 */
function sortByFileProximity(siblings, currentTask, taskOwnership) {
  const currentFiles = taskOwnership[String(currentTask.id)]?.files || []
  if (currentFiles.length === 0) return siblings  // no basis for sorting

  // Extract directory segments from current task's files
  const currentDirs = new Set()
  for (const file of currentFiles) {
    const segments = file.split("/")
    // Build progressive path prefixes: src/, src/services/, src/services/user/
    for (let i = 1; i < segments.length; i++) {
      currentDirs.add(segments.slice(0, i).join("/"))
    }
  }

  // Score each sibling by shared path segments
  return siblings
    .map(s => {
      let score = 0
      for (const file of s.files) {
        const segments = file.split("/")
        for (let i = 1; i < segments.length; i++) {
          if (currentDirs.has(segments.slice(0, i).join("/"))) {
            score++
          }
        }
      }
      return { ...s, proximityScore: score }
    })
    .sort((a, b) => b.proximityScore - a.proximityScore)
}
```

## Integration

```javascript
// Called from worker-prompts.md buildWorkerPrompt()
// Injected after task description, before non-goals section

// Phase 1: file-ownership.md → taskOwnership written to inscription.json
// Phase 2: worker spawn → buildSiblingContext() called per worker

const siblingContext = buildSiblingContext(claimedTask, allTasks, taskOwnership)

// Insert into worker spawn prompt
if (siblingContext) {
  workerPrompt += siblingContext
}
```

## Error Handling

| Scenario | Handling | Fallback |
|----------|----------|----------|
| Sibling awareness disabled in talisman | `enabled: false` check | Return empty string (no-op) |
| No active siblings (all completed) | Filter produces empty array | Return empty string |
| Missing taskOwnership for a sibling | `files` defaults to `[]` | Show sibling with "(no files assigned)" |
| Missing taskOwnership for current task | `currentFiles` defaults to `[]` | Show "(no files assigned)" for self |
| Sibling count exceeds `maxSiblingTasks` | Sort by proximity, truncate | Show top N most relevant siblings |
| File proximity sort with no current files | `currentFiles.length === 0` guard | Skip sorting, return unsorted (original order) |
| Task ID type mismatch (number vs string) | `String(t.id)` coercion in lookup | Consistent string comparison |

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Single-task plan (no siblings) | Filter returns empty → empty string returned |
| All siblings have no file targets | Each shows "(no files assigned)" — still useful for subject awareness |
| Current task has subtasks from decomposition | Subtasks appear as separate siblings — each with own scope |
| Gap tasks in sibling list | Included like any other task — gap tasks have file targets too |
| Worker reassignment mid-execution | Sibling context reflects state at spawn time — stale but acceptable for v1 |
| Blocked siblings (not yet started) | Included — worker should know about future concurrent work |
| `maxSiblingTasks: 0` configured | Filter produces empty after truncation → empty string returned |
