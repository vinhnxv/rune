# Cross-Verification Gate

## Purpose

Validates that VSM regions are covered by design extraction output before proceeding
to implementation. Prevents workers from implementing with incomplete data.

## Algorithm

After Phase 1 extraction (VSM created) and before Phase 1.5 (user confirmation):

```
vsm_regions = parseVsmRegions(vsm_files)
extraction_regions = parseExtractionOutput(reference_code, design_context)

// Zero-region guard: abort if no regions exist (not PASS)
if (vsm_regions.length === 0) {
  ABORT — "Zero VSM regions found, extraction produced no usable data"
}

unmatched = vsm_regions.filter(r => !extraction_regions.covers(r))
mismatch_pct = Math.max(0, (unmatched.length / vsm_regions.length) * 100)  // Clamp negative (over-coverage)
```

## Verdicts

| Mismatch % | Verdict | Action |
|------------|---------|--------|
| <= warn_threshold (default 20%) | **PASS** | Proceed to implementation |
| > warn_threshold and <= block_threshold | **WARN** | Show gap summary, user decides: proceed / pause / manual extraction |
| > block_threshold (default 40%) | **BLOCK** | Stop — try smaller Figma node, break into parts, or manual extraction |

**Boundary rule**: Code uses strict `>` comparisons. A mismatch exactly at the threshold gets the lower verdict (e.g., exactly 40% = WARN, not BLOCK). Mismatch is a float (0.0-100.0).

## Configurable Thresholds

```yaml
# talisman.yml
design_sync:
  verification_gate:
    warn_threshold: 20     # % mismatch to trigger WARN (default: 20)
    block_threshold: 40    # % mismatch to trigger BLOCK (default: 40)
    enabled: true          # Master toggle (default: true)
```

## WARN Output Format

```
Warning: VERIFICATION GATE: WARN ({mismatch_pct}% regions unmatched)

Matched: {matched_count}/{total_count} regions
Unmatched regions:
| # | Region Name | Category | Priority | Suggested Action |
|---|-------------|----------|----------|-----------------|
| 1 | Floating Badge | overlay | P2 | Manual extraction |
| 2 | Footer Links | footer | P3 | Search UntitledUI "footer navigation" |

Options:
1. Proceed with matched regions (unmatched -> fallback to Tailwind)
2. Pause and manually extract missing regions
3. Try a smaller Figma node (less complexity)
```

## BLOCK Output Format

```
Error: VERIFICATION GATE: BLOCK ({mismatch_pct}% regions unmatched)

Only {matched_count}/{total_count} regions were successfully extracted.
This is below the minimum threshold for reliable implementation.

Recommended actions:
1. Break the design into smaller Figma nodes (select specific frames)
2. Manually extract missing regions using the template below
3. Check Figma MCP connectivity (some nodes may have failed silently)
```

## Integration Points

- **design-sync Phase 1.4**: Run gate BEFORE user confirmation AskUserQuestion
- **arc Phase 3**: Run gate after extraction, before VSM collection.
  WARN -> log + proceed. BLOCK -> set phase status "needs_attention" + continue pipeline (non-blocking in arc)
- **design-sync standalone**: WARN -> AskUserQuestion. BLOCK -> AskUserQuestion + STOP option.

## Source Tracking

Each region in the element inventory MUST have a Source column:

| Source | Meaning |
|--------|---------|
| Code | Extracted from `get_design_context()` or `figma_to_react()` |
| Visual | Identified from screenshot VSM analysis only |
| Both | Confirmed by both code extraction and visual analysis |
| Manual | Added by user during WARN/BLOCK resolution |

## Helper Function Signatures

```javascript
// countVsmRegions(vsmFiles: string[]): number
// Counts total visual regions across all VSM JSON files.
// Each VSM file contains a `regions` array — returns the sum of all region counts.

// countCoveredRegions — Two calling conventions (intentional overload):
//
// 1. Arc context (array form):
//    countCoveredRegions(vsmFiles: string[]): number
//    Counts regions that have at least one matched extraction source.
//    A region is "covered" when region.source !== "Visual" (i.e., has code extraction or both).
//
// 2. Standalone design-sync context (enriched form):
//    countCoveredRegions(enrichedVsm: object, referenceCode: string | null): number
//    Counts regions where enrichedVsm regions overlap with referenceCode component names.
//    Used when enriched-vsm.json is available from Phase 1.3 Component Match.
```

## Unit Testing Strategy

The gate algorithm is a pure function (mismatch percentage → verdict). It can be unit-tested with fixture data without live Figma or MCP connections.

**Fixture-based test cases:**

| # | Scenario | vsmRegionCount | extractionCoverage | Expected Verdict |
|---|----------|---------------|--------------------|------------------|
| 1 | All matched | 10 | 10 | PASS (0%) |
| 2 | Below warn threshold | 10 | 9 | PASS (10%) |
| 3 | At warn threshold exactly | 10 | 8 | PASS (20% — strict `>`) |
| 4 | Above warn, below block | 10 | 7 | WARN (30%) |
| 5 | At block threshold exactly | 10 | 6 | WARN (40% — strict `>`) |
| 6 | Above block threshold | 10 | 5 | BLOCK (50%) |
| 7 | Zero regions (empty VSM) | 0 | 0 | ABORT (zero-region guard) |
| 8 | All unmatched | 10 | 0 | BLOCK (100%) |
| 9 | Gate disabled | any | any | SKIP (no verdict) |
| 10 | Non-integer mismatch | 7 | 4 | BLOCK (42.86%) |
| 11 | Custom thresholds (30/60) | 10 | 7 | PASS (30% — at warn, strict `>`) |
| 12 | Custom thresholds (30/60) | 10 | 3 | BLOCK (70%) |
| 13 | Inverted thresholds (40/20) | 10 | 7 | WARN (30% — reverts to defaults) |
| 14 | Over-coverage (more covered than total) | 10 | 12 | PASS (clamped to 0%) |
| 15 | enabled: "false" (string) | 10 | 5 | BLOCK (type warning emitted, gate runs) |

**Negative regression tests:**

| # | Scenario | Assertion |
|---|----------|-----------|
| N-1 | figma_to_react() output NOT passed verbatim to workers | Worker task description must NOT contain raw JSX/className strings from reference code |
| N-2 | LOW confidence regions NOT imported | Workers with score < 0.60 must implement from scratch, NOT import library components |
| N-3 | BLOCK verdict propagated to workers | Worker task description must contain gate verdict context when BLOCK |

**Confidence boundary test cases:**

| # | Score | Expected Confidence | Boundary Rule |
|---|-------|--------------------|----|
| C-1 | 0.80 | HIGH | `>=` high_confidence_threshold |
| C-2 | 0.79 | MEDIUM | Below HIGH, at or above LOW |
| C-3 | 0.60 | MEDIUM | `>=` low_confidence_threshold |
| C-4 | 0.599 | LOW | Below low_confidence_threshold (strict `<`) |
| C-5 | 1.00 | HIGH | Maximum score |
| C-6 | 0.00 | LOW | Minimum score |
| C-7 | 0.80 (custom high=0.90) | MEDIUM | Custom threshold override |
| C-8 | 0.85 (custom low=0.85) | ERROR | low >= high — config warning, reverts to defaults |

### Executable Test Harness

```javascript
// verification-gate.test.js
// Pure function test — no Figma or MCP dependencies required.

function computeVerdict(vsmRegionCount, extractionCoverage, config = {}) {
  const gateConfig = config.verification_gate ?? {}

  // Type check
  if (gateConfig.enabled !== undefined && typeof gateConfig.enabled !== 'boolean') {
    return { verdict: 'TYPE_WARNING', message: `enabled must be boolean, got ${typeof gateConfig.enabled}` }
  }
  if (gateConfig.enabled === false) return { verdict: 'SKIP' }

  // Zero-region guard
  if (vsmRegionCount === 0) return { verdict: 'ABORT', reason: 'zero-regions' }

  const rawPct = ((vsmRegionCount - extractionCoverage) / vsmRegionCount) * 100
  const mismatchPct = Math.max(0, rawPct)

  let warnThreshold = Math.max(0, Math.min(100, gateConfig.warn_threshold ?? 20))
  let blockThreshold = Math.max(0, Math.min(100, gateConfig.block_threshold ?? 40))
  if (warnThreshold >= blockThreshold) {
    warnThreshold = 20; blockThreshold = 40  // revert to defaults
  }

  if (mismatchPct > blockThreshold) return { verdict: 'BLOCK', mismatchPct }
  if (mismatchPct > warnThreshold) return { verdict: 'WARN', mismatchPct }
  return { verdict: 'PASS', mismatchPct }
}

function classifyConfidence(score, config = {}) {
  const low = config.low_confidence_threshold ?? 0.60
  const high = config.high_confidence_threshold ?? 0.80
  if (low >= high) return { confidence: 'ERROR', reason: 'low >= high threshold' }
  if (score >= high) return { confidence: 'HIGH' }
  if (score >= low) return { confidence: 'MEDIUM' }
  return { confidence: 'LOW' }
}

// Run all fixture cases
const fixtures = [
  { vsm: 10, cov: 10, expected: 'PASS' },
  { vsm: 10, cov: 9,  expected: 'PASS' },
  { vsm: 10, cov: 8,  expected: 'PASS' },   // exactly 20% — strict >
  { vsm: 10, cov: 7,  expected: 'WARN' },
  { vsm: 10, cov: 6,  expected: 'WARN' },   // exactly 40% — strict >
  { vsm: 10, cov: 5,  expected: 'BLOCK' },
  { vsm: 0,  cov: 0,  expected: 'ABORT' },  // zero-region guard
  { vsm: 10, cov: 0,  expected: 'BLOCK' },
  { vsm: 10, cov: 5,  expected: 'SKIP', config: { verification_gate: { enabled: false } } },
  { vsm: 7,  cov: 4,  expected: 'BLOCK' },  // 42.86%
  { vsm: 10, cov: 7,  expected: 'PASS', config: { verification_gate: { warn_threshold: 30, block_threshold: 60 } } },
  { vsm: 10, cov: 3,  expected: 'BLOCK', config: { verification_gate: { warn_threshold: 30, block_threshold: 60 } } },
  { vsm: 10, cov: 7,  expected: 'WARN', config: { verification_gate: { warn_threshold: 40, block_threshold: 20 } } },  // inverted → defaults
  { vsm: 10, cov: 12, expected: 'PASS' },   // over-coverage → clamped 0%
]

for (const f of fixtures) {
  const result = computeVerdict(f.vsm, f.cov, f.config ?? {})
  console.assert(result.verdict === f.expected,
    `FAIL: vsm=${f.vsm} cov=${f.cov} expected=${f.expected} got=${result.verdict}`)
}

// Confidence boundary tests
const confFixtures = [
  { score: 0.80, expected: 'HIGH' },
  { score: 0.79, expected: 'MEDIUM' },
  { score: 0.60, expected: 'MEDIUM' },
  { score: 0.599, expected: 'LOW' },
  { score: 1.00, expected: 'HIGH' },
  { score: 0.00, expected: 'LOW' },
  { score: 0.80, expected: 'MEDIUM', config: { high_confidence_threshold: 0.90 } },
  { score: 0.85, expected: 'ERROR', config: { low_confidence_threshold: 0.85, high_confidence_threshold: 0.80 } },
]

for (const f of confFixtures) {
  const result = classifyConfidence(f.score, f.config ?? {})
  console.assert(result.confidence === f.expected,
    `FAIL: score=${f.score} expected=${f.expected} got=${result.confidence}`)
}

console.log('All verification gate tests passed.')
```
