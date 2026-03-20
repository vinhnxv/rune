# Self-Audit Metrics Schema

Documents the `metrics.json` schema written by `/rune:self-audit --mode runtime|all` to
`tmp/self-audit/{timestamp}/metrics.json`.

## Top-Level Schema (version 1.0)

```json
{
  "schema_version": "1.0",
  "timestamp": "2026-03-19T12:00:00Z",
  "arc_id": "arc-1773916367",
  "mode": "runtime",

  "agents": { ... },
  "phases": { ... },
  "convergence": { ... },
  "hallucination": { ... },
  "trends": { ... }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `schema_version` | string | Always `"1.0"` for this schema version |
| `timestamp` | ISO-8601 | Audit execution time |
| `arc_id` | string | Arc run ID analyzed (e.g. `"arc-1773916367"`) |
| `mode` | string | `"static"`, `"runtime"`, or `"all"` |

---

## agents — Per-Agent Effectiveness Metrics

Populated by the `effectiveness-analyzer` agent from TOME findings and mend resolution reports.
Keys are Ash finding prefixes (e.g., `"ward-sentinel"`, `"flaw-hunter"`).

```json
"agents": {
  "ward-sentinel": {
    "total_findings": 12,
    "false_positives": 2,
    "false_positive_rate": 0.167,
    "unique_findings": 8,
    "unique_rate": 0.667,
    "findings_per_minute": 3.2
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `total_findings` | int | Total findings attributed to this Ash (by prefix) |
| `false_positives` | int | Findings marked FALSE_POSITIVE in resolution report |
| `false_positive_rate` | float | `false_positives / total_findings` |
| `unique_findings` | int | Findings not duplicated by another Ash |
| `unique_rate` | float | `unique_findings / total_findings` |
| `findings_per_minute` | float | `total_findings / (duration_ms / 60000)` |

**Derived from**: `tmp/arc/{id}/TOME.md` (finding prefix extraction) + mend resolution report.

---

## phases — Per-Phase Arc Metrics

Populated from checkpoint phase entries. Keys are phase names as they appear in
`checkpoint.phases` (e.g., `"work"`, `"code_review"`, `"forge"`).

```json
"phases": {
  "work": {
    "duration_ms": 480000,
    "retry_count": 0,
    "timeout_usage_pct": 22.8
  },
  "code_review": {
    "duration_ms": 360000,
    "finding_count": 24,
    "retry_count": 1,
    "timeout_usage_pct": 60.0
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `duration_ms` | int | Phase wall-clock duration in milliseconds |
| `retry_count` | int | Number of retries for this phase (0 = no retries) |
| `timeout_usage_pct` | float | `duration_ms / timeout_ms * 100` |
| `finding_count` | int | Findings produced (review/audit phases only) |

**Derived from**: `.rune/arc/{id}/checkpoint.json`.

---

## convergence — Review-Mend Loop Metrics

Populated by the `convergence-analyzer` agent.

```json
"convergence": {
  "review_mend_rounds": 2,
  "initial_findings": 24,
  "final_findings": 0,
  "global_retry_count": 1,
  "improvement_per_retry": 12.0,
  "stagnation_phases": [],
  "bottleneck_phase": "code_review"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `review_mend_rounds` | int | Total review-mend convergence rounds |
| `initial_findings` | int | Finding count at start of first review |
| `final_findings` | int | Finding count after last mend cycle |
| `global_retry_count` | int | Total retries consumed across all phases |
| `improvement_per_retry` | float | `(initial_findings - final_findings) / max(global_retry_count, 1)` |
| `stagnation_phases` | string[] | Phases where retries produced no score improvement |
| `bottleneck_phase` | string | Phase with highest `timeout_usage_pct` |

**Derived from**: `.rune/arc/{id}/checkpoint.json` + `tmp/arc/{id}/verify-mend-*.md`.

---

## hallucination — Hallucination Detection Counts

Populated by the `hallucination-detector` agent.

```json
"hallucination": {
  "phantom_claims": 0,
  "fabricated_references": 1,
  "inflated_scores": 0,
  "copy_paste_findings": 0,
  "total_flags": 1
}
```

| Field | Type | Description |
|-------|------|-------------|
| `phantom_claims` | int | HD-PHANTOM-* findings flagged |
| `fabricated_references` | int | HD-EVIDENCE-* findings flagged |
| `inflated_scores` | int | HD-INFLATE-* findings flagged |
| `copy_paste_findings` | int | HD-INFLATE-02 (entropy) findings |
| `total_flags` | int | Sum of all hallucination flags |

**Derived from**: `tmp/self-audit/{ts}/hallucination-findings.md` (pattern matching on finding IDs).

---

## trends — Cross-Run Trend Analysis

Computed when 2+ completed arcs are available in `.rune/arc/`. Requires comparing
`metrics.json` from current run against previous run metrics.

```json
"trends": {
  "compared_runs": 3,
  "false_positive_trend": "stable",
  "convergence_trend": "improving",
  "duration_trend": "stable",
  "hallucination_trend": "insufficient_data"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `compared_runs` | int | Number of arc runs included in trend |
| `false_positive_trend` | string | Trend of `avg_false_positive_rate` across runs |
| `convergence_trend` | string | Trend of `review_mend_rounds` across runs |
| `duration_trend` | string | Trend of longest phase `duration_ms` |
| `hallucination_trend` | string | Trend of `total_flags` across runs |

**Trend values**: `"improving"` | `"stable"` | `"degrading"` | `"insufficient_data"`

---

## Cross-Run Trend Computation

### Algorithm

Uses threshold-based classification (not linear regression) — suitable for small sample sizes (N < 6).

```
function computeTrend(values[], field, favorableDirection):
  # values[] = chronologically ordered metric values (oldest first)
  # field = metric name for logging
  # favorableDirection = "decreasing" or "increasing"

  if len(values) < 2:
    return "insufficient_data"

  # Compute point-to-point deltas
  deltas = [values[i+1] - values[i] for i in range(len(values)-1)]
  avg_delta = sum(deltas) / len(deltas)

  # Threshold: 5% of the max observed value (avoids noise)
  threshold = max(abs(v) for v in values if v != 0) * 0.05
  if threshold == 0:
    threshold = 0.01

  if abs(avg_delta) < threshold:
    return "stable"

  if favorableDirection == "decreasing":
    return "improving" if avg_delta < 0 else "degrading"
  else:  # "increasing"
    return "improving" if avg_delta > 0 else "degrading"
```

### Favorable Directions

| Trend Field | Favorable Direction | Rationale |
|-------------|--------------------|-|
| `false_positive_trend` | decreasing | Lower FP rate = better calibration |
| `convergence_trend` | decreasing | Fewer rounds = faster convergence |
| `duration_trend` | decreasing | Shorter phases = better efficiency |
| `hallucination_trend` | decreasing | Fewer flags = better agent fidelity |

### Minimum Evidence Requirements

| Compared Runs | Confidence in Trend |
|---------------|---------------------|
| 1 | `"insufficient_data"` (no comparison possible) |
| 2 | 30% — directional hint only |
| 3 | 50% — moderate confidence |
| 4 | 70% — reliable signal |
| 5+ | 85% — high confidence |

When `compared_runs < 2`, all trend fields return `"insufficient_data"`.

---

## File Location

```
tmp/self-audit/{YYYYMMDD-HHmmss}/
├── metrics.json          ← This schema
├── SELF-AUDIT-REPORT.md
├── hallucination-findings.md
├── effectiveness-findings.md
└── convergence-findings.md
```

The timestamp directory is created at Phase 0 of `/rune:self-audit`.
Past metrics files are read by `--history` subcommand for trend display.
