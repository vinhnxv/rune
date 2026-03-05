# Discovery Algorithm — Phase 0

TODO file discovery, pre-flight validation, and early exit conditions.

## Discovery Strategies

Three strategies in priority order:

1. **Explicit path**: User provides a `tmp/` path → scan that directory
2. **Active workflow**: Detect active workflow from `tmp/.rune-*.json` state files
3. **All workflows**: Scan all `tmp/*/todos/` directories for pending TODOs

## Implementation

```javascript
// Pseudocode utility functions used below:
// - Glob(pattern): Rune SDK file pattern match tool (returns string[] or null)
// - Read(path): Rune SDK file read tool
// - parseFrontmatter(content): Extract YAML frontmatter from markdown file

function discoverTodos(args) {
  const sourceFilter = args.source ?? null  // "work", "review", "pr-comment"

  let todoBases = []
  if (args.path) {
    todoBases = [args.path]
  } else {
    // Find active workflow's todo base
    const stateFiles = Glob("tmp/.rune-*.json")
    for (const sf of stateFiles) {
      const state = JSON.parse(Read(sf))
      if (state.status === "active") {
        todoBases.push(`tmp/${state.workflow}/${state.timestamp}/todos/`)
      }
    }
    // Fallback: scan all todo directories
    // Glob returns paths like "tmp/arc-123/todos/" — these ARE the todo dirs,
    // no dirname() needed (dirname would only strip the trailing slash).
    if (todoBases.length === 0) {
      todoBases = Glob("tmp/*/todos/") ?? []
    }
  }

  // Collect TODO files with status=pending or status=ready
  let todos = []
  for (const base of todoBases) {
    const sources = sourceFilter
      ? [join(base, sourceFilter)]
      : Glob(join(base, "*/"))

    for (const sourceDir of sources) {
      const files = Glob(join(sourceDir, "*.md"))
      for (const f of files) {
        if (f.includes("manifest")) continue
        const frontmatter = parseFrontmatter(Read(f))
        if (["pending", "ready", "interrupted"].includes(frontmatter.status)) {
          todos.push({ path: f, ...frontmatter })
        }
      }
    }
  }

  return todos
}
```

## Pre-flight Checks

### EDGE-001: Interrupted TODOs from crashed sessions

```javascript
// Scan for interrupted TODOs and reset
for (const todo of todos) {
  if (todo.status === "interrupted") {
    // Clear stale assigned_to and reset to ready
    const content = Read(todo.path)
    const updated = content.replace(
      /status:\s*interrupted/,
      "status: ready"
    ).replace(
      /assigned_to:\s*\S+/,
      ""
    )
    Write(todo.path, updated)
  }
}
```

### EDGE-002: Blocked TODOs with cascade dependencies

```javascript
// Reject TODOs whose dependencies are not complete.
// NOTE: `todos` only contains pending/ready/interrupted items (completed filtered at L49).
// To check dep completion, we need ALL todo statuses — query from filesystem directly.
function getTodoStatus(todoId, todoBases) {
  for (const base of todoBases) {
    const matches = Glob(`${base}*/*-${todoId}.md`) ?? []
    if (matches.length > 0) {
      const fm = parseFrontmatter(Read(matches[0]))
      return fm.status
    }
  }
  return undefined  // dep not found — treat as incomplete
}

// Detect circular dependencies before filtering (warn, don't deadlock)
const depGraph = new Map()
for (const todo of todos) {
  if (todo.dependencies?.length > 0) depGraph.set(todo.id, todo.dependencies)
}
function hasCycle(id, visited = new Set(), stack = new Set()) {
  visited.add(id); stack.add(id)
  for (const dep of depGraph.get(id) ?? []) {
    if (!visited.has(dep) && hasCycle(dep, visited, stack)) return true
    if (stack.has(dep)) return true
  }
  stack.delete(id); return false
}
for (const id of depGraph.keys()) {
  if (hasCycle(id)) {
    warn(`Circular dependency detected involving TODO ${id} — excluding from resolution`)
  }
}

const readyTodos = todos.filter(todo => {
  if (!todo.dependencies || todo.dependencies.length === 0) return true
  // Skip TODOs involved in circular dependencies
  if (hasCycle(todo.id)) return false
  return todo.dependencies.every(dep => {
    return getTodoStatus(dep, todoBases) === "complete"
  })
})
```

### EDGE-003: Concurrent session detection

```javascript
// Check for active resolve-todos sessions
const existingSessions = Glob("tmp/.rune-resolve-*.json")
for (const session of existingSessions) {
  const state = JSON.parse(Read(session))
  if (state.status === "active") {
    // Check owner_pid liveness
    const pidAlive = Bash(`kill -0 ${state.owner_pid} 2>/dev/null && echo alive`).trim()
    if (pidAlive === "alive") {
      warn("Active resolve-todos session detected. Aborting.")
      return
    }
  }
}
```

### EDGE-004: Empty TODO body

```javascript
// Check for non-whitespace content after frontmatter
for (const todo of todos) {
  const content = Read(todo.path)
  const bodyStart = content.indexOf('---', 4) + 3
  const body = content.slice(bodyStart).trim()
  if (body.length === 0) {
    todo.needs_clarification = true
    todo.clarification_reason = "Empty TODO body"
  }
}
```

### EDGE-005: TODO references deleted file

```javascript
// Validate file targets exist (Rune SDK has no exists() — use Glob for file check)
for (const todo of todos) {
  if (!todo.files || todo.files.length === 0) continue
  for (const file of todo.files) {
    const matches = Glob(file) ?? []
    if (matches.length === 0) {
      todo.needs_clarification = true
      todo.clarification_reason = `Referenced file not found: ${file}`
    }
  }
}
```

## Validation

```javascript
// Cap at reasonable limit
const MAX_TODOS = 50
if (todos.length > MAX_TODOS) {
  const answer = AskUserQuestion({
    question: `Found ${todos.length} TODOs. Process first ${MAX_TODOS}?`,
    options: [
      { label: "Process first 50", value: true },
      { label: "Cancel", value: false }
    ]
  })
  if (!answer) return
  todos = todos.slice(0, MAX_TODOS)
}

// Compute source statistics for summary
const bySource = {}
for (const todo of todos) {
  const source = todo.source ?? "unknown"
  bySource[source] = (bySource[source] ?? 0) + 1
}
const uniqueSources = Object.keys(bySource)

// Present summary
log(`Found ${todos.length} pending TODOs across ${uniqueSources.length} source(s)`)
for (const [source, count] of Object.entries(bySource)) {
  log(`  - ${source}: ${count} TODOs`)
}
```