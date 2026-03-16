---
name: strive
description: |
  Multi-agent work execution using Agent Teams. Parses a plan into tasks,
  summons swarm workers that claim and complete tasks independently,
  and runs quality gates before completion.

  <example>
  user: "/rune:strive plans/feat-user-auth-plan.md"
  assistant: "The Tarnished marshals the Ash to forge the plan..."
  </example>

  <example>
  user: "/rune:strive"
  assistant: "No plan specified. Looking for recent plans..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[plan-path] [--approve] [--worktree] [--background|-bg] [--collect] [--resume]"
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

**Runtime context** (preprocessor snapshot):
- Active workflows: !`find tmp -maxdepth 1 -name '.rune-*-*.json' -exec grep -l '"active"' {} + 2>/dev/null | wc -l | tr -d ' '`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:strive — Multi-Agent Work Execution

Parses a plan into tasks with dependencies, summons swarm workers, and coordinates parallel implementation.

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `codex-cli`, `team-sdk`, `git-worktree` (when worktree mode active), `polling-guard`, `zsh-compat`, `frontend-design-patterns` + `figma-to-react` + `design-sync` (when design context active)

## Usage

```
/rune:strive plans/feat-user-auth-plan.md              # Execute a specific plan
/rune:strive plans/feat-user-auth-plan.md --approve    # Require plan approval per task
/rune:strive plans/feat-user-auth-plan.md --worktree   # Use git worktree isolation (experimental)
/rune:strive plans/feat-user-auth-plan.md --background # Background dispatch (workers run across sessions)
/rune:strive --collect [timestamp]                      # Gather results from a background dispatch
/rune:strive plans/feat-user-auth-plan.md --resume      # Resume from last checkpoint (skip completed tasks)
/rune:strive --resume                                   # Auto-detect latest checkpoint and resume
/rune:strive                                            # Auto-detect recent plan
```

## Pipeline Overview

```
Phase 0: Parse Plan -> Extract tasks, clarify ambiguities, detect --worktree flag
    |
Phase 0.5: Environment Setup -> Branch check, stash dirty files, SDK canary (worktree)
    |
Phase 1: Forge Team -> TeamCreate + TaskCreate pool
    1. Task Pool Creation (complexity ordering, time estimation)
    1.4. Design Context Discovery (conditional, zero cost if no artifacts)
    1.6. MCP Integration Discovery (conditional, zero cost if no integrations)
    1.7. File Ownership and Task Pool (static serialization via blockedBy)
    2. Signal Directory Setup (event-driven fast-path infrastructure)
    → TeamCreate + TaskCreate pool
    |
Phase 2: Summon Workers -> Self-organizing swarm
    | (workers claim -> implement -> complete -> repeat)
Phase 3: Monitor -> TaskList polling, stale detection
    |
Phase 3.5: Commit/Merge Broker -> Apply patches or merge worktree branches (orchestrator-only)
    |
Phase 3.6: Mini Test Phase -> Lightweight unit test verification (orchestrator-only)
    |
Phase 3.7: Codex Post-monitor Critique -> Architectural drift detection (optional, non-blocking)
    |
Phase 4: Ward Check -> Quality gates + verification checklist
    |
Phase 4.1: Todo Summary -> Generate worker-logs/_summary.md from per-worker log files (orchestrator-only)
    |
Phase 4.3: Doc-Consistency -> Non-blocking version/count drift detection (orchestrator-only)
    |
Phase 4.4: Quick Goldmask -> Compare predicted CRITICAL files vs committed (orchestrator-only)
    |
Phase 4.5: Codex Advisory -> Optional plan-vs-implementation review (non-blocking)
    |
Phase 4.6: Drift Signals -> Workers write drift signal files to tmp/work/{timestamp}/drift-signals/ when plan-reality mismatches are detected
    |
Phase 5: Echo Persist -> Save learnings
    |
Phase 6: Cleanup -> Shutdown workers, TeamDelete
    |
Phase 6.5: Ship -> Push + PR creation (optional)
    |
Output: Feature branch with commits + PR (optional)
```

## Phase 0: Parse Plan

See [parse-plan.md](references/parse-plan.md) for detailed task extraction, shard context, ambiguity detection, and user confirmation flow.

**Summary**: Read plan file, validate path, extract tasks with dependencies, classify as impl/test, detect ambiguities, confirm with user.

### Resume Detection (Phase 0, after plan path validation)

When `--resume` is passed, the orchestrator scans for a valid checkpoint from a prior crashed or interrupted session and reconstructs the task pool with completed tasks pre-marked.

```javascript
// Parse --resume flag
const resumeRequested = args.includes("--resume")

if (resumeRequested) {
  const checkpointMaxAgeMs = readTalismanSection("work")?.checkpoint_max_age_ms ?? 86400000  // 24h default
  const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
  let checkpointFile = null
  let checkpoint = null

  // Auto-detect: find most recent checkpoint matching this plan
  const candidates = Glob("tmp/work/*/strive-checkpoint.json")
  for (const candidate of candidates.sort().reverse()) {  // newest first by timestamp dir
    let parsed
    try {
      parsed = JSON.parse(Read(candidate))
    } catch (e) {
      log(`Resume: skipping corrupted checkpoint ${candidate}`)
      continue  // corrupted JSON → skip
    }

    // Session isolation: config_dir must match
    if (parsed.config_dir !== configDir) continue

    // Plan match check
    if (parsed.plan_path !== planPath) continue

    // Staleness check (configurable, default 24h)
    if ((Date.now() - parsed.updated_at) > checkpointMaxAgeMs) {
      log(`Resume: skipping stale checkpoint ${candidate} (age > ${checkpointMaxAgeMs}ms)`)
      continue
    }

    // Live session check: skip if another live session owns this checkpoint
    if (parsed.owner_pid) {
      // SEC-001: Validate owner_pid is purely numeric before shell use
      if (!/^\d+$/.test(String(parsed.owner_pid))) {
        log(`Resume: skipping checkpoint with invalid owner_pid format`)
        continue
      }
      const pidAlive = Bash(`kill -0 ${parsed.owner_pid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
      if (pidAlive === "alive" && String(parsed.owner_pid) !== String(Bash("echo $PPID").trim())) {
        log(`Resume: skipping checkpoint owned by live session PID ${parsed.owner_pid}`)
        continue
      }
    }

    checkpointFile = candidate
    checkpoint = parsed
    break
  }

  if (!checkpointFile) {
    log("Resume: no valid checkpoint found for this plan. Starting fresh.")
    // Fall through to normal flow
  } else {
    // Plan modification detection: compare plan file mtime
    // SEC-006: Validate planPath before shell use
    if (!/^[a-zA-Z0-9._\-\/]+$/.test(planPath) || planPath.includes('..')) {
      log(`Resume: invalid planPath format — skipping modification check`)
    } else {
    const currentMtime = Bash(`stat -f '%m' "${planPath}" 2>/dev/null || stat -c '%Y' "${planPath}" 2>/dev/null`).trim()
    if (checkpoint.plan_mtime && currentMtime !== checkpoint.plan_mtime) {
      log("Resume: WARNING — plan file modified since checkpoint. Changes may affect task definitions.")
      // Warn user but proceed (plan modifications may be intentional refinements)
    }

    // Reconstruct task pool with completion status
    const completedTaskIds = (checkpoint.completed_tasks || []).map(id => String(id))
    for (const task of extractedTasks) {
      const taskIdStr = String(task.id)
      if (completedTaskIds.includes(taskIdStr)) {
        // Verify completed task artifacts still exist
        const artifactInfo = checkpoint.task_artifacts?.[taskIdStr]
        const taskFiles = artifactInfo?.files || []
        let allFilesExist = true
        for (const file of taskFiles) {
          // SEC-002: Validate artifact file path before shell use
          if (!/^[a-zA-Z0-9._\-\/]+$/.test(file) || file.includes('..')) {
            log(`Resume: skipping artifact with invalid path format: ${file}`)
            allFilesExist = false
            break
          }
          const exists = Bash(`test -f "${file}" && echo "yes" || echo "no"`).trim()
          if (exists !== "yes") {
            log(`Resume: completed task ${taskIdStr} artifact missing: ${file} — re-adding to pool`)
            allFilesExist = false
            break
          }
        }

        if (allFilesExist) {
          task.status = "completed"
          task.resumed = true
        }
        // If files missing, task stays pending (re-added to pool)
      }
    }

    const remainingTasks = extractedTasks.filter(t => t.status !== "completed")
    log(`Resume: ${completedTaskIds.length} tasks already done, ${remainingTasks.length} remaining`)

    // Re-validate dependency graph: prune blockedBy edges to completed tasks
    for (const task of remainingTasks) {
      if (task.blockedBy) {
        task.blockedBy = task.blockedBy.filter(depId =>
          !completedTaskIds.includes(String(depId))
        )
      }
    }
  }  // end SEC-006 else (valid planPath)
  }  // end checkpointFile else
}
```

**Edge cases handled**:

| Edge Case | Handling |
|-----------|----------|
| Plan modified since checkpoint | Warn via log, proceed (user refinements are common) |
| Checkpoint from different config_dir | Skipped (session isolation) |
| Checkpoint > 24h old | Skipped as stale (configurable via `work.checkpoint_max_age_ms`) |
| Live session owns checkpoint | Skipped if owner PID alive and not current session |
| Completed task files deleted | Artifact verification catches this → re-added to pool |
| Corrupted checkpoint JSON | Caught by try/catch → skipped with warning |
| `--resume` with no checkpoint | Warning, falls through to fresh start |
| Task ID type mismatch | All IDs cast to `String()` at read boundaries |
| Circular deps after filtering completed tasks | `blockedBy` edges to completed tasks pruned eagerly |

### Worktree Mode Detection (Phase 0)

Parse `--worktree` flag and talisman config. When active: loads `git-worktree` skill, uses wave-aware monitoring, and replaces commit broker with merge broker.

See [worktree-and-mcp.md](references/worktree-and-mcp.md) for the full detection code and mode effects.

## Phase 0.5: Environment Setup

Before forging the team, verify the git environment is safe for work. Checks branch safety (warns on `main`/`master`), handles dirty working trees with stash UX, and validates worktree prerequisites when in worktree mode.

**Skip conditions**: Invoked via `/rune:arc` (arc handles COMMIT-1), or `work.skip_branch_check: true` in talisman.

See [env-setup.md](references/env-setup.md) for the full protocol — branch check, dirty tree detection, stash UX, and worktree validation.

## Phase 0.7: Workflow Lock (writer)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "writer"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "strive" "writer"`)
```

## Phase 1: Forge Team

Creates the team, signal directories, applies complexity-aware task ordering, estimates task time, computes wave configuration, and writes the session state file.

Key steps: teamTransition pre-create guard → signal directory + inscription.json → output directories → complexity scoring + sort → time estimation → wave computation → state file with session isolation fields.

See [forge-team.md](references/forge-team.md) for the full implementation code.

### Design Context Discovery (conditional, zero cost if no artifacts)

See [design-context.md](references/design-context.md) for the 4-strategy cascade (design-package → arc-artifacts → design-sync → figma-url-only), conditional skill loading, and task annotation flow.

**Summary**: Triple-gated (`design_sync.enabled` + frontend task signals + artifact presence). When active, loads `frontend-design-patterns`, `figma-to-react`, `design-sync` skills and injects DCD/VSM content into worker prompts.

### MCP Integration Discovery (conditional, zero cost if no integrations)

**Summary**: Triple-gated (`integrations.mcp_tools` exists in talisman + phase match for "strive" + trigger match against task files/description). When active, loads companion skills via `loadMCPSkillBindings()` and passes `buildMCPContextBlock()` output to worker prompt builder.

See [mcp-integration.md](references/mcp-integration.md) for the resolver algorithm and [worktree-and-mcp.md](references/worktree-and-mcp.md) for the inline integration code.

### File Ownership and Task Pool

See [file-ownership.md](references/file-ownership.md) for file target extraction, risk classification, SEC-STRIVE-001 enforcement via inscription.json, and quality contract.

**Summary**: Extract file targets per task → detect overlaps → serialize via `blockedBy` → create task pool with quality contract → write `task_ownership` to inscription.json. Flat-union allowlist enforced by `validate-strive-worker-paths.sh` hook.

## Phase 2: Summon Swarm Workers

See [worker-prompts.md](references/worker-prompts.md) for full worker prompt templates, scaling logic, and the scaling table.

**Summary**: Summon rune-smith (implementation) and trial-forger (test) workers. Workers receive pre-assigned task lists via inline prompts. Commits are handled through the Tarnished's commit broker. Do not run `git add` or `git commit` directly.

See [todo-protocol.md](references/todo-protocol.md) for the worker todo file protocol that MUST be included in all spawn prompts.

### Wave-Based Execution

See [wave-execution.md](references/wave-execution.md) for the wave loop algorithm, SEC-002 sanitization, non-goals extraction, and worktree mode spawning.

**Summary**: Tasks split into bounded waves (`maxWorkers × tasksPerWorker`). Each wave: distribute → spawn → monitor → commit broker → shutdown → next wave. Single-wave optimization skips overhead when `totalWaves === 1`.

## Phase 3: Monitor

Poll TaskList with timeout guard to track progress. See [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) for the shared polling utility.

> **ANTI-PATTERN — NEVER DO THIS:**
> `Bash("sleep 60 && echo poll check")` — This skips TaskList entirely. You MUST call `TaskList` every cycle.

```javascript
const result = waitForCompletion(teamName, taskCount, {
  timeoutMs: 1_800_000,      // 30 minutes
  staleWarnMs: 300_000,      // 5 minutes — warn about stalled worker
  autoReleaseMs: 600_000,    // 10 minutes — release task for reclaim
  pollIntervalMs: 30_000,
  label: "Work",
  onCheckpoint: (cp) => { ... }
})
```

### Phase 3 Inline Monitoring Blocks

Four inline blocks run each poll cycle in sequence: signal checks → smart reassignment → stale lock scan → stuck worker detection.

- **Signal checks**: Context-critical shutdown (Layer 1), all-tasks-done (Layer 4), force shutdown (Layer 3)
- **Smart reassignment**: Tasks exceeding `multiplier × estimated_minutes` get warned, then force-released after grace period. Max 2 reassignments per task. Gated by `work.reassignment.enabled`.
- **Stale file lock scan**: Removes lock signals older than `stale_threshold_ms` (default: 600s)
- **Stuck worker detection**: Workers exceeding `max_runtime_minutes` (default: 20) receive `shutdown_request` and have tasks released

See [monitor-inline.md](references/monitor-inline.md) for the full implementation code and configuration.

### Question Relay Detection (Phase 3 — Inline)

During Phase 3, the orchestrator handles worker questions reactively. Worker questions arrive via `SendMessage` (auto-delivered — no polling required). Compaction recovery uses a fast-path signal scan.

See [question-relay.md](references/question-relay.md) for full protocol details — `relayQuestionToUser()`, compaction recovery (ASYNC-004), SEC-002/SEC-006 enforcement, live vs recovery paths, and talisman configuration.

**Talisman gate**: Check `question_relay.enabled` (default: `true`) before activating. If disabled, workers proceed on best-effort without question surfacing.

### Discipline Work Loop (8-Phase Convergence Cycle)

When a plan contains YAML acceptance criteria (`AC-*` blocks), strive activates the Discipline Work Loop — an 8-phase convergence cycle that replaces linear task execution with iterative verification.

**Activation gate**: `hasCriteria` — plan has at least one `AC-*` block in code fences. Plans without criteria degrade to current behavior (backward compatibility).

**Reference**: See [discipline-work-loop.md](references/discipline-work-loop.md) for the full 8-phase protocol.
**Convergence detail**: See [work-loop-convergence.md](references/work-loop-convergence.md) for the Phase 5 convergence protocol — entry conditions, iteration logic, exit conditions, gap task creation, and report format.
**Task format**: See [task-file-format.md](references/task-file-format.md) for the task file YAML schema.

**Phases**: Decompose → Review Tasks → Assign → Execute → Monitor → Review Work → Converge → Quality

**Convergence**: Configurable via `talisman.discipline.max_convergence_iterations` (default: 3). Stagnation detection escalates to human after 2+ iterations with same failing criteria.

**Backward compatibility**: Plans without YAML criteria skip Phase 1.5 (cross-reference), Phase 4.5 (completion matrix), and Phase 5 (convergence loop). SOW contracts use file-based scope instead of criteria-based scope.

### Discipline Escalation Chain (Phase 3 — Planned)

> **Status**: Planned — not yet implemented. This section documents the intended escalation behavior when the `validate-discipline-proofs.sh` TaskCompleted hook blocks task completion. Only activates when `discipline.enabled: true` AND `discipline.block_on_fail: true` in talisman.

When the discipline proof hook exits 2 (BLOCK), the worker receives feedback via stderr. The escalation chain provides structured recovery with a maximum of 4 attempts before human intervention:

1. **ATTEMPT 1 — Retry**: Worker receives the hook's failure message (which criteria failed, what evidence is missing). Worker retries the task with the discipline feedback, addressing the specific failing proofs.

2. **ATTEMPT 2 — Decompose**: If retry fails, the orchestrator splits the task into smaller sub-tasks. Each sub-task gets its own evidence path (`tmp/work/{timestamp}/evidence/{sub-task-id}/`). Decomposed tasks inherit the parent's acceptance criteria subset.

3. **ATTEMPT 3 — Reassign**: If decomposed tasks still fail, reassign to a different worker (fresh context window). The new worker receives the full failure history and prior evidence attempts.

4. **ATTEMPT 4 — Human escalation**: If all automated attempts fail, invoke `AskUserQuestion` with the failure details including: task description, all prior attempt results, failing criteria IDs, and evidence paths. Includes `silence_timeout` (default 5 min, separate from `max_convergence_iterations`) — if no human response within the timeout, mark task as FAILED and continue with remaining tasks.

**Configuration**:
- `discipline.max_convergence_iterations`: Controls automated attempts (default: 3). Total attempts = `max_convergence_iterations` + 1 (human).
- `discipline.block_on_fail: false` (WARN mode): No escalation triggered — hook warnings are advisory only.
- `discipline.enabled: false`: Entire escalation chain is skipped. Existing smart reassignment still operates independently.

**Attempt tracking**: Per-task attempt count tracked via task metadata field `discipline_attempts`. Incremented on each TaskCompleted hook rejection.

### Phase 3.5: Commit Broker (Orchestrator-Only, Patch Mode)

The Tarnished is the **sole committer** — workers generate patches, the orchestrator applies and commits them. Serializes all git index operations through a single writer, eliminating `.git/index.lock` contention.

Key steps: validate patch path, read patch + metadata, skip empty patches, dedup by taskId, apply with `--3way` fallback, reset staging area, stage specific files via `--pathspec-from-file`, commit with `-F` message file.

**Recovery on restart**: Scan `tmp/work/{timestamp}/patches/` for metadata JSON with no recorded commit SHA — re-apply unapplied patches.

### Phase 3.5: Merge Broker (Worktree Mode, Orchestrator-Only)

Replaces the commit broker when `worktreeMode === true`. Called between waves. See [worktree-merge.md](references/worktree-merge.md) for the complete algorithm, conflict resolution flow, and cleanup procedures.

Key guarantees: sorted by task ID for deterministic merge order, dedup guard, `--no-ff` merge, file-based commit message, escalate conflicts to user via `AskUserQuestion` (NEVER auto-resolve), worktree cleanup on completion.

### Phase 3.6: Mini Test Phase (Lightweight Verification)

After the commit/merge broker finishes, optionally run a lightweight test phase to catch obvious regressions before quality gates. Non-blocking — failures create fix tasks but don't block the pipeline.

**Pre-flight**: Check `testing.strive_test.enabled` (default: `true`). Worker drain gate waits for ALL active workers before running tests.

**Scope detection**: Uses `resolveTestScope("")` from testing skill — empty string = current branch diff (no PR number in strive context).

**Test discovery**: Uses `discoverUnitTests(changedFiles)` from testing references — maps changed files to test counterparts by convention.

**Execution**: Spawns `unit-test-runner` on existing team with 3-minute timeout. Runs diff-scoped unit tests only (not full testing pipeline).

**Failure handling**: If failures >= `testing.strive_test.failure_analysis_threshold` (default: 3), spawns `test-failure-analyst` for root cause analysis. Creates fix task for workers.

See [test-phase.md](references/test-phase.md) for the full protocol — pre-flight gates, scope detection, test discovery, runner spawning, failure analysis, and cleanup integration.

### Phase 3.7: Codex Post-monitor Architectural Critique (Optional, Non-blocking)

After all workers complete and the commit/merge broker finishes, optionally run Codex to detect architectural drift between committed code and the plan. Non-blocking, opt-in via `codex.post_monitor_critique.enabled`.

**Skip conditions**: Codex unavailable, `codex.disabled`, feature not enabled, `work` not in `codex.workflows`, or `total_worker_commits <= 3`.

See [codex-post-monitor.md](references/codex-post-monitor.md) for the full protocol — feature gate, nonce-bounded prompt injection, codex-exec.sh invocation, error classification, and ward check integration.

## Phase 4: Quality Gates

Read and execute [quality-gates.md](references/quality-gates.md) before proceeding.

**Phase 4 — Ward Check**: Discover wards from Makefile/package.json/pyproject.toml, execute each with SAFE_WARD validation, run 10-point verification checklist. On ward failure, create fix task and summon worker.

**Phase 4.1 — Todo Summary**: Orchestrator generates `worker-logs/_summary.md` after all workers exit. See [todo-protocol.md](references/todo-protocol.md) for full algorithm.

**Phase 4.3 — Doc-Consistency**: Non-blocking version/count drift detection. See [doc-consistency.md](../roundtable-circle/references/doc-consistency.md).

**Phase 4.4 — Quick Goldmask**: Compare plan-time CRITICAL file predictions against committed files. Emits WARNINGs only. Non-blocking.

**Phase 4.5 — Codex Advisory**: Optional plan-vs-implementation review via `codex exec`. INFO-level findings only. Talisman kill switch: `codex.work_advisory.enabled: false`.

## Phase 5: Echo Persist

```javascript
if (exists(".claude/echoes/workers/")) {
  appendEchoEntry(".claude/echoes/workers/MEMORY.md", {
    layer: "inscribed",
    source: `rune:strive ${timestamp}`,
  })
}
```

## Phase 6: Cleanup & Report

Standard cleanup: cache TaskList → dynamic member discovery → shutdown → grace period → artifact finalization (non-blocking) → retry-with-backoff TeamDelete → stale worker log fixup (FLAW-008) → worktree GC (if applicable) → stash restore → state file update → workflow lock release.

See [phase-6-cleanup.md](references/phase-6-cleanup.md) for the full cleanup pseudocode and completion report template. See [engines.md](../team-sdk/references/engines.md) § cleanup for the shared pattern.

## Phase 6.5: Ship (Optional)

See [ship-phase.md](references/ship-phase.md) for gh CLI pre-check, ship decision flow, PR template generation, and smart next steps.

**Summary**: Offer to push branch and create PR. Generates PR body from plan metadata, task list, ward results, verification warnings, and todo summary. See [todo-protocol.md](references/todo-protocol.md) for PR body Work Session format.

## --approve Flag (Plan Approval Per Task)

When `--approve` is set, each worker proposes an implementation plan before coding.

**Flow**: Worker reads task → writes proposal to `tmp/work/{timestamp}/proposals/{task-id}.md` → sends to leader → leader presents via `AskUserQuestion` → user approves/rejects/skips → max 2 rejection cycles → timeout 3 minutes → auto-REJECT (fail-closed).

**Proposal format**: Markdown with `## Approach`, `## Files to Modify`, `## Files to Create`, `## Risks` sections.

**Arc integration**: When used via `/rune:arc --approve`, the flag applies ONLY to Phase 5 (WORK), not to Phase 7 (MEND).

## Incremental Commits

Each task produces exactly one commit via the commit broker: `rune: <task-subject> [ward-checked]`.

Task subjects are sanitized: strip newlines + control chars, limit to 72 chars, use `git commit -F <message-file>` (not inline `-m`).

Only the Tarnished (orchestrator) updates plan checkboxes — workers do not edit the plan file.

## Key Principles

### For the Tarnished (Orchestrator)

- **Ship complete features**: Verify wards pass, plan checkboxes are checked, and offer to create a PR.
- **Fail fast on ambiguity**: Ask clarifying questions in Phase 0, not after workers have started implementing.
- **Branch safety first**: Do not let workers commit to `main` without explicit user confirmation.
- **Serialize git operations**: All commits go through the commit broker.

### For Workers (Rune Smiths & Trial Forgers)

- **Match existing patterns**: Read similar code before writing new code.
- **Test as you go**: Run wards after each task, not just at the end. Fix failures immediately.
- **One task, one patch**: Each task produces exactly one patch.
- **Self-review before ward**: Re-read every changed file before running quality gates.
- **Exit cleanly**: No tasks after 3 retries → idle notification → exit. Approve shutdown requests immediately.

## Error Handling

| Error | Recovery |
|-------|----------|
| Worker stalled (>5 min) | Warn lead, release after 10 min |
| Total timeout (>30 min) | Final sweep, collect partial results, commit applied patches |
| Worker crash | Task returns to pool for reclaim |
| Ward failure | Create fix task, summon worker to fix |
| All workers crash | Abort, report partial progress |
| Plan has no extractable tasks | Ask user to restructure plan |
| Conflicting file edits | File ownership serializes via blockedBy; commit broker handles residual conflicts |
| Empty patch (worker reverted) | Skip commit, log as "completed-no-change" |
| Patch conflict (two workers on same file) | `git apply --3way` fallback; mark NEEDS_MANUAL_MERGE on failure |
| `git push` failure (Phase 6.5) | Warn user, skip PR creation, show manual push command |
| `gh pr create` failure (Phase 6.5) | Warn user (branch was pushed), show manual command |
| Detached HEAD state | Abort with error — require user to checkout a branch first |
| `git stash push` failure (Phase 0.5) | Warn and continue with dirty tree |
| `git stash pop` failure (Phase 6) | Warn user — manual restore needed: `git stash list` |
| Merge conflict (worktree mode) | Escalate to user via AskUserQuestion — never auto-resolve |
| Worker crash in worktree | Worktree cleaned up on Phase 6, task returned to pool |
| Orphaned worktrees (worktree mode) | Phase 6 garbage collection: `git worktree prune` + force removal |

## Common Pitfalls

| Pitfall | Prevention |
|---------|------------|
| Committing to `main` | Phase 0.5 branch check (fail-closed) |
| Building wrong thing from ambiguous plan | Phase 0 clarification sub-step |
| 80% done syndrome | Phase 6.5 ship phase |
| Over-reviewing simple changes | Review guidance heuristic in completion report |
| Workers editing same files | File ownership conflict detection (Phase 1, step 5.1) serializes via blockedBy |
| Stale worker blocking pipeline | Stale detection (5 min warn, 10 min auto-release) |
| Ward failure cascade | Auto-create fix task, summon fresh worker |
| Dirty working tree conflicts | Phase 0.5 stash check |
| `gh` CLI not installed | Pre-check with fallback to manual instructions |
| Partial file reads | Step 5: "Read FULL target files" |
| Fixes that introduce new bugs | Step 6.5: Self-review checklist |
