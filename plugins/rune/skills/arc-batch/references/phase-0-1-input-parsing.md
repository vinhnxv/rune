# Phase 0: Parse Arguments + Phase 1: Pre-flight Validation

## Phase 0: Parse Arguments

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
// See [batch-shard-parsing.md](batch-shard-parsing.md) for full algorithm.
// Outputs: reordered planPaths, shardGroups Map (used in Phase 3 progress file)
Read("references/batch-shard-parsing.md")
// Execute the shard detection algorithm. Sets planPaths and shardGroups.
```

## Phase 1: Pre-flight Validation

```javascript
// SEC-007 FIX: Write paths to temp file first to avoid shell injection via echo interpolation.
// Queue file paths (untrusted input) could contain shell metacharacters.
Write("tmp/arc-batch/preflight-input.txt", planPaths.join('\n'))
const validated = Bash(`"${CLAUDE_PLUGIN_ROOT}/scripts/arc-batch-preflight.sh" < "tmp/arc-batch/preflight-input.txt"`)
if (validated.exitCode !== 0) {
  error("Pre-flight validation failed. Fix errors above and retry.")
  return
}
planPaths = validated.trim().split('\n')

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
