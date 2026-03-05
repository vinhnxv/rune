---
name: arc-batch
description: |
  Use when implementing multiple plan files overnight or in batch, when a
  previous batch crashed mid-run and --resume is needed, when tracking
  progress across multiple sequential arc runs, or when using a queue file
  (one plan path per line) instead of a glob. Use when crash recovery is
  needed for interrupted batch runs. Covers: Stop hook pattern, progress
  tracking via .claude/arc-batch-loop.local.md, --dry-run preview, --no-merge.
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
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Skill
argument-hint: "[plans/*.md | queue-file.txt] [--resume] [--dry-run] [--no-merge] [--no-shard-sort] [--no-smart-sort] [--smart-sort]"
---

# /rune:arc-batch — Sequential Batch Arc Execution

Executes `/rune:arc` across multiple plan files sequentially. Each arc run completes the full 27-phase pipeline (forge through merge) before the next plan starts.

**Core loop**: Stop hook pattern (ralph-wiggum). Each arc runs as a native Claude Code turn. Between arcs, the Stop hook intercepts session end, reads batch state from `.claude/arc-batch-loop.local.md`, determines the next plan, cleans git state, and re-injects the arc prompt.

## Usage

```
/rune:arc-batch plans/*.md                    # All plans matching glob
/rune:arc-batch batch-queue.txt               # Queue file (one plan path per line)
/rune:arc-batch plans/*.md --dry-run          # Preview queue without running
/rune:arc-batch plans/*.md --no-merge         # Skip auto-merge (individual PRs remain open)
/rune:arc-batch --resume                      # Resume interrupted batch from progress file
```

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--dry-run` | List plans and exit without running | Off |
| `--no-merge` | Pass `--no-merge` to each arc run | Off (auto-merge enabled) |
| `--resume` | Resume from `batch-progress.json` (pending plans only — failed/cancelled plans must be re-run individually) | Off |
| `--no-shard-sort` | Process plans in raw order (disable shard auto-sorting) | Off |
| `--no-smart-sort` | Disable smart plan ordering (preserve glob/queue order) | Off |
| `--smart-sort` | Force smart ordering even on queue file input | Off |

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

See [batch-algorithm.md](references/batch-algorithm.md) for full pseudocode. See [smart-ordering.md](references/smart-ordering.md) for the Tier 1 smart ordering algorithm.

## Inter-Iteration Summaries (v1.72.0)

Between arc iterations, the Stop hook writes a structured summary file capturing metadata from the just-completed arc. These summaries improve compact recovery context and provide a record of what each arc accomplished.

**Location**: `tmp/arc-batch/summaries/iteration-{N}.md` (flat path — no PID subdirectory; session isolation is handled by Guard 5.7 in the Stop hook).

**Contents**: Plan path, status, branch name, PR URL, git log (last 5 commits), and a `## Context Note` section where Claude adds a brief qualitative summary during the next turn.

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

```javascript
const args = "$ARGUMENTS".trim()
let planPaths = []
let inputType = "glob"  // "queue" | "glob" | "resume"
let resumeMode = args.includes('--resume')
let dryRun = args.includes('--dry-run')
let noMerge = args.includes('--no-merge')
let noSmartSort = args.includes('--no-smart-sort')
// Token-based parsing: prevents substring match collision with --no-smart-sort
let forceSmartSort = args.split(/\s+/).includes('--smart-sort')

// Conflicting flags: --no-smart-sort wins (fail-safe)
if (forceSmartSort && noSmartSort) {
  warn("Conflicting flags: --smart-sort and --no-smart-sort both present. Using --no-smart-sort.")
  log("Conflicting flags detected: --smart-sort and --no-smart-sort. Using --no-smart-sort.")
  forceSmartSort = false
}

if (resumeMode) {
  inputType = "resume"
  const progress = JSON.parse(Read("tmp/arc-batch/batch-progress.json"))
  const allPlans = progress.plans

  // Bug 4 FIX (v1.110.0): Reset in_progress plans from crashed sessions to pending.
  // A plan stuck in "in_progress" means the previous session died mid-execution.
  const staleInProgress = allPlans.filter(p => p.status === "in_progress")
  if (staleInProgress.length > 0) {
    warn(`Found ${staleInProgress.length} in_progress plan(s) from crashed session — resetting to pending`)
    for (const plan of staleInProgress) {
      plan.status = "pending"
      plan.recovery_note = "reset_from_in_progress_on_resume"
    }
    progress.updated_at = new Date().toISOString()
    Write("tmp/arc-batch/batch-progress.json", JSON.stringify(progress, null, 2))
  }

  // P1-FIX: Filter to pending plans only — don't re-execute completed plans
  const pendingPlans = allPlans.filter(p => p.status === "pending")
  planPaths = pendingPlans.map(p => p.path)
  log(`Resuming batch: ${allPlans.filter(p => p.status === "completed").length}/${allPlans.length} completed, ${planPaths.length} remaining`)
  if (planPaths.length === 0) {
    log("All plans already completed. Nothing to resume.")
    return
  }
} else {
  const inputArg = args.replace(/--\S+/g, '').trim()
  if (inputArg.endsWith('.txt')) {
    inputType = "queue"
    planPaths = Read(inputArg).split('\n').filter(l => l.trim() && !l.startsWith('#'))
  } else {
    inputType = "glob"
    planPaths = Glob(inputArg)
  }
}

if (planPaths.length === 0) {
  error("No plan files found. Usage: /rune:arc-batch plans/*.md")
  return
}

// ── SHARD GROUP DETECTION (v1.66.0+) ──
// Separates shard plans from regular, groups by feature prefix, sorts by shard number,
// detects gaps, auto-excludes parent plans (shattered: true).
// See [batch-shard-parsing.md](references/batch-shard-parsing.md) for full algorithm.
// Outputs: reordered planPaths, shardGroups Map (used in Phase 3 progress file)
Read("references/batch-shard-parsing.md")
// Execute the shard detection algorithm. Sets planPaths and shardGroups.
```

### Phase 1: Pre-flight Validation

```javascript
// SEC-007 FIX: Write paths to temp file first to avoid shell injection via echo interpolation.
// Queue file paths (untrusted input) could contain shell metacharacters.
Write("tmp/arc-batch/preflight-input.txt", planPaths.join('\n'))
const validated = Bash(`"${CLAUDE_PLUGIN_ROOT}/scripts/arc-batch-preflight.sh" < "tmp/arc-batch/preflight-input.txt"`)
if (validated.exitCode !== 0) {
  error("Pre-flight validation failed. Fix errors above and retry.")
  return
}
planPaths = validated.stdout.trim().split('\n')

// Check auto-merge setting (unless --no-merge)
if (!noMerge) {
  // readTalismanSection: "arc"
  const arc = readTalismanSection("arc")
  if (arc?.ship?.auto_merge === false) {
    warn("talisman.yml has arc.ship.auto_merge: false")
    AskUserQuestion({
      questions: [{
        question: "Auto-merge is disabled in talisman.yml. How to proceed?",
        header: "Merge",
        options: [
          { label: "Enable auto-merge for this batch", description: "Temporarily set auto_merge: true" },
          { label: "Run with --no-merge", description: "PRs created but not merged" },
          { label: "Abort", description: "Fix talisman config first" }
        ],
        multiSelect: false
      }]
    })
  }
}
```

### Phase 1.5: Plan Ordering (Opt-In Smart Ordering)

Input-type-aware ordering with 3 modes. Queue files respect user order by default. Glob inputs present ordering options. CLI flags override all modes.

See [smart-ordering.md](references/smart-ordering.md) for the full algorithm when smart ordering is selected.

```javascript
// ── Phase 1.5: Plan Ordering (opt-in smart ordering) ──
// Decision tree: CLI flags > resume guard > talisman mode > input-type heuristic

// readTalismanSection: "arc"
const arcConfig = readTalismanSection("arc")
const smartOrderingConfig = arcConfig?.batch?.smart_ordering || {}
const smartOrderingEnabled = smartOrderingConfig.enabled !== false  // default: true
const smartOrderingMode = smartOrderingConfig.mode || "off"        // "ask" | "auto" | "off" — default "off" ensures smart ordering is truly opt-in

// Validate mode (single check)
const validModes = ["ask", "auto", "off"]
const modeIsValid = validModes.includes(smartOrderingMode)
if (!modeIsValid) {
  warn(`Unknown smart_ordering.mode: '${smartOrderingMode}', defaulting to 'off'.`)
}
const effectiveMode = modeIsValid ? smartOrderingMode : "off"

// ── Priority 1: CLI flags (always win) ──
if (noSmartSort) {
  log("Plan ordering: --no-smart-sort flag — preserving raw order")
} else if (forceSmartSort && planPaths.length === 1) {
  warn("--smart-sort flag ignored: only 1 plan file, no ordering needed")
} else if (forceSmartSort && planPaths.length > 1) {
  log("Plan ordering: --smart-sort flag — applying smart ordering")
  Read("references/smart-ordering.md")
  // Execute smart ordering algorithm
}
// ── Priority 1.5: Resume guard (before talisman — prevents reordering partial batches) ──
else if (resumeMode) {
  log("Plan ordering: resume mode — preserving batch order")
}
// ── Priority 2: Kill switch ──
else if (!smartOrderingEnabled) {
  log("Plan ordering: disabled by talisman (arc.batch.smart_ordering.enabled: false)")
}
// ── Priority 3: Talisman mode ──
else if (effectiveMode === "off") {
  log("Plan ordering: talisman mode='off' — preserving raw order")
} else if (effectiveMode === "auto" && planPaths.length > 1) {
  log("Plan ordering: talisman mode='auto' — auto-applying smart ordering")
  Read("references/smart-ordering.md")
  // Execute smart ordering algorithm
}
// ── Priority 4: Input-type heuristic (mode="ask" or default) ──
else if (inputType === "resume") {
  // skip — resume mode already handled above (Priority 1.5 resume guard)
} else if (inputType === "queue") {
  log("Plan ordering: queue file detected — respecting user-specified order")
} else if (inputType === "glob" && planPaths.length > 1) {
  // Present ordering options to user
  const answer = AskUserQuestion({
    questions: [{
      question: `How should the ${planPaths.length} plans be ordered for execution?`,
      header: "Order",
      options: [
        {
          label: "Smart ordering (Recommended)",
          description: "Dependency-aware: isolated plans first, then by version target. Reduces merge conflicts."
        },
        {
          label: "Alphabetical",
          description: "Sort by filename A→Z. Deterministic and predictable."
        },
        {
          label: "As discovered",
          description: "Keep the default glob expansion order."
        }
      ],
      multiSelect: false
    }]
  })

  if (answer === "Smart ordering (Recommended)") {
    Read("references/smart-ordering.md")
    // Execute smart ordering algorithm
  } else if (answer === "Alphabetical") {
    planPaths.sort((a, b) => a.localeCompare(b))
    log(`Plan ordering: alphabetical — ${planPaths.length} plans sorted A→Z`)
  } else if (answer === "As discovered") {
    log("Plan ordering: discovery order — preserving glob expansion order")
  } else {
    warn(`Plan ordering: unrecognized answer '${answer}', using discovery order`)
    log("Plan ordering: discovery order — preserving glob expansion order")
  }
} else {
  warn("Plan ordering: no applicable rule matched, preserving order")
}
// Single plan or no action needed
```

### Phase 2: Dry Run

```javascript
if (dryRun) {
  log("Dry run — plans that would be processed:")
  for (const [i, plan] of planPaths.entries()) {
    log(`  ${i + 1}. ${plan}`)
  }
  log(`\nTotal: ${planPaths.length} plans`)
  log(`Estimated time: ${planPaths.length * 45}-${planPaths.length * 240} minutes`)
  return
}
```

### Phase 3: Initialize Progress File

```javascript
const progressFile = "tmp/arc-batch/batch-progress.json"
if (!resumeMode) {
  Bash("mkdir -p tmp/arc-batch")
  Write(progressFile, JSON.stringify({
    schema_version: 2,  // v2: shard metadata (v1.66.0+)
    status: "running",
    started_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    total_plans: planPaths.length,
    // NEW (v1.66.0): shard group summary for progress display
    shard_groups: (shardGroups.size > 0)  // F-004: outer-scope Map, always defined
      ? Array.from(shardGroups.entries()).map(([prefix, shards]) => ({
          feature: prefix.replace(/.*\//, ''),  // basename of prefix
          shards: shards.map(s => s.shardNum),
          total: shards.length
        }))
      : [],
    plans: planPaths.map(p => {
      const shardMatch = p.match(/-shard-(\d+)-/)
      return {
        path: p,
        status: "pending",
        error: null,
        completed_at: null,
        arc_session_id: null,
        // NEW (v1.66.0): shard metadata (null for non-shard plans)
        shard_group: shardMatch ? p.replace(/-shard-\d+-[^/]*$/, '').replace(/.*\//, '') : null,
        shard_num: shardMatch ? parseInt(shardMatch[1]) : null
      }
    })
  }, null, 2))
}
```

### Phase 4: Confirm Batch

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

Write state file, resolve session identity, check for existing batch, mark first plan as in_progress, and invoke `/rune:arc`. The Stop hook handles all subsequent plans and the final summary.

See [batch-loop-init.md](references/batch-loop-init.md) for the full algorithm.

```javascript
Read("references/batch-loop-init.md")
// Execute: resolve session identity → pre-creation guard → write state file →
// mark first plan in_progress → Skill("arc", firstPlan + flags)
```
