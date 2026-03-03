# Persistent Test History Protocol

> Defines the storage, format, and lifecycle for persistent test run history (STEP 9.5).
> Test history enables regression detection, flaky test identification, and trend analysis
> across arc pipeline runs.

## Storage Location

Default directory: `.claude/test-history/` (gitignored by default).

Override via talisman: `testing.history.directory`.

```
.claude/test-history/
├── test-run-2026-03-02T123000Z.json   # Individual run entries
├── test-run-2026-03-01T154500Z.json
├── ...
└── history-index.json                  # Lightweight index for fast queries
```

## History Entry Format

Each run produces a file named `test-run-{timestamp}.json`:

```json
{
  "run_id": "arc-1772309747014",
  "timestamp": "2026-03-02T12:30:00Z",
  "scope": "PR #42",
  "branch": "feat/auth",
  "commit": "abc1234",
  "summary": {
    "overall_status": "PASS",
    "pass_rate": 0.95,
    "coverage_pct": 82.3,
    "tiers_run": ["unit", "integration", "e2e"],
    "total_tests": 45,
    "passed": 43,
    "failed": 1,
    "skipped": 1,
    "flaky": 0,
    "duration_ms": 120000
  },
  "per_test": [
    {
      "name": "test_auth_login_valid",
      "tier": "unit",
      "status": "passed",
      "duration_ms": 150,
      "file": "tests/test_auth.py"
    },
    {
      "name": "login-flow",
      "tier": "e2e",
      "status": "failed",
      "duration_ms": 8500,
      "scenario_source": ".claude/test-scenarios/login-flow.yml",
      "failure_trace": "TEST-001"
    }
  ],
  "scenarios_run": 3,
  "scenarios_passed": 2,
  "scenarios_failed": 1,
  "ac_coverage": {
    "AC-001": "COVERED",
    "AC-002": "NOT_COVERED"
  }
}
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `run_id` | string | YES | Arc pipeline run identifier |
| `timestamp` | ISO 8601 | YES | Run completion time |
| `scope` | string | YES | Scope label from `resolveTestScope()` |
| `branch` | string | YES | Git branch at time of run |
| `commit` | string | YES | Git commit SHA (short) |
| `summary.overall_status` | enum | YES | `PASS`, `WARN`, `FAIL` |
| `summary.pass_rate` | number | YES | 0.0–1.0, `null` if no tests |
| `summary.coverage_pct` | number | NO | Diff coverage percentage |
| `summary.tiers_run` | string[] | YES | Tiers executed |
| `summary.total_tests` | number | YES | Total test count |
| `summary.passed` | number | YES | Passed count |
| `summary.failed` | number | YES | Failed count |
| `summary.skipped` | number | YES | Skipped count |
| `summary.flaky` | number | YES | Flaky count (passed on retry) |
| `summary.duration_ms` | number | YES | Total execution time |
| `per_test[].name` | string | YES | Test identifier |
| `per_test[].tier` | enum | YES | `unit`, `integration`, `e2e` |
| `per_test[].status` | enum | YES | `passed`, `failed`, `skipped`, `flaky` |
| `per_test[].duration_ms` | number | YES | Individual test duration |
| `per_test[].file` | string | NO | Source file (unit/integration) |
| `per_test[].scenario_source` | string | NO | Scenario YAML path (e2e) |
| `per_test[].failure_trace` | string | NO | TEST-NNN finding reference |
| `scenarios_run` | number | NO | Total scenarios executed |
| `scenarios_passed` | number | NO | Passed scenarios |
| `scenarios_failed` | number | NO | Failed scenarios |
| `ac_coverage` | object | NO | AC-NNN → `COVERED` / `NOT_COVERED` |

## Persistence Algorithm (STEP 9.5)

```
function persistTestHistory(reportData, talismanConfig):
  historyDir = talismanConfig.testing?.history?.directory ?? ".claude/test-history"
  maxEntries = talismanConfig.testing?.history?.max_entries ?? 100

  // 1. Ensure directory exists
  mkdir -p historyDir

  // 2. Build history entry from report data
  entry = buildHistoryEntry(reportData)

  // 3. Atomic write (tmp + rename to prevent corruption on crash)
  timestamp = entry.timestamp.replace(/[:-]/g, "")  // e.g., "20260302T123000Z"
  tmpFile = "${historyDir}/.tmp-${Date.now()}.json"
  targetFile = "${historyDir}/test-run-${timestamp}.json"
  Write(tmpFile, JSON.stringify(entry, null, 2))
  rename(tmpFile, targetFile)

  // 4. Prune old entries (rolling window)
  entries = glob("${historyDir}/test-run-*.json").sort().reverse()
  if entries.length > maxEntries:
    for entry in entries.slice(maxEntries):
      rm(entry)

  // 5. Update index (lightweight summary for fast queries)
  updateHistoryIndex(historyDir, entries.slice(0, maxEntries))
```

### buildHistoryEntry(reportData)

Extracts fields from the test report output. Maps:
- `reportData.summary` → `entry.summary`
- `reportData.per_tier_results` → flattened `entry.per_test` array
- `reportData.scenario_results` → `entry.scenarios_*` counts
- `reportData.ac_traceability` → `entry.ac_coverage` map
- `Bash("git rev-parse --short HEAD")` → `entry.commit`
- `Bash("git rev-parse --abbrev-ref HEAD")` → `entry.branch`

## History Index Format

The index file (`history-index.json`) provides O(1) lookup by test name.
Aggregated per-test rather than flat entry storage (performance optimization
for large history sets).

```json
{
  "last_updated": "2026-03-02T12:30:00Z",
  "total_runs": 42,
  "tests": {
    "test_auth_login_valid": {
      "last_status": "passed",
      "recent_results": ["passed", "passed", "failed", "passed", "passed"],
      "flakiness_score": 0.05,
      "pass_rate": 0.95,
      "avg_duration_ms": 145
    },
    "login-flow": {
      "last_status": "failed",
      "recent_results": ["failed", "passed", "passed", "passed", "passed"],
      "flakiness_score": 0.10,
      "pass_rate": 0.80,
      "avg_duration_ms": 8200
    }
  }
}
```

### Index Fields

| Field | Type | Description |
|-------|------|-------------|
| `last_updated` | ISO 8601 | When index was last rebuilt |
| `total_runs` | number | Total history entries on disk |
| `tests[name].last_status` | enum | Most recent run result |
| `tests[name].recent_results` | string[] | Last N results (newest first) |
| `tests[name].flakiness_score` | number | 0.0–0.5 (see [flaky-detection.md](flaky-detection.md)) |
| `tests[name].pass_rate` | number | 0.0–1.0 across all stored runs |
| `tests[name].avg_duration_ms` | number | Mean duration across stored runs |

### updateHistoryIndex Algorithm

```
function updateHistoryIndex(historyDir, entries):
  index = { last_updated: now(), total_runs: entries.length, tests: {} }

  for entryFile in entries:
    entry = JSON.parse(Read(entryFile))
    for test in entry.per_test:
      if !index.tests[test.name]:
        index.tests[test.name] = {
          last_status: null,
          recent_results: [],
          flakiness_score: 0,
          pass_rate: 0,
          avg_duration_ms: 0
        }
      record = index.tests[test.name]
      record.recent_results.push(test.status)

  // Compute aggregates per test
  for [name, record] in Object.entries(index.tests):
    results = record.recent_results
    record.last_status = results[0]    // entries are newest-first
    record.pass_rate = results.filter(r => r === "passed").length / results.length
    passCount = results.filter(r => r === "passed").length
    failCount = results.filter(r => r === "failed").length
    record.flakiness_score = (passCount > 0 && failCount > 0)
      ? Math.min(passCount, failCount) / results.length
      : 0
    // avg_duration_ms computed from per_test entries (not shown for brevity)

  // Atomic write
  tmpFile = "${historyDir}/.tmp-index-${Date.now()}.json"
  Write(tmpFile, JSON.stringify(index, null, 2))
  rename(tmpFile, "${historyDir}/history-index.json")
```

## Talisman Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `testing.history.directory` | string | `.claude/test-history` | History storage path |
| `testing.history.max_entries` | number | `100` | Rolling window size |
| `testing.history.regression_threshold` | number | `7` | Min recent passes to flag regression (out of last 10) |

## Cold Start Handling

When fewer than 2 history entries exist:

```
function checkColdStart(historyDir):
  entries = glob("${historyDir}/test-run-*.json")
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

All history reads are wrapped in try-catch:

```
function readRecentHistory(historyDir, count):
  entries = glob("${historyDir}/test-run-*.json").sort().reverse().slice(0, count)
  results = []
  for entryFile in entries:
    try:
      data = JSON.parse(Read(entryFile))
      results.push(data)
    catch (e):
      WARN: "Corrupt history entry: ${entryFile}. Skipping. Error: ${e.message}"
      // Do NOT abort — continue with remaining entries
  return results
```

On index corruption:
```
function readHistoryIndex(historyDir):
  try:
    return JSON.parse(Read("${historyDir}/history-index.json"))
  catch (e):
    WARN: "History index corrupt or missing. Rebuilding from entries."
    entries = glob("${historyDir}/test-run-*.json").sort().reverse()
    updateHistoryIndex(historyDir, entries)
    return JSON.parse(Read("${historyDir}/history-index.json"))
```

## Integration Points

- **STEP 9.5**: Called after test report generation (STEP 9). Persists the current run.
- **Regression detection**: Reads history via `readRecentHistory()`. See [regression-detection.md](regression-detection.md).
- **Flaky test detection**: Reads history via `readRecentHistory()`. See [flaky-detection.md](flaky-detection.md).
- **Test report template**: History-derived sections (regressions, flaky tests) appear in the report. See [test-report-template.md](test-report-template.md).
- **History index**: Queried at STEP 1.5 (test strategy) for trend-informed predictions.

## Edge Cases

| Scenario | Handling |
|----------|----------|
| No git repo | `commit` and `branch` fields set to `"unknown"` |
| No tests found | Entry written with `total_tests: 0`, `pass_rate: null` |
| Timeout (all tiers) | Entry written with `overall_status: "FAIL"`, partial `per_test` |
| Concurrent arc runs | Timestamp in filename prevents collision; index rebuild is idempotent |
| Disk full | Atomic write fails at tmp stage; existing history preserved |
| `.claude/test-history/` deleted | Next run recreates directory; cold start handling activates |
