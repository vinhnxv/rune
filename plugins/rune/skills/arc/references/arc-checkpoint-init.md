# Initialize Checkpoint (ARC-2) — Full Algorithm

Checkpoint initialization: config resolution (3-layer), session identity,
checkpoint schema v23 creation, skip map computation, and initial state write.

**Inputs**: plan path, talisman config, arc arguments, `freshnessResult` from Freshness Check
**Outputs**: checkpoint object (schema v23), resolved arc config (`arcConfig`), pre-computed `skip_map`
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
// FIX (v1.163.1): Replace abstract readTalismanSection("arc") with explicit shard read.
// Root cause: LLM bypassed the pseudo-function and checked arc.yml (wrong extension)
// instead of arc.json, causing silent fallback to hardcoded defaults.
// Explicit Read() with the correct path eliminates the indirection that enabled the bypass.
let arc = null
try {
  arc = JSON.parse(Read("tmp/.talisman-resolved/arc.json"))
} catch (e) {
  // Fallback: try full talisman file (covers case where shards were not resolved)
  try {
    const fullTalisman = Read(".rune/talisman.yml")
    // parseYaml is a dispatcher utility — parses YAML string to object
    const full = parseYaml(fullTalisman)
    arc = full?.arc ?? {}
  } catch (e2) {
    arc = {}
    warn("No talisman config available — using hardcoded defaults for arc config")
  }
}
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
    // GRACE-002 FIX: Include bot_review in Layer 1 defaults for 3-layer consistency
    bot_review: false,
    no_bot_review: false,
  }

  // Layer 2: Talisman overrides (null-safe)
  const talismanDefaults = arc?.defaults ?? {}
  const talismanShip = arc?.ship ?? {}
  const talismanPreMerge = arc?.pre_merge_checks ?? {}  // QUAL-001 FIX

  // RUIN-001 FIX: Use typeof === 'boolean' for Layer 2 boolean fields (14 total).
  // This rejects non-boolean types (string "false", numbers) AND treats null as "use default"
  // (closes RUIN-002 null-propagation behavioral change from ?? era).
  // GRACE-001 FIX: 14 boolean fields — 6 defaults + 6 ship + 2 top-level (bot_review, inspect_enabled).
  const config = {
    no_forge:        typeof talismanDefaults.no_forge === 'boolean' ? talismanDefaults.no_forge : defaults.no_forge,
    approve:         typeof talismanDefaults.approve === 'boolean' ? talismanDefaults.approve : defaults.approve,
    skip_freshness:  typeof talismanDefaults.skip_freshness === 'boolean' ? talismanDefaults.skip_freshness : defaults.skip_freshness,
    confirm:         typeof talismanDefaults.confirm === 'boolean' ? talismanDefaults.confirm : defaults.confirm,
    no_test:         typeof talismanDefaults.no_test === 'boolean' ? talismanDefaults.no_test : defaults.no_test,
    no_browser_test: typeof talismanDefaults.no_browser_test === 'boolean' ? talismanDefaults.no_browser_test : defaults.no_browser_test,
    accept_external_changes: typeof talismanDefaults.accept_external_changes === 'boolean' ? talismanDefaults.accept_external_changes : defaults.accept_external_changes,
    ship: {
      auto_pr:       typeof talismanShip.auto_pr === 'boolean' ? talismanShip.auto_pr : defaults.ship.auto_pr,
      auto_merge:    typeof talismanShip.auto_merge === 'boolean' ? talismanShip.auto_merge : defaults.ship.auto_merge,
      // SEC-001 FIX: Validate merge_strategy against allowlist at config resolution time
      merge_strategy: ["squash", "rebase", "merge"].includes(talismanShip.merge_strategy)
        ? talismanShip.merge_strategy : defaults.ship.merge_strategy,
      wait_ci:       typeof talismanShip.wait_ci === 'boolean' ? talismanShip.wait_ci : defaults.ship.wait_ci,
      draft:         typeof talismanShip.draft === 'boolean' ? talismanShip.draft : defaults.ship.draft,
      labels:        Array.isArray(talismanShip.labels) ? talismanShip.labels : defaults.ship.labels,  // SEC-DECREE-002: validate array
      pr_monitoring: typeof talismanShip.pr_monitoring === 'boolean' ? talismanShip.pr_monitoring : defaults.ship.pr_monitoring,
      rebase_before_merge: typeof talismanShip.rebase_before_merge === 'boolean' ? talismanShip.rebase_before_merge : defaults.ship.rebase_before_merge,
      // BACK-012 FIX: Include co_authors in 3-layer resolution (was read from raw talisman)
      // QUAL-003 FIX: Check arc.ship.co_authors first, fall back to work.co_authors
      co_authors: Array.isArray(talismanShip.co_authors) ? talismanShip.co_authors
        : Array.isArray(work?.co_authors) ? work.co_authors : [],
    },
    // GRACE-002 FIX: Include bot_review in Layer 2 talisman resolution (was CLI-only)
    bot_review: typeof (arc?.bot_review) === 'boolean' ? arc.bot_review : defaults.bot_review,
    no_bot_review: typeof (arc?.no_bot_review) === 'boolean' ? arc.no_bot_review : defaults.no_bot_review,
    // RUIN-004 FIX: Include inspect.enabled in 3-layer resolution (was raw talisman read in computeSkipMap)
    inspect_enabled: typeof (arc?.inspect?.enabled) === 'boolean' ? arc.inspect.enabled : true,
    // BACK-001 FIX: Include verify.enabled in 3-layer resolution (was missing — computeSkipMap check was dead code)
    verify_enabled: typeof (arc?.verify?.enabled) === 'boolean' ? arc.verify.enabled : true,
    // QUAL-001 FIX: Include pre_merge_checks in config resolution (was missing — talisman overrides silently ignored)
    pre_merge_checks: {
      migration_conflict: talismanPreMerge.migration_conflict ?? true,
      schema_conflict: talismanPreMerge.schema_conflict ?? true,
      lock_file_conflict: talismanPreMerge.lock_file_conflict ?? true,
      uncommitted_changes: talismanPreMerge.uncommitted_changes ?? true,
      migration_paths: Array.isArray(talismanPreMerge.migration_paths) ? talismanPreMerge.migration_paths : [],
    },
    // v2.31.0: User-defined phase skip list (merged into skip_map at init time)
    skip_phases: Array.isArray(arc?.skip_phases) ? arc.skip_phases : [],
  }

  // Layer 3: Inline CLI flags override (only if explicitly passed)
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
  // Bot review flags: --no-bot-review (force off) > --bot-review (force on) > talisman
  // Phase 9.1/9.2 read these from arcConfig via flags.bot_review / flags.no_bot_review
  if (inlineFlags.bot_review !== undefined) config.bot_review = inlineFlags.bot_review
  if (inlineFlags.no_bot_review !== undefined) config.no_bot_review = inlineFlags.no_bot_review
  // BACK-001 FIX: Wire --no-verify CLI flag to verify_enabled (was missing — skip map dead code)
  if (inlineFlags.no_verify !== undefined) config.verify_enabled = !inlineFlags.no_verify

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
  // --no-accept-external (force off) > --accept-external (force on) > talisman default (true)
  accept_external_changes: args.includes('--no-accept-external') ? false
    : args.includes('--accept-external') ? true : undefined,
  no_pr: args.includes('--no-pr') ? true : undefined,
  no_merge: args.includes('--no-merge') ? true : undefined,
  draft: args.includes('--draft') ? true : undefined,
  bot_review: args.includes('--bot-review') ? true : undefined,
  no_bot_review: args.includes('--no-bot-review') ? true : undefined,
  // BACK-001 FIX: Wire --no-verify CLI flag into inlineFlags (was missing)
  no_verify: args.includes('--no-verify') ? true : undefined,
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

## Skip Map Computation (v1.162.0+)

Pre-compute deterministic phase skip decisions from talisman config, plan frontmatter, and CLI flags.
Phases in the skip map are auto-skipped by the stop hook without LLM dispatch — saving ~30s per skipped phase.

```javascript
// ── Gather talisman inputs for skip map ──
// readTalismanSection: "misc", "codex", "ux"
const miscConfig = readTalismanSection("misc") ?? {}
const designSync = miscConfig.design_sync ?? {}
const storybook = miscConfig.storybook ?? {}
const ux = readTalismanSection("ux") ?? {}
const codex = readTalismanSection("codex") ?? {}

// ── Detect external tools ──
const codexAvailable = Bash("command -v codex >/dev/null 2>&1 && echo 'yes' || echo 'no'").trim() === "yes"
const codexEnabled = codexAvailable
  && codex?.disabled !== true
  && Array.isArray(codex?.workflows) && codex.workflows.includes("arc")

/**
 * computeSkipMap — Pre-compute deterministic phase skip decisions.
 *
 * @param {object} arcConfig — Resolved arc config from 3-layer resolution
 * @param {object} designSync — talisman misc.design_sync section
 * @param {object} storybook — talisman misc.storybook section
 * @param {object} ux — talisman ux section
 * @param {boolean} codexAvailable — Whether Codex CLI is installed and reachable
 * @param {boolean} codexEnabled — Whether Codex CLI is available AND enabled for arc
 * @param {object} codex — talisman codex section (for per-phase granular disable)
 * @param {object} planMeta — Extracted YAML frontmatter from plan file
 * @returns {object} Map of { phase_name: skip_reason_string } for phases to auto-skip.
 *   Phases NOT in the map are dispatched normally. Empty map = no pre-skipping.
 *
 * Valid skip reasons (canonical enum — keep in sync with arc-phase-constants.md):
 *   forge_disabled, design_sync_disabled, no_figma_urls, storybook_disabled,
 *   ux_disabled, codex_unavailable, codex_disabled_for_arc, codex_phase_disabled,
 *   bot_review_disabled, testing_disabled
 */
function computeSkipMap(arcConfig, designSync, storybook, ux, codexAvailable, codexEnabled, codex, planMeta, planFile) {
  const map = {}

  // ── Forge (unified via skip_map instead of inline status) ──
  if (arcConfig.no_forge) {
    map.forge = "forge_disabled"
  }

  // ── Design phases (4 phases when design_sync disabled, 2 when enabled but no URLs) ──
  const designEnabled = designSync.enabled === true
  const hasFigmaUrls = Array.isArray(planMeta?.figma_urls) && planMeta.figma_urls.length > 0

  // Fallback: scan plan body for Figma URLs when frontmatter is empty.
  // This handles arc-issues generated plans where URLs are in the body but not frontmatter.
  const hasFigmaUrlsInBody = (() => {
    if (hasFigmaUrls) return false  // Frontmatter has URLs — no need to scan body
    try {
      const planContent = Read(planFile)
      const bodyStart = planContent.indexOf('---', planContent.indexOf('---') + 3)
      if (bodyStart < 0) return false
      const planBody = planContent.substring(bodyStart + 3)
      // Strip code blocks before scanning
      const bodyClean = planBody.replace(/```[\s\S]*?```/g, '')
      return /https:\/\/(www\.)?figma\.com\/(design|file)\/[A-Za-z0-9]+/.test(bodyClean)
    } catch (e) { return false }
  })()

  if (!designEnabled) {
    map.design_extraction = "design_sync_disabled"
    map.design_prototype = "design_sync_disabled"
    // When design_sync is disabled, no VSM files will ever be produced,
    // so design_verification, design_verification_qa, and design_iteration are also deterministically skippable.
    map.design_verification = "design_sync_disabled"
    map.design_verification_qa = "design_sync_disabled"
    map.design_iteration = "design_sync_disabled"
  } else if (!hasFigmaUrls && !hasFigmaUrlsInBody) {
    map.design_extraction = "no_figma_urls"
    map.design_prototype = "no_figma_urls"
    // design_verification: runtime-dependent (VSM files may come from other sources)
    // design_iteration: runtime-dependent (depends on verification result)
  }

  // ── Storybook (1 phase) ──
  if (storybook.enabled !== true) {
    map.storybook_verification = "storybook_disabled"
  }

  // ── UX verification (1 phase) ──
  if (ux.enabled !== true) {
    map.ux_verification = "ux_disabled"
  }

  // ── Codex phases (5 phases including task_decomposition) ──
  if (!codexEnabled) {
    const reason = !codexAvailable ? "codex_unavailable" : "codex_disabled_for_arc"
    map.task_decomposition = reason
    map.semantic_verification = reason
    map.codex_gap_analysis = reason
    map.test_coverage_critique = reason
    map.release_quality_check = reason
  } else {
    // Per-phase granular disable (talisman codex sub-keys)
    // QUAL-001 FIX: Use phase-specific skip reasons to match runtime paths in arc-codex-phases.md
    if (codex?.task_decomposition?.enabled === false)
      map.task_decomposition = "codex_task_decomposition_disabled"
    if (codex?.semantic_verification?.enabled === false)
      map.semantic_verification = "codex_semantic_verification_disabled"
    if (codex?.gap_analysis?.enabled === false)
      map.codex_gap_analysis = "codex_gap_analysis_disabled"
    if (codex?.test_coverage?.enabled === false)
      map.test_coverage_critique = "codex_test_coverage_disabled"
    if (codex?.release_quality?.enabled === false)
      map.release_quality_check = "codex_release_quality_disabled"
  }

  // ── Verify phase (1 phase) ──
  if (arcConfig.verify_enabled === false) {
    map.verify = "verify_disabled"
  }

  // ── Inspect phases (3 phases) ──
  // RUIN-004 FIX: Use 3-layer resolved arcConfig instead of raw talisman read
  if (arcConfig.inspect_enabled === false) {
    map.inspect = "inspect_disabled"
    map.inspect_fix = "inspect_disabled"
    map.verify_inspect = "inspect_disabled"
  }

  // ── Bot review (2 phases) ──
  const botReviewEnabled = arcConfig.bot_review === true
    && arcConfig.no_bot_review !== true
  if (!botReviewEnabled) {
    map.bot_review_wait = "bot_review_disabled"
    map.pr_comment_resolution = "bot_review_disabled"
  }

  // ── Test phase ──
  if (arcConfig.no_test) {
    map.test = "testing_disabled"
  }

  // ── Browser test phases ──
  // Skip all 3 browser test loop phases when --no-browser-test or --no-test
  if (arcConfig.no_browser_test || arcConfig.no_test) {
    map.browser_test = "browser_test_disabled"
    map.browser_test_fix = "browser_test_disabled"
    map.verify_browser_test = "browser_test_disabled"
  }

  // ── QA gate phase skip propagation ──
  // QUAL-001 FIX: Order matches PHASE_ORDER canonical sequence
  const QA_GATED_PHASES = ['forge', 'work', 'gap_analysis', 'code_review', 'mend', 'test', 'design_verification']
  // readTalismanSection: "gates"
  const gatesConfig = readTalismanSection("gates") ?? {}
  const qaEnabled = gatesConfig?.qa_gates?.enabled !== false  // default: true
  if (!qaEnabled) {
    for (const phase of QA_GATED_PHASES) {
      map[`${phase}_qa`] = "qa_gates_disabled"
    }
  } else {
    // If parent phase is skipped, auto-skip the corresponding QA phase
    for (const phase of QA_GATED_PHASES) {
      if (map[phase]) {
        map[`${phase}_qa`] = `parent_${phase}_skipped`
      }
    }
  }

  // ── User-defined skip phases (v2.31.0+) ──
  // Merge arc.skip_phases[] from talisman config. Applied AFTER all feature-based
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

const skipMap = computeSkipMap(arcConfig, designSync, storybook, ux, codexAvailable, codexEnabled, codex, planMeta, planFile)
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
  id, schema_version: 28, plan_file: planFile,
  config_dir: configDir, owner_pid: ownerPid, session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  // RUIN-003 FIX: Remove redundant ?? guards — Layer 2 resolveArcConfig() already guarantees all values are defined
  flags: { approve: arcConfig.approve, no_forge: arcConfig.no_forge, skip_freshness: arcConfig.skip_freshness, confirm: arcConfig.confirm, no_test: arcConfig.no_test, no_browser_test: arcConfig.no_browser_test, accept_external_changes: arcConfig.accept_external_changes, bot_review: arcConfig.bot_review, no_bot_review: arcConfig.no_bot_review },
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
    forge:        { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    forge_qa:     { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0 },
    plan_review:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    plan_refine:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    semantic_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_extraction: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_prototype: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    task_decomposition: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    work:         { status: "pending", artifact: null, artifact_hash: null, team_name: null,
                    // Schema v16 (v1.106.0): suspended tasks from context preservation protocol.
                    // Each entry: { task_id, context_path, reason }
                    // context_path scoped to arc checkpoint id (FAIL-008): context/{id}/{task_id}.md
                    suspended_tasks: [], started_at: null, completed_at: null },
    work_qa:      { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0 },
    drift_review: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    storybook_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_verification_qa: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0 },
    ux_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    gap_analysis: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    gap_analysis_qa: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0 },
    codex_gap_analysis: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    gap_remediation: { status: "pending", artifact: null, artifact_hash: null, team_name: null, fixed_count: null, deferred_count: null, started_at: null, completed_at: null },
    inspect: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, completion_pct: null, p1_count: null, verdict: null },
    inspect_fix: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, fixed_count: null, deferred_count: null },
    verify_inspect: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    goldmask_verification: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    code_review:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    code_review_qa: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0 },
    goldmask_correlation: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    verify:       { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    mend:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    mend_qa:      { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0 },
    verify_mend:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    design_iteration: { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
    test:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, tiers_run: [], pass_rate: null, coverage_pct: null, has_frontend: false, started_at: null, completed_at: null },
    test_qa:      { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, retry_count: 0 },
    browser_test:         { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, routes_tested: 0, routes_passed: 0, routes_failed: 0 },
    browser_test_fix:     { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null, fixed_count: null },
    verify_browser_test:  { status: "pending", artifact: null, artifact_hash: null, team_name: null, started_at: null, completed_at: null },
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
  // Controls the inspect → inspect_fix → verify_inspect loop (Phases 5.9, 5.95, 5.99).
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
    max_global_retries: (() => { const g = readTalismanSection("gates"); return g?.qa_gates?.max_global_retries ?? 6 })(),
    max_infra_global_retries: (() => { const g = readTalismanSection("gates"); return g?.qa_gates?.max_infra_global_retries ?? 12 })(),  // 6 phases × 2 retries
    pass_threshold: (() => { const g = readTalismanSection("gates"); return g?.qa_gates?.pass_threshold ?? 70 })(),
    max_phase_retries: (() => { const g = readTalismanSection("gates"); return g?.qa_gates?.max_phase_retries ?? 2 })(),
    enabled: (() => { const g = readTalismanSection("gates"); return g?.qa_gates?.enabled !== false })()
  },
  // Schema v26 addition (v2.5.1): Declarative reaction engine config.
  // Reads reactions from resolved talisman shard with fallback chain.
  // Backward-compat: when reactions.* absent, falls back to legacy paths
  // (gates.qa_gates.*, process_management.*). reactions.* takes precedence.
  reactions: (() => {
    let reactions = null
    try {
      reactions = JSON.parse(Read("tmp/.talisman-resolved/reactions.json"))
    } catch (e) {
      try {
        const fullTalisman = Read(".rune/talisman.yml")
        const full = parseYaml(fullTalisman)
        reactions = full?.reactions ?? {}
      } catch (e2) {
        reactions = {}
        warn("No reactions config available — using hardcoded defaults")
      }
    }
    // Backward-compat aliasing (v2.5.1): when reactions.* keys are absent,
    // fall back to legacy talisman paths. reactions.* takes precedence.
    // Legacy paths: gates.qa_gates.* → reactions.qa_gate_failed.*
    //               process_management.* → reactions.teammate_stuck.*
    const gatesConfig = readTalismanSection("gates") ?? {}
    const pmConfig = readTalismanSection("misc")?.process_management ?? readTalismanSection("process_management") ?? {}
    if (!reactions.qa_gate_failed && gatesConfig.qa_gates) {
      warn("DEPRECATION: gates.qa_gates.* used as fallback for reactions.qa_gate_failed — migrate to reactions: section")
      reactions.qa_gate_failed = {
        action: "retry",
        retries: gatesConfig.qa_gates.max_phase_retries ?? 2,
        pass_threshold: gatesConfig.qa_gates.pass_threshold ?? 70,
        max_global_retries: gatesConfig.qa_gates.max_global_retries ?? 6
      }
    }
    if (!reactions.teammate_stuck && pmConfig.teammate_stuck_threshold) {
      warn("DEPRECATION: process_management.teammate_stuck_threshold used as fallback for reactions.teammate_stuck — migrate to reactions: section")
      reactions.teammate_stuck = {
        action: "escalate",
        threshold_ms: (pmConfig.teammate_stuck_threshold ?? 180) * 1000,
        force_stop_after_ms: 300000
      }
    }
    return reactions
  })(),
  // Schema v26 addition: Per-event reaction state tracking for retry budgets and escalation.
  // Tracks attempt counts and first-attempt timestamps per reaction event.
  // On --resume: firstAttemptMs is reset to current time (EC-7 fix), attemptCount preserved.
  reaction_state: {
    per_event_counters: {},
    _meta: { last_resume_at: null }
  },
  // Schema v26 addition: CI status tracking for CI fix loop in bot_review_wait phase.
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
const sessionId = "${CLAUDE_SESSION_ID}" || Bash('echo "${RUNE_SESSION_ID:-}"').trim() || 'unknown'
// INTEG-INIT-006: sessionId must not be 'unknown' (both sources failed)
if (sessionId === 'unknown') {
  throw new Error(`FATAL (INTEG-INIT-006): sessionId is 'unknown' — neither CLAUDE_SESSION_ID nor RUNE_SESSION_ID is available.`)
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

