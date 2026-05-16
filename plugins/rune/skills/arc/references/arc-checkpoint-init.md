# Initialize Checkpoint (ARC-2) — Full Algorithm

<!-- v3.x: defaults baked from former talisman.{arc,work,misc,ux,gates,process_management}; see references/v3-defaults.md -->

Checkpoint initialization: config resolution (3-layer), session identity,
checkpoint schema v30 creation, skip map computation, and initial state write.

**Inputs**: plan path, arc arguments, `freshnessResult` from Freshness Check
**Outputs**: checkpoint object (schema v30), resolved arc config (`arcConfig`), pre-computed `skip_map`
**Error handling**: Fail arc if plan file missing or config invalid
**Consumers**: SKILL.md checkpoint-init stub, resume logic in [arc-resume.md](arc-resume.md)

> **Note**: `PHASE_ORDER`, `PHASE_TIMEOUTS`, `calculateDynamicTimeout`, and `FORBIDDEN_PHASE_KEYS`
> are defined inline in SKILL.md (Phase Constants block). They are in the orchestrator's context.

## Initialize Checkpoint

```javascript
const id = `arc-${Date.now()}`
if (!/^arc-[a-zA-Z0-9_-]+$/.test(id)) throw new Error("Invalid arc identifier")
// SEC: Session nonce prevents TOME injection from prior sessions.
// MUST be cryptographically random — NOT derived from timestamp or arc id.
// LLM shortcutting this to `arc{id}` defeats the security purpose.
// ARC-SEC-004 (audit 20260420-171018): upgraded from 6→16 bytes (48→128 bits)
// to match industry standard for security tokens. Validators across arc-resume
// and verify-mend accept both legacy 12-hex and current 32-hex to preserve
// backward compatibility with checkpoints written before the upgrade.
const rawNonce = crypto.randomBytes(16).toString('hex').toLowerCase()
// Validate format AFTER generation, BEFORE checkpoint write: exactly 32 lowercase hex characters
// .toLowerCase() ensures consistency across JS runtimes (defense-in-depth)
if (!/^[0-9a-f]{32}$/.test(rawNonce)) {
  throw new Error(`Session nonce generation failed. Must be 32 hex chars from crypto.randomBytes(16). Retry arc invocation.`)
}
const sessionNonce = rawNonce

// SEC-006 FIX: Compute tier BEFORE checkpoint init (was referenced but never defined)
// SEC-011 FIX: Null guard — parseDiffStats may return null on empty/malformed git output
const diffStats = parseDiffStats(Bash(`git diff --stat ${defaultBranch}...HEAD`)) ?? { insertions: 0, deletions: 0, files: [] }
const planMeta = extractYamlFrontmatter(Read(planFile))
// v3.x: arc + work configs baked from defaults (see references/v3-defaults.md)
const arc = {}
const work = { co_authors: [] }
```

## 2-Layer Config Resolution

```javascript
// 2-layer config resolution: hardcoded defaults → inline CLI flags
// v3.x: Layer 2 (talisman) baked into Layer 1 defaults; see references/v3-defaults.md
// Contract: inline flags ALWAYS override hardcoded defaults.
function resolveArcConfig(arc, work, inlineFlags) {
  // Layer 1: Hardcoded defaults (v3.x — former Layer 2 talisman overrides baked in)
  const defaults = {
    no_forge: false,
    approve: false,
    skip_freshness: false,
    confirm: false,
    no_test: false,
    no_browser_test: false,
    accept_external_changes: true,
    ship: {
      auto_pr: true,
      auto_merge: false,
      merge_strategy: "squash",
      wait_ci: false,
      draft: false,
      labels: [],
      pr_monitoring: false,
      rebase_before_merge: true,
    },
    bot_review: false,
    no_bot_review: false,
    step_groups: false,
  }

  // v3.x: All Layer 2 conditionals collapsed to defaults (see references/v3-defaults.md)
  const config = {
    no_forge:        defaults.no_forge,
    approve:         defaults.approve,
    skip_freshness:  defaults.skip_freshness,
    confirm:         defaults.confirm,
    no_test:         defaults.no_test,
    no_browser_test: defaults.no_browser_test,
    accept_external_changes: defaults.accept_external_changes,
    ship: {
      auto_pr:       defaults.ship.auto_pr,
      auto_merge:    defaults.ship.auto_merge,
      merge_strategy: defaults.ship.merge_strategy,
      wait_ci:       defaults.ship.wait_ci,
      draft:         defaults.ship.draft,
      labels:        defaults.ship.labels,
      pr_monitoring: defaults.ship.pr_monitoring,
      rebase_before_merge: defaults.ship.rebase_before_merge,
      // QUAL-003 FIX: co_authors falls back to work.co_authors when present
      co_authors: Array.isArray(work?.co_authors) ? work.co_authors : [],
    },
    bot_review: defaults.bot_review,
    no_bot_review: defaults.no_bot_review,
    inspect_enabled: true,
    verify_enabled: true,
    pre_merge_checks: {
      migration_conflict: true,
      schema_conflict: true,
      lock_file_conflict: true,
      uncommitted_changes: true,
      migration_paths: [],
    },
    // v2.31.0: User-defined phase skip list (merged into skip_map at init time)
    skip_phases: [],
    step_groups: defaults.step_groups,
  }

  // Layer 2: Inline CLI flags override (only if explicitly passed)
  if (inlineFlags.no_forge !== undefined) config.no_forge = inlineFlags.no_forge
  if (inlineFlags.approve !== undefined) config.approve = inlineFlags.approve
  if (inlineFlags.skip_freshness !== undefined) config.skip_freshness = inlineFlags.skip_freshness
  if (inlineFlags.confirm !== undefined) config.confirm = inlineFlags.confirm
  if (inlineFlags.no_test !== undefined) config.no_test = inlineFlags.no_test
  if (inlineFlags.no_browser_test !== undefined) config.no_browser_test = inlineFlags.no_browser_test
  if (inlineFlags.accept_external_changes !== undefined) config.accept_external_changes = inlineFlags.accept_external_changes
  // Ship flags can also be overridden inline
  if (inlineFlags.no_pr !== undefined) config.ship.auto_pr = !inlineFlags.no_pr
  if (inlineFlags.no_merge !== undefined) config.ship.auto_merge = !inlineFlags.no_merge
  if (inlineFlags.draft !== undefined) config.ship.draft = inlineFlags.draft
  // v3.0.0-alpha.2: --bot-review / --no-bot-review removed; bot review handling
  // moved to external pr-guardian harness. Inline-flag entries dropped.
  // BACK-001 FIX: Wire --no-verify CLI flag to verify_enabled (was missing — skip map dead code)
  if (inlineFlags.no_verify !== undefined) config.verify_enabled = !inlineFlags.no_verify
  if (inlineFlags.step_groups !== undefined) config.step_groups = inlineFlags.step_groups

  return config
}

// Parse inline flags and resolve config
const inlineFlags = {
  no_forge: args.includes('--no-forge') ? true : undefined,
  approve: args.includes('--approve') ? true : undefined,
  skip_freshness: args.includes('--skip-freshness') ? true : undefined,
  confirm: args.includes('--confirm') ? true : undefined,
  no_test: args.includes('--no-test') ? true : undefined,
  no_browser_test: args.includes('--no-browser-test') ? true : undefined,
  // --no-accept-external (force off) > --accept-external (force on) > hardcoded default (true)
  accept_external_changes: args.includes('--no-accept-external') ? false
    : args.includes('--accept-external') ? true : undefined,
  no_pr: args.includes('--no-pr') ? true : undefined,
  no_merge: args.includes('--no-merge') ? true : undefined,
  draft: args.includes('--draft') ? true : undefined,
  // BACK-001 FIX: Wire --no-verify CLI flag into inlineFlags (was missing)
  no_verify: args.includes('--no-verify') ? true : undefined,
  step_groups: args.includes('--step-groups') ? true : undefined,
}
const arcConfig = resolveArcConfig(arc, work, inlineFlags)
// Validate PHASE_GROUPS coverage — catches orphaned phases when new phases are added
assertPhaseGroupsCoverage()
// Use arcConfig.no_forge, arcConfig.approve, arcConfig.ship.auto_pr, etc. throughout
```

## Tier Selection and Timeout Calculation

```javascript
const tier = selectReviewMendTier(diffStats, planMeta, arc)
// SEC-005 FIX: Collect changed files for progressive focus fallback (EC-9 paradox recovery)
const changedFiles = diffStats.files || []
// Calculate dynamic total timeout based on tier
const arcTotalTimeout = calculateDynamicTimeout(tier)
```

## Skip Map Computation (v1.162.0+)

Pre-compute deterministic phase skip decisions from hardcoded defaults, plan frontmatter, and CLI flags.
Phases in the skip map are auto-skipped by the stop hook without LLM dispatch — saving ~30s per skipped phase.

```javascript
// ── v3.x: design_sync / storybook / ux baked off; see references/v3-defaults.md ──
const designSync = {}
const storybook = {}
const ux = {}

/**
 * computeSkipMap — Pre-compute deterministic phase skip decisions.
 *
 * @param {object} arcConfig — Resolved arc config from 2-layer resolution
 * @param {object} designSync — Hardcoded default in v3.x (see references/v3-defaults.md)
 * @param {object} storybook — Hardcoded default in v3.x (see references/v3-defaults.md)
 * @param {object} ux — Hardcoded default in v3.x (see references/v3-defaults.md)
 * @param {object} planMeta — Extracted YAML frontmatter from plan file
 * @returns {object} Map of { phase_name: skip_reason_string } for phases to auto-skip.
 *   Phases NOT in the map are dispatched normally. Empty map = no pre-skipping.
 *
 * Valid skip reasons (canonical enum — keep in sync with arc-phase-constants.md):
 *   forge_disabled, design_sync_disabled, no_figma_urls, storybook_disabled,
 *   ux_disabled, bot_review_disabled, testing_disabled
 */
function computeSkipMap(arcConfig, designSync, storybook, ux, planMeta, planFile) {
  const map = {}

  // ── Forge (unified via skip_map instead of inline status) ──
  if (arcConfig.no_forge) {
    map.forge = "forge_disabled"
  }

  // ── Design phases (4 phases when design_sync disabled, 2 when enabled but no URLs) ──
  const designEnabled = designSync.enabled === true
  const hasFigmaUrls = Array.isArray(planMeta?.figma_urls) && planMeta.figma_urls.length > 0

  // ── Design / Storybook / UX phases removed in v3.0.0-alpha.1 ──
  // No design_extraction, design_prototype, design_verification(_qa),
  // design_iteration, storybook_verification, ux_verification entries —
  // those phases are gone from PHASE_ORDER. Skip-map keys for non-existent
  // phases would be rejected by the defense-in-depth check at the bottom.

  // ── Verify phase (1 phase) ──
  if (arcConfig.verify_enabled === false) {
    map.verify = "verify_disabled"
  }

  // ── Inspect phase (single phase since v3.0.0-alpha.6 Day 5 C4c) ──
  // RUIN-004 FIX: Use resolved arcConfig instead of inline lookups.
  // inspect_fix + verify_inspect were absorbed into the unified inspect phase.
  if (arcConfig.inspect_enabled === false) {
    map.inspect = "inspect_disabled"
  }

  // ── Bot review phases removed in v3.0.0-alpha.2 ──
  // bot_review_wait + pr_comment_resolution moved out of default PHASE_ORDER.
  // Use external pr-guardian harness or /rune:resolve-all-gh-pr-comments.

  // ── Test phase ──
  if (arcConfig.no_test) {
    map.test = "testing_disabled"
  }

  // ── Browser test phases removed in v3.0.0-alpha.1 ──
  // browser_test / browser_test_fix / verify_browser_test no longer in PHASE_ORDER.
  // Use /rune:test-browser standalone or arc Phase 7.7 testing pipeline.

  // ── QA gate phase skip propagation ──
  // QUAL-001 FIX: Order matches PHASE_ORDER canonical sequence
  // v3.x: qa_gates enabled by default — propagate skips from parent phases only
  const QA_GATED_PHASES = ['forge', 'work', 'gap_analysis', 'code_review', 'mend', 'test']
  for (const phase of QA_GATED_PHASES) {
    if (map[phase]) {
      map[`${phase}_qa`] = `parent_${phase}_skipped`
    }
  }

  // ── User-defined skip phases (v2.31.0+) ──
  // Merge arc.skip_phases[] from arcConfig. Applied AFTER all feature-based
  // skip logic so user overrides don't conflict with safety-critical skips.
  // FORBIDDEN_PHASE_KEYS guard prevents prototype pollution.
  const userSkipPhases = arcConfig.skip_phases ?? []
  for (const phase of userSkipPhases) {
    if (FORBIDDEN_PHASE_KEYS.has(phase)) continue
    if (PHASE_ORDER.includes(phase)) {
      // Don't override existing skip reasons — user_skip is lower priority
      if (!map[phase]) {
        map[phase] = "user_skip"
      }
    } else {
      warn(`arc.skip_phases: unknown phase "${phase}" — ignoring`)
    }
  }

  // ── Validate all keys exist in PHASE_ORDER (defense-in-depth) ──
  for (const key of Object.keys(map)) {
    if (!PHASE_ORDER.includes(key)) {
      warn(`computeSkipMap: key "${key}" not in PHASE_ORDER — ignoring`)
      delete map[key]
    }
  }

  return map
}

const skipMap = computeSkipMap(arcConfig, designSync, storybook, ux, planMeta, planFile)
```

## Checkpoint Schema v26

// Schema history: see CHANGELOG.md for migration notes from v12-v24.

```javascript
// ── Resolve session identity for cross-session isolation ──
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

// ── Resolve worktree context (v1.174.0) ──
// When arc runs inside a git worktree, record the worktree root and main repo root
// for cross-session resume awareness. --resume from main repo can detect worktree checkpoints.
const gitCommonDir = Bash("git rev-parse --git-common-dir 2>/dev/null").trim()
const gitDir = Bash("git rev-parse --git-dir 2>/dev/null").trim()
const isWorktree = !!(gitCommonDir && gitDir) && gitCommonDir !== gitDir
const worktreeMeta = isWorktree ? {
  is_worktree: true,
  worktree_root: Bash("git rev-parse --show-toplevel 2>/dev/null").trim(),
  main_repo_root: gitCommonDir.replace(/\/\.git$/, ''),
  // Detached HEAD fallback: null signals detached state (not empty string which is ambiguous)
  worktree_branch: Bash("git branch --show-current 2>/dev/null").trim() || null
} : { is_worktree: false }

// ── Resolve parent_plan context (v1.79.0+: hierarchical execution) ──
// When arc is invoked as a child under arc-hierarchy, this context is passed via the
// arc-hierarchy SKILL.md. For standalone arcs, all fields remain null / false.
const parentPlanMeta = {
  path: null,           // Parent plan path (null if not a child arc)
  children_dir: null,   // Children directory from parent frontmatter
  child_seq: null,      // This child's sequence number (1-indexed)
  feature_branch: null, // Parent's feature branch name (child stays on this branch)
  skip_branch: false,   // Skip branch creation (parent manages the feature branch)
  skip_ship_pr: false   // Skip PR creation (parent creates single PR after all children)
}
// If invoked via arc-hierarchy stop hook, the injected prompt sets these fields.
// Detection: check for --hierarchy-child flag or HIERARCHY_CONTEXT env override in args.
// The arc-hierarchy SKILL.md documents the injection protocol.

// ┌─────────────────────────────────────────────────────────────────────────────┐
// │ IRON LAW CKPT-001: Checkpoint path is NON-NEGOTIABLE                       │
// │                                                                             │
// │ Path: `.rune/arc/${id}/checkpoint.json`                                     │
// │                                                                             │
// │ Rules:                                                                      │
// │   1. Extension MUST be .json — content is JSON, extension MUST match        │
// │   2. Path MUST be nested: .rune/arc/{id}/checkpoint.json                    │
// │   3. NEVER use flat files like .rune/arc-checkpoint.local.md                │
// │   4. NEVER use .md extension for JSON content                               │
// │                                                                             │
// │ Violating this breaks:                                                      │
// │   - Stop hook phase loop (arc-phase-stop-hook.sh GUARD 5.6)                │
// │   - Resume search (_find_arc_checkpoint scans arc/*/checkpoint.json)        │
// │   - Arc-batch checkpoint discovery                                          │
// │   - Session-team-hygiene orphan detection                                   │
// └─────────────────────────────────────────────────────────────────────────────┘
const checkpointPath = `.rune/arc/${id}/checkpoint.json`
Bash(`mkdir -p ".rune/arc/${id}"`)
Write(checkpointPath, {
  id, schema_version: 30, plan_file: planFile,
  // SESSION-ID-001: session_id MUST resolve via Bash() reading RUNE_SESSION_ID — never via
  // ${CLAUDE_SESSION_ID} literal. LLMs substitute the latter from system-reminder banners,
  // including wrapper-emitted IDs (tmux, Greater-Will). RUNE_SESSION_ID is the authoritative
  // ID written by the SessionStart hook into CLAUDE_ENV_FILE.
  config_dir: configDir, owner_pid: ownerPid, session_id: Bash(`echo "\${RUNE_SESSION_ID:-unknown}"`).trim(),
  // RUIN-003 FIX: Remove redundant ?? guards — Layer 2 resolveArcConfig() already guarantees all values are defined
  flags: { approve: arcConfig.approve, no_forge: arcConfig.no_forge, skip_freshness: arcConfig.skip_freshness, confirm: arcConfig.confirm, no_test: arcConfig.no_test, no_browser_test: arcConfig.no_browser_test, accept_external_changes: arcConfig.accept_external_changes, bot_review: arcConfig.bot_review, no_bot_review: arcConfig.no_bot_review, step_groups: arcConfig.step_groups },
  arc_config: arcConfig,
  pr_url: null,
  freshness: freshnessResult || null,
  session_nonce: sessionNonce, phase_sequence: 0,
  // Schema v30 addition (v2.64.1): CKPT-INT-008 required fields.
  // Validator at scripts/lib/stop-hook-common.sh:885-886 rejects checkpoints
  // missing either field — GUARD 8.5 halts the arc with a CKPT-INTEG FAIL trace line.
  // current_phase is the canonical "what runs next" pointer, seeded to PHASE_ORDER[0].
  // overall_status is the arc-level lifecycle marker ("in_progress" → "completed" at merge).
  overall_status: "in_progress",
  current_phase: "forge",
  // Schema v14 addition (v1.79.0): parent_plan metadata for hierarchical execution
  parent_plan: parentPlanMeta,
  // Schema v15 addition (v1.80.0): stagnation sentinel state — error patterns, file velocity, budget
  // See references/stagnation-sentinel.md for full algorithm
  stagnation: {
    error_patterns: [],
    file_velocity: [],
    budget: null
  },
  // Schema v23 addition (v1.162.0): pre-computed phase skip map for pipeline optimization.
  // Phases in skip_map are auto-skipped by the stop hook without LLM dispatch.
  // Empty map ({}) means no pre-skipping — all phases dispatched normally.
  // See computeSkipMap() above for computation logic.
  skip_map: skipMap,
  // Schema v23 addition (v1.162.0): phase skip event log (auto_skipped + demoted_to_pending events).
  // QUAL-002 FIX: Explicitly initialized (convention: all array fields initialized at checkpoint creation).
  phase_skip_log: [],
  phases: {
    // v1.162.0: forge always starts as "pending" — skip_map handles the skip decision.
    // This unifies all pre-computed skips through one mechanism (was inline ternary before v23).
    forge:        { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    forge_qa:     { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0, demotion_revert_count: 0 },
    plan_review:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    // v3.0.0-alpha.6 (Day 5 C4a): plan_refine absorbed into plan_review — schema entry removed.
    verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    work:         { status: "pending", artifact: null, artifact_hash: null, team_name: null,
                    // Schema v16 (v1.106.0): suspended tasks from context preservation protocol.
                    // Each entry: { task_id, context_path, reason }
                    // context_path scoped to arc checkpoint id (FAIL-008): context/{id}/{task_id}.md
                    suspended_tasks: [], started_at: null, completed_at: null, demotion_revert_count: 0 },
    work_qa:      { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0, demotion_revert_count: 0 },
    // v3.0.0-alpha.6 (Day 5 C4b): drift_review absorbed into work — schema entry removed.
    gap_analysis: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    gap_analysis_qa: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0, demotion_revert_count: 0 },
    gap_remediation: { status: "pending", artifact: null, artifact_hash: null, team_name: null, fixed_count: null, deferred_count: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    inspect: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, completion_pct: null, p1_count: null, verdict: null, inspect_fixed_count: null, inspect_deferred_count: null, inspect_reclassified_count: null, demotion_revert_count: 0, substate: null },
    // inspect.substate tracks mid-phase resume position (v3.0.0-alpha.6 — #14):
    //   "audit"       → STEP 1-4 (inspector ashes running)
    //   "fix"         → STEP 5 (gap-fixer team running)
    //   "convergence" → STEP 6 (convergence evaluation)
    //   null          → not in progress / completed
    // SCHEMA NOTE: substate is a nested field within phases.inspect — it does NOT add a new
    // top-level key to phases[]. The 21-key invariant (19 PHASE_ORDER + verify_mend +
    // pre_ship_validation) is unchanged. Test 4 in test-phase-groups.sh remains correct.
    // v3.0.0-alpha.6 (Day 5 C4c): inspect_fix + verify_inspect absorbed into inspect —
    // schema entries removed; intra-phase state (fixed/deferred/reclassified counts) lives on inspect itself.
    // v3.0.0-alpha.2: goldmask_verification + goldmask_correlation removed from default order.
    code_review:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    code_review_qa: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0, demotion_revert_count: 0 },
    verify:       { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    mend:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    mend_qa:      { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0, demotion_revert_count: 0 },
    // v3.0.0-alpha.6 (Day 5 C4d): verify_mend absorbed into mend_qa post-step.
    // The runMendQAConvergence() algorithm (verify-mend.md) still writes to
    // checkpoint.phases.verify_mend for backward-compatible state tracking;
    // the entry is retained here intentionally and is the only schema key NOT
    // in PHASE_ORDER. Future cleanup may migrate the state into mend_qa.
    verify_mend:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    test:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, tiers_run: [], pass_rate: null, coverage_pct: null, has_frontend: false, started_at: null, completed_at: null, demotion_revert_count: 0 },
    test_qa:      { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0, demotion_revert_count: 0 },
    // v3.0.0-alpha.6 (Day 5 C4e): deploy_verify removed; pre_ship_validation
    // absorbed into ship as STEP -0.5. The preShipValidator() algorithm in
    // arc-phase-pre-ship-validation.md still writes to checkpoint.phases.pre_ship_validation
    // for backward-compatible state tracking; the entry is retained here intentionally
    // alongside verify_mend (also a post-step transitional state container).
    // Future cleanup may migrate the state into ship.
    pre_ship_validation: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    ship:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    merge:        { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, demotion_revert_count: 0 },
    // Defense-in-depth: every key here MUST be in PHASE_ORDER (19 entries as of v3.0.0-alpha.6),
    // except the verify_mend (C4d) and pre_ship_validation (C4e) transitional state
    // containers — both retained because their absorbed algorithms (mend_qa post-step
    // and ship STEP -0.5) still write to those keys for backward-compatible state tracking.
    // Phantom keys (semantic_verification, design_*, storybook_verification, ux_verification,
    // task_decomposition, browser_test*, test_coverage_critique, release_quality_check,
    // bot_review_wait, pr_comment_resolution) were removed in alpha.1/alpha.2 — do not re-add.
  },
  // Schema v19 addition (v1.111.0): timing totals — per-phase durations and overall arc metrics
  // phase_times is populated from two sources:
  //   1. JS-level: each phase prompt calculates completionTs - startMs and writes to checkpoint
  //   2. Shell-level: arc-phase-stop-hook.sh writes phase_timing events to phase-log.jsonl
  //      via _log_phase (wall-clock elapsed from .epoch files). JSONL events serve as a
  //      reliable backup when the JS-level timing is missed by the LLM.
  // Post-arc summary can derive totals from phase-log.jsonl: grep "phase_timing" .rune/arc/{id}/phase-log.jsonl
  totals: { phase_times: {}, total_duration_ms: null, cost_at_completion: null },
  // Schema v19 addition (v1.111.0): arc-level completion timestamp (set at Post-Arc stamp)
  completed_at: null,
  convergence: { round: 0, max_rounds: tier.maxCycles, tier: tier, history: [], original_changed_files: changedFiles },
  // Schema v25 addition: inspect convergence — separate from review-mend convergence.
  // Controls the inspect retry loop (v3.0.0-alpha.6: inspect_fix + verify_inspect
  // absorbed into a single inspect phase that may reset itself to pending for retry).
  inspect_convergence: { round: 0, max_rounds: 2, threshold: 95, history: [] },
  // Browser test convergence — controls the browser_test → browser_test_fix → verify_browser_test loop (Phases 7.7.5-7.7.7).
  browser_test_convergence: {
    round: 0,
    max_cycles: MAX_BROWSER_TEST_CYCLES,  // 3
    history: [],   // { round, routes_tested, routes_passed, routes_failed, fixes_applied, verdict, timestamp }
  },
  // Schema v27 addition: QA gate configuration — controls per-phase QA verification.
  // Each QA phase runs after its parent and produces a verdict.json with numerical scores.
  // v27: Separated infra vs quality global retry budgets. Infrastructure retries (agent
  // timeout/crash) no longer consume the quality retry budget (global_retry_count).
  qa: {
    global_retry_count: 0,                // quality retries only (not incremented on infra failures)
    infra_global_retry_count: 0,          // infra retries only (timeout/crash — separate budget)
    max_global_retries: 6,
    max_infra_global_retries: 12,         // 6 phases × 2 retries
    pass_threshold: 70,
    max_phase_retries: 2,
    enabled: true
  },
  // Schema v26 addition (v2.5.1): Declarative reaction engine config.
  // v3.x: defaults baked from former talisman.reactions; see references/v3-defaults.md
  reactions: {
    qa_gate_failed: { action: "retry", retries: 2, pass_threshold: 70, max_global_retries: 6 },
    teammate_stuck: { action: "escalate", threshold_ms: 180000, force_stop_after_ms: 300000 }
  },
  // Schema v26 addition: Per-event reaction state tracking for retry budgets and escalation.
  // Tracks attempt counts and first-attempt timestamps per reaction event.
  // On --resume: firstAttemptMs is reset to current time (EC-7 fix), attemptCount preserved.
  reaction_state: {
    per_event_counters: {},
    _meta: { last_resume_at: null }
  },
  // Schema v26 addition: CI status tracking for CI fix loop.
  // v3.0.0-alpha.2: bot_review_wait phase removed; the field is preserved for the
  // external pr-guardian harness to populate.
  // null until CI checks are evaluated. When populated:
  // { passed: bool, attempts: int, failed_checks: string[], head_sha: string,
  //   fix_history: [{attempt: int, fixed: string[], remaining: string[]}] }
  ci_status: null,
  // NEW (v1.66.0): Shard metadata from pre-flight shard detection (null for non-shard arcs)
  shard: shardInfo ? {
    num: shardInfo.shardNum,           // e.g., 2
    total: shardInfo.totalShards,      // e.g., 4
    name: shardInfo.shardName,         // e.g., "methodology"
    feature: shardInfo.featureName,    // e.g., "superpowers-gap-implementation"
    parent: shardInfo.parentPath,      // e.g., "plans/...-implementation-plan.md"
    dependencies: shardInfo.dependencies  // e.g., [1]
  } : null,
  // Schema v24 addition (v1.174.0): worktree context metadata
  // Records whether arc is running inside a git worktree and provides the main repo root
  // for cross-session resume awareness. --resume from main repo can scan worktree checkpoints.
  worktree: worktreeMeta,
  // Schema v22 addition (v1.144.0): cancellation tracking
  user_cancelled: false,
  cancel_reason: null,
  cancelled_at: null,
  stop_reason: null,
  // Schema v22 addition (v1.144.0): resume analytics for crash recovery
  resume_tracking: {
    total_resume_count: 0,
    resume_history: [],
    last_resume_at: null,
    consecutive_failures: 0
  },
  // Schema v28 addition: Operational reliability — stop hook persistence and retry tracking.
  // work_completion_verified: set to true by stop hook after confirming work phase output exists.
  // stop_hook_retries: number of times the stop hook has re-injected due to transient failures.
  // cumulative_retry_cost_cents: running total of API cost (in cents) consumed by stop hook retries.
  work_completion_verified: false,
  stop_hook_retries: 0,
  cumulative_retry_cost_cents: 0,
  commits: [],
  started_at: new Date().toISOString(),
  updated_at: new Date().toISOString()
})

// Schema migration is handled in arc-resume.md (steps 3a through 3z).
// Migrations v1→v26 are defined there. See arc-resume.md for the full chain.

// ── PRE-WRITE VALIDATION (INTEG-INIT, v2.29.8): Validate variables BEFORE writing state file ──
// BUG FIX: LLM variable substitution drift can write wrong values (e.g., config_dir=tmp/arc/...).
// These assertions catch the drift AT WRITE TIME, not after the stop hook reads corrupt data.
//
// INTEG-INIT-001: configDir must be CLAUDE_CONFIG_DIR (absolute path), NOT tmp/arc/ working dir
if (!configDir || configDir.startsWith('tmp/') || configDir.startsWith('./tmp/') || configDir.includes('/tmp/arc/')) {
  throw new Error(`FATAL (INTEG-INIT-001): configDir "${configDir}" looks like an arc working directory, not CLAUDE_CONFIG_DIR. ` +
    `configDir must be the resolved CLAUDE_CONFIG_DIR path (e.g., /Users/x/.claude). ` +
    `Did you confuse the arc tmp dir with configDir? Re-read the configDir resolution above.`)
}
// INTEG-INIT-002: ownerPid must be non-empty and numeric
if (!ownerPid || !/^\d+$/.test(String(ownerPid))) {
  throw new Error(`FATAL (INTEG-INIT-002): ownerPid "${ownerPid}" is empty or non-numeric. ` +
    `ownerPid must come from Bash('echo $PPID'). Session isolation cannot work without it.`)
}
// INTEG-INIT-003: id must match arc-{timestamp} format
if (!id || !/^arc-\d+$/.test(id)) {
  throw new Error(`FATAL (INTEG-INIT-003): id "${id}" does not match arc-{timestamp} format.`)
}
// INTEG-INIT-004: checkpointPath must use the SAME id
if (checkpointPath !== `.rune/arc/${id}/checkpoint.json`) {
  throw new Error(`FATAL (INTEG-INIT-004): checkpointPath "${checkpointPath}" does not match expected ".rune/arc/${id}/checkpoint.json". Cross-ID mismatch.`)
}
// INTEG-INIT-005: planFile must not be empty
if (!planFile || planFile === 'null' || planFile === 'unknown') {
  throw new Error(`FATAL (INTEG-INIT-005): planFile "${planFile}" is empty/null/unknown.`)
}

// ── MANDATORY: Write phase loop state file immediately after checkpoint ──
// FIX (v2.6.0): Co-locate state file write with checkpoint init to prevent
// the "missing state file" bug where the LLM writes the checkpoint but skips
// the phase loop state file under context pressure or step-shortcutting.
// Previously this was a separate section in SKILL.md that could be skipped.
// See arc-phase-loop-state.md for the state file schema.
// SESSION-ID-001 (v2.67.0+): Resolve session_id ONLY via Bash() reading RUNE_SESSION_ID.
// The "${CLAUDE_SESSION_ID}" literal pattern was removed because LLMs misinterpret it as a
// string substitution placeholder and inline whatever "session" label appears in the most
// recent system-reminder banner — including wrapper-emitted IDs (tmux, Greater-Will, sandbox
// harnesses). RUNE_SESSION_ID is the only authoritative ID for the live Claude Code session.
const sessionId = Bash('echo "${RUNE_SESSION_ID:-}"').trim() || 'unknown'
// INTEG-INIT-006: sessionId must not be 'unknown' (RUNE_SESSION_ID env var unavailable)
if (sessionId === 'unknown') {
  throw new Error(`FATAL (INTEG-INIT-006): sessionId is 'unknown' — RUNE_SESSION_ID env var not available. The SessionStart hook must run before /rune:arc.`)
}
const branch = Bash("git branch --show-current 2>/dev/null").trim() || 'main'
const stateContent = `---
active: true
iteration: 0
max_iterations: 66
checkpoint_path: .rune/arc/${id}/checkpoint.json
plan_file: ${planFile}
branch: ${branch}
arc_flags: ${args.replace(/\s+/g, ' ').trim()}
config_dir: ${configDir}
owner_pid: ${ownerPid}
session_id: ${sessionId}
compact_pending: false
user_cancelled: false
cancel_reason: null
cancelled_at: null
stop_reason: null
group_mode: ${arcConfig.step_groups ? 'active' : 'null'}
group_paused: null
---
`
Write('.rune/arc-phase-loop.local.md', stateContent)
// Verify state file was written (defense-in-depth)
const stateFileVerify = Bash('test -f ".rune/arc-phase-loop.local.md" && echo "ok" || echo "missing"').trim()
if (stateFileVerify !== 'ok') {
  throw new Error('FATAL: Phase loop state file write failed — Stop hook cannot drive arc phases. Aborting.')
}

// CKPT-001 VERIFICATION: Confirm checkpoint was written to the EXACT canonical path.
// This catches LLM drift where checkpoint gets written to a different path (e.g., .rune/arc-checkpoint.local.md).
const ckptVerify = Bash(`test -f "${checkpointPath}" && echo "ok" || echo "missing"`).trim()
if (ckptVerify !== 'ok') {
  throw new Error(`FATAL (CKPT-001): Checkpoint not found at canonical path "${checkpointPath}". ` +
    `Did you write it to a different location? The ONLY valid path is .rune/arc/{id}/checkpoint.json. Aborting.`)
}
// Also verify the state file's checkpoint_path matches the actual path
const stateCheckpointPath = Bash('grep "^checkpoint_path:" .rune/arc-phase-loop.local.md | sed "s/^checkpoint_path: //"').trim()
if (stateCheckpointPath !== checkpointPath) {
  throw new Error(`FATAL (CKPT-001): State file checkpoint_path "${stateCheckpointPath}" does not match canonical "${checkpointPath}". Fix the state file.`)
}

// ── POST-WRITE CROSS-FIELD VERIFICATION (INTEG-POST, v2.29.8) ──
// Read back the state file and verify all fields match the variables used to write it.
// This catches template interpolation bugs where ${configDir} resolved to wrong value.
const stateConfigDir = Bash('grep "^config_dir:" .rune/arc-phase-loop.local.md | sed "s/^config_dir: //"').trim()
if (stateConfigDir !== configDir) {
  throw new Error(`FATAL (INTEG-POST-001): State file config_dir "${stateConfigDir}" does not match configDir "${configDir}". Template interpolation bug.`)
}
const stateOwnerPid = Bash('grep "^owner_pid:" .rune/arc-phase-loop.local.md | sed "s/^owner_pid: //"').trim()
if (stateOwnerPid !== String(ownerPid)) {
  throw new Error(`FATAL (INTEG-POST-002): State file owner_pid "${stateOwnerPid}" does not match ownerPid "${ownerPid}". Template interpolation bug.`)
}
const statePlanFile = Bash('grep "^plan_file:" .rune/arc-phase-loop.local.md | sed "s/^plan_file: //"').trim()
if (statePlanFile !== planFile) {
  throw new Error(`FATAL (INTEG-POST-003): State file plan_file "${statePlanFile}" does not match planFile "${planFile}". Template interpolation bug.`)
}
const stateSessionId = Bash('grep "^session_id:" .rune/arc-phase-loop.local.md | sed "s/^session_id: //"').trim()
if (stateSessionId !== sessionId) {
  throw new Error(`FATAL (INTEG-POST-004): State file session_id "${stateSessionId}" does not match sessionId "${sessionId}". Template interpolation bug.`)
}
```

