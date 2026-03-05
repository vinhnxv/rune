# Fixer Protocol — Phase 4

Fixer agent prompts, 8-field fix report schema, atomic write pattern, and large group splitting.

## Fixer Agent Prompt Template

```markdown
You are a TODO resolution fixer. Your job is to apply fixes for verified TODOs.

## ANCHOR — TRUTHBINDING
Apply ONLY the fixes described in the TODOs. Do NOT make additional changes.
Follow existing code patterns exactly.

## File: {file}

## Context Summary:
<context nonce="{nonce}">
{contextSummary}
</context>

## TODOs to Fix:
{validTodos}

## Constraints
- You may ONLY modify: {file}
- Follow existing naming conventions
- Match existing error handling patterns
- Do NOT add new dependencies
- Keep changes minimal and focused

## Output
Write to: tmp/resolve-todos-{timestamp}/fixes/{file}.json
Format:
{
  "file": "{file}",
  "fixes": [
    {
      "todo_id": "001",
      "file": "src/auth.ts",
      "line_hint": 42,
      "status": "FIXED|FAILED|SKIPPED",
      "resolution": "description of what changed",
      "evidence_before": "max 200 chars of original code",
      "evidence_after": "max 200 chars of fixed code",
      "inner_flame": { "grounding": true, "completeness": true, "no_side_effects": true },
      "skip_reason": null,
      "manual_replay_hint": null
    }
  ]
}

## RE-ANCHOR
Only modify the specific file assigned to you. All other files are read-only.
Mark task complete when done.
```

## 8-Field Fix Report Schema

```typescript
interface FixReport {
  file: string
  fixes: FixEntry[]
}

interface FixEntry {
  todo_id: string          // e.g., "001"
  file: string             // e.g., "src/auth.ts"
  line_hint: number        // Approximate line number
  status: "FIXED" | "FAILED" | "SKIPPED"
  resolution: string       // Description of what changed
  evidence_before: string  // Max 200 chars of original code
  evidence_after: string   // Max 200 chars of fixed code
  inner_flame: {
    grounding: boolean
    completeness: boolean
    no_side_effects: boolean
  }
  skip_reason: string | null
  manual_replay_hint: string | null
}
```

## Atomic Write Pattern

```javascript
// Write to temp file first, then atomic rename
// Use full path slug (not basename) to prevent collision for same-named files in different dirs.
// e.g., src/auth/index.ts → src__auth__index.ts
const fileSlug = file.replace(/\//g, '__')
const reportJson = JSON.stringify(fixReport, null, 2)
// Write directly to final path (no tmp+mv pattern — fixers cannot use Bash tool)
Write(`tmp/resolve-todos-${timestamp}/fixes/${fileSlug}.json`, reportJson)
// THEN mark task complete
TaskUpdate({ taskId, status: "completed" })
```

## Large File Group Splitting

Cap per `MAX_TODOS_PER_FIXER` (talisman default: 8). Files exceeding the cap split into sequential sub-groups:

```javascript
const MAX_TODOS_PER_FIXER = talisman?.resolve_todos?.max_per_fixer ?? 8
if (todos.length > MAX_TODOS_PER_FIXER) {
  const chunks = chunk(todos, MAX_TODOS_PER_FIXER)
  const chunkTaskIds = []  // Track task IDs for blockedBy chaining
  const fileSlug = file.replace(/\//g, '__')
  // Each chunk gets its own fixer; chunk N+1 blockedBy chunk N
  for (const [idx, chunkItems] of chunks.entries()) {
    const taskId = TaskCreate({
      subject: `Fix chunk ${idx + 1} for ${fileSlug}`,
      blockedBy: idx > 0 ? [chunkTaskIds[idx - 1]] : []
    })
    chunkTaskIds.push(taskId)
    // Spawn fixer for this chunk
  }
}
```

## buildWaves() Function Definition

Constructs sequential waves of file groups, ensuring no two agents in the same wave share a file.
Returns `Array<Map<file, todos[]>>`. Each wave has at most `maxPerWave` entries.

```javascript
function buildWaves(fileGroups, { maxPerWave = 5 }) {
  const waves = []
  const entries = [...fileGroups.entries()]

  for (const [file, todos] of entries) {
    let placed = false
    for (const wave of waves) {
      // Check capacity and file uniqueness
      if (wave.size < maxPerWave && !wave.has(file)) {
        wave.set(file, todos)
        placed = true
        break
      }
    }
    if (!placed) {
      const newWave = new Map([[file, todos]])
      waves.push(newWave)
    }
  }

  return waves  // Array<Map<string, Todo[]>>
}
```

**Note**: Since Phase 1 groups all TODOs for a file into one entry, the no-overlap invariant is trivially satisfied — each file appears in exactly one entry. Waves only matter when `fileGroups.size > maxPerWave` (batching for concurrency control).

## No-Overlap Wave Invariant

**Hard requirement**: No two fixers in the same wave may share a file in their `file_group`.

```javascript
// Each wave is a Map<file, todos[]> (consistent with SKILL.md iteration pattern).
// This invariant check iterates the wave's entries to detect file conflicts.
const waveFiles = new Set()
const deferredToNextWave = []
for (const [file, fileTodos] of wave) {
  if (waveFiles.has(file)) {
    deferredToNextWave.push([file, fileTodos])
  } else {
    waveFiles.add(file)
  }
}
// deferredToNextWave items join the next wave
```

## Stale Context Detection

Capture SHA at Phase 2 context write time and compare at Phase 4 fixer spawn:

```javascript
// Phase 2: record SHA when context was gathered
contextMeta.sha = Bash("git rev-parse HEAD").trim()

// Phase 4: check for drift before spawning fixer
const currentSha = Bash("git rev-parse HEAD").trim()
if (currentSha !== contextMeta.sha) {
  // Identify which files changed since context was gathered
  const changedFiles = Bash(`git diff --name-only ${contextMeta.sha} ${currentSha}`).trim().split('\n')
  for (const [file, fileTodos] of validFileGroups) {
    if (!changedFiles.includes(file)) continue
    // File was modified externally — validate each TODO's target still exists
    const fileContent = Read(file)
    const lines = fileContent.split('\n')
    for (const todo of fileTodos) {
      const snippet = extractSnippet(todo.description)
      if (!snippet || snippet.trim().length < 5) continue
      const actualLine = lines.findIndex(l => l.includes(snippet))
      if (actualLine === -1 || Math.abs(actualLine - (todo.line_hint ?? 0)) > 10) {
        todo.status = "SKIPPED"
        todo.skip_reason = `file modified externally (SHA drift: ${contextMeta.sha.slice(0,7)}→${currentSha.slice(0,7)})`
      }
    }
  }
  // Remove fully-skipped file groups from validFileGroups
  for (const [file, fileTodos] of validFileGroups) {
    if (fileTodos.every(t => t.status === "SKIPPED")) {
      validFileGroups.delete(file)
    }
  }
}
```