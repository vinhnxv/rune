# Post-Arc: Plan Completion Stamp — Full Algorithm

Appends a persistent completion record to the plan file after arc finishes. Updates the plan's Status field. Creates an audit trail of arc executions.

**Team**: None (orchestrator-only, runs after Phase 9.5 MERGE or Phase 7.7 TEST if ship/merge skipped)
**Tools**: Read, Write, Bash (git queries)
**Timeout**: 30 seconds (fast — single file read+write)

**Inputs**: checkpoint (object, from .claude/arc/{id}/checkpoint.json), branch name (from checkpoint or git)
**Outputs**: Updated plan file with Status field + appended Completion Record
**Preconditions**: Arc pipeline has finished (all phases completed, skipped, or failed). Plan file exists on disk.
**Error handling**: Plan file not found → warn + skip. Write fails → warn + skip (read-only file or permission error). No completed phases → skip stamp.

**Consumers**: SKILL.md (post-completion stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Algorithm

```javascript
// STEP 1: Validate plan path (defense-in-depth — arc init already validates)
const planPath = checkpoint.plan_file
if (!planPath || !/^[a-zA-Z0-9._\/-]+$/.test(planPath) || planPath.includes('..')) {
  warn(`Invalid plan path in checkpoint: ${planPath}`)
  return
}
if (planPath.startsWith('/')) {
  warn(`Absolute path not allowed: ${planPath}`)
  return
}
if (!exists(planPath)) {
  warn("Plan file not found — skipping completion stamp")
  return
}

// STEP 2: Guard — skip if no phases completed
const hasAnyCompleted = Object.values(checkpoint.phases)
  .some(p => p.status === "completed")
if (!hasAnyCompleted) {
  warn("Arc has no completed phases — skipping completion stamp")
  return
}

// STEP 3: Determine overall status
// NOTE: p.status below is pseudocode property access (safe in JS).
// Shell variable names use tstat (line 117) per zsh compatibility rule.
const allCompleted = Object.values(checkpoint.phases)
  .every(p => p.status === "completed" || p.status === "skipped")
const anyFailed = Object.values(checkpoint.phases)
  .some(p => p.status === "failed" || p.status === "timeout")
const newStatus = allCompleted ? "Completed" : anyFailed ? "Failed" : "Partial"

// STEP 4: Read plan content
let content = Read(planPath)

// STEP 5: Update Status field (if present in first 50 lines)
// Limit search to first 50 lines to avoid false matches in previously appended records
const lines = content.split('\n')
const first50 = lines.slice(0, 50).join('\n')
if (first50.includes("**Status**:")) {
  // Find and replace only in the first 50 lines
  const statusLine = lines.findIndex((l, i) => i < 50 && l.includes("**Status**:"))
  if (statusLine !== -1) {
    lines[statusLine] = lines[statusLine].replace(/\*\*Status\*\*: \w+/, `**Status**: ${newStatus}`)
    content = lines.join('\n')
  }
}

// STEP 6: Build completion record
const record = buildCompletionRecord(checkpoint, newStatus, content)

// STEP 7: Append record (single atomic write)
content += "\n\n---\n\n" + record

// STEP 8: Write updated content
try {
  Write(planPath, content)
} catch (err) {
  warn(`Failed to write completion stamp to ${planPath}: ${err.message}`)
}

```

## buildCompletionRecord()

Formats checkpoint data into a markdown completion record.
**Params**: checkpoint (object), newStatus (string), content (string — pre-loaded plan content).
**Returns**: string (markdown completion record).
NOTE: Calls Bash() for git branch fallback — not side-effect-free.

```javascript
function buildCompletionRecord(checkpoint, newStatus, content) {
  const completedAt = new Date().toISOString()
  const startedAt = checkpoint.started_at ? Date.parse(checkpoint.started_at) : Date.now()
  const duration = isNaN(startedAt) ? 0 : Math.max(0, Math.round((Date.now() - startedAt) / 60000))

  // Use branch from checkpoint or fall back to current branch
  // Prefer checkpoint data over live git query (branch may have changed during arc)
  const rawBranch = Bash("git branch --show-current 2>/dev/null").trim() || "unknown"
  const branch = /^[a-zA-Z0-9._\/-]+$/.test(rawBranch) ? rawBranch : "unknown"

  // Count existing completion records for run ordinal
  const existingRecords = (content.match(/## Arc Completion Record/g) || []).length

  // Phase results table
  // Phase table dynamically matches PHASE_ORDER (29 phases, v1.155.0+)
  // WARNING: Order follows PHASE_ORDER (execution order), NOT numeric phase IDs.
  // Phase 5.8 (GAP REMEDIATION) executes before Phase 5.7 (GOLDMASK VERIFICATION).
  const phases = [
    ['1',    'FORGE',                  'forge'],
    ['2',    'PLAN REVIEW',            'plan_review'],
    ['2.5',  'PLAN REFINEMENT',        'plan_refine'],
    ['2.7',  'VERIFICATION',           'verification'],
    ['2.8',  'SEMANTIC VERIFICATION',  'semantic_verification'],
    ['3',    'DESIGN EXTRACTION',      'design_extraction'],
    ['3.2',  'DESIGN PROTOTYPE',       'design_prototype'],
    ['4.5',  'TASK DECOMPOSITION',     'task_decomposition'],
    ['5',    'WORK',                   'work'],
    ['3.3',  'STORYBOOK VERIFICATION', 'storybook_verification'],
    ['5.2',  'DESIGN VERIFICATION',    'design_verification'],
    ['5.3',  'UX VERIFICATION',        'ux_verification'],
    ['5.5',  'GAP ANALYSIS',           'gap_analysis'],
    ['5.6',  'CODEX GAP ANALYSIS',     'codex_gap_analysis'],
    ['5.8',  'GAP REMEDIATION',        'gap_remediation'],
    ['5.7',  'GOLDMASK VERIFICATION',  'goldmask_verification'],
    ['6',    'CODE REVIEW (deep)',      'code_review'],
    ['6.5',  'GOLDMASK CORRELATION',   'goldmask_correlation'],
    ['7',    'MEND',                   'mend'],
    ['7.5',  'VERIFY MEND',            'verify_mend'],
    ['7.6',  'DESIGN ITERATION',       'design_iteration'],
    ['7.7',  'TEST',                   'test'],
    ['7.8',  'TEST COVERAGE CRITIQUE', 'test_coverage_critique'],
    ['8',    'PRE-SHIP VALIDATION',    'pre_ship_validation'],
    ['8.55', 'RELEASE QUALITY CHECK',  'release_quality_check'],
    ['9',    'SHIP',                   'ship'],
    ['9.1',  'BOT REVIEW WAIT',        'bot_review_wait'],
    ['9.2',  'PR COMMENT RESOLUTION',  'pr_comment_resolution'],
    ['9.5',  'MERGE',                  'merge'],
  ]

  let phaseTable = "| # | Phase | Status | Detail |\n|---|-------|--------|--------|\n"
  for (const [num, name, key] of phases) {
    const phase = checkpoint.phases[key]
    const tstat = phase?.status || "pending"  // tstat not status — zsh read-only var (CLAUDE.md rule 8)
    const detail = phase?.artifact ? phase.artifact.split('/').pop() : "—"
    phaseTable += `| ${num} | ${name} | ${tstat} | ${detail} |\n`
  }

  // Convergence history
  let convergenceSection = ""
  const history = checkpoint.convergence?.history || []
  if (history.length > 0) {
    // BACK-009 FIX: history.length is already the pass count (each entry = 1 pass). +1 was off-by-one.
    convergenceSection = `### Convergence\n\n- ${history.length} mend pass(es)\n`
    for (const entry of history) {
      let roundLine = `- Round ${entry.round}: ${entry.findings_before} → ${entry.findings_after} findings (${entry.verdict})`
      // v1.38.0: Include smart convergence score when available
      if (entry.convergence_score?.total != null) {
        roundLine += ` [score: ${entry.convergence_score.total}]`
      }
      convergenceSection += roundLine + `\n`
    }
    // v1.38.0: Include final convergence score breakdown if available
    const lastEntry = history[history.length - 1]
    if (lastEntry?.convergence_score?.components) {
      const c = lastEntry.convergence_score.components
      convergenceSection += `- Smart scoring: P3=${c.p3}, pre-existing=${c.preExisting}, trend=${c.trend}, base=${c.base}\n`
    }
  } else {
    convergenceSection = `### Convergence\n\n- 1 mend pass (no retries needed)\n`
  }

  // Summary
  const commitCount = (checkpoint.commits || []).length
  const runOrdinal = existingRecords + 1

  // PR URL (v1.40.0: from Phase 9 SHIP)
  const prUrl = checkpoint.pr_url || null

  return `## Arc Completion Record — Run ${runOrdinal}\n\n` +
    `**Completed at**: ${completedAt}\n` +
    `**Duration**: ${duration} min\n` +
    `**Arc ID**: ${checkpoint.id}\n` +
    `**Branch**: ${branch}\n` +
    (prUrl ? `**PR**: ${prUrl}\n` : '') +
    `**Checkpoint**: .claude/arc/${checkpoint.id}/checkpoint.json\n\n` +
    `### Phase Results\n\n` +
    phaseTable + `\n` +
    convergenceSection + `\n` +
    `### Summary\n\n` +
    `- **Commits**: ${commitCount} on branch \`${branch}\`\n` +
    (prUrl ? `- **PR**: ${prUrl}\n` : '') +
    `- **Overall status**: ${newStatus}\n`
}
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Plan file deleted during arc | Skip stamp, log warning (STEP 1) |
| Plan has no `**Status**:` field | Skip Status update, still append record (STEP 5) |
| Plan already has a Completion Record (re-run) | Append a NEW record with incremented run ordinal |
| Arc halted mid-pipeline (timeout/failure) | Still stamp with `Partial` or `Failed` status |
| All phases skipped (no completed phases) | Skip stamp entirely (STEP 2 guard) |
| Read-only file or write permission error | Warn + skip (STEP 8 try-catch) |
| Plan path tampered in checkpoint | Reject with warning (STEP 1 validation) |
| Concurrent arc runs on same plan | Last-write-wins — earlier records may be lost. Arc pre-flight prevents concurrent sessions. |
| Multiple Status fields in first 50 lines | Updates FIRST match only (via `findIndex()`). Low-risk — plans rarely have duplicate Status fields. |
| Completion record heading in plan body (e.g. code example) | Ordinal may increment incorrectly. Low risk — unusual case. Consider anchoring regex: `/^## Arc Completion Record/gm` (line-start anchor). |
