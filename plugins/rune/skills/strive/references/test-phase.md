# Phase 3.6: Mini Test Phase (Lightweight Verification)

Lightweight test verification that runs after workers complete implementation but before quality gates.
Designed for fast feedback without the overhead of full arc Phase 7.7 testing.

## Overview

```
Phase 3.5: Commit/Merge Broker (patches applied)
    |
Phase 3.6: Mini Test Phase (lightweight verification)  ← NEW
    |   - Scope detection (current branch diff)
    |   - Unit test discovery
    |   - Spawn strive-test-runner
    |   - Optional: strive-failure-analyst for RCA
    |
Phase 3.7: Codex Post-monitor Critique
    |
Phase 4: Quality Gates
```

## Step 0: Pre-flight

### Talisman Gate Check

```javascript
const testingConfig = readTalismanSection("testing")
const striveTestEnabled = testingConfig?.strive_test?.enabled ?? true

if (!striveTestEnabled) {
  log("STRIVE-TEST: Disabled via talisman testing.strive_test.enabled")
  // Skip to Phase 3.7
  return
}
```

### Worker Drain Gate

Wait for ALL active workers to complete before running tests. This prevents race conditions where a worker's final commit hasn't been applied yet.

```javascript
// Poll until all workers are idle (no in_progress tasks)
const maxDrainWaitMs = 60_000  // 1 minute max
const drainPollIntervalMs = 5_000
const drainStart = Date.now()

while (Date.now() - drainStart < maxDrainWaitMs) {
  const tasks = TaskList()
  const inProgressTasks = tasks.filter(t => t.status === "in_progress")

  if (inProgressTasks.length === 0) {
    log("STRIVE-TEST: All workers drained, proceeding to test phase")
    break
  }

  log(`STRIVE-TEST: Waiting for ${inProgressTasks.length} workers to drain...`)
  Bash(`sleep ${drainPollIntervalMs / 1000}`)
}

// Final check — if still in_progress tasks, warn but proceed
const finalTasks = TaskList()
const stillInProgress = finalTasks.filter(t => t.status === "in_progress")
if (stillInProgress.length > 0) {
  warn(`STRIVE-TEST: ${stillInProgress.length} workers still active after drain timeout. Proceeding with tests.`)
}
```

## Step 1: Scope Detection

Use `resolveTestScope("")` from testing skill. Empty string means current branch diff (no PR number in strive context).

```javascript
// See testing/references/scope-detection.md for full algorithm
const scopeResult = resolveTestScope("")

// resolveTestScope implementation:
function resolveTestScope(input) {
  // Case 3: Current branch (default for strive)
  const defaultBranch = resolveDefaultBranch()
  const result = Bash(`git diff ${defaultBranch}...HEAD --name-only 2>/dev/null`)
  const files = result.trim().split("\n").filter(Boolean)

  const currentBranch = Bash(`git rev-parse --abbrev-ref HEAD 2>/dev/null`).trim() || "HEAD"

  return {
    files,
    source: "current",
    label: `${currentBranch} vs ${defaultBranch}`
  }
}

// Helper: resolve default branch
function resolveDefaultBranch() {
  const ref = Bash(`git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`)
  if (ref) return ref.trim().replace("refs/remotes/origin/", "")

  for (const candidate of ["main", "master", "trunk", "develop"]) {
    const exists = Bash(`git show-ref --verify --quiet refs/heads/${candidate} 2>/dev/null`)
    if (exists) return candidate
  }

  return "main"
}

const { files: changedFiles, label: scopeLabel } = scopeResult
log(`STRIVE-TEST: Scope resolved: ${scopeLabel} (${changedFiles.length} files)`)
```

### Empty Scope Handling

If no files changed (e.g., on main with no diff), skip the test phase entirely.

```javascript
if (changedFiles.length === 0) {
  log("STRIVE-TEST: No diff detected (empty scope). Skipping test phase.")
  // Proceed to Phase 3.7
  return
}
```

## Step 2: Discover Test Files

Use `discoverUnitTests(changedFiles)` from testing references. Maps changed source files to their test counterparts by convention.

```javascript
// See testing/references/test-discovery.md for full algorithm
function discoverUnitTests(changedFiles) {
  const testFiles = []
  const uncoveredFiles = []

  for (const file of changedFiles) {
    // Skip if file is already a test file
    if (isTestFile(file)) {
      testFiles.push(file)
      continue
    }

    // Try test file conventions
    const conventions = [
      // Python
      file.replace(/\.py$/, '_test.py').replace(/^src\//, 'tests/'),
      file.replace(/\.py$/, '/test_').replace(/\/([^/]+)\.py$/, '/test_$1.py'),
      // JavaScript/TypeScript
      file.replace(/\.(ts|tsx|js|jsx)$/, '.test.$1'),
      file.replace(/\.(ts|tsx|js|jsx)$/, '.spec.$1'),
      file.replace(/^src\//, '__tests__/'),
    ]

    let found = false
    for (const testPath of conventions) {
      if (Bash(`test -f "${testPath}" && echo exists`).includes("exists")) {
        testFiles.push(testPath)
        found = true
        break
      }
    }

    if (!found && !isVendorFile(file)) {
      uncoveredFiles.push(file)
    }
  }

  // Shared utility detection — if changed file is in lib/utils/shared/core, flag for full suite
  const sharedUtilityFiles = changedFiles.filter(f =>
    /^(lib|utils|shared|core)\//.test(f)
  )

  return {
    testFiles: [...new Set(testFiles)],  // Dedupe
    uncoveredFiles,
    sharedUtilityFiles,
    needsFullSuite: sharedUtilityFiles.length > 0
  }
}

function isTestFile(path) {
  return /[_.]test\.(py|ts|tsx|js|jsx)$/.test(path) ||
         /[_.]spec\.(ts|tsx|js|jsx)$/.test(path) ||
         /test_.*\.py$/.test(path)
}

function isVendorFile(path) {
  return /^(node_modules|vendor|dist|build)\//.test(path) ||
         /\.(min|d)\.(js|ts)$/.test(path)
}

const { testFiles, uncoveredFiles, needsFullSuite } = discoverUnitTests(changedFiles)

if (uncoveredFiles.length > 0) {
  log(`STRIVE-TEST: ${uncoveredFiles.length} files have no test coverage: ${uncoveredFiles.slice(0, 3).join(", ")}${uncoveredFiles.length > 3 ? "..." : ""}`)
}
```

### Skip Condition

If no test files found for changed files, skip the unit test tier.

```javascript
if (testFiles.length === 0 && !needsFullSuite) {
  log("STRIVE-TEST: No test files found for changed files. Skipping unit test tier.")
  // Proceed to Phase 3.7
  return
}
```

## Step 3: Spawn Unit Test Runner

Create a test task and spawn the unit test runner on the existing strive team.

### Task Creation

```javascript
const testTaskId = TaskCreate({
  subject: "Run unit tests for changed files",
  description: `Execute unit tests for diff-scoped files.

Scope: ${scopeLabel}
Test files: ${testFiles.slice(0, 10).join(", ")}${testFiles.length > 10 ? ` (+${testFiles.length - 10} more)` : ""}
${needsFullSuite ? "\nNOTE: Shared utilities changed — running FULL unit suite." : ""}

Output: Write results to tmp/work/${timestamp}/test-results-unit.md`,
  activeForm: "Running unit tests",
  metadata: {
    phase: "3.6",
    test_scope: scopeLabel,
    test_file_count: testFiles.length,
    needs_full_suite: needsFullSuite
  }
})
```

### Spawn Unit Test Runner

Spawn the existing `unit-test-runner` agent on the existing strive team. The runner inherits the team context and writes results to the work directory.

```javascript
// Build test command based on framework
const testCommand = needsFullSuite
  ? "npm test -- --verbose"  // or pytest, etc.
  : `npx vitest run ${testFiles.join(" ")} --reporter=verbose`

// Spawn test runner with pipefail warning
const spawnResult = Agent({
  name: "unit-test-runner",  // Uses existing agents/testing/unit-test-runner.md
  team_name: teamName,  // Use existing strive team
  prompt: `You are a lightweight unit test runner for the strive workflow.

## Mission
Run unit tests for the changed files and report results.

## Scope
- Files changed: ${changedFiles.length}
- Test files to run: ${testFiles.length}
- Scope label: ${scopeLabel}
${needsFullSuite ? "- NOTE: Shared utilities changed — running FULL unit suite" : ""}

## Test Files
${testFiles.join("\n")}

## Output
Write results to: tmp/work/${timestamp}/test-results-unit.md

Use the format from testing/references/test-report-template.md.

## Important
- Run tests with non-interactive flags
- Capture output (max 500 lines)
- Parse: pass/fail/skip counts
- Write structured Markdown report
- Include the SEAL marker: <!-- SEAL: unit-test-complete -->

When done, report summary to the team lead via SendMessage.`,
  model: "sonnet",
  maxTurns: 25
})

// Note: Agent tool doesn't return a result directly — monitor via TaskList
log(`STRIVE-TEST: Spawned strive-test-runner for ${testFiles.length} test files`)
```

### Monitor Test Runner

Wait for the test runner to complete with a timeout.

```javascript
const testTimeoutMs = 180_000  // 3 minutes
const testPollIntervalMs = 10_000
const testStart = Date.now()

while (Date.now() - testStart < testTimeoutMs) {
  const testTask = TaskGet(testTaskId)
  if (testTask.status === "completed") {
    log("STRIVE-TEST: Test runner completed")
    break
  }
  Bash(`sleep ${testPollIntervalMs / 1000}`)
}

// Timeout check
const finalTestTask = TaskGet(testTaskId)
if (finalTestTask.status !== "completed") {
  warn("STRIVE-TEST: Test runner timed out after 3 minutes. Proceeding without test results.")
  TaskUpdate({ taskId: testTaskId, status: "completed", metadata: { timed_out: true } })
}
```

## Step 4: Handle Failures

Read test results and spawn failure analyst if needed. Non-blocking: proceed to Phase 3.7 regardless of test outcome.

### Read Test Results

```javascript
let testResults = null
try {
  const resultsPath = `tmp/work/${timestamp}/test-results-unit.md`
  const resultsContent = Read(resultsPath)
  testResults = parseTestResults(resultsContent)
} catch (e) {
  warn(`STRIVE-TEST: Could not read test results: ${e.message}`)
}

function parseTestResults(content) {
  // Extract pass/fail counts from markdown
  const testsMatch = content.match(/Tests: (\d+) total, (\d+) passed, (\d+) failed/)
  if (!testsMatch) return null

  return {
    total: parseInt(testsMatch[1], 10),
    passed: parseInt(testsMatch[2], 10),
    failed: parseInt(testsMatch[3], 10),
    raw: content
  }
}
```

### Failure Analysis Trigger

If 3 or more failures detected, spawn `strive-failure-analyst` for root cause analysis.

```javascript
const FAILURE_ANALYSIS_THRESHOLD = 3

if (testResults && testResults.failed >= FAILURE_ANALYSIS_THRESHOLD) {
  log(`STRIVE-TEST: ${testResults.failed} failures detected. Spawning failure analyst for RCA.`)

  const analysisTaskId = TaskCreate({
    subject: "Analyze test failures (RCA)",
    description: `Root cause analysis for ${testResults.failed} test failures.

Test results: tmp/work/${timestamp}/test-results-unit.md

Produce:
1. Root cause category for each failure
2. Proposed fix with confidence level
3. Files to modify

Output: tmp/work/${timestamp}/test-failure-analysis.md`,
    activeForm: "Analyzing test failures",
    metadata: {
      phase: "3.6",
      failure_count: testResults.failed
    }
  })

  Agent({
    name: "test-failure-analyst",  // Uses existing agents/testing/test-failure-analyst.md
    team_name: teamName,
    prompt: `You are a test failure analyst for the strive workflow.

## Mission
Analyze the ${testResults.failed} test failures and produce root cause analysis.

## Test Results
Read: tmp/work/${timestamp}/test-results-unit.md

## Output
Write analysis to: tmp/work/${timestamp}/test-failure-analysis.md

Use the format from agents/testing/test-failure-analyst.md:
- Root cause category
- Log attribution
- Proposed fix
- Confidence level
- Files to modify

## Important
- This is advisory only — do NOT modify code
- Read source files to understand context
- 3-minute deadline
- Report findings to team lead when done`,
    model: "inherit",  // Inherits from team lead (Opus for analysis)
    maxTurns: 15
  })
}
```

### Create Fix Task for Workers

If failures are detected, create a fix task that workers can claim in the next wave or a follow-up strive session.

```javascript
if (testResults && testResults.failed > 0) {
  const fixTaskId = TaskCreate({
    subject: "Fix unit test failures",
    description: `${testResults.failed} unit test(s) are failing.

## Test Results
See: tmp/work/${timestamp}/test-results-unit.md

## Analysis (if available)
See: tmp/work/${timestamp}/test-failure-analysis.md

## Tasks
1. Read the test results and analysis
2. Identify the root cause
3. Implement the fix
4. Verify tests pass locally
5. Submit patch via commit broker

## Files to Check
${uncoveredFiles.length > 0 ? `Uncovered implementation files: ${uncoveredFiles.slice(0, 5).join(", ")}` : "See test results for affected files"}`,
    activeForm: "Fixing test failures",
    metadata: {
      phase: "3.6",
      type: "test-fix",
      failure_count: testResults.failed
    }
  })

  log(`STRIVE-TEST: Created fix task #${fixTaskId} for ${testResults.failed} test failures`)
}
```

### Non-blocking Completion

Regardless of test outcome, proceed to Phase 3.7 (Codex Critique) or Phase 4 (Quality Gates).

```javascript
log(`STRIVE-TEST: Test phase complete. Results: ${testResults?.passed ?? "?"} passed, ${testResults?.failed ?? "?"} failed`)

// Always proceed — test failures are non-blocking
// The fix task allows workers to address failures in a follow-up
```

## Integration Points

### Talisman Configuration

Add to `testing.strive_test` section in talisman.yml:

```yaml
testing:
  strive_test:
    enabled: true                    # Gate for the entire mini test phase
    failure_analysis_threshold: 3    # Failures needed to trigger RCA
    timeout_ms: 180_000              # 3 minutes for test runner
    drain_timeout_ms: 60_000         # 1 minute max for worker drain
```

### Cleanup Integration

Add `unit-test-runner` and `test-failure-analyst` to the cleanup fallback in `phase-6-cleanup.md`:

```javascript
// In the dynamic member discovery fallback array:
const fallbackMembers = [
  ...spawnedWorkerNames,
  "context-scribe",
  "prompt-warden",
  "unit-test-runner",          // NEW: for Phase 3.6 mini test
  "test-failure-analyst"       // NEW: for Phase 3.6 failure analysis
]
```

### Phase Order Update

Update the pipeline overview in `strive/SKILL.md`:

```
Phase 3: Monitor -> TaskList polling, stale detection
    |
Phase 3.5: Commit/Merge Broker -> Apply patches or merge worktree branches
    |
Phase 3.6: Mini Test Phase -> Lightweight unit test verification (NEW)
    |
Phase 3.7: Codex Post-monitor Critique -> Architectural drift detection
    |
Phase 4: Ward Check -> Quality gates + verification checklist
```

## Error Handling

| Error | Recovery |
|-------|----------|
| Worker drain timeout | Warn and proceed — some workers may still be active |
| No test files found | Skip unit tier, log as INFO |
| Test runner timeout | Kill process, mark TIMEOUT, proceed without results |
| No test results file | Warn, proceed without analysis |
| Failure analyst timeout | Attach raw test output instead of RCA |
| All tests pass | No action needed, proceed to Phase 3.7 |

## Anti-Patterns

> **NEVER** block the pipeline on test failures — strive is for implementation, not gate enforcement
> **NEVER** spawn the full testing pipeline (integration/E2E) — that's arc Phase 7.7's job
> **NEVER** wait indefinitely for workers — the drain gate has a 1-minute timeout
> **NEVER** auto-fix test failures — create a fix task for workers to claim

## Summary

Phase 3.6 provides lightweight test verification during the strive workflow:

1. **Pre-flight**: Check talisman gate, wait for worker drain
2. **Scope**: Resolve changed files via current branch diff
3. **Discovery**: Map changed files to test files by convention
4. **Execution**: Spawn strive-test-runner on existing team
5. **Analysis**: Spawn strive-failure-analyst if failures >= threshold
6. **Follow-up**: Create fix task for workers, proceed non-blocking

This catches obvious regressions early without the overhead of full testing tiers.