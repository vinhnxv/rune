# Evidence Convention

Canonical directory layout and file schemas for Discipline Engineering evidence artifacts.
All paths are relative to the project root. `{timestamp}` is an ISO-8601 string
(e.g., `20260316T120511`) set once at workflow start and shared across all agents in
that run.

---

## Directory Layout

```
tmp/work/{timestamp}/
├── tasks/               # Task definition files
│   ├── task-1.1.md
│   ├── task-1.2.md
│   └── ...
├── evidence/            # Per-task acceptance-criterion evidence
│   └── {task-id}/
│       ├── AC-1.1.1.md  # One file per criterion (optional detail)
│       └── summary.json # Aggregated evidence record (required)
├── task-review/         # Task-level review outputs from convergence judges
│   └── {task-id}/
│       ├── verdict.md
│       └── corrections.md
└── convergence/         # Cross-task convergence tracking
    ├── round-1.json
    └── final.json
```

### Path Patterns

| Artifact | Path |
|---|---|
| Strive output root | `tmp/work/{timestamp}/` |
| Task definitions | `tmp/work/{timestamp}/tasks/` |
| Task evidence root | `tmp/work/{timestamp}/evidence/{task-id}/` |
| Task review outputs | `tmp/work/{timestamp}/task-review/{task-id}/` |
| Convergence tracking | `tmp/work/{timestamp}/convergence/` |
| Review output root | `tmp/reviews/{timestamp}/` |
| Arc checkpoint root | `tmp/arc/{id}/` |

---

## Evidence Summary JSON Schema

Every task that requires acceptance-criterion verification MUST produce a
`summary.json` file at `tmp/work/{timestamp}/evidence/{task-id}/summary.json`.

### Schema

```json
{
  "task_id": "string",
  "worker": "string",
  "criteria_results": [
    {
      "criterion_id": "AC-1.1.1",
      "result": "PASS|FAIL",
      "evidence_path": "path/to/artifact",
      "timestamp": "ISO8601"
    }
  ],
  "overall": "PASS|FAIL|PARTIAL",
  "timestamp": "ISO8601"
}
```

### Field Definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `task_id` | string | yes | Matches the task ID in `tasks/` directory |
| `worker` | string | yes | Agent/teammate name that produced this evidence |
| `criteria_results` | array | yes | One entry per acceptance criterion |
| `criteria_results[].criterion_id` | string | yes | ID from the plan (e.g., `AC-1.3.2`) |
| `criteria_results[].result` | enum | yes | `PASS` or `FAIL` — no other values |
| `criteria_results[].evidence_path` | string | yes | Relative path to the artifact that proves the criterion |
| `criteria_results[].timestamp` | string | yes | ISO-8601 time the criterion was checked |
| `overall` | enum | yes | `PASS` (all criteria pass), `FAIL` (any hard fail), `PARTIAL` (some passed) |
| `timestamp` | string | yes | ISO-8601 time the summary was written |

### Validity Rules

1. `overall` MUST be derived from `criteria_results` — never set it manually.
2. `overall = PASS` requires every `criteria_results[].result` to be `PASS`.
3. `overall = PARTIAL` means at least one passed and at least one failed.
4. `overall = FAIL` means all criteria failed (or the file could not be evaluated).
5. `evidence_path` MUST point to a file that exists on disk at verification time.

---

## Task Review Directory

After a task's evidence is gathered, a convergence judge writes to:

```
tmp/work/{timestamp}/task-review/{task-id}/
├── verdict.md      # ACCEPT | REJECT | NEEDS_REVISION with rationale
└── corrections.md  # Required corrections (if REJECT or NEEDS_REVISION)
```

### verdict.md Format

```markdown
# Task Review: {task-id}

**Verdict**: ACCEPT | REJECT | NEEDS_REVISION
**Reviewer**: {agent-name}
**Timestamp**: {ISO8601}

## Rationale

{explanation tied directly to acceptance criteria}

## Criterion Results

| Criterion | Status | Evidence |
|---|---|---|
| AC-1.1.1 | PASS | tmp/work/.../evidence/task-1.1/AC-1.1.1.md |
```

---

## Convergence Tracking Directory

Cross-task convergence state is written to `tmp/work/{timestamp}/convergence/`:

```
convergence/
├── round-1.json    # After first convergence pass
├── round-2.json    # After second pass (if needed)
└── final.json      # Terminal convergence state
```

### round-N.json Schema

```json
{
  "round": 1,
  "timestamp": "ISO8601",
  "tasks": {
    "task-1.1": "CONVERGED",
    "task-1.2": "DIVERGED",
    "task-1.3": "PENDING"
  },
  "overall_convergence": "PARTIAL"
}
```

`overall_convergence` is `FULL` when all tasks are `CONVERGED`, `PARTIAL` when
some remain, or `FAILED` when divergence cannot be resolved.

---

## Alignment with Existing Patterns

| Context | Existing Pattern | Discipline Extension |
|---|---|---|
| Strive worker output | `tmp/work/{timestamp}/` | Same root; tasks + evidence sub-dirs added |
| Review output | `tmp/reviews/{timestamp}/` | Unchanged; discipline review uses `task-review/` |
| Arc checkpoints | `tmp/arc/{id}/` | Unchanged |

Do NOT write evidence files outside `tmp/`. Do NOT use session-scoped paths
(e.g., `~/.claude/`) for evidence — those are for team coordination only.
