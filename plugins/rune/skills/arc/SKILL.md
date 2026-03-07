---
name: arc
description: |
  Use when running the full plan-to-merged-PR pipeline, when resuming an
  interrupted arc with --resume, or when any named phase fails (forge,
  plan-review, plan-refinement, verification, semantic-verification,
  design-extraction, design-verification, design-iteration, work,
  gap-analysis, codex-gap-analysis, gap-remediation, goldmask-verification,
  code-review, goldmask-correlation, mend, verify-mend, test,
  pre-ship-validation, bot-review-wait, pr-comment-resolution, ship, merge).
  Use when checkpoint resume is needed after a crash or session end.
  28-phase pipeline with convergence loops, Goldmask risk analysis,
  pre-ship validation, bot review integration, cross-model verification,
  and conditional design sync (Figma VSM extraction, fidelity verification, iteration).
  Keywords: arc, pipeline, --resume, checkpoint, convergence, forge, mend,
  bot review, PR comments, ship, merge, design sync, Figma, VSM, 28 phases.

  <example>
  user: "/rune:arc plans/feat-user-auth-plan.md"
  assistant: "The Tarnished begins the arc — 28 phases of forge, review, design sync, goldmask, test, mend, convergence, pre-ship validation, bot review, ship, and merge..."
  </example>

  <example>
  user: "/rune:arc --resume"
  assistant: "Resuming arc from Phase 5 (WORK) — validating checkpoint integrity..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[plan-file-path | --resume]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Agent
  - TaskCreate
  - TaskUpdate
  - TaskGet
  - TaskList
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
  - EnterPlanMode
  - ExitPlanMode
---

# /rune:arc — End-to-End Orchestration Pipeline

Chains twenty-eight phases into a single automated pipeline. Each phase runs as its own Claude Code turn with fresh context — the `arc-phase-stop-hook.sh` drives phase iteration via the Stop hook pattern. Artifact-based handoff connects phases. Checkpoint state enables resume after failure.

**Context budget advisory**: Full arc run: 28 phases x ~3.5min avg = ~95 minutes (lower bound). Context compaction is almost guaranteed in a single session. For constrained sessions, use `--no-forge` to skip Phase 1 enrichment, or split into multiple `/rune:arc --resume` sessions. The `PreCompact` hook saves checkpoint state automatically.

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `elicitation`, `codex-cli`, `team-sdk`, `testing`, `agent-browser`, `polling-guard`, `zsh-compat`, `design-sync`

## CRITICAL — Agent Teams Enforcement (ATE-1)

**EVERY phase that summons agents MUST follow this exact pattern. No exceptions.**

```
1. TeamCreate({ team_name: "{phase-prefix}-{id}" })     ← CREATE TEAM FIRST
2. TaskCreate({ subject: ..., description: ... })         ← CREATE TASKS
3. Agent({ team_name: "...", name: "...",                  ← SPAWN WITH team_name
     subagent_type: "general-purpose",                    ← ALWAYS general-purpose
     prompt: "You are {agent-name}...", ... })             ← IDENTITY VIA PROMPT
4. Monitor → Shutdown → TeamDelete with fallback          ← CLEANUP
```

**NEVER DO:**
- `Agent({ ... })` without `team_name` — bare Agent calls bypass Agent Teams entirely.
- Using named `subagent_type` values — always use `subagent_type: "general-purpose"` and inject agent identity via the prompt.

**ENFORCEMENT:** The `enforce-teams.sh` PreToolUse hook blocks bare Agent calls when a Rune workflow is active.

## Phase Number → Name Mapping

The pipeline uses **named phases** (not numeric IDs) in `PHASE_ORDER`. The numeric labels below are for human reference only — execution order is always determined by position in `PHASE_ORDER`.

| # | Phase Key | Type | Timeout | Delegated To |
|---|-----------|------|---------|-------------|
| 1 | `forge` | Team | 15 min | `/rune:forge` |
| 2 | `plan_review` | Team | 15 min | `/rune:appraise` (inspect mode) |
| 2.5 | `plan_refine` | Inline | 3 min | — |
| 2.7 | `verification` | Inline | 30 sec | — |
| 2.8 | `semantic_verification` | Team | 12 min | Codex (conditional) |
| 3 | `design_extraction` | Team | 10 min | Conditional: `design_sync.enabled` |
| 4.5 | `task_decomposition` | Team | 10 min | Codex (conditional) |
| 5 | `work` | Team | 35 min | `/rune:strive` |
| 3.3 | `storybook_verification` | Team | 15 min | Conditional: `storybook.enabled` |
| 5.2 | `design_verification` | Team | 8 min | Conditional: VSM files |
| 5.3 | `ux_verification` | Team | 5 min | Conditional: `ux.enabled` |
| 5.5 | `gap_analysis` | Team | 12 min | — |
| 5.6 | `codex_gap_analysis` | Team | 16 min | Codex (conditional) |
| 5.8 | `gap_remediation` | Team | 15 min | — |
| 5.7 | `goldmask_verification` | Team | 15 min | `/rune:goldmask` |
| 6 | `code_review` | Team | 15 min | `/rune:appraise --deep` |
| 6.5 | `goldmask_correlation` | Inline | 1 min | — |
| 7 | `mend` | Team | 23 min | `/rune:mend` |
| 7.3 | `verify_mend` | Inline | 4 min | — |
| 7.4 | `design_iteration` | Team | 15 min | Conditional: design fidelity |
| 7.7 | `test` | Team | 25-50 min | Testing agents |
| 7.8 | `test_coverage_critique` | Team | 15 min | Codex (conditional) |
| 8.5 | `pre_ship_validation` | Inline | 6 min | — |
| 8.55 | `release_quality_check` | Team | 10 min | Codex (conditional) |
| 9 | `ship` | Inline | 5 min | — |
| 9.1 | `bot_review_wait` | Inline | 15 min | Conditional: `--bot-review` |
| 9.2 | `pr_comment_resolution` | Inline | 20 min | Conditional: `--bot-review` |
| 9.5 | `merge` | Inline | 10 min | — |

> **Non-monotonic numbering**: Phase 5.8 (gap_remediation) executes **before** 5.7 (goldmask_verification). Always use `PHASE_ORDER` array position, not numeric IDs.

## Usage

```
/rune:arc <plan_file.md>              # Full pipeline
/rune:arc <plan_file.md> --no-forge   # Skip research enrichment
/rune:arc <plan_file.md> --approve    # Require human approval for work tasks
/rune:arc --resume                    # Resume from last checkpoint
/rune:arc <plan_file.md> --skip-freshness   # Skip freshness validation
/rune:arc <plan_file.md> --confirm          # Pause on all-CONCERN escalation
/rune:arc <plan_file.md> --no-pr           # Skip PR creation (Phase 9)
/rune:arc <plan_file.md> --no-merge        # Skip auto-merge (Phase 9.5)
/rune:arc <plan_file.md> --draft           # Create PR as draft
/rune:arc <plan_file.md> --bot-review     # Enable bot review wait + comment resolution
/rune:arc <plan_file.md> --no-bot-review  # Force-disable bot review
/rune:arc <plan_file.md> --no-accept-external  # Prompt when unrelated changes detected (default: accept)
```

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--no-forge` | Skip Phase 1 (research enrichment), use plan as-is | Off |
| `--approve` | Require human approval for each work task (Phase 5 only) | Off |
| `--resume` | Resume from last checkpoint. Plan path auto-detected from checkpoint | Off |
| `--skip-freshness` | Skip plan freshness check (bypass stale-plan detection) | Off |
| `--confirm` | Pause for user input when all plan reviewers raise CONCERN verdicts | Off |
| `--no-pr` | Skip Phase 9 (PR creation) | Off |
| `--no-merge` | Skip Phase 9.5 (auto merge) | Off |
| `--no-test` | Skip Phase 7.7 (testing) | Off |
| `--draft` | Create PR as draft | Off |
| `--accept-external` | Accept external changes (bug fixes, audit commits) on branch without prompting | **On** |
| `--no-accept-external` | Prompt user when unrelated changes are detected on branch | Off |
| `--bot-review` | Enable bot review wait + PR comment resolution (Phase 9.1/9.2) | Off |
| `--no-bot-review` | Force-disable bot review (overrides both `--bot-review` and talisman) | Off |

> **Note**: Worktree mode for `/rune:strive` (Phase 5) is activated via `work.worktree.enabled: true` in talisman.yml, not via a `--worktree` flag on arc.

## External Changes Policy (`accept_external_changes`)

When `--accept-external` is passed (or `arc.defaults.accept_external_changes: true` in talisman), the pipeline tolerates commits on the working branch that are NOT part of the plan. This is common when:
- Running `/rune:arc-batch` where prior arcs leave commits on the branch
- Running `/rune:audit` or manual bug fixes in a parallel session that commit to the same branch
- Cherry-picking hotfixes onto the arc's working branch

**Behavior when enabled:**
- Do NOT pause or prompt the user about unrelated changes — continue autonomously
- Gap analysis evaluates only plan criteria coverage; external changes are not flagged as drift
- Code review reviews all changes but does not halt for code outside plan scope
- All commits (plan-related and external) are included in the PR

**Default**: `true` (accept external changes silently). Use `--no-accept-external` or `arc.defaults.accept_external_changes: false` to restore the prompting behavior.

## Workflow Lock (writer)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "writer"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "arc" "writer"`)
```

## Pre-flight

See [arc-preflight.md](references/arc-preflight.md) for the full pre-flight sequence.

Read and execute the arc-preflight.md algorithm at dispatcher init.

### Plan Freshness Check (FRESH-1)

See [freshness-gate.md](references/freshness-gate.md) for the full algorithm.

Read and execute the algorithm. Store `freshnessResult` for checkpoint initialization below.

### Context Monitoring Bridge Check (non-blocking advisory)

```javascript
const bridgePattern = `/tmp/rune-ctx-*.json`
const bridgeFiles = Bash(`ls ${bridgePattern} 2>/dev/null | head -1`).trim()
if (!bridgeFiles) {
  warn(`Context monitoring bridge not detected.`)
}
const ctxBridgeFile = bridgeFiles || null
```

### Phase Constants

Read [arc-phase-constants.md](references/arc-phase-constants.md) for PHASE_ORDER, PHASE_TIMEOUTS, CYCLE_BUDGET, calculateDynamicTimeout(), FORBIDDEN_PHASE_KEYS, and updateCascadeTracker().

### Initialize Checkpoint (ARC-2)

See [arc-checkpoint-init.md](references/arc-checkpoint-init.md) for the full initialization.

Read and execute the arc-checkpoint-init.md algorithm.

### Session-Scoped Todos (initialized by checkpoint)

`todos_base` is set eagerly during checkpoint init (see [arc-checkpoint-init.md](references/arc-checkpoint-init.md)) — NOT as a separate post-init step. The directory `tmp/arc/{id}/todos/` is also created during init.

```javascript
// VERIFY todos_base was set by checkpoint init (defensive — should never be null)
if (!checkpoint.todos_base) {
  const todosBase = `tmp/arc/${id}/todos/`
  Bash(`mkdir -p "${todosBase}"`)
  updateCheckpoint({ todos_base: todosBase })
  warn("todos_base was null after checkpoint init — recovered. This should not happen.")
}
```

Each delegated phase (strive, appraise) detects the active arc checkpoint and redirects todos to `tmp/arc/{id}/todos/` instead of their own output directory. Detection: scan `.claude/arc/*/checkpoint.json` for the relevant phase `in_progress` + `todos_base`. No `--todos-dir` flag is passed. See [arc-delegation-checklist.md](references/arc-delegation-checklist.md) § Phase 5, 6, 7 for per-phase todo resolution contracts.

### Dispatch Herald — Inter-Phase Staleness Detection

Between delegated phases that use Utility Crew context packs, the dispatch-herald agent checks for pack staleness. Only spawned when `utility_crew.enabled` AND `dispatch_herald.enabled` AND the workflow is `arc` or `arc-batch`.

**Transition points** (herald spawns between these phases):
- After `work` → before `code_review` (file list may have changed from worker commits)
- After `code_review` → before `mend` (TOME content is new since pack creation)

```javascript
// Dispatch Herald — inter-phase staleness check
// Called by the phase reference file at the START of code_review and mend phases
const crewConfig = readTalismanSection("settings")?.utility_crew
const heraldEnabled = crewConfig?.enabled !== false && crewConfig?.dispatch_herald?.enabled !== false

if (heraldEnabled && checkpoint.crew_used) {
  // Spawn herald into the current phase's team
  const heraldTimeout = crewConfig?.dispatch_herald?.staleness_check_ms ?? 30000

  Agent({
    team_name: currentTeamName,
    name: "dispatch-herald",
    subagent_type: "general-purpose",
    model: "haiku",
    prompt: `You are dispatch-herald. Read your agent definition, then check context pack staleness.
Context packs dir: ${checkpoint.context_packs_dir}
Manifest: ${checkpoint.context_packs_dir}/manifest.json
Current phase: ${phaseName}
Previous phase: ${previousPhaseName}
TOME path: ${checkpoint.tome_path ?? "N/A"}
Plan path: ${planFile}
Mend round: ${checkpoint.mend_round ?? 0}`,
    run_in_background: false
  })

  // Read staleness report
  try {
    const report = JSON.parse(Read(`${checkpoint.context_packs_dir}/staleness-report.json`))
    if (report.recommendation === "refresh" || report.recommendation === "full_refresh") {
      // Re-invoke context-scribe for affected packs only (incremental refresh)
      checkpoint.crew_refresh_needed = true
      checkpoint.stale_packs = report.affected_packs
    }
  } catch (e) {
    warn("dispatch-herald: staleness report not found or unparseable — proceeding without refresh")
  }

  // Shutdown herald before phase proceeds
  SendMessage({ type: "shutdown_request", recipient: "dispatch-herald", content: "Staleness check complete" })
}
```

### Inter-Phase Cleanup Guard (ARC-6)

See [arc-preflight.md](references/arc-preflight.md) for `prePhaseCleanup()`.

```javascript
Read(references/arc-preflight.md)
Read(references/arc-phase-cleanup.md)
```

### Stale Arc Team Scan

See [arc-preflight.md](references/arc-preflight.md) for the stale team scan algorithm.

## Resume (`--resume`)

See [arc-resume.md](references/arc-resume.md) for the full resume algorithm.

```javascript
if (args.includes("--resume")) {
  Read(references/arc-preflight.md)
  Read(references/arc-phase-cleanup.md)
  Read and execute the arc-resume.md algorithm.
}
```

## Phase Loop State File

After checkpoint initialization (or resume), write the phase loop state file that drives `arc-phase-stop-hook.sh`:

```javascript
// Write the phase loop state file for the Stop hook driver.
// The Stop hook reads this file, finds the next pending phase in the checkpoint,
// and re-injects the phase-specific prompt with fresh context.
const stateContent = `---
active: true
iteration: 0
max_iterations: 50
checkpoint_path: .claude/arc/${id}/checkpoint.json
plan_file: ${planFile}
branch: ${branch}
arc_flags: ${args.replace(/\s+/g, ' ').trim()}
config_dir: ${configDir}
owner_pid: ${ownerPid}
session_id: ${sessionId}
compact_pending: false
---
`
Write('.claude/arc-phase-loop.local.md', stateContent)
```

## First Phase Invocation

Execute the first pending phase from the checkpoint. The Stop hook (`arc-phase-stop-hook.sh`) handles all subsequent phases automatically.

```javascript
// Check for context-critical shutdown signal before starting next phase (Layer 1)
const shutdownSignalCheck = (() => {
  try {
    const sid = Bash(`echo "$CLAUDE_SESSION_ID"`).trim()
    const signalPath = `tmp/.rune-shutdown-signal-${sid}.json`
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "context_warning"
  } catch { return false }
})()

if (shutdownSignalCheck) {
  warn("CTX-WARNING: Context pressure detected between phases. Skipping remaining phases.")
  // Mark remaining phases as skipped in checkpoint
  for (const p of PHASE_ORDER) {
    if (checkpoint.phases[p]?.status === 'pending') {
      checkpoint.phases[p].status = 'skipped'
      checkpoint.phases[p].skip_reason = 'context_pressure'
    }
  }
  Write(checkpointPath, checkpoint)
  return
}

// Find first pending phase
const firstPending = PHASE_ORDER.find(p => checkpoint.phases[p]?.status === 'pending')
if (!firstPending) {
  log("All phases already complete. Nothing to execute.")
  return
}

// ── Utility Crew: dispatch-herald staleness check (inter-phase) ──
// Spawns dispatch-herald between phases to detect stale context packs.
// Only runs when: (1) utility_crew.enabled, (2) dispatch_herald.enabled,
// (3) context-packs/ exists from a previous Crew invocation,
// (4) transition is between phases that use context packs (work→review, review→mend).
const crewConfig = readTalismanSection("settings")?.utility_crew ?? { enabled: true }
const packsDir = `${checkpoint.output_dir ?? `tmp/arc/${checkpoint.id}/`}context-packs/`
const HERALD_TRANSITIONS = new Set(["code_review", "mend"])  // phases where packs may be stale
if (crewConfig.enabled && crewConfig.dispatch_herald?.enabled !== false
    && HERALD_TRANSITIONS.has(firstPending)
    && Glob(`${packsDir}manifest.json`).length > 0) {
  try {
    const completedPhase = PHASE_ORDER.slice(0, PHASE_ORDER.indexOf(firstPending))
      .reverse().find(p => checkpoint.phases[p]?.status === 'completed') ?? "unknown"

    // Spawn herald into the current arc team
    Agent({
      team_name: checkpoint.team_name,
      name: "dispatch-herald",
      subagent_type: "general-purpose",
      model: "haiku",
      prompt: `Check staleness: context_packs_dir=${packsDir}, manifest_path=${packsDir}manifest.json, current_phase=${firstPending}, previous_phase=${completedPhase}, tome_path=${checkpoint.output_dir ?? ""}TOME.md, plan_path=${checkpoint.plan_path ?? ""}, mend_round=${checkpoint.mend_round ?? 0}`,
      run_in_background: true
    })

    const heraldTimeout = crewConfig.dispatch_herald?.staleness_check_ms ?? 30000
    waitForCompletion(checkpoint.team_name, 1, {
      timeoutMs: heraldTimeout,
      pollIntervalMs: 30000,
      label: "Dispatch Herald"
    })

    // Read staleness report
    const stalenessReport = JSON.parse(Read(`${packsDir}staleness-report.json`))
    if (stalenessReport.stale && stalenessReport.recommendation !== "fresh") {
      // Trigger incremental refresh via context-scribe for affected packs
      // refreshStalePacks() from utility-crew SKILL.md
      const affectedAgents = stalenessReport.affected_packs.map(p => p.agent)
      // Re-invoke spawnUtilityCrew with reduced agent list (see utility-crew/SKILL.md)
    }

    // Shutdown herald
    SendMessage({ type: "shutdown_request", recipient: "dispatch-herald", content: "Staleness check complete" })
    Bash(`sleep 8`)
  } catch (heraldError) {
    // Herald failure is non-blocking — proceed with existing packs
    SendMessage({ type: "shutdown_request", recipient: "dispatch-herald", content: "Herald error — proceeding" })
  }
}

// Schema v19: stamp phase start time before executing
checkpoint.phases[firstPending].started_at = new Date().toISOString()
Write(checkpointPath, checkpoint)

// Read and execute the phase reference file
const refFile = getPhaseReferenceFile(firstPending)
Read(refFile)
// Execute the phase algorithm as described in the reference file.
// When done, update checkpoint.phases[firstPending].status to "completed".
// Schema v19: stamp phase completion time and compute duration
const completionTs = Date.now()
checkpoint.phases[firstPending].completed_at = new Date(completionTs).toISOString()
const phaseStartMs = new Date(checkpoint.phases[firstPending].started_at).getTime()
checkpoint.totals = checkpoint.totals ?? { phase_times: {}, total_duration_ms: null, cost_at_completion: null }
checkpoint.totals.phase_times[firstPending] = Number.isFinite(phaseStartMs) ? completionTs - phaseStartMs : null
// Then STOP responding — the Stop hook will advance to the next phase.
```

**Phase-to-reference mapping**: See `arc-phase-stop-hook.sh` `_phase_ref()` function for the canonical phase → reference file mapping.

**Timing instrumentation**: Each phase MUST stamp `started_at` before execution and `completed_at` + `totals.phase_times[phaseName]` (duration in ms) after. The Stop hook re-injects this same pattern for all subsequent phases via the phase prompt template. The `totals.phase_times` map accumulates durations across the full pipeline.

## Post-Arc (Final Phase)

These steps run after Phase 9.5 MERGE (the last phase). The Stop hook injects a completion prompt when all phases are done.

### Timing Totals + Completion Stamp (schema v19)

Before calling the Plan Completion Stamp, record arc-level timing metrics:

```javascript
// Schema v19: record arc completion time and total duration
const completedAtTs = new Date().toISOString()
checkpoint.completed_at = completedAtTs
checkpoint.totals = checkpoint.totals ?? { phase_times: {}, total_duration_ms: null, cost_at_completion: null }
checkpoint.totals.total_duration_ms = Date.now() - new Date(checkpoint.started_at).getTime()

// Read cost from statusline bridge file (non-blocking — skip if unavailable)
if (ctxBridgeFile) {
  try {
    const bridge = JSON.parse(Bash(`cat "${ctxBridgeFile}" 2>/dev/null`))
    checkpoint.totals.cost_at_completion = bridge.cost ?? null
  } catch (e) { /* bridge unavailable — leave null */ }
}
Write(checkpointPath, checkpoint)
```

### Plan Completion Stamp

See [arc-phase-completion-stamp.md](references/arc-phase-completion-stamp.md). Runs FIRST after merge — writes persistent record before context-heavy steps.

### Result Signal (automatic)

Written automatically by `arc-result-signal-writer.sh` PostToolUse hook. No manual call needed. See [arc-result-signal.md](references/arc-result-signal.md).

### Echo Persist + Completion Report

See [post-arc.md](references/post-arc.md) for echo persist and completion report template.

### Lock Release

```javascript
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_all_locks`)
```

### Final Sweep (ARC-9)

See [post-arc.md](references/post-arc.md). 30-second time budget. `on-session-stop.sh` handles remaining cleanup.

### Response Completion (CRITICAL)

After ARC-9 sweep, **finish your response immediately**. Do NOT process further TeammateIdle notifications or attempt additional cleanup. IGNORE zombie teammate messages — the Stop hook handles them.

## References

- [Architecture & Pipeline Overview](references/arc-architecture.md) — Pipeline diagram, orchestrator design, transition contracts
- [Phase Constants](references/arc-phase-constants.md) — PHASE_ORDER, PHASE_TIMEOUTS, CYCLE_BUDGET, shared utilities
- [Failure Policy](references/arc-failure-policy.md) — Per-phase failure handling matrix
- [Checkpoint Init](references/arc-checkpoint-init.md) — Schema v20, 3-layer config resolution
- [Resume](references/arc-resume.md) — Checkpoint restoration, schema migration
- [Pre-flight](references/arc-preflight.md) — Git state, branch creation, stale team scan, prePhaseCleanup
- [Phase Cleanup](references/arc-phase-cleanup.md) — postPhaseCleanup, PHASE_PREFIX_MAP
- [Freshness Gate](references/freshness-gate.md) — 5-signal plan drift detection
- [Phase Tool Matrix](references/phase-tool-matrix.md) — Per-phase tool restrictions and time budgets
- [Delegation Checklist](references/arc-delegation-checklist.md) — Phase delegation contracts (RUN/SKIP/ADAPT)
- [Naming Conventions](references/arc-naming-conventions.md) — Gate/validator/sentinel/guard taxonomy
- [Post-Arc](references/post-arc.md) — Echo persist, completion report, ARC-9 sweep
- [Completion Stamp](references/arc-phase-completion-stamp.md) — Plan file completion record
- [Result Signal](references/arc-result-signal.md) — Deterministic completion signal for stop hooks
- [Stagnation Sentinel](references/stagnation-sentinel.md) — Error pattern detection, budget enforcement
- [Codex Phases](references/arc-codex-phases.md) — Phases 2.8, 4.5, 5.6, 7.8, 8.55
- [Task Decomposition](references/arc-phase-task-decomposition.md) — Phase 4.5
- [Design Extraction](references/arc-phase-design-extraction.md) — Phase 3 (conditional)
- [Design Verification](references/arc-phase-design-verification.md) — Phase 5.2 (conditional)
