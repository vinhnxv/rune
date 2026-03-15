# Persistent Test History Protocol

> Defines the storage, format, and lifecycle for persistent test run history (STEP 9.5).
> Test history enables regression detection, flaky test identification, and trend analysis
> across arc pipeline runs.

## Storage Location

Default directory: `.claude/test-history/` (gitignored by default).

Override via talisman: `testing.history.directory`.

```
.claude/test-history/
└── test-history.jsonl   # Rolling window of history entries (JSONL format)
```

Each line in `test-history.jsonl` is one JSON object representing a single arc run.
The file is a rolling window: when it exceeds `max_entries` lines, the oldest entries
are trimmed from the top. No separate index file is maintained.

## History Entry Format

Each run appends one JSON line to `test-history.jsonl`:

```json
{"id":"arc-1772309747014","timestamp":"2026-03-02T12:30:00Z","scope_label":"PR #42","pass_rate":0.95,"coverage_pct":82.3,"tiers_run":["unit","integration","e2e"],"tier_breakdown":{"unit":{"pass":38,"fail":1,"duration_ms":8000},"integration":{"pass":5,"fail":0,"duration_ms":12000},"e2e":{"pass":0,"fail":0,"duration_ms":100000}},"flaky_scores":{},"pr_number":42}
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | YES | Arc pipeline run identifier |
| `timestamp` | ISO 8601 | YES | Run completion time |
| `scope_label` | string | YES | Scope label from `resolveTestScope()` |
| `pass_rate` | number | YES | 0.0–1.0, `null` if no tests |
| `coverage_pct` | number | NO | Diff coverage percentage |
| `tiers_run` | string[] | YES | Tiers executed |
| `tier_breakdown` | object | NO | Per-tier pass/fail/duration |
| `tier_breakdown[tier].pass` | number | YES | Passed count for tier |
| `tier_breakdown[tier].fail` | number | YES | Failed count for tier |
| `tier_breakdown[tier].duration_ms` | number | YES | Tier execution time |
| `tier_breakdown[tier].batch_count` | number | NO | Number of batches for this tier |
| `flaky_scores` | object | NO | Per-test flakiness scores (see [flaky-detection.md](flaky-detection.md)) |
| `pr_number` | number | NO | Associated PR number (`null` if none) |
| `total_batches` | number | NO | Total batch count across all tiers |
| `passed_batches` | number | NO | Batches that passed (first attempt or after fix) |
| `failed_batches` | number | NO | Batches that remained failed after all retries |
| `skipped_batches` | number | NO | Batches skipped (budget exhaustion or other) |
| `fixes_applied` | number | NO | Total fix attempts across all batches |
| `batches_fixed_by_retry` | number | NO | Batches that failed initially but passed after fix loop |
| `avg_batch_duration_ms` | number | NO | Average batch execution time (for timing regression) |

## Persistence Algorithm (STEP 9.5)

```
function persistTestHistory(reportData, talismanConfig):
  historyDir = talismanConfig.testing?.history?.directory ?? ".claude/test-history"
  maxEntries = talismanConfig.testing?.history?.max_entries ?? 50
  passRateDropThreshold = talismanConfig.testing?.history?.pass_rate_drop_threshold ?? 0.05
  regressionThreshold = talismanConfig.testing?.history?.regression_threshold ?? 7

  // 1. Ensure directory exists
  Bash(`mkdir -p "${historyDir}"`)

  // 2. Build history entry from report data
  entry = buildHistoryEntry(reportData)

  // 3. Append to rolling history (JSON lines format)
  historyFile = "${historyDir}/test-history.jsonl"
  existingHistory = exists(historyFile)
    ? Read(historyFile).trim().split('\n').filter(Boolean).map(l => JSON.parse(l))
    : []

  existingHistory.push(entry)

  // 4. Rolling window — keep last maxEntries
  trimmedHistory = existingHistory.slice(-maxEntries)
  Write(historyFile, trimmedHistory.map(e => JSON.stringify(e)).join('\n') + '\n')

  // 5. Global pass-rate regression check (STEP 9.5 gate)
  //    Uses pass_rate_drop_threshold — a float representing the max tolerated drop
  if (trimmedHistory.length >= 2):
    previousEntry = trimmedHistory[trimmedHistory.length - 2]
    currentPassRate = entry.pass_rate ?? 0
    previousPassRate = previousEntry.pass_rate ?? 0
    passRateDrop = previousPassRate - currentPassRate

    if (passRateDrop > passRateDropThreshold):
      WARN: "Test regression detected: pass rate dropped ${(passRateDrop * 100).toFixed(1)}%" +
            " (${(previousPassRate * 100).toFixed(1)}% → ${(currentPassRate * 100).toFixed(1)}%)." +
            " Threshold: ${(passRateDropThreshold * 100).toFixed(1)}%"
      updateCheckpoint({ test_regression_detected: true, regression_pass_rate_drop: passRateDrop })
```

### buildHistoryEntry(reportData)

Extracts fields from the test report output. Maps:
- `reportData.arc_id` → `entry.id`
- `reportData.scope_label` → `entry.scope_label`
- `reportData.summary.pass_rate` → `entry.pass_rate`
- `reportData.summary.coverage_pct` → `entry.coverage_pct`
- `reportData.active_tiers` → `entry.tiers_run`
- Per-tier results → `entry.tier_breakdown` (now includes `batch_count` per tier)
- Computed flaky scores → `entry.flaky_scores`
- `Bash("gh pr view --json number -q .number")` → `entry.pr_number`

#### Batch-Level Fields (v1.165.0+)

When a `testing-plan.json` checkpoint exists, batch-level metrics are extracted:

```javascript
function enrichWithBatchData(entry, testingPlan, evidenceRecords) {
  if (!testingPlan) return entry

  const batches = testingPlan.batches ?? []
  entry.total_batches = batches.length
  entry.passed_batches = batches.filter(b => b.status === "passed").length
  entry.failed_batches = batches.filter(b => b.status === "failed").length
  entry.skipped_batches = batches.filter(b => b.status === "skipped").length

  // Fix loop stats
  const batchesWithFixes = batches.filter(b => (b.fix_attempts ?? 0) > 0)
  entry.fixes_applied = batchesWithFixes.reduce((s, b) => s + (b.fix_attempts ?? 0), 0)
  entry.batches_fixed_by_retry = batchesWithFixes.filter(b => b.status === "passed").length

  // Timing
  const durations = batches
    .filter(b => b.started_at && b.completed_at)
    .map(b => new Date(b.completed_at).getTime() - new Date(b.started_at).getTime())
    .filter(d => d > 0 && Number.isFinite(d))
  entry.avg_batch_duration_ms = durations.length > 0
    ? Math.round(durations.reduce((s, d) => s + d, 0) / durations.length)
    : null

  // Per-tier batch counts
  const tierBatchCounts = {}
  for (const batch of batches) {
    tierBatchCounts[batch.type] = (tierBatchCounts[batch.type] ?? 0) + 1
  }
  for (const [tier, count] of Object.entries(tierBatchCounts)) {
    if (entry.tier_breakdown?.[tier]) {
      entry.tier_breakdown[tier].batch_count = count
    }
  }

  return entry
}
```

## Talisman Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `testing.history.directory` | string | `.claude/test-history` | History storage path |
| `testing.history.max_entries` | number | `50` | Rolling window size (number of JSONL entries retained) |
| `testing.history.pass_rate_drop_threshold` | float | `0.05` | Maximum tolerated global pass-rate drop between consecutive runs before flagging a regression (STEP 9.5 gate). Values are 0.0–1.0 (e.g., `0.05` = 5% drop). Used by the arc-phase-test.md persistence algorithm. |
| `testing.history.regression_threshold` | integer | `7` | Minimum number of recent passing runs (out of last 10) required for a per-test historical series to be considered healthy. Used by regression-detection.md per-test series check. |

## Cold Start Handling

When fewer than 2 history entries exist:

```
function checkColdStart(historyDir):
  historyFile = "${historyDir}/test-history.jsonl"
  entries = exists(historyFile)
    ? Read(historyFile).trim().split('\n').filter(Boolean)
    : []
  if entries.length < 2:
    INFO: "Test history has ${entries.length} run(s). Regression detection " +
          "and flaky test analysis require at least 2 runs. " +
          "Results will improve with more data."
    return true
  return false
```

Regression detection and flaky test detection skip gracefully on cold start.
History is still written — subsequent runs will have enough data.

## Corruption Handling

All history reads are wrapped in try-catch. Corrupt JSONL lines are skipped:

```
function readRecentHistory(historyDir, count):
  historyFile = "${historyDir}/test-history.jsonl"
  if !exists(historyFile):
    return []
  lines = Read(historyFile).trim().split('\n').filter(Boolean)
  results = []
  for line in lines:
    try:
      data = JSON.parse(line)
      results.push(data)
    catch (e):
      WARN: "Corrupt history entry (skipping): ${e.message}"
      // Do NOT abort — continue with remaining lines
  // Return last `count` entries (most recent)
  return results.slice(-count)
```

## Integration Points

- **STEP 9.5**: Called after test report generation (STEP 9). Persists the current run to `test-history.jsonl`.
- **Evidence protocol**: Batch evidence records and failure signatures feed into history entries. See [evidence-protocol.md](evidence-protocol.md).
- **Regression detection**: Reads history via `readRecentHistory()`. See [regression-detection.md](regression-detection.md).
- **Flaky test detection**: Reads history via `readRecentHistory()`. See [flaky-detection.md](flaky-detection.md).
- **Test report template**: History-derived sections (regressions, flaky tests, batch evidence) appear in the report. See [test-report-template.md](test-report-template.md).
- **Trend prediction**: `readRecentHistory()` is called at STEP 1.5 (test strategy) for trend-informed scope decisions.

## Edge Cases

| Scenario | Handling |
|----------|----------|
| No tests found | Entry written with `pass_rate: null`, `tier_breakdown: {}` |
| Timeout (all tiers) | Entry written with `pass_rate: 0` reflecting failures |
| Concurrent arc runs | JSONL append is non-atomic; entries may interleave on the same millisecond — acceptable because rolling-window trim is idempotent |
| Corrupt JSONL line | Skipped silently; remaining valid lines are processed |
| Disk full | `Write()` fails; existing `.jsonl` content is preserved (no partial overwrite) |
| `.claude/test-history/` deleted | Next run recreates directory; cold start handling activates |
