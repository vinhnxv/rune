# Main Execution Loop

Iterates through child plans in topological order, executing each via `/rune:arc`. Handles prerequisite verification, child branch management, execution table updates, provides verification, merge to parent, and completion marking.

**Inputs**: `planPath`, `executionTable`, `contractMatrix`, `featureBranch`, `noMerge` flag, `stateFile`
**Outputs**: Updated execution table in parent plan, merged child branches, JSON sidecar file
**Preconditions**: Phases 0-6 complete (parsed, validated, state file written, feature branch created)

## Loop Structure

```javascript
let iteration = 0
const MAX_ITERATIONS = executionTable.length + 10  // Safety cap
// BACK-016 FIX: Track per-child prerequisite failure counts for cycle detection
const prereqFailureCounts = {}

while (true) {
  iteration++
  if (iteration > MAX_ITERATIONS) {
    error(`Safety cap reached (${MAX_ITERATIONS} iterations). Possible infinite loop. Aborting.`)
    break
  }

  // Re-read plan to get fresh execution table state
  const freshContent = Read(planPath)
  const freshTable = parseExecutionTable(freshContent)

  const next = findNextExecutable(freshTable)
  if (!next) {
    const allDone = freshTable.every(e => ["completed", "failed", "skipped"].includes(e.status))
    if (allDone) {
      log("All children have terminal status. Execution complete.")
    } else {
      const blocked = freshTable.filter(e => e.status === "pending")
      warn(`No executable children found. ${blocked.length} children remain blocked (circular dependency or failed predecessor).`)
      for (const b of blocked) {
        warn(`  Blocked: [${b.seq}] ${b.path} (deps: ${b.dependencies.join(", ")})`)
      }
    }
    break
  }

  log(`\n── Executing child [${next.seq}]: ${next.path} ──`)
```

## Phase 7a: Verify Prerequisites (requires contracts)

```javascript
  // See prerequisite-verification.md for full pseudocode
  const prereqResult = verifyPrerequisites(next, contractMatrix)
  if (!prereqResult.passed) {
    // BACK-016 FIX: Track per-child failure counts for cycle detection
    prereqFailureCounts[next.seq] = (prereqFailureCounts[next.seq] || 0) + 1
    if (prereqFailureCounts[next.seq] > 2) {
      warn(`Child [${next.seq}] has failed prerequisites ${prereqFailureCounts[next.seq]} times. Automated recovery exhausted.`)
      error("Execution paused. Fix prerequisites manually and run /rune:arc-hierarchy --resume")
      break
    }

    const resolution = await handlePrerequisiteFailure(next, prereqResult, contractMatrix, planPath)
    if (resolution === "abort") break
    if (resolution === "skip") {
      const updated = updateExecutionTable(Read(planPath), next.seq, { status: "skipped" })
      Write(planPath, updated)
      continue
    }
    // resolution === "retry" — loop continues (BACK-005/006: child reset to pending by handler)
    continue
  }
```

## Phase 7b: Create Child Branch

```javascript
  const childBranch = createChildBranch(featureBranch, next.seq, next.path.split("/").pop().replace(".md", ""))
```

## Phase 7c: Update Table to in_progress

```javascript
  // QUAL-004 FIX: underscore, not hyphen
  let updatedContent = updateExecutionTable(Read(planPath), next.seq, {
    status: "in_progress",
    started: new Date().toISOString()
  })
  Write(planPath, updatedContent)

  // Phase 7c.1: Update state file with current child info for stop hook (BACK-008 FIX)
  const childFilename = next.path.split("/").pop()
  const stateContent = Read(stateFile)
  const updatedState = stateContent
    .replace(/^current_child:.*$/m, `current_child: ${childFilename}`)
    .replace(/^feature_branch:.*$/m, `feature_branch: ${featureBranch}`)
    .replace(/^execution_table_path:.*$/m, `execution_table_path: ${planPath}`)
  Write(stateFile, updatedState)

  // Phase 7c.2: Write JSON sidecar for stop hook execution table parsing (BACK-009 FIX)
  // The stop hook uses jq for topological sort — it needs JSON, not the Markdown table.
  // This sidecar is the machine-readable version; the Markdown table in the plan is human-readable.
  const jsonTable = {
    updated_at: new Date().toISOString(),
    children: parseExecutionTable(Read(planPath)).map(e => ({
      seq: e.seq,
      plan: e.path.split("/").pop(),
      status: e.status,
      depends_on: e.dependencies,
      started_at: e.started,
      completed_at: e.completed,
      provides: (contractMatrix.find(c => c.child === extractChildId(e.path))?.provides || [])
        .map(a => `${a.name}`)
    }))
  }
  Write(".claude/arc-hierarchy-exec-table.json", JSON.stringify(jsonTable, null, 2))
```

## Phase 7d: Invoke Arc for Child Plan

```javascript
  // ARC-BATCH-001 FIX: Use "rune:arc" prefix for reliable plugin skill resolution.
  const mergeFlag = noMerge ? " --no-merge" : ""
  Skill("rune:arc", `${next.path}${mergeFlag}`)

  // CRITICAL — SKILL INVOCATION REQUIRED:
  // - /rune:arc is a SKILL. You MUST call it via the Skill tool.
  // - DO NOT implement the plan code directly. DO NOT skip to coding.
  // - Only the arc skill should orchestrate execution.
```

## Phase 7e: Verify Provides Contracts

```javascript
  const providesResult = verifyProvides(next, contractMatrix)
  if (!providesResult.passed) {
    warn(`Child [${next.seq}] completed but provides verification failed:`)
    for (const failure of providesResult.failures) {
      warn(`  MISSING: ${failure.type}:${failure.name} — ${failure.reason}`)
    }

    // Mark as partial — does not unblock dependents (BUG-1)
    updatedContent = updateExecutionTable(Read(planPath), next.seq, {
      status: "partial",
      completed: new Date().toISOString()
    })
    Write(planPath, updatedContent)

    // BACK-003 FIX: Capture response and implement all 4 branches
    const providesChoice = AskUserQuestion({
      questions: [{
        question: `Child [${next.seq}] has ${providesResult.failures.length} missing provides. How to proceed?`,
        header: "Provides Verification Failed",
        options: [
          { label: "Mark as completed anyway", description: "Unblocks dependent children (risky)" },
          { label: "Re-run child arc", description: "Try to fix the missing artifacts" },
          { label: "Skip dependents", description: "Mark dependent children as skipped" },
          { label: "Abort hierarchy", description: "Stop execution here" }
        ],
        multiSelect: false
      }]
    })

    if (providesChoice === "Mark as completed anyway") {
      updatedContent = updateExecutionTable(Read(planPath), next.seq, {
        status: "completed",
        completed: new Date().toISOString()
      })
      Write(planPath, updatedContent)
      warn(`Child [${next.seq}] force-marked as completed despite missing provides.`)
      continue
    } else if (providesChoice === "Re-run child arc") {
      // Reset to pending so it gets picked up again
      updatedContent = updateExecutionTable(Read(planPath), next.seq, {
        status: "pending",
        started: "—",
        completed: "—"
      })
      Write(planPath, updatedContent)
      continue
    } else if (providesChoice === "Skip dependents") {
      // Find all children that depend on this child and mark them skipped
      const freshTable = parseExecutionTable(Read(planPath))
      for (const entry of freshTable) {
        if (entry.dependencies.some(d => normalizeSeq(d) === normalizeSeq(next.seq))) {
          const skipUpdate = updateExecutionTable(Read(planPath), entry.seq, { status: "skipped" })
          Write(planPath, skipUpdate)
          warn(`Skipped dependent child [${entry.seq}]: ${entry.path}`)
        }
      }
      continue
    } else {
      // "Abort hierarchy" or any other response
      error("Hierarchy execution aborted by user due to provides verification failure.")
      break
    }
  }
```

## Phase 7f: Merge Child Branch to Feature Branch

```javascript
  mergeChildToFeature(childBranch, featureBranch)
```

## Phase 7g: Mark Completed in Execution Table

```javascript
  updatedContent = updateExecutionTable(Read(planPath), next.seq, {
    status: "completed",
    completed: new Date().toISOString()
  })
  Write(planPath, updatedContent)

  log(`Child [${next.seq}] completed successfully.`)
}
```
