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

**Load skills**: `file-todos`, `inner-flame`, `zsh-compat`, `rune-orchestration`, `polling-guard`

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

// Discover TODO files
const todos = discoverTodos({ sourceFilter, path: null })
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

// Write inscription.json for hook enforcement (includes session isolation fields per Core Rule 11)
const timestamp = Date.now()
const configDir = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
const inscription = {
  workflow: "rune-resolve-todos",
  timestamp: timestamp,
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}",
  verifiers: [],
  fixers: [],
  task_ownership: {}
}
Write(`tmp/.rune-signals/rune-resolve-todos-${timestamp}/inscription.json`, JSON.stringify(inscription))
```

## Phase 2: Codebase Deep Dive

Context gathering agents read affected files in parallel. See references for full protocol.

```javascript
// Team bootstrap
const teamName = `rune-resolve-todos-${timestamp}`
TeamCreate({ team_name: teamName })

// Spawn context gathering agents (Explore, read-only)
// NOTE: Phase 2 is optional — verifiers in Phase 3 also read files directly.
// Consider skipping Phase 2 for small batches (< 5 file groups) where the
// context summary adds marginal value over direct verifier reads.
let fileIdx = 0
for (const [file, todos] of fileGroups) {
  if (file === "__unscoped__") continue
  Agent({
    name: `context-${fileIdx}`,
    subagent_type: "Explore",
    team_name: teamName,
    model: "haiku",
    prompt: `Gather context for ${file}. Read the file, identify imports, callers, and existing patterns.`,
    run_in_background: true
  })
  fileIdx++
}

// Wait with timeout — uses TaskList-based polling per Core Rule 9.
// See roundtable-circle/references/monitor-utility.md for the shared polling utility.
// maxIterations = ceil(timeoutMs / pollIntervalMs) = ceil(180000 / 30000) = 6
// Per cycle: TaskList() → count completed → check stale → Bash("sleep 30") → repeat
const contextTaskCount = fileIdx
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
// Build verifier waves — group by file, no two verifiers in same wave share a file
// See fixer-protocol.md "No-Overlap Wave Invariant" for the wave construction algorithm.
// Verifier waves use the same algorithm: one verifier per file group per wave.
const verifierWaves = buildWaves(fileGroups, { maxPerWave: 5 })

// Sanitize TODO bodies before prompt injection (SEC-003: prevent prompt injection)
// See verify-protocol.md "TODO Body Sanitization" for sanitizeTodoBody() definition.
const sanitizedTodos = todos.map(t => ({
  ...t,
  description: sanitizeTodoBody(t.description).clean
}))

// Spawn verifiers (modeled after todo-verifier agent — model: haiku, tools: Read, Grep, Glob, Write)
let fileIdx = 0
for (const wave of verifierWaves) {
  for (const [file, fileTodos] of wave) {
    Agent({
      name: `verifier-${fileIdx}`,
      subagent_type: "general-purpose",
      team_name: teamName,
      model: "haiku",
      prompt: `You are todo-verifier. Verify each TODO in ${file}.

      Verdict taxonomy: VALID | FALSE_POSITIVE | ALREADY_FIXED | NEEDS_CLARIFICATION | PARTIAL | DUPLICATE | DEFERRED

      Confidence thresholds:
      - VALID: >= 0.70
      - FALSE_POSITIVE: >= 0.85
      - ALREADY_FIXED: >= 0.80

      TODOs with PARTIAL verdict: fix the unresolved parts. Include partial evidence.

      Write verdicts to: tmp/resolve-todos-${timestamp}/verdicts/${basename(file)}.json`,
      run_in_background: true
    })
    fileIdx++
  }
  // Wait with TaskList-based polling per Core Rule 9
  // maxIterations = ceil(300000 / 30000) = 10
  waitForCompletion(teamName, wave.length, {
    timeoutMs: 300_000,
    pollIntervalMs: 30_000,
    staleWarnMs: 180_000,
    label: "Verify"
  })
}
```

## Phase 4: Batch Fix

Wave-based fixer agents resolve verified TODOs. See [fixer-protocol.md](references/fixer-protocol.md).

```javascript
// Build fixer waves — no two fixers in same wave share a file (prevents write conflicts)
// See fixer-protocol.md "No-Overlap Wave Invariant" for the wave construction algorithm:
//   1. Group fixers by file → check overlap → assign to wave → defer conflicts to next wave
const fixerWaves = buildWaves(validFileGroups, { maxPerWave: 5 })

// Spawn fixers (reuse mend-fixer agent pattern)
// SEC-003: Sanitize TODO descriptions before prompt injection
let fileIdx = 0
for (const wave of fixerWaves) {
  for (const [file, validTodos] of wave) {
    const sanitizedDescriptions = validTodos.map(t => {
      const { clean } = sanitizeTodoBody(t.description)
      return `- [${t.issue_id}] ${clean}`
    }).join('\n')
    Agent({
      name: `fixer-${fileIdx}`,
      subagent_type: "general-purpose",
      team_name: teamName,
      prompt: `Fix the following TODOs in ${file}:
      ${sanitizedDescriptions}

      Write fix report to: tmp/resolve-todos-${timestamp}/fixes/${basename(file)}.json`,
      run_in_background: true
    })
    fileIdx++
  }
  // Wait with TaskList-based polling per Core Rule 9
  // maxIterations = ceil(300000 / 30000) = 10
  waitForCompletion(teamName, wave.length, {
    timeoutMs: 300_000,
    pollIntervalMs: 30_000,
    staleWarnMs: 180_000,
    label: "Fix"
  })
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
// Aggregate results from verdict and fix report files
const verdictFiles = Glob(`tmp/resolve-todos-${timestamp}/verdicts/*.json`)
const fixFiles = Glob(`tmp/resolve-todos-${timestamp}/fixes/*.json`)

let validCount = 0, falsePositiveCount = 0, alreadyFixedCount = 0
let needsClarificationCount = 0, partialCount = 0, duplicateCount = 0, deferredCount = 0
for (const vf of verdictFiles) {
  const data = JSON.parse(Read(vf))
  for (const v of data.verdicts ?? []) {
    if (v.verdict === "VALID") validCount++
    else if (v.verdict === "FALSE_POSITIVE") falsePositiveCount++
    else if (v.verdict === "ALREADY_FIXED") alreadyFixedCount++
    else if (v.verdict === "NEEDS_CLARIFICATION") needsClarificationCount++
    else if (v.verdict === "PARTIAL") partialCount++
    else if (v.verdict === "DUPLICATE") duplicateCount++
    else if (v.verdict === "DEFERRED") deferredCount++
  }
}

let fixedCount = 0, failedCount = 0, skippedCount = 0
for (const ff of fixFiles) {
  const data = JSON.parse(Read(ff))
  for (const f of data.fixes ?? []) {
    if (f.status === "FIXED") fixedCount++
    else if (f.status === "FAILED") failedCount++
    else if (f.status === "SKIPPED") skippedCount++
  }
}

const summary = `
# TODO Resolution Summary

| Category | Count |
|----------|-------|
| Input TODOs | ${todos.length} |
| Verified VALID | ${validCount} |
| Successfully FIXED | ${fixedCount} |
| FALSE POSITIVE | ${falsePositiveCount} |
| ALREADY FIXED | ${alreadyFixedCount} |
| FAILED to fix | ${failedCount} |
| SKIPPED | ${skippedCount} |
| NEEDS CLARIFICATION | ${needsClarificationCount} |
`
Write(`tmp/resolve-todos-${timestamp}/summary.md`, summary)
```

## Phase 7: Cleanup

Standard 5-component cleanup pattern per CLAUDE.md Agent Team Cleanup (QUAL-012).

```javascript
// 1. Dynamic member discovery — read team config for ALL teammates
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: hardcoded list of all known teammate name patterns for this workflow
  // Safe to send shutdown_request to absent members — no-op
  allMembers = []
}

// 2. Shutdown request to all members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Workflow complete" })
}

// 3. Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash("sleep 15")
}

// 4. TeamDelete with retry-with-backoff (3 attempts: 0s, 5s, 10s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}
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

- **Existing skills**: `file-todos` (TODO file format), `inner-flame` (self-review), `zsh-compat` (shell safety), `rune-orchestration` (team coordination), `polling-guard` (TaskList polling)
- **Existing agents**: `mend-fixer` (reused for fixes)
- **New agent**: `todo-verifier` (custom verifier agent)
- **New hook**: `validate-resolve-fixer-paths.sh` (SEC-RESOLVE-001)