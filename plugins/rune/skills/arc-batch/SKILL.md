---
name: arc-batch
description: |
  Use when implementing multiple plan files overnight or in batch, when a
  previous batch crashed mid-run and --resume is needed, when tracking
  progress across multiple sequential arc runs, or when using a queue file
  (one plan path per line) instead of a glob. Use when crash recovery is
  needed for interrupted batch runs. Covers: Stop hook pattern, progress
  tracking via .rune/arc-batch-loop.local.md, --dry-run preview, --no-merge.
  Keywords: arc-batch, batch, queue file, overnight, --resume, crash recovery,
  progress tracking, sequential plans.

  <example>
  Context: User has multiple plans to implement
  user: "/rune:arc-batch plans/*.md"
  assistant: "The Tarnished begins the batch arc pipeline..."
  </example>

  <example>
  Context: User has a queue file
  user: "/rune:arc-batch batch-queue.txt"
  assistant: "Reading plan queue from batch-queue.txt..."
  </example>
user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Skill
argument-hint: "[plans/*.md | queue-file.txt] [--resume] [--dry-run] [--no-merge] [--no-shard-sort] [--no-smart-sort] [--smart-sort] [--no-forge] [--no-test] [--draft] [--bot-review] [--no-bot-review] [--no-pr]"
---

# /rune:arc-batch — Sequential Batch Arc Execution

Executes `/rune:arc` across multiple plan files sequentially. Each arc run completes the full 40-phase pipeline (forge through merge) before the next plan starts.

**Core loop**: Stop hook pattern (ralph-wiggum). Each arc runs as a native Claude Code turn. Between arcs, the Stop hook intercepts session end, reads batch state from `.rune/arc-batch-loop.local.md`, determines the next plan, cleans git state, and re-injects the arc prompt.

## Usage

```
/rune:arc-batch plans/*.md                    # All plans matching glob
/rune:arc-batch batch-queue.txt               # Queue file (one plan path per line)
/rune:arc-batch plans/*.md --dry-run          # Preview queue without running
/rune:arc-batch plans/*.md --no-merge         # Skip auto-merge (individual PRs remain open)
/rune:arc-batch --resume                      # Resume interrupted batch from progress file
/rune:arc-batch plans/*.md --no-forge         # Skip forge phase on each arc run
/rune:arc-batch plans/*.md --no-test          # Skip test phase on each arc run
/rune:arc-batch plans/*.md --draft --no-pr    # Forward multiple flags to each arc run
```

> **Single-Plan Batches**: Running with a single plan file works correctly — it runs as a normal arc with minimal batch infrastructure overhead. The Stop hook fires after completion, finds no more pending plans, and cleans up. For simple single-plan cases, consider using `/rune:arc` directly to skip batch tracking.

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--dry-run` | List plans and exit without running | Off |
| `--no-merge` | Pass `--no-merge` to each arc run | Off (auto-merge enabled) |
| `--resume` | Resume from `batch-progress.json` (pending plans only — failed/cancelled plans must be re-run individually) | Off |
| `--no-shard-sort` | Process plans in raw order (disable shard auto-sorting) | Off |
| `--no-smart-sort` | Disable smart plan ordering (preserve glob/queue order) | Off |
| `--smart-sort` | Force smart ordering even on queue file input | Off |
| `--no-forge` | Pass `--no-forge` to each arc run (skip forge phase) | Off |
| `--no-test` | Pass `--no-test` to each arc run (skip test phase) | Off |
| `--draft` | Pass `--draft` to each arc run (open PRs as draft) | Off |
| `--bot-review` | Pass `--bot-review` to each arc run | Off |
| `--no-bot-review` | Pass `--no-bot-review` to each arc run | Off |
| `--no-pr` | Pass `--no-pr` to each arc run (skip PR creation) | Off |

> **Note**: `--smart-sort` is a positive override flag — unlike the `--no-*` disable family. Use it to force smart ordering on input types that would otherwise preserve order (e.g., queue files). When both `--smart-sort` and `--no-smart-sort` are present, `--no-smart-sort` takes precedence (fail-safe).

### Flag Coexistence

| `--smart-sort` | `--no-smart-sort` | `--no-shard-sort` | Result |
|----------------|-------------------|-------------------|--------|
| false | false | false | Input-type detection + shard grouping (default) |
| false | true | false | Raw order, shard grouping still active |
| true | false | false | Force smart ordering + shard grouping |
| true | true | false | Conflicting — `--no-smart-sort` wins (warn user) |
| false | false | true | Input-type detection, no shard grouping |
| true | false | true | Force smart ordering, no shard grouping |
| false | true | true | Raw glob/queue order preserved |
| true | true | true | Conflicting — `--no-smart-sort` wins (warn user) |

## Algorithm

See [batch-algorithm.md](references/batch-algorithm.md) for full pseudocode. See [smart-ordering.md](references/smart-ordering.md) for the Tier 1 smart ordering algorithm. Read this SKILL.md for full documentation on all phases, flags, and edge cases.

## Inter-Iteration Summaries (v1.72.0)

Between arc iterations, the Stop hook writes a structured summary file capturing metadata from the just-completed arc. These summaries improve compact recovery context and provide a record of what each arc accomplished.

**Location**: `tmp/arc-batch/summaries/iteration-{N}.md` (flat path — no PID subdirectory; session isolation is handled by Guard 5.7 in the Stop hook).

**Contents**: Plan path, status, branch name, PR URL, git log (last 5 commits), and a `## Context Note` section where Claude adds a brief qualitative summary during the next turn that captures insights and learnings from the completed arc.

**Behavior**:
- Summaries are written BEFORE marking the plan as completed (crash-safe ordering)
- Write failures are non-blocking — the batch continues without a summary
- ARC_PROMPT step 4.5 is conditional: only injected when a summary was successfully written
- `arc.batch.summaries.enabled: false` in talisman.yml disables all summary behavior
- Git log content is capped to last 5 commits (not talisman-configurable)

**Compact recovery**: The `pre-compact-checkpoint.sh` hook captures `arc_batch_state` (current iteration, total plans, latest summary path) in the compact checkpoint. On recovery, the session-compact-recovery hook includes batch iteration context in the injected message.

## Known Limitations (V2 — Stop Hook Pattern)

1. **Sequential only**: No parallel arc execution (SDK one-team-per-session constraint).
2. **No version bump coordination**: Multiple arcs bumping plugin.json will conflict. Smart ordering (Phase 1.5) mitigates this by sorting plans by `version_target`, but cannot resolve conflicting bumps to the same version.
3. **Shard ordering is sequential**: Shards are auto-sorted by number within groups but execute sequentially (no parallel shards). Use `--no-shard-sort` to disable auto-sorting.
4. **Context growth**: Each arc runs as a native turn. Auto-compaction handles context window growth across multiple arcs. State is tracked in files, not context.
5. **Compact recovery during arc-batch**: Teams are created/destroyed per phase. Compaction may hit when no team is active. Summary files persist independently — the compact checkpoint captures batch state even without an active team (C6 accepted limitation).

## Orchestration

The skill orchestrates via `$ARGUMENTS` parsing. Phase 5 writes a state file and invokes the first arc natively. The Stop hook (`scripts/arc-batch-stop-hook.sh`) handles all subsequent plans via self-invoking loop:

```
Phase 0: Parse arguments (glob expand or queue file read)
Phase 1: Pre-flight validation (arc-batch-preflight.sh)
Phase 1.5: Plan ordering (input-type-aware: queue→skip, glob→ask, --smart-sort→force)
Phase 2: Dry run (if --dry-run)
Phase 3: Initialize batch-progress.json
Phase 4: Confirm batch with user
Phase 5: Write state file + invoke first arc (Stop hook handles rest)
(Stop hook handles all subsequent plans + final summary)
```

### Workflow Lock (writer)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "writer"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "arc-batch" "writer"`)
```

### Phase 0: Parse Arguments

Parse `$ARGUMENTS` into `planPaths`, `inputType`, flag booleans, and passthrough flags. Handles 3 input types: glob, queue file (`.txt`), and `--resume` (reads `batch-progress.json`, resets stale `in_progress` plans). Queue files preserve user order by default — plans are processed in the exact order listed. Includes shard group detection (v1.66.0+).

Extract passthrough flags for forwarding to each child arc invocation:

```javascript
// Extract passthrough flags from $ARGUMENTS
const ARC_BATCH_ALLOWED_FLAGS = ['--no-forge', '--no-test', '--draft', '--bot-review', '--no-bot-review', '--no-pr']
const arcPassthroughFlags = ARC_BATCH_ALLOWED_FLAGS.filter(f => args.includes(f))
// arcPassthroughFlags is an array of validated flags (e.g., ['--no-forge', '--draft'])
// Stored as a space-joined string in the state file: "--no-forge --draft"
```

See [phase-0-1-input-parsing.md](references/phase-0-1-input-parsing.md) for full pseudocode.

### Phase 1: Pre-flight Validation

Runs `arc-batch-preflight.sh` via temp file (SEC-007: avoids shell injection from untrusted queue paths). Validates plan paths exist, are not symlinks, pass character allowlist, and checks `arc.ship.auto_merge` talisman setting when `--no-merge` is not set.

See [phase-0-1-input-parsing.md](references/phase-0-1-input-parsing.md) for full pseudocode.

### Phase 1.5: Plan Ordering (Opt-In Smart Ordering)

Input-type-aware ordering with 3 modes. Decision tree: CLI flags > resume guard > talisman mode > input-type heuristic. Queue files respect user order by default. Glob inputs present ordering options (Smart/Alphabetical/As discovered). Talisman modes: `ask` | `auto` | `off` (default).

See [phase-1.5-plan-ordering.md](references/phase-1.5-plan-ordering.md) for full pseudocode. See [smart-ordering.md](references/smart-ordering.md) for the smart ordering algorithm.

### Phase 2: Dry Run

```javascript
if (dryRun) {
  log("Dry run — plans that would be processed:")
  for (const [i, plan] of planPaths.entries()) {
    log(`  ${i + 1}. ${plan}`)
  }
  log(`\nTotal: ${planPaths.length} plans`)
  log(`Estimated time: ${planPaths.length * 45}-${planPaths.length * 240} minutes`)
  if (arcPassthroughFlags.length > 0) {
    log(`Forwarded flags: ${arcPassthroughFlags.join(' ')}`)
  }
  return
}
```

### Phase 3: Initialize Progress File

Writes `tmp/arc-batch/batch-progress.json` (schema v2) with plan statuses, shard group metadata (v1.66.0+), and timestamps. Skipped in `--resume` mode.

See [phase-3-progress-init.md](references/phase-3-progress-init.md) for full pseudocode.

### Phase 4: Confirm Batch

Shows plan count and time estimate before execution. The dialog presents three options:

```javascript
AskUserQuestion({
  questions: [{
    question: `Start batch arc for ${planPaths.length} plans? Estimated ${planPaths.length * 45}-${planPaths.length * 240} minutes.`,
    header: "Confirm",
    options: [
      { label: "Start batch", description: `Process ${planPaths.length} plans sequentially with auto-merge` },
      { label: "Dry run first", description: "Preview the queue and estimates" },
      { label: "Cancel", description: "Abort batch" }
    ],
    multiSelect: false
  }]
})
```

### Phase 5: Start Batch Loop (Stop Hook Pattern)

Write state file (including `arc_passthrough_flags`), resolve session identity, check for existing batch, mark first plan as in_progress, and invoke `/rune:arc`. The Stop hook handles all subsequent plans and the final summary.

See [batch-loop-init.md](references/batch-loop-init.md) for the full algorithm.

```javascript
Read("references/batch-loop-init.md")
// Execute: resolve session identity → pre-creation guard → write state file →
// mark first plan in_progress → Skill("rune:arc", firstPlan + flags)
```
