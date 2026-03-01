# Failure Handling — Interactive E2E Test Failures

Interactive failure resolution for standalone `/rune:test-browser` mode. When an E2E
assertion fails, the user is presented with three options: fix the code inline, create a
deferred todo, or skip the route.

**Arc Phase 7.7**: When `standalone=false`, failures are recorded directly in the test
report without interactive prompts. All routes run and all failures are aggregated.

## Core Failure Handling Flow

```
handleFailure(route, failure, sessionName, standalone) → "fixed" | "todo-created" | "skipped" | "aborted"

  if standalone is false:
    // Arc mode — no interactive prompt, record and continue
    recordFailureToReport(route, failure)
    return "skipped"

  --- Standalone interactive path ---
  response = AskUserQuestion(
    `E2E test failure on route: ${route}

Assertion: ${failure.assertion}
Error: ${failure.message}
Screenshot (if available): ${failure.screenshot}

Options:
  - FIX    → Analyze and fix the code now, then re-test
  - TODO   → Create a todo item and continue to next route
  - SKIP   → Skip this route (no todo)
  - ABORT  → Stop the entire test run`
  )

  normalized = response.trim().toUpperCase()

  if normalized starts with "F":
    result = handleFixNow(route, failure, sessionName)
    return result  // "fixed" or "skipped" (if fix failed)

  if normalized starts with "T":
    handleCreateTodo(route, failure, sessionName)
    return "todo-created"

  if normalized starts with "S":
    return "skipped"

  if normalized starts with "A":
    return "aborted"

  // Unrecognized → default to todo (preserves info)
  handleCreateTodo(route, failure, sessionName)
  return "todo-created"
```

## Fix Now Handler

```
handleFixNow(route, failure, sessionName) → "fixed" | "skipped"

  // Step 1: Map route to source files
  sourceFiles = mapRouteToSourceFiles(route)
  if sourceFiles is empty:
    WARN: "Cannot map route '${route}' to source files. Falling back to todo."
    handleCreateTodo(route, failure, sessionName)
    return "skipped"

  // Step 2: Read source files for context
  contents = []
  for each file in sourceFiles:
    validate: file must match SAFE_PATH_PATTERN (/^[a-zA-Z0-9._\/-]+$/)
    validate: file must not contain ".." (path traversal guard)
    validate: file must be under project root (no absolute paths)
    contents.push({ path: file, content: Read(file) })

  // Step 3: Analyze failure and produce fix
  // Present to Claude: route, failure message, assertion, source file contents
  // Claude makes targeted edits to source files

  // Step 4: Re-test the route with concrete pass criteria
  // Navigate fresh session to avoid stale state
  newSessionName = sessionName + "-fix-verify"
  navigate(route, session: newSessionName)
  Bash(`agent-browser wait --load networkidle`)

  snapshotText = Bash(`agent-browser snapshot -i --text`)
  consoleErrors = Bash(`agent-browser errors`)

  // Concrete pass criteria (Gap 6.1)
  passed = (
    consoleErrors.count == 0
    AND snapshotText.length > 50           // page rendered meaningful content
    AND originalAssertionPasses(route, failure.assertion)  // positive assertion holds
  )

  Bash(`agent-browser close --session "${newSessionName}"`)

  if passed:
    log: "FIXED: Route '${route}' now passes after code change."
    return "fixed"
  else:
    log: "FIX ATTEMPT FAILED: Route '${route}' still failing after code change."
    WARN: "Fix attempt did not resolve the failure. Creating todo and continuing."
    handleCreateTodo(route, failure, sessionName)
    return "skipped"
```

### Original Assertion Re-check (Gap 6.1 — Concrete Criteria)

```
originalAssertionPasses(route, assertion) → boolean

  assertion.type == "element-visible":
    result = Bash(`agent-browser find testid "${assertion.testid}"`)
    return result contains "found"

  assertion.type == "text-present":
    snapshotText = Bash(`agent-browser snapshot --text`)
    return snapshotText.includes(assertion.text)

  assertion.type == "no-console-errors":
    errors = Bash(`agent-browser errors`)
    return errors is empty or errors == "[]"

  assertion.type == "url-match":
    currentUrl = Bash(`agent-browser eval --stdin <<'EOF'
      window.location.href
    EOF`)
    return currentUrl.includes(assertion.pattern)

  default:
    // Unknown assertion type — use snapshot length heuristic only
    snapshotText = Bash(`agent-browser snapshot -i --text`)
    return snapshotText.length > 50
```

## Create Todo Handler

```
handleCreateTodo(route, failure, sessionName) → void

  sourceFiles = mapRouteToSourceFiles(route)
  today = Bash(`date +%Y-%m-%d`).trim()
  issueId = generateSequentialId()  // 3-digit padded, e.g. "001"

  todoDir = "tmp/test-browser/${sessionName}/todos/test-browser"
  todoFileName = "${issueId}-e2e-${sanitizeRouteName(route)}.md"
  todoPath = "${todoDir}/${todoFileName}"

  // Validate write path (SAFE_PATH_PATTERN reuse)
  validate: todoPath must match /^tmp\/[a-zA-Z0-9._\/-]+\.md$/
  validate: todoPath must not contain ".."

  Bash(`mkdir -p "${todoDir}"`)
  Write(todoPath, buildTodoContent(issueId, route, failure, sessionName, sourceFiles, today))
  log: "TODO: Created ${todoPath}"
```

### Todo Content Schema (v2)

```yaml
---
schema_version: 2
status: pending
priority: p2
issue_id: "{issueId}"
source: test-browser
source_ref: "test-browser/{sessionName}"
finding_id: "E2E-{issueId}"
finding_severity: "P2"
tags: ["e2e", "browser", "test-failure"]
dependencies: []
files: ["{sourceFile1}", "{sourceFile2}"]
assigned_to: null
created: "{today}"
updated: "{today}"
resolution: null
resolution_reason: ""
resolved_by: ""
resolved_at: ""
claimed_at: ""
completed_by: ""
completed_at: ""
mend_fixer_claim: ""
duplicate_of: ""
related_todos: []
workflow_chain: ["test-browser:{sessionName}"]
execution_order: null
wave: null
---

# E2E Failure: {route}

## Problem Statement

E2E browser test failed on route `{route}` during session `{sessionName}`.

## Findings

- **Finding ID**: E2E-{issueId}
- **Route**: `{route}`
- **Assertion**: {failure.assertion}
- **Error**: {failure.message}
- **Screenshot**: `{failure.screenshot}` (if captured)

## Proposed Solutions

### Option 1: Fix Assertion Failure

**Approach**: Investigate and fix the failing component in {sourceFiles}
**Effort**: Unknown — requires root cause analysis
**Risk**: Low

## Recommended Action

_Run `/rune:test-browser {route}` after fixing to verify resolution._

## Acceptance Criteria

- [ ] Route `{route}` passes E2E browser test
- [ ] No console errors during page load
- [ ] Snapshot length > 50 characters (page renders meaningful content)
- [ ] Original assertion holds: {failure.assertion}

## Work Log

### {today} - Initial Discovery

**By**: test-browser
**Source**: test-browser/{sessionName}

**Actions**:
- Created from E2E test failure on {route}

**Learnings**:
- Failure occurred during standalone /rune:test-browser run

## Status History

| Timestamp | From | To | Actor | Reason |
|-----------|------|----|-------|--------|
| {today}T00:00:00Z | — | pending | test-browser:{sessionName} | Created from E2E failure on {route} |
```

## Route-to-Source-File Mapping

Uses the shared `mapRouteToSourceFiles()` function from [file-route-mapping.md](../../testing/references/file-route-mapping.md).
Do NOT duplicate the framework detection logic here — always defer to the shared reference.

```
sourceFiles = mapRouteToSourceFiles(route)
// See testing/references/file-route-mapping.md for framework detection and candidate resolution
// Returns: string[] of existing source files that map to this route
```

## Safety: Write Path Containment

All Write() calls MUST target paths under `tmp/`:

```
SAFE_TODO_PATH_PATTERN = /^tmp\/[a-zA-Z0-9._\/-]+\.md$/

validate(path):
  if !SAFE_TODO_PATH_PATTERN.test(path):
    ABORT: "Unsafe write path rejected: ${path}"
  if path.includes(".."):
    ABORT: "Path traversal rejected: ${path}"
  return true
```

This mirrors the SAFE_PATH_PATTERN validation in the testing skill.

## Helper

```
sanitizeRouteName(route) → string
  // /users/profile → users-profile
  // / → root
  return new URL(route).pathname
    .replace(/^\//, "")
    .replace(/\//g, "-")
    .replace(/[^a-zA-Z0-9-]/g, "")
    .substring(0, 40) || "root"
```
