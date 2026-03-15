# Testing Plan Schema

JSON schema for `tmp/arc/{id}/testing-plan.json`. This file is both the execution plan
and the live checkpoint — plan structure and batch states are combined into a single document.

See [batch-execution.md](batch-execution.md) for the functions that read and write this file.

## Full Schema

```json
{
  "version": 1,
  "arc_id": "arc-1772309747014",
  "created_at": "2026-03-15T12:00:00Z",
  "config": {
    "max_fix_retries": 2,
    "inter_batch_delay_ms": 5000,
    "hard_batch_timeout_ms": 240000,
    "max_batch_iterations": 50
  },
  "summary": {
    "total_batches": 5,
    "completed": 0,
    "failed": 0,
    "skipped": 0
  },
  "batches": [
    {
      "id": 0,
      "type": "unit",
      "files": ["tests/foo.test.ts", "tests/bar.test.ts"],
      "prompt_context": "Run unit tests for changed auth module files.",
      "expected_behavior": "All unit assertions pass with no regressions.",
      "pass_criteria": "Exit code 0; no failed assertions.",
      "status": "pending",
      "fix_attempts": 0,
      "started_at": null,
      "completed_at": null,
      "result_path": null,
      "skip_reason": null,
      "estimated_duration_ms": 20000
    }
  ]
}
```

## Field Reference — Top Level

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | integer | yes | Schema version for compatibility checks. Current: `1`. |
| `arc_id` | string | yes | Arc session ID — must match the current arc run. |
| `created_at` | ISO 8601 | yes | When the plan was first generated. Never mutated after creation. |
| `config` | object | yes | Execution parameters resolved from talisman at plan creation time. Includes `max_batch_iterations`. |
| `summary` | object | yes | Aggregate counts updated after each batch completes. |
| `batches` | array | yes | Ordered list of batches. Execution order is the array order. |

## Field Reference — `config`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `max_fix_retries` | integer | yes | Maximum fix loops allowed per failed batch. Default: `2`. |
| `inter_batch_delay_ms` | integer | yes | Pause between batches in milliseconds. Default: `5000`. |
| `hard_batch_timeout_ms` | integer | yes | Hard timeout per batch in milliseconds. Default: `240000` (4 min). |
| `max_batch_iterations` | integer | yes | Safety cap on executor loop iterations. Default: `50`. |

## Field Reference — `summary`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `total_batches` | integer | yes | Total number of batches in the plan. Immutable after creation. |
| `completed` | integer | yes | Batches that reached a terminal state (passed OR failed). Updated after each batch. |
| `failed` | integer | yes | Batches whose final status is `"failed"`. Subset of `completed`. |
| `skipped` | integer | yes | Batches with status `"skipped"`. NOT included in `completed`. |

## Field Reference — `batches[]`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | integer | yes | Zero-based batch index. Unique within the plan. Immutable. |
| `type` | string | yes | Test tier: `"unit"`, `"integration"`, `"e2e"`, `"contract"`, or `"extended"`. |
| `files` | string[] | yes | Test file paths (or route paths for e2e) assigned to this batch. |
| `prompt_context` | string | yes | Context injected into the runner agent prompt. Describes what to test. |
| `expected_behavior` | string | yes | Human-readable description of the expected outcome. |
| `pass_criteria` | string | yes | Machine-interpretable pass condition (exit code, assertion count, etc.). |
| `status` | string | yes | Lifecycle state — see Status Values table below. |
| `fix_attempts` | integer | yes | Number of fix loops executed. `0` if the batch passed on first run. |
| `started_at` | ISO 8601 \| null | yes | When the batch transitioned to `"running"`. `null` if not yet started. |
| `completed_at` | ISO 8601 \| null | yes | When the batch reached a terminal state. `null` until terminal. |
| `result_path` | string \| null | yes | Path to the runner's result file (e.g., `tmp/arc/{id}/test-results-unit-batch-0.md`). `null` until the runner writes it. |
| `skip_reason` | string \| null | yes | Human-readable reason for skipping. `null` unless `status === "skipped"`. |
| `estimated_duration_ms` | integer | yes | Pre-computed estimate: `files.length × avg_duration`. Used for rendering only. |

## Status Values

| Status | Terminal? | Description |
|--------|-----------|-------------|
| `pending` | No | Not yet started. Initial state for all batches. |
| `running` | No | Agent spawned and executing. |
| `fixing` | No | Runner failed; fix agent is applying corrections. |
| `passed` | **Yes** | Runner exited with pass result. Skipped on resume. |
| `failed` | **Yes** | Runner failed and all fix retries exhausted. Skipped on resume. |
| `skipped` | **Yes** | Skipped due to budget exhaustion or explicit skip. |

**Resume rule**: Only `pending` and `running`/`fixing` batches are re-executed on resume.
`running` and `fixing` reset to `pending` before the loop restarts (see batch-execution.md §Resume Logic).

## Status Transition Diagram

```
             ┌─────────────┐
             │   pending   │ ◄─── reset on resume (from running/fixing)
             └──────┬──────┘
                    │ budget OK → TaskCreate + Agent()
                    ▼
             ┌─────────────┐
             │   running   │
             └──────┬──────┘
           pass ◄───┤───► fail (fix_attempts < max)
             │      │              │
             ▼      │              ▼
          ┌──────┐  │       ┌─────────────┐
          │passed│  │       │   fixing    │
          └──────┘  │       └──────┬──────┘
                    │        pass ◄┤──► fail (fix_attempts == max)
                    │              │              │
                    │              ▼              ▼
                    │          ┌──────┐       ┌──────┐
                    │          │passed│       │failed│
                    │          └──────┘       └──────┘
                    │
             budget = 0
                    ▼
             ┌─────────────┐
             │   skipped   │ (skip_reason: "skipped_budget_exhausted")
             └─────────────┘
```

## Example: Partial Completion (After 2 Batches)

```json
{
  "version": 1,
  "arc_id": "arc-1772309747014",
  "created_at": "2026-03-15T12:00:00Z",
  "config": {
    "max_fix_retries": 2,
    "inter_batch_delay_ms": 5000,
    "hard_batch_timeout_ms": 240000,
    "max_batch_iterations": 50
  },
  "summary": {
    "total_batches": 4,
    "completed": 2,
    "failed": 1,
    "skipped": 0
  },
  "batches": [
    {
      "id": 0,
      "type": "unit",
      "files": ["tests/auth.test.ts"],
      "prompt_context": "Run unit tests for auth module.",
      "expected_behavior": "All auth unit tests pass.",
      "pass_criteria": "Exit code 0.",
      "status": "passed",
      "fix_attempts": 0,
      "started_at": "2026-03-15T12:01:00Z",
      "completed_at": "2026-03-15T12:01:18Z",
      "result_path": "tmp/arc/arc-1772309747014/test-results-unit-0.md",
      "skip_reason": null,
      "estimated_duration_ms": 10000
    },
    {
      "id": 1,
      "type": "integration",
      "files": ["tests/integration/auth_flow.test.ts"],
      "prompt_context": "Run integration tests for auth flow.",
      "expected_behavior": "Login and logout flows succeed against real DB.",
      "pass_criteria": "Exit code 0; no fixture errors.",
      "status": "failed",
      "fix_attempts": 2,
      "started_at": "2026-03-15T12:02:00Z",
      "completed_at": "2026-03-15T12:05:45Z",
      "result_path": "tmp/arc/arc-1772309747014/test-results-integration-1.md",
      "skip_reason": null,
      "estimated_duration_ms": 30000
    },
    {
      "id": 2,
      "type": "e2e",
      "files": ["/login", "/dashboard"],
      "prompt_context": "E2E browser test for login and dashboard routes.",
      "expected_behavior": "Pages render without errors; login redirects correctly.",
      "pass_criteria": "No console errors; correct page titles.",
      "status": "pending",
      "fix_attempts": 0,
      "started_at": null,
      "completed_at": null,
      "result_path": null,
      "skip_reason": null,
      "estimated_duration_ms": 120000
    },
    {
      "id": 3,
      "type": "e2e",
      "files": ["/profile"],
      "prompt_context": "E2E browser test for profile route.",
      "expected_behavior": "Profile page renders user data correctly.",
      "pass_criteria": "No console errors; profile data visible.",
      "status": "pending",
      "fix_attempts": 0,
      "started_at": null,
      "completed_at": null,
      "result_path": null,
      "skip_reason": null,
      "estimated_duration_ms": 60000
    }
  ]
}
```

## Invariants

The executor maintains these invariants across all writes:

1. `summary.completed` = count of batches where `status === "passed" || status === "failed"`
2. `summary.failed` ≤ `summary.completed`
3. `summary.skipped` = count of batches where `status === "skipped"`
4. `fix_attempts` ≤ `config.max_fix_retries` for all batches
5. `started_at` is non-null iff `status` is not `"pending"`
6. `completed_at` is non-null iff status is terminal (`passed`, `failed`, `skipped`)
7. `result_path` is non-null iff a runner wrote a result file (may be null even for `failed`)
8. `skip_reason` is non-null iff `status === "skipped"`
