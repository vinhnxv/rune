# Phase 5: WORK — Full Algorithm

Invoke `/rune:strive` logic on the enriched plan. Swarm workers implement tasks with incremental commits.

**Team**: `arc-work-{id}` (delegated to `/rune:strive` — manages its own TeamCreate/TeamDelete with guards)
**Tools**: Full access (Read, Write, Edit, Bash, Glob, Grep)
**Timeout**: 35 min (PHASE_TIMEOUTS.work = 2_100_000 — inner 30m + 5m setup)
**Inputs**: id (string), enriched plan path (`tmp/arc/{id}/enriched-plan.md`), concern context (optional: `tmp/arc/{id}/concern-context.md`), verification report (optional: `tmp/arc/{id}/verification-report.md`), `--approve` flag
**Outputs**: `tmp/arc/{id}/work-summary.md` + committed code on feature branch
**Error handling**: Halt if <50% tasks complete. Partial work is committed via incremental commits (E5).
**Consumers**: SKILL.md (Phase 5 stub)

**Phase loop mechanism**: The arc dispatcher invokes this phase via the **Stop hook re-injection** pattern (`arc-phase-stop-hook.sh`). The Stop hook reads `.rune/arc-phase-loop.local.md`, finds "work" as the next pending phase in `PHASE_ORDER`, and re-injects a prompt that executes this reference file. Each arc phase runs in its own Claude Code turn, preventing context accumulation across phases.

**Arc context detection**: Strive detects arc orchestration by scanning `.rune/arc/*/checkpoint.json` for `phases.work.status === 'in_progress'`.

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

// Discipline criteria coverage context: remind workers that acceptance criteria
// were extracted and included in TaskCreate descriptions during plan parsing.
// Workers should reference criteria when collecting evidence via the Discipline Work Loop.
workContext += `\n\n## Discipline Integration\nAcceptance criteria from the plan have been extracted and included in your task descriptions. When the Discipline Work Loop is active, collect evidence per criterion before marking tasks complete. Reference proof-schema.md for proof type selection. Criteria coverage was validated during task decomposition — all plan criteria are mapped to work items.`

// plan_file_path is available from the checkpoint for workers that need spec context.
// Pass it to workers so they can verify their implementation matches the original plan.
// Read from checkpoint.plan_file — do NOT use the state file or CLI flags as the source.
const planFilePath = checkpoint.plan_file
if (planFilePath) {
  workContext += `\n\n## Plan Specification\nOriginal plan: ${planFilePath}\nWorkers should reference this plan to confirm each implemented task satisfies the stated requirements and acceptance criteria.`
}

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

// Thread only --approve flag if applicable
// --approve routing: routes to HUMAN USER via AskUserQuestion (not to AI leader).
// Phase 5 only — do NOT propagate --approve to /rune:mend in Phase 7.

// STEP 4: After work completes, produce enriched work summary (v1.180.0+)
// CDX-003 FIX: Assign workSummary to a variable so sha256() in STEP 5 can reference it.
// Previously, Write() used an inline object but sha256() referenced an undefined `workSummary`.

// Build per-task breakdown from TaskList results
const taskResults = TaskList()
const perTaskRows = taskResults.map(t => {
  const taskFiles = t.metadata?.files_modified || []
  const criteriaPass = t.metadata?.criteria_passed ?? 0
  const criteriaTotal = t.metadata?.criteria_total ?? 0
  const commitSha = t.metadata?.commit_sha || "—"
  return `| ${t.id} | ${t.subject} | ${t.status} | ${taskFiles.join(", ") || "—"} | ${criteriaPass}/${criteriaTotal} | ${commitSha} |`
}).join('\n')

const workSummaryContent = `# Work Summary

## Aggregate

| Metric | Value |
|--------|-------|
| Tasks Completed | ${completedCount} |
| Tasks Failed | ${failedCount} |
| Files Committed | ${committedFiles.length} |
| Uncommitted Changes | ${uncommittedList.length} |
| Commits | ${commitSHAs.length} |

## Per-Task Status

| Task ID | Subject | Status | Files Modified | Criteria Pass/Total | Commit SHA |
|---------|---------|--------|---------------|---------------------|------------|
${perTaskRows}

## Criteria Coverage

| Metric | Value |
|--------|-------|
| Total Criteria | ${taskResults.reduce((sum, t) => sum + (t.metadata?.criteria_total ?? 0), 0)} |
| Criteria Passed | ${taskResults.reduce((sum, t) => sum + (t.metadata?.criteria_passed ?? 0), 0)} |
| Coverage | ${taskResults.length > 0 ? ((taskResults.reduce((sum, t) => sum + (t.metadata?.criteria_passed ?? 0), 0) / Math.max(1, taskResults.reduce((sum, t) => sum + (t.metadata?.criteria_total ?? 0), 0))) * 100).toFixed(1) : 0}% |

## Committed Files

${committedFiles.map(f => `- \`${f}\``).join('\n')}

## Commits

${commitSHAs.map(sha => `- ${sha}`).join('\n')}
`

const workSummary = workSummaryContent
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

// STEP 4b: Log task file observability event (AC-7)
// After strive Phase 1 delegation returns, log counts of all physical task files created.
// This provides a concrete audit trail that file-based delegation actually ran.
const taskFileCount = Glob(`tmp/work/${timestamp}/tasks/task-*.md`).length
const promptFileCount = Glob(`tmp/work/${timestamp}/prompts/*.md`).length
const contextFileCount = Glob(`tmp/work/${timestamp}/scopes/*.md`).length

appendPhaseLog(id, {
  event: "task_files_created",
  phase: "work",
  task_files: taskFileCount,
  prompt_files: promptFileCount,
  context_files: contextFileCount,
  delegation_manifest: `tmp/work/${timestamp}/delegation-manifest.json`,
  timestamp: new Date().toISOString()
})

// Validation gate: zero task files means strive Phase 1 skipped file creation
if (taskFileCount === 0) {
  warn("CRITICAL: No task files created — strive Phase 1 may have skipped file creation. Workers are in degraded mode (inline prompt only). Check forge-team.md Write() execution.")
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

See [engines.md](../../team-sdk/references/engines.md) § cleanup and [protocols.md](../../team-sdk/references/protocols.md) § Handle Serialization for full orphan recovery documentation.

## --approve Routing

The `--approve` flag routes to the **human user** via `AskUserQuestion` (not to the AI leader). This applies only to Phase 5. Do NOT propagate `--approve` when invoking `/rune:mend` in Phase 7 -- mend fixers apply deterministic fixes from TOME findings.

## Team Lifecycle

Delegated to `/rune:strive` — manages its own TeamCreate/TeamDelete with guards (see [engines.md](../../team-sdk/references/engines.md)). Arc records the actual `team_name` in checkpoint for cancel-arc discovery.

Arc MUST record the actual `team_name` created by `/rune:strive` in the checkpoint. This enables `/rune:cancel-arc` to discover and shut down the work team if the user cancels mid-pipeline. The work command creates its own team with its own naming convention — arc reads the team name back after delegation.

Arc runs `prePhaseCleanup(checkpoint)` before delegation (ARC-6) and `postPhaseCleanup(checkpoint, "work")` after checkpoint update. See SKILL.md Inter-Phase Cleanup Guard section and [arc-phase-cleanup.md](arc-phase-cleanup.md).

## Backward Compatibility

File-based task delegation is **additive** — it extends existing flows without replacing them.

| Scenario | Behavior |
|----------|----------|
| Task files created successfully | Workers read task files + task files enable report-back. Full discipline loop active. |
| Task files NOT created (Write() failed) | Workers fall back to inline prompt content. Pipeline continues. Warning logged. |
| Plans without AC criteria | Task files are still created (with `proof_count: 0`). Discipline Work Loop degrades to linear execution. |
| Workers that don't read task files | Still work — the spawn prompt contains the full task spec. Task files are supplemental, not load-bearing. |
| `tmp/work/{ts}/prompts/` missing | Workers use inline prompt passed to `Agent()`. Prompt files are an audit trail, not a prerequisite. |
| `tmp/work/{ts}/scopes/` missing | Workers use scope-of-work section embedded in inline prompt. Scope files are supplemental. |
| `delegation-manifest.json` missing | Pipeline continues. Cancel-arc discovery uses team name from checkpoint. Manifest is advisory. |

**Graceful degradation rule**: If `Write()` fails for any task/prompt/scope file, log a warning and continue. File creation failures are **non-blocking** — the inline prompt always contains enough context for workers to proceed.

**Note**: The `scopes/` directory is used (not `context/`) to avoid namespace collision with `context-preservation.md` which uses `tmp/work/{ts}/context/{arc-checkpoint-id}/` for compaction snapshots.

## Feature Branch Strategy

Before delegating to `/rune:strive`, the arc orchestrator ensures a feature branch exists (see SKILL.md Pre-flight: Branch Strategy COMMIT-1). If already on a feature branch, the current branch is used. `/rune:strive`'s own Phase 0.5 (env setup) skips branch creation when invoked from arc context.
