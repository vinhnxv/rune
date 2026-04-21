# Phase 7.5: Verify Mend (Review-Mend Convergence Controller) — Full Algorithm

Full convergence controller that evaluates mend results, determines whether to loop back for another review-mend cycle, or proceed to test. Replaces the previous single-pass spot-check with an adaptive multi-cycle review-mend loop.

**Team**: None for convergence decision. Delegates full re-review to `/rune:appraise` (Phase 6) via dispatcher loop-back.
**Tools**: Read, Glob, Grep, Write, Bash (git diff)
**Duration**: Max 4 minutes per convergence evaluation (re-review cycles run as separate Phase 6+7 invocations)

See [review-mend-convergence.md](../../roundtable-circle/references/review-mend-convergence.md) for shared tier selection and convergence evaluation logic.

## Entry Guard

Skip if mend was skipped, had 0 findings, or produced no fixes.

```javascript
// Decree-arbiter P2: Round-aware resolution report read path
const mendRound = checkpoint.convergence?.round ?? 0
const resolutionReportPath = mendRound === 0
  ? `tmp/arc/${id}/resolution-report.md`
  : `tmp/arc/${id}/resolution-report-round-${mendRound}.md`
const resolutionReport = Read(resolutionReportPath)
const mendSummary = parseMendSummary(resolutionReport)
// parseMendSummary extracts: { total, fixed, false_positive, failed, skipped }

// BACK-004 FIX: Removed mendSummary.fixed === 0 from entry guard — that case is handled by EC-1 below.
if (checkpoint.phases.mend.status === "skipped" || mendSummary.total === 0) {
  updateCheckpoint({ phase: "verify_mend", status: "skipped", phase_sequence: 7.5, team_name: null })
  return
}

// EC-1: Mend made no progress — prevent infinite retry on unfixable findings
if (mendSummary.fixed === 0 && mendSummary.failed > 0) {
  warn(`Mend fixed 0 findings (${mendSummary.failed} failed) — manual intervention required.`)
  // BACK-001 FIX: p1_remaining and p2_remaining are null (not 0) because TOME has not been read yet.
  // EC-1 fires before STEP 1 — actual finding counts are unknown at this stage.
  checkpoint.convergence.history.push({
    round: mendRound, findings_before: mendSummary.total, findings_after: mendSummary.failed,
    p1_remaining: null, p2_remaining: null, verdict: 'halted', reason: 'zero_progress', timestamp: new Date().toISOString()
  })
  updateCheckpoint({ phase: 'verify_mend', status: 'completed', phase_sequence: 7.5, team_name: null,
    artifact: resolutionReportPath, artifact_hash: sha256(resolutionReport) })
  return
}

updateCheckpoint({ phase: "verify_mend", status: "in_progress", phase_sequence: 7.5, team_name: null })
```

## STEP 1: Read Current TOME and Count Findings

```javascript
// ARTIFACT EXTRACTION (v1.141.0): Extract TOME metrics via shell script for convergence checks.
// readTalismanSection: "settings"
const extractionEnabled = readTalismanSection("settings")?.artifact_extraction?.enabled !== false
if (extractionEnabled) {
  try {
    Bash(`cd "${CWD}" && bash plugins/rune/scripts/artifact-extract.sh tome-digest "${id}" "${mendRound}"`)
  } catch (e) { warn(`artifact-extract tome-digest (round ${mendRound}) failed: ${e.message} — falling back`) }
}
// Digest available at: tmp/arc/${id}/tome-digest${mendRound > 0 ? '-round-' + mendRound : ''}.json
// Used below for quick-check metrics; full TOME still read for detailed convergence logic.

// EC-2: Guard against missing or malformed TOME
const tomeFile = mendRound === 0 ? `tmp/arc/${id}/tome.md` : `tmp/arc/${id}/tome-round-${mendRound}.md`
let currentTome
try {
  currentTome = Read(tomeFile)
} catch (e) {
  warn(`TOME not found at ${tomeFile} — review may have timed out.`)
  // BACK-001 FIX: p1_remaining/p2_remaining null — TOME not available, counts unknown
  checkpoint.convergence.history.push({
    round: mendRound, findings_before: 0, findings_after: 0,
    p1_remaining: null, p2_remaining: null, verdict: 'halted', reason: 'tome_missing', timestamp: new Date().toISOString()
  })
  updateCheckpoint({ phase: 'verify_mend', status: 'completed', phase_sequence: 7.5, team_name: null })
  return
}
// STEP 1: Try structured markers first (preferred)
if (!currentTome) {
  warn(`TOME at ${tomeFile} is empty — halting convergence.`)
  checkpoint.convergence.history.push({
    round: mendRound, findings_before: 0, findings_after: 0,
    p1_remaining: null, p2_remaining: null,
    verdict: 'halted', reason: 'tome_malformed',
    timestamp: new Date().toISOString()
  })
  updateCheckpoint({ phase: 'verify_mend', status: 'completed', phase_sequence: 7.5, team_name: null })
  return
}

let allFindingMarkers = currentTome.match(/<!-- RUNE:FINDING[^>]*-->/g) || []

// STEP 1b: Fallback to markdown parsing when no structured markers
// When Runebinder crashes/times out, the TOME has markdown content but no RUNE:FINDING markers.
// This 2-pass fallback parses severity section headers and finding list items.
// NOTE: Fallback-synthesized markers include source="markdown_fallback" for downstream diagnostics.
// They intentionally LACK nonce and interaction attributes — downstream filters handle this:
//   - Nonce: effectiveNonce=null path (line ~168) includes all markers (safe fallback)
//   - Interaction: Q/N filter (line ~141) won't match → counted as assertions (safe overcount)
//   - Scope: scopeStats will be null → smart convergence scoring skipped (correct)
if (allFindingMarkers.length === 0 && !currentTome.includes('<!-- CLEAN -->')) {
  warn("TOME lacks RUNE:FINDING markers — falling back to markdown parsing")

  // Pass 1: find severity sections (## P1 (Critical) — {count}, ## P2 (High) — {count}, etc.)
  const severitySections = currentTome.match(/^## P([123]) \([^)]+\)/gm) || []
  // Pass 2: find findings within each section (- [ ] **[PREFIX-NNN] Title** in `file:line`)
  const findingPattern = /^- \[ \] \*\*\[(\w+-\d+)\]/gm

  if (severitySections.length > 0) {
    // Split TOME by severity sections — capture group produces alternating array:
    // [header, severity1, content1, severity2, content2, ...]
    const sections = currentTome.split(/^## P([123]) \([^)]+\)/m)
    for (let i = 1; i < sections.length; i += 2) {
      const severity = sections[i]  // "1", "2", or "3"
      const content = sections[i + 1] || ''
      let match
      findingPattern.lastIndex = 0  // Reset global regex per section
      while ((match = findingPattern.exec(content)) !== null) {
        const findingId = match[1]
        allFindingMarkers.push(
          `<!-- RUNE:FINDING id="${findingId}" severity="P${severity}" source="markdown_fallback" -->`
        )
      }
    }
    if (allFindingMarkers.length > 0) {
      warn(`Parsed ${allFindingMarkers.length} findings from markdown (fallback mode)`)
    }
  }

  // If still no findings after fallback, truly malformed
  if (allFindingMarkers.length === 0) {
    warn(`TOME at ${tomeFile} appears empty or malformed — halting convergence.`)
    // BACK-001 FIX: p1_remaining/p2_remaining null — TOME malformed, counts unreliable
    checkpoint.convergence.history.push({
      round: mendRound, findings_before: 0, findings_after: 0,
      p1_remaining: null, p2_remaining: null,
      verdict: 'halted', reason: 'tome_malformed',
      timestamp: new Date().toISOString()
    })
    updateCheckpoint({ phase: 'verify_mend', status: 'completed', phase_sequence: 7.5, team_name: null })
    return
  }
}

// v1.60.0: Exclude Q/N interaction findings from convergence counting
// Q/N findings are human-facing only and should not influence convergence decisions
const assertionMarkers = allFindingMarkers.filter(m => !/interaction="(question|nit)"/.test(m))
const currentFindingCount = assertionMarkers.length
const p1Count = assertionMarkers.filter(m => /severity="P1"/i.test(m)).length
const p2Count = assertionMarkers.filter(m => /severity="P2"/i.test(m)).length
const qCount = allFindingMarkers.filter(m => /interaction="question"/.test(m)).length
const nCount = allFindingMarkers.filter(m => /interaction="nit"/.test(m)).length
if (qCount + nCount > 0) {
  log(`Verify-mend: ${qCount} Q + ${nCount} N findings excluded from convergence (human-triage only)`)
}

// v1.38.0: Extract scope stats for smart convergence scoring
// Scope stats are available when diff-scope tagging was applied (appraise.md Phase 5.3).
// For untagged TOMEs (pre-v1.38.0), scopeStats is null → evaluateConvergence skips smart scoring.
let scopeStats = null
// SEC-007 FIX: Filter markers by session nonce before extracting scope stats.
// Without nonce validation, stale/injected markers from prior sessions could inflate counts.
const sessionNonce = checkpoint.session_nonce
// BACK-013 FIX: Validate nonce format before use in string matching (defense-in-depth)
// SEC-001 FIX: On invalid nonce, set effectiveNonce to null so ternary takes allMarkers branch.
// L-4 FIX: Tightened regex to match generation format ([0-9a-f]{12}) exactly.
// Previously used permissive [a-zA-Z0-9_-]+ which allowed tampered nonces to pass validation.
// ARC-SEC-004 (audit 20260420-171018): accept both legacy 12-hex (pre-2.65)
// and current 32-hex (2.65+) so active arcs spanning the upgrade keep filtering.
let effectiveNonce = sessionNonce
if (sessionNonce && !/^[0-9a-f]{12}$|^[0-9a-f]{32}$/.test(sessionNonce)) {
  warn(`Invalid session nonce format: ${sessionNonce} — falling back to unfiltered markers`)
  effectiveNonce = null
}
const allMarkers = currentTome.match(/<!-- RUNE:FINDING[^>]*-->/g) || []
const findingMarkers = effectiveNonce
  ? allMarkers.filter(m => m.includes(`nonce="${effectiveNonce}"`))
  : allMarkers  // Fallback: no nonce or invalid nonce → use all markers
if (findingMarkers.some(m => /scope="(in-diff|pre-existing)"/.test(m))) {
  // SEC-006 FIX: Case-insensitive severity matching to prevent p1 bypass via lowercase
  const p3Markers = findingMarkers.filter(m => /severity="P3"/i.test(m))
  const preExistingMarkers = findingMarkers.filter(m => /scope="pre-existing"/.test(m))
  const inDiffMarkers = findingMarkers.filter(m => /scope="in-diff"/.test(m))
  scopeStats = {
    p1Count,
    p2Count,
    p3Count: p3Markers.length,
    preExistingCount: preExistingMarkers.length,
    inDiffCount: inDiffMarkers.length,
    totalFindings: currentFindingCount,
  }
}
```

## STEP 2: Evaluate Convergence

Uses shared `evaluateConvergence()` from review-mend-convergence.md. Passes `p2Count` (v1.41.0+) for P2 awareness and `scopeStats` (v1.38.0+) for smart convergence scoring when diff-scope data is available.

**evaluateConvergence cascade** (3 key gates): (1) minCycles gate — `round + 1 < minCycles` → forced retry, (2) P1 AND P2 threshold — `p1Count <= findingThreshold && p2Count <= p2Threshold` (default p2Threshold=0 — any P2 blocks), (3) smart scoring via `computeConvergenceScore()` when diff-scope enabled — 4-component formula: `0.4*p3Ratio + 0.3*preExistingRatio + 0.2*trendDecreasing + 0.1*base` against convergenceThreshold=0.7 (default). P2 hard gate: returns score 0.0 if `p2Count > p2Threshold`.

<!-- p2Threshold: configurable via talisman review.arc_convergence_p2_threshold
     Default: 0 (strict — all P2 must be resolved). Recommended opt-in: 2.
     Users set arc_convergence_p2_threshold: 2 in talisman.yml to allow up to 2 remaining P2 findings. -->

```javascript
// readTalismanSection: "review"
const review = readTalismanSection("review")
// Wrap in {review} to match evaluateConvergence() expected shape
const talisman = { review }
const verdict = evaluateConvergence(currentFindingCount, p1Count, p2Count, checkpoint, talisman, scopeStats)

// v1.38.0: Compute convergence score for history record (observability — R6 mitigation)
let convergenceScore = null
if (scopeStats && review?.diff_scope?.enabled !== false) {
  convergenceScore = computeConvergenceScore(scopeStats, checkpoint, talisman)
}

// Record convergence history
// BACK-007 NOTE: prevFindings is also computed inside evaluateConvergence() (review-mend-convergence.md).
// Intentional duplication — this copy is for the history record; evaluateConvergence uses its own for verdict.
const prevFindings = mendRound === 0 ? Infinity
  : checkpoint.convergence.history[mendRound - 1]?.findings_after ?? Infinity
checkpoint.convergence.history.push({
  round: mendRound,
  findings_before: prevFindings === Infinity ? currentFindingCount : prevFindings,
  findings_after: currentFindingCount,
  p1_remaining: p1Count,
  p2_remaining: p2Count,                         // v1.41.0: P2 observability
  mend_fixed: mendSummary.fixed,
  mend_failed: mendSummary.failed,
  // v1.38.0: Scope-aware fields for smart convergence observability
  scope_stats: scopeStats ?? null,              // { p1Count, p2Count, p3Count, preExistingCount, inDiffCount, totalFindings }
  convergence_score: convergenceScore ?? null,   // { total, components, reason } from computeConvergenceScore()
  verdict,
  timestamp: new Date().toISOString()
})
```

## STEP 2.5: Criteria Convergence Check (Discipline Integration, v1.173.0)

Dual convergence gate: BOTH findings AND acceptance criteria must converge for the pipeline to proceed. This prevents the "tests pass on wrong code" failure mode where findings decrease but criteria regress.

```javascript
// Criteria convergence check — alongside findings convergence (verdict from STEP 2)
// Source: Spec Compliance Matrix from Phase 5.5 (gap_analysis) or evidence directory
// Reference: work-loop-convergence.md (Shard 6 T6.3) for criteria convergence protocol
let criteriaConverged = true  // default: pass if no criteria data available
let criteriaRegression = false

const scm = checkpoint.spec_compliance_matrix
if (scm && scm.total > 0) {
  // Re-check criteria status by scanning evidence directory for freshness
  const criteriaPassCount = scm.green ?? 0
  const criteriaTotalCount = scm.total

  // Check for criteria regression: previously-PASS criterion moved to FAIL after mend
  // Compare current SCR against checkpoint's stored SCR from gap_analysis
  // NOTE: SCR uses the checkpoint's green count, not a fresh evidence re-scan.
  // Re-running proofs here would be expensive (~30s per criterion). The checkpoint
  // SCR is sufficient because mend fixes review findings, not acceptance criteria
  // directly — criteria status rarely changes during mend.
  const previousScr = scm.scr ?? 0
  const currentScr = criteriaTotalCount > 0 ? criteriaPassCount / criteriaTotalCount : 1.0

  if (currentScr < previousScr) {
    criteriaRegression = true
    warn(`DISCIPLINE: Criteria regression detected — SCR dropped from ${(previousScr * 100).toFixed(1)}% to ${(currentScr * 100).toFixed(1)}% after mend. Previously-PASS criteria may have moved to FAIL (F10 CRITERIA_REGRESSION).`)
  }

  // Criteria converge when SCR >= threshold (default 0.8) or no regression
  // readTalismanSection: "settings"
  // NOTE: Default 0.8 here is intentionally lower than strive's 0.95 (work-loop-convergence.md)
  // because arc operates at pipeline level where some criteria may be addressed in later phases.
  // Both read from discipline.scr_threshold if set in talisman — only the defaults diverge.
  // readTalismanSection: "discipline"
  const disciplineConfig = readTalismanSection("discipline") ?? {}
  const scrThreshold = disciplineConfig.scr_threshold ?? 0.8
  if (currentScr < scrThreshold && !criteriaRegression) {
    warn(`DISCIPLINE: SCR ${(currentScr * 100).toFixed(1)}% below threshold ${scrThreshold * 100}% — criteria not converged`)
    criteriaConverged = false
  }
}

// Record criteria convergence in history
checkpoint.convergence.history[checkpoint.convergence.history.length - 1].criteria_converged = criteriaConverged
checkpoint.convergence.history[checkpoint.convergence.history.length - 1].criteria_regression = criteriaRegression

// Override verdict: if findings converged but criteria did NOT converge, force retry
// Dual convergence gate: BOTH findings AND criteria must converge to proceed.
// Two failure modes: (a) criteria regressed (SCR went DOWN), (b) criteria below threshold (SCR stays low).
if (verdict === 'converged' && criteriaRegression) {
  warn('DISCIPLINE: Findings converged but criteria regressed — forcing retry (dual convergence gate)')
  verdict = 'retry'  // override — regression is highest priority
} else if (verdict === 'converged' && !criteriaConverged) {
  warn('DISCIPLINE: Findings converged but SCR below threshold — forcing retry (dual convergence gate)')
  verdict = 'retry'  // override — criteria must also converge
}
```

## STEP 3: Act on Verdict

```javascript
if (verdict === 'converged') {
  updateCheckpoint({
    phase: 'verify_mend', status: 'completed',
    artifact: resolutionReportPath, artifact_hash: sha256(resolutionReport),
    phase_sequence: 7.5, team_name: null
  })
  // → Dispatcher proceeds to Phase 7.7 (TEST)

} else if (verdict === 'retry') {
  // Build progressive focus scope for re-review
  const focusResult = buildProgressiveFocus(resolutionReport, checkpoint.convergence.original_changed_files || [])

  // EC-9: Empty focus scope → halt convergence
  if (!focusResult) {
    warn(`No files modified by mend — cannot scope re-review. Convergence halted.`)
    checkpoint.convergence.history[checkpoint.convergence.history.length - 1].verdict = 'halted'
    checkpoint.convergence.history[checkpoint.convergence.history.length - 1].reason = 'empty_focus_scope'
    updateCheckpoint({ phase: 'verify_mend', status: 'completed',
      artifact: resolutionReportPath, artifact_hash: sha256(resolutionReport),
      phase_sequence: 7.5, team_name: null })
    return
  }

  // Store focus scope for Phase 6 re-review
  // BACK-008 FIX: Write focus file BEFORE incrementing round — crash between won't leave inconsistent state.
  const nextRound = checkpoint.convergence.round + 1
  Write(`tmp/arc/${id}/review-focus-round-${nextRound}.json`, JSON.stringify(focusResult))
  checkpoint.convergence.round = nextRound

  // CRITICAL: Reset code_review, goldmask_correlation, mend, and verify_mend phases to "pending"
  // The dispatcher scans PHASE_ORDER for the first "pending" phase.
  // Resetting code_review (index 6) ensures the dispatcher loops back to Phase 6
  // before reaching verify_mend (index 8).
  // NOTE: prePhaseCleanup(checkpoint) runs automatically before the re-review round
  // (called by the dispatcher for every delegated phase) to clean stale teams from
  // the prior round. This is what prevents team name collisions between rounds.
  // ASSERTION (decree-arbiter P2): Verify code_review precedes verify_mend in PHASE_ORDER
  const crIdx = PHASE_ORDER.indexOf('code_review')
  const vmIdx = PHASE_ORDER.indexOf('verify_mend')
  if (crIdx < 0 || vmIdx < 0 || crIdx >= vmIdx) {
    throw new Error(`PHASE_ORDER invariant violated: code_review (${crIdx}) must precede verify_mend (${vmIdx})`)
  }

  // NOTE: goldmask_verification is intentionally NOT reset on convergence retry.
  // Rationale: mend only touches files already in the diff scope — it does not introduce
  // new files. The blast-radius analysis from goldmask_verification remains valid because
  // the set of changed files is unchanged (only their content differs after mend fixes).
  // Re-running goldmask would produce the same file-level risk tiers.

  checkpoint.phases.code_review.status = 'pending'
  checkpoint.phases.code_review.artifact = null
  checkpoint.phases.code_review.artifact_hash = null
  checkpoint.phases.code_review.team_name = null      // BUG FIX: Clear stale team from prior round
  // QUAL-101 FIX: Reset goldmask_correlation so it re-correlates with new TOME on next cycle
  if (checkpoint.phases.goldmask_correlation) {
    checkpoint.phases.goldmask_correlation.status = 'pending'
    checkpoint.phases.goldmask_correlation.artifact = null
    checkpoint.phases.goldmask_correlation.artifact_hash = null
    checkpoint.phases.goldmask_correlation.team_name = null
  }
  checkpoint.phases.mend.status = 'pending'
  checkpoint.phases.mend.artifact = null
  checkpoint.phases.mend.artifact_hash = null
  checkpoint.phases.mend.team_name = null              // BUG FIX: Clear stale team from prior round
  checkpoint.phases.verify_mend.status = 'pending'
  checkpoint.phases.verify_mend.artifact = null      // Must null — stale artifact causes phantom hash match on resume
  checkpoint.phases.verify_mend.artifact_hash = null
  checkpoint.phases.verify_mend.team_name = null      // BUG FIX: Clear stale team from prior round

  updateCheckpoint(checkpoint)
  // → Dispatcher loops back to Phase 6 (code_review is next "pending" in PHASE_ORDER)

} else if (verdict === 'halted') {
  const round = checkpoint.convergence.round
  warn(`Convergence halted after ${round + 1} cycle(s): ${currentFindingCount} findings remain (${p1Count} P1). Proceeding to test.`)

  updateCheckpoint({
    phase: 'verify_mend', status: 'completed',
    artifact: resolutionReportPath, artifact_hash: sha256(resolutionReport),
    phase_sequence: 7.5, team_name: null
  })
  // → Dispatcher proceeds to Phase 7.7 (TEST) with warning
}
```

### File Velocity Integration (v1.80.0)

After each mend round completes, the dispatcher calls `updateFileVelocity(mendRound, checkpoint)` from [stagnation-sentinel.md](stagnation-sentinel.md). This enriches convergence decisions with per-file velocity classification:

- **improving**: Findings decreasing between rounds (healthy)
- **stagnant**: Touched 2+ rounds with <10% improvement (concern)
- **regressing**: Findings increasing between rounds (alarm)

The convergence controller can use `checkpoint.stagnation.file_velocity` to detect files that are consuming mend cycles without progress.

## Helper: countP2Findings

```javascript
// Count P2 findings from TOME content
// Matches <!-- RUNE:FINDING severity="P2" ... --> markers (case-insensitive for SEC-006 compliance)
function countP2Findings(tomeContent) {
  const markers = tomeContent.match(/<!-- RUNE:FINDING[^>]*severity="P2"[^>]*-->/gi) || []
  return markers.length
}
```

**Output**: Convergence verdict stored in checkpoint. On retry, phases reset to "pending" and dispatcher loops back.

**Failure policy**: Non-blocking. Halting proceeds to test with warning. The convergence gate never blocks the pipeline permanently; it either retries or gives up gracefully.

## Dispatcher Contract

**CRITICAL**: The dispatcher MUST use "first pending in PHASE_ORDER" scan to select the next phase. The convergence controller resets `code_review` to "pending" to trigger a loop-back. If the dispatcher were optimized to use "last completed + 1", the loop-back would silently fail and the pipeline would skip to Phase 7.7 (test).

The defensive assertion in STEP 3 (retry branch) verifies the PHASE_ORDER invariant at runtime: `code_review` index must be less than `verify_mend` index.
