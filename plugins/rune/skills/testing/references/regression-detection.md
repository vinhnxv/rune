# Regression Detection Algorithm

> Compares the current test run against recent history to identify tests
> that have regressed — previously passing tests that now fail. Runs as
> part of STEP 9.5 after history persistence.

## Algorithm

```
function detectRegressions(currentRun, historyDir, talismanConfig):
  recentCount = 10
  threshold = talismanConfig.testing?.history?.regression_threshold ?? 7
  recentRuns = readRecentHistory(historyDir, count=recentCount)

  // Cold start guard — need history to compare against
  if recentRuns.length < 2:
    INFO: "Insufficient history for regression detection (${recentRuns.length} runs). Skipping."
    return []

  regressions = []
  for test in currentRun.per_test:
    if test.status === "failed":
      // Look up this test in recent history
      recentResults = []
      for run in recentRuns:
        match = run.per_test.find(t => t.name === test.name)
        if match:
          recentResults.push(match.status)

      // Skip new tests (no history at all)
      if recentResults.length === 0:
        continue

      // Count recent passes
      passCount = recentResults.filter(r => r === "passed").length

      // Regression = test passed in >= threshold of recent runs
      if passCount >= threshold:
        regressions.push({
          test: test.name,
          type: "regression",
          confidence: passCount / recentResults.length,
          first_failure: currentRun.timestamp,
          tier: test.tier,
          file: test.file ?? test.scenario_source ?? null,
          recent_pass_count: passCount,
          recent_total: recentResults.length
        })

  return regressions.sort((a, b) => b.confidence - a.confidence)
```

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `testing.history.regression_threshold` | integer | `7` | Minimum recent passes (out of last 10) to classify a currently-failing test as a per-test regression |

> **Two complementary regression signals.** The Rune testing pipeline uses two
> distinct regression checks, each with its own config key:
>
> | Signal | Config Key | Type | Scope | Algorithm |
> |--------|-----------|------|-------|-----------|
> | Per-test regression | `testing.history.regression_threshold` | integer (default `7`) | Individual test series | A test that passes in >= threshold of its last 10 runs but fails now is flagged as a regression (this file) |
> | Global pass-rate drop | `testing.history.pass_rate_drop_threshold` | float 0.0--1.0 (default `0.05`) | Entire test suite | If the overall pass rate drops by more than this fraction compared to the rolling baseline, the STEP 9.5 global gate fires (see arc-phase-test.md) |
>
> These signals are independent — a run can trigger one, both, or neither. The
> per-test check (this algorithm) identifies *which* tests regressed; the global
> gate detects *aggregate* quality drops that might not surface in any single test.

### Threshold Tuning

| Threshold | Sensitivity | Use case |
|-----------|------------|----------|
| `9` or `10` | Very high | Only flags tests with near-perfect pass history |
| `7` (default) | Balanced | Standard — catches most regressions, tolerates some prior failures |
| `5` | Low | Permissive — may include tests with inconsistent history |
| `< 5` | Very low | Not recommended — overlaps with flaky test detection |

## Output Format

Each regression entry:

```json
{
  "test": "test_auth_login_valid",
  "type": "regression",
  "confidence": 0.9,
  "first_failure": "2026-03-02T12:30:00Z",
  "tier": "unit",
  "file": "tests/test_auth.py",
  "recent_pass_count": 9,
  "recent_total": 10
}
```

### Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `test` | string | Test identifier (matches `per_test[].name` in history) |
| `type` | string | Always `"regression"` |
| `confidence` | number | 0.0–1.0 — ratio of passes in recent history |
| `first_failure` | ISO 8601 | Timestamp of the current run (when regression was detected) |
| `tier` | string | Test tier (`unit`, `integration`, `e2e`) |
| `file` | string or null | Source file or scenario path |
| `recent_pass_count` | number | How many of the last N runs passed |
| `recent_total` | number | How many recent runs contained this test |

## Data Source Note

> **`per_test` field**: The `detectRegressions()` algorithm operates on **runtime test report data**, not on persisted JSONL history entries. The `currentRun.per_test` array is populated from the current test execution results (parsed from `test-results-*.md` files during STEP 9.5). Historical `per_test` data in `run.per_test` is available only when history entries include per-test granularity — which is **not guaranteed** by the base history entry schema in `history-protocol.md`. When `per_test` is absent from historical entries, the per-test regression loop is a no-op and only the global pass-rate drop check (in arc-phase-test.md STEP 9.5) provides regression signals.

## Integration with STEP 9.5

Regression detection runs after history persistence within STEP 9.5:

```
// In persistTestHistory (after writing current run):

// 6. Detect regressions against updated history
regressions = detectRegressions(currentRun, historyDir, talismanConfig)
if regressions.length > 0:
  WARN: "${regressions.length} regression(s) detected"
  // Attach to report data for template rendering
  reportData.regressions = regressions
```

## Integration with Test Report Template

Regressions appear in the test report as a dedicated section:

```markdown
## Regressions Detected

| Test | Tier | Confidence | Recent History |
|------|------|------------|----------------|
| test_auth_login_valid | unit | 90% (9/10 recent passes) | Likely regression |
| checkout-flow | e2e | 70% (7/10 recent passes) | Possible regression |
```

When no regressions are detected, the section is omitted (not rendered as empty).

## Flaky vs Regression Distinction

A test that fails in the current run could be either a regression or a flaky test.
The distinction relies on historical pass rate:

| Pattern | Classification | Rationale |
|---------|---------------|-----------|
| Passes 7+/10 recent, fails now | **Regression** | Historically reliable test broke |
| Passes 3-6/10 recent, fails now | Neither (inconclusive) | Not enough signal — monitor |
| Passes some, fails some (flakiness > 0.1) | **Flaky** | Inconsistent pass/fail pattern |
| Never passed in history | Not regression | May be a known broken test |

A test can appear in BOTH the regression list and the flaky list if:
- It has a high pass rate overall (e.g., 80%) but occasional failures
- The current run happens to catch one of its rare failures

In this case, the regression entry will have lower confidence, and the flaky
detection provides the more actionable classification.

## Edge Cases

| Scenario | Handling |
|----------|----------|
| New test (no history) | Skipped — `recentResults.length === 0` guard |
| Renamed test | Treated as new test (no match on old name). Name-based matching only. |
| Test removed from codebase | Does not appear in `currentRun.per_test`, so never evaluated |
| All recent runs failed | `passCount` = 0, below threshold — not flagged as regression |
| Test only in some tiers | Only compared against runs where the test was present |
| Cold start (< 2 history runs) | Function returns `[]` with INFO message |
| Corrupt history entry | Handled by `readRecentHistory()` try-catch — see [history-protocol.md](history-protocol.md) |
| Skipped test in current run | Only `status === "failed"` tests are evaluated — skipped tests ignored |

## Batch-Level Regression Signals (v1.165.0+)

In addition to per-test regression, the following batch-level signals are computed
when history entries include batch data (see [history-protocol.md](history-protocol.md)):

### Duration Regression

Detects batch execution time inflation (slow tests, resource contention):

```
function detectDurationRegression(currentEntry, recentEntries):
  if recentEntries.length < 3:
    return null  // Need baseline

  // Compare current avg batch duration against historical average
  currentAvg = currentEntry.avg_batch_duration_ms
  if !currentAvg:
    return null

  historicalAvgs = recentEntries
    .map(e => e.avg_batch_duration_ms)
    .filter(d => d != null && d > 0)

  if historicalAvgs.length < 2:
    return null

  historicalMean = historicalAvgs.reduce((s, d) => s + d, 0) / historicalAvgs.length

  ratio = currentAvg / historicalMean
  if ratio > 1.5:
    return {
      type: "duration_regression",
      severity: ratio > 2.0 ? "critical" : "warning",
      current_avg_ms: currentAvg,
      historical_avg_ms: Math.round(historicalMean),
      ratio: Math.round(ratio * 100) / 100,
      message: "Avg batch duration ${ratio}x above historical average"
    }
  return null
```

### New Failure Signatures

Detects tests that passed in ALL recent runs but fail now (high-confidence regressions):

```
function detectNewFailureSignatures(currentSignatures, recentEntries):
  if !currentSignatures || currentSignatures.length === 0:
    return []

  // Collect all historical failure signatures
  historicalSignatures = new Set()
  for entry in recentEntries:
    for sig in (entry.failure_signatures ?? []):
      historicalSignatures.add(sig)

  // New = present in current but never seen in history
  newSignatures = currentSignatures.filter(s => !historicalSignatures.has(s))

  return newSignatures.map(sig => ({
    type: "new_failure_signature",
    signature: sig,
    message: "Failure signature ${sig} never seen in last ${recentEntries.length} runs"
  }))
```

### Fix Rate Trend

Detects declining code quality (more fixes needed than usual):

```
function detectFixRateTrend(currentEntry, recentEntries):
  if recentEntries.length < 3:
    return null

  currentFixes = currentEntry.fixes_applied ?? 0
  historicalFixes = recentEntries
    .map(e => e.fixes_applied ?? 0)
    .filter(f => f != null)

  if historicalFixes.length < 2:
    return null

  historicalMean = historicalFixes.reduce((s, f) => s + f, 0) / historicalFixes.length

  // Flag if current fix count is 2x+ the historical average (minimum 2 fixes)
  if currentFixes >= 2 && historicalMean > 0 && currentFixes / historicalMean >= 2.0:
    return {
      type: "fix_rate_increase",
      severity: "warning",
      current_fixes: currentFixes,
      historical_avg: Math.round(historicalMean * 10) / 10,
      message: "Fix rate ${currentFixes} is ${(currentFixes / historicalMean).toFixed(1)}x above average"
    }
  return null
```

### Combined Output

```
function detectBatchRegressions(currentEntry, recentEntries):
  regressions = []

  duration = detectDurationRegression(currentEntry, recentEntries)
  if duration:
    regressions.push(duration)

  newSigs = detectNewFailureSignatures(currentEntry.failure_signatures, recentEntries)
  regressions.push(...newSigs)

  fixRate = detectFixRateTrend(currentEntry, recentEntries)
  if fixRate:
    regressions.push(fixRate)

  // Compute overall trend
  trend = "stable"
  if regressions.some(r => r.severity === "critical"):
    trend = "declining"
  elif regressions.length >= 2:
    trend = "mixed"
  elif regressions.length === 0 && (currentEntry.pass_rate ?? 0) >= 0.95:
    trend = "improving"

  return { regressions, trend }
```

## Error Handling

```
function detectRegressionsWithGuard(currentRun, historyDir, talismanConfig):
  try:
    return detectRegressions(currentRun, historyDir, talismanConfig)
  catch (e):
    WARN: "Regression detection failed: ${e.message}. Continuing without regression data."
    return []
```

Regression detection is advisory — failures in the detection algorithm must not
block the arc pipeline or test report generation.
