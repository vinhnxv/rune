---
name: resolve-todos
description: |
  Resolve file-based TODOs using Agent Teams with verify-before-fix pipeline.
  Each TODO is reviewed before any fix is applied, preventing hallucinated fixes.
  Uses parallel batch processing with file ownership enforcement.
  Keywords: resolve, todos, fix, batch, parallel, verify, file-todos.

  <example>
  user: "/rune:resolve-todos"
  assistant: "Discovering pending TODOs from active workflow..."
  </example>

  <example>
  user: "/rune:resolve-todos review --dry-run"
  assistant: "Dry run: analyzing review TODOs without applying fixes..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[source] [--dry-run] [--batch-size N]"
allowed-tools:
  - Agent
  - TaskCreate
  - TaskList
  - TaskUpdate
  - TaskGet
  - TeamCreate
  - TeamDelete
  - SendMessage
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# /rune:resolve-todos — Agent Teams Parallel Resolution

Resolves file-based TODOs using Agent Teams with a **verify-before-fix** pipeline. Combines parallel batch processing with hallucination prevention patterns.

**Load skills**: `file-todos`, `inner-flame`, `zsh-compat`, `roundtable-circle`, `rune-orchestration`, `polling-guard`

## Overview

```
Phase 0: Discovery & Parse ─── Scan sources, parse TODO files, validate
    ↓
Phase 1: Triage & Ownership ── Group by file, assign ownership, detect dependencies
    ↓
Phase 2: Codebase Deep Dive ── Context agents read affected files + surrounding code
    ↓
Phase 3: Review Gate ───────── Verify each TODO is real + actionable
    ↓
Phase 4: Batch Fix ─────────── Wave-based fixer agents resolve verified TODOs
    ↓
Phase 5: Quality Gate ──────── Lint, typecheck, test (once, after all fixes)
    ↓
Phase 6: Report & Commit ───── Summary, optional commit + push
    ↓
Phase 7: Cleanup ───────────── Team shutdown, state file cleanup
```

## Usage

```
/rune:resolve-todos                          # All pending TODOs from active workflow
/rune:resolve-todos work                     # Only source=work TODOs
/rune:resolve-todos review                   # Only source=review TODOs
/rune:resolve-todos tmp/work/1234/todos/     # Specific todo directory
/rune:resolve-todos --dry-run                # Analyze + review only, no fixes
/rune:resolve-todos --batch-size 5           # Override batch size (default: 5)
```

## Phase 0: Discovery & Parse

See [discovery-algorithm.md](references/discovery-algorithm.md) for full details.

**Summary**: Parse arguments, discover TODO files, validate count and status.

```javascript
// Parse source filter from $ARGUMENTS
const args = "$ARGUMENTS"
const sourceFilter = args.match(/--source[=\s]+(\S+)/)?.[1] ?? args.split(' ')[0] ?? null
const dryRun = args.includes("--dry-run")
const batchSize = parseInt(args.match(/--batch-size[=\s]+(\d+)/)?.[1] ?? "5")

// Discover TODO files
const todos = discoverTodos({ sourceFilter, path: null })
if (todos.length === 0) {
  log("No pending TODOs found. Nothing to resolve.")
  return
}

// Cap at reasonable limit
const MAX_TODOS = 50
if (todos.length > MAX_TODOS) {
  const answer = AskUserQuestion(`Found ${todos.length} TODOs. Process first ${MAX_TODOS}?`)
  if (!answer) return
  todos = todos.slice(0, MAX_TODOS)
}
```

## Phase 1: Triage & Ownership

Group TODOs by file, detect cross-file dependencies, create inscription contract.

```javascript
// Group by file (one fixer per file group prevents conflicts)
const fileGroups = new Map()
for (const todo of todos) {
  const targetFiles = todo.files ?? []
  if (targetFiles.length === 0) {
    fileGroups.get("__unscoped__")?.push(todo) ?? fileGroups.set("__unscoped__", [todo])
    continue
  }
  const primary = targetFiles[0]
  fileGroups.get(primary)?.push(todo) ?? fileGroups.set(primary, [todo])
}

// Write inscription.json for hook enforcement
const timestamp = Date.now()
const inscription = {
  workflow: "rune-resolve-todos",
  timestamp: timestamp,
  verifiers: [],
  fixers: [],
  task_ownership: {}
}
Write("tmp/.rune-signals/rune-resolve-todos/inscription.json", JSON.stringify(inscription))
```

## Phase 2: Codebase Deep Dive

Context gathering agents read affected files in parallel. See references for full protocol.

```javascript
// Team bootstrap
TeamCreate({ team_name: `rune-resolve-todos-${timestamp}` })

// Spawn context gathering agents (Explore, read-only)
for (const [file, todos] of fileGroups) {
  if (file === "__unscoped__") continue
  Agent({
    name: `context-${fileIdx}`,
    subagent_type: "Explore",
    team_name: `rune-resolve-todos-${timestamp}`,
    model: "haiku",
    prompt: `Gather context for ${file}. Read the file, identify imports, callers, and existing patterns.`,
    run_in_background: true
  })
}

// Wait with timeout
waitForCompletion(teamName, contextTaskCount, { timeoutMs: 180000 })
```

## Phase 3: Review Gate (Verify Before Fix)

**Critical differentiator**: Each TODO is reviewed BEFORE any fix is applied.

See [verify-protocol.md](references/verify-protocol.md) for verifier prompts and verdict taxonomy.

```javascript
// Spawn verifiers (use custom todo-verifier agent)
for (const wave of verifierWaves) {
  for (const [file, todos] of wave) {
    Agent({
      name: `verifier-${fileIdx}`,
      subagent_type: "general-purpose",
      team_name: `rune-resolve-todos-${timestamp}`,
      prompt: `You are todo-verifier. Verify each TODO in ${file}.

      Verdict taxonomy: VALID | FALSE_POSITIVE | ALREADY_FIXED | NEEDS_CLARIFICATION | PARTIAL | DUPLICATE | DEFERRED

      Confidence thresholds:
      - VALID: >= 0.70
      - FALSE_POSITIVE: >= 0.85
      - ALREADY_FIXED: >= 0.80

      Write verdicts to: tmp/resolve-todos-${timestamp}/verdicts/${basename(file)}.json`,
      run_in_background: true
    })
  }
  waitForCompletion(teamName, wave.length, { timeoutMs: 300000 })
}
```

## Phase 4: Batch Fix

Wave-based fixer agents resolve verified TODOs. See [fixer-protocol.md](references/fixer-protocol.md).

```javascript
// Spawn fixers (reuse mend-fixer agent)
for (const wave of fixerWaves) {
  for (const [file, validTodos] of wave) {
    Agent({
      name: `fixer-${fileIdx}`,
      subagent_type: "general-purpose",
      team_name: `rune-resolve-todos-${timestamp}`,
      prompt: `Fix the following TODOs in ${file}:
      ${validTodos.map(t => `- [${t.issue_id}] ${t.description}`).join('\n')}

      Write fix report to: tmp/resolve-todos-${timestamp}/fixes/${basename(file)}.json`,
      run_in_background: true
    })
  }
  waitForCompletion(teamName, wave.length, { timeoutMs: 300000 })
}
```

## Phase 5: Quality Gate

See [quality-gate.md](references/quality-gate.md) for talisman integration.

```javascript
const qualityCommands = ["npm run lint --if-present", "npm run typecheck --if-present"]
let qualityPassed = true
for (const cmd of qualityCommands) {
  const result = Bash(cmd, { timeout: 120000 })
  if (result.exitCode !== 0) {
    qualityPassed = false
    warn(`Quality check failed: ${cmd}`)
  }
}
```

## Phase 6: Report & Commit

```javascript
const summary = `
# TODO Resolution Summary

| Category | Count |
|----------|-------|
| Input TODOs | ${todos.length} |
| Verified VALID | ${validCount} |
| Successfully FIXED | ${fixedCount} |
| FALSE POSITIVE | ${falsePositiveCount} |
| FAILED to fix | ${failedCount} |
`
Write("tmp/resolve-todos-${timestamp}/summary.md", summary)
```

## Phase 7: Cleanup

```javascript
// 1. Dynamic member discovery
const allMembers = teamConfig.members.map(m => m.name).filter(n => /^[a-zA-Z0-9_-]+$/.test(n))

// 2. Shutdown request to all
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Workflow complete" })
}

// 3. Grace period
Bash("sleep 15")

// 4. TeamDelete with retry
for (const delay of [0, 5000, 10000]) {
  if (delay > 0) Bash(`sleep ${delay / 1000}`)
  try { TeamDelete(); break } catch (e) { /* retry */ }
}

// 5. Filesystem fallback if needed
TeamDelete() // Best effort
```

## Error Handling

| Error | Recovery |
|-------|----------|
| No pending TODOs found | Exit cleanly with message |
| TODO file parse error | Skip that TODO, log warning |
| Context agent timeout (>3 min) | Proceed with partial context |
| Verifier agent timeout (>5 min) | Mark as NEEDS_CLARIFICATION |
| Fixer agent timeout (>5 min) | Mark as FAILED, proceed |
| Quality gate failure | User decides: fix / commit / abort |

## Security Constraints

- **SEC-RESOLVE-001**: Mandatory PreToolUse hook validates fixer Write/Edit paths
- **Nonce-bounded content injection**: TODO content wrapped with unique nonces
- **sanitizeTodoBody()**: Two-pass sanitization before prompt injection
- **Session isolation**: State file includes config_dir + owner_pid + session_id

## Dependencies

- **Existing skills**: `file-todos` (TODO file format), `inner-flame` (self-review), `zsh-compat` (shell safety)
- **Existing agents**: `mend-fixer` (reused for fixes)
- **New agent**: `todo-verifier` (custom verifier agent)
- **New hook**: `validate-resolve-fixer-paths.sh` (SEC-RESOLVE-001)