# Phase 5: WORK — Full Algorithm

Invoke `/rune:strive` logic on the enriched plan. Swarm workers implement tasks with incremental commits.

**Team**: `arc-work-{id}` (delegated to `/rune:strive` — manages its own TeamCreate/TeamDelete with guards)
**Tools**: Full access (Read, Write, Edit, Bash, Glob, Grep)
**Timeout**: 35 min (PHASE_TIMEOUTS.work = 2_100_000 — inner 30m + 5m setup)
**Inputs**: id (string), enriched plan path (`tmp/arc/{id}/enriched-plan.md`), concern context (optional: `tmp/arc/{id}/concern-context.md`), verification report (optional: `tmp/arc/{id}/verification-report.md`), `--approve` flag
**Outputs**: `tmp/arc/{id}/work-summary.md` + committed code on feature branch
**Error handling**: Halt if <50% tasks complete. Partial work is committed via incremental commits (E5).
**Consumers**: SKILL.md (Phase 5 stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Algorithm

```javascript
// STEP 1: Feature branch creation (if on main)
createFeatureBranchIfNeeded()

// STEP 2: Build context for workers
let workContext = ""

// Include reviewer concerns if any
if (exists(`tmp/arc/${id}/concern-context.md`)) {
  workContext += `\n\n## Reviewer Concerns\nSee tmp/arc/${id}/concern-context.md for full details.`
}

// Include verification warnings if any
if (exists(`tmp/arc/${id}/verification-report.md`)) {
  const verReport = Read(`tmp/arc/${id}/verification-report.md`)
  const issueCount = (verReport.match(/^- /gm) || []).length
  if (issueCount > 0) {
    workContext += `\n\n## Verification Warnings (${issueCount} issues)\nSee tmp/arc/${id}/verification-report.md.`
  }
}

// Quality contract for all workers
workContext += `\n\n## Quality Contract\nAll code must include:\n- Type annotations on all function signatures\n- Docstrings on all public functions, classes, and modules\n- Error handling with specific exception types (no bare except)\n- Test coverage target: >=80% for new code`

// STEP 3: Delegate to /rune:strive
// /rune:strive manages its own team lifecycle (TeamCreate, TaskCreate, worker spawning,
// monitoring, commit brokering, ward check, cleanup, TeamDelete).
// Arc records the team_name for cancel-arc discovery.
// Delegation pattern: /rune:strive creates its own team (e.g., rune-work-{timestamp}).
// Arc reads the team name back from the work state file or teammate idle notification.
// The team name is recorded in checkpoint for cancel-arc discovery.
// PRE-DELEGATION: Record phase as in_progress with null team name.
// Actual team name will be discovered post-delegation from state file (see below).
updateCheckpoint({ phase: "work", status: "in_progress", phase_sequence: 5, team_name: null })

// No --todos-dir flag needed — strive detects arc context automatically
// Strive scans .claude/arc/*/checkpoint.json for work phase in_progress + todos_base
// When found, strive redirects todos to "tmp/arc/{id}/todos/work/" instead of "tmp/work/{timestamp}/todos/work/"
// checkpoint.todos_base is set by arc scaffolding (pre-Phase 5) and records this path for resume
// Thread only --approve flag if applicable (no todosFlag needed)

// STEP 4: After work completes, produce work summary
// CDX-003 FIX: Assign workSummary to a variable so sha256() in STEP 5 can reference it.
// Previously, Write() used an inline object but sha256() referenced an undefined `workSummary`.
const workSummary = JSON.stringify({
  tasks_completed: completedCount, tasks_failed: failedCount,
  files_committed: committedFiles, uncommitted_changes: uncommittedList, commits: commitSHAs
})
Write(`tmp/arc/${id}/work-summary.md`, workSummary)

// POST-DELEGATION: Read actual team name from state file
// State file was created by the sub-command during its Phase 1 (TeamCreate).
// This is the only reliable way to discover the team name for cancel-arc.
// NOTE (Forge: flaw-hunter): Include recently-completed files (< 5s) to handle
// fast workflows where sub-command completes before arc reads the state file.
// NOTE (Forge: ward-sentinel): Validate age >= 0 to prevent future-timestamp bypass.
const postWorkStateFiles = Glob("tmp/.rune-work-*.json").filter(f => {
  try {
    const state = JSON.parse(Read(f))
    if (!state.status) return false  // Reject malformed state files
    const age = Date.now() - new Date(state.started).getTime()
    const isValidAge = !Number.isNaN(age) && age >= 0 && age < PHASE_TIMEOUTS.work
    const isRelevant = state.status === "active" ||
      (state.status === "completed" && age >= 0 && age < 5000)  // Recently completed
    return isRelevant && isValidAge
  } catch (e) { return false }
})
if (postWorkStateFiles.length > 1) {
  warn(`Multiple work state files found (${postWorkStateFiles.length}) — using most recent`)
}
if (postWorkStateFiles.length > 0) {
  try {
    const actualTeamName = JSON.parse(Read(postWorkStateFiles[0])).team_name
    if (actualTeamName && /^[a-zA-Z0-9_-]+$/.test(actualTeamName)) {
      updateCheckpoint({ phase: "work", team_name: actualTeamName })
    }
  } catch (e) {
    warn(`Failed to read team_name from state file: ${e.message}`)
  }
}

// Post-work todos verification (non-blocking)
if (checkpoint.todos_base) {
  const workTodos = Glob(`${checkpoint.todos_base}work/[0-9][0-9][0-9]-*.md`)
  log(`Work todos: ${workTodos.length} task files generated`)
} else {
  log("todos_base not yet initialized — skipping todo verification")
}

// STEP 5: Update checkpoint
updateCheckpoint({
  phase: "work", status: completedRatio >= 0.5 ? "completed" : "failed",
  artifact: `tmp/arc/${id}/work-summary.md`, artifact_hash: sha256(workSummary),
  phase_sequence: 5, commits: commitSHAs
})
```

**Output**: Implemented code (committed) + `tmp/arc/{id}/work-summary.md`

**Failure policy**: Halt if <50% tasks complete. Partial work is committed via incremental commits (E5).

## Crash Recovery

If this phase crashes before reaching cleanup, the following resources are orphaned:

| Resource | Location |
|----------|----------|
| Team config | `$CHOME/teams/rune-work-{identifier}/` (where CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}") |
| Task list | `$CHOME/tasks/rune-work-{identifier}/` |
| State file | `tmp/.rune-work-*.json` (stuck in `"active"` status) |
| Signal dir | `tmp/.rune-signals/rune-work-{identifier}/` |

### Recovery Layers

If this phase crashes, the orphaned resources above are recovered by the 3-layer defense:
Layer 1 (ORCH-1 resume), Layer 2 (`/rune:rest --heal`), Layer 3 (arc pre-flight stale scan).
Work phase teams use `rune-work-*` prefix — handled by the sub-command's own pre-create guard (not Layer 3).

See [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md) §Orphan Recovery Pattern for full layer descriptions and coverage matrix.

## --approve Routing

The `--approve` flag routes to the **human user** via `AskUserQuestion` (not to the AI leader). This applies only to Phase 5. Do NOT propagate `--approve` when invoking `/rune:mend` in Phase 7 -- mend fixers apply deterministic fixes from TOME findings.

## Team Lifecycle

Delegated to `/rune:strive` — manages its own TeamCreate/TeamDelete with guards (see [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md)). Arc records the actual `team_name` in checkpoint for cancel-arc discovery.

Arc MUST record the actual `team_name` created by `/rune:strive` in the checkpoint. This enables `/rune:cancel-arc` to discover and shut down the work team if the user cancels mid-pipeline. The work command creates its own team with its own naming convention — arc reads the team name back after delegation.

Arc runs `prePhaseCleanup(checkpoint)` before delegation (ARC-6) and `postPhaseCleanup(checkpoint, "work")` after checkpoint update. See SKILL.md Inter-Phase Cleanup Guard section and [arc-phase-cleanup.md](arc-phase-cleanup.md).

## Feature Branch Strategy

Before delegating to `/rune:strive`, the arc orchestrator ensures a feature branch exists (see SKILL.md Pre-flight: Branch Strategy COMMIT-1). If already on a feature branch, the current branch is used. `/rune:strive`'s own Phase 0.5 (env setup) skips branch creation when invoked from arc context.
