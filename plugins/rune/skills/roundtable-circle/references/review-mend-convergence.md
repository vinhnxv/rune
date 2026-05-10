# Review-Mend Convergence — Shared Reference

Shared tier selection, convergence evaluation, and progressive focus logic for both arc (Phase 6-7.5 loop) and standalone `/rune:appraise --cycles N`.

> **Disambiguation**: These tiers (LIGHT/STANDARD/THOROUGH) control **review→mend cycle count**
> across the arc pipeline. They are distinct from the per-chunk convergence tiers
> (CHUNK_MINIMAL/CHUNK_STANDARD/CHUNK_THOROUGH) in [convergence-gate.md](convergence-gate.md),
> which control **re-review rounds within a single review pass**.

## 3-Tier Adaptive Convergence

The number of review-mend cycles scales with changeset complexity.

| Tier | Max Cycles | Min Cycles | Trigger |
|------|-----------|-----------|---------|
| **LIGHT** | 2 | 1 | ≤100 lines changed AND no high-risk files AND type=fix |
| **STANDARD** | 3 | 2 | 100-2000 lines OR mixed code/docs (default) |
| **THOROUGH** | 5 | 2 | >2000 lines OR high-risk files OR architectural changes |

## Tier Selection Engine

**Inputs**: `git diff --stat`, plan frontmatter (optional), talisman config
**Outputs**: `{ tier, maxCycles, reason }` — selected convergence tier
**Error handling**: Missing git stats → default STANDARD; invalid talisman config → ignore with warning

```javascript
// Security-critical path patterns (reuse from chunk-scoring.md)
// Security pattern: HIGH_RISK_PATTERNS — see security-patterns.md
const HIGH_RISK_PATTERNS = [
  '**/auth/**', '**/middleware/auth*', '**/security/**',
  '**/validators/**', '**/*permission*', '**/crypto/**',
  '**/payment/**', '**/migrate/**', '**/migration*',
]

const TIERS = {
  light:    { name: 'LIGHT',    maxCycles: 2, minCycles: 1 },
  standard: { name: 'STANDARD', maxCycles: 3, minCycles: 2 },
  thorough: { name: 'THOROUGH', maxCycles: 5, minCycles: 2 },
}

// SEC-007 helper: compute auto-tier without config override (for warning comparison)
function computeAutoTier(diffStats, planMeta) {
  const totalLines = diffStats.insertions + diffStats.deletions
  const hasHighRisk = diffStats.files.some(f => matchesAnyPattern(f, HIGH_RISK_PATTERNS))
  const planType = planMeta?.type
  const fileCount = diffStats.files.length
  if (totalLines > 2000 || hasHighRisk || (planType === 'feat' && fileCount > 20)) return 'thorough'
  if (totalLines <= 100 && !hasHighRisk && planType === 'fix') return 'light'
  return 'standard'
}

function selectReviewMendTier(diffStats, planMeta, config) {
  // User override via talisman.yml (arc-specific namespace per decree-arbiter P1)
  // NOTE: Uses arc_convergence_tier_override (not convergence_tier_override)
  // to avoid collision with chunked review's convergence_tier_override key.
  const override = config?.review?.arc_convergence_tier_override
  // SEC-004 FIX: Type-check override before TIERS lookup — reject non-string values (arrays, objects)
  if (typeof override === 'string' && TIERS[override]) {
    // SEC-007: Compute auto-tier for comparison — warn if override disagrees
    const autoTier = computeAutoTier(diffStats, planMeta)
    if (autoTier && autoTier !== override) {
      warn(`Tier override "${override}" disagrees with auto-detected "${autoTier}" — using override. This may increase compute time.`)
    }
    return { ...TIERS[override], reason: `User override: ${override} (auto-detected: ${autoTier ?? 'unknown'})` }
  }

  // Signal 1: Total lines changed (primary signal)
  const totalLines = diffStats.insertions + diffStats.deletions

  // Signal 2: High-risk files present?
  const hasHighRisk = diffStats.files.some(f => matchesAnyPattern(f, HIGH_RISK_PATTERNS))

  // Signal 3: Plan type (from frontmatter, if available)
  // NOTE: planMeta is null for standalone review (no plan context).
  // In standalone mode, only Signal 1, 2, and 4 are used.
  const planType = planMeta?.type  // 'feat', 'fix', 'refactor'

  // Signal 4: File count (secondary)
  const fileCount = diffStats.files.length

  // Tier selection — highest matching wins
  if (totalLines > 2000 || hasHighRisk || (planType === 'feat' && fileCount > 20)) {
    return { ...TIERS.thorough,
      reason: totalLines > 2000 ? `Large changeset (${totalLines} lines)`
        : hasHighRisk ? 'High-risk files detected'
        : `Large feature (${fileCount} files)` }
  }

  if (totalLines <= 100 && !hasHighRisk && planType === 'fix') {
    return { ...TIERS.light,
      reason: `Small fix (${totalLines} lines, no high-risk files)` }
  }

  return { ...TIERS.standard,
    reason: `Default (${totalLines} lines, ${fileCount} files)` }
}
```

## Convergence Evaluation

Used by Phase 7.5 to decide: converge, retry, or halt.

**Inputs**: Current TOME finding counts, convergence history, tier config
**Outputs**: Verdict (`converged` | `retry` | `halted`)

```javascript
function evaluateConvergence(currentFindingCount, p1Count, p2Count, checkpoint, config, scopeStats) {
  const round = checkpoint.convergence.round
  const tier = checkpoint.convergence.tier ?? TIERS.standard
  // SEC-005: Apply arc_convergence_max_cycles override with clamping (1-5)
  const rawMaxCycles = config?.review?.arc_convergence_max_cycles
  // SEC-002 FIX: Use Number.isNaN instead of || to avoid falsy-zero bug (parseInt("1") || 3 = 1, but parseInt("0") || 3 = 3)
  // SEC-005 FIX: Type guard — reject arrays/objects from YAML (parseInt([3], 10) returns 3 silently)
  const parsedMaxCycles = (rawMaxCycles != null && (typeof rawMaxCycles === 'number' || typeof rawMaxCycles === 'string'))
    ? parseInt(String(rawMaxCycles), 10) : NaN
  const maxCycles = !Number.isNaN(parsedMaxCycles)
    ? Math.max(1, Math.min(5, parsedMaxCycles))
    // BACK-001 NOTE: checkpoint.convergence.max_rounds is a legacy field — not read by evaluateConvergence.
    // The canonical source is tier.maxCycles (from checkpoint.convergence.tier). max_rounds remains
    // in checkpoint schema for backward compatibility but is effectively dead data.
    : tier.maxCycles ?? TIERS.standard.maxCycles
  // SEC-003 FIX: Add upper bound (100) to prevent threshold=9999 from bypassing convergence
  // QUAL-005 FIX: Match rawMaxCycles pattern — separate extraction from parsing, type-guard before parseInt
  const rawThresholdVal = config?.review?.arc_convergence_finding_threshold
  const rawThreshold = (rawThresholdVal != null && (typeof rawThresholdVal === 'number' || typeof rawThresholdVal === 'string'))
    ? parseInt(String(rawThresholdVal), 10) : NaN
  const findingThreshold = !Number.isNaN(rawThreshold) ? Math.max(0, Math.min(100, rawThreshold)) : 0
  // Validate ratio: reject values outside (0.1, 0.9)
  const rawRatio = parseFloat(config?.review?.arc_convergence_improvement_ratio ?? 0.5)
  const improvementRatio = Number.isNaN(rawRatio) ? 0.5 : Math.max(0.1, Math.min(0.9, rawRatio))

  // BACK-017 FIX: minCycles from tier (with talisman override)
  // SEC-005 type guard: reject arrays/objects from YAML (parseInt([3],10) returns 3 silently)
  const rawMinVal = config?.review?.arc_convergence_min_cycles
  const parsedMinCycles = (rawMinVal != null && (typeof rawMinVal === 'number' || typeof rawMinVal === 'string'))
    ? parseInt(String(rawMinVal), 10) : NaN
  const effectiveMinCycles = !Number.isNaN(parsedMinCycles) ? parsedMinCycles : (tier.minCycles ?? 2)
  const minCycles = Math.max(1, Math.min(maxCycles, effectiveMinCycles))
  if (!Number.isNaN(parsedMinCycles) && parsedMinCycles > maxCycles) {
    warn(`arc_convergence_min_cycles (${parsedMinCycles}) exceeds max_cycles (${maxCycles}) — clamped to ${maxCycles}`)
  }
  // BACK-002 FIX: Warn when minCycles equals maxCycles — retry window collapses to zero
  if (minCycles === maxCycles) {
    warn(`arc_convergence_min_cycles (${minCycles}) equals max_cycles (${maxCycles}) — only 1 cycle available for convergence check`)
  }

  // BACK-019 FIX: P2 threshold (with talisman override)
  // SEC-005 type guard applied (same pattern as maxCycles/findingThreshold)
  // BACK-007 NOTE: Default p2Threshold=0 means ANY P2 finding blocks convergence at step 2.
  // If diff-scope is disabled (smart scoring unavailable), this forces all maxCycles iterations
  // before circuit-breaker halts. Users with pre-existing P2 findings should either:
  // (a) enable diff-scope (default), or (b) set arc_convergence_p2_threshold > 0.
  const rawP2Val = config?.review?.arc_convergence_p2_threshold
  const parsedP2Threshold = (rawP2Val != null && (typeof rawP2Val === 'number' || typeof rawP2Val === 'string'))
    ? parseInt(String(rawP2Val), 10) : NaN
  const p2Threshold = !Number.isNaN(parsedP2Threshold)
    ? Math.max(0, Math.min(100, parsedP2Threshold)) : 0

  // Guard: ensure p2Count is a finite number (defense-in-depth for undefined/NaN)
  const safeP2Count = Number.isFinite(p2Count) ? p2Count : 0

  // Get previous round's finding count
  // BACK-002 NOTE: Invariant: round === history.length throughout the convergence lifecycle.
  // Oscillation detection uses history.length; evaluation uses round. They MUST stay in sync.
  const prevFindings = round === 0 ? Infinity
    : checkpoint.convergence.history[round - 1]?.findings_after ?? Infinity

  // BACK-002 invariant assertion (defense-in-depth)
  if (round !== checkpoint.convergence.history.length) {
    warn(`Invariant violation: round (${round}) !== history.length (${checkpoint.convergence.history.length})`)
  }

  // === REORDERED DECISION CASCADE ===
  // Forge finding (flaw-hunter): circuit breaker must be AFTER convergence checks
  // to allow convergence at the final eligible cycle. Otherwise STANDARD tier
  // round 2 (round+1=3 >= maxCycles=3) halts even when all findings are resolved.

  // 0. BACK-005 FIX: Zero-findings short-circuit — skip minCycles gate when no findings remain.
  // Without this, a clean TOME (0 findings) still forces a retry when minCycles > 1,
  // wasting a full review-mend cycle that immediately converges at step 2 (0 ≤ 0).
  if (currentFindingCount === 0) {
    return 'converged'  // No findings remain — converged regardless of minCycles
  }

  // 1. BACK-017 FIX: Minimum cycles gate — force re-review before convergence
  if (round + 1 < minCycles) {
    return 'retry'      // Haven't reached minimum cycles — force re-review
  }

  // 2. BACK-019 FIX: P1 AND P2 thresholds — both must pass
  if (p1Count <= findingThreshold && safeP2Count <= p2Threshold) {
    return 'converged'  // Both P1 and P2 below acceptable thresholds
  }

  // 3. Smart convergence scoring (now only fires after minCycles met)
  // scopeStats is optional — null/undefined for pre-v1.38.0 TOMEs or disabled diff-scope.
  if (scopeStats && config?.review?.diff_scope?.enabled !== false) {
    const smartScoringEnabled = config?.review?.convergence?.smart_scoring !== false  // Default: true
    if (smartScoringEnabled) {
      const score = computeConvergenceScore(scopeStats, checkpoint, config)
      const convergenceThreshold = parseFloat(config?.review?.convergence?.convergence_threshold ?? 0.7)
      const safeThreshold = Number.isNaN(convergenceThreshold) ? 0.7 : Math.max(0.1, Math.min(1.0, convergenceThreshold))
      if (score.total >= safeThreshold) {
        return 'converged'  // Smart scoring: remaining findings are mostly P3/pre-existing noise
      }
    }
  }

  // 4. BACK-018 FIX: Circuit breaker — hard limit (moved from position 1 to position 4)
  // Fires AFTER convergence checks so the final eligible cycle can still converge.
  if (round + 1 >= maxCycles) {
    return 'halted'     // Max cycles reached — findings still unresolved
  }

  // 5. Stagnation — findings not decreasing AND P1 not improving (unchanged)
  // BACK-016 FIX: Check P1 progress alongside total count — severity shift (P1→P3) is meaningful
  // even when total count unchanged. prevP1 defaults to Infinity for round 0 (same as prevFindings).
  const prevP1 = round === 0 ? Infinity
    : checkpoint.convergence.history[round - 1]?.p1_remaining ?? Infinity
  if (currentFindingCount >= prevFindings && p1Count >= prevP1) {
    return 'halted'     // Findings not decreasing AND P1 not improving — truly stagnant
  }

  // 6. Oscillation detection (unchanged)
  // BACK-005 FIX: Compare only against round N-2 (A→B→A pattern).
  if (checkpoint.convergence.history.length >= 2) {
    const twoRoundsBack = checkpoint.convergence.history[checkpoint.convergence.history.length - 2]
    if (twoRoundsBack && twoRoundsBack.findings_after === currentFindingCount) {
      return 'halted'   // Oscillation detected (A→B→A pattern)
    }
  }

  // 7. Improvement ratio check (unchanged, guard prevFindings > 0 for NaN safety)
  if (currentFindingCount > 0 && prevFindings > 0 &&
      currentFindingCount / prevFindings > (1 - improvementRatio)) {
    return 'halted'     // Improvement too small — diminishing returns
  }

  return 'retry'        // Findings decreasing meaningfully — another cycle
}
```

## Smart Convergence Scoring (v1.38.0+)

Computes a composite convergence score from scope-aware signals. Used by `evaluateConvergence()` to detect early convergence when remaining findings are mostly noise (P3 severity or pre-existing code).

**Inputs**: `scopeStats` (from TOME parsing), `checkpoint`, `config`
**Outputs**: `{ total, components, reason }` — score between 0.0 and 1.0
**Error handling**: Missing/null scopeStats → returns null (caller must guard). P1 > 0 → returns 0.0 (hard gate).

```javascript
function computeConvergenceScore(scopeStats, checkpoint, config) {
  // BACK-006 FIX: Return zero-score object instead of null for invalid input.
  // Prevents null.total TypeError in callers that forget truthiness guard.
  if (!scopeStats || typeof scopeStats !== 'object') {
    return { total: 0.0, components: { p3: 0, preExisting: 0, trend: 0, base: 0 }, reason: 'invalid_input' }
  }

  const { p1Count, p2Count, p3Count, preExistingCount, inDiffCount, totalFindings } = scopeStats

  // BACK-019 FIX: Parse P2 threshold from config (same logic as evaluateConvergence)
  const rawP2Val = config?.review?.arc_convergence_p2_threshold
  const parsedP2Threshold = (rawP2Val != null && (typeof rawP2Val === 'number' || typeof rawP2Val === 'string'))
    ? parseInt(String(rawP2Val), 10) : NaN
  const p2Threshold = !Number.isNaN(parsedP2Threshold)
    ? Math.max(0, Math.min(100, parsedP2Threshold)) : 0

  // Guard: ensure p2Count is finite (defense-in-depth — matches evaluateConvergence pattern)
  const safeP2Count = Number.isFinite(p2Count) ? p2Count : 0

  // Hard gate: P1 findings prevent smart convergence — always retry or fix
  if (p1Count > 0) {
    return { total: 0.0, components: { p3: 0, preExisting: 0, trend: 0, base: 0 }, reason: 'p1_active' }
  }

  // BACK-019 FIX: P2 hard gate — if P2 above threshold, smart scoring returns low score
  if (safeP2Count > p2Threshold) {
    return { total: 0.0, components: { p3: 0, preExisting: 0, trend: 0, base: 0 }, reason: `P2 count (${safeP2Count}) exceeds threshold (${p2Threshold})` }
  }

  // Guard: no findings = fully converged
  if (totalFindings === 0) {
    return { total: 1.0, components: { p3: 0, preExisting: 0, trend: 0, base: 1.0 }, reason: 'zero_findings' }
  }

  // Edge case: zero in-diff findings — all findings are pre-existing
  // If nothing in the PR diff remains, this is ideal convergence
  if (inDiffCount === 0 && totalFindings > 0) {
    return { total: 1.0, components: { p3: 0, preExisting: 1.0, trend: 0, base: 1.0 }, reason: 'zero_in_diff' }
  }

  // Component 1: P3 dominance ratio (weight: 0.4)
  // High P3 ratio means remaining findings are low-severity polish items
  const p3Ratio = totalFindings > 0 ? p3Count / totalFindings : 0

  // Component 2: Pre-existing noise ratio (weight: 0.3)
  // High pre-existing ratio means findings aren't caused by this PR
  const preExistingRatio = totalFindings > 0 ? preExistingCount / totalFindings : 0

  // Component 3: Trend — findings decreasing from previous round? (weight: 0.2)
  const round = checkpoint.convergence?.round ?? 0
  const prevFindings = round === 0 ? Infinity
    : checkpoint.convergence.history[round - 1]?.findings_after ?? Infinity
  const trendDecreasing = (totalFindings < prevFindings) ? 1.0 : 0.0

  // Component 4: Base (weight: 0.1) — always contributes minimum score
  const base = 1.0

  // BACK-007: CANONICAL SOURCE for convergence weights (v3.x: hardcoded values).
  // Sum must equal 1.0: 0.4 + 0.3 + 0.2 + 0.1 = 1.0
  const total = 0.4 * p3Ratio + 0.3 * preExistingRatio + 0.2 * trendDecreasing + 0.1 * base

  return {
    total: Math.round(total * 100) / 100,  // Round to 2 decimal places
    components: {
      p3: Math.round(p3Ratio * 100) / 100,
      preExisting: Math.round(preExistingRatio * 100) / 100,
      trend: trendDecreasing,
      base
    },
    reason: null
  }
}
```

### Score Interpretation

| Score Range | Verdict Effect | Meaning |
|-------------|---------------|---------|
| >= 0.7 | `converged` | Remaining findings are mostly P3/pre-existing noise — safe to stop |
| 0.5 - 0.7 | No effect (existing logic decides) | Mixed signals — let improvement ratio and cycle limits decide |
| < 0.5 | No effect (existing logic decides) | Active findings remain — existing halting conditions apply |
| 0.0 | Always | P1 findings present — never converge via smart scoring |

### Talisman Config Keys (smart convergence)

Under `review:` section. Requires `diff_scope.enabled: true` (default) for scope stats to be available.

```yaml
review:
  convergence:
    smart_scoring: true              # Enable smart convergence scoring (default: true)
    convergence_threshold: 0.7       # Score >= this = converged (default: 0.7, range: 0.1-1.0)
    # p3_dominance_threshold: 0.7    # RESERVED — no effect in v1.38.0. Planned for future per-component thresholds.
    # noise_threshold: 0.5           # RESERVED — no effect in v1.38.0. Planned for future per-component thresholds.
```

## Progressive Review Focus

For re-review rounds (pass 2+), narrow scope to mend-modified files + 1-hop dependencies.

**Inputs**: Mend-modified files, resolution report, full file list
**Outputs**: Focused file list capped at mend-modified + 10 dependencies
**Error handling**: Dependency extraction failure → fall back to mend-modified files only

```javascript
function buildProgressiveFocus(resolutionReport, originalChangedFiles) {
  const mendModifiedFiles = extractFixedFiles(resolutionReport)
  // EC-7: Include files with unfixed P1/P2 findings
  const unfixedFiles = extractUnfixedFiles(resolutionReport, ['P1', 'P2'])
  const allFocusFiles = [...new Set([...mendModifiedFiles, ...unfixedFiles])]

  let dependencies = []
  try {
    dependencies = collectOneHopDependencies(allFocusFiles, 10)  // max 10
  } catch (e) {
    warn(`Dependency collection failed: ${e.message} — using mend-modified files only`)
  }

  const focusScope = [...new Set([...allFocusFiles, ...dependencies])]

  // EC-9: Guard against empty focusScope
  if (focusScope.length === 0) {
    if (mendModifiedFiles.length > 0) {
      // Paradox: fixed files exist but none in scope — fall back to full changed_files
      warn(`focusScope empty despite ${mendModifiedFiles.length} fixed files — using full scope`)
      return { focus_files: originalChangedFiles, mend_modified: mendModifiedFiles, unfixed_files: unfixedFiles, dependency_files: [] }
    }
    return null  // Signal: no files modified, halt convergence
  }

  return {
    focus_files: focusScope,
    mend_modified: mendModifiedFiles,
    unfixed_files: unfixedFiles,
    dependency_files: dependencies,
  }
}
```

### 1-Hop Dependency Collection

```javascript
function collectOneHopDependencies(modifiedFiles, maxDeps) {
  if (!modifiedFiles || modifiedFiles.length === 0) return []  // Guard: empty input → empty Grep match
  const deps = new Set()
  for (const file of modifiedFiles) {
    // Extract imports from the modified file (reuse from chunk-orchestrator.md)
    const imports = extractImports(file)
    for (const imp of imports) {
      if (!modifiedFiles.includes(imp)) deps.add(imp)
    }
    // Find files that import the modified file (reverse dependencies)
    // SEC: Escape basename for regex safety (dots, brackets, etc.)
    const escapedBasename = basename(file).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const importers = Grep(`import.*${escapedBasename}|require.*${escapedBasename}`, { type: ext(file) })
    for (const importer of importers) {
      if (!modifiedFiles.includes(importer)) deps.add(importer)
    }
  }
  return [...deps].slice(0, maxDeps)
}
```

## Talisman Config Keys (arc-specific)

Under `review:` section in talisman.yml. Uses `arc_` prefix to avoid collision with existing chunked review convergence keys.

```yaml
review:
  # Arc review-mend convergence (v1.37.0+)
  # NOTE: These keys use 'arc_' prefix to distinguish from chunked review
  # convergence keys (convergence_tier_override, convergence_density_threshold, etc.)
  arc_convergence_tier_override: null     # Force: "light" | "standard" | "thorough" | null
  arc_convergence_max_cycles: null        # Hard override: 1-5 (overrides tier, use sparingly)
  arc_convergence_min_cycles: null        # Min re-review cycles before convergence (1-maxCycles, default: tier-based)
  arc_convergence_finding_threshold: 0    # P1 findings below this count = converged (default: 0)
  arc_convergence_p2_threshold: 0         # P2 findings below this count = eligible for convergence (default: 0)
  arc_convergence_improvement_ratio: 0.5  # Findings must decrease by this ratio to continue (default: 0.5)
```

**Validation**:
- `arc_convergence_max_cycles`: Clamped to 1-5 range. Values outside are silently clamped.
- `arc_convergence_min_cycles`: Clamped to 1-maxCycles range. Warning emitted if exceeds maxCycles. Default: tier-based (LIGHT=1, STANDARD=2, THOROUGH=2).
- `arc_convergence_finding_threshold`: Clamped to 0-100 range. P1-specific threshold.
- `arc_convergence_p2_threshold`: Clamped to 0-100 range. Default 0 (any P2 blocks convergence). Raise to allow some P2 findings without forcing additional cycles.
- `arc_convergence_improvement_ratio`: Clamped to 0.1-0.9 range. NaN → 0.5 default.
- `arc_convergence_tier_override`: Must be a key of `TIERS` or null. Invalid values ignored with warning.

## Scope Limitation Note

**SCOPE-BIAS** (P3 — partially mitigated in v1.38.0): `findings_before` comparison is biased by scope reduction (full → focused review). Pass 1 reviews all changed files; pass 2+ reviews only mend-modified files + dependencies. A decrease in findings may reflect narrower scope rather than code improvement.

**v1.38.0 mitigation**: Smart convergence scoring (`computeConvergenceScore()`) partially addresses this by evaluating finding COMPOSITION (P3 ratio, pre-existing ratio) rather than raw count. A focused review with 5 P3 pre-existing findings scores higher than 5 P1 in-diff findings, correctly identifying the former as noise. However, the raw `findings_before` vs `findings_after` comparison in `evaluateConvergence()` (line ~145) still uses counts without scope adjustment. Full scope-adjusted ratio remains a future improvement.
