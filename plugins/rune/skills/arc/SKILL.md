---
name: arc
description: |
  Use when running the full plan-to-merged-PR pipeline, when resuming an
  interrupted arc with --resume, or when any named phase fails (forge,
  plan-review, plan-refinement, verification, semantic-verification,
  design-extraction, design-prototype, design-verification, design-iteration, work,
  gap-analysis, codex-gap-analysis, gap-remediation, goldmask-verification,
  code-review, goldmask-correlation, mend, verify-mend, test,
  browser-test, browser-test-fix, verify-browser-test,
  pre-ship-validation, bot-review-wait, pr-comment-resolution, ship, merge).
  Use when checkpoint resume is needed after a crash or session end.
  43-phase pipeline with convergence loops, Goldmask risk analysis,
  pre-ship validation, bot review integration, cross-model verification,
  and conditional design sync (Figma VSM extraction, prototype generation, fidelity verification, iteration).
  Keywords: arc, pipeline, --resume, checkpoint, convergence, forge, mend,
  bot review, PR comments, ship, merge, design sync, Figma, VSM, 43 phases.

  <example>
  user: "/rune:arc plans/feat-user-auth-plan.md"
  assistant: "The Tarnished begins the arc — 43 phases of forge, review, design sync, goldmask, test, browser test convergence, mend, convergence, pre-ship validation, bot review, ship, and merge..."
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

Chains forty phases into a single automated pipeline. Each phase runs as its own Claude Code turn with fresh context — the `arc-phase-stop-hook.sh` drives phase iteration via the Stop hook pattern. Artifact-based handoff connects phases. Checkpoint state enables resume after failure.

**Context budget advisory**: Full arc run: 43 phases x ~3.5min avg = ~140 minutes (lower bound). Context compaction is almost guaranteed in a single session. For constrained sessions, use `--no-forge` to skip Phase 1 enrichment, or split into multiple `/rune:arc --resume` sessions. The `PreCompact` hook saves checkpoint state automatically.

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

| # | Exec Order | Phase Key | Type | Timeout | Delegated To |
|---|-----------|-----------|------|---------|-------------|
| 1 | 1 | `forge` | Team | 15 min | `/rune:forge` |
| 2 | 2 | `plan_review` | Team | 15 min | `/rune:appraise` (inspect mode) |
| 2.5 | 3 | `plan_refine` | Inline | 3 min | — |
| 2.7 | 4 | `verification` | Inline | 30 sec | — |
| 2.8 | 5 | `semantic_verification` | Team | 12 min | Codex (conditional) |
| 3 | 6 | `design_extraction` | Team | 10 min | Conditional: `design_sync.enabled` |
| 3.2 | 7 | `design_prototype` | Team | 10 min | Conditional: `design_sync.enabled` + VSM files |
| 4.5 | 8 | `task_decomposition` | Team | 10 min | Codex (conditional) |
| 5 | 9 | `work` | Team | 35 min | `/rune:strive` |
| 5.1 | 10 | `drift_review` | Inline | 2 min | — |
| 3.3 | 11 | `storybook_verification` | Team | 15 min | Conditional: `storybook.enabled` |
| 5.2 | 12 | `design_verification` | Team | 8 min | Conditional: VSM files |
| 5.3 | 13 | `ux_verification` | Team | 5 min | Conditional: `ux.enabled` |
| 5.5 | 14 | `gap_analysis` | Team | 12 min | — |
| 5.6 | 15 | `codex_gap_analysis` | Team | 16 min | Codex (conditional) |
| 5.8 | 16 | `gap_remediation` | Team | 15 min | — |
| 5.7 | 17 | `goldmask_verification` | Team | 15 min | `/rune:goldmask` |
| 6 | 18 | `code_review` | Team | 15 min | `/rune:appraise --deep` |
| 6.5 | 19 | `goldmask_correlation` | Inline | 1 min | — |
| 7 | 20 | `mend` | Team | 23 min | `/rune:mend` |
| 7.3 | 21 | `verify_mend` | Inline | 4 min | — |
| 7.4 | 22 | `design_iteration` | Team | 15 min | Conditional: design fidelity |
| 7.7 | 23 | `test` | Team | 25-50 min | Testing agents |
| 7.7.5 | 24 | `browser_test` | Team | 15 min | Conditional: frontend + agent-browser |
| 7.7.6 | 25 | `browser_test_fix` | Team | 15 min | Conditional: browser_test failures |
| 7.7.7 | 26 | `verify_browser_test` | Inline | 4 min | Convergence controller |
| 7.8 | 27 | `test_coverage_critique` | Team | 15 min | Codex (conditional) |
| 7.9 | 28 | `deploy_verify` | Team | 5 min | Conditional: deployment verification |
| 8.5 | 29 | `pre_ship_validation` | Inline | 6 min | — |
| 8.55 | 30 | `release_quality_check` | Team | 10 min | Codex (conditional) |
| 9 | 31 | `ship` | Inline | 5 min | — |
| 9.1 | 32 | `bot_review_wait` | Inline | 15 min | Conditional: `--bot-review` |
| 9.2 | 33 | `pr_comment_resolution` | Inline | 20 min | Conditional: `--bot-review` |
| 9.5 | 34 | `merge` | Inline | 10 min | — |

> **Execution order**: The "Exec Order" column shows the actual sequence. Phase numbers (#) are for human reference only and are **non-monotonic** — e.g., 5.8 (gap_remediation) runs before 5.7 (goldmask_verification). Always use `PHASE_ORDER` array position, not numeric IDs. Total: 34 phases.

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
| `--no-browser-test` | Skip Phase 7.7.5-7.7.7 (browser test convergence loop) | Off |
| `--draft` | Create PR as draft | Off |
| `--accept-external` | Accept external changes (bug fixes, audit commits) on branch without prompting | **On** |
| `--no-accept-external` | Prompt user when unrelated changes are detected on branch | Off |
| `--bot-review` | Enable bot review wait + PR comment resolution (Phase 9.1/9.2) | Off |
| `--no-bot-review` | Force-disable bot review (overrides both `--bot-review` and talisman) | Off |
| `--status` | Show current arc phase, progress, and elapsed time (delegates to rune-status.sh) | Off |

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

### Inter-Phase Cleanup Guard (ARC-6)

See [arc-preflight.md](references/arc-preflight.md) for `prePhaseCleanup()`.

```javascript
Read(references/arc-preflight.md)
Read(references/arc-phase-cleanup.md)
```

### Stale Arc Team Scan

See [arc-preflight.md](references/arc-preflight.md) for the stale team scan algorithm.

## Status (`--status`)

Early return — display current arc phase, progress, and elapsed time without entering the pipeline.

```javascript
if (args.includes("--status")) {
  const output = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/rune-status.sh"`)
  // Display current phase, elapsed time, completed/total phases
  return output
}
```

## Resume (`--resume`)

See [arc-resume.md](references/arc-resume.md) for the full resume algorithm.

```javascript
if (args.includes("--resume")) {
  Read(references/arc-preflight.md)
  Read(references/arc-phase-cleanup.md)
  Read and execute the arc-resume.md algorithm.
}
```

## Pre-Flight: State File Conflict Detection

Enforces ONE arc at a time — checks for existing state files from previous or concurrent sessions. Handles 6 cases (F1-F6) including hard blocks, resume prompts, and stale cleanup.

See [arc-state-conflict.md](references/arc-state-conflict.md) for the full conflict detection algorithm and case table.

## Phase Loop State File

**Co-located with checkpoint init (v2.6.0)**: The phase loop state file is now written as part of [arc-checkpoint-init.md](references/arc-checkpoint-init.md), immediately after the checkpoint `Write()` call. This eliminates the "missing state file" bug where the LLM wrote the checkpoint but skipped this step under context pressure.

If you are here during execution, the state file (`.rune/arc-phase-loop.local.md`) should already exist. If it does not, the safety guard in "First Phase Invocation" below will catch and recover.

See [arc-phase-loop-state.md](references/arc-phase-loop-state.md) for the state file schema reference.

## Discipline Integration

Integrates at 3 points: **Phase 5** (work loop with AC criteria), **Phase 8.5** (SCR/proof metrics), **Post-Arc** (echo persist). Config: `discipline.enabled` (default: true), `discipline.block_on_fail` (default: false). See `strive/references/discipline-work-loop.md` and `discipline/references/metrics-schema.md`.

## QA Discipline Protocol

Independent QA gates enforce quality obligations at every gated phase. The Tarnished (orchestrator) and all phase agents MUST adhere to these 6 obligations:

1. **No self-evaluation**: The Tarnished MUST NOT evaluate its own phase output. QA agents are spawned as independent teammates with read-only access to phase artifacts. QA verdicts cannot be overridden programmatically.

2. **Verdict file contract**: Every QA gate MUST produce a verdict JSON file at `tmp/arc/{id}/qa/{phase}-verdict.json` before the stop hook advances. Missing verdict files default to FAIL with `timed_out: true`.

3. **GUARD 9 retry budget**: QA retries are capped at `MAX_QA_RETRIES` (2), which MUST remain strictly less than `MAX_PHASE_DISPATCHES - 1` (currently 3). Exceeding this invariant triggers GUARD 9 destruction of the state file. Do NOT increase `MAX_QA_RETRIES` without first raising `MAX_PHASE_DISPATCHES` in the stop hook.

4. **Score transparency**: All QA scores (artifact, quality, completeness, overall) are persisted in verdict files and surfaced in the QA Dashboard (`tmp/arc/{id}/qa/dashboard.md`). No phase may suppress or alter QA scores after they are written.

5. **Human escalation**: When QA fails after max retries, the pipeline MUST escalate to the human via `AskUserQuestion` — never silently skip or auto-pass a failed gate.

6. **Dashboard generation**: After the last QA-gated phase completes, `generateQADashboard(arcId)` MUST be called to produce the consolidated pipeline quality summary. The dashboard is injected into the PR body (Phase 9) for reviewer visibility.

See [arc-phase-qa-gate.md](references/arc-phase-qa-gate.md) for the full QA gate architecture, scoring system, and per-phase checklists.

## First Phase Invocation

Execute the first pending phase from the checkpoint. The Stop hook (`arc-phase-stop-hook.sh`) handles all subsequent phases automatically.

**CRITICAL — Single-Phase-Per-Turn Rule**: You MUST execute exactly ONE phase per turn, then STOP responding. Do NOT batch-process multiple phases in a single turn. Do NOT skip conditional phases (semantic_verification, design_extraction, design_prototype, task_decomposition) based on assumptions — each phase has its own gate logic in its reference file that MUST be executed. The Stop hook advances to the next phase automatically. Violating this rule causes phases to be skipped without proper gate evaluation.

```javascript
// ── SAFETY GUARD: Verify phase loop state file exists before first phase ──
// FIX (v2.6.0): Catches the case where checkpoint init completed but state file
// write was skipped (context pressure, LLM shortcutting, or error between steps).
// Without this file, the Stop hook silently exits 0 and the arc stalls after Phase 1.
const stateFilePath = '.rune/arc-phase-loop.local.md'
const stateFileExists = Bash(`test -f "${stateFilePath}" && echo "ok" || echo "missing"`).trim()
if (stateFileExists !== 'ok') {
  warn('RECOVERY: Phase loop state file missing — recreating from checkpoint.')
  // Reconstruct from checkpoint data (checkpoint was written successfully)
  const cp = JSON.parse(Read(checkpointPath))
  const recoverySessionId = "${CLAUDE_SESSION_ID}" || Bash('echo "${RUNE_SESSION_ID:-}"').trim() || 'unknown'
  const recoveryBranch = Bash("git branch --show-current 2>/dev/null").trim() || 'main'
  const recoveryContent = `---
active: true
iteration: 0
max_iterations: 65
checkpoint_path: ${checkpointPath}
plan_file: ${cp.plan_file}
branch: ${recoveryBranch}
arc_flags: ${(cp.flags?.no_forge ? '--no-forge ' : '') + (cp.flags?.approve ? '--approve ' : '') + (cp.flags?.no_test ? '--no-test ' : '')}
config_dir: ${cp.config_dir}
owner_pid: ${Bash('echo $PPID').trim()}
session_id: ${recoverySessionId}
compact_pending: false
user_cancelled: false
cancel_reason: null
cancelled_at: null
stop_reason: null
---
`
  Write(stateFilePath, recoveryContent)
  log('Phase loop state file recovered successfully.')
}

// Check for context-critical shutdown signal before starting next phase (Layer 1)
const shutdownSignalCheck = (() => {
  try {
    const sid = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
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
const phaseDuration = completionTs - phaseStartMs
checkpoint.totals.phase_times[firstPending] = Number.isFinite(phaseDuration) && phaseDuration >= 0
  ? phaseDuration : null
// Then STOP responding — the Stop hook will advance to the next phase.
```

**Phase-to-reference mapping**: See `arc-phase-stop-hook.sh` `_phase_ref()` function for the canonical phase → reference file mapping.

**Timing instrumentation**: Each phase MUST stamp `started_at` before execution and `completed_at` + `totals.phase_times[phaseName]` (duration in ms) after. The Stop hook re-injects this same pattern for all subsequent phases via the phase prompt template. The `totals.phase_times` map accumulates durations across the full pipeline.

## Spec Continuity (Plan Path Propagation)

The `plan_file` path written to the phase loop state file and checkpoint is propagated to downstream phases that need the original plan specification as their source-of-truth. Each phase reference file reads `plan_file` from the checkpoint before spawning agents.

| Phase | Checkpoint Key | Purpose |
|-------|---------------|---------|
| `plan_review` (Phase 2) | `plan_file_path` → review agents | Reviewers read plan to evaluate scope and detect drift |
| `gap_analysis` (Phase 5.5) | `plan_file_path` → gap agents | Gap agents compare plan acceptance criteria vs. committed code |
| `test` (Phase 7.7) | `plan_file_path` → test agents | Test agents derive coverage targets from plan requirements |
| `pre_ship_validation` (Phase 8.5) | `plan_file_path` → validation gate | Pre-ship gate reads plan to verify all stated criteria are met before PR |

**Rule**: Phases that consume `plan_file_path` MUST read it from `checkpoint.plan_file` (not from the state file or flags). Workers receive it as `planFilePath` in their context prompt so they can cross-reference the original spec, even when the pipeline spans multiple sessions via `--resume`.

## Post-Arc (Final Phase)

**MANDATORY**: These steps run after Phase 9.5 MERGE (the last phase). The Stop hook injects a completion prompt when all phases are done. You MUST read and execute `arc-phase-completion-stamp.md` and `post-arc.md` — do NOT skip them or just present a summary. The plan file update is the primary deliverable of this phase.

### Timing Totals + Completion Stamp (schema v19)

Before calling the Plan Completion Stamp, record arc-level timing metrics:

```javascript
// Schema v19: record arc completion time and total duration
const completedAtTs = new Date().toISOString()
checkpoint.completed_at = completedAtTs
checkpoint.totals = checkpoint.totals ?? { phase_times: {}, total_duration_ms: null, cost_at_completion: null }
const totalDuration = Date.now() - new Date(checkpoint.started_at).getTime()
if (!Number.isFinite(totalDuration) || totalDuration < 0) {
  warn(`Arc timing anomaly: computed duration ${totalDuration}ms — setting to null`)
  checkpoint.totals.total_duration_ms = null
} else {
  checkpoint.totals.total_duration_ms = totalDuration
}

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

**Discipline accountability echo**: When `discipline.enabled: true` and convergence metrics exist in the arc checkpoint, write a pipeline-level discipline echo to `.rune/echoes/discipline/MEMORY.md` with aggregate SCR, first-pass rate, failure code distribution, and trend detection vs historical averages. See [discipline/references/accountability-protocol.md](../discipline/references/accountability-protocol.md) for the full echo format and trend detection algorithm.

### Proof Manifest Persistence (Discipline Integration, v1.173.0)

Persists the proof manifest (SCR + DSR per criterion) as a PR comment after ship/merge. Includes code compliance and design compliance (when `design_sync.enabled`). Uses `--body-file` for injection-safe PR comments.

See [arc-proof-manifest.md](references/arc-proof-manifest.md) for the full manifest schema and persistence logic.

### Lock Release

```javascript
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_all_locks`)
```

### Final Sweep (ARC-9) + Response Completion

See [post-arc.md](references/post-arc.md). 30-second budget. After sweep, **finish your response immediately** — IGNORE zombie teammate messages (Stop hook handles cleanup).

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
- [Storybook Verification](references/arc-phase-storybook-verification.md) — Phase 3.3 (conditional: `storybook.enabled`)
- [Design Verification](references/arc-phase-design-verification.md) — Phase 5.2 (conditional)
- [State Conflict Detection](references/arc-state-conflict.md) — Pre-flight F1-F6 conflict cases
- [Phase Loop State](references/arc-phase-loop-state.md) — State file template for Stop hook driver
- [Proof Manifest](references/arc-proof-manifest.md) — Discipline proof manifest persistence (v1.173.0)
