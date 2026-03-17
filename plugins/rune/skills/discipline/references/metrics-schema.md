# Discipline Metrics Schema

Quantitative metrics for measuring orchestration discipline across multi-agent pipelines.
All metrics are computed per-run and persisted to `tmp/work/{timestamp}/convergence/metrics.json`.

Source: `docs/discipline-engineering.md` Sections 10.1–10.3.

---

## Metric Definitions

### SCR — Spec Compliance Rate

The ratio of plan acceptance criteria that are fully verified (GREEN) to the total number
of acceptance criteria extracted from the plan.

```
SCR = count(criteria where status = GREEN) / count(all_criteria)
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Target | ≥ 0.95 (configurable via talisman `discipline.scr_threshold`) |
| Gate | SCR < threshold → BLOCK at pre-ship validation |

SCR is the **primary quality signal** for spec compliance. It answers: "What fraction of
the specification was delivered with verifiable evidence?" A run with SCR < 1.0 has
unverified criteria — those criteria may be implemented but lack evidence, or may be
missing entirely.

---

### DSR — Design Spec-compliance Rate

The ratio of design criteria (DES-prefixed) that are verified as PASS to the total number of
actionable design criteria. INCONCLUSIVE criteria (tool unavailable, F4 graceful degradation)
are excluded from the denominator — they represent tool unavailability, not implementation failure.

```
DSR = count(DES- criteria where status = PASS) / count(DES- criteria where status != INCONCLUSIVE)
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 (null when design_sync.enabled is false) |
| Target | 1.0 (all actionable design criteria pass) |
| Gate | DSR < 1.0 with block_on_fail → BLOCK at pre-ship validation |
| Signal | Low DSR indicates design-implementation divergence |

DSR is the **primary design quality signal**, paralleling SCR for code quality. It answers:
"What fraction of the design specification was implemented with verifiable evidence?"

**Relationship to SCR**: SCR measures code criteria compliance; DSR measures design criteria
compliance. Both appear in `verdicts.details`. The overall verdict uses
`Math.min(scr_gate, dsr_gate)` — both must pass for overall PASS. When `design_sync.enabled`
is false, DSR is `null` (not computed) and the `design_compliance` section is omitted from the
proof manifest entirely.

**Per-component breakdown**: DSR is also computed per-component in the design criteria matrix
(`tmp/arc/{id}/design-criteria-matrix-{iteration}.json`). The aggregate DSR in the metrics
artifact is the run-level summary.

See [design-convergence.md](design-convergence.md) for the full criteria-based convergence
protocol that uses DSR as its primary metric.

---

### First-Pass Rate

The fraction of tasks that pass ALL acceptance criteria on the first worker attempt
(iteration 1), without requiring convergence corrections.

```
first_pass_rate = count(tasks where iteration = 1 AND all_criteria = PASS) / count(all_tasks)
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Target | ≥ 0.70 |
| Signal | Low first-pass rate indicates poor task decomposition or ambiguous criteria |

A high first-pass rate means the decomposition layer is producing clear, unambiguous tasks.
A low first-pass rate means workers are consistently misunderstanding or partially implementing
tasks — the specification needs improvement, not just the workers.

---

### Silent Skip Rate

The fraction of plan acceptance criteria that were present in the plan but absent from
ALL task files — criteria that were silently dropped during decomposition without
acknowledgment.

```
silent_skip_rate = count(criteria NOT in any task file) / count(all_plan_criteria)
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Target | 0.0 (any silent skip is a decomposition failure) |
| Signal | Non-zero = silent scope reduction (see anti-rationalization.md) |

This is the most dangerous metric because it measures **invisible failures**. A silent
skip is a criterion that no one noticed was missing. It differs from a FAIL (which is
visible) because it never appears in any task, evidence, or report.

---

### Escalation Depth

The maximum number of convergence iterations required by any single task before it
reached a terminal state (CONVERGED or FAILED).

```
escalation_depth = max(task.iteration for all tasks)
```

| Field | Value |
|-------|-------|
| Range | 1 – N (typically capped at 3 by talisman `discipline.max_iterations`) |
| Target | ≤ 2 |
| Signal | Depth 3+ indicates a systemic issue — criterion is ambiguous or infeasible |

Escalation depth tracks how many correction cycles were needed. Depth 1 = first-pass
success. Depth 2 = one correction cycle. Depth 3+ = the criterion or task needs human
attention — repeated machine correction is unlikely to converge.

---

### Proof Coverage

The fraction of acceptance criteria that have a defined proof type (any of the 14 proof
types from proof-schema.md), regardless of whether the proof passed or failed.

```
proof_coverage = count(criteria with proof_type defined) / count(all_criteria)
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Target | 1.0 (every criterion must have a proof type) |
| Signal | < 1.0 = unverifiable criteria exist (rewrite them) |

Proof coverage measures specification quality, not implementation quality. A criterion
without a proof type is unverifiable by definition — it must be rewritten per the
Proof Selection Decision Tree in proof-schema.md.

---

### Verification Overhead

The ratio of time spent on verification activities (proof execution, evidence collection,
convergence checks) to total pipeline time.

```
verification_overhead = verification_time_ms / total_pipeline_time_ms
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Target | ≤ 0.30 (verification should not exceed 30% of total time) |
| Signal | High overhead = proofs are too expensive or too numerous |

This metric guards against over-verification. Discipline should increase quality without
making the pipeline prohibitively slow. If verification overhead exceeds 30%, consider:
consolidating criteria, using faster proof types, or parallelizing proof execution.

---

### Context Pressure

The ratio of consumed context budget to total context budget at any point during the pipeline.
Context pressure measures how close the orchestrator or agent is to context exhaustion —
a leading indicator of silent backpressure where response quality degrades without explicit error.

```
context_pressure = consumed_context_tokens / total_context_budget
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Advisory | ≥ 0.65 (warn — consider compacting or reducing scope) |
| Critical | ≥ 0.75 (agent output quality likely degrading) |
| Signal | High context pressure correlates with declining response length and superficial evidence |

Context pressure is an **advisory metric** — it does not gate pipeline progression. Instead,
it informs the orchestrator that agent output quality may be degrading silently. When
context pressure exceeds the advisory threshold, the orchestrator should consider:
reducing active agent count, compacting the session, or switching to file-based output.

The `enforce-glyph-budget.sh` hook tracks response length trends per session and warns
when a teammate's response length falls below 50% of the session average — a runtime
proxy for context pressure without requiring direct token count access.

---

### Convergence Iterations

The total number of convergence rounds executed across the entire run. Each round
re-evaluates all non-converged tasks.

```
convergence_iterations = count(convergence rounds executed)
```

| Field | Value |
|-------|-------|
| Range | 1 – N |
| Target | ≤ 2 |
| Signal | High iterations = many tasks failing first pass |

Convergence iterations is a run-level metric (vs escalation depth which is per-task).
A run with 1 convergence iteration means all tasks converged on first pass. A run with
3+ iterations indicates systemic decomposition or specification issues.

---

### Task Review Gap Rate

The fraction of tasks where the task review (Phase 1.5) found criteria present in the
plan but missing from the task file — gaps between the plan and the decomposed tasks.

```
task_review_gap_rate = count(tasks with missing criteria) / count(all_tasks)
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Target | 0.0 |
| Signal | Non-zero = decomposition is losing criteria |

Task review gap rate measures decomposition fidelity. It differs from silent skip rate
in that it catches gaps during the pipeline (Phase 1.5 task review) rather than
post-hoc. A high gap rate means the enrichment/decomposition phase is consistently
failing to capture all criteria from the plan.

---

### Fabrication Rate

The fraction of criteria found in task files that do NOT exist in the original plan —
criteria that were hallucinated or invented by the decomposition agent.

```
fabrication_rate = count(task_criteria NOT in plan_criteria) / count(all_task_criteria)
```

| Field | Value |
|-------|-------|
| Range | 0.0 – 1.0 |
| Target | 0.0 (any fabrication is a decomposition failure) |
| Signal | Non-zero = agent hallucination in decomposition |

Fabrication is the inverse of silent skip: instead of losing criteria, the agent invents
new ones. Fabricated criteria waste worker effort and may introduce unwanted behavior.
Phase 1.5 (Task Review) detects fabrication by cross-referencing task criteria against
the plan's criteria list.

---

### Stochastic Budget

The expected failure rate for a run, accounting for transient (non-systemic) failures such
as network timeouts, tool flakiness, and filesystem race conditions. Failures within the
stochastic budget are **expected noise** — not signals of implementation problems.

```
stochastic_budget = stochastic_rate × total_criteria
actual_failures = count(criteria where first_attempt = FAIL AND second_attempt = PASS)
```

| Field | Value |
|-------|-------|
| Range | 0 – total_criteria |
| Target | actual_failures ≤ stochastic_budget |
| Signal | Over budget = systemic issue, not transient noise |

#### Classification

| Classification | Condition | Meaning |
|----------------|-----------|---------|
| `WITHIN_BUDGET` | actual_failures ≤ stochastic_budget | Failures are expected noise — no escalation needed |
| `OVER_BUDGET` | actual_failures > stochastic_budget | Failure rate exceeds baseline — systemic issue likely |

The `stochastic_rate` is configurable via talisman (default: `0.05` = 5% expected failure rate).
For a run with 20 criteria, `stochastic_budget = 0.05 × 20 = 1` — one transient failure is
expected and should not trigger escalation.

#### Stochastic vs Systemic Failures

A failure is classified as **stochastic** (transient) when:
- First attempt fails, second attempt passes (the retry fixed it)
- The failure code is in the transient set (e.g., timeout, flaky tool)

A failure is classified as **systemic** when:
- The same criterion fails across 2+ consecutive attempts
- The failure rate exceeds the stochastic budget

This distinction prevents over-reaction to normal variance while still catching real problems.

---

## Metrics Artifact JSON Schema

The metrics artifact is persisted at `tmp/work/{timestamp}/convergence/metrics.json`
after the final convergence round completes.

```json
{
  "run_id": "string",
  "plan_file": "string",
  "timestamp": "ISO8601",
  "total_criteria": 0,
  "total_tasks": 0,
  "metrics": {
    "scr": {
      "value": 0.0,
      "numerator": 0,
      "denominator": 0,
      "threshold": 0.95,
      "gate_result": "PASS|FAIL"
    },
    "dsr": {
      "value": null,
      "numerator": 0,
      "denominator": 0,
      "threshold": 1.0,
      "gate_result": "PASS|FAIL|null",
      "design_sync_enabled": false,
      "components": [],
      "dimensions": {
        "token_compliance": 0.0,
        "accessibility": 0.0,
        "variant_coverage": 0.0,
        "story_coverage": 0.0,
        "responsive": 0.0,
        "fidelity": 0.0
      }
    },
    "first_pass_rate": {
      "value": 0.0,
      "numerator": 0,
      "denominator": 0
    },
    "silent_skip_rate": {
      "value": 0.0,
      "numerator": 0,
      "denominator": 0,
      "skipped_criteria": []
    },
    "escalation_depth": {
      "value": 0,
      "per_task": {}
    },
    "proof_coverage": {
      "value": 0.0,
      "numerator": 0,
      "denominator": 0,
      "unverifiable_criteria": []
    },
    "verification_overhead": {
      "value": 0.0,
      "verification_time_ms": 0,
      "total_pipeline_time_ms": 0
    },
    "convergence_iterations": {
      "value": 0,
      "per_round_summary": []
    },
    "task_review_gap_rate": {
      "value": 0.0,
      "numerator": 0,
      "denominator": 0,
      "tasks_with_gaps": []
    },
    "fabrication_rate": {
      "value": 0.0,
      "numerator": 0,
      "denominator": 0,
      "fabricated_criteria": []
    },
    "stochastic_budget": {
      "stochastic_rate": 0.05,
      "budget": 0,
      "actual_failures": 0,
      "classification": "WITHIN_BUDGET",
      "transient_criteria": []
    }
  },
  "verdicts": {
    "overall": "PASS|FAIL|WARN",
    "details": []
  }
}
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `run_id` | string | yes | Unique run identifier (matches `{timestamp}` in path) |
| `plan_file` | string | yes | Path to the plan file used for this run |
| `timestamp` | string | yes | ISO-8601 time the metrics were computed |
| `total_criteria` | integer | yes | Total acceptance criteria extracted from the plan |
| `total_tasks` | integer | yes | Total tasks decomposed from the plan |
| `metrics.*` | object | yes | One entry per metric (see definitions above) |
| `metrics.*.value` | number | yes | The computed metric value |
| `metrics.*.numerator` | integer | varies | Count used in ratio calculation (where applicable) |
| `metrics.*.denominator` | integer | varies | Total used in ratio calculation (where applicable) |
| `verdicts.overall` | enum | yes | `PASS` (all gates pass), `FAIL` (any gate fails), `WARN` (advisory thresholds crossed) |
| `verdicts.details` | array | yes | Per-metric verdict entries with gate results |

### Verdict Entry Schema

Each entry in `verdicts.details`:

```json
{
  "metric": "scr",
  "value": 0.95,
  "threshold": 0.95,
  "result": "PASS|FAIL|WARN",
  "message": "SCR 0.95 meets threshold 0.95"
}
```

### Validity Rules

1. `verdicts.overall` MUST be derived from individual metric verdicts — never set manually.
2. `verdicts.overall = PASS` requires every gated metric to pass its threshold.
3. `verdicts.overall = FAIL` if any gated metric (SCR, proof_coverage) fails its threshold.
4. `verdicts.overall = WARN` if non-gated metrics exceed advisory thresholds but no gates fail.
5. `metrics.scr.threshold` MUST match the talisman `discipline.scr_threshold` value (default: 0.95).
6. All `*_criteria` arrays (skipped, unverifiable, fabricated) MUST contain criterion IDs that exist in either the plan or task files.
7. `metrics.dsr.design_sync_enabled` MUST be `false` when plan frontmatter lacks `design_sync: true`. When `design_sync_enabled` is `false`, `metrics.dsr.value` MUST be `null`.

---

## Talisman Configuration

Metric thresholds are configurable via `talisman.yml`:

```yaml
discipline:
  enabled: true
  scr_threshold: 0.95          # Minimum SCR to pass pre-ship gate
  max_iterations: 3            # Maximum convergence iterations before escalation
  block_on_fail: false         # true = hard block on FAIL; false = WARN only
  stochastic_rate: 0.05           # Expected failure rate for stochastic budget (5%)
  metrics:
    first_pass_target: 0.70    # Advisory target for first-pass rate
    overhead_target: 0.30      # Advisory target for verification overhead

# Design discipline thresholds (nested under design_sync:)
# design_sync:
#   discipline:
#     dsr_threshold: 1.0       # Target DSR for design criteria (0.0-1.0)
#     block_on_fail: false     # Advisory by default — design failures don't block pipeline
```

---

## Metric Relationships

```
                    DECOMPOSITION QUALITY
                    ┌──────────────────┐
                    │ silent_skip_rate │──── criteria lost
                    │ fabrication_rate │──── criteria invented
                    │ task_review_gap  │──── gaps caught in review
                    └────────┬─────────┘
                             │
                    EXECUTION QUALITY
                    ┌────────▼─────────┐
                    │ first_pass_rate  │──── worker comprehension
                    │ escalation_depth │──── correction cycles
                    │ convergence_iter │──── run-level iterations
                    └────────┬─────────┘
                             │
                    VERIFICATION QUALITY
                    ┌────────▼─────────┐
                    │ proof_coverage   │──── spec quality
                    │ verification_oh  │──── pipeline efficiency
                    │ SCR              │──── final code compliance
                    │ DSR              │──── final design compliance (conditional)
                    └──────────────────┘
```

The metrics form three layers. Decomposition quality feeds into execution quality,
which feeds into verification quality. SCR is the terminal code compliance metric,
and DSR (when design_sync is enabled) is the terminal design compliance metric.
Together they aggregate the quality of all preceding layers into compliance numbers.

---

## See Also

- [proof-schema.md](proof-schema.md) — Proof types and evidence artifact format
- [evidence-convention.md](evidence-convention.md) — Directory layout and evidence storage
- [spec-continuity.md](spec-continuity.md) — Spec continuity through all pipeline phases
- [anti-rationalization.md](anti-rationalization.md) — Rationalization patterns (relevant to fabrication and silent skip)
- [design-proof-types.md](design-proof-types.md) — Design proof types (6 types: token_scan, axe_passes, story_exists, storybook_renders, screenshot_diff, responsive_check)
- [design-convergence.md](design-convergence.md) — Per-criterion design convergence protocol using DSR as primary metric
