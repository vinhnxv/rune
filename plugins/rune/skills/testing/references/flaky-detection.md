# Flaky Test Detection Algorithm

> Analyzes test pass/fail patterns over recent history to identify flaky tests —
> tests with non-deterministic outcomes. Provides actionable recommendations
> (QUARANTINE or INVESTIGATE) and the `pass_k` reliability metric.

## Algorithm

```
function detectFlakyTests(historyDir, talismanConfig):
  recentCount = 20
  minDataPoints = 5
  flakinessThreshold = 0.1
  quarantineThreshold = 0.3
  recentRuns = readRecentHistory(historyDir, count=recentCount)

  // Cold start guard — require minimum data points
  if recentRuns.length < minDataPoints:
    INFO: "Insufficient history for flaky detection (${recentRuns.length}/${minDataPoints} runs). Skipping."
    return []

  // Aggregate pass/fail counts per test
  testStats = {}
  for run in recentRuns:
    for test in run.per_test:
      if !testStats[test.name]:
        testStats[test.name] = { pass: 0, fail: 0, results: [] }
      if test.status === "passed":
        testStats[test.name].pass++
        testStats[test.name].results.push("passed")
      else if test.status === "failed":
        testStats[test.name].fail++
        testStats[test.name].results.push("failed")
      // skipped tests are excluded from flakiness calculation

  // Identify flaky tests
  flakyTests = []
  for [name, stats] in Object.entries(testStats):
    total = stats.pass + stats.fail

    // Require minimum data points before scoring
    if total < minDataPoints:
      continue

    // Both passes AND failures required for flakiness
    if stats.pass === 0 || stats.fail === 0:
      continue

    // Flakiness score: min(pass, fail) / total
    // Range: 0.0 (deterministic) to 0.5 (perfectly random)
    flakiness = Math.min(stats.pass, stats.fail) / total

    if flakiness > flakinessThreshold:
      flakyTests.push({
        name,
        flakiness_score: flakiness,
        pass_rate: stats.pass / total,
        pass_k3: computePassK(name, recentRuns, k=3),
        recommendation: flakiness > quarantineThreshold ? "QUARANTINE" : "INVESTIGATE"
      })

  return flakyTests.sort((a, b) => b.flakiness_score - a.flakiness_score)
```

## Flakiness Score

The flakiness score uses the `min(pass, fail) / total` heuristic
(aligned with Google ICSE 2020 methodology):

```
flakiness_score = min(pass_count, fail_count) / total_count
```

| Score | Interpretation |
|-------|---------------|
| `0.0` | Deterministic — always passes or always fails |
| `0.05` | Very low flakiness (e.g., 1 failure in 20 runs) |
| `0.1` | Threshold — starts being flagged as flaky |
| `0.2` | Moderate — fails ~20% of the time |
| `0.3` | High — threshold for QUARANTINE recommendation |
| `0.5` | Maximum — perfectly non-deterministic (coin flip) |

## pass_k Metric

The `pass_k` metric measures the probability that a test passes `k` consecutive
times. This captures sequential reliability — a test with 90% pass rate might
still fail frequently in runs of 3+ consecutive executions.

### Definition

```
function computePassK(testName, recentRuns, k):
  // Extract ordered results for this test (oldest to newest)
  results = []
  for run in recentRuns.reverse():  // oldest first
    match = run.per_test.find(t => t.name === testName)
    if match:
      results.push(match.status === "passed" ? 1 : 0)

  // Need at least k results to compute
  if results.length < k:
    return null

  // Count windows of k consecutive passes
  windows = results.length - k + 1
  consecutivePasses = 0
  for i in range(0, windows):
    window = results.slice(i, i + k)
    if window.every(r => r === 1):
      consecutivePasses++

  // pass_k = fraction of k-length windows that are all-pass
  return consecutivePasses / windows
```

### Interpretation

| pass_k(3) | Meaning |
|-----------|---------|
| `1.0` | Every window of 3 consecutive runs passed — highly reliable |
| `0.8` | 80% of 3-run windows passed — generally reliable |
| `0.5` | Only half of 3-run windows passed — unreliable |
| `0.0` | No 3-run window passed — consistently disrupted |
| `null` | Insufficient data (< k results) |

### Why pass_k Matters

A test with `pass_rate = 0.9` and `pass_k3 = 0.3` tells a different story than
`pass_rate = 0.9` and `pass_k3 = 0.85`:

- The first test clusters its failures — it has "bad streaks" that break CI runs
- The second test has isolated, widely-spaced failures — less disruptive

`pass_k3` helps distinguish tests that are "annoying but manageable" from tests
that "break the build repeatedly."

## Recommendations

| Flakiness Score | pass_k3 | Recommendation | Action |
|----------------|---------|----------------|--------|
| > 0.3 | any | **QUARANTINE** | Move to quarantine suite, do not block CI |
| 0.1–0.3 | < 0.5 | **INVESTIGATE** (high priority) | Clustered failures — likely environmental |
| 0.1–0.3 | >= 0.5 | **INVESTIGATE** | Sporadic failures — may be timing/race condition |
| < 0.1 | any | Not flagged | Below flakiness threshold |

## Output Format

Each flaky test entry:

```json
{
  "name": "test_payment_webhook_retry",
  "flakiness_score": 0.25,
  "pass_rate": 0.75,
  "pass_k3": 0.45,
  "recommendation": "INVESTIGATE"
}
```

### Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Test identifier |
| `flakiness_score` | number | 0.0–0.5 flakiness metric |
| `pass_rate` | number | 0.0–1.0 overall pass ratio |
| `pass_k3` | number or null | Probability of 3 consecutive passes |
| `recommendation` | enum | `QUARANTINE` or `INVESTIGATE` |

## Integration with History Protocol

Flaky detection reads from the same history store as regression detection.
See [history-protocol.md](history-protocol.md) for storage format and
`readRecentHistory()` implementation.

```
// In STEP 9.5 (after regression detection):

// 7. Detect flaky tests
flakyTests = detectFlakyTests(historyDir, talismanConfig)
if flakyTests.length > 0:
  WARN: "${flakyTests.length} flaky test(s) detected"
  reportData.flaky_analysis = flakyTests
```

## Integration with Batch Evidence (v1.165.0+)

When batch evidence records are available (see [evidence-protocol.md](evidence-protocol.md)),
flaky detection benefits from richer failure data — the evidence record's `failures[]` array
provides `error_type` and `assertion_message` which can distinguish between different failure
modes for the same test name. This data is available for future enrichment of flaky scoring
when sufficient cross-run history accumulates.

## Integration with Test Report Template

Flaky test analysis appears as a dedicated section in the test report:

```markdown
## Flaky Test Analysis

| Test | Flakiness | Pass Rate | pass_k3 | Recommendation |
|------|-----------|-----------|---------|----------------|
| test_payment_webhook_retry | 0.25 | 75% | 0.45 | INVESTIGATE |
| test_ws_reconnect | 0.35 | 65% | 0.20 | QUARANTINE |
```

This section is distinct from the existing "Flaky Tests" section in the report
template (which lists tests that passed on retry in the current run). The
history-based analysis provides cross-run trend data, while the existing section
captures single-run retry outcomes.

## Cold Start Handling

Flaky detection requires at least 5 data points per test before scoring:

```
// Per-test minimum (within the algorithm)
if total < minDataPoints:
  continue  // skip this test, not enough data

// Global minimum (entry guard)
if recentRuns.length < minDataPoints:
  return []  // skip entirely
```

On cold start, the flaky analysis section is omitted from the report.
As history accumulates, flaky tests are progressively detected.

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Test always passes | `fail === 0`, skipped (not flaky) |
| Test always fails | `pass === 0`, skipped (not flaky — it is broken, not flaky) |
| Test only in some runs | Scored only against runs where it appeared |
| Renamed test | Treated as new test — old name retains its own history |
| Test with only skipped results | `total = 0` (pass + fail), skipped by `total < minDataPoints` |
| Very new test (< 5 appearances) | Skipped by minimum data points guard |
| Flaky AND regression | Test can appear in both lists — see [regression-detection.md](regression-detection.md) |
| History corruption | Handled by `readRecentHistory()` try-catch — see [history-protocol.md](history-protocol.md) |

## Error Handling

```
function detectFlakyTestsWithGuard(historyDir, talismanConfig):
  try:
    return detectFlakyTests(historyDir, talismanConfig)
  catch (e):
    WARN: "Flaky test detection failed: ${e.message}. Continuing without flaky analysis."
    return []
```

Flaky test detection is advisory — failures in the detection algorithm must not
block the arc pipeline or test report generation.
