# Phase 7.7.7: Verify Browser Test (Browser Test Convergence Controller)

Evaluates browser test results and determines whether to loop back for another
test→fix cycle or proceed to `test_coverage_critique`. Follows the same convergence
pattern as [verify-inspect.md](verify-inspect.md) and [verify-mend.md](verify-mend.md).

**Team**: None (orchestrator-only evaluation, no team spawned)
**Tools**: Read, Glob, Grep, Write
**Duration**: Max 4 minutes per convergence evaluation

## Entry Guard

```javascript
// ═══════════════════════════════════════════════════════
// ENTRY GUARD
// ═══════════════════════════════════════════════════════

// Skip if browser_test was skipped
if (checkpoint.phases.browser_test.status === "skipped") {
  updateCheckpoint({ phase: "verify_browser_test", status: "skipped" })
  return
}

updateCheckpoint({ phase: "verify_browser_test", status: "in_progress" })

const id = checkpoint.id
const round = checkpoint.browser_test_convergence.round

// Read failures from browser test phase
const failuresFile = `tmp/arc/${id}/browser-test-failures.json`
let failures
try {
  failures = JSON.parse(Read(failuresFile))
} catch (e) {
  warn("browser-test-failures.json not found — browser test may have timed out")
  updateCheckpoint({ phase: "verify_browser_test", status: "completed" })
  return
}

// EC-1 analog: If no failures, convergence is immediate
if (!failures.failures || failures.failures.length === 0) {
  checkpoint.browser_test_convergence.history.push({
    round,
    routes_tested: checkpoint.phases.browser_test.routes_tested,
    routes_passed: checkpoint.phases.browser_test.routes_tested,
    routes_failed: 0,
    fixes_applied: 0,
    verdict: 'converged',
    timestamp: new Date().toISOString()
  })
  updateCheckpoint({ phase: "verify_browser_test", status: "completed" })
  return
}
```

## STEP 1: Read Fix Results

```javascript
// ═══════════════════════════════════════════════════════
// STEP 1: READ FIX RESULTS
// ═══════════════════════════════════════════════════════

let fixCount = 0
try {
  const fixReport = Read(`tmp/arc/${id}/browser-fix-report.md`)
  fixCount = (fixReport.match(/status:\s*fixed/gi) || []).length
} catch (e) {
  warn("browser-fix-report.md not found — fix phase may have been skipped or timed out")
}

const failCount = failures.failures.length
```

## STEP 2: Evaluate Convergence

```javascript
// ═══════════════════════════════════════════════════════
// STEP 2: EVALUATE CONVERGENCE
// ═══════════════════════════════════════════════════════

const maxCycles = checkpoint.browser_test_convergence.max_cycles  // MAX_BROWSER_TEST_CYCLES (3)
let verdict = 'converged'

// EC-1: Zero progress detection — prevents infinite retry on unfixable issues
if (fixCount === 0 && failCount > 0) {
  verdict = 'halted'
  warn(`Browser test fix made 0 progress (${failCount} failures remain) — halting`)
}
// Budget check: max cycles reached
else if (round + 1 >= maxCycles) {
  verdict = 'halted'
  warn(`Browser test convergence budget exhausted after ${round + 1} cycles — ${failCount} failures remain`)
}
// Some failures remain but progress was made → retry
else if (failCount > 0 && fixCount > 0) {
  verdict = 'retry'
}
// All fixed (failCount === 0 handled by entry guard, but defensive)
else {
  verdict = 'converged'
}

// Record history
checkpoint.browser_test_convergence.history.push({
  round,
  routes_tested: checkpoint.phases.browser_test.routes_tested,
  routes_passed: checkpoint.phases.browser_test.routes_passed,
  routes_failed: failCount,
  fixes_applied: fixCount,
  verdict,
  timestamp: new Date().toISOString()
})
```

## STEP 3: Act on Verdict

```javascript
// ═══════════════════════════════════════════════════════
// STEP 3: ACT ON VERDICT
// ═══════════════════════════════════════════════════════

if (verdict === 'converged') {
  updateCheckpoint({ phase: "verify_browser_test", status: "completed" })
  // → Dispatcher proceeds to test_coverage_critique

} else if (verdict === 'retry') {
  // ASSERTION: Verify PHASE_ORDER invariant — browser_test must precede verify_browser_test
  // Same defensive check as verify-inspect.md STEP 3
  const btIdx = PHASE_ORDER.indexOf('browser_test')
  const btfIdx = PHASE_ORDER.indexOf('browser_test_fix')
  const vbtIdx = PHASE_ORDER.indexOf('verify_browser_test')
  if (btIdx < 0 || btfIdx < 0 || vbtIdx < 0 || btIdx >= btfIdx || btfIdx >= vbtIdx) {
    throw new Error(`PHASE_ORDER invariant violated: browser_test (${btIdx}) < browser_test_fix (${btfIdx}) < verify_browser_test (${vbtIdx})`)
  }

  // CRITICAL: Reset 3 phases to "pending" for loop-back
  // Mirrors verify_inspect STEP 3 retry pattern
  checkpoint.phases.browser_test.status = 'pending'
  checkpoint.phases.browser_test.artifact = null
  checkpoint.phases.browser_test.artifact_hash = null
  checkpoint.phases.browser_test.team_name = null
  checkpoint.phases.browser_test.routes_tested = null
  checkpoint.phases.browser_test.routes_passed = null
  checkpoint.phases.browser_test.routes_failed = null

  checkpoint.phases.browser_test_fix.status = 'pending'
  checkpoint.phases.browser_test_fix.artifact = null
  checkpoint.phases.browser_test_fix.artifact_hash = null
  checkpoint.phases.browser_test_fix.team_name = null
  checkpoint.phases.browser_test_fix.fixed_count = null
  checkpoint.phases.browser_test_fix.skipped_count = null

  checkpoint.phases.verify_browser_test.status = 'pending'
  checkpoint.phases.verify_browser_test.artifact = null
  checkpoint.phases.verify_browser_test.artifact_hash = null
  checkpoint.phases.verify_browser_test.team_name = null

  checkpoint.browser_test_convergence.round = round + 1
  updateCheckpoint(checkpoint)
  // → Dispatcher loops back to browser_test (first pending in PHASE_ORDER)

} else if (verdict === 'halted') {
  warn(`Browser test convergence halted: ${failCount} failures remain after ${round + 1} cycle(s). Proceeding to test_coverage_critique.`)
  updateCheckpoint({ phase: "verify_browser_test", status: "completed" })
  // → Dispatcher proceeds to test_coverage_critique with warning
}
```

## Dispatcher Contract

**CRITICAL**: Same contract as verify_mend and verify_inspect — the dispatcher MUST use
"first pending in PHASE_ORDER" scan. The convergence controller resets `browser_test` to
"pending" to trigger loop-back. The defensive assertion verifies the PHASE_ORDER invariant
at runtime: `browser_test` index < `browser_test_fix` index < `verify_browser_test` index.

**Output**: Convergence verdict stored in `checkpoint.browser_test_convergence.history`.
On retry, all 3 phases reset to "pending" and the dispatcher naturally loops back.

**Failure policy**: Non-blocking. Halting proceeds to `test_coverage_critique` with a warning.
The convergence gate never blocks the pipeline permanently; it either retries or gives up gracefully.

## Convergence State Schema

```javascript
// Initialized in checkpoint-init.md alongside existing convergence/inspect_convergence
checkpoint.browser_test_convergence = {
  round: 0,
  max_cycles: MAX_BROWSER_TEST_CYCLES,  // 3 (from arc-phase-constants.md)
  history: [],  // Array of { round, routes_tested, routes_passed, routes_failed, fixes_applied, verdict, timestamp }
}
```

## References

- [verify-inspect.md](verify-inspect.md) — analogous convergence controller pattern
- [verify-mend.md](verify-mend.md) — original convergence controller (review-mend loop)
- [arc-phase-constants.md](arc-phase-constants.md) — `MAX_BROWSER_TEST_CYCLES`, `BROWSER_TEST_CYCLE_BUDGET`
