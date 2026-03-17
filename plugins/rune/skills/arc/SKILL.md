---
name: arc
description: |
  Use when running the full plan-to-merged-PR pipeline, when resuming an
  interrupted arc with --resume, or when any named phase fails (forge,
  plan-review, plan-refinement, verification, semantic-verification,
  design-extraction, design-prototype, design-verification, design-iteration, work,
  gap-analysis, codex-gap-analysis, gap-remediation, goldmask-verification,
  code-review, goldmask-correlation, mend, verify-mend, test,
  pre-ship-validation, bot-review-wait, pr-comment-resolution, ship, merge).
  Use when checkpoint resume is needed after a crash or session end.
  29-phase pipeline with convergence loops, Goldmask risk analysis,
  pre-ship validation, bot review integration, cross-model verification,
  and conditional design sync (Figma VSM extraction, prototype generation, fidelity verification, iteration).
  Keywords: arc, pipeline, --resume, checkpoint, convergence, forge, mend,
  bot review, PR comments, ship, merge, design sync, Figma, VSM, 29 phases.

  <example>
  user: "/rune:arc plans/feat-user-auth-plan.md"
  assistant: "The Tarnished begins the arc — 29 phases of forge, review, design sync, goldmask, test, mend, convergence, pre-ship validation, bot review, ship, and merge..."
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

Chains twenty-nine phases into a single automated pipeline. Each phase runs as its own Claude Code turn with fresh context — the `arc-phase-stop-hook.sh` drives phase iteration via the Stop hook pattern. Artifact-based handoff connects phases. Checkpoint state enables resume after failure.

**Context budget advisory**: Full arc run: 29 phases x ~3.5min avg = ~95 minutes (lower bound). Context compaction is almost guaranteed in a single session. For constrained sessions, use `--no-forge` to skip Phase 1 enrichment, or split into multiple `/rune:arc --resume` sessions. The `PreCompact` hook saves checkpoint state automatically.

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
| 3.2 | `design_prototype` | Team | 10 min | Conditional: `design_sync.enabled` + VSM files |
| 4.5 | `task_decomposition` | Team | 10 min | Codex (conditional) |
| 5 | `work` | Team | 35 min | `/rune:strive` |
| 5.1 | `drift_review` | Inline | 2 min | — |
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

## Pre-Flight: State File Conflict Detection

Before creating a new state file, check if one already exists from a previous or concurrent session. This enforces Rule 2 (ONE arc at a time) and prevents data corruption from concurrent arcs.

| Case | State File | Plan Match | Owner Alive | Session Match | Action |
|------|-----------|------------|-------------|--------------|--------|
| F1 | No | — | — | — | **Proceed**: create state file, start arc |
| F2 | Yes | Same | Yes | Same | **BLOCKED**: already running in this session |
| F3 | Yes | Same | Yes | Different | **BLOCKED**: running in another session |
| F4 | Yes | Same | No | — | **Prompt**: resume or fresh start? |
| F5 | Yes | Different | Yes | — | **BLOCKED**: different plan is running |
| F6 | Yes | Different | No | — | **Prompt**: clean up stale state? |

> **F2, F3, F5 are hard blocks** — no "proceed anyway" option. The user MUST cancel the existing arc first via `/rune:cancel-arc`.

```javascript
// ── Pre-flight: State file conflict detection (runs BEFORE state file creation) ──
const stateFile = ".claude/arc-phase-loop.local.md"
const stateExists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim() === "yes"

if (stateExists) {
  const stateContent = Read(stateFile)
  const statePlanFile = extractYamlField(stateContent, "plan_file")
  const stateOwnerPid = extractYamlField(stateContent, "owner_pid")
  const stateSessionId = extractYamlField(stateContent, "session_id")
  const stateActive = extractYamlField(stateContent, "active")

  // Inactive state file → clean up silently and proceed
  if (stateActive !== "true") {
    Bash(`rm -f "${stateFile}"`)
    // F1 equivalent: proceed to create new state file
  } else {
    // Check owner PID liveness (cross-platform: works on macOS + Linux)
    const pidAlive = stateOwnerPid
      ? Bash(`kill -0 ${stateOwnerPid} 2>/dev/null && echo yes || echo no`).trim() === "yes"
      : false
    const samePlan = (statePlanFile === planFile)
    const sameSession = (stateSessionId === "${CLAUDE_SESSION_ID}")

    if (samePlan && pidAlive && sameSession) {
      // F2: Already running in this session
      throw new Error(
        "Arc already running for this plan in this session. " +
        "Run `/rune:cancel-arc` to stop it first."
      )
    }
    if (samePlan && pidAlive && !sameSession) {
      // F3: Running in another live session
      throw new Error(
        `Arc running for this plan in another session (PID ${stateOwnerPid}). ` +
        "Only that session or `/rune:cancel-arc` can stop it."
      )
    }
    if (samePlan && !pidAlive) {
      // F4: Same plan, owner dead → ask user
      const choice = AskUserQuestion({
        question:
          "Found interrupted arc for the same plan (owner session is dead).\n" +
          "- **Resume**: continue from where it stopped\n" +
          "- **Fresh**: delete stale state and start from scratch\n\n" +
          "Choose: resume / fresh"
      })
      if (choice.toLowerCase().includes("resume")) {
        // Switch to --resume flow
        args = args.replace(planFile, "--resume")
        Read("references/arc-resume.md")
        // Execute resume algorithm and return — do not create new state file
        return
      } else {
        // Clean up stale state file + checkpoint, then proceed
        Bash(`rm -f "${stateFile}"`)
      }
    }
    if (!samePlan && pidAlive) {
      // F5: Different plan, still running
      throw new Error(
        `Another arc is running a different plan (${statePlanFile}). ` +
        "Only one arc can run at a time. Cancel it first with `/rune:cancel-arc`."
      )
    }
    if (!samePlan && !pidAlive) {
      // F6: Different plan, owner dead → ask user
      const choice = AskUserQuestion({
        question:
          `Found stale arc state for a different plan (${statePlanFile}, owner PID ${stateOwnerPid} is dead).\n` +
          "Clean up stale state and start fresh? (yes / no)"
      })
      if (choice.toLowerCase().includes("yes")) {
        Bash(`rm -f "${stateFile}"`)
        // Proceed to create new state file
      } else {
        throw new Error("Aborted by user. Clean up manually or run `/rune:cancel-arc`.")
      }
    }
  }
}
// F1: No state file exists → proceed normally to create one below
```

## Phase Loop State File

After checkpoint initialization (or resume), write the phase loop state file that drives `arc-phase-stop-hook.sh`:

```javascript
// Write the phase loop state file for the Stop hook driver.
// The Stop hook reads this file, finds the next pending phase in the checkpoint,
// and re-injects the phase-specific prompt with fresh context.
//
// CRITICAL: session_id MUST use SKILL.md substitution ("${CLAUDE_SESSION_ID}") as primary source.
// DO NOT use Bash('echo $CLAUDE_SESSION_ID') — it is NOT available in Bash tool context
// (anthropics/claude-code#25642). The SKILL.md preprocessor replaces ${CLAUDE_SESSION_ID}
// at skill load time, providing the real session ID without Bash.
const sessionId = "${CLAUDE_SESSION_ID}" || Bash('echo "${RUNE_SESSION_ID:-}"').trim() || 'unknown'
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
user_cancelled: false
cancel_reason: null
cancelled_at: null
stop_reason: null
---
`
Write('.claude/arc-phase-loop.local.md', stateContent)
```

## Discipline Integration

The arc pipeline integrates with the Discipline Work Loop at two points:

1. **Work Phase (Phase 5)**: When the plan has YAML acceptance criteria, `/rune:strive` activates the Discipline Work Loop (8-phase convergence cycle). Workers collect evidence per criterion. See `strive/references/discipline-work-loop.md`.

2. **Pre-Ship Validation (Phase 8.5)**: Computes discipline metrics (SCR, proof coverage) from evidence artifacts. SCR below threshold triggers WARN (advisory for initial rollout). See `discipline/references/metrics-schema.md`.

3. **Echo Persist (Post-Arc)**: Discipline failure patterns (silent skips, fabrication, escalation depth) are persisted to Rune Echoes with `discipline` metadata tag for cross-session learning.

**Talisman config**: `discipline.enabled` (default: true), `discipline.block_on_fail` (default: false — WARN mode for rollout).

## First Phase Invocation

Execute the first pending phase from the checkpoint. The Stop hook (`arc-phase-stop-hook.sh`) handles all subsequent phases automatically.

**CRITICAL — Single-Phase-Per-Turn Rule**: You MUST execute exactly ONE phase per turn, then STOP responding. Do NOT batch-process multiple phases in a single turn. Do NOT skip conditional phases (semantic_verification, design_extraction, design_prototype, task_decomposition) based on assumptions — each phase has its own gate logic in its reference file that MUST be executed. The Stop hook advances to the next phase automatically. Violating this rule causes phases to be skipped without proper gate evaluation.

```javascript
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
checkpoint.totals.phase_times[firstPending] = Number.isFinite(phaseStartMs) ? completionTs - phaseStartMs : null
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

**Discipline accountability echo**: When `discipline.enabled: true` and convergence metrics exist in the arc checkpoint, write a pipeline-level discipline echo to `.claude/echoes/discipline/MEMORY.md` with aggregate SCR, first-pass rate, failure code distribution, and trend detection vs historical averages. See [discipline/references/accountability-protocol.md](../discipline/references/accountability-protocol.md) for the full echo format and trend detection algorithm.

### Proof Manifest Persistence (Discipline Integration, v1.173.0)

After ship/merge, persist the proof manifest beyond `tmp/` lifecycle. The manifest is generated
at Phase 8.5 (pre-ship validation) and contains per-criterion PASS/FAIL/UNTESTED status,
SCR, failure codes, convergence iterations, and evidence file references.

```javascript
// Persist proof manifest as PR comment (survives in GitHub, searchable, linked to code)
const manifestPath = `tmp/arc/${id}/proof-manifest.json`
try {
  const manifest = JSON.parse(Read(manifestPath))
  const prUrl = checkpoint.pr_url
  if (prUrl && manifest) {
    const prNumber = prUrl.match(/\/pull\/(\d+)/)?.[1]
    if (prNumber) {
      const manifestComment = [
        '## Discipline Proof Manifest',
        '',
        `**Plan**: \`${manifest.plan_file}\``,
        `**Arc ID**: ${manifest.arc_id}`,
        `**SCR**: ${manifest.scr !== null ? (manifest.scr * 100).toFixed(1) + '%' : 'N/A'}`,
        `**Criteria**: ${manifest.criteria_count} total`,
        `**Convergence**: ${manifest.convergence_rounds} round(s)`,
        `**Verdict**: ${manifest.verdict}`,
        `**Timestamp**: ${manifest.timestamp}`,
      ].join('\n')
      // SEC-S8-004 FIX: Use --body-file instead of heredoc to prevent content injection
      const tmpManifestFile = Bash("mktemp").trim()
      Write(tmpManifestFile, manifestComment)
      Bash(`gh pr comment ${prNumber} --body-file "${tmpManifestFile}" && rm -f "${tmpManifestFile}"`)
    }
  }
} catch (e) {
  warn(`Proof manifest persistence failed: ${e.message} — non-blocking`)
}
```

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
