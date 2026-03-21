# Sibling Context — strive Phase 2 Reference

Worker prompt injection providing explicit sibling awareness. Each worker
receives a view of what other workers are implementing and which files they own,
preventing duplicate work and cross-worker file conflicts.

See [worker-prompts.md](worker-prompts.md) for the injection point (`siblingWorkerContext`).
See [file-ownership.md](file-ownership.md) for the `taskOwnership` map that feeds this module.

## Configuration

```yaml
work:
  sibling_awareness:
    enabled: true          # Inject sibling context into worker prompts (default: true)
    max_sibling_files: 5   # Max files shown per sibling entry (token cap, default: 5)
```

Read via `readTalismanSection("work")?.sibling_awareness`.

## buildSiblingContext()

Builds the sibling context block injected into each worker's spawn prompt.
Each worker receives a different view: they see all OTHER workers' tasks, not their own.

**Inputs**:
- `currentTask` (object) — the task being assigned to this worker
- `allTasks` (Array) — full expanded task list (post-decomposition)
- `taskOwnership` (object) — inscription.json `task_ownership` map
- `workConfig` (object) — resolved talisman `work` section

**Outputs**: `string` — markdown block to inject into worker prompt, or `""` if disabled or no siblings

**Error handling**: Any missing task or ownership entry → skip that sibling silently (fail-open, never throw)

```javascript
function buildSiblingContext(currentTask, allTasks, taskOwnership, workConfig) {
  const siblingConfig = workConfig?.sibling_awareness
  const siblingEnabled = siblingConfig?.enabled ?? true

  if (!siblingEnabled) return ""

  const maxSiblingFiles = siblingConfig?.max_sibling_files ?? 5
  const maxSiblingTasks = siblingConfig?.max_sibling_tasks ?? 10  // FIX SO-002: cap sibling count

  // Collect siblings: other tasks that are not yet completed and not the current task
  const siblings = allTasks
    .filter(t => String(t.id) !== String(currentTask.id) && t.status !== "completed")
    .map(t => {
      const ownership = taskOwnership[String(t.id)] || {}
      const files = (ownership.files || []).slice(0, maxSiblingFiles)
      const dirs = (ownership.dirs || []).slice(0, maxSiblingFiles)
      const allTargets = [...files, ...dirs.map(d => d + "*")]
      return {
        subject: t.subject || "(unnamed task)",
        targets: allTargets,
        owner: ownership.owner && ownership.owner !== "unassigned"
          ? ownership.owner
          : `Worker #${t.id}`,
        taskId: String(t.id),
      }
    })
    .filter(s => s.targets.length > 0)  // Only show siblings with known file targets
    .slice(0, maxSiblingTasks)  // FIX SO-002: cap to max_sibling_tasks to prevent token explosion

  if (siblings.length === 0) return ""

  // Build current task's own file list for the "YOU are assigned" line
  const myOwnership = taskOwnership[String(currentTask.id)] || {}
  const myFiles = [...(myOwnership.files || []), ...(myOwnership.dirs || []).map(d => d + "*")]
  const myTargetLine = myFiles.length > 0
    ? myFiles.join(", ")
    : "(targets not yet registered)"

  // SEC-004: Sanitize untrusted task subjects, owners, and file paths before prompt injection
  const sanitize = (s) => String(s || "").replace(/[\r\n]+/g, " ").replace(/<[^>]*>/g, "").replace(/[^\x20-\x7E]/g, "").slice(0, 200)

  const siblingLines = siblings
    .map(s => {
      const targetStr = s.targets.length > 0 ? s.targets.map(t => sanitize(t)).join(", ") : "(no declared targets)"
      return `- ${sanitize(s.owner)}: "${sanitize(s.subject)}" → ${targetStr}`
    })
    .join("\n")

  return `
## Sibling Context (DO NOT DUPLICATE)

Other workers are concurrently implementing these tasks:
${siblingLines}

YOU are assigned: "${currentTask.subject}" → ${myTargetLine}

RULES:
- Do NOT modify files assigned to other workers
- If you need an interface or type from another worker's domain, import it — do not redefine
- If you discover an unplanned dependency on another worker's output, note it in your Worker Report as SIBLING_DEP
- If a sibling's file does not yet exist (worker not started), create a minimal stub and note it as SIBLING_STUB
`
}
```

## Injection Point

The `siblingWorkerContext` variable is injected between the non-goals block and the
`YOUR LIFECYCLE:` section in the worker spawn prompt. This is distinct from:

- `shardContext` — shard plan context (shared across all workers in a shard run)
- `childWorkerContext` — hierarchical plan context (parent→child relationship)

```javascript
// In buildWorkerPrompt() (see worker-prompts.md):
const siblingContext = buildSiblingContext(
  claimedTask,
  allTasks,
  taskOwnership,
  readTalismanSection("work")
)
// Inject after nonGoalsBlock, before "YOUR LIFECYCLE:"
prompt += siblingContext
```

## Example Output

```markdown
## Sibling Context (DO NOT DUPLICATE)

Other workers are concurrently implementing these tasks:
- rune-smith-1: "Implement UserService with CRUD operations" → src/services/user.ts
- rune-smith-3: "Add user validation middleware" → src/middleware/validate.ts, src/types/user.ts

YOU are assigned: "Write User API routes" → src/routes/users.ts, src/routes/index.ts

RULES:
- Do NOT modify files assigned to other workers
- If you need an interface or type from another worker's domain, import it — do not redefine
- If you discover an unplanned dependency on another worker's output, note it in your Worker Report as SIBLING_DEP
- If a sibling's file does not yet exist (worker not started), create a minimal stub and note it as SIBLING_STUB
```

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Only one task in pool | `siblings` is empty → returns `""` (no block injected) |
| Sibling has no file targets | Filtered out — only siblings with declared targets are shown |
| `taskOwnership` entry missing for sibling | Treat as no targets → filtered out |
| `max_sibling_files: 0` | All target lists become empty → siblings filtered out → returns `""` |
| `sibling_awareness.enabled: false` | Early return `""` |
| Current task not yet in `taskOwnership` | `myTargetLine` shows "(targets not yet registered)" |
| Sibling task is already completed | Excluded from siblings list (status filter) |
| Subtasks from same parent | Treated as independent siblings — each sees the others' file targets |
