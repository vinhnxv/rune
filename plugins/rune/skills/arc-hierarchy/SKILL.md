---
name: arc-hierarchy
description: |
  Hierarchical plan execution — orchestrates parent/child plan decomposition with
  dependency DAGs, requires/provides contracts, and feature branch strategy.
  Use when a plan has been decomposed into child plans via /rune:devise Phase 2.5
  (Hierarchical option) and frontmatter shows `hierarchical: true` with a `children_dir`.
  Handles: topological sequencing, contract verification, partial failure recovery,
  and per-child feature branch management.
  Keywords: hierarchical, parent plan, child plan, decomposition, DAG, dependency,
  shatter, children_dir, requires, provides, contract matrix, arc-hierarchy.

  <example>
  Context: User has a parent plan with child plans decomposed
  user: "/rune:arc-hierarchy plans/2026-02-23-feature-auth-plan.md"
  assistant: "The Tarnished reads the execution table and begins executing child plans in topological order..."
  </example>

  <example>
  Context: User wants to resume after a child plan failure
  user: "/rune:arc-hierarchy plans/parent.md --resume"
  assistant: "Resuming hierarchy execution. Found 2/5 children completed. Next executable: 03-permissions..."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Agent
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
  - Skill
argument-hint: "<parent-plan-path> [--resume] [--dry-run] [--no-merge]"
---

# /rune:arc-hierarchy — Hierarchical Plan Execution

Orchestrates sequential execution of child plans (produced by `/rune:devise` with `--shatter`) in dependency order. Each child is executed via a full `/rune:arc` pipeline. The parent plan serves as the execution manifest.

**Load skills**: `rune-orchestration`, `chome-pattern`, `zsh-compat`, `polling-guard`

> **FC-1**: Detection of hierarchical plans belongs HERE — not in arc-preflight.md. Standard `/rune:arc` runs NEVER see hierarchical logic. Users invoke this skill explicitly when they have a shattered parent plan.

## Usage

```
/rune:arc-hierarchy plans/2026-02-23-feature-auth-plan.md
/rune:arc-hierarchy plans/parent.md --resume       # Resume after interruption
/rune:arc-hierarchy plans/parent.md --dry-run      # Preview execution order only
/rune:arc-hierarchy plans/parent.md --no-merge     # Skip auto-merge on children
```

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--resume` | Resume from current execution table state | Off |
| `--dry-run` | Show execution order and contracts, exit without running | Off |
| `--no-merge` | Pass `--no-merge` to each child arc run | Off |

## Parent Plan Detection

A plan is hierarchical if its YAML frontmatter contains both:
```yaml
hierarchical: true
children_dir: plans/children/
```

Parse with `extractYamlFrontmatter(content)`. If frontmatter is missing either field, this skill exits with guidance to run `/rune:devise --shatter` first.

## Reference Files

- [hierarchy-parser.md](references/hierarchy-parser.md) — `parseExecutionTable`, `updateExecutionTable`, `findNextExecutable`, `parseDependencyContractMatrix`, artifact verification
- [branch-strategy.md](references/branch-strategy.md) — feature branch creation, child branch management, merge, cleanup
- [prerequisite-verification.md](references/prerequisite-verification.md) — `verifyPrerequisites`, `verifyProvides`, resolution strategies
- [coherence-check.md](references/coherence-check.md) — pre-execution contract coherence validation
- [session-state.md](references/session-state.md) — session identity resolution, state file schema, liveness check
- [main-loop.md](references/main-loop.md) — 7 sub-phases (7a-7g): prerequisite verification, branch management, arc invocation, provides verification, merge

---

## Orchestration Loop

### Workflow Lock (writer)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "writer"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "arc-hierarchy" "writer"`)
```

### Phase 0: Parse Arguments

```javascript
const args = "$ARGUMENTS".trim()
const planPath = args.replace(/--\S+/g, '').trim()
const resumeMode = args.includes('--resume')
const dryRun = args.includes('--dry-run')
const noMerge = args.includes('--no-merge')

// Guard: empty path check BEFORE validation (BACK-001 fix)
if (!planPath) {
  error("Usage: /rune:arc-hierarchy <parent-plan-path>")
  return
}

// SEC-1: validate path before any file operations
const pathValidation = validatePlanPath(planPath)
if (!pathValidation.valid) {
  error(`Invalid plan path: ${pathValidation.reason}`)
  return
}
```

### Phase 1: Detect Hierarchical Plan

```javascript
const planContent = Read(planPath)
if (!planContent) {
  error(`Cannot read parent plan: ${planPath}`)
  return
}

const frontmatter = extractYamlFrontmatter(planContent)
if (!frontmatter?.hierarchical || !frontmatter?.children_dir) {
  error("This plan is not hierarchical.")
  error("Expected frontmatter: `hierarchical: true` and `children_dir: plans/children/`")
  error("Run /rune:devise --shatter to decompose a plan into child plans first.")
  return
}

const childrenDir = frontmatter.children_dir
```

### Phase 2: Parse Execution State

```javascript
// See hierarchy-parser.md for full pseudocode
const executionTable = parseExecutionTable(planContent)
const contractMatrix = parseDependencyContractMatrix(planContent)

if (executionTable.length === 0) {
  error("No execution table found in parent plan. Expected a | Seq | Child Plan | Status | ... table.")
  return
}

const totalChildren = executionTable.length
const completedChildren = executionTable.filter(e => e.status === "completed").length
const pendingChildren = executionTable.filter(e => e.status === "pending").length

log(`Execution table: ${totalChildren} children, ${completedChildren} completed, ${pendingChildren} pending`)
```

### Phase 3: Dry Run (if --dry-run)

```javascript
if (dryRun) {
  log("Dry run — execution order (topological):")
  let remaining = [...executionTable]
  let order = 0
  let simulatedCompleted = new Set(
    executionTable.filter(e => e.status === "completed").map(e => e.seq)
  )

  while (true) {
    const next = findNextExecutable(remaining.map(e =>
      simulatedCompleted.has(e.seq) ? { ...e, status: "completed" } : e
    ))
    if (!next) break
    order++
    log(`  ${order}. [${next.seq}] ${next.path}`)
    simulatedCompleted.add(next.seq)
    remaining = remaining.filter(e => e.seq !== next.seq)
  }

  if (contractMatrix.length > 0) {
    log("\nContract Matrix:")
    for (const entry of contractMatrix) {
      const requires = entry.requires.length > 0 ? entry.requires.map(a => `${a.type}:${a.name}`).join(", ") : "—"
      const provides = entry.provides.length > 0 ? entry.provides.map(a => `${a.type}:${a.name}`).join(", ") : "—"
      log(`  ${entry.child}: requires=[${requires}] provides=[${provides}]`)
    }
  }

  return
}
```

### Phase 4: Pre-Execution Coherence Check

```javascript
// See coherence-check.md for full pseudocode
const coherenceResult = runCoherenceCheck(planContent, executionTable, contractMatrix)
if (coherenceResult.errors.length > 0) {
  warn("Coherence check found issues:")
  for (const err of coherenceResult.errors) {
    warn(`  [${err.severity}] ${err.message}`)
  }

  const hasBlockingErrors = coherenceResult.errors.some(e => e.severity === "error")
  if (hasBlockingErrors) {
    const userChoice = AskUserQuestion({
      questions: [{
        question: "Coherence check found blocking errors. How to proceed?",
        header: "Coherence",
        options: [
          { label: "Abort — fix parent plan first", description: "Review coherence-check.md output" },
          { label: "Continue anyway (risky)", description: "Proceed despite errors" }
        ],
        multiSelect: false
      }]
    })

    // BACK-002 FIX: Handle user response — abort if user chooses to fix first
    if (userChoice !== "Continue anyway (risky)") {
      error("Aborting due to coherence check blocking errors. Fix parent plan and re-run.")
      return
    }
    warn("User chose to continue despite blocking errors.")
  }
}
```

### Phase 5: Session Identity + State File

Resolves CHOME, PID, and session ID. Checks for conflicting sessions (abort if another session owns the state file, unless `--resume`). Writes `.claude/arc-hierarchy-loop.local.md` with all session isolation fields.

See [session-state.md](references/session-state.md) for the full protocol.

### Phase 6: Feature Branch Setup

```javascript
// See branch-strategy.md for full pseudocode
const featureBranch = createFeatureBranch(frontmatter.title || planPath)
log(`Feature branch created: ${featureBranch}`)
```

### Phase 7: Main Execution Loop

Iterates through child plans in topological order. Each iteration: find next executable child, verify prerequisites, create child branch, update execution table, invoke `/rune:arc`, verify provides contracts, merge child branch, mark completed. Safety cap prevents infinite loops. Sub-phases:
- **7a**: Prerequisite verification (cycle detection after 2 failures)
- **7b**: Child branch creation
- **7c**: Execution table + state file + JSON sidecar updates
- **7d**: Arc invocation for child plan
- **7e**: Provides contract verification (4-branch user choice on failure)
- **7f**: Merge child branch to feature branch
- **7g**: Mark completed in execution table

See [main-loop.md](references/main-loop.md) for the full protocol.

### Phase 8: Finalize

```javascript
const finalContent = Read(planPath)
const finalTable = parseExecutionTable(finalContent)
const completedCount = finalTable.filter(e => e.status === "completed").length
const failedCount = finalTable.filter(e => e.status === "failed").length
const partialCount = finalTable.filter(e => e.status === "partial").length
const skippedCount = finalTable.filter(e => e.status === "skipped").length

log(`\n── Hierarchy Execution Complete ──`)
log(`  Completed: ${completedCount}/${totalChildren}`)
if (failedCount > 0) log(`  Failed: ${failedCount}`)
if (partialCount > 0) log(`  Partial: ${partialCount}`)
if (skippedCount > 0) log(`  Skipped: ${skippedCount}`)

if (completedCount === totalChildren) {
  // All children succeeded — finalize feature branch
  finalizeFeatureBranch(featureBranch)
  log("The Tarnished has claimed the Elden Throne for the full feature.")
} else {
  warn("Not all children completed. Feature branch left in place for manual review.")
  log(`Feature branch: ${featureBranch}`)
}

// Clean up state file and JSON sidecar
Bash(`rm -f "${stateFile}" ".claude/arc-hierarchy-exec-table.json"`)

// Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "arc-hierarchy"`)
```

---

## State File Format

`.claude/arc-hierarchy-loop.local.md` — YAML frontmatter:

```yaml
---
active: true
status: active
parent_plan: plans/2026-02-23-feature-auth-plan.md
children_dir: plans/children/
current_child: 02-api-plan.md
feature_branch: feat/hierarchical-auth
execution_table_path: plans/2026-02-23-feature-auth-plan.md
no_merge: false
config_dir: /Users/user/.claude
owner_pid: 12345
session_id: abc-123-def-456
started_at: "2026-02-23T00:00:00Z"
---

Arc hierarchy loop state. Do not edit manually.
Use /rune:cancel-arc-hierarchy to stop execution.
```

**JSON Sidecar**: `.claude/arc-hierarchy-exec-table.json` — machine-readable execution table for the stop hook (jq-based parsing). Updated by the orchestrator at Phase 7c before each child arc. The Markdown table in the parent plan remains the human-readable source of truth.

**Session isolation fields** (CLAUDE.md §11 — CRITICAL):
- `config_dir` — resolved CLAUDE_CONFIG_DIR. Isolates different Claude Code installations.
- `owner_pid` — `$PPID` in Bash (Claude Code process PID). Isolates parallel sessions.
- `session_id` — `CLAUDE_SESSION_ID`. Diagnostic only — not verifiable in bash.

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Path traversal in planPath | Abort immediately (SEC-1) |
| Not a hierarchical plan | Abort with guidance to `/rune:devise --shatter` |
| Another session active | Abort unless `--resume` |
| Coherence check errors | AskUserQuestion — user chooses abort or continue |
| Prerequisites missing | Resolution strategies: pause/self-heal/backtrack/skip (see prerequisite-verification.md) |
| Provides verification fails | Mark as `partial`, AskUserQuestion for resolution |
| Circular dependency detected | Warn, list blocked children, abort loop |
| Failed predecessor | Warn, list blocked children, offer to skip dependents |
| Safety cap hit | Abort with diagnostic output |
