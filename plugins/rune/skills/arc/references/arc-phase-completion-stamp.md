# Post-Arc: Plan Completion Stamp — Full Algorithm

Appends a persistent completion record to the plan file after arc finishes. Updates the plan's Status field. Creates an audit trail of arc executions.

**Team**: None (orchestrator-only, runs after Phase 9.5 MERGE or Phase 7.7 TEST if ship/merge skipped)
**Tools**: Read, Write, Bash (git queries)
**Timeout**: 30 seconds (fast — single file read+write)

**Inputs**: checkpoint (object, from .rune/arc/{id}/checkpoint.json), branch name (from checkpoint or git)
**Outputs**: Updated plan file with Status field + appended Completion Record
**Preconditions**: Arc pipeline has finished (all phases completed, skipped, or failed). Plan file exists on disk.
**Error handling**: Plan file not found → warn + skip. Write fails → warn + skip (read-only file or permission error). No completed phases → skip stamp.

**Consumers**: SKILL.md (post-completion stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Algorithm

```javascript
// STEP 1: Validate plan path (defense-in-depth — arc init already validates)
let planPath = checkpoint.plan_file
const checkpointPath = `.rune/arc/${checkpoint.id}/checkpoint.json`
if (!planPath || !/^[a-zA-Z0-9._\/-]+$/.test(planPath) || planPath.includes('..')) {
  warn(`Invalid plan path in checkpoint: ${planPath}`)
  return
}
if (planPath.startsWith('/')) {
  warn(`Absolute path not allowed: ${planPath}`)
  return
}
if (!exists(planPath)) {
  // STEP 1.5: Plan file relocation search
  // If plan not found at checkpoint path, search known subdirectories by basename.
  // Users frequently move plans to archived/, deleted/, skip/, defer/, shattering/.
  const basename = planPath.split('/').pop()
  if (!basename || !/^[a-zA-Z0-9._-]+\.md$/.test(basename)) {
    warn("Plan file not found and basename invalid — skipping completion stamp")
    return
  }

  // Search known plan subdirectories (ordered by likelihood)
  const PLAN_SEARCH_DIRS = [
    "plans/archived",
    "plans/skip",
    "plans/defer",
    "plans/deleted",
    "plans/shattering",
    "plans"
  ]

  let relocatedPath = null
  const normPlanPath = planPath.replace(/^\.\//, '')
  for (const dir of PLAN_SEARCH_DIRS) {
    const candidate = `${dir}/${basename}`
    if (candidate !== normPlanPath && exists(candidate)) {
      relocatedPath = candidate
      break
    }
  }

  // Glob fallback for deeper nesting (e.g., plans/archived/children/)
  if (!relocatedPath) {
    const globResults = Glob(`plans/**/${basename}`)
    if (globResults.length === 1) {
      relocatedPath = globResults[0]
    } else if (globResults.length > 1) {
      warn(`Plan file found at ${globResults.length} locations — ambiguous relocation, skipping stamp: ${globResults.join(', ')}`)
      return
    }
  }

  if (relocatedPath) {
    warn(`Plan file relocated: ${planPath} → ${relocatedPath}`)
    planPath = relocatedPath
    // Update checkpoint so subsequent consumers (echo persist, etc.) use correct path
    checkpoint.plan_file = relocatedPath
    // Persist checkpoint to disk (AC-7 requires this for --resume cross-session)
    try { Write(checkpointPath, JSON.stringify(checkpoint, null, 2)) } catch (e) { /* non-blocking */ }
  } else {
    warn("Plan file not found at original path or known subdirectories — skipping completion stamp")
    return
  }
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

// STEP 4: Read plan content (try-catch guards TOCTOU with relocation search)
let content
try {
  content = Read(planPath)
} catch (e) {
  warn(`Plan file unreadable after relocation search — skipping stamp: ${e.message}`)
  return
}

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

  // Session identity — read from checkpoint (populated at arc init via SKILL.md preprocessor)
  // CLAUDE_SESSION_ID is NOT available in Bash() context (anthropics/claude-code#25642)
  const sessionId = checkpoint.session_id || "unknown"
  const ownerPid = checkpoint.owner_pid || "unknown"
  // RUNE_SESSION_ID IS available in Bash context (real env var, not preprocessor)
  const runeSessionId = Bash('echo "${RUNE_SESSION_ID:-unknown}"').trim()

  // Plugin version (non-blocking — "unknown" on failure)
  let pluginVersion = "unknown"
  try {
    const pluginJson = JSON.parse(Read("plugins/rune/.claude-plugin/plugin.json"))
    pluginVersion = pluginJson.version ?? "unknown"
  } catch (e) { /* plugin.json unreadable */ }

  // Default branch for quality metrics and diff stats (compute once, reuse)
  // Validate before shell interpolation — prevents command injection if origin/HEAD is malformed
  const rawDefaultBranch = Bash("git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||'").trim() || "main"
  const defaultBranch = /^[a-zA-Z0-9._\/-]+$/.test(rawDefaultBranch) ? rawDefaultBranch : "main"

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
    ['5.1',  'DRIFT REVIEW',           'drift_review'],
    ['3.3',  'STORYBOOK VERIFICATION', 'storybook_verification'],
    ['5.2',  'DESIGN VERIFICATION',    'design_verification'],
    ['5.3',  'UX VERIFICATION',        'ux_verification'],
    ['5.5',  'GAP ANALYSIS',           'gap_analysis'],
    ['5.6',  'CODEX GAP ANALYSIS',     'codex_gap_analysis'],
    ['5.8',  'GAP REMEDIATION',        'gap_remediation'],
    ['5.9',  'INSPECT',                'inspect'],
    ['5.95', 'INSPECT FIX',            'inspect_fix'],
    ['5.99', 'VERIFY INSPECT',         'verify_inspect'],
    ['5.7',  'GOLDMASK VERIFICATION',  'goldmask_verification'],
    ['6',    'CODE REVIEW (deep)',      'code_review'],
    ['6.5',  'GOLDMASK CORRELATION',   'goldmask_correlation'],
    ['7',    'MEND',                   'mend'],
    ['7.5',  'VERIFY MEND',            'verify_mend'],
    ['7.6',  'DESIGN ITERATION',       'design_iteration'],
    ['7.7',  'TEST',                   'test'],
    ['7.8',  'TEST COVERAGE CRITIQUE', 'test_coverage_critique'],
    ['7.9',  'DEPLOY VERIFY',          'deploy_verify'],
    ['8',    'PRE-SHIP VALIDATION',    'pre_ship_validation'],
    ['8.55', 'RELEASE QUALITY CHECK',  'release_quality_check'],
    ['9',    'SHIP',                   'ship'],
    ['9.1',  'BOT REVIEW WAIT',        'bot_review_wait'],
    ['9.2',  'PR COMMENT RESOLUTION',  'pr_comment_resolution'],
    ['9.5',  'MERGE',                  'merge'],
  ]

  let phaseTable = "| # | Phase | Status | Duration | Detail |\n|---|-------|--------|----------|--------|\n"
  for (const [num, name, key] of phases) {
    const phase = checkpoint.phases[key]
    const tstat = phase?.status || "pending"  // tstat not status — zsh read-only var (CLAUDE.md rule 8)
    const detail = phase?.artifact ? phase.artifact.split('/').pop() : "—"
    // Per-phase duration from totals.phase_times (ms → human-readable)
    // Guard against non-numeric values (schema drift) and negative durations (clock skew)
    const rawDuration = checkpoint.totals?.phase_times?.[key]
    const durationMs = (rawDuration != null && Number.isFinite(Number(rawDuration)))
      ? Math.max(0, Number(rawDuration))
      : null
    const durationStr = durationMs != null
      ? (durationMs >= 60000
        ? `${Math.round(durationMs / 60000)}m ${Math.round((durationMs % 60000) / 1000)}s`
        : `${Math.round(durationMs / 1000)}s`)
      : "—"
    phaseTable += `| ${num} | ${name} | ${tstat} | ${durationStr} | ${detail} |\n`
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

  // Quality Metrics (v1.178.0+)
  let qualitySection = "### Quality Metrics\n\n"

  // TOME findings (P1/P2/P3 counts from code review)
  const tomeArtifact = checkpoint.phases.code_review?.artifact
  if (tomeArtifact && !/^\.\./.test(tomeArtifact) && !tomeArtifact.startsWith('/') && exists(tomeArtifact)) {
    const tomeContent = Read(tomeArtifact)
    // Anchor regex to finding ID prefix to avoid false matches in headers/code blocks
    const findingLines = tomeContent.split('\n').filter(l => /^\|\s*[A-Z]+-\d+\s*\|/.test(l))
    const p1 = findingLines.filter(l => /\|\s*P1\s*\|/.test(l)).length
    const p2 = findingLines.filter(l => /\|\s*P2\s*\|/.test(l)).length
    const p3 = findingLines.filter(l => /\|\s*P3\s*\|/.test(l)).length
    qualitySection += `- **Review findings**: ${p1} P1 (critical), ${p2} P2 (important), ${p3} P3 (minor)\n`
  } else {
    qualitySection += `- **Review findings**: N/A\n`
  }

  // Gap analysis coverage
  const gapPhase = checkpoint.phases.gap_analysis
  if (gapPhase?.status === "completed") {
    qualitySection += `- **Gap coverage**: ${gapPhase.artifact ? "see " + gapPhase.artifact.split('/').pop() : "completed"}\n`
  }

  // Test pass rate
  const testPhase = checkpoint.phases.test
  if (testPhase?.pass_rate != null) {
    qualitySection += `- **Test pass rate**: ${testPhase.pass_rate}% (tiers: ${(testPhase.tiers_run || []).join(", ") || "N/A"})\n`
  }

  // Resume count (stability indicator)
  const resumeCount = checkpoint.resume_tracking?.total_resume_count ?? 0
  if (resumeCount > 0) {
    qualitySection += `- **Resumes**: ${resumeCount} (arc was interrupted and resumed)\n`
  }

  // Target branch
  qualitySection += `- **Target branch**: ${defaultBranch}\n`

  // Changed Files Summary (v1.178.0+)
  let diffSummary = ""
  try {
    const diffStat = Bash(`git diff --stat ${defaultBranch}...HEAD 2>/dev/null`).trim()
    if (diffStat) {
      const diffLines = diffStat.split('\n')
      const summaryLine = diffLines[diffLines.length - 1].trim()
      const fileLines = diffLines.slice(0, -1).map(l => l.trim()).filter(Boolean)
      const cappedFiles = fileLines.slice(0, 30)
      const truncated = fileLines.length > 30

      diffSummary = `### Changes\n\n`
      diffSummary += `${summaryLine}\n\n`
      if (cappedFiles.length > 0) {
        diffSummary += `<details>\n<summary>Changed files (${fileLines.length})</summary>\n\n`
        diffSummary += "```\n"
        diffSummary += cappedFiles.join('\n') + '\n'
        if (truncated) diffSummary += `... and ${fileLines.length - 30} more files\n`
        diffSummary += "```\n\n</details>\n"
      }
    }
  } catch (e) { /* git unavailable or not on a branch */ }

  // Summary
  const commitCount = (checkpoint.commits || []).length
  const runOrdinal = existingRecords + 1

  // PR URL (v1.40.0: from Phase 9 SHIP)
  const prUrl = checkpoint.pr_url || null

  return `## Arc Completion Record — Run ${runOrdinal}\n\n` +
    `**Completed at**: ${completedAt}\n` +
    `**Started at**: ${checkpoint.started_at || "unknown"}\n` +
    `**Duration**: ${duration} min\n` +
    `**Arc ID**: ${checkpoint.id}\n` +
    `**Branch**: ${branch}\n` +
    (prUrl ? `**PR**: ${prUrl}\n` : '') +
    `**Checkpoint**: .rune/arc/${checkpoint.id}/checkpoint.json\n` +
    `**Session ID**: ${sessionId}\n` +
    `**Owner PID**: ${ownerPid}\n` +
    `**Rune Session ID**: ${runeSessionId}\n` +
    `**Rune Version**: ${pluginVersion}\n\n` +
    `### Phase Results\n\n` +
    phaseTable + `\n` +
    convergenceSection + `\n` +
    qualitySection + `\n` +
    `### Summary\n\n` +
    `- **Commits**: ${commitCount} on branch \`${branch}\`\n` +
    (prUrl ? `- **PR**: ${prUrl}\n` : '') +
    `- **Overall status**: ${newStatus}\n` +
    (diffSummary ? `\n` + diffSummary : '')
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
| Plan moved to `plans/archived/` during arc | STEP 1.5 relocation search finds by basename, writes stamp there, persists updated checkpoint path |
| Plan moved to nested subdir (e.g., `plans/archived/children/`) | Glob fallback `plans/**/{basename}` finds it |
| Plan basename matches multiple relocated files | Skip stamp with warning — ambiguous relocation is safer than guessing |
| Plan renamed (different basename) | Not found by relocation search — skip stamp. Checkpoint retains original path. |
| `checkpoint.totals.phase_times[key]` is non-numeric | Duration shows `"—"` (guarded by `Number.isFinite()`) |
| Negative phase duration (clock skew) | Duration shows `"0s"` (guarded by `Math.max(0, ...)`) |
| `origin/HEAD` not configured or contains shell metacharacters | `defaultBranch` validated against safe pattern, falls back to `"main"` |
| TOME file contains code examples with severity markers | P1/P2/P3 regex anchored to finding ID prefix `[A-Z]+-\d+` to avoid false matches |
| Binary file changes in git diff | `Bin X → Y bytes` format shown in file list; summary line remains correct |
| `CLAUDE_SESSION_ID` env var not set | Read from `checkpoint.session_id` instead (populated at arc init via preprocessor) |
| Plugin version unreadable | Shows `"unknown"` — non-blocking |
| `--resume` after plan moved between sessions | Relocation search runs at stamp time — handles cross-session moves. Checkpoint persisted. |
