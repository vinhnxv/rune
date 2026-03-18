# Phase 5.99: Verify Inspect (Inspect Convergence Controller) — Full Algorithm

Evaluates inspect results and determines whether to loop back for another
inspect cycle or proceed to goldmask_verification. Follows the same convergence
pattern as verify-mend.md but uses inspect-specific metrics.

**Team**: None (orchestrator-only evaluation)
**Tools**: Read, Glob, Grep, Write, Bash
**Duration**: Max 4 minutes per convergence evaluation

See [verify-mend.md](verify-mend.md) for the shared convergence pattern reference.

## Entry Guard

```javascript
// Skip if inspect was skipped
if (checkpoint.phases.inspect.status === 'skipped') {
  updateCheckpoint({ phase: 'verify_inspect', status: 'skipped', phase_sequence: 5.99, team_name: null })
  return
}

updateCheckpoint({ phase: 'verify_inspect', status: 'in_progress', phase_sequence: 5.99, team_name: null })
```

## STEP 1: Read VERDICT and Evaluate

```javascript
const id = checkpoint.id
const inspectRound = checkpoint.inspect_convergence?.round ?? 0

// Read current VERDICT.md
let verdictContent
try {
  verdictContent = Read(`tmp/arc/${id}/inspect-verdict.md`)
} catch (e) {
  warn('Phase 5.99: VERDICT.md not found — halting convergence')
  checkpoint.inspect_convergence.history.push({
    round: inspectRound, completion_pct: null, p1_count: null,
    fixed_count: null, verdict: 'halted', reason: 'verdict_missing',
    timestamp: new Date().toISOString()
  })
  updateCheckpoint({ phase: 'verify_inspect', status: 'completed', phase_sequence: 5.99, team_name: null })
  return
}

// Extract current metrics — dual scoring (adjusted preferred, raw fallback, legacy compat)
// FLAW-001 FIX: Use colon-free patterns matching VERDICT.md pipe-delimited format
const adjustedMatch = verdictContent.match(/Overall Completion \(Adjusted\)\s*\|\s*(\d+(?:\.\d+)?)%/)
const rawMatch = verdictContent.match(/Overall Completion \(Raw\)\s*\|\s*(\d+(?:\.\d+)?)%/)
const legacyMatch = verdictContent.match(/Overall Completion:\s*(\d+(?:\.\d+)?)%/)
  ?? verdictContent.match(/Overall Completion\s*\|\s*(\d+(?:\.\d+)?)%/)

const rawPct = rawMatch ? parseFloat(rawMatch[1]) : (legacyMatch ? parseFloat(legacyMatch[1]) : 0)
const adjustedPct = adjustedMatch ? parseFloat(adjustedMatch[1]) : rawPct
const completionPct = Number.isFinite(adjustedPct) ? adjustedPct : 0  // NaN guard (FRINGE-003)

// Log both for transparency
log(`Verify-inspect: raw=${rawMatch?.[1] ?? legacyMatch?.[1] ?? '?'}%, adjusted=${adjustedMatch?.[1] ?? '?'}%`)

// P1 count — adjusted preferred (excludes INTENTIONAL/EXCLUDED/FP), raw fallback, legacy compat
const adjP1Match = verdictContent.match(/P1 Findings \(Adjusted\)\s*\|\s*(\d+)/)
const rawP1Match = verdictContent.match(/P1 Findings \(Raw\)\s*\|\s*(\d+)/)
// NaN guard (RUIN-003): parseInt may return NaN on non-numeric capture
const rawP1 = adjP1Match
  ? parseInt(adjP1Match[1], 10)
  : rawP1Match
    ? parseInt(rawP1Match[1], 10)
    : (verdictContent.match(/severity="P1"/gi) || []).length  // legacy fallback
const p1Markers = Number.isFinite(rawP1) ? rawP1 : 0

const fixedCount = checkpoint.phases.inspect_fix?.fixed_count ?? 0
const deferredCount = checkpoint.phases.inspect_fix?.deferred_count ?? 0

// readTalismanSection: "inspect"
const inspectConfig = readTalismanSection("inspect") ?? {}
const maxRounds = inspectConfig.max_rounds ?? checkpoint.inspect_convergence?.max_rounds ?? 2
const threshold = inspectConfig.threshold ?? checkpoint.inspect_convergence?.threshold ?? 95
```

## STEP 2: Evaluate Convergence

```javascript
function evaluateInspectConvergence(completionPct, p1Count, fixedCount, inspectRound, maxRounds, threshold) {
  // Gate 1: Completion threshold met AND no P1 findings → converge
  if (completionPct >= threshold && p1Count === 0) {
    return 'converge'
  }

  // Gate 2: Max rounds exceeded → halt
  if (inspectRound + 1 >= maxRounds) {
    return 'halt'
  }

  // Gate 3: No progress in this round (inspect_fix made 0 fixes) → halt
  if (fixedCount === 0 && inspectRound > 0) {
    return 'halt'
  }

  // Default: retry — completion below threshold or P1 findings remain
  return 'retry'
}

const verdict = evaluateInspectConvergence(completionPct, p1Markers, fixedCount, inspectRound, maxRounds, threshold)

// Record convergence history (dual scoring)
checkpoint.inspect_convergence.history.push({
  round: inspectRound,
  completion_pct: completionPct,         // adjusted (used for convergence)
  completion_pct_raw: Number.isFinite(rawPct) ? rawPct : null,
  p1_count: p1Markers,                   // adjusted (used for convergence)
  fixed_count: fixedCount,
  deferred_count: deferredCount,
  verdict,
  timestamp: new Date().toISOString()
})
```

## STEP 3: Act on Verdict

```javascript
if (verdict === 'converge') {
  updateCheckpoint({
    phase: 'verify_inspect', status: 'completed', phase_sequence: 5.99, team_name: null,
    artifact: `tmp/arc/${id}/inspect-verdict.md`,
    artifact_hash: sha256(verdictContent),
  })
  // → Dispatcher proceeds to goldmask_verification

} else if (verdict === 'retry') {
  // Build progressive focus scope for next inspect round
  // Narrow to only the gaps that were NOT fixed in this round
  const remainingGaps = verdictContent.match(/<!-- GAP:[^>]*-->/g) || []
  const focusResult = {
    round: inspectRound + 1,
    remaining_gap_count: remainingGaps.length,
    focused_diff: Bash(`git diff ${Bash("git rev-parse --abbrev-ref HEAD@{upstream} 2>/dev/null || echo main").trim().split('/').pop()}...HEAD`),
  }

  const nextRound = inspectRound + 1
  Write(`tmp/arc/${id}/inspect-focus-round-${nextRound}.json`, JSON.stringify(focusResult))
  checkpoint.inspect_convergence.round = nextRound

  // Shared convergence budget tracking
  // Deduct one cycle's budget from remaining arc timeout
  const cycleBudget = PHASE_TIMEOUTS.inspect + PHASE_TIMEOUTS.inspect_fix + PHASE_TIMEOUTS.verify_inspect
  const elapsedBudget = (checkpoint.inspect_convergence.history.length) * cycleBudget
  if (elapsedBudget > cycleBudget * maxRounds) {
    warn(`Inspect convergence budget exhausted after ${inspectRound + 1} rounds — halting`)
    checkpoint.inspect_convergence.history[checkpoint.inspect_convergence.history.length - 1].verdict = 'halt'
    checkpoint.inspect_convergence.history[checkpoint.inspect_convergence.history.length - 1].reason = 'budget_exhausted'
    updateCheckpoint({ phase: 'verify_inspect', status: 'completed', phase_sequence: 5.99, team_name: null,
      artifact: `tmp/arc/${id}/inspect-verdict.md`, artifact_hash: sha256(verdictContent) })
    return
  }

  // CRITICAL: Reset inspect, inspect_fix, verify_inspect to "pending"
  // The dispatcher scans PHASE_ORDER for the first "pending" phase.
  // Resetting inspect ensures the dispatcher loops back to Phase 5.9.
  // ASSERTION: Verify inspect precedes inspect_fix and verify_inspect in PHASE_ORDER
  const inspIdx = PHASE_ORDER.indexOf('inspect')
  const fixIdx = PHASE_ORDER.indexOf('inspect_fix')
  const viIdx = PHASE_ORDER.indexOf('verify_inspect')
  if (inspIdx < 0 || fixIdx < 0 || viIdx < 0 || inspIdx >= fixIdx || fixIdx >= viIdx) {
    throw new Error(`PHASE_ORDER invariant violated: inspect (${inspIdx}) < inspect_fix (${fixIdx}) < verify_inspect (${viIdx})`)
  }

  checkpoint.phases.inspect.status = 'pending'
  checkpoint.phases.inspect.artifact = null
  checkpoint.phases.inspect.artifact_hash = null
  checkpoint.phases.inspect.team_name = null
  checkpoint.phases.inspect.completion_pct = null
  checkpoint.phases.inspect.p1_count = null
  checkpoint.phases.inspect.verdict = null
  checkpoint.phases.inspect_fix.status = 'pending'
  checkpoint.phases.inspect_fix.artifact = null
  checkpoint.phases.inspect_fix.artifact_hash = null
  checkpoint.phases.inspect_fix.team_name = null
  checkpoint.phases.inspect_fix.fixed_count = null
  checkpoint.phases.inspect_fix.deferred_count = null
  checkpoint.phases.verify_inspect.status = 'pending'
  checkpoint.phases.verify_inspect.artifact = null
  checkpoint.phases.verify_inspect.artifact_hash = null
  checkpoint.phases.verify_inspect.team_name = null

  updateCheckpoint(checkpoint)
  // → Dispatcher loops back to Phase 5.9 (inspect is next "pending" in PHASE_ORDER)

} else if (verdict === 'halt') {
  const round = checkpoint.inspect_convergence.round
  warn(`Inspect convergence halted after ${round + 1} cycle(s): ${completionPct}% complete, ${p1Markers} P1 findings remain. Proceeding to goldmask_verification.`)

  updateCheckpoint({
    phase: 'verify_inspect', status: 'completed', phase_sequence: 5.99, team_name: null,
    artifact: `tmp/arc/${id}/inspect-verdict.md`,
    artifact_hash: sha256(verdictContent),
  })
  // → Dispatcher proceeds to goldmask_verification with warning
}
```

## Dispatcher Contract

**CRITICAL**: The dispatcher MUST use "first pending in PHASE_ORDER" scan. The convergence controller resets `inspect` to "pending" to trigger a loop-back. This is the same pattern used by verify-mend for the review-mend convergence loop.

The defensive assertion in STEP 3 (retry branch) verifies the PHASE_ORDER invariant at runtime: `inspect` index must be less than `inspect_fix` index, which must be less than `verify_inspect` index.

**Output**: Convergence verdict stored in checkpoint. On retry, phases reset to "pending" and dispatcher loops back.

**Failure policy**: Non-blocking. Halting proceeds to goldmask_verification with warning. The convergence gate never blocks the pipeline permanently; it either retries or gives up gracefully.
