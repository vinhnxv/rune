# Inspect — STEP D: Halt Decision Gate (Sub-Reference)

<!-- v3.0.0-alpha.7 (Day 6): Absorbed from the retired gap_analysis phase's
     STEP C + STEP D-DISCIPLINE + STEP D, lines 1248-1762 of the retired
     `gap-analysis.md`. Verbatim extraction with output paths migrated to
     `tmp/arc/{id}/inspect/` and checkpoint phase field renamed from
     `gap_analysis` to `inspect`. The three load-bearing semantics this
     sub-reference enforces are non-negotiable:

     1. STEP D.0 Task Completion Gate (PR #310 fix, 2026-03-16) — hardcoded
        100% completion floor, non-bypassable in non-headless mode. The
        `error()` call after `needsRemediation` evaluation is the gate
        mechanism. Preserve verbatim — wrapping it in try/catch silently
        re-opens the "40% shipped" bug class.

     2. STEP D.7 Plan writeback — appends "Implementation Status" + DEFERRED
        tasks back to `checkpoint.plan_file`. Enforces the "no silent
        deferrals" invariant.

     3. STEP D-DISCIPLINE Spec Compliance Matrix — when plan has YAML AC-*
        blocks, computes per-criterion status (GREEN/YELLOW/RED/ORANGE) and
        feeds RED count to the STEP D halt decision.
-->

<!-- v3.x: defaults baked from former talisman.{settings,arc}; see references/v3-defaults.md -->

Orchestrator-only halt-decision gate. Reads the deterministic report from
`tmp/arc/{id}/inspect/deterministic.md` (written by STEP A) and the VERDICT
from `tmp/arc/{id}/inspect/VERDICT.md` (written by STEP 3 verdict-binder),
merges them into a unified report, applies a dual-gate halt (Task Completion
Gate + Quality Score Gate + optional Spec Compliance halt), evaluates plan
drift, writes the implementation status section back to the plan file, and
sets `checkpoint.phases.inspect.needs_remediation` for the existing STEP 5
gap-fixer dispatch in `arc-phase-inspect.md`.

**Caller**: `arc-phase-inspect.md` (Phase 5.9). Invoked once per inspect
audit round, AFTER STEP 4 (Parse VERDICT and Update Checkpoint) and
BEFORE STEP 5 (Inspect Fix). On halt in non-headless mode, raises `error()`
and terminates the arc pipeline; the user resumes via `/rune:arc --resume`
after manual fixes.

**Team**: none — orchestrator only.
**Tools**: Read, Write, Bash (git diff, grep)
**Timeout**: ~1 minute (no agent dispatch).

**Failure policy** (v1.169.0 — hardened after PR #310 incident):

- **Task completion gate** (STEP D.0): ALWAYS active. Default floor: 100%.
  Tasks below floor trigger halt + remediation. Non-bypassable in
  non-headless mode (only adjustable via `task_completion_floor`, range
  50-100).
- **Quality score gate** (STEP D.1-D.2): `halt_on_critical: true` by
  default. `halt_threshold: 70`.
- **Plan writeback** (STEP D.7): Deferred tasks written back to plan file
  with status. No silent deferrals.
- **Gap remediation signal**: `needs_remediation: true` and
  `needs_task_remediation: true` in checkpoint when tasks are missing.
  Triggers the existing STEP 5 in `arc-phase-inspect.md` to spawn
  gap-fixer agents (absorbed from the retired gap_remediation phase).
- Headless/CI mode auto-proceeds but still writes plan status back.

---


## STEP C: Merge Deterministic + VERDICT (Orchestrator-Only)

Merges STEP A results (`tmp/arc/{id}/inspect/deterministic.md`) with the
4-Inspector VERDICT (`tmp/arc/{id}/inspect/VERDICT.md`) into a unified report.

**Author**: Orchestrator only — no team, no agents.
**Output**: `tmp/arc/{id}/inspect/UNIFIED.md`

```javascript
// STEP C.1: Extract scores from VERDICT.md
const verdictContent = Read(`tmp/arc/${id}/inspect/VERDICT.md`)

// Parse dimension scores from VERDICT — match lines like: "| Correctness | 7.5/10 |"
const dimensionScorePattern = /\|\s*([A-Za-z ]+)\s*\|\s*(\d+(?:\.\d+)?)\/10\s*\|/g
const verdictScores = {}
let match
while ((match = dimensionScorePattern.exec(verdictContent)) !== null) {
  const dimension = match[1].trim().toLowerCase().replace(/ /g, '_')
  verdictScores[dimension] = parseFloat(match[2])
}

// Parse overall completion % from VERDICT — match "Overall completion: N%" or "Completion: N%"
const completionMatch = verdictContent.match(/(?:Overall\s+)?[Cc]ompletion[:\s]+(\d+(?:\.\d+)?)%/)
const verdictCompletionPct = completionMatch ? parseFloat(completionMatch[1]) : null

// STEP C.2: Compute weighted aggregate using inspect-scoring.md dimension weights
// Weights from roundtable-circle/references/inspect-scoring.md
// Normalize VERDICT scores (0-10) to 0-100 scale, then apply weights:
//
// P2-001 (GW): Weight divergence note — these are PROPORTIONAL weights (sum ≈ 1.0)
// used for normalization in arc's gap analysis. They differ from inspect-scoring.md's
// RELATIVE weights (which are descriptive priorities, not arithmetic). The proportional
// form is needed here because we compute a single weighted aggregate score.
// If inspect-scoring.md updates its priority order, update these proportions to match.
const dimensionWeights = {
  correctness:    0.20,
  completeness:   0.20,
  failure_modes:  0.15,
  security:       0.15,
  design:         0.10,
  performance:    0.08,
  observability:  0.05,
  test_coverage:  0.04,
  maintainability: 0.03
}

let weightedScore = 0
let totalWeight = 0
for (const [dim, weight] of Object.entries(dimensionWeights)) {
  if (verdictScores[dim] !== undefined) {
    weightedScore += (verdictScores[dim] / 10) * 100 * weight
    totalWeight += weight
  }
}
const normalizedScore = totalWeight > 0 ? Math.round(weightedScore / totalWeight) : null

// STEP C.3: Count fixable vs manual gaps
const deterministicMissing = gaps.filter(g => g.status === "MISSING").length
const deterministicPartial = gaps.filter(g => g.status === "PARTIAL").length
const deterministicExtra = gaps.filter(g => g.status === "EXTRA").length
const verdictP1Count = (verdictContent.match(/## P1 \(Critical\)/g) || []).length > 0
  ? (verdictContent.match(/^- \[ \].*P1/gm) || []).length : 0
const verdictP2Count = (verdictContent.match(/^- \[ \].*P2/gm) || []).length

// Fixable = P2/P3 findings without security or architecture tags; Manual = P1 or security
// Stale references (PARTIAL) are fixable — just delete the reference
// Scope creep (EXTRA) is advisory — flagged but doesn't count as fixable
const fixableCount = verdictP2Count + deterministicPartial
const manualCount = verdictP1Count + deterministicMissing
const advisoryCount = deterministicExtra

// STEP C.4: Write unified report
const unifiedReport = `# Inspect — Unified Report (Phase 5.9)\n\n` +
  `**Plan**: ${checkpoint.plan_file}\n` +
  `**Date**: ${new Date().toISOString()}\n` +
  `**Unified Score**: ${normalizedScore !== null ? normalizedScore + '/100' : 'N/A (VERDICT unavailable)'}\n\n` +
  `## Deterministic Summary (STEP A)\n\n` +
  Read(`tmp/arc/${id}/inspect/deterministic.md`).slice(0, 3000) + '\n\n' +
  `## LLM Inspector Analysis (STEP B)\n\n` +
  verdictContent.slice(0, 5000) + '\n\n' +
  `## Aggregate\n\n` +
  `| Metric | Value |\n|--------|-------|\n` +
  `| Deterministic: MISSING | ${deterministicMissing} |\n` +
  `| Deterministic: PARTIAL | ${deterministicPartial} |\n` +
  `| Deterministic: EXTRA | ${deterministicExtra} |\n` +
  `| Inspector P1 findings | ${verdictP1Count} |\n` +
  `| Inspector P2 findings | ${verdictP2Count} |\n` +
  `| Fixable gaps | ${fixableCount} |\n` +
  `| Manual-review required | ${manualCount} |\n` +
  `| Advisory (scope creep) | ${advisoryCount} |\n` +
  `| Weighted score (0-100) | ${normalizedScore ?? 'N/A'} |\n\n` +
  `**Verdict completion**: ${verdictCompletionPct !== null ? verdictCompletionPct + '%' : 'N/A'}\n`

Write(`tmp/arc/${id}/inspect/UNIFIED.md`, unifiedReport)
```

---

## STEP D-DISCIPLINE: Spec Compliance Matrix (v1.171.0+)

When the plan contains YAML acceptance criteria (`AC-*` blocks), gap analysis produces a **Spec Compliance Matrix** — a per-criterion status report that cross-references every plan criterion against implementation evidence.

**Activation gate**: `hasCriteria` — at least one `AC-*` block found in plan. Zero overhead when not present.

```javascript
// Extract ALL acceptance criteria from plan
const criteriaBlocks = planContent.match(/```yaml\n(AC-[\s\S]*?)```/g) || []
const allCriteria = []
for (const block of criteriaBlocks) {
  const entries = block.match(/^(AC-[\d.]+):/gm) || []
  allCriteria.push(...entries.map(e => e.replace(':', '')))
}

if (allCriteria.length > 0) {
  // Build Spec Compliance Matrix
  const matrix = []
  for (const criterion of allCriteria) {
    // Check evidence artifacts
    const evidenceDirs = Glob(`tmp/work/*/evidence/*/`)
    let hasEvidence = false
    let hasPassed = false
    for (const dir of evidenceDirs) {
      const summaryPath = `${dir}summary.json`
      if (exists(summaryPath)) {
        const summary = JSON.parse(Read(summaryPath))
        const result = summary?.results?.find(r => r.criterion === criterion)
        if (result) {
          hasEvidence = true
          if (result.result === "PASS") hasPassed = true
        }
      }
    }

    // Check if criterion's file targets exist in diff
    const status = hasPassed ? "IMPLEMENTED+TESTED"
      : hasEvidence ? "IMPLEMENTED+UNTESTED"
      : "NOT_IMPLEMENTED"

    matrix.push({ criterion, status })
  }

  // Write matrix to gap analysis report
  const matrixContent = matrix.map(m =>
    `| ${m.criterion} | ${m.status} |`
  ).join('\n')

  // Count statuses
  const greenCount = matrix.filter(m => m.status === "IMPLEMENTED+TESTED").length
  const yellowCount = matrix.filter(m => m.status === "IMPLEMENTED+UNTESTED").length
  const redCount = matrix.filter(m => m.status === "NOT_IMPLEMENTED").length

  // RED criteria: create remediation tasks (WARN mode for initial rollout)
  // NOTE CDX-SV-002: Use WARN mode — RED creates remediation tasks, not BLOCK
  if (redCount > 0) {
    warn(`Spec Compliance Matrix: ${redCount} NOT_IMPLEMENTED criteria — creating remediation tasks`)
    // Remediation tasks are picked up by inspect STEP 5 (gap-fixer dispatch — absorbed gap_remediation in v3.0.0-alpha.7 Day 6)
  }

  // DISCIPLINE INTEGRATION: Evidence collection for inspect STEP 5 gap-fixer dispatch (absorbed gap_remediation v3.0.0-alpha.7 Day 6)
  // Gap-fixers must collect evidence after applying fixes, following the evidence convention:
  //   tmp/work/{timestamp}/evidence/{task-id}/{criterion-id}.json
  // The evidence is used by the TaskCompleted hook (validate-discipline-proofs.sh) and
  // by verify-mend's dual convergence gate (criteria dimension alongside findings).
  // If proof fails after remediation fix, fixer reports F3 (PROOF_FAILURE) per failure codes.
  // See discipline/references/evidence-convention.md and proof-schema.md.

  // Store in checkpoint for pre-ship validator
  updateCheckpoint({
    spec_compliance_matrix: {
      total: allCriteria.length,
      green: greenCount,
      yellow: yellowCount,
      red: redCount,
      scr: greenCount / allCriteria.length
    }
  })
}
```

**Per-criterion status values**:
- **IMPLEMENTED+TESTED** (GREEN): Evidence exists and verification passed
- **IMPLEMENTED+UNTESTED** (YELLOW): Evidence exists but not machine-verified
- **NOT_IMPLEMENTED** (RED): No evidence found for this criterion
- **DRIFTED** (ORANGE): Evidence exists but doesn't match criterion (mismatch detected)

## STEP D: Halt Decision

**Dual-gate halt**: task completion gate (deterministic, always active) + quality score gate (configurable).

The task completion gate was added in v1.169.0 after PR #310 shipped with only 40% plan completion — gap analysis detected 60% coverage but recommended PROCEED because the quality score gate was non-blocking by default. The task completion gate is a **hard, non-bypassable floor** that prevents shipping fundamentally incomplete implementations.

```javascript
// STEP D.0: Task Completion Gate (ALWAYS ACTIVE — not configurable)
// Deterministic check: extract plan tasks, verify each has implementation evidence.
// This gate exists because quality-score-based halting can be rationalized away,
// but "5 of 18 tasks have zero code" is an objective, non-negotiable signal.

const planContent = Read(enrichedPlanPath)
const strippedPlan = planContent.replace(/```[\s\S]*?```/g, '')

// D.0.1: Extract tasks from plan (### Task X.Y: heading pattern)
const taskPattern = /^###\s+Task\s+(\d+\.\d+):?\s*(.+)/gm
const planTasks = []
let taskMatch
while ((taskMatch = taskPattern.exec(strippedPlan)) !== null) {
  planTasks.push({ id: taskMatch[1], title: taskMatch[2].trim() })
}

// D.0.1.5: Re-derive safeDiffFiles for this code block scope
// (safeDiffFiles is declared in STEP A.3's code block — not carried across blocks)
const safeDiffFiles = diffFiles.filter(f => /^[a-zA-Z0-9._\-\/]+$/.test(f) && !f.includes('..'))

// D.0.2: For each task, extract **Files**: line and check against committed files
const taskCompletionResults = []
for (const task of planTasks) {
  // Find the task section content (until next ### or ##)
  const taskSectionPattern = new RegExp(
    `### Task ${task.id.replace(/\./g, '\\.')}[:\\s].*?(?=### (?:Task \\d|[A-Za-z])|##[^#]|$)`, 's'
  )
  const sectionMatch = strippedPlan.match(taskSectionPattern)
  const sectionText = sectionMatch ? sectionMatch[0] : ''

  // Extract file patterns from **Files**: line
  const filesMatch = sectionText.match(/\*\*Files?\*\*:\s*(.+)/i)
  const taskFiles = filesMatch
    ? filesMatch[1].match(/`([^`]+)`/g)?.map(f => f.replace(/`/g, '')) || []
    : []

  // SEC-STEP-D: Sanitize taskFiles — plan content is untrusted (Truthbinding)
  // FLAW-005 FIX: filter out shell metacharacters before any Bash() interpolation
  const safeTaskFiles = taskFiles.filter(tf =>
    /^[a-zA-Z0-9._\-\/\*]+$/.test(tf) && !tf.includes('..')
  )

  // Extract action keywords (delete, create, migrate, move, update)
  const hasDeleteAction = /\b(delete|remove|eliminate|drop)\b/i.test(sectionText)
  const hasCreateAction = /\b(create|new file|add file|build)\b/i.test(sectionText)
  const hasMigrateAction = /\b(migrate|move|rename)\b/i.test(sectionText)

  // Check evidence in committed files
  let evidence = "NONE"
  if (safeTaskFiles.length > 0) {
    const fileHits = safeTaskFiles.filter(tf => {
      // Glob pattern (e.g., "agents/**/*.md") — check if any diff file matches
      if (tf.includes('*')) {
        const globPrefix = tf.split('*')[0]
        // FLAW-004 FIX: Also check extension when pattern has one (e.g., *.md)
        const extMatch = tf.match(/\*\.(\w+)$/)
        const expectedExt = extMatch ? `.${extMatch[1]}` : null
        return safeDiffFiles.some(df =>
          df.startsWith(globPrefix) && (!expectedExt || df.endsWith(expectedExt))
        )
      }
      // Exact path — check if in diff
      return safeDiffFiles.includes(tf)
    })
    if (fileHits.length > 0) {
      evidence = "ADDRESSED"
    } else if (hasDeleteAction) {
      // For deletion tasks: verify target files no longer exist
      // FLAW-005 FIX: safeTaskFiles already sanitized — safe for Bash()
      const deletionTargets = safeTaskFiles.filter(tf => !tf.includes('*'))
      const stillExist = deletionTargets.filter(tf => {
        try { return Bash(`test -e "${tf}" && echo "yes" || echo "no"`).trim() === "yes" }
        catch { return false }
      })
      evidence = stillExist.length > 0 ? "MISSING" : "ADDRESSED"
    }
  } else {
    // No **Files**: line — try keyword grep against diff files
    const keywords = task.title.match(/`([^`]+)`/g)?.map(k => k.replace(/`/g, '')) || []
    if (keywords.length > 0 && safeDiffFiles.length > 0) {
      for (const kw of keywords.slice(0, 5)) {
        if (!/^[a-zA-Z0-9._\-\/]+$/.test(kw)) continue
        const grepResult = Bash(`rg -l --max-count 1 -- "${kw}" ${safeDiffFiles.map(f => `"${f}"`).join(' ')} 2>/dev/null`)
        if (grepResult.trim().length > 0) { evidence = "ADDRESSED"; break }
      }
    }
  }

  taskCompletionResults.push({
    id: task.id,
    title: task.title,
    evidence,
    hasDelete: hasDeleteAction,
    hasMigrate: hasMigrateAction,
    fileCount: taskFiles.length
  })
}

// D.0.3: Calculate task completion percentage
const totalTasks = taskCompletionResults.length
const completedTasks = taskCompletionResults.filter(t => t.evidence === "ADDRESSED").length
const missingTasks = taskCompletionResults.filter(t => t.evidence === "MISSING" || t.evidence === "NONE")
const taskCompletionPct = totalTasks > 0 ? Math.round((completedTasks / totalTasks) * 100) : 100

// D.0.4: Hard completion floor — ALWAYS enforced, cannot be disabled
// This is the fix for the "40% shipped" incident (PR #310, 2026-03-16).
// Unlike halt_threshold (quality gate, configurable), this is a completion gate (non-negotiable).
// Default: 100% — ALL plan tasks must be implemented. Skip/defer is exceptional.
// When tasks ARE deferred, gap analysis writes explicit deferral records back to
// the plan file (STEP D.7) — no silent deferrals allowed.
// v3.x: hardcoded floor of 100% (see references/v3-defaults.md). Deferred tasks are written back.
const TASK_COMPLETION_FLOOR = 100

const taskCompletionFailed = totalTasks > 0 && taskCompletionPct < TASK_COMPLETION_FLOOR

// Inject task completion report into unified report
const taskReportSection = `\n## TASK COMPLETION\n\n` +
  `**Tasks**: ${completedTasks}/${totalTasks} addressed (${taskCompletionPct}%)\n` +
  `**Floor**: ${TASK_COMPLETION_FLOOR}%\n` +
  `**Gate**: ${taskCompletionFailed ? 'HALT' : 'PASS'}\n\n` +
  `| Task | Title | Evidence |\n|------|-------|----------|\n` +
  taskCompletionResults.map(t =>
    `| ${t.id} | ${t.title.slice(0, 60)} | ${t.evidence}${t.hasDelete ? ' (deletion)' : ''}${t.hasMigrate ? ' (migration)' : ''} |`
  ).join('\n') + '\n\n' +
  (missingTasks.length > 0
    ? `**Missing tasks**:\n${missingTasks.map(t => `- Task ${t.id}: ${t.title}`).join('\n')}\n`
    : '')

// Append to unified report
const existingUnifiedContent = Read(`tmp/arc/${id}/inspect/UNIFIED.md`) ?? ""
Write(`tmp/arc/${id}/inspect/UNIFIED.md`, existingUnifiedContent + taskReportSection)

// STEP D.1: v3.x — hardcoded halt config (see references/v3-defaults.md)
const haltThreshold = 70  // Quality score threshold (raised from 50 in v1.169.0)
const haltEnabled   = true  // ENABLED (changed from false in v1.169.0)

// STEP D.2: Map VERDICT to halt decision
// CRITICAL_ISSUES = any P1 finding → always halt if halt_enabled
// TASK_COMPLETION = below floor → always halt (non-bypassable)
const hasCriticalIssues = verdictP1Count > 0
const scoreBelowThreshold = normalizedScore !== null && normalizedScore < haltThreshold

// STEP A.12 integration: RED criteria in BLOCK mode trigger halt
const specComplianceHalt = specComplianceMode === "block" && redCriteriaCount > 0

const needsRemediation =
  taskCompletionFailed ||  // Task completion gate — ALWAYS enforced
  specComplianceHalt ||    // Spec compliance gate — only in BLOCK mode (CDX-SV-002)
  (haltEnabled && hasCriticalIssues) ||
  (haltEnabled && scoreBelowThreshold)

// STEP D.3: Headless mode — auto-proceed (CI/batch mode ignores halt)
const headlessMode = Bash(`echo "\${ARC_BATCH_MODE:-no}"`).trim() === "yes"
  || Bash(`echo "\${CI:-no}"`).trim() === "yes"
  || Bash(`echo "\${CONTINUOUS_INTEGRATION:-no}"`).trim() === "yes"

if (needsRemediation && headlessMode) {
  warn(`STEP D: Halt threshold triggered (score: ${normalizedScore}, threshold: ${haltThreshold}) but headless mode — auto-proceeding.`)
}

// STEP D.4: Write needs_remediation flag to checkpoint
// When tasks are missing, ALWAYS flag for remediation — inspect STEP 5 (gap-fixer dispatch) will
// spawn workers to implement missing tasks, then re-verify.
const needsTaskRemediation = totalTasks > 0 && missingTasks.length > 0
updateCheckpoint({
  phase: "inspect",
  // v3.0.0-alpha.7 (Day 6): do NOT mark inspect 'completed' here. STEP D
  // sets status to 'failed' only on halt; on PASS, the caller arc-phase-inspect.md
  // continues to STEP 5 (gap-fixer dispatch) and STEP 6 (convergence) which
  // own the final 'completed' state. This preserves the existing convergence
  // loop behavior introduced in v3.0.0-alpha.6 Day 5.
  status: needsRemediation && !headlessMode ? "failed" : "in_progress",
  artifact: `tmp/arc/${id}/inspect/UNIFIED.md`,
  artifact_hash: sha256(unifiedReport),
  phase_sequence: 5.9,
  // CORR-007 FIX (v3.0.0-alpha.7 Day 6 review): `inspectTeamName` was an undefined local.
  // Read the existing checkpoint value so we don't clobber the team name that arc-phase-inspect.md
  // line 159 set for the inspector team.
  team_name: checkpoint.phases?.inspect?.team_name ?? null,
  substate: 'halt_gate_done',
  // Extra fields read by the existing STEP 5 gap-fixer dispatch and STEP 6 convergence
  needs_remediation: (needsRemediation && !headlessMode) || needsTaskRemediation,
  needs_task_remediation: needsTaskRemediation,
  unified_score: normalizedScore,
  fixable_count: fixableCount,
  manual_count: manualCount,
  // Spec compliance data (STEP A.12)
  spec_compliance_mode: specComplianceMode,
  spec_compliance_red_count: redCriteriaCount,
  spec_compliance_counts: specCounts,
  // Task completion data for gap-remediation convergence loop
  task_completion_pct: taskCompletionPct,
  task_completion_floor: TASK_COMPLETION_FLOOR,
  missing_tasks: missingTasks.map(t => ({ id: t.id, title: t.title })),
  total_tasks: totalTasks,
  completed_tasks: completedTasks
})

// STEP D.5: Halt if needed (and not headless)
if (needsRemediation && !headlessMode) {
  const haltReasons = []
  if (taskCompletionFailed) {
    haltReasons.push(`TASK_COMPLETION: ${completedTasks}/${totalTasks} tasks addressed (${taskCompletionPct}%) — below floor of ${TASK_COMPLETION_FLOOR}%`)
    // List the missing tasks for actionable feedback
    for (const t of missingTasks.slice(0, 10)) {
      haltReasons.push(`  - Task ${t.id}: ${t.title}`)
    }
    if (missingTasks.length > 10) haltReasons.push(`  ... and ${missingTasks.length - 10} more`)
  }
  if (specComplianceHalt) haltReasons.push(`SPEC_COMPLIANCE: ${redCriteriaCount} RED criteria in BLOCK mode (${specCounts.not_implemented} not implemented, ${specCounts.drifted} drifted)`)
  if (hasCriticalIssues) haltReasons.push(`CRITICAL_ISSUES: ${verdictP1Count} P1 findings found`)
  if (scoreBelowThreshold) haltReasons.push(`QUALITY_SCORE: ${normalizedScore}/100 is below halt_threshold ${haltThreshold}`)

  const haltMessage = haltReasons.join('\n')

  // CRITICAL — DO NOT WRAP IN try/catch. PR #310 (2026-03-16) regression:
  // the "40% shipped" bug class exists because this `error()` was the only
  // non-bypassable halt mechanism. Wrapping it in try/catch silently
  // downgrades the Task Completion Gate. Preserve the unwrapped throw
  // verbatim through every future absorption.
  error(`Phase 5.9 INSPECT halted (halt-gate):\n${haltMessage}\n\n` +
    `Unified report: tmp/arc/${id}/inspect/UNIFIED.md\n` +
    (taskCompletionFailed
      ? `Task completion floor is ${TASK_COMPLETION_FLOOR}% (v3.x baked default 100%, range: [50, 100]).\n`
      : `v3.x: halt_on_critical baked true; lower the literal to bypass.\n`) +
    `Or resume after manual fixes: /rune:arc --resume`)
}

// ── STEP D.6: Plan Drift Reassessment Gate ──
// When a high proportion of acceptance criteria are MISSING, the original plan
// may be fundamentally misaligned with the codebase — warn before wasting effort
// on incremental gap fixes.
// v3.x: arc.gap_analysis.reassessment.enabled baked true (always run);
//       drift_threshold baked at 0.40 (40% MISSING triggers warning).
const driftThreshold = 0.40

{
  const totalCriteria = gaps.length
  const missingCount = gaps.filter(g => g.status === "MISSING").length
  const driftRatio = totalCriteria > 0 ? missingCount / totalCriteria : 0

  if (driftRatio > driftThreshold) {
    const driftPct = (driftRatio * 100).toFixed(1)
    const driftWarning = `\n\n> **⚠ PLAN DRIFT WARNING**: ${driftPct}% of acceptance criteria ` +
      `(${missingCount}/${totalCriteria}) are MISSING (threshold: ${(driftThreshold * 100).toFixed(0)}%). ` +
      `The original plan may need reassessment before proceeding with gap remediation.\n`

    // Inject drift warning into the UNIFIED report (gap-analysis-unified.md)
    // that downstream phases read for decisions
    const unifiedPath = `tmp/arc/${id}/inspect/UNIFIED.md`
    const existingUnified = Read(unifiedPath) ?? ""
    Write(unifiedPath, existingUnified + driftWarning)

    // Store drift metadata in checkpoint for downstream phase gates
    updateCheckpoint({
      phase: "inspect",
      plan_drift_detected: true,
      plan_drift_ratio: driftRatio,
      plan_drift_missing: missingCount,
      plan_drift_total: totalCriteria,
      plan_drift_threshold: driftThreshold
    })

    if (headlessMode) {
      warn(`STEP D.6: Plan drift detected (${driftPct}% MISSING, threshold: ${(driftThreshold * 100).toFixed(0)}%) but headless mode — logging only.`)
    } else {
      warn(`STEP D.6: Plan drift detected — ${driftPct}% of acceptance criteria are MISSING ` +
        `(${missingCount}/${totalCriteria}, threshold: ${(driftThreshold * 100).toFixed(0)}%).\n` +
        `Consider revising the plan before proceeding with gap remediation.\n` +
        `To disable in v3.x: remove the STEP D.6 block from inspect-step-d-halt-gate.md.`)
    }
  }
}
// ── STEP D.7: Write Implementation Status Back to Plan File (v1.169.0) ──
// Plan files are living documents. After gap analysis, write task completion
// status back to the plan so deferred tasks are explicitly recorded.
// This prevents the "silent deferral" problem where tasks disappear without trace.

// planPath from checkpoint — gap-analysis uses checkpoint.plan_file throughout
const planPath = checkpoint.plan_file
if (planPath && totalTasks > 0) {
  const timestamp = new Date().toISOString().split('T')[0]  // YYYY-MM-DD
  const arcRunId = id

  // Build implementation status section
  let statusSection = `\n---\n\n## Implementation Status (arc: ${arcRunId}, ${timestamp})\n\n`
  statusSection += `**Completion**: ${completedTasks}/${totalTasks} tasks (${taskCompletionPct}%)\n`
  statusSection += `**Arc run**: ${arcRunId}\n\n`
  statusSection += `| Task | Status | Notes |\n|------|--------|-------|\n`

  for (const task of taskCompletionResults) {
    const status = task.evidence === "ADDRESSED" ? "DONE" :
                   task.evidence === "MISSING" ? "MISSING" : "NOT STARTED"
    const notes = task.hasDelete ? "deletion task" :
                  task.hasMigrate ? "migration task" : ""
    statusSection += `| ${task.id} | ${status} | ${notes} |\n`
  }

  // Deferred tasks MUST have explicit reason — no silent deferrals
  if (missingTasks.length > 0) {
    statusSection += `\n### Deferred Tasks — REQUIRES JUSTIFICATION\n\n`
    statusSection += `> **WARNING**: The following tasks were NOT implemented. Each deferral MUST have\n`
    statusSection += `> an explicit reason. Tasks without justification will be flagged as incomplete\n`
    statusSection += `> in future arc runs.\n\n`
    for (const t of missingTasks) {
      statusSection += `- **Task ${t.id}**: ${t.title}\n`
      statusSection += `  - **Status**: DEFERRED\n`
      statusSection += `  - **Reason**: _[REQUIRED — fill before ship or task blocks pipeline]_\n`
      statusSection += `  - **Follow-up arc**: Required — this task will be re-extracted by gap analysis\n`
      statusSection += `  - **Risk if skipped**: _[REQUIRED — what breaks if this is never done]_\n`
    }
    statusSection += `\n> v3.x: task_completion_floor is hardcoded at 100% (see references/v3-defaults.md).\n`
    statusSection += `> Deferred tasks must be implemented in a follow-up arc.\n`
  }

  // Append to plan file (don't overwrite — append below the original content)
  try {
    const existingPlan = Read(planPath)
    // Only append if not already present (idempotent — check for arc run ID)
    if (!existingPlan.includes(`arc: ${arcRunId}`)) {
      Write(planPath, existingPlan + statusSection)
      log(`STEP D.7: Wrote implementation status to plan file: ${planPath}`)
    }
  } catch (e) {
    warn(`STEP D.7: Could not write implementation status to plan: ${e.message}`)
  }
}
```

**Output**: `tmp/arc/{id}/inspect/UNIFIED.md`, `tmp/arc/{id}/inspect/VERDICT.md`, individual inspector files. **Plan file updated** with implementation status section (v1.169.0+).

**Failure policy** (v1.169.0 — hardened after PR #310 incident):
- **Task completion gate** (STEP D.0): ALWAYS active. Default floor: 100%. Tasks below floor trigger halt + inspect STEP 5 (gap-fixer dispatch). Non-bypassable (only adjustable via `task_completion_floor`, range 50-100).
- **Quality score gate** (STEP D.1-D.2): `halt_on_critical: true` by default (changed from `false`). `halt_threshold: 70` (raised from 50).
- **Plan writeback** (STEP D.7): Deferred tasks written back to plan file with status. No silent deferrals.
- **Gap remediation signal**: `needs_task_remediation: true` in checkpoint when tasks are missing — triggers inspect STEP 5 (gap-fixer dispatch) to implement missing tasks, followed by re-verification (convergence loop).
- Headless/CI mode auto-proceeds but still writes plan status back.

