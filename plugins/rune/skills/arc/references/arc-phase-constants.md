# Arc Phase Constants

Canonical phase order, timeouts, convergence budgets, and shared utilities.
Extracted from SKILL.md in v1.110.0 for phase-isolated context architecture.

**Consumers**: SKILL.md (checkpoint init), arc-phase-stop-hook.sh (phase ordering),
per-phase reference files (timeout values), arc-resume.md (schema migration)

## Phase Order

```javascript
const PHASE_ORDER = ['forge', 'plan_review', 'plan_refine', 'verification', 'semantic_verification', 'design_extraction', 'task_decomposition', 'work', 'storybook_verification', 'design_verification', 'gap_analysis', 'codex_gap_analysis', 'gap_remediation', 'goldmask_verification', 'code_review', 'goldmask_correlation', 'mend', 'verify_mend', 'design_iteration', 'test', 'test_coverage_critique', 'pre_ship_validation', 'release_quality_check', 'ship', 'bot_review_wait', 'pr_comment_resolution', 'merge']

// Heavy phases that MUST be delegated to sub-skills — never implemented inline.
// These phases consume significant tokens and require fresh teammate context windows.
// Context Advisory: Emitted by the dispatcher before each heavy phase is invoked.
// NOTE: This list covers phases that delegate to /rune:strive, /rune:appraise, /rune:mend.
// Phases like goldmask_verification and gap_remediation also spawn teams but are managed
// by their own reference files, not sub-skill commands — they are NOT included here.
const HEAVY_PHASES = ['work', 'code_review', 'mend']

// IMPORTANT: checkArcTimeout() runs BETWEEN phases, not during. A phase that exceeds
// its budget will only be detected after it finishes/times out internally.
// NOTE: SETUP_BUDGET (5 min, all delegated phases) and MEND_EXTRA_BUDGET (3 min, mend-only)
// are defined in arc-phase-mend.md.
```

**WARNING — Non-monotonic execution order**: Phase 5.8 (GAP REMEDIATION) executes **before** Phase 5.7 (GOLDMASK VERIFICATION). The `PHASE_ORDER` array defines the canonical execution sequence using phase **names**, not numbers. Any tooling that sorts by numeric phase ID will get the wrong order. The non-sequential numbering preserves backward compatibility with older checkpoints — do NOT renumber. Always use `PHASE_ORDER` for iteration order.

## Phase Timeouts

```javascript
// readTalismanSection: "arc"
const arc = readTalismanSection("arc")
// Talisman-aware phase timeouts (v1.40.0+): talisman overrides → hardcoded defaults
// CFG-DECREE-002: Clamp each talisman timeout to sane range (10s - 1hr)
const talismanTimeouts = arc?.timeouts ?? {}
for (const [key, val] of Object.entries(talismanTimeouts)) {
  if (typeof val === 'number') {
    talismanTimeouts[key] = Math.max(10_000, Math.min(val, 3_600_000))
  }
}

const PHASE_TIMEOUTS = {
  forge:         talismanTimeouts.forge ?? 900_000,    // 15 min (inner 10m + 5m setup)
  plan_review:   talismanTimeouts.plan_review ?? 900_000,    // 15 min (inner 10m + 5m setup)
  plan_refine:   talismanTimeouts.plan_refine ?? 180_000,    //  3 min (orchestrator-only, no team)
  verification:  talismanTimeouts.verification ?? 30_000,    // 30 sec (orchestrator-only, no team)
  semantic_verification: talismanTimeouts.semantic_verification ?? 180_000,  //  3 min (orchestrator-only, inline codex exec)
  design_extraction: talismanTimeouts.design_extraction ?? 600_000,  // 10 min (conditional — gated by design_sync.enabled + Figma URL)
  task_decomposition: talismanTimeouts.task_decomposition ?? 300_000,  //  5 min (orchestrator-only, inline codex exec)
  work:          talismanTimeouts.work ?? 2_100_000,    // 35 min (inner 30m + 5m setup)
  storybook_verification: talismanTimeouts.storybook_verification ?? 900_000,  // 15 min (conditional — gated by storybook.enabled in talisman misc)
  design_verification: talismanTimeouts.design_verification ?? 480_000,  //  8 min (conditional — gated by VSM files from design_extraction)
  gap_analysis:  talismanTimeouts.gap_analysis ?? 720_000,   // 12 min (inner 8m + 2m setup + 2m aggregate)
  codex_gap_analysis: talismanTimeouts.codex_gap_analysis ?? 660_000,  // 11 min (orchestrator-only, inline codex exec)
  gap_remediation: talismanTimeouts.gap_remediation ?? 900_000,  // 15 min (inner 10m + 5m setup)
  code_review:   talismanTimeouts.code_review ?? 900_000,    // 15 min (inner 10m + 5m setup)
  mend:          talismanTimeouts.mend ?? 1_380_000,    // 23 min (inner 15m + 5m setup + 3m ward/cross-file)
  verify_mend:   talismanTimeouts.verify_mend ?? 240_000,    //  4 min (orchestrator-only, no team)
  design_iteration: talismanTimeouts.design_iteration ?? 900_000,  // 15 min (conditional)
  test:          talismanTimeouts.test ?? 1_500_000,      // 25 min without E2E. Dynamic: 50 min with E2E (3_000_000)
  test_coverage_critique: talismanTimeouts.test_coverage_critique ?? 600_000,  // 10 min (orchestrator-only, inline codex exec)
  pre_ship_validation: talismanTimeouts.pre_ship_validation ?? 360_000,  //  6 min (orchestrator-only)
  release_quality_check: talismanTimeouts.release_quality_check ?? 300_000,  //  5 min (orchestrator-only, inline codex exec)
  bot_review_wait: talismanTimeouts.bot_review_wait ?? 900_000,  // 15 min (orchestrator-only, polling)
  pr_comment_resolution: talismanTimeouts.pr_comment_resolution ?? 1_200_000,  // 20 min (orchestrator-only)
  goldmask_verification: talismanTimeouts.goldmask_verification ?? 900_000,  // 15 min (inner 10m + 5m setup)
  goldmask_correlation:  talismanTimeouts.goldmask_correlation ?? 60_000,    //  1 min (orchestrator-only, no team)
  ship:          talismanTimeouts.ship ?? 300_000,      //  5 min (orchestrator-only)
  merge:         talismanTimeouts.merge ?? 600_000,     // 10 min (orchestrator-only)
}
```

## Dynamic Timeout Calculation

```javascript
// Tier-based dynamic timeout — replaces fixed ARC_TOTAL_TIMEOUT.
// See review-mend-convergence.md for tier selection logic.
const ARC_TOTAL_TIMEOUT_DEFAULT = 17_670_000  // 294.5 min fallback (LIGHT tier minimum)
const ARC_TOTAL_TIMEOUT_HARD_CAP = 19_200_000  // 320 min (5.33 hours) — absolute hard cap
const STALE_THRESHOLD = 300_000      // 5 min
const MEND_RETRY_TIMEOUT = 780_000   // 13 min (inner 5m polling + 5m setup + 3m ward/cross-file)

// Convergence cycle budgets
const CYCLE_BUDGET = {
  pass_1_review: 900_000,    // 15 min (full Phase 6)
  pass_N_review: 540_000,    //  9 min (60% of full — focused re-review)
  pass_1_mend:   1_380_000,  // 23 min (full Phase 7)
  pass_N_mend:   780_000,    // 13 min (retry mend)
  convergence:   240_000,    //  4 min (Phase 7.5 evaluation)
}

function calculateDynamicTimeout(tier) {
  const basePhaseBudget = PHASE_TIMEOUTS.forge + PHASE_TIMEOUTS.plan_review +
    PHASE_TIMEOUTS.plan_refine + PHASE_TIMEOUTS.verification +
    PHASE_TIMEOUTS.semantic_verification + PHASE_TIMEOUTS.design_extraction +
    PHASE_TIMEOUTS.task_decomposition + PHASE_TIMEOUTS.work +
    PHASE_TIMEOUTS.storybook_verification + PHASE_TIMEOUTS.design_verification +
    PHASE_TIMEOUTS.gap_analysis +
    PHASE_TIMEOUTS.codex_gap_analysis + PHASE_TIMEOUTS.gap_remediation +
    PHASE_TIMEOUTS.goldmask_verification + PHASE_TIMEOUTS.goldmask_correlation +
    PHASE_TIMEOUTS.design_iteration +
    PHASE_TIMEOUTS.test + PHASE_TIMEOUTS.test_coverage_critique +
    PHASE_TIMEOUTS.pre_ship_validation + PHASE_TIMEOUTS.release_quality_check +
    PHASE_TIMEOUTS.bot_review_wait + PHASE_TIMEOUTS.pr_comment_resolution +
    PHASE_TIMEOUTS.ship + PHASE_TIMEOUTS.merge
  const cycle1Budget = CYCLE_BUDGET.pass_1_review + CYCLE_BUDGET.pass_1_mend + CYCLE_BUDGET.convergence
  const cycleNBudget = CYCLE_BUDGET.pass_N_review + CYCLE_BUDGET.pass_N_mend + CYCLE_BUDGET.convergence
  const maxCycles = tier?.maxCycles ?? 3
  const dynamicTimeout = basePhaseBudget + cycle1Budget + (maxCycles - 1) * cycleNBudget
  return Math.min(dynamicTimeout, ARC_TOTAL_TIMEOUT_HARD_CAP)
}
```

## Shared Utilities

```javascript
// Shared prototype pollution guard — used by prePhaseCleanup (ARC-6) and ORCH-1 resume cleanup.
const FORBIDDEN_PHASE_KEYS = new Set(['__proto__', 'constructor', 'prototype'])

// Cascade circuit breaker tracker — updates codex_cascade checkpoint fields.
// Called after every classifyCodexError() in Codex integration phases (4.5, 7.8, 8.55).
function updateCascadeTracker(checkpoint, classified) {
  if (!checkpoint.codex_cascade) {
    checkpoint.codex_cascade = {
      total_attempted: 0, total_succeeded: 0, total_failed: 0,
      consecutive_failures: 0, cascade_warning: false,
      cascade_skipped: 0, last_failure_phase: null
    }
  }
  const cc = checkpoint.codex_cascade
  cc.total_attempted++

  if (classified.category === "SUCCESS") {
    cc.total_succeeded++
    cc.consecutive_failures = 0
  } else {
    cc.total_failed++
    cc.consecutive_failures++
    cc.last_failure_phase = checkpoint.current_phase

    // Trigger cascade warning on 3+ consecutive failures or AUTH/QUOTA errors
    if (cc.consecutive_failures >= 3 || classified.category === "AUTH" || classified.category === "QUOTA") {
      cc.cascade_warning = true
    }
  }

  updateCheckpoint({ codex_cascade: cc })
}
```

See [phase-tool-matrix.md](phase-tool-matrix.md) for per-phase tool restrictions and time budget details.
