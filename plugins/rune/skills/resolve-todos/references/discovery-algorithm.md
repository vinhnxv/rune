# Discovery Algorithm — Phase 0

TODO file discovery, pre-flight validation, and early exit conditions.

## Discovery Strategies

Three strategies in priority order:

1. **Explicit path**: User provides a `tmp/` path → scan that directory
2. **Active workflow**: Detect active workflow from `tmp/.rune-*.json` state files
3. **All workflows**: Scan all `tmp/*/todos/` directories for pending TODOs

## Implementation

```javascript
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
    // Fallback: scan all
    if (todoBases.length === 0) {
      todoBases = Glob("tmp/*/todos/").map(p => dirname(p))
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
// Reject TODOs whose dependencies are not complete
const readyTodos = todos.filter(todo => {
  if (!todo.dependencies || todo.dependencies.length === 0) return true
  return todo.dependencies.every(dep => {
    const depTodo = todos.find(t => t.id === dep)
    return depTodo?.status === "complete"
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
// Validate file targets exist
for (const todo of todos) {
  if (!todo.files || todo.files.length === 0) continue
  for (const file of todo.files) {
    if (!exists(file)) {
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

// Present summary
log(`Found ${todos.length} pending TODOs across ${uniqueSources.length} source(s)`)
for (const [source, count] of Object.entries(bySource)) {
  log(`  - ${source}: ${count} TODOs`)
}
```