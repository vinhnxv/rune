# Task File Format — Discipline-Aware Task Definitions

Canonical schema for task definition files written to `tmp/work/{timestamp}/tasks/`.
These files bridge plan acceptance criteria to worker evidence production.

Source: Discipline Engineering v2.3.0, Sections 5.1–5.3.

---

## File Location

```
tmp/work/{timestamp}/tasks/task-{id}.md
```

Where `{id}` matches the plan task ID (e.g., `1.1`, `2.3`). One file per task.

---

## YAML Frontmatter Schema

Every task file begins with YAML frontmatter containing machine-readable metadata.

```yaml
---
task_id: "1.1"                        # Plan task ID (e.g., "1.1", "2.3")
plan_file: "plans/my-feature-plan.md" # Relative path to source plan
plan_section: "### Task 1.1"          # Section heading in plan this task maps to
status: PENDING                       # Task lifecycle status (see Status Enum)
assigned_to: null                     # Worker name when claimed (e.g., "rune-smith-1")
iteration: 0                          # Re-attempt count (0 = first attempt)
risk_tier: 1                          # 0=Grace, 1=Ember, 2=Rune, 3=Elden
proof_count: 3                        # Number of acceptance criteria to verify
created_at: "2026-03-16T12:05:11Z"    # ISO-8601 creation timestamp
updated_at: "2026-03-16T12:05:11Z"    # ISO-8601 last update timestamp
completed_at: null                    # ISO-8601 completion timestamp (null until DONE)
---
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `task_id` | string | yes | Matches plan `### Task X.Y` heading ID |
| `plan_file` | string | yes | Relative path to the plan that defines this task |
| `plan_section` | string | yes | Markdown heading in plan where task is specified |
| `status` | enum | yes | Current lifecycle status (see Status Enum below) |
| `assigned_to` | string\|null | yes | Worker agent name, null when unassigned |
| `iteration` | integer | yes | Starts at 0, incremented on each re-attempt after FAILED |
| `risk_tier` | integer | no | Risk classification: 0 (Grace), 1 (Ember), 2 (Rune), 3 (Elden) |
| `proof_count` | integer | no | Count of acceptance criteria requiring verification |
| `created_at` | string | yes | ISO-8601 timestamp of task file creation |
| `updated_at` | string | yes | ISO-8601 timestamp of last status change |
| `completed_at` | string\|null | yes | ISO-8601 timestamp when status reached DONE or VERIFIED |

---

## Status Enum

Task status follows a strict state machine. Transitions are unidirectional except for
the FAILED → PENDING retry path.

```
PENDING → IN_PROGRESS → DONE → VERIFIED
                ↓                    ↓
              FAILED              (terminal)
                ↓
             PENDING (retry: iteration++)
```

| Status | Meaning |
|--------|---------|
| `PENDING` | Task created, not yet claimed by a worker |
| `IN_PROGRESS` | Worker has claimed and is actively working on the task |
| `DONE` | Worker reports completion with evidence artifacts |
| `VERIFIED` | System-level proof execution confirms all criteria pass |
| `FAILED` | Proof execution found at least one criterion failing |

### Transition Rules

- `PENDING → IN_PROGRESS`: Worker claims task via TaskUpdate (sets `assigned_to`)
- `IN_PROGRESS → DONE`: Worker produces evidence at `tmp/work/{timestamp}/evidence/{task-id}/summary.json`
- `DONE → VERIFIED`: `validate-discipline-proofs.sh` hook confirms all proofs pass
- `DONE → FAILED`: `validate-discipline-proofs.sh` hook finds at least one proof failure
- `FAILED → PENDING`: Orchestrator re-enqueues task with `iteration++` (max retries from talisman)
- `IN_PROGRESS → FAILED`: Worker encounters unrecoverable error, writes failure evidence

---

## Body Sections

After the YAML frontmatter, the task file body uses structured Markdown sections.

### Source

The original task description extracted from the plan. Preserves the plan's wording
verbatim to prevent drift between specification and execution.

```markdown
## Source

Create the User model with email validation, password hashing via bcrypt,
and timestamps. Must support soft-delete via `deleted_at` column.
```

### Acceptance Criteria

Machine-verifiable criteria extracted from the plan. Each criterion has a proof type
and verification arguments. These are the contract the worker must satisfy.

```markdown
## Acceptance Criteria

- id: AC-1.1.1
  text: "User model file exists at src/models/user.ts"
  proof: file_exists
  args: { target: "src/models/user.ts" }

- id: AC-1.1.2
  text: "User model exports a class with email field"
  proof: pattern_matches
  args: { target: "src/models/user.ts", pattern: "email.*string" }

- id: AC-1.1.3
  text: "Password hashing uses bcrypt"
  proof: pattern_matches
  args: { target: "src/models/user.ts", pattern: "bcrypt\\.hash" }
```

**Proof type reference**: See [proof-schema.md](../../discipline/references/proof-schema.md)
for the full 8-type taxonomy, tool mappings, and reliability ratings.

### File Targets

Files and directories the worker is expected to create or modify. Used by
`validate-strive-worker-paths.sh` (SEC-STRIVE-001) for write-scope enforcement.

```markdown
## File Targets

- src/models/user.ts (create)
- src/models/index.ts (modify)
- tests/models/user.test.ts (create)
```

### Context

Additional context from the plan, sibling shards, or hierarchical parent that helps
the worker understand the broader picture. Not part of the verification contract.

```markdown
## Context

This model is part of the auth subsystem (Shard 2). The session middleware
(from Shard 1) expects `User.findByEmail()` to return a promise.
Bcrypt cost factor should match the value in `.env.example` (default: 12).
```

---

## Worker Report

When a worker completes (or fails) a task, it appends a Worker Report section to the
task file. This provides a human-readable audit trail alongside the machine-readable
evidence in `summary.json`.

### Echo-Back

Layer 2 (COMPREHENSION) output: worker restates the task in its own words before
implementation, proving it understood the requirements.

```markdown
## Worker Report

### Echo-Back

I need to create a User model at src/models/user.ts with:
- Email field with validation
- Password field hashed with bcrypt
- Timestamps (created_at, updated_at)
- Soft-delete via deleted_at column
- Re-export from src/models/index.ts

Proof plan:
- AC-1.1.1: file_exists on src/models/user.ts
- AC-1.1.2: pattern_matches for email field
- AC-1.1.3: pattern_matches for bcrypt usage
```

### Implementation Notes

Worker's narrative of what was implemented and any decisions made during execution.

```markdown
### Implementation Notes

Created User model using TypeORM entity decorator pattern (matching existing
Product model in src/models/product.ts). Used bcrypt with configurable cost
factor from process.env.BCRYPT_ROUNDS (default 12). Added soft-delete via
TypeORM's @DeleteDateColumn decorator rather than manual deleted_at handling.
```

### Evidence

Summary of proof execution results. Links to the machine-readable evidence file.

```markdown
### Evidence

Evidence path: tmp/work/20260316T120511/evidence/1.1/summary.json

| Criterion | Proof Type | Result |
|-----------|-----------|--------|
| AC-1.1.1 | file_exists | PASS |
| AC-1.1.2 | pattern_matches | PASS |
| AC-1.1.3 | pattern_matches | PASS |

Overall: PASS (3/3 criteria verified)
```

### Code Changes

Files created or modified, with line counts for traceability.

```markdown
### Code Changes

| File | Action | Lines |
|------|--------|-------|
| src/models/user.ts | created | +87 |
| src/models/index.ts | modified | +1 |
| tests/models/user.test.ts | created | +124 |
```

### Self-Review

Inner Flame self-review output (Grounding, Completeness, Self-Adversarial layers).
Required by `validate-inner-flame.sh` hook.

```markdown
### Self-Review

**Grounding**: All three acceptance criteria verified via proof execution.
Evidence artifacts written to tmp/work/20260316T120511/evidence/1.1/.

**Completeness**: All file targets created. Re-export added to index.ts.
No acceptance criteria left unaddressed.

**Self-Adversarial**: Considered whether bcrypt import could fail on
missing native module — verified package.json includes bcrypt dependency.
Soft-delete decorator tested with findOne({ withDeleted: true }) pattern.
```

---

## Full Example

```markdown
---
task_id: "1.1"
plan_file: "plans/auth-system-plan.md"
plan_section: "### Task 1.1: Create User Model"
status: VERIFIED
assigned_to: "rune-smith-1"
iteration: 0
risk_tier: 1
proof_count: 3
created_at: "2026-03-16T12:05:11Z"
updated_at: "2026-03-16T12:22:45Z"
completed_at: "2026-03-16T12:22:45Z"
---

## Source

Create the User model with email validation, password hashing via bcrypt,
and timestamps. Must support soft-delete via deleted_at column.

## Acceptance Criteria

- id: AC-1.1.1
  text: "User model file exists at src/models/user.ts"
  proof: file_exists
  args: { target: "src/models/user.ts" }

- id: AC-1.1.2
  text: "User model exports a class with email field"
  proof: pattern_matches
  args: { target: "src/models/user.ts", pattern: "email.*string" }

- id: AC-1.1.3
  text: "Password hashing uses bcrypt"
  proof: pattern_matches
  args: { target: "src/models/user.ts", pattern: "bcrypt\\.hash" }

## File Targets

- src/models/user.ts (create)
- src/models/index.ts (modify)
- tests/models/user.test.ts (create)

## Context

Auth subsystem (Shard 2). Session middleware from Shard 1 expects
User.findByEmail() to return a promise.

## Worker Report

### Echo-Back

I need to create a User model at src/models/user.ts with email validation,
bcrypt password hashing, timestamps, and soft-delete support.

### Implementation Notes

Used TypeORM entity decorator pattern. Bcrypt with configurable cost factor.
Added soft-delete via @DeleteDateColumn decorator.

### Evidence

Evidence path: tmp/work/20260316T120511/evidence/1.1/summary.json

| Criterion | Proof Type | Result |
|-----------|-----------|--------|
| AC-1.1.1 | file_exists | PASS |
| AC-1.1.2 | pattern_matches | PASS |
| AC-1.1.3 | pattern_matches | PASS |

Overall: PASS (3/3 criteria verified)

### Code Changes

| File | Action | Lines |
|------|--------|-------|
| src/models/user.ts | created | +87 |
| src/models/index.ts | modified | +1 |
| tests/models/user.test.ts | created | +124 |

### Self-Review

**Grounding**: All three acceptance criteria verified via proof execution.
**Completeness**: All file targets created and re-exported.
**Self-Adversarial**: Verified bcrypt dependency exists in package.json.
```

---

## Integration Points

### Task File Creation (strive Phase 1)

Task files are created by the strive orchestrator during Phase 1 (parse-plan) after
extracting tasks and acceptance criteria. See [parse-plan.md](parse-plan.md) for the
extraction algorithm (STEP A.1: criteria extraction, STEP C: auto-create).

### Evidence Production (worker Phase 3)

Workers write evidence to `tmp/work/{timestamp}/evidence/{task-id}/summary.json`
following the schema in [evidence-convention.md](../../discipline/references/evidence-convention.md).

### Proof Execution (TaskCompleted hook)

The `validate-discipline-proofs.sh` hook reads `summary.json` and executes
`execute-discipline-proofs.sh` against the acceptance criteria. See
[proof-schema.md](../../discipline/references/proof-schema.md) for proof types.

### Status Tracking (discipline metrics)

Task file status transitions feed into discipline metrics aggregation.
Status changes update `updated_at` and trigger metric recording.
