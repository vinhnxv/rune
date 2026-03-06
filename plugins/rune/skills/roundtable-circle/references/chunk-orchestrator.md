# Chunk Orchestrator — Chunked Review Pipeline

> Wraps the existing Roundtable Circle in a chunking loop when `changed_files.length > CHUNK_THRESHOLD`.
> The inner Roundtable Circle (7-phase lifecycle) remains a black box — chunking wraps, never modifies it.
> Lives in `review.md` Phase 0 (routing branch) and delegates detail to this reference.

## Sharding Supersedes Chunking (v1.98.0+)

When Inscription Sharding is active (`inscription.sharding.enabled === true`), chunked review
is BYPASSED for that review session:

```javascript
// In SKILL.md Phase 1 — set after shard allocation:
inscription.chunked = false  // sharding replaces chunking for standard depth
```

**Rationale:** Sharding is strictly superior to chunked review for standard depth + diff scope:
- Sharding is parallel (shard reviewers run concurrently); chunking is sequential
- Sharding uses domain affinity (related files stay together); chunking uses arbitrary slicing
- Sharding has a dedicated cross-file analysis agent; chunking relies on individual Ash seeing all chunks

Chunked review continues to apply for `scope=full` (audit) where sharding is not active.

## Chunk Decision Routing

This routing check lives in **review.md Phase 0** as a conditional branch — not a separate phase.

```javascript
// Phase 0: Pre-flight + chunk decision (routing concern, not a new pipeline phase)
const CHUNK_THRESHOLD   = config?.chunk_threshold   ?? 20
const CHUNK_TARGET_SIZE = config?.chunk_target_size ?? 15
const MAX_CHUNKS        = config?.max_chunks        ?? 5

// SEC-001 FIX: Use object key lookup (flags['--key']) not array-style flags.includes()
// Must match review.md's BACK-013 FIX pattern for consistent flags access
const noChunk = flags['--no-chunk']

if (changed_files.length <= CHUNK_THRESHOLD || noChunk) {
  // ── SINGLE-PASS ──────────────────────────────────────────────────────────
  // Zero behavioral change — existing Roundtable Circle, unmodified
  runSinglePassReview(changed_files, identifier, flags)
} else {
  // ── CHUNKED REVIEW ───────────────────────────────────────────────────────
  // See: chunk-orchestrator.md for full lifecycle
  runChunkedReview(changed_files, identifier, flags, config)
}
```

## `--dry-run` Output Format

When `--no-chunk` is absent and `--dry-run` is present, print the chunk plan and exit without reviewing:

```
Chunked Review Plan — dry run
══════════════════════════════════════════════════════════

Files: 34  |  Chunks: 3  |  Tier: STANDARD (max 2 re-reviews)
Token cost: ~3x single-pass review (one Roundtable Circle per chunk)

Chunk 1 — plugins/rune/commands/ (12 files, complexity: 18.4)
  plugins/rune/skills/appraise/SKILL.md  [md,  complexity: 0.5]
  plugins/rune/commands/arc.md            [md,  complexity: 0.5]
  plugins/rune/skills/strive/SKILL.md    [md,  complexity: 0.5]
  ... (9 more)

Chunk 2 — plugins/rune/skills/ (14 files, complexity: 21.7)
  plugins/rune/skills/roundtable-circle/SKILL.md  [md, complexity: 0.5]
  ... (13 more)

Chunk 3 — plugins/rune/agents/ (8 files, complexity: 9.2)
  ... (8 files)

Security pins (read-only context in every chunk):
  plugins/rune/scripts/enforce-readonly.sh
  plugins/rune/hooks/hooks.json

Run without --dry-run to begin review.
```

## Token Cost Warning

Before the first TeamCreate, always display the cost multiplier:

```javascript
const chunkCount = Math.min(chunks.length, MAX_CHUNKS)
log(`\nToken cost notice: Chunked review runs ${chunkCount} Roundtable Circle passes.`)
log(`Estimated cost: ~${chunkCount}x a single-pass review of comparable file count.`)
log(`Convergence tier: ${tier.name} — up to ${tier.maxRounds + 1} total passes if re-reviews triggered.`)
log(`Use --no-chunk to force single-pass, or --no-converge to disable re-review rounds.\n`)
```

## Per-Chunk Roundtable Circle Lifecycle

Each chunk runs a full team lifecycle: create → review → cleanup.
The inner Roundtable Circle is invoked unchanged — chunk parameters are passed as context only.

```javascript
// QUAL-014 FIX: Renamed from runChunkReview to reviewSingleChunk for clarity.
// runChunkedReview = top-level orchestrator; reviewSingleChunk = per-chunk lifecycle.
async function reviewSingleChunk(chunk, identifier, flags, securityPins, arcRemainingMs, activeChunkCount) {
  const teamName  = `rune-review-${identifier}-chunk-${chunk.chunkIndex}`  // disambiguated
  const chunkDir  = `tmp/reviews/${identifier}/chunk-${chunk.chunkIndex}`
  const tomePath  = `${chunkDir}/TOME.md`

  mkdir(chunkDir)

  // Dynamic per-chunk timeout — scales with remaining arc budget
  // BACK-011 FIX: Use activeChunkCount (current round's chunk count), not the initial chunkCount
  // from outer scope. On re-review rounds, fewer chunks should get more time each.
  // Floor at 3 min to prevent zero-timeout edge cases.
  const perChunkTimeout = arcRemainingMs
    ? Math.max(Math.floor(arcRemainingMs / activeChunkCount), 180_000)
    : 660_000  // 11 min default when not in arc context

  // ── PRE-CREATE GUARD ──────────────────────────────────────────────────────
  // See: team-sdk/references/engines.md for the canonical 3-step escalation pattern
  // Step 1: try TeamDelete (graceful)
  // Step 2: rm -rf target team dirs (filesystem fallback)
  // Step 3: cross-workflow find scan + retry TeamDelete
  applyPreCreateGuard(teamName)

  // ── TEAM CREATE ───────────────────────────────────────────────────────────
  TeamCreate({ team_name: teamName })

  // ── ROUNDTABLE CIRCLE (inner black box) ───────────────────────────────────
  // Pass chunk.files as the review scope.
  // securityPins are contextFiles: read-only references, not budgeted files.
  Agent({
    team_name: teamName,
    subagent_type: 'general-purpose',
    prompt: buildRoundtablePrompt({
      files:        chunk.files.map(f => f.file ?? f),
      contextFiles: securityPins,  // Read-only security pins for every chunk
      identifier:   teamName,
      outputDir:    chunkDir,
      flags,
    }),
  })

  // ── MONITOR ───────────────────────────────────────────────────────────────
  // **ANTI-PATTERN — NEVER DO THIS:**
  //   Bash("sleep 45 && echo poll check") — skips TaskList, provides zero visibility
  //   Bash("sleep 60 && echo poll check 2") — wrong interval AND skips TaskList
  // **CORRECT**: Call TaskList on every poll cycle.
  // See monitor-utility.md and the polling-guard skill for the canonical monitoring loop.
  waitForCompletion(teamName, ashCount, {
    timeoutMs: perChunkTimeout,  // dynamic per-chunk budget
    staleWarnMs: 300_000,        // 5 minutes
    pollIntervalMs: 30_000,      // 30 seconds — ALWAYS 30s, never arbitrary
    label: `Review Chunk ${chunk.chunkIndex + 1}`
  })

  // ── COLLECT OUTPUT ────────────────────────────────────────────────────────
  const tomeMd = Read(tomePath) ?? buildPartialTome(chunkDir, chunk)
  // If full TOME not written (timeout), collect completed Ash outputs:
  //   glob: tmp/reviews/{id}/chunk-{N}/ash-*-runes.md
  //   status: 'completed_partial', Coverage Gaps for timed-out Ashes

  // ── PRE-DELETE GUARD + CLEANUP ────────────────────────────────────────────
  // Broadcast shutdown, wait for teammate acknowledgements, then TeamDelete
  // rm -rf fallback if TeamDelete fails (see team-sdk/references/engines.md)
  shutdownAndCleanup(teamName)

  writeChunkProgress(identifier, chunk.chunkIndex, 'completed')
  return { chunkIndex: chunk.chunkIndex, tome: tomeMd, path: tomePath }
}
```

## Full Chunked Review Orchestration

```javascript
// QUAL-002 FIX: `config` is `talisman?.review` (the review: section), NOT the full talisman object.
// Caller (review.md) passes `reviewConfig` — all config keys (chunk_threshold, convergence_tier_override,
// convergence_density_threshold, etc.) live directly under config, not under config.review.
// BACK-007 FIX: Added arcRemainingMs as 5th parameter — enables dynamic per-chunk timeout
// when invoked from arc Phase 6. Defaults to null (uses 660_000ms per-chunk default).
async function runChunkedReview(changed_files, identifier, flags, config, arcRemainingMs) {
  // SEC-002 FIX: Defense-in-depth — re-validate identifier at chunk orchestrator boundary
  // Primary validation in review.md Phase 2, but chunk-orchestrator is a separate trust boundary
  if (!/^[a-zA-Z0-9_-]+$/.test(identifier)) throw new Error("SEC-002: identifier validation failed in runChunkedReview")
  // QUAL-005 FIX: Assert config is talisman?.review, NOT the full talisman object
  // If caller passes full talisman, auto-normalize to prevent wrong threshold lookups
  if (config?.review && !config?.convergence_enabled && config?.review?.convergence_enabled !== undefined) {
    warn('QUAL-005: config appears to be full talisman object — normalizing to config.review')
    config = config.review
  }

  // ── SCORING + GROUPING ────────────────────────────────────────────────────
  const diffStats    = parseDiffNumstat()  // git diff --numstat: batch call, not per-file
  const scoredFiles  = changed_files.map(f => scoreFile(f, diffStats))
  // QUAL-009 FIX: CHUNK_TARGET_SIZE comes from the config parameter (review: section of talisman)
  const CHUNK_TARGET_SIZE = config?.chunk_target_size ?? 15
  const MAX_CHUNKS        = config?.max_chunks ?? 5
  const chunks       = groupIntoChunks(scoredFiles, CHUNK_TARGET_SIZE)
  const chunkCount   = Math.min(chunks.length, MAX_CHUNKS)
  const securityPins = collectSecurityPins(scoredFiles)

  // ── CONVERGENCE TIER ─────────────────────────────────────────────────────
  // SEC-001 FIX: Use object key lookup consistently with review.md's BACK-013 pattern
  const convergenceEnabled = !flags['--no-converge'] &&
                             (config?.convergence_enabled ?? true)
  const tier = selectConvergenceTier(scoredFiles, chunks, config)

  // ── TOKEN COST WARNING ────────────────────────────────────────────────────
  displayCostWarning(chunkCount, tier)

  // ── DRY RUN ───────────────────────────────────────────────────────────────
  // SEC-001 FIX: Object key lookup for flags consistency
  if (flags['--dry-run']) {
    displayDryRunPlan(chunks, tier, securityPins, chunkCount)
    return
  }

  // ── CONVERGENCE STATE ─────────────────────────────────────────────────────
  const convergenceHistory = []  // [{ round, chunk_metrics, verdict, timestamp }]
  let chunksToReview = chunks.slice(0, chunkCount)
  let allChunkTomes  = []  // Full set: updated on re-reviews, preserved otherwise
  let unifiedTome    = null

  // ── CONVERGENCE OUTER LOOP ────────────────────────────────────────────────
  // BACK-002 FIX: Use `round < maxRounds + 1` (exclusive upper bound).
  // Previously `round <= tier.maxRounds` ran maxRounds+1 iterations (0..maxRounds inclusive = maxRounds+1 passes).
  // For STANDARD (maxRounds=2): 0,1,2 = 3 passes = correct (initial + 2 re-reviews).
  // The bug was actually in the comment — the loop bound is correct for "total passes = maxRounds + 1".
  // The real fix is ensuring the loop terminates correctly with the convergence gate (break on converged/halted).
  // BACK-005 FIX: maxTotalPasses derived from tier.maxRounds (not undefined MAX_CONVERGENCE_ROUNDS)
  // STANDARD: maxRounds=2 → 3 total passes (initial + 2 re-reviews)
  const maxTotalPasses = convergenceEnabled ? tier.maxRounds + 1 : 1
  for (let round = 0; round < maxTotalPasses; round++) {
    const isReReview = round > 0
    log(`\n=== ${isReReview ? `Re-review round ${round}` : 'Initial review'} — ${chunksToReview.length} chunks ===`)

    // ── PER-CHUNK INNER LOOP ────────────────────────────────────────────────
    const roundTomes = []
    for (const chunk of chunksToReview) {
      const roundLabel = isReReview ? `-r${round}` : ''
      log(`\n--- Chunk ${chunk.chunkIndex + 1}/${chunkCount}${roundLabel}: ${chunk.files.length} files ---`)

      // On re-review: inject cross-chunk context to improve low-quality chunks
      const contextFiles = isReReview
        ? selectCrossChunkContext(chunk, chunks, unifiedTome)
        : []

      // BACK-008 FIX: Wrap per-chunk review in try/catch — partial failure should not abort all chunks
      try {
        // QUAL-014 FIX: Call reviewSingleChunk (renamed from runChunkReview)
        // BACK-011 FIX: Pass chunksToReview.length for dynamic timeout calculation
        // BACK-007 FIX: Pass arcRemainingMs (5th param) from runChunkedReview scope
        // instead of hardcoded null — enables dynamic per-chunk timeout in arc context
        const result = await reviewSingleChunk(chunk, identifier, flags, [
          ...securityPins,
          ...contextFiles,
        ], arcRemainingMs ?? null, chunksToReview.length)
        roundTomes.push(result)
      } catch (chunkError) {
        warn(`Chunk ${chunk.chunkIndex + 1} failed: ${chunkError.message}. Partial results preserved.`)
        writeChunkProgress(identifier, chunk.chunkIndex, 'failed')
        // BACK-008 FIX: Push sentinel result so mergeChunkTomes records a Coverage Gap
        // instead of silently omitting the chunk's files from the unified TOME
        roundTomes.push({
          chunkIndex: chunk.chunkIndex,
          tome: `<!-- RUNE:COVERAGE_GAP chunk="${chunk.chunkIndex + 1}" reason="chunk failed: ${chunkError.message}" files="${chunk.files.map(f => f.file ?? f).join(', ')}" -->`,
          path: null,
        })
        // Continue with remaining chunks — partial review is better than no review
      }
    }

    // ── CROSS-CHUNK TOME MERGE ────────────────────────────────────────────
    // On re-review: replace only re-reviewed chunk TOMEs; keep others from prior round
    if (isReReview) {
      allChunkTomes = replaceChunkTomes(allChunkTomes, roundTomes, chunksToReview)
    } else {
      allChunkTomes = roundTomes
    }

    unifiedTome = mergeChunkTomes(allChunkTomes, identifier)
    Write(`tmp/reviews/${identifier}/TOME.md`, unifiedTome)

    // ── CONVERGENCE GATE ──────────────────────────────────────────────────
    if (!convergenceEnabled) {
      convergenceHistory.push({ round, chunk_metrics: null, verdict: 'disabled', timestamp: now() })
      break
    }

    // BACK-001 FIX: Pass config to evaluateConvergence so talisman overrides reach computeChunkMetrics
    // BACK-004 FIX: Destructure `reason` from the verdict object — `chunkMetrics` is an array, not the verdict
    const { verdict, flaggedChunks, chunkMetrics, reason: haltReason } = evaluateConvergence(
      unifiedTome, chunksToReview, chunks, round, convergenceHistory, config
    )
    convergenceHistory.push({ round, chunk_metrics: chunkMetrics, verdict, timestamp: now() })

    if (verdict === 'converged') {
      log(`✓ Convergence achieved at round ${round}`)
      break
    } else if (verdict === 'halted') {
      // BACK-004 FIX: Use destructured `haltReason` from verdict, not `chunkMetrics.reason` (which is undefined)
      warn(`⚠ Convergence halted: ${haltReason ?? 'metrics not improving'}. Proceeding with current TOME.`)
      break
    } else if (verdict === 'retry') {
      log(`↻ Re-review needed: ${flaggedChunks.length} chunk(s) below quality threshold`)
      chunksToReview = flaggedChunks
    }
  }

  // ── OPTIONAL CROSS-CUTTING PASS ───────────────────────────────────────────
  if (shouldRunCrossCuttingPass(unifiedTome, chunks, config)) {
    runCrossCuttingPass(identifier, chunks, unifiedTome)
  }

  // ── CONVERGENCE REPORT ────────────────────────────────────────────────────
  const report = generateConvergenceReport(convergenceHistory, chunks, identifier, tier)
  Write(`tmp/reviews/${identifier}/convergence-report.md`, report)

  log(`\nChunked review complete. Unified TOME: tmp/reviews/${identifier}/TOME.md`)
  log(`Convergence report:      tmp/reviews/${identifier}/convergence-report.md`)
}
```

## Cross-Chunk TOME Merge

Finding IDs use **standard `{PREFIX}-{NUM}` format**. Chunk attribution is via `chunk="N"` attribute
in `<!-- RUNE:FINDING -->` HTML comment — NOT a `C{N}-PREFIX-NUM` prefix. This preserves dedup and
parsing compatibility with existing tooling.

```javascript
function mergeChunkTomes(chunkResults, identifier) {
  const allFindings = []

  for (const { chunkIndex, tome } of chunkResults) {
    const findings = parseRuneFindings(tome)
    for (const finding of findings) {
      // Standard ID preserved — chunk attributed via HTML comment attribute
      // e.g., <!-- RUNE:FINDING id="BACK-001" chunk="1" severity="P1" -->
      finding.chunk = chunkIndex + 1
      allFindings.push(finding)
    }
  }

  // Cross-chunk dedup: key on (file, line_range_bucket, category)
  // Category prevents false merge of SEC vs QUAL findings in 5-line window
  // Strip no prefix — IDs are standard, dedup keys on content not ID
  // BACK-010 FIX: Guard lineBucket against null/undefined line (file-level findings).
  // File-level findings have no line number → use 'file' sentinel instead of NaN bucket.
  const deduped = dedupFindings(allFindings, {
    windowLines: 5,
    keyFn: f => `${f.file}:${f.line != null ? lineBucket(f.line, 5) : 'file'}:${f.category}`,
  })

  const chunkSummary = chunkResults.map(({ chunkIndex, tome }) => ({
    chunk: chunkIndex + 1,
    findings: parseFindingCount(tome),
    files:    parseFileCount(tome),
  }))

  return formatTome(deduped, {
    header: [
      `# TOME — Review Summary (Chunked: ${chunkResults.length} chunks)`,
      ``,
      `**Chunks:** ${chunkResults.length}`,
      `**Total findings:** ${deduped.length} (from ${allFindings.length} pre-dedup)`,
    ].join('\n'),
    chunkSummary,
  })
}

// BACK-003 FIX: Preserve previous round's TOME when re-review produces no result for a chunk.
// Previously, if updatedByIndex[r.chunkIndex] was undefined (chunk failed), the entry became undefined
// in the returned array → downstream mergeChunkTomes would crash or silently drop findings.
function replaceChunkTomes(existing, updated, updatedChunks) {
  const updatedIndices = new Set(updatedChunks.map(c => c.chunkIndex))
  const updatedByIndex = Object.fromEntries(updated.map(r => [r.chunkIndex, r]))
  return existing.map(r => {
    if (!updatedIndices.has(r.chunkIndex)) return r  // Not re-reviewed — keep existing
    return updatedByIndex[r.chunkIndex] ?? r  // BACK-003: Fallback to existing if re-review failed
  })
}
```

## Chunk Progress Tracking

Chunk state is written to `tmp/reviews/{id}/chunk-{N}/.status` for `--resume` support.

```javascript
// Chunk state machine: pending → active → completed | partial | failed
// QUAL-007 FIX: Aligned status values with project convention (active/partial instead of in_progress/completed_partial)
function writeChunkProgress(identifier, chunkIndex, status, sessionNonce) {
  // 'partial' when chunk timed out but partial Ash outputs were collected (matches mend convention)
  Write(`tmp/reviews/${identifier}/chunk-${chunkIndex}/.status`, JSON.stringify({
    // SEC-005 FIX: Include session nonce to prevent stale status files from prior sessions
    // being trusted on --resume. Validate nonce before trusting status on resume.
    chunkIndex, status, timestamp: now(), session_nonce: sessionNonce ?? null,
  }))
}

// On --resume: read .status markers to skip completed chunks
// BACK-013 NOTE: Chunks with status 'partial' or 'failed' restart from scratch on --resume.
// Partial chunk TOMEs from the previous run are NOT merged — a fresh review provides
// better coverage than attempting to splice partial results.
function getCompletedChunks(identifier, chunkCount, sessionNonce) {
  return Array.from({ length: chunkCount }, (_, i) => i).filter(i => {
    try {
      const s = JSON.parse(Read(`tmp/reviews/${identifier}/chunk-${i}/.status`) ?? '{}')
      // SEC-005 FIX: Validate session nonce before trusting status — stale files from prior sessions are retried
      if (sessionNonce && s.session_nonce && s.session_nonce !== sessionNonce) return false
      return s.status === 'completed'  // Skip completed only; retry partial and failed
    } catch (_) { return false }
  })
}
```

## Cross-Cutting Pass (Optional)

Only runs when 3+ chunks span 3+ distinct top-level directories. Uses a single Explore agent (haiku,
read-only, 3-minute timeout). Skipped on timeout — does not block the review.

```javascript
function shouldRunCrossCuttingPass(unifiedTome, chunks, config) {
  if (config?.cross_cutting_pass === false) return false
  if (chunks.length < 3) return false
  // BACK-011 FIX: Use 2-level directory grouping instead of top-level only.
  // split('/')[0] returns 'plugins' for nearly all files in monorepo-style projects.
  // 2-level (e.g., 'plugins/rune') provides meaningful directory diversity signal.
  const topDirs = new Set(chunks.flatMap(c =>
    c.files.map(f => (f.file ?? f).split('/').slice(0, 2).join('/'))
  ))
  return topDirs.size >= 3
}
```

## Arc Integration — Dynamic Timeout

When invoked from arc Phase 6, chunk count and convergence tier constrain timeout:

```javascript
// arc.md Phase 6 — compute adjusted timeout before delegating to review.md
const maxChunksForBudget = Math.floor(arcRemainingMs / PHASE_TIMEOUTS.code_review)
const chunkCount         = Math.min(chunks.length, MAX_CHUNKS, maxChunksForBudget)
const perChunkTimeout    = Math.max(Math.floor(arcRemainingMs / chunkCount), 180_000)

// Arc checkpoint v5: add chunks tracking to code_review phase
updateCheckpoint({
  phase: 'code_review', status: 'in_progress', schema_version: 5,
  chunks: { total: chunkCount, completed: 0, tomes: [] },
})
```

## Communication Protocol

All agents spawned within chunked review follow this communication protocol:
- **Heartbeat**: Send "Starting: reviewing chunk {N}" via SendMessage after claiming task.
- **Seal**: On completion, TaskUpdate(completed) then SendMessage with Review Seal format (see team-sdk/references/seal-protocol.md).
- **Inner-flame**: Always include Inner-flame: {pass|fail|partial} in Seal.
- **Recipient**: Always use recipient: "team-lead".
- **Shutdown**: When you receive a shutdown_request, respond with shutdown_response({ approve: true }).

## References

- [Chunk Scoring](chunk-scoring.md) — `scoreFile`, `groupIntoChunks`, security pins
- [Convergence Gate](convergence-gate.md) — Tier selection, quality metrics, decision matrix
- [Dedup Runes](dedup-runes.md) — Cross-chunk dedup algorithm and finding ID format
- [Team SDK engines.md](../../team-sdk/references/engines.md) — teamTransition and pre-create guard (3-step escalation)
- [Monitor Utility](monitor-utility.md) — `waitForCompletion` parameters per command
- [Smart Selection](smart-selection.md) — Ash budgets and file classification
