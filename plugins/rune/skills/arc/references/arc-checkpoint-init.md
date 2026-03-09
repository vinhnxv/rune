# Initialize Checkpoint (ARC-2) — Full Algorithm

Checkpoint initialization: config resolution (3-layer), session identity,
checkpoint schema v22 creation, and initial state write.

**Inputs**: plan path, talisman config, arc arguments, `freshnessResult` from Freshness Check
**Outputs**: checkpoint object (schema v22), resolved arc config (`arcConfig`)
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
const rawNonce = crypto.randomBytes(6).toString('hex').toLowerCase()
// Validate format AFTER generation, BEFORE checkpoint write: exactly 12 lowercase hex characters
// .toLowerCase() ensures consistency across JS runtimes (defense-in-depth)
if (!/^[0-9a-f]{12}$/.test(rawNonce)) {
  throw new Error(`Session nonce generation failed. Must be 12 hex chars from crypto.randomBytes(6). Retry arc invocation.`)
}
const sessionNonce = rawNonce

// SEC-006 FIX: Compute tier BEFORE checkpoint init (was referenced but never defined)
// SEC-011 FIX: Null guard — parseDiffStats may return null on empty/malformed git output
const diffStats = parseDiffStats(Bash(`git diff --stat ${defaultBranch}...HEAD`)) ?? { insertions: 0, deletions: 0, files: [] }
const planMeta = extractYamlFrontmatter(Read(planFile))
// readTalismanSection: "arc", "work"
const arc = readTalismanSection("arc")
const work = readTalismanSection("work")
```

## 3-Layer Config Resolution

```javascript
// 3-layer config resolution: hardcoded defaults → talisman → inline CLI flags (v1.40.0+)
// Contract: inline flags ALWAYS override talisman; talisman overrides hardcoded defaults.
function resolveArcConfig(arc, work, inlineFlags) {
  // Layer 1: Hardcoded defaults
  const defaults = {
    no_forge: false,
    approve: false,
    skip_freshness: false,
    confirm: false,
    no_test: false,
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
    }
  }

  // Layer 2: Talisman overrides (null-safe)
  const talismanDefaults = arc?.defaults ?? {}
  const talismanShip = arc?.ship ?? {}
  const talismanPreMerge = arc?.pre_merge_checks ?? {}  // QUAL-001 FIX

  const config = {
    no_forge:        talismanDefaults.no_forge ?? defaults.no_forge,
    approve:         talismanDefaults.approve ?? defaults.approve,
    skip_freshness:  talismanDefaults.skip_freshness ?? defaults.skip_freshness,
    confirm:         talismanDefaults.confirm ?? defaults.confirm,
    no_test:         talismanDefaults.no_test ?? defaults.no_test,
    accept_external_changes: talismanDefaults.accept_external_changes ?? defaults.accept_external_changes,
    ship: {
      auto_pr:       talismanShip.auto_pr ?? defaults.ship.auto_pr,
      auto_merge:    talismanShip.auto_merge ?? defaults.ship.auto_merge,
      // SEC-001 FIX: Validate merge_strategy against allowlist at config resolution time
      merge_strategy: ["squash", "rebase", "merge"].includes(talismanShip.merge_strategy)
        ? talismanShip.merge_strategy : defaults.ship.merge_strategy,
      wait_ci:       talismanShip.wait_ci ?? defaults.ship.wait_ci,
      draft:         talismanShip.draft ?? defaults.ship.draft,
      labels:        Array.isArray(talismanShip.labels) ? talismanShip.labels : defaults.ship.labels,  // SEC-DECREE-002: validate array
      pr_monitoring: talismanShip.pr_monitoring ?? defaults.ship.pr_monitoring,
      rebase_before_merge: talismanShip.rebase_before_merge ?? defaults.ship.rebase_before_merge,
      // BACK-012 FIX: Include co_authors in 3-layer resolution (was read from raw talisman)
      // QUAL-003 FIX: Check arc.ship.co_authors first, fall back to work.co_authors
      co_authors: Array.isArray(talismanShip.co_authors) ? talismanShip.co_authors
        : Array.isArray(work?.co_authors) ? work.co_authors : [],
    },
    // QUAL-001 FIX: Include pre_merge_checks in config resolution (was missing — talisman overrides silently ignored)
    pre_merge_checks: {
      migration_conflict: talismanPreMerge.migration_conflict ?? true,
      schema_conflict: talismanPreMerge.schema_conflict ?? true,
      lock_file_conflict: talismanPreMerge.lock_file_conflict ?? true,
      uncommitted_changes: talismanPreMerge.uncommitted_changes ?? true,
      migration_paths: Array.isArray(talismanPreMerge.migration_paths) ? talismanPreMerge.migration_paths : [],
    }
  }

  // Layer 3: Inline CLI flags override (only if explicitly passed)
  if (inlineFlags.no_forge !== undefined) config.no_forge = inlineFlags.no_forge
  if (inlineFlags.approve !== undefined) config.approve = inlineFlags.approve
  if (inlineFlags.skip_freshness !== undefined) config.skip_freshness = inlineFlags.skip_freshness
  if (inlineFlags.confirm !== undefined) config.confirm = inlineFlags.confirm
  if (inlineFlags.no_test !== undefined) config.no_test = inlineFlags.no_test
  if (inlineFlags.accept_external_changes !== undefined) config.accept_external_changes = inlineFlags.accept_external_changes
  // Ship flags can also be overridden inline
  if (inlineFlags.no_pr !== undefined) config.ship.auto_pr = !inlineFlags.no_pr
  if (inlineFlags.no_merge !== undefined) config.ship.auto_merge = !inlineFlags.no_merge
  if (inlineFlags.draft !== undefined) config.ship.draft = inlineFlags.draft
  // Bot review flags: --no-bot-review (force off) > --bot-review (force on) > talisman
  // Phase 9.1/9.2 read these from arcConfig via flags.bot_review / flags.no_bot_review
  if (inlineFlags.bot_review !== undefined) config.bot_review = inlineFlags.bot_review
  if (inlineFlags.no_bot_review !== undefined) config.no_bot_review = inlineFlags.no_bot_review

  return config
}

// Parse inline flags and resolve config
const inlineFlags = {
  no_forge: args.includes('--no-forge') ? true : undefined,
  approve: args.includes('--approve') ? true : undefined,
  skip_freshness: args.includes('--skip-freshness') ? true : undefined,
  confirm: args.includes('--confirm') ? true : undefined,
  no_test: args.includes('--no-test') ? true : undefined,
  // --no-accept-external (force off) > --accept-external (force on) > talisman default (true)
  accept_external_changes: args.includes('--no-accept-external') ? false
    : args.includes('--accept-external') ? true : undefined,
  no_pr: args.includes('--no-pr') ? true : undefined,
  no_merge: args.includes('--no-merge') ? true : undefined,
  draft: args.includes('--draft') ? true : undefined,
  bot_review: args.includes('--bot-review') ? true : undefined,
  no_bot_review: args.includes('--no-bot-review') ? true : undefined,
}
const arcConfig = resolveArcConfig(arc, work, inlineFlags)
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

## Checkpoint Schema v22

// Schema history: see CHANGELOG.md for migration notes from v12-v22.

```javascript
// ── Resolve session identity for cross-session isolation ──
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

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

Write(`.claude/arc/${id}/checkpoint.json`, {
  id, schema_version: 22, plan_file: planFile,
  config_dir: configDir, owner_pid: ownerPid, session_id: "${CLAUDE_SESSION_ID}",
  flags: { approve: arcConfig.approve, no_forge: arcConfig.no_forge, skip_freshness: arcConfig.skip_freshness, confirm: arcConfig.confirm, no_test: arcConfig.no_test, accept_external_changes: arcConfig.accept_external_changes ?? true, bot_review: arcConfig.bot_review ?? false, no_bot_review: arcConfig.no_bot_review ?? false },
  arc_config: arcConfig,
  pr_url: null,
  freshness: freshnessResult || null,
  session_nonce: sessionNonce, phase_sequence: 0,
  // Schema v14 addition (v1.79.0): parent_plan metadata for hierarchical execution
  parent_plan: parentPlanMeta,
  // Schema v15 addition (v1.80.0): stagnation sentinel state — error patterns, file velocity, budget
  // See references/stagnation-sentinel.md for full algorithm
  stagnation: {
    error_patterns: [],
    file_velocity: [],
    budget: null
  },
  phases: {
    forge:        { status: arcConfig.no_forge ? "skipped" : "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    plan_review:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    plan_refine:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    semantic_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_extraction: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    task_decomposition: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    work:         { status: "pending", artifact: null, artifact_hash: null, team_name: null,
                    // Schema v16 (v1.106.0): suspended tasks from context preservation protocol.
                    // Each entry: { task_id, context_path, reason }
                    // context_path scoped to arc checkpoint id (FAIL-008): context/{id}/{task_id}.md
                    suspended_tasks: [], started_at: null, completed_at: null },
    storybook_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    ux_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    gap_analysis: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    codex_gap_analysis: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    gap_remediation: { status: "pending", artifact: null, artifact_hash: null, team_name: null, fixed_count: null, deferred_count: null, started_at: null, completed_at: null },
    goldmask_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    code_review:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    goldmask_correlation: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    mend:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    verify_mend:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_iteration: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    test:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, tiers_run: [], pass_rate: null, coverage_pct: null, has_frontend: false, started_at: null, completed_at: null },
    test_coverage_critique: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    pre_ship_validation: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    release_quality_check: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    ship:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    bot_review_wait: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    pr_comment_resolution: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    merge:        { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    // Design phases (design_extraction, design_verification, design_iteration) are
    // interleaved at their PHASE_ORDER positions above. Conditionally set to "skipped"
    // at runtime when design_sync.enabled === false.
  },
  // Schema v19 addition (v1.111.0): timing totals — per-phase durations and overall arc metrics
  totals: { phase_times: {}, total_duration_ms: null, cost_at_completion: null },
  // Schema v19 addition (v1.111.0): arc-level completion timestamp (set at Post-Arc stamp)
  completed_at: null,
  convergence: { round: 0, max_rounds: tier.maxCycles, tier: tier, history: [], original_changed_files: changedFiles },
  // NEW (v1.66.0): Shard metadata from pre-flight shard detection (null for non-shard arcs)
  shard: shardInfo ? {
    num: shardInfo.shardNum,           // e.g., 2
    total: shardInfo.totalShards,      // e.g., 4
    name: shardInfo.shardName,         // e.g., "methodology"
    feature: shardInfo.featureName,    // e.g., "superpowers-gap-implementation"
    parent: shardInfo.parentPath,      // e.g., "plans/...-implementation-plan.md"
    dependencies: shardInfo.dependencies  // e.g., [1]
  } : null,
  // CRITICAL: Set todos_base eagerly during init — NOT as a separate post-init step.
  // Previously null here, causing downstream phases to scatter todos across standalone dirs.
  todos_base: `tmp/arc/${id}/todos/`,
  // Schema v22 addition (v1.144.0): cancellation tracking
  user_cancelled: false,
  cancel_reason: null,
  cancelled_at: null,
  stop_reason: null,
  // Schema v22 addition (v1.144.0): scheduled task linkage
  cron_task_id: null,
  // Schema v22 addition (v1.144.0): resume analytics for crash recovery
  resume_tracking: {
    total_resume_count: 0,
    resume_history: [],
    last_resume_at: null,
    consecutive_failures: 0
  },
  // Schema v22 addition (v1.144.0): scheduler state for recurring arcs
  scheduler: {
    created_at: null,
    interval_minutes: null,
    expires_at: null,
    renewal_count: 0,
    last_renewal_at: null
  },
  commits: [],
  started_at: new Date().toISOString(),
  updated_at: new Date().toISOString()
})

// Create the todos directory immediately after checkpoint write.
// Downstream phases (strive, appraise) depend on both the checkpoint field AND
// the directory existing when they scan for arc context.
Bash(`mkdir -p "tmp/arc/${id}/todos/"`)

// ── Scheduled Monitoring Task Creation (Schema v22) ──
// Create a scheduled task to monitor arc health and auto-resume on unexpected stops.
// Only runs when scheduler is enabled and CronCreate is available.
const schedulerConfig = readTalismanSection("arc")?.scheduler ?? {}
const schedulerEnabled = schedulerConfig.enabled !== false

if (schedulerEnabled && typeof CronCreate !== 'undefined') {
  const intervalMinutes = schedulerConfig.interval_minutes ?? 15
  const cronExpr = `*/${intervalMinutes} * * * *`

  // Build the monitoring prompt with all necessary context
  const monitoringPrompt = buildArcMonitoringPrompt(checkpoint)

  try {
    const cronResult = CronCreate({
      cron_expression: cronExpr,
      prompt: monitoringPrompt,
      recurring: true
    })

    // Update checkpoint with scheduler info
    checkpoint.cron_task_id = cronResult.id
    checkpoint.scheduler = {
      created_at: new Date().toISOString(),
      interval_minutes: intervalMinutes,
      expires_at: new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString(),
      renewal_count: 0,
      last_renewal_at: null
    }

    log(`[ARC-SCHEDULER] Created monitoring task ${cronResult.id} for arc ${checkpoint.id}`)
  } catch (error) {
    warn(`Failed to create monitoring task: ${error.message}`)
    // Non-fatal - arc continues without monitoring
  }
} else {
  log("[ARC-SCHEDULER] Scheduled tasks not available or disabled")
}

// Schema migration is handled in arc-resume.md (steps 3a through 3w).
// Migrations v1→v22 are defined there. See arc-resume.md for the full chain.
```

## buildArcMonitoringPrompt()

Generate the monitoring prompt for the scheduled task (Layer 1). This prompt is injected
as plain text into CronCreate and must be self-contained. Simplified in v1.145.0 to
reduce hallucination surface (P1 fix).

```javascript
function buildArcMonitoringPrompt(checkpoint) {
  // SEC: Validate interpolated values before prompt construction (P1 fix)
  if (!/^arc-[a-zA-Z0-9_-]+$/.test(checkpoint.id)) {
    throw new Error("Invalid arc id format — refusing to build monitoring prompt")
  }
  const stateFile = ".claude/arc-phase-loop.local.md"
  const ckptFile = `.claude/arc/${checkpoint.id}/checkpoint.json`

  // Simplified prompt: minimal, unambiguous instructions (P1 fix — reduced hallucination surface)
  return `[ARC-MONITOR] Check arc ${checkpoint.id}.
Read ${stateFile}. If missing or user_cancelled=true or stop_reason is "completed" or "user_cancel": run CronDelete for this task and stop.
Otherwise read ${ckptFile}. If no phase has status "in_progress": run /rune:arc --resume.
If a phase IS in_progress: do nothing (arc is running).`
}
