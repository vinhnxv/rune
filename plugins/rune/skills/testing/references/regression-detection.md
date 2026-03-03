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
| `testing.history.regression_threshold` | number | `7` | Minimum recent passes (out of last 10) to classify a failure as a regression |

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
