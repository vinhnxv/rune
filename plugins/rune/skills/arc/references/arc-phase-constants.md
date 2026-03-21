# Arc Phase Constants

Canonical phase order, timeouts, convergence budgets, and shared utilities.
Extracted from SKILL.md in v1.110.0 for phase-isolated context architecture.

**Consumers**: SKILL.md (checkpoint init), arc-phase-stop-hook.sh (phase ordering),
per-phase reference files (timeout values), arc-resume.md (schema migration)

## Phase Order

```javascript
const PHASE_ORDER = ['forge', 'forge_qa', 'plan_review', 'plan_refine', 'verification', 'semantic_verification', 'design_extraction', 'design_prototype', 'task_decomposition', 'work', 'work_qa', 'drift_review', 'storybook_verification', 'design_verification', 'ux_verification', 'gap_analysis', 'gap_analysis_qa', 'codex_gap_analysis', 'gap_remediation', 'inspect', 'inspect_fix', 'verify_inspect', 'goldmask_verification', 'code_review', 'code_review_qa', 'goldmask_correlation', 'mend', 'mend_qa', 'verify_mend', 'design_iteration', 'test', 'test_qa', 'test_coverage_critique', 'deploy_verify', 'pre_ship_validation', 'release_quality_check', 'ship', 'bot_review_wait', 'pr_comment_resolution', 'merge']

// Heavy phases that MUST be delegated to sub-skills — never implemented inline.
// These phases consume significant tokens and require fresh teammate context windows.
// Context Advisory: Emitted by the dispatcher before each heavy phase is invoked.
// NOTE: This list covers phases that delegate to /rune:strive, /rune:appraise, /rune:mend.
// Phases like goldmask_verification and gap_remediation also spawn teams but are managed
// by their own reference files, not sub-skill commands — they are NOT included here.
const HEAVY_PHASES = ['work', 'code_review', 'mend', 'inspect']

// IMPORTANT: checkArcTimeout() runs BETWEEN phases, not during. A phase that exceeds
// its budget will only be detected after it finishes/times out internally.
// NOTE: SETUP_BUDGET (5 min, all delegated phases) and MEND_EXTRA_BUDGET (3 min, mend-only)
// are defined in arc-phase-mend.md.
```

**WARNING — Non-monotonic execution order**: Phase 5.8 (GAP REMEDIATION) executes **before** Phase 5.7 (GOLDMASK VERIFICATION). The `PHASE_ORDER` array defines the canonical execution sequence using phase **names**, not numbers. Any tooling that sorts by numeric phase ID will get the wrong order. The non-sequential numbering preserves backward compatibility with older checkpoints — do NOT renumber. Always use `PHASE_ORDER` for iteration order.

**DECREE-001 Guard — Phase dispatch assertion**: All phase dispatch code MUST use `PHASE_ORDER` for iteration. The following assertion validates correct ordering:

```javascript
// Assertion: Verify phase dispatch uses PHASE_ORDER, not numeric sorting
function assertPhaseOrderCorrect(nextPhase, currentPhase) {
  const currentIndex = PHASE_ORDER.indexOf(currentPhase)
  const nextIndex = PHASE_ORDER.indexOf(nextPhase)
  if (nextIndex !== currentIndex + 1) {
    throw new Error(`DECREE-001: Phase ordering violation — ${currentPhase} (index ${currentIndex}) should be followed by ${PHASE_ORDER[currentIndex + 1]}, not ${nextPhase} (index ${nextIndex})`)
  }
}
```

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
  semantic_verification: talismanTimeouts.semantic_verification ?? 720_000,  // 12 min (delegated to codex-phase-handler teammate)
  design_extraction: talismanTimeouts.design_extraction ?? 600_000,  // 10 min (conditional — gated by design_sync.enabled + Figma URL)
  design_prototype: talismanTimeouts.design_prototype ?? 600_000,  // 10 min (conditional — gated by design_sync.enabled + VSM files from design_extraction)
  task_decomposition: talismanTimeouts.task_decomposition ?? 600_000,  // 10 min (delegated to codex-phase-handler teammate)
  work:          talismanTimeouts.work ?? 2_100_000,    // 35 min (inner 30m + 5m setup)
  drift_review:  talismanTimeouts.drift_review ?? 120_000,  // 2 min (inline, no team)
  storybook_verification: talismanTimeouts.storybook_verification ?? 900_000,  // 15 min (conditional — gated by storybook.enabled in talisman misc)
  design_verification: talismanTimeouts.design_verification ?? 480_000,  //  8 min (conditional — gated by VSM files from design_extraction)
  ux_verification: talismanTimeouts.ux_verification ?? 300_000,  //  5 min (conditional — gated by ux.enabled + frontend files detected)
  gap_analysis:  talismanTimeouts.gap_analysis ?? 720_000,   // 12 min (inner 8m + 2m setup + 2m aggregate)
  codex_gap_analysis: talismanTimeouts.codex_gap_analysis ?? 960_000,  // 16 min (delegated to codex-phase-handler teammate)
  gap_remediation: talismanTimeouts.gap_remediation ?? 900_000,  // 15 min (inner 10m + 5m setup)
  inspect:       talismanTimeouts.inspect ?? 900_000,       // 15 min (4 Inspector Ashes + verdict-binder)
  inspect_fix:   talismanTimeouts.inspect_fix ?? 900_000,   // 15 min (gap-fixer agents for FIXABLE findings)
  verify_inspect: talismanTimeouts.verify_inspect ?? 240_000, // 4 min (convergence evaluation, no team)
  code_review:   talismanTimeouts.code_review ?? 900_000,    // 15 min (inner 10m + 5m setup)
  mend:          talismanTimeouts.mend ?? 1_380_000,    // 23 min (inner 15m + 5m setup + 3m ward/cross-file)
  verify_mend:   talismanTimeouts.verify_mend ?? 240_000,    //  4 min (orchestrator-only, no team)
  design_iteration: talismanTimeouts.design_iteration ?? 900_000,  // 15 min (conditional)
  test:          talismanTimeouts.test ?? 1_500_000,      // 25 min without E2E. Dynamic: 50 min with E2E (3_000_000)
  test_coverage_critique: talismanTimeouts.test_coverage_critique ?? 900_000,  // 15 min (delegated to codex-phase-handler teammate)
  deploy_verify: talismanTimeouts.deploy_verify ?? 300_000,  //  5 min (conditional — gated by migration/API/config file changes)
  pre_ship_validation: talismanTimeouts.pre_ship_validation ?? 360_000,  //  6 min (orchestrator-only)
  release_quality_check: talismanTimeouts.release_quality_check ?? 600_000,  // 10 min (delegated to codex-phase-handler teammate)
  bot_review_wait: talismanTimeouts.bot_review_wait ?? 900_000,  // 15 min (orchestrator-only, polling)
  pr_comment_resolution: talismanTimeouts.pr_comment_resolution ?? 1_200_000,  // 20 min (orchestrator-only)
  goldmask_verification: talismanTimeouts.goldmask_verification ?? 900_000,  // 15 min (inner 10m + 5m setup)
  goldmask_correlation:  talismanTimeouts.goldmask_correlation ?? 60_000,    //  1 min (orchestrator-only, no team)
  ship:          talismanTimeouts.ship ?? 300_000,      //  5 min (orchestrator-only)
  merge:         talismanTimeouts.merge ?? 600_000,     // 10 min (orchestrator-only)
  forge_qa:        talismanTimeouts.forge_qa ?? 300_000,        //  5 min (QA gate — 1 agent)
  work_qa:         talismanTimeouts.work_qa ?? 300_000,         //  5 min (QA gate — 1 agent)
  gap_analysis_qa: talismanTimeouts.gap_analysis_qa ?? 300_000, //  5 min (QA gate — 1 agent)
  code_review_qa:  talismanTimeouts.code_review_qa ?? 300_000,  //  5 min (QA gate — 1 agent)
  mend_qa:         talismanTimeouts.mend_qa ?? 300_000,         //  5 min (QA gate — 1 agent)
  test_qa:         talismanTimeouts.test_qa ?? 300_000,         //  5 min (QA gate — 1 agent)
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

// Batch testing configuration defaults (v1.165.0+)
// readTalismanSection: "testing"
const testing = readTalismanSection("testing")
const BATCH_CONFIG = {
  target_batch_duration_ms: testing?.batch?.target_batch_duration_ms ?? 180_000,
  min_batch_size: testing?.batch?.min_batch_size ?? 1,
  max_batch_size: testing?.batch?.max_batch_size ?? 20,
  hard_batch_timeout_ms: testing?.batch?.hard_batch_timeout_ms ?? 240_000,
  max_fix_retries: testing?.batch?.max_fix_retries ?? 2,
  inter_batch_delay_ms: testing?.batch?.inter_batch_delay_ms ?? 5_000,
  max_batch_iterations: testing?.batch?.max_batch_iterations ?? 50,
  avg_duration: {
    unit: testing?.batch?.avg_duration?.unit ?? 10_000,
    integration: testing?.batch?.avg_duration?.integration ?? 30_000,
    e2e: testing?.batch?.avg_duration?.e2e ?? 60_000,
    contract: testing?.batch?.avg_duration?.contract ?? 15_000,
    extended: testing?.batch?.avg_duration?.extended ?? 120_000
  }
}

function calculateDynamicTimeout(tier) {
  const basePhaseBudget = PHASE_TIMEOUTS.forge + PHASE_TIMEOUTS.forge_qa +
    PHASE_TIMEOUTS.plan_review +
    PHASE_TIMEOUTS.plan_refine + PHASE_TIMEOUTS.verification +
    PHASE_TIMEOUTS.semantic_verification + PHASE_TIMEOUTS.design_extraction +
    PHASE_TIMEOUTS.design_prototype + PHASE_TIMEOUTS.task_decomposition +
    PHASE_TIMEOUTS.work + PHASE_TIMEOUTS.work_qa +
    PHASE_TIMEOUTS.storybook_verification + PHASE_TIMEOUTS.design_verification +
    PHASE_TIMEOUTS.ux_verification +
    PHASE_TIMEOUTS.gap_analysis + PHASE_TIMEOUTS.gap_analysis_qa +
    PHASE_TIMEOUTS.codex_gap_analysis + PHASE_TIMEOUTS.gap_remediation +
    PHASE_TIMEOUTS.inspect + PHASE_TIMEOUTS.inspect_fix + PHASE_TIMEOUTS.verify_inspect +
    PHASE_TIMEOUTS.goldmask_verification +
    PHASE_TIMEOUTS.code_review + PHASE_TIMEOUTS.code_review_qa +
    PHASE_TIMEOUTS.goldmask_correlation +
    PHASE_TIMEOUTS.mend + PHASE_TIMEOUTS.mend_qa +
    PHASE_TIMEOUTS.verify_mend +
    PHASE_TIMEOUTS.design_iteration +
    PHASE_TIMEOUTS.test + PHASE_TIMEOUTS.test_qa +
    PHASE_TIMEOUTS.test_coverage_critique +
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
// Called after every Codex phase completion in phases (2.8, 4.5, 5.6, 7.8, 8.55).
// With delegation, the Tarnished calls this using error_class from teammate's SendMessage metadata.
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

// Declarative reaction evaluation — replaces hardcoded thresholds in arc-failure-policy.md.
// Called by phase reference files when a reaction event occurs.
// Returns { action, reason?, wait_ms? } to guide phase behavior.
// Cycle guard: MAX_REACTION_DEPTH prevents cascading reactions (e.g., retry → timeout → retry).
const MAX_REACTION_DEPTH = 3

function evaluateReaction(eventName, context, depth = 0) {
  if (depth >= MAX_REACTION_DEPTH) {
    warn(`evaluateReaction: max depth (${MAX_REACTION_DEPTH}) reached for ${eventName} — halting`)
    return { action: "halt", reason: "max_reaction_depth" }
  }

  const reaction = checkpoint.reactions?.[eventName]
  if (!reaction) return { action: "halt", reason: "unknown_event" }  // Unknown event = safe default

  const attempts = context.attemptCount || 0
  const elapsed = context.firstAttemptMs
    ? Date.now() - context.firstAttemptMs
    : 0  // First attempt: elapsed = 0 (escalation timeout cannot fire)

  // Escalation timeout takes priority (only after first attempt)
  if (reaction.escalate_after_ms && elapsed > reaction.escalate_after_ms) {
    return { action: "escalate", reason: "timeout", elapsed_ms: elapsed }
  }

  // Retry budget
  if (attempts < (reaction.retries || 0)) {
    return { action: "retry", wait_ms: reaction.wait_ms || 0, attempt: attempts + 1 }
  }

  // Budget exhausted — fall back to base action or halt
  const exhaustedAction = reaction.action === "retry" ? "halt" : reaction.action
  return { action: exhaustedAction, reason: "budget_exhausted", attempts }
}

// Helper: increment per-event counter in reaction_state
function incrementReactionCounter(eventName) {
  const state = checkpoint.reaction_state?.per_event_counters ?? {}
  if (!state[eventName]) {
    state[eventName] = { attemptCount: 0, firstAttemptMs: Date.now() }
  }
  state[eventName].attemptCount++
  checkpoint.reaction_state = checkpoint.reaction_state ?? { per_event_counters: {}, _meta: {} }
  checkpoint.reaction_state.per_event_counters = state
  updateCheckpoint({ reaction_state: checkpoint.reaction_state })
}

// Helper: get context for evaluateReaction from reaction_state
function getReactionContext(eventName) {
  const counter = checkpoint.reaction_state?.per_event_counters?.[eventName]
  return {
    attemptCount: counter?.attemptCount ?? 0,
    firstAttemptMs: counter?.firstAttemptMs ?? null
  }
}
```

## Skip Map Schema (v1.162.0+)

Pre-computed phase skip decisions, stored in `checkpoint.skip_map`. Computed at checkpoint init
by `computeSkipMap()` (see [arc-checkpoint-init.md](arc-checkpoint-init.md)). Consumed by
the stop hook's single-pass auto-skip logic (see `arc-phase-stop-hook.sh`).

```javascript
// Skip map structure: { phase_name: skip_reason_string | undefined }
// Only phases with deterministic skip conditions appear in the map.
// Phases NOT in the map are dispatched to the LLM normally.
// Empty map ({}) = no pre-skipping (all features enabled).

// ── Canonical skip reasons ──
const SKIP_REASONS = {
  FORGE_DISABLED: "forge_disabled",                   // --no-forge flag or arc.defaults.no_forge
  DESIGN_SYNC_DISABLED: "design_sync_disabled",       // misc.design_sync.enabled !== true
  NO_FIGMA_URLS: "no_figma_urls",                     // design_sync enabled but no figma_urls in plan
  STORYBOOK_DISABLED: "storybook_disabled",           // misc.storybook.enabled !== true
  UX_DISABLED: "ux_disabled",                         // ux.enabled !== true
  CODEX_UNAVAILABLE: "codex_unavailable",             // codex CLI not installed
  CODEX_DISABLED_FOR_ARC: "codex_disabled_for_arc",   // codex.disabled or "arc" not in codex.workflows
  CODEX_TASK_DECOMPOSITION_DISABLED: "codex_task_decomposition_disabled",
  CODEX_SEMANTIC_VERIFICATION_DISABLED: "codex_semantic_verification_disabled",
  CODEX_GAP_ANALYSIS_DISABLED: "codex_gap_analysis_disabled",
  CODEX_TEST_COVERAGE_DISABLED: "codex_test_coverage_disabled",
  CODEX_RELEASE_QUALITY_DISABLED: "codex_release_quality_disabled",  // per-phase codex sub-key disabled
  BOT_REVIEW_DISABLED: "bot_review_disabled",         // bot_review not enabled via flag or talisman
  TESTING_DISABLED: "testing_disabled",               // --no-test flag or arc.defaults.no_test
  INSPECT_DISABLED: "inspect_disabled",               // arc.inspect.enabled === false
}

// ── Phase skip classification ──
// Pre-computable: forge, design_extraction, design_prototype, design_verification*,
//   design_iteration*, storybook_verification, ux_verification, task_decomposition,
//   semantic_verification, codex_gap_analysis, test_coverage_critique,
//   release_quality_check, bot_review_wait, pr_comment_resolution, test*
//   (* = conditionally pre-computable — only when parent feature is disabled)
//
// Runtime-dependent (NOT in skip_map): plan_refine (depends on Phase 2 verdicts),
//   drift_review (depends on worker drift signal files — zero overhead when none exist),
//   deploy_verify (depends on post-work diff analysis)
//
// computeSkipMap() signature:
//   function computeSkipMap(arcConfig, designSync, storybook, ux, codexEnabled, codex, planMeta) → object

// ── phase_skip_log entry schema (appended to checkpoint by stop hook) ──
// { phase: string, event: "auto_skipped", reason: string,
//   source: "preflight_skip_map", timestamp: ISO8601 }
```

See [phase-tool-matrix.md](phase-tool-matrix.md) for per-phase tool restrictions and time budget details.
