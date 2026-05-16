# Arc Phase Constants

<!-- v3.x: defaults baked from former talisman.arc / talisman.testing; see references/v3-defaults.md -->

Canonical phase order, timeouts, convergence budgets, and shared utilities.
Extracted from SKILL.md in v1.110.0 for phase-isolated context architecture.

**Consumers**: SKILL.md (checkpoint init), arc-phase-stop-hook.sh (phase ordering),
per-phase reference files (timeout values), arc-resume.md (schema migration)

## Phase Order

```javascript
// SYNC-CRITICAL: PHASE_ORDER is duplicated in:
//   1. This file (JavaScript reference for timeout/budget calculations)
//   2. arc-phase-stop-hook.sh (Bash array for phase dispatch)
// These MUST stay in sync. Divergence causes silent phase ordering bugs.
// TODO: Add preflight assertion comparing both arrays.
// v3.0.0-alpha.2: Removed 4 phases from default order — goldmask_verification,
// goldmask_correlation, bot_review_wait, pr_comment_resolution. Goldmask remains
// a standalone command (`/rune:goldmask`); PR-comment + bot-review handling moves
// to external pr-guardian harness territory.
// v3.0.0-alpha.2 (codex-strip sync, self-audit 1778278942): bash side now matches —
// semantic_verification, task_decomposition, test_coverage_critique,
// release_quality_check were already absent from this JS array but lingered in
// PHASE_GROUPS and calculateDynamicTimeout(); now also removed from those.
// v3.0.0-alpha.6 (Day 5 arc-surface trim): Day 5 absorbs orchestrator-only and
// thin-shell phases into their natural parents. See
// plans/2026-05-15-chore-rune-v3-day5-arc-surface-trim-plan.md.
//   - plan_refine → plan_review (this commit, C4a)
//   - drift_review → work (C4b — as a post-step before work_qa runs)
//   - inspect_fix + verify_inspect → inspect (C4c)
//   - verify_mend → mend_qa (C4d)
//   - deploy_verify + pre_ship_validation → ship (C4e)
const PHASE_ORDER = ['forge', 'forge_qa', 'plan_review', 'verification', 'work', 'work_qa', 'gap_analysis', 'gap_analysis_qa', 'gap_remediation', 'inspect', 'inspect_fix', 'verify_inspect', 'code_review', 'code_review_qa', 'verify', 'mend', 'mend_qa', 'verify_mend', 'test', 'test_qa', 'deploy_verify', 'pre_ship_validation', 'ship', 'merge']

// SYNC-CRITICAL: PHASE_GROUPS is duplicated in:
//   1. This file (JavaScript reference for group definitions)
//   2. arc-phase-stop-hook.sh (Bash lookup for boundary detection)
// These MUST stay in sync. When adding a new phase to PHASE_ORDER,
// also add it to the appropriate group in PHASE_GROUPS.
const PHASE_GROUPS = [
  { id: 'planning',     phases: ['forge', 'forge_qa', 'plan_review', 'verification'] },
  { id: 'work',         phases: ['work', 'work_qa'] },
  { id: 'verification', phases: ['gap_analysis', 'gap_analysis_qa', 'gap_remediation'] },
  { id: 'inspect',      phases: ['inspect', 'inspect_fix', 'verify_inspect'] },
  { id: 'review',       phases: ['code_review', 'code_review_qa', 'verify', 'mend', 'mend_qa', 'verify_mend'] },
  { id: 'testing',      phases: ['test', 'test_qa'] },
  { id: 'ship',         phases: ['deploy_verify', 'pre_ship_validation', 'ship', 'merge'] },
]

// Preflight assertion: validates all PHASE_ORDER entries appear in exactly one group
function assertPhaseGroupsCoverage() {
  const allGroupPhases = PHASE_GROUPS.flatMap(g => g.phases)
  const orphaned = PHASE_ORDER.filter(p => !allGroupPhases.includes(p))
  const duplicated = allGroupPhases.filter((p, i) => allGroupPhases.indexOf(p) !== i)
  const unknown = allGroupPhases.filter(p => !PHASE_ORDER.includes(p))
  if (orphaned.length > 0) throw new Error(`PHASE_GROUPS: orphaned phases not in any group: ${orphaned.join(', ')}`)
  if (duplicated.length > 0) throw new Error(`PHASE_GROUPS: phases in multiple groups: ${duplicated.join(', ')}`)
  if (unknown.length > 0) throw new Error(`PHASE_GROUPS: unknown phases not in PHASE_ORDER: ${unknown.join(', ')}`)
}

// Heavy phases that MUST be delegated to sub-skills — never implemented inline.
// These phases consume significant tokens and require fresh teammate context windows.
// Context Advisory: Emitted by the dispatcher before each heavy phase is invoked.
// NOTE: This list covers phases that delegate to /rune:strive, /rune:appraise, /rune:mend.
// Phases like goldmask_verification and gap_remediation also spawn teams but are managed
// by their own reference files, not sub-skill commands — they are NOT included here.
// SYNC-NOTE: arc-phase-stop-hook.sh has a separate HEAVY_PHASES for compact interlude triggers
// (includes QA and test phases). The two lists serve different purposes — do not unify.
const HEAVY_PHASES = ['work', 'code_review', 'verify', 'mend', 'inspect']

// IMPORTANT: checkArcTimeout() runs BETWEEN phases, not during. A phase that exceeds
// its budget will only be detected after it finishes/times out internally.
// NOTE: SETUP_BUDGET (5 min, all delegated phases) and MEND_EXTRA_BUDGET (3 min, mend-only)
// are defined in arc-phase-mend.md.
```

**WARNING — Non-monotonic execution order**: Phase 5.8 (GAP REMEDIATION) executes **before** Phase 5.7 (GOLDMASK VERIFICATION). The `PHASE_ORDER` array defines the canonical execution sequence using phase **names**, not numbers. Any tooling that sorts by numeric phase ID will get the wrong order. The non-sequential numbering preserves backward compatibility with older checkpoints — do NOT renumber. Always use `PHASE_ORDER` for iteration order.

**DECREE-001 Guard — Phase dispatch assertion**: All phase dispatch code MUST use `PHASE_ORDER` for iteration. The following assertion validates correct ordering:

```javascript
// REFERENCE ONLY — not executed at runtime. See BIZL-002.
// Implement in arc-phase-stop-hook.sh during phase dispatch for runtime validation.
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
// v3.x: phase timeouts are hardcoded — no talisman overrides.
const PHASE_TIMEOUTS = {
  forge:         900_000,    // 15 min (inner 10m + 5m setup)
  plan_review:   900_000,    // 15 min (inner 10m + 5m setup)
  // plan_refine: absorbed into plan_review in v3.0.0-alpha.6 (Day 5 C4a)
  verification:  30_000,     // 30 sec (orchestrator-only, no team)
  work:          2_100_000,  // 35 min (inner 30m + 5m setup)
  // drift_review: absorbed into work in v3.0.0-alpha.6 (Day 5 C4b)
  gap_analysis:  720_000,    // 12 min (inner 8m + 2m setup + 2m aggregate)
  gap_remediation: 900_000,  // 15 min (inner 10m + 5m setup)
  inspect:       900_000,    // 15 min (4 Inspector Ashes + verdict-binder)
  inspect_fix:   900_000,    // 15 min (gap-fixer agents for FIXABLE findings)
  verify_inspect: 240_000,   //  4 min (convergence evaluation, no team)
  code_review:   900_000,    // 15 min (inner 10m + 5m setup)
  mend:          1_380_000,  // 23 min (inner 15m + 5m setup + 3m ward/cross-file)
  verify_mend:   240_000,    //  4 min (orchestrator-only, no team)
  test:          1_500_000,  // 25 min without E2E. Dynamic: 50 min with E2E (3_000_000)
  deploy_verify: 300_000,    //  5 min (conditional — gated by migration/API/config file changes)
  pre_ship_validation: 360_000,  //  6 min (orchestrator-only)
  // v3.0.0-alpha.2: bot_review_wait, pr_comment_resolution, goldmask_verification,
  // goldmask_correlation removed — see PHASE_ORDER comment.
  verify:        600_000,    // 10 min (finding verification — spawns verifier agents)
  ship:          300_000,    //  5 min (orchestrator-only)
  merge:         600_000,    // 10 min (orchestrator-only)
  forge_qa:        300_000,  //  5 min (QA gate — 1 agent)
  work_qa:         300_000,  //  5 min (QA gate — 1 agent)
  gap_analysis_qa: 300_000,  //  5 min (QA gate — 1 agent)
  code_review_qa:  300_000,  //  5 min (QA gate — 1 agent)
  mend_qa:         300_000,  //  5 min (QA gate — 1 agent)
  test_qa:         300_000,  //  5 min (QA gate — 1 agent)
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

// Browser test convergence cycle budgets (v1.170.0+)
const BROWSER_TEST_CYCLE_BUDGET = {
  test: 900_000,       // 15 min per browser test run
  fix: 900_000,        // 15 min per fix round
  verify: 240_000,     //  4 min per convergence check
}
const MAX_BROWSER_TEST_CYCLES = 3  // Hard cap on test→fix→verify iterations

// Batch testing configuration (v1.165.0+; v3.x: hardcoded — testing.batch.* removed from talisman)
const BATCH_CONFIG = {
  target_batch_duration_ms: 180_000,
  min_batch_size: 1,
  max_batch_size: 20,
  hard_batch_timeout_ms: 240_000,
  max_fix_retries: 2,
  inter_batch_delay_ms: 5_000,
  max_batch_iterations: 50,
  avg_duration: {
    unit: 10_000,
    integration: 30_000,
    e2e: 60_000,
    contract: 15_000,
    extended: 120_000
  }
}

function calculateDynamicTimeout(tier) {
  const basePhaseBudget = PHASE_TIMEOUTS.forge + PHASE_TIMEOUTS.forge_qa +
    PHASE_TIMEOUTS.plan_review +
    PHASE_TIMEOUTS.verification +  // v3.0.0-alpha.6: plan_refine absorbed into plan_review (Day 5 C4a)
    PHASE_TIMEOUTS.work + PHASE_TIMEOUTS.work_qa +
    // v3.0.0-alpha.6: drift_review absorbed into work (Day 5 C4b)
    PHASE_TIMEOUTS.gap_analysis + PHASE_TIMEOUTS.gap_analysis_qa +
    PHASE_TIMEOUTS.gap_remediation +
    PHASE_TIMEOUTS.inspect + PHASE_TIMEOUTS.inspect_fix + PHASE_TIMEOUTS.verify_inspect +
    PHASE_TIMEOUTS.code_review + PHASE_TIMEOUTS.code_review_qa +
    PHASE_TIMEOUTS.verify +
    PHASE_TIMEOUTS.mend + PHASE_TIMEOUTS.mend_qa +
    PHASE_TIMEOUTS.verify_mend +
    PHASE_TIMEOUTS.test + PHASE_TIMEOUTS.test_qa +
    PHASE_TIMEOUTS.deploy_verify +  // DECR-001 fix: was missing from budget
    PHASE_TIMEOUTS.pre_ship_validation +
    PHASE_TIMEOUTS.ship + PHASE_TIMEOUTS.merge
    // v3.0.0-alpha.2: removed goldmask_verification, goldmask_correlation,
    // bot_review_wait, pr_comment_resolution from default budget.
    // v3.0.0-alpha.2 (codex-strip sync, self-audit 1778278942):
    // also removed semantic_verification, task_decomposition,
    // test_coverage_critique, release_quality_check terms — these phases
    // were dropped from PHASE_ORDER but had been left in the budget sum,
    // yielding NaN whenever they were referenced.
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

  // SEC-001 FIX: Prototype pollution guard — reject __proto__, constructor, prototype
  if (FORBIDDEN_PHASE_KEYS.has(eventName)) {
    warn(`evaluateReaction: blocked prototype pollution attempt: ${eventName}`)
    return { action: "halt", reason: "forbidden_key" }
  }

  // BACK-001 FIX: Null guard — reactions shard may resolve to null when talisman is malformed
  const reactions = checkpoint.reactions ?? {}
  const reaction = reactions[eventName]
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
  // SEC-001 FIX: Prototype pollution guard
  if (FORBIDDEN_PHASE_KEYS.has(eventName)) return
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
// v3.0.0-alpha.1+ removed: DESIGN_SYNC_DISABLED, NO_FIGMA_URLS, STORYBOOK_DISABLED,
// UX_DISABLED, BROWSER_TEST_DISABLED — those phases are no longer in PHASE_ORDER.
const SKIP_REASONS = {
  FORGE_DISABLED: "forge_disabled",                   // --no-forge flag or arc.defaults.no_forge
  TESTING_DISABLED: "testing_disabled",               // --no-test flag or arc.defaults.no_test
  INSPECT_DISABLED: "inspect_disabled",               // arc.inspect.enabled === false
  VERIFY_DISABLED: "verify_disabled",                 // arc.verify.enabled === false or --no-verify flag
  USER_SKIP: "user_skip",                             // arc.skip_phases[] or --depth preset
}

// ── Phase skip classification ──
// Pre-computable: forge, storybook_verification, ux_verification, test*,
//   browser_test*, browser_test_fix*, verify_browser_test*
//   (* = conditionally pre-computable — only when parent feature is disabled)
//
// Runtime-dependent (NOT in skip_map):
//   deploy_verify (depends on post-work diff analysis)
// v3.0.0-alpha.6 (Day 5): plan_refine and drift_review removed (absorbed into
// plan_review and work respectively; no longer phases).
//
// v3.0.0-alpha.1 removed the design family (design_extraction, design_prototype,
// design_verification*, design_iteration*) so they are no longer pre-computable.
//
// computeSkipMap() signature:
//   function computeSkipMap(arcConfig, designSync, storybook, ux, planMeta) → object

// ── phase_skip_log entry schema (appended to checkpoint by stop hook) ──
// { phase: string, event: "auto_skipped", reason: string,
//   source: "preflight_skip_map", timestamp: ISO8601 }

// ── Depth presets (v2.31.0+) ──
// Predefined skip_phases sets for --depth flag. Each preset maps to an array
// of phases to skip via user_skip reason. Resolved at checkpoint init time.
// Usage: /rune:arc --depth quick  →  arc.skip_phases = DEPTH_PRESETS.quick
const DEPTH_PRESETS = {
  // quick: Skip heavy quality gates — fastest path to PR
  // v3.0.0-alpha.2: removed goldmask_verification, goldmask_correlation,
  // bot_review_wait, pr_comment_resolution — they are no longer in PHASE_ORDER.
  // v3.0.0-alpha.2 (codex-strip sync): removed semantic_verification,
  // test_coverage_critique, release_quality_check — also no longer in PHASE_ORDER.
  // v3.0.0-alpha.1 removed the design family (design_extraction,
  // design_prototype, design_verification*, design_iteration*) — also removed
  // from these presets to keep the list a strict subset of live phases.
  quick: [
    "forge", "forge_qa",
    "ux_verification", "storybook_verification",
    "inspect", "inspect_fix",
    "verify_inspect", "browser_test", "browser_test_fix",
    "verify_browser_test"
  ],
  // standard: Default — skip optional/conditional phases only
  standard: [
    "ux_verification", "storybook_verification",
    "browser_test", "browser_test_fix",
    "verify_browser_test"
  ],
  // thorough: Skip nothing — all phases run (empty list)
  thorough: []
}
```

See [phase-tool-matrix.md](phase-tool-matrix.md) for per-phase tool restrictions and time budget details.

## updateCheckpoint() — Dispatcher Utility (v2.30.0+)

`updateCheckpoint(fields)` is a dispatcher-provided pseudo-function called by all phase reference files.
It merges `fields` into the in-memory checkpoint object and writes the result to disk.

### Merge Semantics (CRITICAL)

`updateCheckpoint` MUST **replace** existing keys, never append duplicate keys to the JSON.
When serializing checkpoint to JSON via `Write()`, ensure the in-memory object has each key
only once. The jq `*` operator (recursive merge) is the correct semantic — it replaces
existing keys with new values.

**Common bug**: LLM writes `phase_sequence` at init (value 0) and again during phase updates
(value N), producing duplicate JSON keys. Most parsers silently use the last value, but this
is a data integrity issue. The stop hook's `validate_checkpoint_json_integrity()` (CKPT-INT-007)
auto-detects and fixes duplicates by re-serializing through jq.

### Implementation

```javascript
// updateCheckpoint() — merge fields into checkpoint, then write atomically.
// This is pseudocode that the LLM executes via Read/Write tools.
//
// RULE: When updating phase_sequence or current_phase, you are REPLACING
// the existing top-level value — not adding a second copy. The in-memory
// checkpoint object is a single JS object where assignment overwrites.
function updateCheckpoint(fields) {
  // Phase-level fields go into checkpoint.phases[phase]
  if (fields.phase && checkpoint.phases[fields.phase]) {
    const phaseFields = ['status', 'artifact', 'artifact_hash', 'team_name',
      'started_at', 'completed_at', 'skip_reason', 'retry_count', 'score',
      'verdicts', 'refinements', 'fixed_count', 'deferred_count']
    for (const key of phaseFields) {
      if (key in fields) {
        checkpoint.phases[fields.phase][key] = fields[key]
      }
    }
  }
  // Top-level fields go into checkpoint root (REPLACES existing keys)
  for (const [key, value] of Object.entries(fields)) {
    if (key !== 'phase') {  // 'phase' is the routing key, not stored at root
      checkpoint[key] = value  // assignment = replacement, no duplicates
    }
  }
  // Atomic write
  Write(checkpointPath, JSON.stringify(checkpoint, null, 2))
}
```

### Operational Reliability Fields (Schema v28)

Top-level checkpoint fields for stop hook persistence and retry cost tracking:

| Field | Type | Default | Updated by |
|-------|------|---------|------------|
| `work_completion_verified` | boolean | `false` | Stop hook — set `true` after confirming work phase output exists |
| `stop_hook_retries` | integer | `0` | Stop hook — incremented on each re-injection due to transient failure |
| `cumulative_retry_cost_cents` | integer | `0` | Stop hook — running total of API cost (cents) consumed by retries |

Usage in stop hook:
```javascript
updateCheckpoint({
  stop_hook_retries: checkpoint.stop_hook_retries + 1,
  cumulative_retry_cost_cents: checkpoint.cumulative_retry_cost_cents + estimatedCostCents,
  work_completion_verified: true  // after confirming work output
})
```

### Script-Based Alternative

For deterministic writes without LLM serialization risk, use the
`checkpoint-update.sh` utility:

```bash
# Top-level merge
"${RUNE_PLUGIN_ROOT}/scripts/lib/checkpoint-update.sh" "$checkpointPath" \
  '{"phase_sequence":1,"current_phase":"forge"}'

# Phase-aware merge (routes fields to .phases[phase] automatically)
"${RUNE_PLUGIN_ROOT}/scripts/lib/checkpoint-update.sh" "$checkpointPath" \
  '{"phase":"forge","status":"completed","artifact":"tmp/arc/id/enriched-plan.md","phase_sequence":1}' \
  --phase-update
```

### Validation

```bash
# Check for duplicate keys, missing fields, schema issues
"${RUNE_PLUGIN_ROOT}/scripts/lib/checkpoint-validate.sh" "$checkpointPath"

# Auto-fix duplicates
"${RUNE_PLUGIN_ROOT}/scripts/lib/checkpoint-validate.sh" "$checkpointPath" --fix
```
