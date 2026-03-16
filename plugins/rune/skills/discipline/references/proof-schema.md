# Proof Schema Reference

Proof types, tool mappings, execution model, and evidence artifact format for Discipline Engineering.

Source: `docs/discipline-engineering.md` Sections 7.1–7.3, 9.3.

---

## Proof Types

Eight proof types are defined. Each maps to a specific tool and carries a Reliability rating.

### Machine Proofs (deterministic, binary)

| Proof Type | Tool Mapping | Reliability |
|------------|-------------|-------------|
| `file_exists` | stat/glob | HIGH |
| `pattern_matches` | regex | HIGH |
| `no_pattern_exists` | !regex | HIGH |
| `test_passes` | exec + exit code | HIGH |
| `builds_clean` | exec + exit code | HIGH |
| `git_diff_contains` | diff parse | MEDIUM |
| `line_count_delta` | wc compare | MEDIUM |

### Judge Model Proofs (probabilistic, threshold-gated)

| Proof Type | Tool Mapping | Reliability |
|------------|-------------|-------------|
| `semantic_match` | judge model with rubric | LOW-MEDIUM (confidence threshold 70%) |

---

## Proof Type Definitions

### `file_exists`

```yaml
type: file_exists
target: path/to/file.ext
expected: true | false
```

Checks whether a file or directory exists at the given path. Uses stat or glob. **Reliability: HIGH** — the result is binary and deterministic.

---

### `test_passes`

```yaml
type: test_passes
command: npm test -- --testPathPattern=foo
expected: exit_code_0
```

Executes a test command and checks the exit code. **Reliability: HIGH** — exit code 0 means pass, non-zero means fail. No rationalization possible.

---

### `pattern_matches`

```yaml
type: pattern_matches
target: path/to/file.ext
pattern: "regex pattern here"
expected: true
```

Applies a regex to file content. The file either contains the pattern or it does not. **Reliability: HIGH**.

---

### `no_pattern_exists`

```yaml
type: no_pattern_exists
target: path/to/file.ext
pattern: "forbidden pattern"
expected: true
```

Inverse of `pattern_matches`. Verifies a pattern does NOT appear in the target. **Reliability: HIGH**.

---

### `builds_clean`

```yaml
type: builds_clean
command: npm run build
expected: exit_code_0
```

Executes a build command and verifies it exits cleanly. **Reliability: HIGH** — same binary semantics as `test_passes`.

---

### `git_diff_contains`

```yaml
type: git_diff_contains
target: "HEAD~1..HEAD"   # diff scope: staged, HEAD~N..HEAD, or base_branch..HEAD
pattern: "expected diff pattern"
expected: true
```

Parses the git diff output to verify a change was made. The `target` field specifies the diff scope (default: `HEAD~1..HEAD`). **Reliability: MEDIUM** — diff parsing is reliable but depends on the specified scope and working state.

---

### `line_count_delta`

```yaml
type: line_count_delta
target: path/to/file.ext
baseline: "git"   # baseline source: "git" (last commit), "explicit" (value below), or "zero" (new file)
baseline_value: 0  # only used when baseline: "explicit"
expected: ">0"    # or a specific count, e.g., "42"
```

Compares line count against a baseline using `wc`. The `baseline` field specifies how the pre-execution count is obtained: `git` (from last commit via `git show HEAD:{target} | wc -l`), `explicit` (from `baseline_value`), or `zero` (new file, baseline is 0). **Reliability: MEDIUM** — accurate but can produce false positives when lines are reformatted without semantic change.

---

### `semantic_match`

```yaml
type: semantic_match
target: path/to/file.ext
rubric: |
  Criterion 1: ...
  Criterion 2: ...
  Criterion 3: ...
expected: PASS
confidence_threshold: 70
```

Delegates to a judge model instance with no context from the implementation session. The judge receives: criterion text, relevant code, and a scoring rubric — nothing else.

**Reliability: LOW-MEDIUM**. Rules:
- Maximum 3 clear rubric criteria. If you cannot define ≤3 criteria, the criterion needs further decomposition.
- If confidence < 70%: result is INCONCLUSIVE → escalate to human.
- Use ONLY when no machine proof is feasible.

---

## Proof Selection Decision Tree

Use this tree to select the correct proof type for any acceptance criterion.

```
CAN THE CRITERION BE CHECKED BY EXAMINING FILES?
│
├── YES: Does a file/pattern need to exist?
│   ├── YES → file_exists or pattern_matches
│   └── NO: Does a file/pattern need to NOT exist?
│       └── YES → no_pattern_exists
│
├── MAYBE: Does it require running a command?
│   ├── YES: Is the command output binary (pass/fail)?
│   │   ├── YES → test_passes or builds_clean
│   │   └── NO: Does the output need specific content?
│   │       └── YES → pattern_matches (write command output to temp file, then match)
│   └── NO: Does it require comparing file sizes or line counts?
│       ├── YES → line_count_delta
│       └── NO: Does it require comparing versions/diffs?
│           └── YES → git_diff_contains
│
└── NO: Does it require judgment about quality or intent?
    ├── YES: Can a rubric be defined with ≤3 clear criteria?
    │   ├── YES → semantic_match (judge model with rubric)
    │   └── NO → DECOMPOSE FURTHER. Criterion is too vague.
    │
    └── NO → CRITERION IS UNVERIFIABLE. Rewrite it.
```

**The unverifiable criterion rule**: If a criterion cannot be verified by any method in this taxonomy, the criterion is poorly written. It must be rewritten, not exempted from verification.

- UNVERIFIABLE: "The code should be clean."
- VERIFIABLE: "No function exceeds 50 lines."
- UNVERIFIABLE: "The architecture should be scalable."
- VERIFIABLE: "The service uses a connection pool with max 20 connections."

---

## Evidence Artifact Format

Every proof execution produces an evidence artifact persisted to disk.

Required fields: `criterion_id, result, evidence, timestamp`

```json
{
  "criterion_id": "AC-1",
  "result": "PASS",
  "evidence": "Exit code 0 from: npm test -- --testPathPattern=auth",
  "timestamp": "2026-03-16T12:00:00Z"
}
```

Artifacts are persisted to: `tmp/work/{timestamp}/evidence/{task-id}/{criterion_id}.json`

> **Path convention**: The full path includes the `tmp/work/{timestamp}/` prefix per evidence-convention.md. The evidence directory also contains a `summary.json` aggregating all per-criterion results.

Result values: `PASS` | `FAIL` | `INCONCLUSIVE`

`INCONCLUSIVE` is only valid for `semantic_match` when confidence < 70%. It always triggers human escalation — it is never treated as a pass.

---

## Proof Execution Model

```
┌─────────────────────────────────────────────────────────┐
│  PROOF EXECUTOR (System Component, NOT Agent)            │
│                                                          │
│  Input: Criterion + proof type + arguments               │
│                                                          │
│  ┌────────────────────────────────┐                      │
│  │ Machine Proof Engine           │                      │
│  │                                │                      │
│  │ file_exists → stat/glob       │                      │
│  │ pattern_matches → regex       │                      │
│  │ test_passes → exec + exit code│                      │
│  │ builds_clean → exec + exit    │                      │
│  │ git_diff_contains → diff parse│                      │
│  │ no_pattern_exists → !regex    │                      │
│  │ line_count_delta → wc compare │                      │
│  └──────────────┬─────────────────┘                      │
│                 │                                        │
│  ┌──────────────▼─────────────────┐                      │
│  │ Judge Model Engine             │                      │
│  │ (ONLY when machine proof       │                      │
│  │  is not feasible)              │                      │
│  │                                │                      │
│  │ Input: code + criterion + rubric│                      │
│  │ Model: smallest sufficient     │                      │
│  │ Output: PASS/FAIL + confidence │                      │
│  │                                │                      │
│  │ If confidence < 70%:           │                      │
│  │   → INCONCLUSIVE              │                      │
│  │   → Escalate to human         │                      │
│  └──────────────┬─────────────────┘                      │
│                 │                                        │
│  Output: { criterion_id, result, evidence, timestamp }   │
│  Persisted to: evidence/{task_id}/{criterion_id}.json    │
└─────────────────────────────────────────────────────────┘
```

---

## The Separation Principle

The most critical design decision in verification is **who executes the proofs**:

| Model | Description | Problem |
|-------|-------------|---------|
| Self-verification | Agent verifies its own work | Agent rationalizes marginal passes |
| Peer-verification | Another agent verifies | Less rationalization, but same model biases |
| **System-verification** | Infrastructure executes proofs | No rationalization possible. Machine proofs are binary. |

Discipline Engineering mandates **system-verification** for all machine-verifiable proofs. The agent cannot rationalize exit code 1 into a pass. A file either matches the regex or it does not. A build either succeeds or it fails. There is no "close enough."

For semantic proofs, a **separate model instance with no context from the implementation session** serves as judge. The judge receives only: criterion text, relevant code, and a scoring rubric. It does NOT receive the implementer's reasoning, confidence, or justification.

---

## Task File YAML Format

Tasks are files on disk (Section 9.3), not in-memory objects. Each task file has YAML frontmatter:

```yaml
---
task_id: TASK-001
plan_file: plans/my-feature.md
plan_section: "2.1 Authentication"
status: PENDING          # PENDING | IN_PROGRESS | COMPLETE
assigned_to: smith-1
iteration: 1
created_at: 2026-03-16T10:00:00Z
updated_at: 2026-03-16T12:00:00Z
---
```

Status values:
- `PENDING` — not yet started
- `IN_PROGRESS` — worker has claimed and is executing
- `COMPLETE` — worker has finished AND evidence collected

### Worker Report Section

The Worker Report is filled by the assigned teammate during execution:

```markdown
## Worker Report

### Echo-Back
[Restate the task in your own words to prove comprehension before touching any code]

### Implementation Notes
[Key decisions made, patterns followed, deviations from spec and why]

### Evidence
[Per-criterion proof results — cite specific command output, file:line, exit codes]

| Criterion | Proof Type | Result | Evidence |
|-----------|-----------|--------|----------|
| AC-1 | test_passes | PASS | Exit 0: npm test auth.test.ts (7 tests) |
| AC-2 | pattern_matches | PASS | Found pattern at src/auth.ts:45 |

### Code Changes
[Diff summary — which files changed and why]

### Self-Review
[Inner Flame log — Layer 1 Grounding, Layer 2 Completeness, Layer 3 Adversarial]

### Status Update
DONE — 2026-03-16T12:34:56Z
```

---

## See Also

- `docs/discipline-engineering.md` — foundational document
- `references/anti-rationalization.md` — rationalization patterns and counters
- `references/evidence-convention.md` — evidence collection and storage conventions
