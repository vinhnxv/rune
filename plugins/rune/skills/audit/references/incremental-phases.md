# Incremental Audit Phases (0.0-0.4) — Full Pseudocode

> Extracted from SKILL.md to keep the main file under 500 lines.
> **Gate**: Only runs when `isIncremental === true`. When `--incremental` is NOT set, these phases are skipped entirely with zero overhead — the full `all_files` list passes directly to Phase 0.5.

```javascript
// ── NON-INCREMENTAL EARLY RETURN (Concern 1: regression safety) ──
if (!isIncremental) {
  // Zero-overhead pass-through — all_files unchanged
  // This ensures default /rune:audit behavior is IDENTICAL to pre-incremental
  goto "Load Custom Ashes"
}
```

## Phase 0.0: Status-Only Exit

```javascript
if (flags['--status']) {
  // Report-only mode — no audit, no teams, no state changes
  // Read state files + generate coverage report
  // See coverage-report.md for template
  const state = Read(".rune/audit-state/state.json")
  if (!state) {
    log("No incremental audit state found. Run /rune:audit --incremental first.")
    return
  }
  // Generate and display coverage report
  // See references/coverage-report.md
  return
}
```

## Phase 0.0.5: Reset (conditional)

```javascript
if (flags['--reset']) {
  // Remove all state files, preserve history/archive
  Bash(`rm -f .rune/audit-state/state.json .rune/audit-state/manifest.json \
    .rune/audit-state/workflows.json .rune/audit-state/apis.json \
    .rune/audit-state/checkpoint.json .rune/audit-state/coverage-report.md`)
  Bash(`rm -rf .rune/audit-state/.lock`)
  log("Incremental audit state reset. Starting fresh.")
}
```

## Phase 0.1: Acquire Lock & Init State Directory

```javascript
// Create state directory if needed
Bash(`mkdir -p .rune/audit-state/history/archive`)

// Clean up leftover temp files from previous crashes
Bash(`for f in .rune/audit-state/*.tmp; do [ -f "$f" ] && rm -f "$f"; done`)

// Acquire advisory lock (mkdir-based TOCTOU-hardened)
// See references/incremental-state-schema.md "Locking Protocol"
const lockDir = ".rune/audit-state/.lock"
const lockAcquired = Bash(`mkdir "${lockDir}" 2>/dev/null && echo "ACQUIRED" || echo "EXISTS"`)
if (lockAcquired === "EXISTS") {
  // Check if lock is stale (dead PID, different config_dir)
  const lockMeta = Read(`${lockDir}/meta.json`)
  if (lockMeta?.config_dir !== configDir) {
    log("Lock held by different installation — skipping incremental")
    goto "Load Custom Ashes"  // Fall back to full audit
  }
  // PID liveness check (Concern 3: check for "node" not "claude")
  // Validate PID is a positive integer before shell interpolation (SEC-001)
  if (!/^\d+$/.test(String(lockMeta.pid))) {
    log("Invalid PID in lock file — removing stale lock")
    Bash(`rm -rf "${lockDir}"`)
    const reacquired = Bash(`mkdir "${lockDir}" 2>/dev/null && echo "ACQUIRED" || echo "FAILED"`)
    if (reacquired === "FAILED") {
      log("Lost lock race after stale cleanup — skipping incremental")
      goto "Load Custom Ashes"  // Fall back to full audit
    }
    // Re-write lock metadata below
  } else {
    const pidAlive = Bash(`kill -0 ${lockMeta.pid} 2>/dev/null && ps -p ${lockMeta.pid} -o comm= | grep -q node && echo "alive" || echo "dead"`)
    if (pidAlive === "alive") {
      log("Another audit session (PID ${lockMeta.pid}) is active — skipping incremental update")
      goto "Load Custom Ashes"  // Fall back to full audit
    }
    // Stale lock — clean up and retry (verify reacquisition to close race window)
    Bash(`rm -rf "${lockDir}"`)
    const reacquired = Bash(`mkdir "${lockDir}" 2>/dev/null && echo "ACQUIRED" || echo "FAILED"`)
    if (reacquired === "FAILED") {
      log("Lost lock race after stale cleanup — skipping incremental")
      goto "Load Custom Ashes"  // Fall back to full audit
    }
  }
}
// Lock successfully acquired — mark for write-back gate
incrementalLockAcquired = true
// Write lock metadata
Write(`${lockDir}/meta.json`, {
  pid: ownerPid, config_dir: configDir,
  started_at: new Date().toISOString(), session_id: sessionId,
  heartbeat_at: new Date().toISOString()
})
```

## Phase 0.1.5: Resume Check

```javascript
if (flags['--resume']) {
  const checkpoint = Read(".rune/audit-state/checkpoint.json")
  if (checkpoint?.status === "active") {
    // Validate session ownership
    // Validate PID is a positive integer before shell interpolation (SEC-001)
    if (!/^\d+$/.test(String(checkpoint.owner_pid))) {
      log("Invalid PID in checkpoint — starting fresh")
      goto "Phase 0.2"
    }
    const cpPidAlive = Bash(`kill -0 ${checkpoint.owner_pid} 2>/dev/null && echo "alive" || echo "dead"`)
    if (checkpoint.config_dir === configDir && cpPidAlive === "dead") {
      // Stale checkpoint from dead session — resume
      log(`Resuming from checkpoint: ${checkpoint.completed.length}/${checkpoint.batch.length} completed`)
      const remainingBatch = checkpoint.batch.filter(f => !checkpoint.completed.includes(f))
      all_files = remainingBatch
      goto "Load Custom Ashes"  // Skip re-scoring, use checkpoint batch
    }
    if (checkpoint.config_dir !== configDir) {
      log("Checkpoint belongs to different installation — starting fresh")
    }
  } else {
    log("No active checkpoint found — starting fresh incremental audit")
  }
}
```

## Phase 0.2: Build Manifest (Codebase Mapper)

See [codebase-mapper.md](codebase-mapper.md) for the full protocol.

```javascript
// Load previous manifest for warm-run optimization
const prevManifest = Read(".rune/audit-state/manifest.json")
const isGitRepo = Bash(`git rev-parse --is-inside-work-tree 2>/dev/null || echo "false"`).trim()

let manifest
if (isGitRepo === "true") {
  // Check for warm-run (no new commits since last scan)
  if (prevManifest?.last_commit_hash) {
    // Validate commit hash is a hex string before shell interpolation (SEC-002)
    if (!/^[0-9a-f]{7,40}$/i.test(prevManifest.last_commit_hash)) {
      log("Invalid commit hash in manifest — skipping warm-run optimization")
      prevManifest.last_commit_hash = null  // force full scan
    }
  }
  if (prevManifest?.last_commit_hash) {
    const newCommits = Bash(`git rev-list --count ${prevManifest.last_commit_hash}..HEAD 2>/dev/null || echo "-1"`)
    if (newCommits === "0") {
      log("Warm run: no new commits — reusing cached manifest")
      manifest = prevManifest
      goto "Phase 0.3"
    }
  }

  // Batch git metadata extraction (4 commands, not per-file)
  // 1. Current hash per tracked file
  const lsFiles = Bash(`git ls-files -s`)
  // 2. Last modification per file (--since="1 year" ceiling — Concern 2)
  const gitLog = Bash(`git log --all --format="%H %aI" --name-only --since="1 year"`)
  // 3. Contributors + churn (90-day window)
  const gitStats = Bash(`git log --since="90 days ago" --format="%H %aN" --numstat`)
  // 4. File creation dates
  const gitCreation = Bash(`git log --all --diff-filter=A --format="%aI %H" --name-only --since="1 year"`)

  // Build manifest entries from parsed git data
  manifest = buildManifestFromGit(all_files, lsFiles, gitLog, gitStats, gitCreation)
} else {
  // Non-git fallback: mtime-based metadata
  manifest = buildManifestFromFilesystem(all_files)
}

manifest.last_commit_hash = isGitRepo === "true"
  ? Bash(`git rev-parse HEAD`).trim() : null
manifest.updated_at = new Date().toISOString()

// Apply extra_skip_patterns from talisman
const skipPatterns = talisman?.audit?.incremental?.extra_skip_patterns || []
for (const pattern of skipPatterns) {
  // Mark matching files as "excluded"
  manifest = applySkipPattern(manifest, pattern)
}

// Atomic write manifest
Write(".rune/audit-state/manifest.json", manifest)
```

## Phase 0.3: Manifest Diff & State Reconciliation

```javascript
const state = Read(".rune/audit-state/state.json") || initFreshState()

// Compute diff between current and previous manifest
if (prevManifest) {
  const diff = diffManifest(manifest, prevManifest)
  log(`Manifest diff: +${diff.added.length} added, ~${diff.modified.length} modified, -${diff.deleted.length} deleted`)

  // Mark modified files as "stale" in state
  for (const path of diff.modified) {
    if (state.files[path]) {
      state.files[path].changed_since_audit = true
      state.files[path].status = "stale"
    }
  }

  // Add new files to state as "never_audited"
  for (const path of diff.added) {
    state.files[path] = {
      status: "never_audited", audit_count: 0, coverage_gap_streak: 0,
      consecutive_error_count: 0, previous_paths: [], findings: { P1: 0, P2: 0, P3: 0, total: 0 }
    }
  }

  // Mark deleted files
  for (const path of diff.deleted) {
    if (state.files[path]) {
      state.files[path].status = "deleted"
    }
  }
}

// Reconcile: paths in manifest not in state → add as never_audited
// See references/incremental-state-schema.md "Manifest-State Reconciliation"
for (const path in manifest.files) {
  if (manifest.files[path].status !== "excluded" && !state.files[path]) {
    state.files[path] = {
      status: "never_audited", audit_count: 0, coverage_gap_streak: 0,
      consecutive_error_count: 0, previous_paths: [], findings: { P1: 0, P2: 0, P3: 0, total: 0 }
    }
  }
}
```

## Phase 0.3.5: Priority Scoring

See [priority-scoring.md](priority-scoring.md) for the full algorithm.

```javascript
// Read and validate weights from talisman (normalize if needed)
const defaultWeights = { staleness: 0.30, recency: 0.25, risk: 0.20, complexity: 0.10, novelty: 0.10, role: 0.05 }
let weights = talisman?.audit?.incremental?.weights || defaultWeights
const weightSum = Object.values(weights).reduce((a, b) => a + b, 0)
if (Math.abs(weightSum - 1.0) > 0.001) {
  log(`Warning: weights sum to ${weightSum}, normalizing to 1.0`)
  for (const key of Object.keys(weights)) weights[key] /= weightSum
}

// Load Lore Layer risk map (if available)
const riskMap = Read("tmp/lore/risk-map.json")  // May be null — default MEDIUM

// Score each auditable file
const scored = []
for (const [path, entry] of Object.entries(manifest.files)) {
  if (entry.status === "excluded") continue
  const stateEntry = state.files[path]
  if (stateEntry?.status === "deleted" || stateEntry?.status === "error_permanent") continue

  const score = (
    weights.staleness  * computeStalenessScore(stateEntry) +
    weights.recency    * computeRecencyScore(entry) +
    weights.risk       * computeRiskScore(path, riskMap) +
    weights.complexity * computeComplexityScore(entry) +
    weights.novelty    * computeNoveltyScore(entry) +
    weights.role       * computeRoleScore(path)
  )

  // Apply error penalty (consecutive_error_count 1-2: -count * 3.0)
  const errorPenalty = (stateEntry?.consecutive_error_count || 0) * 3.0
  scored.push({ path, score: Math.max(0, score - errorPenalty), entry, stateEntry })
}
```

## Phase 0.4: Batch Selection

See [priority-scoring.md](priority-scoring.md) "Batch Selection" section.

```javascript
// Apply --focus filter BEFORE scoring (reduces candidate set)
let candidates = scored
if (flags['--focus']) {
  candidates = candidates.filter(f => matchesFocusArea(f.path, flags['--focus']))
}

// Apply --force-files (always include matching files)
const forceFiles = flags['--force-files']
  ? candidates.filter(f => matchGlob(f.path, flags['--force-files']))
  : []

// Apply --tier filter
const tier = flags['--tier'] || 'all'

// Tier 2/3 integration point (after file batch selection):
// See references/workflow-discovery.md and references/workflow-audit.md for Tier 2 execution details.
// See references/api-discovery.md and references/api-audit.md for Tier 3 execution details.
if (tier === 'all' || tier === 'workflow') {
  // Invoke workflow discovery + audit on the selected batch
}
if (tier === 'all' || tier === 'api') {
  // Invoke API discovery + audit on the selected batch
}

// Batch selection with composition rules
const batchSize = talisman?.audit?.incremental?.batch_size || 30
const minBatch = talisman?.audit?.incremental?.min_batch_size || 10
const alwaysAudit = talisman?.audit?.incremental?.always_audit || []

const batch = selectBatch(candidates, {
  batchSize, minBatch, alwaysAudit, forceFiles,
  neverAuditedFloor: 5, gapCarryForwardPct: 0.10
})

log(`Incremental batch: ${batch.length} files selected from ${candidates.length} candidates`)

// Write checkpoint for crash resume
Write(".rune/audit-state/checkpoint.json", {
  audit_id, started_at: new Date().toISOString(),
  batch: batch.map(f => f.path), completed: [], current_file: null,
  team_name: `rune-audit-${audit_id}`, status: "active",
  config_dir: configDir, owner_pid: ownerPid, session_id: sessionId
})

// Override all_files with the incremental batch
all_files = batch.map(f => f.path)
```
