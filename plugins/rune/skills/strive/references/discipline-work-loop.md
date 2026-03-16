# Discipline Work Loop — 8-Phase Convergence Cycle

The Discipline Work Loop replaces strive's linear task execution with an 8-phase convergence cycle. Each phase builds on the previous, ensuring that every plan criterion is addressed, verified, and evidenced before completion.

**Activation gate**: Plan has YAML acceptance criteria (`AC-*` blocks in code fences). Plans without criteria degrade to the existing strive linear execution (backward compatibility).

**File structure**:
```
tmp/work/{timestamp}/
├── tasks/                    # Task definition files (Phase 1 output)
│   ├── task-1.md
│   └── task-2.md
├── task-review/              # Cross-reference results (Phase 1.5 output)
│   ├── task-1-review.md
│   └── coverage-matrix.md
├── evidence/                 # Worker-collected proof artifacts (Phase 3 output)
│   ├── task-1/
│   │   ├── pattern-match-001.json
│   │   └── summary.json
│   └── task-2/
├── work-review/              # Per-task completion assessments (Phase 4.5 output)
│   ├── task-1-review.md
│   └── completion-matrix.md
├── convergence/              # Per-iteration state + metrics (Phase 5 output)
│   ├── iteration-1.json
│   ├── iteration-2.json
│   └── metrics.json
└── drift-signals/            # Plan-reality mismatch signals (Phase 3 worker output)
```

---

## Phase 1: Decompose

Generate one task file per plan task section. Each task file contains the full acceptance criteria from the plan, file targets, and context needed for the worker.

**Input**: Enriched plan file
**Output**: `tmp/work/{timestamp}/tasks/task-{id}.md` (one per task)

See [task-file-format.md](task-file-format.md) for the canonical task file schema.

**Key rules**:
- Every plan acceptance criterion MUST appear in exactly one task file
- Task files include the plan section text verbatim (no paraphrasing)
- File targets extracted from plan (backtick-wrapped paths, `Files:` annotations)

---

## Phase 1.5: Review Tasks (Cross-Reference Protocol)

5-step cross-reference between plan criteria and task file criteria:

1. **Extract plan AC**: Parse all `AC-*` entries from the original plan
2. **Extract task AC**: Parse all `AC-*` entries from generated task files
3. **Cross-reference**: Compare plan AC ↔ task AC, classify each as:
   - **MAPPED**: Criterion exists in both plan and task file ✓
   - **MISSING**: Criterion in plan but not in any task file ✗
   - **DRIFTED**: Criterion text differs between plan and task file ⚠
   - **FABRICATED**: Criterion in task file but not in plan ✗
4. **Remediate**: For MISSING → add to appropriate task. For FABRICATED → remove from task. For DRIFTED → align with plan text.
5. **Verify**: Re-run cross-reference to confirm 100% MAPPED after remediation.

**Output**: `tmp/work/{timestamp}/task-review/coverage-matrix.md`

**Gate**: MISSING count must be 0 after remediation. FABRICATED count must be 0.

---

## Phase 2: Assign

Distribute task files to workers. Each worker receives ONLY their assigned task files (context isolation — prevents cross-contamination).

**SOW (Scope of Work) Contract** per worker:
```
## Your Scope of Work
RESPONSIBLE FOR: [list of task IDs and their criteria]
NOT RESPONSIBLE FOR: [everything else — do not modify files outside your scope]
```

**SOW coverage check**: After assignment, verify that the union of all worker SOWs covers every plan criterion. Any uncovered criterion → assign to an existing worker or create a new task.

---

## Phase 3: Execute

Workers implement their assigned tasks, collecting evidence as they go. Each worker:

1. Reads the task file (their only source of truth)
2. Implements the required changes
3. Collects evidence per acceptance criterion (see evidence-convention.md)
4. Writes a Worker Report section in the task file
5. Produces a patch for the commit broker

**Context isolation**: Each teammate receives only assigned task files — not the full plan, not other workers' tasks. This prevents cross-contamination and ensures each worker operates from a bounded, verified specification.

---

## Phase 4: Monitor

Standard strive Phase 3 monitoring with discipline extensions:
- Track per-criterion evidence collection (not just task completion)
- Detect stuck workers via silence timeout (configurable, default 5 min)
- Escalation chain: retry → decompose → reassign → human (max 4 attempts)

---

## Phase 4.5: Review Work (Completion Matrix)

Build a completion matrix per task after workers finish:

| Task | Criterion | Status | Evidence |
|------|-----------|--------|----------|
| T1 | AC-1.1 | PASS | pattern-match-001.json |
| T1 | AC-1.2 | FAIL | Missing evidence |
| T2 | AC-2.1 | PASS | file-exists-001.json |
| T2 | AC-2.2 | ABANDONED | Worker reported infeasible |
| T2 | AC-2.3 | INCOMPLETE | Partial evidence only |

**Status values**:
- **PASS**: Criterion verified with machine-readable evidence
- **FAIL**: Evidence collected but verification failed
- **INCOMPLETE**: Partial evidence — needs additional work
- **ABANDONED**: Worker explicitly reported criterion as infeasible
- **MISSING**: No evidence collected (silent skip)

**Output**: `tmp/work/{timestamp}/work-review/completion-matrix.md`

---

## Phase 5: Convergence

Iterative re-work loop for non-PASS criteria. Each iteration:

1. Read completion matrix from Phase 4.5
2. Identify non-PASS criteria (FAIL, INCOMPLETE, MISSING)
3. Generate correction tasks for non-PASS criteria
4. Re-assign to workers (same or different)
5. Re-execute (Phase 3) and re-review (Phase 4.5)
6. Check convergence: all criteria PASS → exit loop

**Convergence limits**:
- `max_convergence_iterations`: Default 3 (talisman configurable via `discipline.max_convergence_iterations`)
- **Stagnation detection**: If same criteria fail across 2+ iterations → escalate to human
- **Exit conditions**: All PASS, max iterations reached, or human intervention

**Detailed convergence protocol**: See [work-loop-convergence.md](work-loop-convergence.md) for the full protocol — entry conditions, iteration logic, exit conditions (success + 3 failure modes), gap task creation, and convergence report format.

**Output**: `tmp/work/{timestamp}/convergence/iteration-{N}.json` per iteration + final `metrics.json`

---

## Phase 6: Quality Gates

Standard strive Phase 4 quality gates + discipline-specific checks:
- Ward check (existing)
- Discipline metrics computation (see metrics-schema.md)
- Final SCR calculation
- Metrics artifact write to `convergence/metrics.json`

---

## Backward Compatibility

Plans **without** YAML acceptance criteria (no `AC-*` blocks) degrade gracefully:

| Feature | With Criteria | Without Criteria |
|---------|--------------|-----------------|
| Task decomposition | From AC blocks | From `### Task` headings (existing) |
| Cross-reference (Phase 1.5) | Full 5-step protocol | Skipped |
| Evidence collection | Machine-verifiable | Best-effort |
| Convergence loop | Enabled | Disabled (single pass) |
| SOW contracts | Bounded by criteria | Bounded by files |
| Completion matrix | Per-criterion | Per-task |
| Metrics | Full schema | Partial (no SCR) |

The discipline work loop is an **overlay** — it enhances the existing strive execution without replacing it. The activation gate (`hasCriteria`) determines which path runs.

---

## See Also

- [task-file-format.md](task-file-format.md) — Task file YAML schema and body sections
- [metrics-schema.md](../../discipline/references/metrics-schema.md) — Discipline metrics JSON schema
- [evidence-convention.md](../../discipline/references/evidence-convention.md) — Evidence directory layout
- [proof-schema.md](../../discipline/references/proof-schema.md) — Proof types and execution
- [spec-continuity.md](../../discipline/references/spec-continuity.md) — Spec propagation across phases
