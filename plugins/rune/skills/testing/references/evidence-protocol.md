# Evidence Protocol — Batch Evidence Records, Fix Audit Trail & Failure Journal

> Defines the per-batch evidence record format, fix loop audit trail, and
> cumulative failure journal. Produces auditable proof of what ran, when,
> what failed, why, and what was fixed.

## File Hierarchy

```
tmp/arc/{id}/
├── evidence/
│   ├── batch-1-evidence.json
│   ├── batch-2-evidence.json
│   └── ...
├── failure-journal.md          # Cumulative markdown across all batches
└── testing-plan.json           # Checkpoint (existing — batch-execution.md)
```

## Batch Evidence Record Format

Written by the batch executor after each batch completes (pass or fail).
Path: `tmp/arc/{id}/evidence/batch-{N}-evidence.json`

```json
{
  "batch_id": 1,
  "type": "unit",
  "timing": {
    "started_at": "2026-03-15T10:00:00Z",
    "completed_at": "2026-03-15T10:02:45Z",
    "duration_ms": 165000
  },
  "scope": {
    "files_tested": ["tests/test_auth.py", "tests/test_user.py"],
    "prompt_context": "Unit testing batch — verify function-level correctness for 2 test file(s)...",
    "pass_criteria": "0 test failures. All assertions pass. No uncaught exceptions."
  },
  "results": {
    "pass_count": 15,
    "fail_count": 2,
    "skip_count": 0,
    "all_passed": false
  },
  "failures": [
    {
      "file": "tests/test_auth.py",
      "line": 42,
      "test_name": "test_login_expired_token",
      "assertion_message": "Expected 401, got 200",
      "error_type": "assertion",
      "stack_trace": "...(first 15 lines)...",
      "root_cause_hint": "Token expiry check bypassed when refresh_token is present"
    }
  ],
  "fix_loop": {
    "retries": 1,
    "fixed_files": ["src/auth/token.py"],
    "fixes": [
      {
        "retry": 1,
        "timestamp": "2026-03-15T10:03:00Z",
        "file": "src/auth/token.py",
        "description": "Add expiry check before refresh token fallback",
        "diff_summary": "+3 -1 in validate_token()",
        "failure_addressed": {
          "test_file": "tests/test_auth.py",
          "test_name": "test_login_expired_token",
          "original_error": "Expected 401, got 200"
        },
        "rerun_result": "PASSED"
      }
    ]
  },
  "coverage": {
    "files_executed": 2,
    "files_total": 2
  }
}
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `batch_id` | number | YES | Batch sequence number from testing plan |
| `type` | string | YES | Test tier: `unit`, `integration`, `e2e`, `contract`, `extended` |
| `timing.started_at` | ISO 8601 | YES | Batch execution start time |
| `timing.completed_at` | ISO 8601 | YES | Batch execution end time (after all retries) |
| `timing.duration_ms` | number | YES | Total elapsed time including fix loops |
| `scope.files_tested` | string[] | YES | List of test files or routes executed |
| `scope.prompt_context` | string | YES | Context string given to the runner agent |
| `scope.pass_criteria` | string | YES | Pass criteria for this batch |
| `results.pass_count` | number | YES | Number of passing tests |
| `results.fail_count` | number | YES | Number of failing tests |
| `results.skip_count` | number | YES | Number of skipped tests |
| `results.all_passed` | boolean | YES | True if zero failures after all retries |
| `failures` | array | NO | Only present when `fail_count > 0` |
| `failures[].file` | string | YES | Test file containing the failure |
| `failures[].line` | number | NO | Line number of the failing assertion |
| `failures[].test_name` | string | YES | Name of the failing test function |
| `failures[].assertion_message` | string | YES | Human-readable assertion failure |
| `failures[].error_type` | string | YES | `assertion`, `timeout`, `crash`, `import_error`, `fixture_error` |
| `failures[].stack_trace` | string | NO | First 15 lines of stack trace |
| `failures[].root_cause_hint` | string | NO | Agent-generated root cause hypothesis |
| `fix_loop.retries` | number | YES | Number of fix attempts (0 if first-pass success) |
| `fix_loop.fixed_files` | string[] | YES | Source files modified during fix loop |
| `fix_loop.fixes` | array | YES | Per-fix detail records (see Fix Audit Trail) |
| `coverage.files_executed` | number | YES | Files that actually ran |
| `coverage.files_total` | number | YES | Files in the batch scope |

## Write Algorithm

```javascript
function writeBatchEvidence(id, batch, result, fixes) {
  const evidenceDir = `tmp/arc/${id}/evidence`
  Bash(`mkdir -p "${evidenceDir}"`)

  const evidence = {
    batch_id: batch.id,
    type: batch.type,
    timing: {
      started_at: batch.started_at,
      completed_at: batch.completed_at ?? new Date().toISOString(),
      duration_ms: batch.completed_at
        ? new Date(batch.completed_at).getTime() - new Date(batch.started_at).getTime()
        : Date.now() - new Date(batch.started_at).getTime()
    },
    scope: {
      files_tested: batch.files,
      prompt_context: batch.prompt_context ?? "",
      pass_criteria: batch.pass_criteria ?? ""
    },
    results: {
      pass_count: result?.pass_count ?? 0,
      fail_count: result?.fail_count ?? 0,
      skip_count: result?.skip_count ?? 0,
      all_passed: batch.status === "passed"
    },
    failures: (result?.failures ?? []).map(f => ({
      file: f.file,
      line: f.line ?? null,
      test_name: f.test_name ?? f.name ?? "unknown",
      assertion_message: f.message ?? f.assertion_message ?? "",
      error_type: f.error_type ?? "assertion",
      stack_trace: (f.stack_trace ?? "").split('\n').slice(0, 15).join('\n'),
      root_cause_hint: f.root_cause_hint ?? null
    })),
    fix_loop: {
      retries: fixes.length,
      fixed_files: [...new Set(fixes.map(f => f.file))],
      fixes: fixes
    },
    coverage: {
      files_executed: result?.files_executed ?? batch.files.length,
      files_total: batch.files.length
    }
  }

  Write(`${evidenceDir}/batch-${batch.id}-evidence.json`, JSON.stringify(evidence, null, 2))
  return evidence
}
```

## Fix Audit Trail

Each fix attempt is recorded via `recordFix()` during the fix loop.

```javascript
function recordFix(retryNumber, fixDetails) {
  return {
    retry: retryNumber,
    timestamp: new Date().toISOString(),
    file: fixDetails.file,
    description: fixDetails.description,
    diff_summary: fixDetails.diff_summary ?? "",
    failure_addressed: {
      test_file: fixDetails.test_file,
      test_name: fixDetails.test_name,
      original_error: fixDetails.original_error
    },
    rerun_result: null  // Updated by updateFixResult()
  }
}

function updateFixResult(fix, passed) {
  fix.rerun_result = passed ? "PASSED" : "STILL_FAILING"
  return fix
}
```

## Failure Journal

Cumulative markdown written after all batches complete.
Path: `tmp/arc/{id}/failure-journal.md`

```javascript
function writeFailureJournal(id, evidenceRecords) {
  const failedBatches = evidenceRecords.filter(e => !e.results.all_passed)

  if (failedBatches.length === 0) {
    Write(`tmp/arc/${id}/failure-journal.md`,
      "# Failure Journal\n\nNo failures detected. All batches passed.\n")
    return
  }

  const lines = [
    "# Failure Journal",
    "",
    `**Generated**: ${new Date().toISOString()}`,
    `**Failed batches**: ${failedBatches.length}`,
    `**Total failures**: ${failedBatches.reduce((s, e) => s + e.results.fail_count, 0)}`,
    ""
  ]

  for (const evidence of failedBatches) {
    lines.push(`## Batch ${evidence.batch_id} (${evidence.type})`)
    lines.push("")
    lines.push(`- **Duration**: ${Math.round(evidence.timing.duration_ms / 1000)}s`)
    lines.push(`- **Retries**: ${evidence.fix_loop.retries}`)
    lines.push(`- **Final status**: ${evidence.results.all_passed ? "PASSED (after fix)" : "FAILED"}`)
    lines.push("")

    // Failure details
    lines.push("### Failures")
    lines.push("")
    for (const failure of evidence.failures) {
      lines.push(`#### ${failure.test_name}`)
      lines.push(`- **File**: ${failure.file}${failure.line ? `:${failure.line}` : ""}`)
      lines.push(`- **Error type**: ${failure.error_type}`)
      lines.push(`- **Message**: ${failure.assertion_message}`)
      if (failure.root_cause_hint) {
        lines.push(`- **Root cause hint**: ${failure.root_cause_hint}`)
      }
      if (failure.stack_trace) {
        lines.push("```")
        lines.push(failure.stack_trace)
        lines.push("```")
      }
      lines.push("")
    }

    // Fix loop history
    if (evidence.fix_loop.retries > 0) {
      lines.push("### Fix Loop History")
      lines.push("")
      lines.push("| Retry | Timestamp | File | Description | Diff | Result |")
      lines.push("|-------|-----------|------|-------------|------|--------|")
      for (const fix of evidence.fix_loop.fixes) {
        lines.push(
          `| ${fix.retry} | ${fix.timestamp} | ${fix.file} | ${fix.description} | ${fix.diff_summary} | ${fix.rerun_result ?? "PENDING"} |`
        )
      }
      lines.push("")
    }
  }

  Write(`tmp/arc/${id}/failure-journal.md`, lines.join('\n'))
}
```

## Integration with Batch Executor

The evidence protocol hooks into `executeBatchLoop()` from [batch-execution.md](batch-execution.md):

```javascript
// After batch execution completes (step 8 in batch-execution.md):
const fixes = []  // Populated during fix loop via recordFix()

// ... during fix loop:
const fixRecord = recordFix(fixAttempts, {
  file: modifiedFile,
  description: changeDescription,
  diff_summary: diffSummary,
  test_file: failedTestFile,
  test_name: failedTestName,
  original_error: originalError
})
// ... after rerun:
updateFixResult(fixRecord, rerunPassed)
fixes.push(fixRecord)

// ... after batch final status:
writeBatchEvidence(id, batch, result, fixes)

// ... after ALL batches complete (finalization turn):
const allEvidence = []
for (const batch of plan.batches) {
  const evidencePath = `tmp/arc/${id}/evidence/batch-${batch.id}-evidence.json`
  if (exists(evidencePath)) {
    allEvidence.push(JSON.parse(Read(evidencePath)))
  }
}
writeFailureJournal(id, allEvidence)
```

## Failure Identification

Each failure is identified by the tuple `(test_name, error_type, assertion_first_line)`.
This tuple is stored in plain text in the evidence record and can be compared directly
across runs for deduplication, regression detection, and flaky analysis — no hashing needed
at the current scale (<100 failures per run).

## Talisman Configuration

No new talisman keys required. Evidence writes use existing `testing.batch.*` config.
The `testing.history.*` keys (from [history-protocol.md](history-protocol.md)) govern
history persistence which now includes batch-level data.
