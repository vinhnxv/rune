---
name: discipline
description: |
  Proof-based orchestration discipline for spec-compliant multi-agent systems.
  Five layers: DECOMPOSITION, COMPREHENSION, VERIFICATION, ENFORCEMENT, ACCOUNTABILITY.
  Use when: workers need discipline context, proof schemas, anti-rationalization guidance.
  Keywords: discipline, proof, verification, compliance, spec, acceptance criteria,
  rationalization, evidence, SOW, spec continuity
user-invocable: false
disable-model-invocation: false
---

# Discipline Engineering

Proof-based orchestration that guarantees specification compliance across multi-agent pipelines.
This is not a quality suggestion — it is the architecture of correctness.

Source: `docs/discipline-engineering.md` (Foundational — Active, v2.3.0)

---

## Iron Law

> **NO COMPLETION WITHOUT VERIFIABLE EVIDENCE** (DISC-001)
>
> A task is complete when its acceptance criteria have been verified by machine proof or
> judge-model evaluation — not when the worker believes it is done. Self-reported completion
> is not completion. "It should work" is not evidence. Exit code 0 is evidence.
>
> If you find yourself rationalizing why verification is not needed for this particular task,
> you are about to violate this law.

---

## The Five Discipline Layers

All five layers apply at every task. Skipping any layer leaves a compliance blind spot.

### Layer 1: DECOMPOSITION — "Break It Until It's Boring"

Transform specifications into atomic, verifiable units before any implementation begins.
A task that cannot be verified with a binary pass/fail result must be decomposed further.
"Partially complete" is not a valid task state.

### Layer 2: COMPREHENSION — "Prove You Read It"

Verify understanding of the task *before* execution via echo-back. Restate the task in your
own words. Identify the acceptance criteria you will be proving. Identify the files you will
modify. Name the proof type for each criterion. If you cannot do this, you do not understand
the task — stop and seek clarification rather than guessing.

### Layer 3: VERIFICATION — "Show Your Work"

Replace self-reported completion with machine-verifiable evidence. Every acceptance criterion
has a proof type (see [proof-schema.md](references/proof-schema.md)). Run the proof. Record
the result. Produce the evidence artifact. Fresh evidence only — prior runs do not count if
code has changed since.

### Layer 4: ENFORCEMENT — "You Cannot Skip This"

The previous three layers are structurally non-optional. System components (not agents)
execute proofs. Exit codes are binary. Regex either matches or it does not. There is no
"close enough" mode. Silence equals failure — no output within the timeout window means
the task is FAILED, not "still in progress."

### Layer 5: ACCOUNTABILITY — "The System Learns, Not the Agent"

Deviation patterns are recorded at the system level, not the agent level. When a proof fails
repeatedly for the same criterion pattern, the failure is a signal about the specification or
the architecture — not just the agent. The system accumulates this signal and improves the
next decomposition cycle.

---

## Proof Types Quick Reference

Eight proof types are available. Full definitions in [proof-schema.md](references/proof-schema.md).

| Proof Type | Tool | Reliability | Use When |
|------------|------|-------------|----------|
| `file_exists` | stat/glob | HIGH | Criterion requires a file to exist |
| `pattern_matches` | regex | HIGH | Criterion requires specific content |
| `no_pattern_exists` | !regex | HIGH | Criterion forbids a pattern |
| `test_passes` | exec + exit code | HIGH | Criterion requires tests to pass |
| `builds_clean` | exec + exit code | HIGH | Criterion requires a clean build |
| `git_diff_contains` | diff parse | MEDIUM | Criterion requires a change |
| `line_count_delta` | wc compare | MEDIUM | Criterion requires added/removed lines |
| `semantic_match` | judge model | LOW-MEDIUM | Only when no machine proof is feasible |

**Selection rule**: Prefer machine proofs. Use `semantic_match` only as a last resort.
If no proof type applies, the criterion is unverifiable — rewrite it.

---

## The Separation Principle

System-verification is mandatory for all machine-verifiable proofs. Three models:

1. **Self-verification** — agent verifies its own work → FORBIDDEN (agent rationalizes marginal passes)
2. **Peer-verification** — another agent verifies → DISCOURAGED (same model biases)
3. **System-verification** — infrastructure executes proofs → REQUIRED

For `semantic_match`, the judge model instance receives: criterion text, relevant code, and a
rubric — nothing else. No context from the implementation session. No implementer reasoning.

---

## Anti-Rationalization

Rationalization is the core failure mode that Discipline Engineering exists to counter.
Common patterns and their counters are documented in [anti-rationalization.md](references/anti-rationalization.md).

The most dangerous rationalizations are "silent scope reduction" — when a worker
narrows the task to avoid difficult criteria without acknowledging the narrowing. Discipline
Engineering makes this visible: Phase 1.5 (Task Review) cross-references every plan criterion
against every task file criterion. MISSING means a gap. FABRICATED means hallucination.

---

## Spec Continuity

The plan file is the persistent reference for ALL pipeline phases — not consumed once at
decomposition and forgotten. Every phase reads the plan:

- **Enrichment Phase**: extracts acceptance criteria
- **Work Phase**: echo-back against plan, evidence collection
- **Gap Analysis**: cross-references every plan criterion against implementation evidence
- **Review Phase**: reviewers receive both code AND plan — spec compliance is a review dimension
- **Remediation Phase**: fixes are validated against the original spec

Full spec continuity documentation: [spec-continuity.md](references/spec-continuity.md)

---

## Evidence Artifacts

Every proof produces a JSON artifact persisted to disk.
Required fields: `criterion_id, result, evidence, timestamp`

```json
{
  "criterion_id": "AC-1",
  "result": "PASS",
  "evidence": "Exit code 0 from: npm test -- --testPathPattern=auth",
  "timestamp": "2026-03-16T12:00:00Z"
}
```

Result values: `PASS` | `FAIL` | `INCONCLUSIVE`

`INCONCLUSIVE` is valid only for `semantic_match` when confidence < 70%. Always triggers
human escalation — never treated as pass.

---

## Task File Format

Tasks are files on disk, not in-memory objects. Each has YAML frontmatter with `task_id`,
`status` (PENDING/IN_PROGRESS/COMPLETE), and a Worker Report section filled during execution.

Full schema: [proof-schema.md](references/proof-schema.md)

---

## References

- [proof-schema.md](references/proof-schema.md) — Proof types, tool mappings, evidence format, task file schema
- [anti-rationalization.md](references/anti-rationalization.md) — Rationalization patterns and counters
- [evidence-convention.md](references/evidence-convention.md) — Evidence collection and storage conventions
- [spec-continuity.md](references/spec-continuity.md) — Spec continuity through all pipeline phases
- `docs/discipline-engineering.md` — Foundational document (v2.3.0)
