# Work Loop Convergence — Criteria-Based Iteration Protocol

Detailed convergence protocol for the Discipline Work Loop Phase 5. This document
specifies entry conditions, iteration logic, exit conditions (success + 3 failure modes),
gap task creation, and convergence report format.

Referenced from [discipline-work-loop.md](discipline-work-loop.md) Phase 5.

---

## Entry Conditions

The convergence loop activates ONLY when ALL of the following are true:

1. **Plan has YAML acceptance criteria**: At least one `AC-*` block exists in the plan.
   Detection: `hasCriteria` gate from parse-plan Phase 0.
2. **Phase 4.5 completion matrix exists**: `tmp/work/{timestamp}/work-review/completion-matrix.md`
   has been written with per-criterion status.
3. **At least one non-PASS criterion**: If all criteria are PASS after Phase 4.5, the
   convergence loop is skipped entirely (success on first pass).
4. **Discipline enabled**: `talisman.yml` → `discipline.enabled` is not `false` (default: `true`).

When entry conditions are NOT met, strive proceeds directly to Phase 6 (Quality Gates)
with single-pass results.

---

## Configuration

| Config Key | Default | Description |
|---|---|---|
| `discipline.max_convergence_iterations` | `3` | Maximum number of convergence iterations before forced exit |
| `discipline.scr_threshold` | `0.95` | SCR target — convergence succeeds when SCR >= threshold |
| `discipline.block_on_fail` | `false` | Whether convergence failure blocks task completion (WARN vs BLOCK) |
| `discipline.enabled` | `true` | Master switch for the discipline work loop |

All values read via `readTalismanSection("discipline")` (dedicated discipline shard — FLAW-001 fix).

---

## Iteration Logic

Each convergence iteration follows this sequence:

```
┌─────────────────────────────────────────────────────────┐
│ Iteration N                                             │
│                                                         │
│ 1. Read completion matrix (Phase 4.5 output)            │
│ 2. Identify non-PASS criteria                           │
│ 3. Classify non-PASS by status:                         │
│    - FAIL → generate correction task                    │
│    - INCOMPLETE → generate completion task              │
│    - MISSING → generate new implementation task         │
│    - ABANDONED → log + escalate (no auto-retry)         │
│ 4. Check exit conditions (see below)                    │
│ 5. If continuing: create gap tasks                      │
│ 6. Assign gap tasks to workers                          │
│ 7. Execute gap tasks (Phase 3 re-entry)                 │
│ 8. Re-review (Phase 4.5 re-entry)                       │
│ 9. Write iteration report                               │
│ 10. Increment iteration counter → loop to Step 1        │
└─────────────────────────────────────────────────────────┘
```

### Step 1: Read Completion Matrix

Parse `tmp/work/{timestamp}/work-review/completion-matrix.md` to extract per-criterion
status. Build a map: `{ criterion_id → { status, evidence_path, task_id } }`.

### Step 2: Identify Non-PASS Criteria

Filter the map for entries where `status != PASS`. These are the **gap criteria** that
need correction in this iteration.

### Step 3: Classify and Route

| Status | Action | Gap Task Type |
|---|---|---|
| `FAIL` | Evidence collected but verification failed. Generate correction task with failure evidence attached. | `correction` |
| `INCOMPLETE` | Partial evidence exists. Generate completion task to fill remaining gaps. | `completion` |
| `MISSING` | No evidence at all. Generate implementation task from scratch. | `implementation` |
| `ABANDONED` | Worker marked infeasible. Log and escalate — do NOT auto-retry. | `escalation` (no task created) |

### Step 4: Check Exit Conditions

Exit conditions are checked BEFORE creating gap tasks. See [Exit Conditions](#exit-conditions).

### Step 5: Create Gap Tasks

For each non-PASS, non-ABANDONED criterion, create a gap task:

```json
{
  "task_id": "gap-{iteration}-{criterion_id}",
  "type": "correction|completion|implementation",
  "criterion_id": "AC-1.2.3",
  "previous_status": "FAIL",
  "previous_evidence": "path/to/failed/evidence",
  "failure_code": "F3",
  "context": "Previous attempt failed because: {evidence text from last iteration}",
  "files": ["path/to/relevant/file.ts"]
}
```

Gap task files are written to `tmp/work/{timestamp}/tasks/gap-{iteration}-{criterion_id}.md`
following the [task-file-format.md](task-file-format.md) schema.

**Key rule**: Gap tasks include the PREVIOUS failure evidence so workers can learn from
the prior attempt's failure. This prevents workers from repeating the same mistake.

### Steps 6-8: Re-Execute

Gap tasks are added to the TaskCreate pool and assigned to workers using the same
Phase 2-3 mechanisms. Workers receive ONLY their gap task files (context isolation
preserved). After execution, Phase 4.5 runs again to produce an updated completion matrix.

### Step 9: Write Iteration Report

See [Convergence Report Format](#convergence-report-format).

---

## Exit Conditions

Exit conditions are evaluated at the START of each iteration (Step 4), using the
completion matrix from the previous iteration's Phase 4.5.

### Success Exit

**Condition**: All criteria have status `PASS` (or all non-ABANDONED criteria are PASS).

```
if non_pass_count == 0 OR (non_pass_count == abandoned_count):
  exit SUCCESS
```

When success is reached:
1. Write final iteration report with `"exit_reason": "success"`
2. Compute SCR from the final completion matrix
3. Proceed to Phase 6 (Quality Gates)

### Failure Exit 1: Stagnation (F17)

**Condition**: Same criteria fail across 2 consecutive iterations with no improvement.

```
if iteration >= 2:
  current_fails = set(criteria where status in [FAIL, INCOMPLETE, MISSING])
  previous_fails = set(criteria from iteration N-1 where status in [FAIL, INCOMPLETE, MISSING])
  if current_fails == previous_fails:
    exit STAGNATION (F17)
```

**Detection signal**: `CONVERGENCE_STAGNATION` — the system is stuck. Same failures repeat
because the worker is trying the same approach or the criterion is fundamentally unsatisfiable.

**Recovery path**:
1. Write iteration report with `"exit_reason": "stagnation"`, `"failure_code": "F17"`
2. Log stagnated criteria IDs to stderr
3. If `block_on_fail`: block task completion (exit 2)
4. If not: warn and proceed to Phase 6 with partial results

### Failure Exit 2: Regression (F10)

**Condition**: A criterion that was PASS in a previous iteration is now non-PASS.

```
for each criterion in current_iteration:
  if criterion.status != PASS:
    for prev in previous_iterations:
      if prev[criterion.id].status == PASS:
        exit REGRESSION (F10)
```

**Detection signal**: `REGRESSION` — a gap task fix broke something that was working.
This is the most dangerous failure mode because it indicates cross-cutting side effects.

**Recovery path**:
1. Write iteration report with `"exit_reason": "regression"`, `"failure_code": "F10"`
2. Identify the regression: which criterion regressed and what changed
3. Log regressed criteria to stderr with the iteration where they last passed
4. If `block_on_fail`: block task completion (exit 2)
5. If not: warn and proceed — the regression is visible in the convergence report

### Failure Exit 3: Budget Exceeded (F15)

**Condition**: Maximum iterations reached without full convergence.

```
if iteration > max_convergence_iterations:
  exit BUDGET_EXCEEDED (F15)
```

**Detection signal**: `BUDGET_EXCEEDED` — the convergence loop ran out of iterations.
Some criteria may still be non-PASS.

**Recovery path**:
1. Write iteration report with `"exit_reason": "budget_exceeded"`, `"failure_code": "F15"`
2. Log remaining non-PASS criteria count and IDs
3. Compute partial SCR from the final state
4. If `block_on_fail`: block task completion (exit 2)
5. If not: proceed to Phase 6 with partial results + SCR below threshold warning

---

## Gap Task Creation

Gap tasks are created in Step 5 for non-PASS, non-ABANDONED criteria.

### Task File Structure

Gap task files follow the same [task-file-format.md](task-file-format.md) schema as
regular tasks, with these additions:

```yaml
---
id: gap-2-AC-1.2.3
type: correction
iteration: 2
criterion_id: AC-1.2.3
previous_status: FAIL
failure_code: F3
---
```

### Task Body

The gap task body includes:

1. **Criterion text**: Verbatim from the plan (same as original task)
2. **Previous attempt context**: What the worker did and why it failed
3. **Failure evidence**: Path to the evidence artifact from the failed attempt
4. **Failure code**: The F-code classification with its recovery hint
5. **File scope**: Which files to modify (inherited from original task or narrowed)

### Assignment Strategy

| Gap Task Type | Assignment |
|---|---|
| `correction` | Same worker who produced the FAIL (they have context) |
| `completion` | Same worker (partial work exists) |
| `implementation` | Any available worker (fresh perspective may help) |

If the same worker has failed the same criterion twice, assign to a DIFFERENT worker
on the third attempt to break potential reasoning loops.

---

## Convergence Report Format

Each iteration writes a report to `tmp/work/{timestamp}/convergence/iteration-{N}.json`:

```json
{
  "iteration": 2,
  "timestamp": "2026-03-16T19:45:00Z",
  "entry_state": {
    "total_criteria": 12,
    "pass": 9,
    "fail": 2,
    "incomplete": 1,
    "missing": 0,
    "abandoned": 0
  },
  "gap_tasks_created": 3,
  "gap_task_ids": ["gap-2-AC-1.2.3", "gap-2-AC-2.1.1", "gap-2-AC-3.4.2"],
  "exit_state": {
    "total_criteria": 12,
    "pass": 11,
    "fail": 1,
    "incomplete": 0,
    "missing": 0,
    "abandoned": 0
  },
  "failure_codes": ["F3"],
  "scr": 0.917,
  "exit_reason": null,
  "exit_failure_code": null,
  "regressions": [],
  "stagnation_detected": false
}
```

### Field Definitions

| Field | Type | Description |
|---|---|---|
| `iteration` | number | 1-indexed iteration number |
| `timestamp` | string | ISO-8601 time the iteration completed |
| `entry_state` | object | Criterion status counts at iteration start |
| `gap_tasks_created` | number | How many gap tasks were created this iteration |
| `gap_task_ids` | array | IDs of created gap tasks |
| `exit_state` | object | Criterion status counts after gap tasks completed |
| `failure_codes` | array | Unique F-codes from all FAIL criteria in exit state |
| `scr` | number | Spec Compliance Rate at exit (0.0-1.0) |
| `exit_reason` | string\|null | `null` if continuing, or `"success"`, `"stagnation"`, `"regression"`, `"budget_exceeded"` |
| `exit_failure_code` | string\|null | `null` if success/continuing, or `"F17"`, `"F10"`, `"F15"` |
| `regressions` | array | Criterion IDs that regressed (were PASS, now non-PASS) |
| `stagnation_detected` | boolean | Whether same-fail-set was detected vs previous iteration |

### Final Report

When the loop exits (any reason), a summary is written to
`tmp/work/{timestamp}/convergence/metrics.json` (merged with other discipline metrics):

```json
{
  "convergence": {
    "iterations_used": 2,
    "max_iterations": 3,
    "exit_reason": "success",
    "exit_failure_code": null,
    "final_scr": 1.0,
    "first_pass_rate": 0.75,
    "failure_code_histogram": {"F3": 3, "F8": 1},
    "regressions_total": 0,
    "stagnation_rounds": 0
  }
}
```

The `failure_code_histogram` aggregates all F-codes seen across all iterations,
providing a signal about systematic failure patterns (e.g., many F3s suggest
implementation quality issues; many F8s suggest infrastructure problems).

---

## Executable Pseudocode

```javascript
// Phase 5: Convergence Loop
// Run AFTER Phase 4.5 (Completion Matrix), when SCR < threshold
function convergenceLoop(timestamp, matrixResult, planCriteriaMap) {
  // FLAW-001 FIX: Read from dedicated discipline shard (not full talisman parse)
  const disciplineConfig = readTalismanSection("discipline")
  const maxIterations = disciplineConfig?.max_convergence_iterations ?? 3
  const scrThreshold = disciplineConfig?.scr_threshold ?? 100
  const iterationTimeoutMs = disciplineConfig?.iteration_timeout_ms ?? 1_200_000  // 20 min per iteration

  // FLAW-002 FIX: Guard — no criteria = no convergence
  if (!planCriteriaMap || Object.keys(planCriteriaMap).length === 0) {
    log('Convergence: No acceptance criteria in plan — skipping convergence loop')
    return { exit: 'skipped', reason: 'no_acceptance_criteria' }
  }

  // FLAW-003 FIX: Guard — maxIterations <= 0 = disabled
  if (maxIterations <= 0) {
    log('Convergence: max_convergence_iterations=0 — convergence disabled')
    return { exit: 'disabled', reason: 'max_iterations_zero' }
  }

  let iteration = 0
  let currentMatrix = matrixResult
  let previousMatrix = null  // For stagnation detection

  while (currentMatrix.scr < scrThreshold && iteration < maxIterations) {
    // FLAW-014: Include INCONCLUSIVE in gap criteria filter
    const gapCriteria = currentMatrix.matrix.filter(m =>
      m.proof_result === 'FAIL' || m.proof_result === 'MISSING' || m.proof_result === 'INCONCLUSIVE'
    )
    if (gapCriteria.length === 0) break

    // FLAW-006 FIX: Stagnation detection — compare BOTH IDs AND statuses
    if (iteration >= 1 && previousMatrix) {
      const prevGaps = previousMatrix.matrix
        .filter(m => m.proof_result !== 'PASS')
        .map(m => `${m.criterion_id}:${m.proof_result}`)
        .sort()
      const currGaps = gapCriteria
        .map(m => `${m.criterion_id}:${m.proof_result}`)
        .sort()
      if (JSON.stringify(prevGaps) === JSON.stringify(currGaps)) {
        warn(`Convergence: F17 STAGNATION — same criteria with same statuses after iteration ${iteration}`)
        break
      }
      // Also check: if non-PASS count did not decrease, halt
      if (gapCriteria.length >= previousMatrix.matrix.filter(m => m.proof_result !== 'PASS').length) {
        warn(`Convergence: No improvement — ${gapCriteria.length} gaps (same or more than previous)`)
        break
      }
    }

    log(`Convergence iteration ${iteration + 1}/${maxIterations}: ` +
        `${gapCriteria.length} criteria need re-work (SCR=${currentMatrix.scr.toFixed(1)}%)`)

    // Group gap criteria by task
    const gapsByTask = {}
    for (const gap of gapCriteria) {
      const taskId = String(gap.task_id)  // FLAW-008: normalize to String
      if (!gapsByTask[taskId]) gapsByTask[taskId] = []
      gapsByTask[taskId].push(gap)
    }

    // Create gap tasks (one per task with failing criteria)
    for (const [taskId, gaps] of Object.entries(gapsByTask)) {
      const gapTaskId = `gap-${iteration + 1}-${taskId}`

      // FLAW-004 FIX: Extract Source from ORIGINAL PLAN, not from worker-modified task file
      // Task file frontmatter has plan_file and plan_section — use those to get ground truth
      let originalSource = 'See original plan file.'
      try {
        const originalTaskFile = Read(`tmp/work/${timestamp}/tasks/task-${taskId}.md`)
        const taskFrontmatter = parseYAMLFrontmatter(originalTaskFile)
        const planContent = Read(taskFrontmatter.plan_file)
        const planSectionMatch = planContent.match(
          new RegExp(`${taskFrontmatter.plan_section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[\\s\\S]*?(?=\\n### Task|\\n## |$)`)
        )
        if (planSectionMatch) originalSource = planSectionMatch[0]
      } catch { /* original task file may not exist for synthetic tasks */ }

      // Write gap task file to tasks/ directory
      Write(`tmp/work/${timestamp}/tasks/task-${gapTaskId}.md`, [
        '---',
        `task_id: "${gapTaskId}"`,
        `plan_file: "${planCriteriaMap[taskId]?.[0]?.plan_file ?? ''}"`,
        `plan_section: "### Task ${taskId}"`,
        `status: PENDING`,
        `assigned_to: null`,
        `iteration: ${iteration + 1}`,
        `risk_tier: 2`,
        `proof_count: ${gaps.length}`,
        `created_at: "${new Date().toISOString()}"`,
        `updated_at: "${new Date().toISOString()}"`,
        `completed_at: null`,
        '---',
        '',
        '## Source',
        '',
        `**GAP RE-WORK** (iteration ${iteration + 1}): The following criteria from Task ${taskId} were NOT satisfied:`,
        '',
        ...gaps.map(g => `- **${g.criterion_id}** [${g.proof_result}]: ${g.text}`),
        '',
        '## Original Task Context (from plan — not worker-modified)',
        '',
        originalSource,
        '',
        '## Acceptance Criteria',
        '',
        ...gaps.map(g => {
          const original = (planCriteriaMap[taskId] || []).find(c => c.id === g.criterion_id)
          return original ? `- id: ${original.id}\n  text: "${original.text}"\n  proof: ${original.proof}\n  args: ${JSON.stringify(original.args)}\n` : ''
        }),
        '## Worker Report',
        '',
        '_To be filled by assigned worker._',
      ].join('\n'))

      // Create SDK task for gap
      TaskCreate({
        subject: `[GAP-${iteration + 1}] Task ${taskId}: ${gaps.length} criteria to fix`,
        description: `**Task File**: tmp/work/${timestamp}/tasks/task-${gapTaskId}.md\nRead the task file FIRST.`,
      })
    }

    // FLAW-007 FIX: Gap Task Execution — reuse wave-execution.md pattern
    // See wave-execution.md for the canonical pattern:
    // 1. Compute wave capacity: maxWorkers=2 (gap tasks are smaller, limit concurrency)
    // 2. Spawn gap workers: Agent({ name: `rune-smith-gap-{iteration}-{idx}`, team_name, ... })
    // 3. Monitor via TaskList polling (30s intervals, iterationTimeoutMs cap)
    // 4. After completion: commit broker applies patches
    // 5. Shutdown gap workers before next iteration
    const gapTaskCount = Object.keys(gapsByTask).length
    const gapWorkerCount = Math.min(2, gapTaskCount)  // Max 2 concurrent gap workers
    for (let w = 0; w < gapWorkerCount; w++) {
      Agent({
        name: `rune-smith-gap-${iteration + 1}-${w + 1}`,
        team_name: teamName,
        subagent_type: 'rune:work:rune-smith',
        prompt: `You are a gap-fixer worker. Read your assigned task file and fix the FAILED criteria.`,
      })
    }
    // Monitor gap workers (reuse existing waitForCompletion pattern)
    waitForCompletion(teamName, gapWorkerCount, { timeoutMs: iterationTimeoutMs, pollIntervalMs: 30_000 })
    // Shutdown gap workers
    for (let w = 0; w < gapWorkerCount; w++) {
      try { SendMessage({ type: 'shutdown_request', recipient: `rune-smith-gap-${iteration + 1}-${w + 1}` }) } catch {}
    }

    // Write iteration report
    Bash(`mkdir -p "tmp/work/${timestamp}/convergence"`)
    Write(`tmp/work/${timestamp}/convergence/iteration-${iteration + 1}.json`, JSON.stringify({
      iteration: iteration + 1,
      timestamp: new Date().toISOString(),
      entry_state: currentMatrix.breakdown,
      gap_tasks_created: Object.keys(gapsByTask).length,
      scr: currentMatrix.scr,
      exit_reason: null,
      stagnation_detected: false,
    }, null, 2))

    // Save previous matrix for stagnation detection, then re-generate
    previousMatrix = currentMatrix
    currentMatrix = generateCompletionMatrix(timestamp, planCriteriaMap)
    iteration++
  }

  // Final convergence report
  const exitReason = currentMatrix.scr >= scrThreshold ? 'success'
    : iteration >= maxIterations ? 'budget_exceeded' : 'stagnation'
  const exitCode = exitReason === 'success' ? null
    : exitReason === 'budget_exceeded' ? 'F15' : 'F17'

  if (currentMatrix.scr < scrThreshold) {
    warn(`Convergence halted at iteration ${iteration}/${maxIterations}. ` +
         `SCR=${currentMatrix.scr.toFixed(1)}% (threshold: ${scrThreshold}%).`)
  } else {
    log(`Convergence achieved: SCR=${currentMatrix.scr.toFixed(1)}% after ${iteration} iterations.`)
  }

  // Update convergence section in metrics.json
  const metricsPath = `tmp/work/${timestamp}/convergence/metrics.json`
  let metrics = {}
  try { metrics = JSON.parse(Read(metricsPath)) } catch {}
  metrics.convergence = {
    iterations_used: iteration,
    max_iterations: maxIterations,
    exit_reason: exitReason,
    exit_failure_code: exitCode,
    final_scr: currentMatrix.scr,
    first_pass_rate: matrixResult.scr,  // SCR from before convergence
  }
  Write(metricsPath, JSON.stringify(metrics, null, 2))

  return { exit: exitReason, failure_code: exitCode, scr: currentMatrix.scr, iterations: iteration }
}
```

---

## Stochastic Awareness — Retry Classification

Not all failures are equal. The convergence loop distinguishes between **stochastic**
(transient) failures and **systemic** failures using the stochastic budget from
[metrics-schema.md](../../discipline/references/metrics-schema.md).

### Retry Classification Rules

| Retry | Classification | Action |
|-------|---------------|--------|
| First retry | **Expected (stochastic)** — transient failures are baseline noise | Retry silently. No escalation. No log noise. The first retry is within the stochastic budget and does not count toward escalation thresholds. |
| Second retry | **Signal (systemic)** — repeated failure exceeds baseline | Escalate. Log the criterion as a systemic failure. Adjust escalation depth tracking. The second consecutive failure on the same criterion is a signal that the issue is structural, not transient. |

### Why First Retry Is Silent

In multi-agent pipelines, transient failures are unavoidable:
- Tool calls time out under load
- Filesystem operations race with concurrent workers
- External services (MCP, git) return intermittent errors

A `stochastic_rate` of 0.05 (5%) means that for every 20 criteria, ~1 transient failure
is statistically expected. Escalating on the first failure would create false alarms and
waste convergence iterations on noise.

### Escalation Threshold Adjustment

The stochastic budget adjusts escalation thresholds:

```
stochastic_budget = stochastic_rate × total_criteria
effective_escalation_threshold = base_threshold + stochastic_budget
```

When computing whether convergence is stagnating (F17), subtract stochastic failures
(first-retry-pass criteria) from the failure count. Only **repeated failures** (second
retry and beyond) count toward stagnation detection.

### Integration with Convergence Loop

In the iteration logic (Step 3: Classify and Route), apply stochastic classification:

1. **First failure on a criterion**: Mark as `stochastic_candidate`. Retry silently in the
   next iteration without generating stderr warnings or escalation signals.
2. **Second consecutive failure on the same criterion**: Reclassify as `systemic`. Generate
   a correction task with repeated escalation context. Include both failure attempts in the
   gap task body so the next worker sees the full failure history.
3. **Budget tracking**: After each iteration, compute `actual_stochastic = count(criteria
   that failed once then passed)`. If `actual_stochastic > stochastic_budget`, emit a
   warning — the transient failure rate itself is abnormally high (infrastructure issue).

---

## See Also

- [discipline-work-loop.md](discipline-work-loop.md) — 8-phase overview (this document details Phase 5)
- [evidence-convention.md](../../discipline/references/evidence-convention.md) — Evidence directory layout and summary.json schema
- [failure-codes.md](../../discipline/references/failure-codes.md) — F1-F17 failure code registry
- [metrics-schema.md](../../discipline/references/metrics-schema.md) — SCR, first-pass rate, and other discipline metrics
- [task-file-format.md](task-file-format.md) — Task file schema (gap tasks follow same format)
