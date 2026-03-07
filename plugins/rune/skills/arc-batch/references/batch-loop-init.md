# Batch Loop Initialization (Phase 5)

Write the Stop hook state file, resolve session identity, mark the first plan as in_progress,
and invoke `/rune:arc` for the first plan. The Stop hook handles all subsequent plans.
Extracted from SKILL.md Phase 5 in v1.110.0 for context reduction.

**Consumers**: SKILL.md Phase 5 (Start Batch Loop)
**Inputs**: `planPaths` (array), `progressFile` (string), `autoMerge` (boolean), `summaryEnabled` (boolean)
**Outputs**: `.claude/arc-batch-loop.local.md` (state file), first arc invocation

## Algorithm

```javascript
const pluginDir = Bash(`echo "${CLAUDE_PLUGIN_ROOT}"`).trim()
const planListFile = "tmp/arc-batch/plan-list.txt"
Write(planListFile, planPaths.join('\n'))

// readTalismanSection: "arc"
const arc = readTalismanSection("arc")
const batchConfig = arc?.batch || {}
const autoMerge = noMerge ? false : (batchConfig.auto_merge ?? true)
const summaryEnabled = batchConfig?.summaries?.enabled !== false  // default: true

// ── Resolve session identity for cross-session isolation ──
// Two isolation layers prevent cross-session interference:
//   Layer 1: config_dir — isolates different Claude Code installations
//   Layer 2: owner_pid — isolates different sessions with same config dir
// $PPID in Bash = Claude Code process PID (Bash runs as child of Claude Code)
const configDir = Bash(`cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

// ── Pre-creation guard: check for existing batch from another session ──
const existingState = Read(".claude/arc-batch-loop.local.md") // returns null/error if not found
if (existingState && existingState.includes("active: true")) {
  const existingPid = existingState.match(/owner_pid:\s*(\d+)/)?.[1]
  const existingCfg = existingState.match(/config_dir:\s*(.+)/)?.[1]?.trim()

  let ownedByOther = false
  if (existingCfg && existingCfg !== configDir) {
    ownedByOther = true
  }
  if (!ownedByOther && existingPid && /^\d+$/.test(existingPid) && existingPid !== ownerPid) {
    // Check if other session is alive (SEC-1: numeric guard before shell interpolation)
    const alive = Bash(`kill -0 ${existingPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === "alive") {
      ownedByOther = true
    }
  }

  if (ownedByOther) {
    error("Another session is already running arc-batch on this repo.")
    error("Cancel it first with /rune:cancel-arc-batch, or wait for it to finish.")
    return
  }
  // Owner is dead → orphaned state file. Safe to overwrite.
  warn("Found orphaned batch state file (previous session crashed). Overwriting.")
}

// ── Write state file for Stop hook ──
// Format matches ralph-wiggum's .local.md convention (YAML frontmatter)
Write(".claude/arc-batch-loop.local.md", `---
active: true
iteration: 1
max_iterations: 0
total_plans: ${planPaths.length}
no_merge: ${!autoMerge}
plugin_dir: ${pluginDir}
config_dir: ${configDir}
owner_pid: ${ownerPid}
session_id: ${CLAUDE_SESSION_ID}
plans_file: ${planListFile}
progress_file: ${progressFile}
summary_enabled: ${summaryEnabled}
summary_dir: tmp/arc-batch/summaries
compact_pending: false
started_at: "${new Date().toISOString()}"
---

Arc batch loop state. Do not edit manually.
Use /rune:cancel-arc-batch to stop the batch loop.
`)
// NOTE: summary_enabled and summary_dir are read by the Stop hook via get_field().
// summary_enabled defaults to true when missing (backward compat with old state files).
// summary_dir is always "tmp/arc-batch/summaries" (flat path per C2 — no PID subdirectory).
// Phase 6 synthetic resume summaries are NOT implemented (C11 — YAGNI).
// On --resume, step 4.5 handles missing summaries via conditional injection.

// ── Mark first pending plan as in_progress ──
// P1-FIX: Find the correct plan entry in progress file by matching path,
// not by index — planPaths[0] is the first *pending* plan (filtered in resume mode).
const firstPlan = planPaths[0]
const progress = JSON.parse(Read(progressFile))
const planEntry = progress.plans.find(p => p.path === firstPlan && p.status === "pending")
if (planEntry) {
  planEntry.status = "in_progress"
  planEntry.started_at = new Date().toISOString()
  progress.updated_at = new Date().toISOString()
  Write(progressFile, JSON.stringify(progress, null, 2))
}

// ── Write plan path to fallback file (FIX-001: ensures arc receives plan path) ──
const mergeFlag = !autoMerge ? " --no-merge" : ""
const arcArgs = `${firstPlan} --skip-freshness --accept-external${mergeFlag}`
Write("tmp/.rune-arc-batch-next-plan.txt", arcArgs)

// ── Load and execute arc for first plan ──
// FIX-005 (v1.143.5): Bypass Skill() call entirely. Claude treats Skill() as a
// terminal action in Stop hook context — loads the skill but ends response without
// executing the loaded instructions. Instead, Read() the arc SKILL.md and reference
// files directly. Read() returns content inline, which Claude processes as part of
// its response flow (no "loaded" endpoint).
//
// ARC-BATCH-001 FIX: Use "rune:arc" (not "arc") — must match stop hook naming.
// Arc-batch always passes --accept-external: batch runs commonly accumulate
// commits from prior arcs or parallel sessions on the same branch.
const pluginRel = "plugins/rune" // relative path from CWD to plugin root
Read(`${pluginRel}/skills/arc/SKILL.md`)
Read(`${pluginRel}/skills/arc/references/arc-preflight.md`)
Read(`${pluginRel}/skills/arc/references/arc-checkpoint-init.md`)

// Now execute the arc pipeline with these parameters:
//   - Plan file: firstPlan (= planPaths[0])
//   - Flags: --skip-freshness --accept-external + mergeFlag
//   - Follow the instructions from the Read() calls above, starting at "Pre-flight"
//   - Create the arc checkpoint (arc-checkpoint-init.md)
//   - Write the phase loop state file (.claude/arc-phase-loop.local.md)
//   - Execute the first pending phase
//
// DO NOT call Skill("rune:arc") — you already have the instructions from Read().
// DO NOT implement the plan code directly. Follow the arc SKILL.md instructions.

// After the first arc completes, Claude's response ends.
// The Stop hook fires, reads the state file, marks plan 1 as completed,
// finds plan 2, and re-injects the arc prompt for the next plan.
// This continues until all plans are processed.
```

## How the Loop Works

1. Phase 5 reads arc SKILL.md + reference files directly (Read, not Skill) and executes the pipeline
2. When arc completes, Claude's response ends → Stop event fires
3. `arc-batch-stop-hook.sh` reads `.claude/arc-batch-loop.local.md`
4. Marks current plan as completed in `batch-progress.json`
5. Finds next pending plan
6. Re-injects arc prompt via `{"decision":"block","reason":"<prompt>"}`
7. Claude receives the re-injected prompt → runs next arc
8. Repeat until all plans done
9. On final iteration: removes state file, releases workflow lock, injects summary prompt
10. Summary turn completes → Stop hook finds no state file → allows session end

**Lock release**: The stop hook releases the workflow lock on the final iteration:
```bash
source "${CWD}/plugins/rune/scripts/lib/workflow-lock.sh" && rune_release_lock "arc-batch"
```
