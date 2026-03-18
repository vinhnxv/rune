# Batch Algorithm Reference

Full orchestration pseudocode for `/rune:arc-batch`. The SKILL.md body contains the executable version; this reference documents the design rationale and edge cases.

## Architecture (V2 — Stop Hook Pattern, v1.59.0)

```
SKILL.md (orchestration layer)
  ├── Phase 0: Parse $ARGUMENTS → plan list
  ├── Phase 1: Pre-flight → arc-batch-preflight.sh (validation)
  ├── Phase 1.5: Plan ordering → input-type-aware (queue→skip, glob→ask, --smart-sort→force)
  ├── Phase 2: Dry run (if --dry-run) → early return
  ├── Phase 3: Initialize batch-progress.json
  ├── Phase 4: Confirm batch → AskUserQuestion
  └── Phase 5: Start loop → write state file + Skill("rune:arc", firstPlan)
                │
                └── Stop hook drives all subsequent iterations:

scripts/arc-batch-stop-hook.sh (Stop hook — loop driver)
  ├── Guard: jq available?
  ├── Guard: stdin cap (1MB)
  ├── Guard: CWD extraction from hook input
  ├── Guard: .rune/arc-batch-loop.local.md exists?
  ├── Guard: symlink check
  ├── Guard: session isolation (config_dir + owner_pid)
  ├── Guard: active flag = true?
  ├── Guard: numeric field validation
  ├── Guard: max_iterations reached?
  ├── Read batch-progress.json
  │   ├── Mark current in_progress plan → completed
  │   └── Find next pending plan
  ├── No more plans?
  │   └── rm state file → block stop with summary prompt
  └── More plans?
      ├── Increment iteration in state file
      ├── Git cleanup (checkout main, pull --ff-only)
      ├── Clean stale teams/tasks dirs
      └── Output: {"decision":"block","reason":"<arc prompt>"}
```

**Key difference from V1**: Each arc run executes as a native Claude Code turn. No subprocess spawning, no Bash tool timeout limit, no orphaned processes. The Stop hook intercepts session end and re-injects the next arc prompt.

**Inspired by**: [ralph-wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) Stop hook pattern.

## Phase 1.5: Plan Ordering (v1.104.0, opt-in v1.118.0)

Input-type-aware ordering with 3 modes. Queue files respect user order by default. Glob inputs present ordering options. CLI flags override all modes. Memory-only — does NOT write `plan-list.txt` (Phase 5 writes it from the already-reordered array). The Stop hook reads `batch-progress.json` which reflects the ordered result.

See [smart-ordering.md](smart-ordering.md) for the full Tier 1 smart ordering algorithm (applied when smart ordering is selected).

**Decision tree** (evaluated top-to-bottom, first match wins):

```
function resolveOrdering(planPaths, inputType, talisman, resumeMode, noSmartSort, forceSmartSort):
  // Priority 1: CLI flags
  if noSmartSort:
    return planPaths  // raw order
  if forceSmartSort and planPaths.length > 1:
    return smartOrderPlans(planPaths)  // force even on queue files

  // Priority 2: Resume guard (before talisman)
  if resumeMode:
    return planPaths  // preserve partial batch order

  // Priority 3: Kill switch
  if talisman?.arc?.batch?.smart_ordering?.enabled === false:
    return planPaths  // master kill switch

  // Priority 4: Talisman mode
  mode = talisman?.arc?.batch?.smart_ordering?.mode ?? "ask"
  if mode === "off":
    return planPaths
  if mode === "auto" and planPaths.length > 1:
    return smartOrderPlans(planPaths)

  // Priority 5: Input-type heuristic (mode="ask")
  if inputType === "queue":
    return planPaths  // respect user's explicit order
  if inputType === "glob" and planPaths.length > 1:
    answer = AskUserQuestion("Smart ordering / Alphabetical / As discovered")
    if answer === "Smart ordering":
      return smartOrderPlans(planPaths)
    if answer === "Alphabetical":
      return planPaths.sort(alphabetical)
    return planPaths  // as discovered

  return planPaths  // single plan or no action needed
```

**`smartOrderPlans()` subroutine** (unchanged from v1.104.0):
```
function smartOrderPlans(planPaths):
  UNIVERSAL = {plugin.json, CHANGELOG.md, CLAUDE.md, marketplace.json, README.md}

  for each plan in planPaths:
    plan.fileTargets = extractFileTargets(plan) - UNIVERSAL
    plan.versionTarget = extractYamlFrontmatter(plan).version_target ?? null

  for each plan in planPaths:
    plan.isIsolated = true
    for each other in planPaths where other != plan:
      if intersect(plan.fileTargets, other.fileTargets) is not empty:
        plan.isIsolated = false
        break

  sort planPaths by:
    1. is_isolated DESC (true before false)
    2. version_target ASC (null sorts last)
    3. path alphabetical

  return sorted planPaths
```

**Interaction with shard grouping**: Phase 0 (shard auto-sorting) runs FIRST on its subset, then Phase 1.5 (plan ordering) runs on the full plan list. Smart ordering respects shard grouping boundaries — shard plans within feature groups maintain their numeric order. Both are independently controlled (`--no-smart-sort` / `--no-shard-sort`).

## V1 Architecture (REMOVED — v1.59.0)

The V1 architecture used `scripts/arc-batch.sh` to spawn `claude -p` subprocesses in a loop. This was broken because the Bash tool timeout (max 600s / 10 min) is far shorter than a single arc run (45-240 min). The parent process would be killed, orphaning the child `claude -p` process, causing the batch to get stuck after the first plan.

`scripts/arc-batch.sh` was removed in v1.59.0. See git history for the V1 implementation.

## State File Format

The Stop hook reads and writes `.rune/arc-batch-loop.local.md`:

```yaml
---
active: true
iteration: 1
max_iterations: 0
total_plans: 4
no_merge: false
plugin_dir: /path/to/rune/plugin
config_dir: /Users/user/.claude
owner_pid: 12345
session_id: abc-123-def-456
plans_file: tmp/arc-batch/plan-list.txt
progress_file: tmp/arc-batch/batch-progress.json
summary_enabled: true
summary_dir: tmp/arc-batch/summaries
started_at: "2026-02-21T00:00:00Z"
---

Batch arc loop state. Do not edit manually.
Use /rune:cancel-arc-batch to stop.
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `summary_enabled` | boolean | `true` | Enable inter-iteration summary files. Read from `talisman.arc.batch.summaries.enabled`. Backward-compat: missing field treated as `true`. |
| `summary_dir` | string | `tmp/arc-batch/summaries` | Flat directory for summary files (no PID subdirectory — session isolation via Guard 5.7). |

## Stop Hook Loop Flow

```
Claude session turn N:
  1. /rune:arc completes (or user ends turn)
  2. Claude stops responding → Stop hook fires
  3. arc-batch-stop-hook.sh reads state file
  3.5. [v1.72.0] Write structured summary to tmp/arc-batch/summaries/iteration-{N}.md
       (plan path, status, git log, PR URL, branch — BEFORE marking completed)
  4. Marks current plan completed in batch-progress.json
  5. Finds next pending plan
  6. Outputs blocking JSON → Claude starts new turn with arc prompt
     [v1.72.0] ARC_PROMPT includes step 4.5 (conditional):
     read summary, append context note under ## Context Note section
  7. /rune:arc runs for next plan
  8. Repeat from step 2

Final iteration:
  3. Stop hook reads state file, finds no more pending plans
  4. Removes state file
  5. Outputs blocking JSON with summary prompt
  6. Claude reads batch-progress.json, presents summary
  7. Stop hook fires again, no state file → exit 0 (allows stop)
```

## Progress File Schema

```json
{
  "schema_version": 2,
  "status": "running | completed | finished | interrupted",
  "started_at": "ISO-8601",
  "updated_at": "ISO-8601",
  "completed_at": "ISO-8601 | null",
  "total_duration_s": 0,
  "total_plans": 3,
  "plans": [
    {
      "path": "plans/feat-a.md",
      "status": "pending | in_progress | completed | failed",
      "error": "null | error message",
      "completed_at": "ISO-8601 | null",
      "arc_session_id": "arc-{timestamp} | null",
      "summary_file": "tmp/arc-batch/summaries/iteration-1.md | null",
      "pr_url": "https://github.com/... | null"
    }
  ]
}
```

**Schema v2 additions** (v1.66.0+): `shard_groups`, per-plan `shard_group` and `shard_num`.
**v1.72.0 additions**: per-plan `summary_file` and `pr_url` (both nullable, backward-compatible).

> **Schema version history**: schema v2 was introduced in v1.66.0 for shard metadata (`shard_groups`, `shard_group`, `shard_num`). The `summary_file` and `pr_url` fields are backward-compatible nullable additions within v2 (added in v1.72.0) — existing v2 progress files without these fields are valid.

## Edge Case Matrix (V2)

| Edge Case | Handler | Location |
|-----------|---------|----------|
| Empty glob (zsh NOMATCH) | Glob tool handles expansion | SKILL.md Phase 0 |
| Plan file doesn't exist | arc-batch-preflight.sh validates | scripts/ |
| Plan file is symlink | arc-batch-preflight.sh rejects | scripts/ |
| Duplicate plan in list | arc-batch-preflight.sh deduplicates | scripts/ |
| Path traversal (`..`) | arc-batch-preflight.sh rejects | scripts/ |
| Auto-merge disabled | SKILL.md detects and prompts | SKILL.md Phase 1 |
| State file missing | Stop hook exits 0 (no active batch) | arc-batch-stop-hook.sh |
| State file is symlink | Stop hook exits 0 (security guard) | arc-batch-stop-hook.sh |
| State file corrupt/non-YAML | Stop hook removes state file, exits 0 | arc-batch-stop-hook.sh |
| jq unavailable | Stop hook exits 0 (cannot parse progress) | arc-batch-stop-hook.sh |
| stdin exceeds 1MB | Stop hook exits 0 (safety cap) | arc-batch-stop-hook.sh |
| max_iterations reached | Stop hook removes state file, exits 0 | arc-batch-stop-hook.sh |
| Progress file missing | Stop hook removes state file, exits 0 | arc-batch-stop-hook.sh |
| No more pending plans | Stop hook removes state file, blocks with summary prompt | arc-batch-stop-hook.sh |
| Git checkout/pull fails | Stop hook skips git ops, includes in prompt | arc-batch-stop-hook.sh |
| Context window growth | Auto-compaction handles; state in file not context | Claude Code |
| Cancel mid-batch | `/rune:cancel-arc-batch` removes state file | commands/cancel-arc-batch.md |
| Cancel arc also cancels batch | `/rune:cancel-arc` Step 0 removes batch state file | commands/cancel-arc.md |
| Smart ordering with 1 plan | Phase 1.5 skip (length <= 1) | SKILL.md Phase 1.5 |
| Smart ordering + resume | Phase 1.5 skip (would reorder partial batch) | SKILL.md Phase 1.5 |
| Plan without frontmatter | Backtick-path fallback for file targets; null version_target (sorted last) | SKILL.md Phase 1.5 |
| All plans isolated | All classified as isolated; sorted by version_target then filename | SKILL.md Phase 1.5 |
| All plans conflicting | All classified as conflicting; sorted by version_target then filename | SKILL.md Phase 1.5 |
| on-session-stop.sh conflict | GUARD 5 defers when batch state file present | scripts/on-session-stop.sh |
| Cross-session interference | Two-layer isolation: config_dir (installation) + owner_pid (process). Dead owner = orphaned batch cleanup | arc-batch-stop-hook.sh |
| Concurrent batch creation | Pre-creation guard checks if state file exists with a live owner. Blocks with error if another session owns it | SKILL.md Phase 5 |
| Cancel from wrong session | Ownership warning on cancel commands (still allows cancellation) | cancel-arc-batch.md, cancel-arc.md |
| on-session-stop.sh deferral | Only defers to arc-batch hook if this session owns the batch | on-session-stop.sh |
| Stale teams between plans | Stop hook cleans teams/tasks dirs | arc-batch-stop-hook.sh |
| Summary write fails | Non-blocking — SUMMARY_PATH set to empty, step 4.5 omitted | arc-batch-stop-hook.sh |
| First iteration (no prior summary) | Step 4.5 conditional on SUMMARY_PATH — omitted for first arc | arc-batch-stop-hook.sh |
| summary_enabled: false | All summary logic skipped (talisman kill switch) | arc-batch-stop-hook.sh |
| Old state file without summary_enabled | get_field returns empty → treated as true (backward compat) | arc-batch-stop-hook.sh |
| Compaction during arc-batch (no team) | Teamless checkpoint with arc_batch_state (C6 accepted) | pre-compact-checkpoint.sh |
| Large git log output | Capped to 5 commits via --oneline -5 (hardcoded per C8/C9) | arc-batch-stop-hook.sh |
| Summary path traversal/symlink | Rejected by path validation + symlink check | arc-batch-stop-hook.sh |

## V1 Edge Cases (REMOVED — v1.59.0)

These edge cases applied to the V1 subprocess architecture and are no longer relevant:

| Edge Case | V1 Handler | V2 Status |
|-----------|-----------|-----------|
| Bash tool timeout (600s) | Root cause of V1 failure | Eliminated — no Bash subprocess |
| `claude -p` not available | SKILL.md check | Eliminated — uses native Skill() |
| `setsid` unavailable | Fallback to direct exec | Eliminated — no subprocess |
| Claude hangs after completion | Checkpoint watchdog | Eliminated — Stop hook fires naturally |
| `$!` captures tee PID | Direct redirect fix | Eliminated — no subprocess |
| JSON output buffers | `--output-format text` | Eliminated — no subprocess |
