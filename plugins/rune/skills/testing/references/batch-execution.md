# Batch Execution — Batched Testing Phase

Defines the batch size formula, testing plan generator, batch executor state machine,
checkpoint system, and rendering for the batched testing phase (arc Phase 7.7).

The testing plan is both the execution plan AND the checkpoint — plan + state are combined
into a single `testing-plan.json` file. See [testing-plan-schema.md](testing-plan-schema.md)
for the full JSON schema.

## Constants

```javascript
// v2.10.8: Tuned for one-batch-per-turn architecture.
// Each batch runs as a separate Claude Code turn with its own context window.
// Per-turn overhead is ~10-15s (stop hook jq parsing, compact check, prompt injection).
// Larger batches reduce total turns → less overhead → faster overall execution.
const TARGET_BATCH_DURATION_MS = 300_000   // 5 min target per batch (was 3 min)
const MIN_BATCH_SIZE = 1
const MAX_BATCH_SIZE = 50                  // Raised from 20 — each batch has own context
const HARD_BATCH_TIMEOUT_MS = 420_000      // 7 min hard cap per batch (was 4 min)
const MAX_BATCH_ITERATIONS = 50            // Safety cap against infinite re-injection
const MAX_BATCHES_TOTAL = 15               // Cap total batches to prevent 40+ turn sessions
                                           // Override via talisman.testing.batch.max_batches_total

const DEFAULT_AVG_DURATION = {
  unit:        10_000,    // 10s per test file
  integration: 30_000,    // 30s per test file
  e2e:         60_000,    // 60s per route/spec
  contract:    15_000,    // 15s per contract test
  extended:   120_000,    // 2 min per extended scenario
}
```

### Computed Batch Sizes (with new defaults)

| Type | Avg duration | Batch size | Rationale |
|------|-------------|------------|-----------|
| unit | 10s | 30 | 5 min target ÷ 10s = 50, capped at 50 → 30 (practical limit) |
| contract | 15s | 20 | 5 min ÷ 15s = 33, capped at 50 → 20 |
| integration | 30s | 16 | 5 min ÷ 30s = 16 |
| e2e | 60s | 5 | 5 min ÷ 60s = 5 |
| extended | 120s | 2 | 5 min ÷ 120s = 2 |

For thechoice (486 files): ~12 batches instead of ~40.

## Batch Size Formula

```javascript
function computeBatchSize(testType, talisman) {
  // Prefer talisman-configured average; fall back to built-in default
  const avg = talisman?.testing?.batch?.avg_duration?.[testType]
            ?? DEFAULT_AVG_DURATION[testType]

  return Math.max(
    MIN_BATCH_SIZE,
    Math.min(MAX_BATCH_SIZE, Math.floor(TARGET_BATCH_DURATION_MS / avg))
  )
}
```

### Example Computed Batch Sizes (defaults)

| Type | Avg duration | Batch size |
|------|-------------|------------|
| unit | 10s | 18 |
| contract | 15s | 12 |
| integration | 30s | 6 |
| e2e | 60s | 3 |
| extended | 120s | 1 |

Override via `talisman.testing.batch.avg_duration.<type>` (integer, milliseconds).

## Testing Plan Generator

`generateTestingPlan()` builds the ordered batch list from discovered tests.

```javascript
function generateTestingPlan(id, talisman, context) {
  // 1. Discover tests per tier using existing discovery functions
  const unitFiles        = discoverUnitTests(context.diffFiles)
  const integFiles       = discoverIntegrationTests(context.diffFiles)
  const e2eRoutes        = discoverE2ERoutes(context.diffFiles)
  const contractFiles    = discoverContractTests(context.diffFiles)   // optional
  const extendedScenarios = discoverExtendedScenarios()               // optional

  // 2. Compute batch sizes
  const batchSizes = {
    unit:        computeBatchSize("unit",        talisman),
    integration: computeBatchSize("integration", talisman),
    e2e:         computeBatchSize("e2e",         talisman),
    contract:    computeBatchSize("contract",    talisman),
    extended:    computeBatchSize("extended",    talisman),
  }

  // 3. Component-aware batching: split files by component THEN by chunk size.
  //
  // WHY: Monorepos (e.g., backend/ + dashboard/) have different test runners
  // (pytest vs vitest vs playwright), different working directories, and different
  // dependency setups. Running backend and frontend tests in the same batch causes
  // confusion and errors. Splitting by component ensures each batch agent knows
  // exactly which test runner to use and which directory to operate in.
  //
  // For large test suites (400+ files), this also prevents context exhaustion —
  // each batch runs as a separate foreground agent with its own context window.
  //
  // Component detection heuristic:
  //   - Files matching known component directories (backend/, frontend/, dashboard/,
  //     admin/, api/, web/, server/, client/, packages/*/) get grouped by component.
  //   - Files not matching any component pattern go into a "root" group.
  //   - Configurable via talisman.testing.batch.component_dirs (string[]).
  //
  // Batch ordering: fast-first strategy
  //   backend-unit → frontend-unit → backend-contract → backend-integration → frontend-e2e → extended
  //   This gives early feedback on unit tests before slow integration/e2e batches.

  const COMPONENT_PATTERNS = talisman?.testing?.batch?.component_dirs ?? [
    "backend", "frontend", "dashboard", "admin", "api", "web",
    "server", "client", "app", "mobile", "packages"
  ]

  function detectComponent(filePath) {
    const parts = filePath.split("/")
    for (const part of parts) {
      if (COMPONENT_PATTERNS.includes(part)) return part
    }
    // Check for packages/*/... monorepo pattern
    const packagesMatch = filePath.match(/^packages\/([^/]+)\//)
    if (packagesMatch) return `packages/${packagesMatch[1]}`
    return "root"
  }

  function splitByComponent(files) {
    const groups = {}
    for (const file of files) {
      const component = detectComponent(file)
      if (!groups[component]) groups[component] = []
      groups[component].push(file)
    }
    // Sort components: "root" last, others alphabetically (stable ordering for reproducibility)
    return Object.entries(groups).sort(([a], [b]) => {
      if (a === "root") return 1
      if (b === "root") return -1
      return a.localeCompare(b)
    })
  }

  const batches = []
  let batchId = 0

  for (const [type, files] of [
    ["unit",        unitFiles],
    ["contract",    contractFiles],
    ["integration", integFiles],
    ["e2e",         e2eRoutes],
    ["extended",    extendedScenarios],
  ]) {
    // Empty tiers produce zero batches — no empty placeholder batches
    if (!files || files.length === 0) continue

    const size = batchSizes[type]
    const avgDuration = talisman?.testing?.batch?.avg_duration?.[type]
                      ?? DEFAULT_AVG_DURATION[type]

    // Split by component first, then chunk each component group
    const componentGroups = splitByComponent(files)

    for (const [component, componentFiles] of componentGroups) {
      for (let i = 0; i < componentFiles.length; i += size) {
        const slice = componentFiles.slice(i, i + size)
        const chunkIndex = Math.floor(i / size) + 1
        const totalChunks = Math.ceil(componentFiles.length / size)

        batches.push({
          id:               batchId++,
          type,
          component,        // NEW: which component this batch belongs to
          files:            slice,
          label:            `${component}-${type}${totalChunks > 1 ? `-${chunkIndex}/${totalChunks}` : ""}`,
          prompt_context:   buildBatchPromptContext(type, slice, context),
          expected_behavior: describeExpectedBehavior(type, slice),
          pass_criteria:    buildPassCriteria(type, talisman),
          status:           "pending",
          fix_attempts:     0,
          started_at:       null,
          completed_at:     null,
          result_path:      null,
          skip_reason:      null,
          estimated_duration_ms: slice.length * avgDuration,
        })
      }
    }
  }

  // 3.5. Batch count cap — merge smallest batches if total exceeds MAX_BATCHES_TOTAL.
  // Each batch = 1 stop hook turn (~10-15s overhead). 40 batches = 10+ minutes of pure overhead.
  // When over the cap, merge the smallest same-type batches until under the limit.
  const maxBatchesTotal = talisman?.testing?.batch?.max_batches_total ?? MAX_BATCHES_TOTAL
  while (batches.length > maxBatchesTotal) {
    // Find the smallest batch (by file count) and merge it into its neighbor
    let smallestIdx = -1
    let smallestSize = Infinity
    for (let i = 0; i < batches.length; i++) {
      if (batches[i].files.length < smallestSize) {
        smallestSize = batches[i].files.length
        smallestIdx = i
      }
    }
    if (smallestIdx < 0) break  // Safety — shouldn't happen

    // Find a neighbor with same type+component to merge into (prefer same component)
    let mergeTarget = -1
    // First pass: same type AND same component
    for (let i = 0; i < batches.length; i++) {
      if (i === smallestIdx) continue
      if (batches[i].type === batches[smallestIdx].type &&
          batches[i].component === batches[smallestIdx].component) {
        mergeTarget = i
        break
      }
    }
    // Second pass: same type only (cross-component merge as last resort)
    if (mergeTarget < 0) {
      for (let i = 0; i < batches.length; i++) {
        if (i === smallestIdx) continue
        if (batches[i].type === batches[smallestIdx].type) {
          mergeTarget = i
          break
        }
      }
    }
    if (mergeTarget < 0) break  // No merge target found — can't reduce further

    // Merge smallest into target
    batches[mergeTarget].files.push(...batches[smallestIdx].files)
    batches[mergeTarget].estimated_duration_ms += batches[smallestIdx].estimated_duration_ms
    batches[mergeTarget].label = `${batches[mergeTarget].component}-${batches[mergeTarget].type}` +
      (batches[mergeTarget].component !== batches[smallestIdx].component ? '+' : '')
    batches.splice(smallestIdx, 1)
  }

  // Re-index batch IDs after merging (IDs must be sequential for stop hook)
  for (let i = 0; i < batches.length; i++) {
    batches[i].id = i
  }

  // 4. Build the plan document
  const plan = {
    version:            1,
    arc_id:             id,
    created_at:         new Date().toISOString(),
    config: {
      max_fix_retries:        talisman?.testing?.batch?.max_fix_retries ?? 2,
      inter_batch_delay_ms:   talisman?.testing?.batch?.inter_batch_delay_ms ?? 5_000,
      hard_batch_timeout_ms:  HARD_BATCH_TIMEOUT_MS,
      max_batch_iterations:   MAX_BATCH_ITERATIONS,
    },
    summary: {
      total_batches: batches.length,
      completed: 0,
      failed: 0,
      skipped: 0,
    },
    batches,
  }

  // 5. Write plan to disk (plan.json IS the checkpoint)
  writeCheckpoint(id, plan)
  Write(`tmp/arc/${id}/testing-plan.md`, renderTestingPlanMarkdown(plan))

  return plan
}
```

## Batch Executor (State Machine)

Core execution loop. Each batch runs in a foreground Agent with its own TaskCreate.

```javascript
function executeBatchingPlan(id, plan, remainingBudget) {
  let iterationCount = 0
  const maxIterations = plan.config.max_batch_iterations ?? MAX_BATCH_ITERATIONS

  for (const batch of plan.batches) {
    // 0. Safety cap — prevent infinite re-injection
    if (iterationCount >= maxIterations) {
      warn(`Batch executor reached max_batch_iterations (${maxIterations}). Stopping.`)
      break
    }
    iterationCount++

    // 1. Skip already-terminal batches (idempotent resume)
    if (batch.status === "passed" || batch.status === "failed") continue
    if (batch.status === "skipped") continue

    // 2. Budget check — skip remaining if budget exhausted
    if (remainingBudget() <= 0) {
      markBatchSkipped(plan, batch, "skipped_budget_exhausted")
      continue
    }

    // 3. Mark batch as running
    batch.status = "running"
    batch.started_at = new Date().toISOString()
    writeCheckpoint(id, plan)

    // 4. TEAM-002: TaskCreate BEFORE Agent() — required for waitForCompletion
    const taskId = TaskCreate({
      subject:       `Test batch ${batch.id}: ${batch.type} (${batch.files.length} files)`,
      description: batch.prompt_context,
      status:      "pending",
    })

    // 5. Spawn foreground agent — run_in_background: false
    //    team_name is REQUIRED (Iron Law TEAM-001)
    const batchStartTime = Date.now()
    const result = Agent({
      subagent_type:     resolveRunnerAgentType(batch.type),
      team_name:         `arc-test-${id}`,
      run_in_background: false,
      prompt:            buildRunnerPrompt(batch, taskId, plan.config),
    })

    // 5a. Enforce hard batch timeout — if agent took too long, mark failed
    const batchElapsed = Date.now() - batchStartTime
    if (batchElapsed > plan.config.hard_batch_timeout_ms) {
      warn(`Batch ${batch.id} exceeded hard timeout (${batchElapsed}ms > ${plan.config.hard_batch_timeout_ms}ms)`)
      batch.status = "failed"
      batch.completed_at = new Date().toISOString()
      batch.skip_reason = "hard_timeout_exceeded"
      plan.summary.completed += 1
      plan.summary.failed += 1
      writeCheckpoint(id, plan)
      continue
    }

    // 5b. Resolve result path — runner writes to convention-based path
    batch.result_path = `tmp/arc/${id}/test-results-${batch.type}-batch-${batch.id}.md`

    // 6. Read result and classify pass/fail
    // Structured classification: result must exist AND contain STATUS: PASS marker.
    // Empty/missing result = agent crash = treated as FAIL (not false-positive PASS).
    const resultContent = exists(batch.result_path) ? Read(batch.result_path) : ""
    let passed = resultContent.length > 0
      && resultContent.includes("<!-- STATUS: PASS -->")

    // 7. Fix loop — up to max_fix_retries on failure
    let fixAttempts = 0
    const maxFixes = plan.config.max_fix_retries

    while (!passed && fixAttempts < maxFixes) {
      batch.status = "fixing"
      batch.fix_attempts = ++fixAttempts
      writeCheckpoint(id, plan)

      const fixTaskId = TaskCreate({
        subject:       `Fix batch ${batch.id} attempt ${fixAttempts}`,
        description: buildFixPromptContext(batch, result),
        status:      "pending",
      })

      const fixResult = Agent({
        subagent_type:     "rune:work:rune-smith",
        team_name:         `arc-test-${id}`,
        run_in_background: false,
        prompt:            buildFixPrompt(batch, result, fixTaskId, fixAttempts),
      })

      // Re-run the batch after the fix (reuse same tier-specific runner)
      const rerunTaskId = TaskCreate({
        subject:       `Rerun batch ${batch.id} after fix ${fixAttempts}`,
        description: `Re-execute ${batch.type} tests: ${batch.files.join(', ')}`,
        status:      "pending",
      })
      Agent({
        subagent_type:     resolveRunnerAgentType(batch.type),
        team_name:         `arc-test-${id}`,
        run_in_background: false,
        prompt:            buildRunnerPrompt(batch, rerunTaskId, plan.config),
      })
      const rerunContent = exists(batch.result_path) ? Read(batch.result_path) : ""
      passed = rerunContent.length > 0
        && rerunContent.includes("<!-- STATUS: PASS -->")
      if (passed) break
    }

    // 8. Update final status
    batch.status      = passed ? "passed" : "failed"
    batch.completed_at = new Date().toISOString()
    plan.summary.completed += 1
    if (!passed) plan.summary.failed += 1
    writeCheckpoint(id, plan)

    // 9. Inter-batch delay — configurable, avoids resource contention
    const delay = plan.config.inter_batch_delay_ms
    if (delay > 0) Bash(`sleep ${Math.ceil(delay / 1000)}`)
  }

  return plan
}
```

### Runner Agent Type Resolution

All test runners use `general-purpose` as the subagent type. Testing-specific behavior
(frameworks, assertions, reporting) is injected via prompt from `registry/testing/` agent
definition files — not via custom subagent types.

```javascript
// Testing agent frameworks are injected via prompt from registry/testing/*.md files.
// All runners use general-purpose — there are no registered rune:testing:* agent types.
function resolveRunnerAgentType(batchType) {
  return "general-purpose"
}
```

| Batch type | Agent type | Prompt source |
|-----------|-----------|---------------|
| `unit` | `general-purpose` | `registry/testing/unit-test-runner.md` |
| `contract` | `general-purpose` | `registry/testing/contract-validator.md` |
| `integration` | `general-purpose` | `registry/testing/integration-test-runner.md` |
| `e2e` | `general-purpose` | `registry/testing/e2e-browser-tester.md` |
| `extended` | `general-purpose` | `registry/testing/extended-test-runner.md` |

## Checkpoint System

The `testing-plan.json` file is both the plan and the checkpoint. No separate checkpoint file.

### Atomic Write

```javascript
function writeCheckpoint(id, plan) {
  const tmpPath   = `tmp/arc/${id}/testing-plan.tmp.json`
  const finalPath = `tmp/arc/${id}/testing-plan.json`

  // 1. Write to temp file
  Write(tmpPath, JSON.stringify(plan, null, 2))

  // 2. Atomic rename — mv is atomic on the same filesystem
  Bash(`mv "${tmpPath}" "${finalPath}"`)
}
```

### Read Checkpoint

```javascript
function readCheckpoint(id) {
  const path = `tmp/arc/${id}/testing-plan.json`
  try {
    const raw = Read(path)
    return JSON.parse(raw)
  } catch (e) {
    return null  // No checkpoint — start fresh
  }
}
```

### Resume Logic

When resuming after a crash or context compaction:

```javascript
function resumeOrCreate(id, talisman, context) {
  const checkpoint = readCheckpoint(id)

  if (!checkpoint) {
    // No checkpoint — generate fresh plan
    return generateTestingPlan(id, talisman, context)
  }

  // Repair in-progress batches: reset to pending so they re-execute
  for (const batch of checkpoint.batches) {
    if (batch.status === "running" || batch.status === "fixing") {
      batch.status    = "pending"
      batch.started_at = null
    }
  }

  // Recalculate summary from batch states
  checkpoint.summary.completed = checkpoint.batches.filter(
    b => b.status === "passed" || b.status === "failed"
  ).length
  checkpoint.summary.failed = checkpoint.batches.filter(
    b => b.status === "failed"
  ).length
  checkpoint.summary.skipped = checkpoint.batches.filter(
    b => b.status === "skipped"
  ).length

  writeCheckpoint(id, checkpoint)
  return checkpoint
}
```

**Key rules:**
- `completed` / `failed` / `skipped` batches are skipped on resume (idempotent)
- `running` / `fixing` batches reset to `pending` — they re-execute from scratch
- The `max_batch_iterations` counter resets on resume (fresh iteration cap per execution)

## Rendering

```javascript
function renderTestingPlanMarkdown(plan) {
  const STATUS_ICONS = {
    passed:   "[x]",
    failed:   "[!]",
    running:  "[>]",
    fixing:   "[~]",
    pending:  "[ ]",
    skipped:  "[-]",
  }

  const lines = [
    `# Testing Plan — ${plan.arc_id}`,
    `Created: ${plan.created_at}`,
    "",
    "## Batches",
    "",
    "| # | Status | Type | Files | Est. Duration |",
    "|---|--------|------|-------|--------------|",
  ]

  for (const batch of plan.batches) {
    const icon     = STATUS_ICONS[batch.status] ?? "[ ]"
    const fileCount = batch.files.length
    const estMs    = batch.estimated_duration_ms
    const estSec   = Math.round(estMs / 1000)

    lines.push(
      `| ${batch.id} | ${icon} ${batch.status} | ${batch.type} | ${fileCount} | ~${estSec}s |`
    )
  }

  // Summary line
  const s = plan.summary
  const remaining = s.total_batches - s.completed - s.skipped
  lines.push("")
  lines.push(
    `**Summary**: ${s.completed - s.failed} passed · ${s.failed} failed ` +
    `· ${s.skipped} skipped · ${remaining} remaining`
  )

  // Fix attempt callouts
  const fixedBatches = plan.batches.filter(b => b.fix_attempts > 0)
  if (fixedBatches.length > 0) {
    lines.push("")
    lines.push("## Fix Attempts")
    for (const b of fixedBatches) {
      lines.push(`- Batch ${b.id} (${b.type}): ${b.fix_attempts} fix attempt(s) — final: ${b.status}`)
    }
  }

  return lines.join("\n")
}
```

## Talisman Configuration

```yaml
testing:
  batch:
    max_fix_retries: 2             # Max fix loops per failed batch
    inter_batch_delay_ms: 5000     # Pause between batches (ms)
    avg_duration:                  # Override per-type average test duration
      unit: 10000                  # 10s (default)
      integration: 30000           # 30s (default)
      e2e: 60000                   # 60s (default)
      contract: 15000              # 15s (default)
      extended: 120000             # 2 min (default)
```

All keys have defaults matching the constants at the top of this file. Override only when
your project's actual test durations differ significantly from the defaults.
