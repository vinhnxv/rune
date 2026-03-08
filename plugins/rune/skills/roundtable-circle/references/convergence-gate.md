# Convergence Gate — Iterative Review Quality Control

> Evaluates review quality after each chunk merge round and decides whether re-review is needed.
> Used by the chunk orchestrator after every TOME merge. Generates a `convergence-report.md` always,
> even when convergence is disabled.
>
> **Disambiguation**: These tiers control **per-chunk re-review rounds** within a single review pass.
> They are distinct from the arc-level convergence tiers (LIGHT/STANDARD/THOROUGH) in
> [review-mend-convergence.md](review-mend-convergence.md), which control **review→mend cycle count**
> across the full arc pipeline. The `CHUNK_` prefix prevents confusion between the two systems.
>
> **Sharding bypass (v1.98.0+):** When `inscription.sharding.enabled === true`, chunked review
> is inactive (`inscription.chunked = false`). This convergence gate is bypassed entirely for
> sharded reviews. Arc-level convergence (LIGHT/STANDARD/THOROUGH in review-mend-convergence.md)
> continues to operate on the unified TOME scalar counts regardless of shard topology — it is
> fully shard-topology-agnostic. No changes to arc-level convergence are needed.

## 3-Tier Adaptive Convergence

Rather than a fixed round cap, the convergence budget scales with changeset risk and complexity.
The tier is selected **once** at the start (after Phase 1 scoring) and does not change mid-review.

| Tier | Max Re-reviews | Total Passes | Trigger Condition |
|------|---------------|-------------|-------------------|
| **CHUNK_MINIMAL** | 1 | 2 | All chunks doc-only OR total files <= 25 |
| **CHUNK_STANDARD** | 2 | 3 | Default — mixed code/docs, no high-risk files |
| **CHUNK_THOROUGH** | 3 | 4 | Any file `riskFactor >= 2.0` OR `avgComplexity > 2.0` OR total files > 40 |

**Calibration**: CHUNK_STANDARD (3 total passes) matches real-world usage where normal plans need ~3 review runs. CHUNK_THOROUGH adds 1 extra pass for auth/security/payment/migration changes. CHUNK_MINIMAL still gets 1 re-review — even docs-only changes benefit from a quality check.

**Time impact** (5 chunks, ~8 min/chunk avg):

| Tier | Best Case | Typical | Worst Case |
|------|-----------|---------|------------|
| CHUNK_MINIMAL | ~40 min | ~44 min | ~48 min |
| CHUNK_STANDARD | ~40 min | ~52 min | ~64 min |
| CHUNK_THOROUGH | ~40 min | ~60 min | ~80 min |

*Best case = all chunks converge on first pass. Worst case = all chunks re-reviewed every round.*

## `selectConvergenceTier(scoredFiles, chunks, config)`

**Inputs**:
- `scoredFiles` — `{ file, complexity, riskFactor, type }[]` — output of `scoreFile`
- `chunks` — `{ files, totalComplexity, chunkIndex }[]` — from `groupIntoChunks`
- `config` — talisman.yml `review` section (may be null). Caller passes `talisman?.review`.

**Outputs**: `{ name, maxRounds, reason }` — selected convergence tier

**Error handling**: Invalid `convergence_tier_override` values are ignored with a warning; falls back to auto-detect.

```javascript
const TIERS = {
  minimal:  { name: 'CHUNK_MINIMAL',  maxRounds: 1 },
  standard: { name: 'CHUNK_STANDARD', maxRounds: 2 },
  thorough: { name: 'CHUNK_THOROUGH', maxRounds: 3 },
}

function selectConvergenceTier(scoredFiles, chunks, config) {
  // User override via talisman.yml: convergence_tier_override: "thorough"
  // SEC-008 FIX: Type check before .toLowerCase() — non-string values (numbers, booleans) would throw
  const rawOverride = config?.convergence_tier_override
  const override = typeof rawOverride === 'string' ? rawOverride.toLowerCase() : undefined
  if (override && TIERS[override]) {
    return { ...TIERS[override], reason: `User override via talisman.yml: ${override}` }
  }
  if (override && !TIERS[override]) {
    warn(`Unknown convergence_tier_override "${override}" — falling back to auto-detect`)
  }

  // SEC-001 FIX: Guard against empty scoredFiles (division by zero → NaN → silent misclassification)
  if (scoredFiles.length === 0) {
    return { ...TIERS.minimal, reason: 'Empty changeset — no files to score' }
  }

  // Signal 1: Any high-risk file present (auth/security/payment/crypto)?
  const hasHighRiskFile = scoredFiles.some(f => f.riskFactor >= 2.0)

  // Signal 2: Aggregate complexity mean (safe — empty guard above prevents /0)
  const avg = scoredFiles.reduce((sum, f) => sum + f.complexity, 0) / scoredFiles.length

  // Signal 3: Are ALL chunks documentation-only?
  // isSourceCode: returns true for code extensions (.py, .ts, .js, .go, .rs, .rb, .java, .tsx, .jsx, .sql, .sh)
  // and false for doc/config extensions (.md, .txt, .yml, .yaml, .json, .toml, .ini)
  // Defined in smart-selection.md — referenced here for chunk type classification.
  const allDocOnly = chunks.every(chunk =>
    chunk.files.filter(f => isSourceCode(f.file ?? f)).length === 0
  )

  // Signal 4: Total file count
  const totalFiles = scoredFiles.length

  // Highest matching tier wins
  if (hasHighRiskFile || avg > 2.0 || totalFiles > 40) {
    return {
      ...TIERS.thorough,
      reason: hasHighRiskFile
        ? 'High-risk files detected (auth/security/payment/crypto/migration)'
        : avg > 2.0
          ? `High average complexity (${avg.toFixed(1)})`
          : `Large changeset (${totalFiles} files)`,
    }
  }

  if (allDocOnly || totalFiles <= 25) {
    return {
      ...TIERS.minimal,
      reason: allDocOnly
        ? 'All chunks are documentation-only'
        : `Small changeset (${totalFiles} files)`,
    }
  }

  return { ...TIERS.standard, reason: 'Mixed code/docs, no high-risk signals' }
}
```

## Quality Metrics (4 per chunk)

Each chunk is scored on 4 orthogonal dimensions after every TOME merge round.

| Metric | Formula | Code Threshold | Doc Threshold |
|--------|---------|---------------|---------------|
| **Finding Density** | `findings_in_chunk / files_in_chunk` | >= 0.3 | >= 0.1 |
| **Evidence Ratio** | `findings_with_rune_trace / total_findings` | >= 0.7 | >= 0.5 |
| **Confidence Mean** | `avg(finding.confidence)` | >= 0.6 | >= 0.5 |
| **Coverage Completeness** | `files_with_any_finding / files_in_chunk` | >= 0.4 | >= 0.2 |

**Chunk type**: Code if >50% of files are source code (per smart-selection.md extension mapping), otherwise doc.

**P1/P2 Findings as Quality Gate Trigger**:

In addition to metric thresholds, chunks with P1 or P2 findings are flagged for re-review when:
- `convergence.re_review_p1_p2: true` in talisman (default: false)
- The chunk has P1 or P2 findings that could potentially be resolved or improved by a second review pass
- This is useful for high-stakes reviews where critical findings warrant extra scrutiny

**Re-review trigger logic** (when `re_review_p1_p2` is enabled):
```
if (chunk.has_p1_p2_findings && !chunk.passed_previous_review) {
  flag_for_re_review = true
  reason = "P1/P2 findings present — re-review for validation"
}
```

**Edge cases**:
- Chunks with < 3 files auto-pass (too few files for meaningful density measurement)
- `Math.max(chunkFindings.length, 1)` prevents division by zero in Evidence Ratio

## `computeChunkMetrics(unifiedTome, chunk, config)`

**Inputs**:
- `unifiedTome` — string: merged TOME content after all chunk TOMEs combined
- `chunk` — `{ files, chunkIndex }[]`
- `config` — talisman.yml `review` section (may be null). Required for `passesThresholds` to apply talisman overrides.

**Outputs**: `{ chunkIndex, finding_density, evidence_ratio, confidence_mean, coverage_completeness, is_code_chunk, finding_count, file_count, pass }`

**Error handling**: Metric parse failure → treat chunk as failing (conservative); log warning.

```javascript
function computeChunkMetrics(unifiedTome, chunk, config) {
  // BACK-002 FIX: Explicit 0-file guard — degenerate chunks should warn, not silently pass
  if (chunk.files.length === 0) {
    warn('computeChunkMetrics: 0-file chunk detected — auto-pass with warning')
    return {
      chunkIndex: chunk.chunkIndex,
      finding_density: 0, evidence_ratio: 0,
      confidence_mean: 0, coverage_completeness: 0,
      is_code_chunk: false, finding_count: 0,
      file_count: 0, pass: true,
      note: 'auto-pass: 0 files (degenerate chunk)',
    }
  }

  // Auto-pass tiny chunks — not enough files for meaningful density measurement
  if (chunk.files.length < 3) {
    return {
      chunkIndex: chunk.chunkIndex,
      finding_density: 1.0, evidence_ratio: 1.0,
      confidence_mean: 1.0, coverage_completeness: 1.0,
      is_code_chunk: false, finding_count: 0,
      file_count: chunk.files.length, pass: true,
      note: 'auto-pass: < 3 files',
    }
  }

  // Filter TOME findings to those belonging to this chunk's files
  const chunkFileSet = new Set(chunk.files.map(f => f.file ?? f))
  const chunkFindings = parseRuneFindings(unifiedTome)
    .filter(f => chunkFileSet.has(f.file))

  const findingDensity       = chunkFindings.length / chunk.files.length
  const evidenceRatio        = chunkFindings.filter(f => f.hasRuneTrace).length /
                               Math.max(chunkFindings.length, 1)
  // BACK-009 FIX: Zero-finding chunks should not fail confidence threshold.
  // A chunk with 0 findings means it passed cleanly — default to 1.0, not 0.
  const confidenceMean       = chunkFindings.length > 0
    ? chunkFindings.reduce((sum, f) => sum + (f.confidence ?? 0.5), 0) / chunkFindings.length
    : 1.0
  const filesWithFindings    = new Set(chunkFindings.map(f => f.file)).size
  const coverageCompleteness = filesWithFindings / chunk.files.length

  const isCodeChunk = chunk.files.filter(f => isSourceCode(f.file ?? f)).length /
                      chunk.files.length > 0.5

  return {
    chunkIndex: chunk.chunkIndex,
    finding_density:       findingDensity,
    evidence_ratio:        evidenceRatio,
    confidence_mean:       confidenceMean,
    coverage_completeness: coverageCompleteness,
    is_code_chunk:         isCodeChunk,
    finding_count:         chunkFindings.length,
    file_count:            chunk.files.length,
    // BACK-007 FIX: Pass config to passesThresholds so talisman overrides take effect
    pass: passesThresholds(findingDensity, evidenceRatio, confidenceMean, coverageCompleteness, isCodeChunk, config),
  }
}

// BACK-007 FIX: Wire talisman config values to threshold checks.
// Without this, the convergence_*_threshold keys in talisman.yml are dead config.
// SEC-004 FIX: Validate numeric talisman config values within acceptable range
function clampNumeric(value, min, max, fallback) {
  if (typeof value !== 'number' || Number.isNaN(value)) return fallback
  return Math.max(min, Math.min(max, value))
}

function passesThresholds(density, evidence, confidence, coverage, isCode, config) {
  const t = isCode
    ? {
        // SEC-004 FIX: Validate config values are numbers in range [0.0, 1.0]
        density:    clampNumeric(config?.convergence_density_threshold,    0.0, 1.0, 0.3),
        evidence:   clampNumeric(config?.convergence_evidence_threshold,   0.0, 1.0, 0.7),
        confidence: clampNumeric(config?.convergence_confidence_threshold, 0.0, 1.0, 0.6),
        coverage:   clampNumeric(config?.convergence_coverage_threshold,   0.0, 1.0, 0.4),
      }
    // BACK-006 NOTE: Doc-chunk thresholds are intentionally hardcoded (not configurable via talisman).
    // Doc thresholds are stable — density/coverage expectations for docs are universally lower.
    // If customization is needed, add convergence_doc_*_threshold keys to talisman.example.yml.
    : { density: 0.1, evidence: 0.5, confidence: 0.5, coverage: 0.2 }
  return density >= t.density && evidence >= t.evidence &&
         confidence >= t.confidence && coverage >= t.coverage
}
```

## `evaluateConvergence(unifiedTome, reviewedChunks, allChunks, round, history, config)`

**Inputs**:
- `unifiedTome` — current merged TOME string
- `reviewedChunks` — chunks reviewed this round (all on round 0, only flagged on re-reviews)
- `allChunks` — complete chunk list (for returning flagged chunks by index)
- `round` — `number`: current round index (0 = initial)
- `history` — `{ round, chunk_metrics, verdict, timestamp }[]`
- `config` — talisman.yml `review` section (may be null). Passed through to `computeChunkMetrics`.

**Outputs**: `{ verdict: 'converged' | 'retry' | 'halted', flaggedChunks, chunkMetrics, reason? }`

**Error handling**: If metrics cannot be parsed for a chunk, it is treated as failing (conservative bias).

```javascript
function evaluateConvergence(unifiedTome, reviewedChunks, allChunks, round, history, config, tier) {
  // BACK-001 FIX: Pass config through to computeChunkMetrics so talisman threshold overrides take effect
  const chunkMetrics = reviewedChunks.map(chunk => computeChunkMetrics(unifiedTome, chunk, config))
  const failedChunks = chunkMetrics.filter(m => !m.pass)

  // DECREE-002 FIX: Circuit breaker — hard limit check FIRST before any other logic.
  // This ensures we halt when max rounds is reached regardless of metric state.
  // The tier is selected once at review start and passed through to this function.
  const maxRounds = tier?.maxRounds ?? 2  // Default: CHUNK_STANDARD
  if (round >= maxRounds) {
    return {
      verdict: 'halted', flaggedChunks: [], chunkMetrics,
      reason: `Circuit breaker: round ${round} >= maxRounds ${maxRounds}`,
    }
  }

  // CONVERGED: all chunks pass thresholds
  if (failedChunks.length === 0) {
    return { verdict: 'converged', flaggedChunks: [], chunkMetrics }
  }

  // BACK-006 FIX: Check global trend across ALL previous rounds (not just the last one).
  // Detects oscillation (e.g., 3 → 2 → 3) that single-round comparison misses.
  if (history.length > 0) {
    const prevMetrics = history[history.length - 1].chunk_metrics
    if (prevMetrics) {
      const prevFailCount = prevMetrics.filter(m => !m.pass).length
      // Immediate check: stagnant or worsening vs previous round
      if (failedChunks.length >= prevFailCount) {
        return {
          verdict: 'halted', flaggedChunks: [], chunkMetrics,
          reason: `Failed chunks not decreasing: ${prevFailCount} → ${failedChunks.length}`,
        }
      }
      // BACK-010 FIX: Enhanced oscillation detection — catches trend reversals (e.g., 3→1→2→1→2)
      // in addition to exact count matches from prior rounds.
      const historicalFailCounts = history
        .filter(h => h.chunk_metrics)
        .map(h => h.chunk_metrics.filter(m => !m.pass).length)
      if (historicalFailCounts.includes(failedChunks.length) && history.length >= 2) {
        return {
          verdict: 'halted', flaggedChunks: [], chunkMetrics,
          reason: `Oscillation detected: failure count ${failedChunks.length} seen in prior round`,
        }
      }
      // Trend reversal: failures increased after a previous improvement
      if (historicalFailCounts.length >= 2) {
        const lastTwo = historicalFailCounts.slice(-2)
        // Pattern: was improving (lastTwo[0] > lastTwo[1]) but now increasing again
        if (lastTwo[0] > lastTwo[1] && failedChunks.length > lastTwo[1]) {
          return {
            verdict: 'halted', flaggedChunks: [], chunkMetrics,
            reason: `Trend reversal: ${lastTwo[0]}→${lastTwo[1]}→${failedChunks.length} (improving then worsening)`,
          }
        }
      }
    }
  }

  // RETRY: metrics improving, rounds remaining — only re-review failed chunks
  const flaggedChunks = allChunks.filter(chunk =>
    failedChunks.some(m => m.chunkIndex === chunk.chunkIndex)
  )
  return { verdict: 'retry', flaggedChunks, chunkMetrics }
}
```

## Convergence Decision Flow

```
Round 0 (initial):
  Review ALL chunks → Merge → Evaluate
  → All pass?           → CONVERGED (done)
  → Some fail, < max?   → RETRY (flag failed chunks for re-review)
  → [diverge impossible: no previous round to compare against]

Round 1+ (re-reviews):
  Review FLAGGED chunks only → Merge (replace flagged TOMEs) → Evaluate
  → All pass?                    → CONVERGED
  → Fewer failures than before?  → RETRY (if rounds remain)
  → Same or more failures?       → HALTED (diverging — stop)

Circuit breaker:
  round >= tier.maxRounds → HALTED regardless of metric state
```

### Convergence States

| State | Meaning | Next Action |
|-------|---------|-------------|
| **CONVERGED** | All chunks pass quality thresholds | Review complete, proceed to TOME finalization |
| **RETRY** | Some chunks failed but improvement detected | Re-review ONLY flagged chunks |
| **HALTED** | Quality not improving (stagnation/oscillation) | Stop loop, proceed with current TOME |

### Disabling Convergence

The `--no-converge` flag disables the convergence loop entirely — single review pass per chunk with no re-reviews. This is useful when:
- Quick turnaround is needed and quality gates can be skipped
- Changeset is well-understood and re-review adds minimal value
- CI/CD pipeline has time constraints

### Reduced Timeout Per Pass

Each re-review pass gets **50% of the initial timeout** (configurable via `convergence.timeout_reduction_factor`). For example, if the initial timeout is 600 seconds:
- Round 0: 600s
- Round 1: 300s (50% reduction)
- Round 2: 150s (50% reduction from Round 1)

This prevents convergence from indefinitely extending review time. The `MAX_CONVERGENCE_CYCLES` (derived from tier, equivalent to `tier.maxRounds`) also prevents infinite loops.

**Variable Alias**:
- `MAX_CONVERGENCE_CYCLES` = `tier.maxRounds` (both names refer to the same value)
- CHUNK_MINIMAL: `MAX_CONVERGENCE_CYCLES = 1`
- CHUNK_STANDARD: `MAX_CONVERGENCE_CYCLES = 2`
- CHUNK_THOROUGH: `MAX_CONVERGENCE_CYCLES = 3`

```javascript
// Both are valid:
const maxRounds = tier.maxRounds           // From tier selection
const maxCycles = MAX_CONVERGENCE_CYCLES   // Alias for clarity
// maxRounds === maxCycles (same value, different naming)
```

## `selectCrossChunkContext(flaggedChunk, allChunks, currentTome)`

On re-review, flagged chunks receive read-only context from related chunks to improve coverage.

**Inputs**:
- `flaggedChunk` — chunk being re-reviewed
- `allChunks` — all chunks (for cross-reference lookup)
- `currentTome` — merged TOME from previous round

**Outputs**: `string[]` — up to 5 additional file paths (read-only context)

**Error handling**: Import parsing failure → skip that file silently. Max 5 files hard cap prevents budget overflow.

```javascript
function selectCrossChunkContext(flaggedChunk, allChunks, currentTome) {
  const contextFiles = new Set()
  const flaggedFileSet = new Set(flaggedChunk.files.map(f => f.file ?? f))
  const allOtherFiles  = allChunks
    .filter(c => c.chunkIndex !== flaggedChunk.chunkIndex)
    .flatMap(c => c.files.map(f => f.file ?? f))

  // 1. Files imported by flagged chunk files that live in OTHER chunks
  // SEC-007 FIX: Validate import-resolved paths against SAFE_PATH_PATTERN to prevent
  // path traversal via crafted import statements (e.g., import from '../../etc/passwd')
  const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
  for (const file of flaggedChunk.files) {
    try {
      const imports = extractImports(file.file ?? file)
      for (const imp of imports) {
        if (!SAFE_PATH_PATTERN.test(imp) || imp.includes('..')) continue  // SEC-007: reject unsafe paths
        if (!flaggedFileSet.has(imp) && allOtherFiles.includes(imp)) {
          contextFiles.add(imp)
        }
      }
    } catch (_) {
      // Import parsing is best-effort — skip on error
    }
  }

  // 2. Files referenced cross-chunk in the current TOME (findings that span chunks)
  const crossRefs = parseCrossChunkReferences(currentTome, flaggedChunk.chunkIndex)
  for (const ref of crossRefs) contextFiles.add(ref)

  // Cap at 5 — prevents Ash budget overflow during re-review
  return [...contextFiles].slice(0, 5)
}
```

## Convergence Report Format

Always written to `tmp/reviews/{id}/convergence-report.md` after the convergence loop completes.
Generated deterministically (no LLM) — adds < 2 seconds.

```markdown
# Convergence Report — Review {identifier}

**Date:** {timestamp}
**Convergence Tier:** {CHUNK_MINIMAL | CHUNK_STANDARD | CHUNK_THOROUGH} (reason: {tier_reason})
**Total Rounds:** {N} (initial + {N-1} re-reviews, max allowed: {tier.maxRounds})
**Final Verdict:** {CONVERGED | HALTED | DISABLED}
**Total Findings:** {N} (after dedup)
**Total Review Time:** {mm:ss}

## Round Summary

| Round | Chunks Reviewed | Findings | Failed Chunks | Verdict | Duration |
|-------|----------------|----------|---------------|---------|----------|
| 0 (initial) | 3/3 | 24 | 1 | retry | 8m 32s |
| 1 (re-review) | 1/3 | 28 (+4) | 0 | converged | 3m 15s |

## Per-Chunk Quality Scorecard

### Chunk 1: plugins/rune/commands/ (8 files)

| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|
| Finding Density | 0.625 | >= 0.3 | PASS |
| Evidence Ratio | 0.80 | >= 0.7 | PASS |
| Confidence Mean | 0.72 | >= 0.6 | PASS |
| Coverage Completeness | 0.50 | >= 0.4 | PASS |

**Round 0:** PASS (no re-review needed)

### Chunk 2: plugins/rune/skills/ (10 files)

| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|
| Finding Density | 0.20 | >= 0.3 | **FAIL** |
| Evidence Ratio | 0.85 | >= 0.7 | PASS |
| Confidence Mean | 0.65 | >= 0.6 | PASS |
| Coverage Completeness | 0.20 | >= 0.4 | **FAIL** |

**Round 0:** FAIL → flagged for re-review
**Round 1:** Finding Density 0.40, Coverage 0.50 → PASS

## Convergence Trend

{round} | {total_findings} | {failed_chunks}
  0     |       24         |       1
  1     |       28         |       0          ← converged

Trend: IMPROVING (findings +4, failed chunks 1 → 0)

## Recommendations

- Chunk 2 required re-review: Initial pass had low finding density (0.20) and poor
  coverage (0.20). After re-review with cross-chunk context injection (3 imported files
  from Chunk 1), density improved to 0.40 and 3 new findings were discovered.
- Cross-chunk context was effective: 2 of 4 new findings referenced imports from
  other chunks, confirming that context injection improves review quality.

## Configuration Used

| Key | Value |
|-----|-------|
| convergence_enabled | true |
| convergence_tier | CHUNK_STANDARD (auto-detected) |
| max_convergence_rounds (derived) | 2 |
| density_threshold (code) | 0.3 |
| evidence_threshold (code) | 0.7 |
| confidence_threshold (code) | 0.6 |
| coverage_threshold (code) | 0.4 |
```

## Talisman Config Keys

All keys live under `review:` in `.claude/talisman.yml` (QUAL-001 FIX: standardized from `rune-gaze:`):

```yaml
review:
  convergence_enabled: true            # Enable convergence loop (default: true)
  convergence_tier_override: null      # Force tier: "minimal" | "standard" | "thorough" | null
  # max_convergence_rounds is DERIVED from tier — do not set directly
  convergence_density_threshold: 0.3   # Min findings/file for code chunks
  convergence_evidence_threshold: 0.7  # Min evidence-traced findings ratio
  convergence_confidence_threshold: 0.6 # Min avg confidence score
  convergence_coverage_threshold: 0.4  # Min files-with-findings ratio (code chunks)
```

## References

- [Chunk Scoring](chunk-scoring.md) — `scoreFile`, `groupIntoChunks`, security pins
- [Chunk Orchestrator](chunk-orchestrator.md) — How the convergence loop is called
- [Dedup Runes](dedup-runes.md) — Cross-chunk dedup algorithm
- [Verify Mend](../../arc/references/verify-mend.md) — Model for iterative convergence loops
