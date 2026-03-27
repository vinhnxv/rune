# Phase 7.7.6: Browser Test Fix (Fix Browser E2E Failures)

Reads browser test failures from Phase 7.7.5, maps failed routes to source files,
and spawns fixer agents to apply targeted fixes. Part of the browser test convergence
loop: `browser_test` → `browser_test_fix` → `verify_browser_test`.

**Team**: `arc-browser-fix-{id}` (1+ rune-smith agents, one per file group)
**Tools**: Read, Write, Edit, Glob, Grep, Bash, Agent, TeamCreate, TaskCreate, SendMessage
**Duration**: Max 15 minutes

**Inputs**: `tmp/arc/{id}/browser-test-failures.json` (from Phase 7.7.5)
**Outputs**: `tmp/arc/{id}/browser-fix-report.md`

## Entry Guard

```javascript
// ═══════════════════════════════════════════════════════
// ENTRY GUARD
// ═══════════════════════════════════════════════════════

// Skip if browser_test was skipped
if (checkpoint.phases.browser_test.status === "skipped") {
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
  return
}

// Read failures from browser test phase
const id = checkpoint.id
const round = checkpoint.browser_test_convergence.round
let failures
try {
  failures = JSON.parse(Read(`tmp/arc/${id}/browser-test-failures.json`))
} catch (e) {
  warn("Phase 7.7.6: browser-test-failures.json not found — skipping fix phase")
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped" })
  return
}

// Skip if no failures (all tests passed)
if (!failures.failures || failures.failures.length === 0) {
  updateCheckpoint({ phase: "browser_test_fix", status: "skipped",
    fixed_count: 0, skip_reason: "no_failures" })
  return
}

updateCheckpoint({ phase: "browser_test_fix", status: "in_progress" })
```

## STEP 1: Map Failures to Source Files

```javascript
// ═══════════════════════════════════════════════════════
// STEP 1: MAP FAILURES TO SOURCE FILES
// ═══════════════════════════════════════════════════════

// Reuse mapRouteToSourceFiles() from testing/references/scope-detection.md
// Groups each failed route to the component/page files that render it
const failuresByFile = {}
for (const failure of failures.failures) {
  const sourceFiles = mapRouteToSourceFiles(failure.route)
  for (const file of sourceFiles) {
    if (!failuresByFile[file]) failuresByFile[file] = []
    failuresByFile[file].push(failure)
  }
}

// Cap fixers — same pattern as inspect-fix
// readTalismanSection: "testing"
const testingConfig = readTalismanSection("testing") ?? {}
const browserTestConfig = testingConfig?.browser_test ?? {}
const maxFixers = browserTestConfig.max_fixers ?? 5

const fileGroups = Object.entries(failuresByFile).slice(0, maxFixers)

if (fileGroups.length === 0) {
  warn("Phase 7.7.6: No source files mapped from failed routes — skipping fix phase")
  updateCheckpoint({ phase: "browser_test_fix", status: "completed",
    fixed_count: 0, skip_reason: "no_source_mapping" })
  return
}
```

## STEP 2: Create Team and Spawn Fixers

```javascript
// ═══════════════════════════════════════════════════════
// STEP 2: CREATE TEAM & SPAWN FIXERS
// ═══════════════════════════════════════════════════════

const teamName = `arc-browser-fix-${id}`
TeamCreate({ team_name: teamName })
updateCheckpoint({ phase: "browser_test_fix", team_name: teamName })

const fixerNames = []
let fixerIdx = 0

for (const [file, routeFailures] of fileGroups) {
  const fixerName = `browser-fixer-${fixerIdx++}`
  fixerNames.push(fixerName)

  const failureDetails = routeFailures.map(f =>
    `Route: ${f.route}\nErrors: ${(f.errors || []).join('; ')}\nScreenshot: ${f.screenshot || 'none'}`
  ).join('\n---\n')

  TaskCreate({
    subject: `Fix browser test failures in ${file}`,
    description: `Fix browser E2E test failures for file: ${file}\n\n${failureDetails}`
  })

  Agent({
    team_name: teamName,
    name: fixerName,
    subagent_type: "rune:work:rune-smith",
    prompt: `You are ${fixerName}. Fix browser E2E test failures in: ${file}

## Failure Details
${failureDetails}

## Instructions
1. Read the source file(s) and understand the current implementation
2. Analyze each failure — focus on the error messages and route behavior
3. Apply targeted fixes to resolve the failures
4. Do NOT re-run browser tests (verification is a separate phase)
5. Write your fix status to: tmp/arc/${id}/browser-fix-${fixerIdx - 1}.json
   Format: { "file": "${file}", "fixes": [{ "route": "/path", "status": "fixed"|"skipped", "description": "what was changed" }] }

Claim your task via TaskList + TaskUpdate (status: completed).`
  })
}

// Monitor completion
waitForCompletion(teamName, fileGroups.length, { timeout: 900_000 })
```

## STEP 3: Aggregate Fix Results and Commit

```javascript
// ═══════════════════════════════════════════════════════
// STEP 3: AGGREGATE FIX RESULTS & COMMIT
// ═══════════════════════════════════════════════════════

const allFixes = []
for (let i = 0; i < fileGroups.length; i++) {
  try {
    const fixResult = JSON.parse(Read(`tmp/arc/${id}/browser-fix-${i}.json`))
    allFixes.push(fixResult)
  } catch (e) { warn(`Failed to read fixer ${i} results: ${e.message}`) }
}

const fixedCount = allFixes.reduce((sum, r) =>
  sum + (r.fixes || []).filter(f => f.status === "fixed").length, 0)
const skippedCount = allFixes.reduce((sum, r) =>
  sum + (r.fixes || []).filter(f => f.status === "skipped").length, 0)

// Generate resolution report
const reportLines = [
  `# Browser Test Fix Report — Round ${round + 1}`,
  '',
  `| Metric | Count |`,
  `|--------|-------|`,
  `| Total failures | ${failures.failures.length} |`,
  `| Fixes applied | ${fixedCount} |`,
  `| Fixes skipped | ${skippedCount} |`,
  '',
]

for (const result of allFixes) {
  reportLines.push(`## ${result.file}`)
  for (const fix of (result.fixes || [])) {
    reportLines.push(`- **${fix.route}**: status: ${fix.status} — ${fix.description || 'no description'}`)
  }
  reportLines.push('')
}

Write(`tmp/arc/${id}/browser-fix-report.md`, reportLines.join('\n'))

// Atomic commit for fixes (if any files changed)
const diffCheck = Bash("git diff --name-only 2>/dev/null").trim()
if (diffCheck) {
  Bash("git add -u")  // SEC-001 FIX: Use -u (tracked files only) instead of -A to avoid staging secrets
  // SEC-011: Write commit message to temp file
  Write(`tmp/arc/${id}/browser-fix-commit-msg.txt`,
    `fix(browser): resolve E2E test failures [round ${round + 1}]`)
  Bash(`git commit -F "tmp/arc/${id}/browser-fix-commit-msg.txt"`)
}

// Cleanup team — standard 5-component cleanup pattern
// (see arc-phase-cleanup.md for the canonical pattern)
```

## Checkpoint Update

```javascript
updateCheckpoint({
  phase: "browser_test_fix", status: "completed",
  artifact: `tmp/arc/${id}/browser-fix-report.md`,
  artifact_hash: sha256(Read(`tmp/arc/${id}/browser-fix-report.md`)),
  team_name: teamName,
  fixed_count: fixedCount,
  skipped_count: skippedCount,
})
```

## Crash Recovery

If the phase crashes mid-execution:
- Team `arc-browser-fix-{id}` may be orphaned → `arc-phase-cleanup.md` handles via `PHASE_PREFIX_MAP`
- Partial fix results in `tmp/arc/{id}/browser-fix-*.json` are safe to re-read on resume
- Uncommitted fixes are lost on crash — fixer agents re-run from scratch on resume

## References

- [arc-phase-inspect-fix.md](arc-phase-inspect-fix.md) — analogous pattern (gap-fixer agents grouped by file)
- [scope-detection.md](../../testing/references/scope-detection.md) — `mapRouteToSourceFiles()`
- [arc-phase-constants.md](arc-phase-constants.md) — `BROWSER_TEST_CYCLE_BUDGET`
