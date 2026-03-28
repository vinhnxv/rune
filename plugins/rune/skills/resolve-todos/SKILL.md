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

**Load skills**: `file-todos`, `inner-flame`, `zsh-compat`, `rune-orchestration`, `team-sdk`, `polling-guard`

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
const sourceFilter = args.split(' ').filter(a => !a.startsWith('--'))[0] ?? null
const dryRun = args.includes("--dry-run")
const batchSize = parseInt(args.match(/--batch-size[=\s]+(\d+)/)?.[1] ?? "5")

// Discover TODO files (let — reassigned below if capped at MAX_TODOS)
let todos = discoverTodos({ sourceFilter, path: null })
if (todos.length === 0) {
  log("No pending TODOs found. Nothing to resolve.")
  return
}

// Cap at reasonable limit
const MAX_TODOS = 50
if (todos.length > MAX_TODOS) {
  const answer = AskUserQuestion({
    question: `Found ${todos.length} TODOs. Process first ${MAX_TODOS}?`,
    options: [
      { label: `Process first ${MAX_TODOS}`, value: true },
      { label: "Cancel", value: false }
    ]
  })
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

// Handle __unscoped__ TODOs: these have no target file and cannot be processed by fixers.
// Report them separately and exclude from downstream phases.
const unscopedTodos = fileGroups.get("__unscoped__") ?? []
if (unscopedTodos.length > 0) {
  warn(`${unscopedTodos.length} TODO(s) have no target file — excluded from resolution.`)
  for (const todo of unscopedTodos) {
    todo.verdict = "NEEDS_CLARIFICATION"
    todo.verdict_reason = "TODO has no target file specified"
  }
  fileGroups.delete("__unscoped__")
}

// Write inscription.json for hook enforcement (includes session isolation fields per Core Rule 11)
const timestamp = Date.now()
const configDir = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
const inscription = {
  workflow: "rune-resolve-todos",
  timestamp: timestamp,
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  verifiers: [],
  fixers: [],
  task_ownership: {}
}

// Populate task_ownership BEFORE fixer spawning so SEC-RESOLVE-001 hook can enforce file scope.
// Each fixer's assigned files are registered here; the hook reads this to build the allowlist.
for (const [file, fileTodos] of fileGroups) {
  if (file === "__unscoped__") continue
  const fixerName = `fixer-${[...fileGroups.keys()].indexOf(file)}`
  inscription.task_ownership[fixerName] = {
    files: [file, ...fileTodos.flatMap(t => (t.files ?? []).slice(1))]
  }
}

Write(`tmp/.rune-signals/rune-resolve-todos-${timestamp}/inscription.json`, JSON.stringify(inscription))
```

## Phase 2: Codebase Deep Dive

Context gathering agents read affected files in parallel. See references for full protocol.

```javascript
// Team bootstrap
const teamName = `rune-resolve-todos-${timestamp}`
TeamCreate({ team_name: teamName })
// Cleanup fallback array (TLC-003): ["context-0", "context-1", ..., "verifier-0", ..., "fixer-0", ...]
// Dynamic member discovery is primary; this list covers worst-case for filesystem fallback.

// Spawn context gathering agents (Explore, read-only)
// NOTE: Phase 2 is optional — verifiers in Phase 3 read files directly.
// Skip Phase 2 for small batches (< 5 file groups) where the context summary
// adds marginal value over direct verifier reads. Phase 3 verifiers do not
// consume Phase 2 output; they read source files independently.
let fileIdx = 0
for (const [file, fileTodos] of fileGroups) {
  if (file === "__unscoped__") continue
  Agent({
    name: `context-${fileIdx}`,
    subagent_type: "Explore",
    team_name: teamName,
    // Haiku pinned: context gathering is mechanical (read + list imports). Cost-tier override
    // not applied here because Explore agents don't benefit from higher-capability models.
    model: "haiku",
    prompt: `Gather context for ${file}. Read the file, identify imports, callers, and existing patterns.`,
    run_in_background: true
  })
  fileIdx++
}

// waitForCompletion(): Defined in polling-guard skill / monitor-utility.md.
// TaskList-based polling per Core Rule 9. Count arg is CUMULATIVE total.
// maxIterations = ceil(timeoutMs / pollIntervalMs) = ceil(180000 / 30000) = 6
// Per cycle: TaskList() → count completed → check stale → Bash("sleep 30") → repeat
const contextTaskCount = fileIdx
// Context gathering is read-only (no analysis) → shorter 3 min timeout
waitForCompletion(teamName, contextTaskCount, {
  timeoutMs: 180_000,
  pollIntervalMs: 30_000,
  staleWarnMs: 120_000,
  label: "Context"
})
```

## Phase 3: Review Gate (Verify Before Fix)

**Critical differentiator**: Each TODO is reviewed BEFORE any fix is applied.

See [verify-protocol.md](references/verify-protocol.md) for verifier prompts and verdict taxonomy.

```javascript
// buildWaves(): See fixer-protocol.md "No-Overlap Wave Invariant" for definition.
// Groups entries by file, assigns to waves ensuring no two agents in same wave share a file.
// Returns Array<Map<file, todos[]>>. Each wave is a Map<string, Todo[]>.
// For typical batches (< 5 file groups), a single wave suffices — wave overhead is minimal.
const verifierWaves = buildWaves(fileGroups, { maxPerWave: 5 })

// Sanitize TODO bodies before prompt injection (SEC-003: prevent prompt injection)
// sanitizeTodoBody() is defined in verify-protocol.md "TODO Body Sanitization" section.
// Two-pass: strip control patterns → detect SUSPECT injection vectors.
// Returns { clean: string, isSuspect: boolean, matchedPattern: string|null }.
const sanitizedTodos = todos.map(t => ({
  ...t,
  description: sanitizeTodoBody(t.description).clean
}))

// Spawn verifiers (modeled after todo-verifier agent — model set in agent frontmatter)
// Use sanitized TODO descriptions in verifier prompts (not raw fileTodos)
let verifierIdx = 0
let totalVerifiersSpawned = 0
for (const wave of verifierWaves) {
  const waveSize = wave.size ?? wave.length
  for (const [file, fileTodos] of wave) {
    // Use sanitized descriptions from sanitizedTodos (not raw fileTodos)
    const safeTodos = fileTodos.map(t => {
      const sanitized = sanitizedTodos.find(st => st.path === t.path)
      return sanitized ?? t
    })
    // Output path: use full path slug to prevent collision (e.g., src/auth/index.ts → src__auth__index.ts)
    const fileSlug = file.replace(/\//g, '__')
    Agent({
      name: `verifier-${verifierIdx}`,
      subagent_type: "general-purpose",
      team_name: teamName,
      // model and tools: general-purpose defaults; todo-verifier framework injected via prompt
      prompt: `You are todo-verifier. Verify each TODO in ${file}.

      Verdict taxonomy: VALID | FALSE_POSITIVE | ALREADY_FIXED | NEEDS_CLARIFICATION | PARTIAL | DUPLICATE | DEFERRED

      Confidence thresholds:
      - VALID: >= 0.70
      - FALSE_POSITIVE: >= 0.85
      - ALREADY_FIXED: >= 0.80
      - PARTIAL: >= 0.70
      - DUPLICATE: >= 0.90
      - DEFERRED: >= 0.70

      TODOs with PARTIAL verdict: fix the unresolved parts. Include partial evidence.

      Write verdicts to: tmp/resolve-todos-${timestamp}/verdicts/${fileSlug}.json`,
      run_in_background: true
    })
    verifierIdx++
  }
  totalVerifiersSpawned += waveSize
  // waitForCompletion(): See polling-guard skill for definition.
  // Count arg is CUMULATIVE (total completed tasks to wait for across team).
  // Verification requires code analysis → longer 5 min timeout
  // Count is CUMULATIVE across all phases: context agents + verifiers spawned so far
  waitForCompletion(teamName, contextTaskCount + totalVerifiersSpawned, {
    timeoutMs: 300_000,
    pollIntervalMs: 30_000,
    staleWarnMs: 180_000,
    label: "Verify"
  })
}
```

### Phase 3.5: Verdict Aggregation

```javascript
// Aggregate verifier verdicts to build validFileGroups for Phase 4.
// Only TODOs with verdict=VALID or verdict=PARTIAL proceed to fixers.
const validFileGroups = new Map()
for (const [file, fileTodos] of fileGroups) {
  const fileSlug = file.replace(/\//g, '__')
  const verdictPath = `tmp/resolve-todos-${timestamp}/verdicts/${fileSlug}.json`
  let verdictData
  try {
    verdictData = JSON.parse(Read(verdictPath))
  } catch (e) {
    // Verifier crashed or wrote malformed JSON — treat all TODOs in this group
    // as NEEDS_CLARIFICATION so they are not silently dropped
    warn(`Verdict file missing or malformed for ${file} — marking as NEEDS_CLARIFICATION`)
    // Track for Phase 6 report (not silently dropped)
    for (const t of fileTodos) {
      t.verdict = "NEEDS_CLARIFICATION"
      t.verdict_reason = "Verifier crashed or wrote malformed JSON"
    }
    continue
  }
  const validTodos = fileTodos.filter(t => {
    const v = verdictData.verdicts?.find(v => v.todo_id === t.id)
    return v && (v.verdict === "VALID" || v.verdict === "PARTIAL")
  })
  if (validTodos.length > 0) {
    validFileGroups.set(file, validTodos)
  }
}

if (validFileGroups.size === 0) {
  log("No VALID or PARTIAL TODOs after verification. Skipping Phase 4.")
  // Jump directly to Phase 6 — do NOT fall through to Phase 4/5
}
```

**Control flow**: If `validFileGroups.size === 0`, skip Phase 4 and Phase 5 entirely and proceed to Phase 6 (Report). The orchestrator MUST guard Phases 4-5 with `if (validFileGroups.size > 0)`.

## Phase 4: Batch Fix

Wave-based fixer agents resolve verified TODOs. See [fixer-protocol.md](references/fixer-protocol.md).

```javascript
// buildWaves(): See fixer-protocol.md "No-Overlap Wave Invariant" for definition.
// No two fixers in same wave share a file (prevents write conflicts).
const fixerWaves = buildWaves(validFileGroups, { maxPerWave: 5 })

// Spawn fixers (reuse mend-fixer agent pattern)
// SEC-003: Sanitize TODO descriptions before prompt injection
let fixerIdx = 0
let totalFixersSpawned = 0
for (const wave of fixerWaves) {
  const waveSize = wave.size ?? wave.length
  for (const [file, validTodos] of wave) {
    // Use sanitizeTodoBody() from verify-protocol.md for injection defense
    const sanitizedDescriptions = validTodos.map(t => {
      const { clean } = sanitizeTodoBody(t.description)
      return `- [${t.issue_id}] ${clean}`
    }).join('\n')
    // Output path: use full path slug to prevent collision (matches verifier pattern)
    const fileSlug = file.replace(/\//g, '__')
    Agent({
      name: `fixer-${fixerIdx}`,
      subagent_type: "rune:utility:mend-fixer",
      team_name: teamName,
      prompt: `Fix the following TODOs in ${file}:
      ${sanitizedDescriptions}

      CONSTRAINT: Do NOT use the Bash tool. Use only Read, Write, Edit, Glob, Grep.

      Write fix report to: tmp/resolve-todos-${timestamp}/fixes/${fileSlug}.json`,
      run_in_background: true
    })
    fixerIdx++
  }
  totalFixersSpawned += waveSize
  // waitForCompletion(): See polling-guard skill. Count is CUMULATIVE.
  waitForCompletion(teamName, totalFixersSpawned, {
    timeoutMs: 300_000,
    pollIntervalMs: 30_000,
    staleWarnMs: 180_000,
    label: "Fix"
  })
}
```

## Phase 5: Quality Gate

See [quality-gate.md](references/quality-gate.md) for the canonical implementation (talisman-aware command discovery, auto-detection, results file, and failure handling).

## Phase 6: Report & Commit

Aggregates verdict files (7 verdict categories) and fix files (3 statuses) into a summary table at `tmp/resolve-todos-{timestamp}/summary.md`.

See [phase6-report.md](references/phase6-report.md) for the full aggregation logic.

## Phase 7: Cleanup

Standard 5-component cleanup (QUAL-012). Dynamic member discovery with 151-member fallback array (50 context + 50 verifier + 50 fixer + quality-fixer) covering worst-case MAX_TODOS=50.

See [phase7-cleanup.md](references/phase7-cleanup.md) for the full cleanup protocol.

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

- **Existing skills**: `file-todos` (TODO file format), `inner-flame` (self-review), `zsh-compat` (shell safety), `rune-orchestration` (team coordination), `polling-guard` (TaskList polling)
- **Existing agents**: `mend-fixer` (reused for fixes)
- **New agent**: `todo-verifier` (custom verifier agent)
- **New hook**: `validate-resolve-fixer-paths.sh` (SEC-RESOLVE-001)