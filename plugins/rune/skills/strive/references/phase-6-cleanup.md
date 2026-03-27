# Phase 6: Cleanup & Report

## Teammate Fallback Array

```javascript
// FALLBACK: all possible strive teammates (static worst-case, safe to send to absent members)
allMembers = [
  // Single-wave workers (non-wave mode)
  ...Array.from({length: 6}, (_, i) => `rune-smith-${i + 1}`),
  // Multi-wave workers (wave-execution.md: up to 4 waves x 6 workers per wave)
  ...Array.from({length: 4}, (_, w) =>
    Array.from({length: 6}, (_, i) => `rune-smith-w${w}-${i + 1}`)
  ).flat(),
  // Gap convergence workers (up to 6 iterations x 2 concurrent = 12 workers)
  ...Array.from({length: 12}, (_, i) => `rune-smith-gap-${Math.floor(i / 2) + 1}-${(i % 2) + 1}`),
  "trial-forger", "unit-test-runner", "test-failure-analyst",
  "codex-advisory", "micro-evaluator"
]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

**Pre-shutdown note:** Cache `const allTasks = TaskList()` BEFORE team cleanup (TaskList() requires active team).

**Mid-protocol (step 2.7):** After grace period, finalize per-worker artifacts before TeamDelete:

```javascript
// 2.7. Finalize per-worker artifacts (non-blocking — skip if runs/ absent)
try {
  const workRunsDir = `tmp/work/${timestamp}/runs/`
  const runMetas = Glob(`${workRunsDir}*/meta.json`)
  for (const metaPath of runMetas) {
    try {
      const meta = JSON.parse(Read(metaPath))
      if (meta.status === "running") {
        const agentRunDir = metaPath.replace(/\/meta\.json$/, '')
        const agentName = agentRunDir.split('/').pop()
        const workerTasks = allTasks.filter(t => t.owner === agentName && t.status === "completed")
        const agentStatus = workerTasks.length > 0 ? "completed" : "failed"
        Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/run-artifacts.sh 2>/dev/null && type rune_artifact_finalize &>/dev/null && rune_artifact_finalize "${agentRunDir}" "${agentStatus}"`)
      }
    } catch (e) { /* per-agent finalization failure is non-blocking */ }
  }
} catch (e) { /* artifact finalization is non-blocking */ }
```

## Post-Cleanup

```javascript
// 3.5: Fix stale worker log statuses (FLAW-008 — active → interrupted)
// 3.6: Worktree garbage collection (worktree mode only)
//      git worktree prune + remove orphaned worktrees matching rune-work-*
// 3.7: Restore stashed changes if Phase 0.5 stashed (git stash pop)
// 4. Update state file to completed (preserve session identity fields)
// 5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "strive"`)
```

## Completion Report

```
The Tarnished has claimed the Elden Throne.

Plan: {planPath}
Branch: {currentBranch}

Tasks: {completed}/{total}
Workers: {smith_count} Rune Smiths, {forger_count} Trial Forgers
Wards: {passed}/{total} passed
Commits: {commit_count}
Time: {duration}

Files changed:
- {file list with change summary}

Artifacts: tmp/work/{timestamp}/
```

## Per-Task Status Table (discipline-enabled plans only)

```javascript
// Read all task files to build per-task status breakdown
const taskFiles = Glob(`tmp/work/${timestamp}/tasks/task-*.md`)
const perTaskStatus = []

for (const tf of taskFiles) {
  const content = Read(tf)
  const fm = parseYAMLFrontmatter(content)
  const taskId = String(fm.task_id)  // FLAW-008: normalize to String
  if (taskId.startsWith('gap-')) continue  // Skip gap tasks in primary summary

  const evidencePath = `tmp/work/${timestamp}/evidence/${taskId}/summary.json`
  let evidence = null
  try { evidence = JSON.parse(Read(evidencePath)) } catch {}

  const criteriaTotal = fm.proof_count ?? 0
  const criteriaPass = evidence?.criteria_results?.filter(r => r.result === 'PASS').length ?? 0

  perTaskStatus.push({
    task_id: taskId,
    status: fm.status,
    worker: fm.assigned_to,
    criteria: `${criteriaPass}/${criteriaTotal}`,
    has_report: content.includes('### Echo-Back') && !content.includes('_To be filled'),
  })
}

// Include per-task table in completion report
const perTaskTable = [
  '| Task | Status | Worker | Criteria | Report |',
  '|------|--------|--------|----------|--------|',
  ...perTaskStatus.map(t =>
    `| ${t.task_id} | ${t.status} | ${t.worker ?? 'unassigned'} | ${t.criteria} | ${t.has_report ? '✓' : '✗'} |`
  ),
].join('\n')

// Append convergence metrics if available
let convergenceSection = ''
if (exists(`tmp/work/${timestamp}/convergence/metrics.json`)) {
  const metrics = JSON.parse(Read(`tmp/work/${timestamp}/convergence/metrics.json`))
  const scr = metrics.metrics?.scr?.value ?? 'N/A'
  const iterations = metrics.metrics?.convergence_iterations?.value ?? 0
  convergenceSection = `\nSCR: ${scr}% | Convergence iterations: ${iterations}`
}
```
