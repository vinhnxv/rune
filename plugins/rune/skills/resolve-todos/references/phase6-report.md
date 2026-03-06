# Phase 6: Report & Commit

Aggregates verdict and fix results into a summary report.

```javascript
// Aggregate results from verdict and fix report files
const verdictFiles = Glob(`tmp/resolve-todos-${timestamp}/verdicts/*.json`)
const fixFiles = Glob(`tmp/resolve-todos-${timestamp}/fixes/*.json`)

let validCount = 0, falsePositiveCount = 0, alreadyFixedCount = 0
let needsClarificationCount = 0, partialCount = 0, duplicateCount = 0, deferredCount = 0
for (const vf of verdictFiles) {
  const data = JSON.parse(Read(vf))
  for (const v of data.verdicts ?? []) {
    if (v.verdict === "VALID") validCount++
    else if (v.verdict === "FALSE_POSITIVE") falsePositiveCount++
    else if (v.verdict === "ALREADY_FIXED") alreadyFixedCount++
    else if (v.verdict === "NEEDS_CLARIFICATION") needsClarificationCount++
    else if (v.verdict === "PARTIAL") partialCount++
    else if (v.verdict === "DUPLICATE") duplicateCount++
    else if (v.verdict === "DEFERRED") deferredCount++
  }
}

let fixedCount = 0, failedCount = 0, skippedCount = 0
for (const ff of fixFiles) {
  const data = JSON.parse(Read(ff))
  for (const f of data.fixes ?? []) {
    if (f.status === "FIXED") fixedCount++
    else if (f.status === "FAILED") failedCount++
    else if (f.status === "SKIPPED") skippedCount++
  }
}

const summary = `
# TODO Resolution Summary

| Category | Count |
|----------|-------|
| Input TODOs | ${todos.length} |
| Verified VALID | ${validCount} |
| Successfully FIXED | ${fixedCount} |
| FALSE POSITIVE | ${falsePositiveCount} |
| ALREADY FIXED | ${alreadyFixedCount} |
| FAILED to fix | ${failedCount} |
| SKIPPED | ${skippedCount} |
| NEEDS CLARIFICATION | ${needsClarificationCount} |
`
Write(`tmp/resolve-todos-${timestamp}/summary.md`, summary)
```
