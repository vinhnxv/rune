# Accountability Protocol — Discipline Echoes

Layer 5 of Discipline Engineering: systematic tracking of verification patterns across
pipeline runs. Persists aggregate metrics to Rune Echoes so the system learns its weak
points and improves decomposition, agent assignment, and proof selection over time.

This protocol defines: what to track (5 signal categories), when to persist (post-strive, post-arc),
where to store (.rune/echoes/discipline/), and how to query (echo_search MCP with role filter).

Referenced from [discipline SKILL.md](../SKILL.md) Layer 5.

---

## What to Track

Five categories of discipline signal are tracked per pipeline run:

### 1. Failure Code Distribution

Which F-codes (F1-F17) appeared, how often, and in which proof types.

| Field | Type | Description |
|---|---|---|
| `failure_codes` | object | Map of F-code → count (e.g., `{"F3": 5, "F8": 1}`) |
| `dominant_code` | string | Most frequent F-code this run |
| `total_failures` | integer | Total proof failures across all criteria |

**Why track**: Repeated F3 (PROOF_FAILURE) suggests implementation quality issues.
Repeated F8 (INFRASTRUCTURE_FAILURE) suggests tooling gaps. F17 (CONVERGENCE_STAGNATION)
signals decomposition problems. See [failure-codes.md](failure-codes.md) for the full registry.

### 2. Rationalization Detection

Whether anti-rationalization measures fired and what patterns were caught.

| Field | Type | Description |
|---|---|---|
| `rationalization_detections` | integer | Count of rationalization attempts detected |
| `rationalization_patterns` | array | Pattern names triggered (e.g., `["silent_scope_reduction", "trivial_bypass"]`) |
| `inner_flame_failures` | integer | Count of Inner Flame self-review failures |

**Why track**: Rising rationalization counts indicate agent discipline is degrading.
Specific patterns inform which anti-rationalization rules need strengthening.

### 3. Proof Type Effectiveness

Pass/fail rates per proof type across all criteria in the run.

| Field | Type | Description |
|---|---|---|
| `proof_effectiveness` | object | Map of proof_type → `{pass: N, fail: N, rate: 0.0-1.0}` |
| `least_effective_type` | string | Proof type with lowest pass rate |
| `most_reliable_type` | string | Proof type with highest pass rate |

**Why track**: Proof types with consistently low pass rates may indicate poor criterion
writing (the criterion is hard to satisfy) or infrastructure issues (the proof is flaky).
Informs proof selection in future plan decomposition.

### 4. Agent Compliance

Per-agent first-pass completion and convergence iteration counts.

| Field | Type | Description |
|---|---|---|
| `agent_compliance` | object | Map of agent_name → `{first_pass: N, total: N, rate: 0.0-1.0, avg_iterations: N}` |
| `highest_compliance` | string | Agent with highest first-pass rate |
| `lowest_compliance` | string | Agent with lowest first-pass rate |

**Why track**: Agents with consistently low first-pass rates may be receiving tasks
outside their strength area. Informs agent-task assignment in future runs.

### 5. Convergence Summary

Run-level convergence metrics for trend analysis.

| Field | Type | Description |
|---|---|---|
| `convergence_iterations` | integer | Total convergence rounds this run |
| `scr` | number | Final Spec Compliance Rate (0.0-1.0) |
| `first_pass_rate` | number | Fraction of tasks passing on first attempt |
| `total_criteria` | integer | Total acceptance criteria in the plan |
| `total_tasks` | integer | Total tasks decomposed from the plan |

**Why track**: Trend analysis across runs reveals whether the project's discipline
is improving or degrading over time.

---

## When to Persist

Discipline echoes are written at two pipeline boundaries:

### Strive Post-Completion (Phase 5)

After all workers complete and quality gates pass, the Tarnished writes a discipline
echo entry. This captures the work phase metrics from `tmp/work/{timestamp}/convergence/metrics.json`.

**Trigger**: `discipline.enabled: true` AND `metrics.json` exists in the convergence directory.

**Timing**: After standard echo persist (existing Phase 5), before cleanup (Phase 6).

### Arc Post-Merge (Completion Phase)

After the full arc pipeline completes (post-ship, post-merge), the Tarnished writes a
pipeline-level discipline echo that aggregates metrics across all phases.

**Trigger**: `discipline.enabled: true` AND arc checkpoint contains metrics data.

**Timing**: During echo persist in the arc completion phase (see [post-arc.md](../../arc/references/post-arc.md)).

---

## Where to Store

Discipline echoes are stored in the standard Rune Echoes directory under a dedicated role:

```
.rune/echoes/
└── discipline/
    └── MEMORY.md    # Discipline accountability entries (150-line limit)
```

**Role**: `discipline` — distinct from `workers`, `reviewer`, `planner` to avoid
polluting role-specific memories with cross-cutting metrics.

**Layer**: `inscribed` — tactical patterns that persist across sessions and get pruned
when stale (90 days unreferenced). Weight: 0.7.

---

## How to Query

Discipline echoes are queryable via the echo-search MCP server, the same as all other echoes.

### Direct Query

```javascript
// Via echo-search MCP
echo_search({
  query: "discipline failure codes convergence",
  role: "discipline",
  limit: 5
})
```

### Filtered by Domain

Echo entries include `domain: verification` in their metadata, enabling filtered queries:

```javascript
echo_search({
  query: "proof effectiveness trend",
  role: "discipline"
})
```

### Programmatic Access

The Tarnished reads discipline echoes during plan decomposition (devise Phase 1) to
inform task assignment and proof selection. Workers do NOT read discipline echoes —
they receive guidance indirectly via improved task definitions.

---

## Echo Entry Format

Discipline echo entries follow the standard Rune Echoes format with discipline-specific
fields in the body.

### Template

```markdown
### [YYYY-MM-DD] Discipline: {plan_name} run summary
- **layer**: inscribed
- **source**: rune:{workflow} {timestamp}
- **confidence**: 0.8
- **evidence**: `tmp/work/{timestamp}/convergence/metrics.json`
- **verified**: YYYY-MM-DD
- **role**: discipline
- **domain**: verification
- **tags**: [discipline, accountability, metrics]
- **supersedes**: none
- Run SCR: {scr} | First-pass: {first_pass_rate} | Iterations: {convergence_iterations}
- Failure codes: {failure_code_summary}
- Proof effectiveness: {least_effective_type} ({rate})
- Agent compliance: {lowest_compliance} ({rate})
- Trend: {improving|stable|degrading} vs {N} prior runs
```

### Field Definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `role` | string | yes | Always `discipline` — enables role-filtered echo queries |
| `domain` | string | yes | Always `verification` — enables domain-filtered echo queries |
| `tags` | array | yes | Always includes `discipline`, `accountability`, `metrics` |
| `failure_codes` | object | yes | F-code distribution map from the run |
| `rationalization_detections` | integer | yes | Count of rationalization attempts detected |
| `proof_effectiveness` | object | yes | Per-proof-type pass/fail rates |
| `agent_compliance` | object | yes | Per-agent first-pass rates |
| `scr` | number | yes | Final Spec Compliance Rate |
| `first_pass_rate` | number | yes | Fraction of tasks passing first attempt |
| `convergence_iterations` | integer | yes | Total convergence rounds |

### Privacy Constraints

Discipline echoes contain **aggregate metrics only**. The following are explicitly excluded:

- No specific code snippets or implementation details
- No file paths from the working directory (only relative tmp/ evidence paths)
- No user data, authentication tokens, or environment variables
- No raw criterion text (only criterion IDs like `AC-1.2.3`)
- No agent conversation excerpts or prompt content

**Rationale**: Echoes persist across sessions and may be shared globally via `/rune:elevate`.
Aggregate metrics (counts, rates, distributions) are safe to persist. Specific code or
file paths would leak project internals into persistent memory.

---

## Trend Detection

Discipline echoes enable trend detection by comparing the current run's metrics against
historical averages from previous echo entries.

### Algorithm

```
function detectTrend(currentMetrics, historicalEchoes):
  // Read last N discipline echo entries (default: 5)
  recentEntries = echo_search({ role: "discipline", limit: 5 })

  // Extract historical averages
  historicalSCR = average(recentEntries.map(e => e.scr))
  historicalFirstPass = average(recentEntries.map(e => e.first_pass_rate))
  historicalIterations = average(recentEntries.map(e => e.convergence_iterations))

  // Compare current vs historical
  scrDelta = currentMetrics.scr - historicalSCR
  firstPassDelta = currentMetrics.first_pass_rate - historicalFirstPass
  iterationDelta = currentMetrics.convergence_iterations - historicalIterations

  // Classify trend (thresholds configurable via talisman)
  if scrDelta > 0.05 AND firstPassDelta > 0.05:
    return "improving"
  elif scrDelta < -0.05 OR firstPassDelta < -0.10:
    return "degrading"
  else:
    return "stable"
```

### Trend Signals

| Signal | Condition | Action |
|---|---|---|
| `improving` | SCR +5% AND first-pass +5% vs historical average | Log positive trend. No action needed. |
| `stable` | Metrics within 5% of historical average | Normal operation. |
| `degrading` | SCR -5% OR first-pass -10% vs historical average | Warn in completion report. Suggest reviewing decomposition quality. |

### Historical Average Window

The trend detection window is the last 5 discipline echo entries (configurable via
`discipline.trend_window` in talisman, default: 5). Entries older than the window are
still available for manual query but excluded from automatic trend computation.

When fewer than 2 historical entries exist (new project or fresh echoes), trend detection
returns `"insufficient_data"` and skips the comparison.

---

## Integration with Existing Metrics

Discipline echoes consume data from `metrics.json` (see [metrics-schema.md](metrics-schema.md)):

| Metrics Field | Echo Field | Mapping |
|---|---|---|
| `metrics.scr.value` | `scr` | Direct copy |
| `metrics.first_pass_rate.value` | `first_pass_rate` | Direct copy |
| `metrics.convergence_iterations.value` | `convergence_iterations` | Direct copy |
| `verdicts.overall` | (not persisted) | Used to gate echo writing — only write on PASS or WARN |
| Convergence `failure_code_histogram` | `failure_codes` | Direct copy from convergence metrics |

Proof effectiveness and agent compliance are computed from the per-task evidence summaries
in `tmp/work/{timestamp}/evidence/*/summary.json` at echo-write time.

---

## Talisman Configuration

```yaml
discipline:
  echoes:
    enabled: true           # Master switch for discipline echo writing
    trend_window: 5         # Number of recent entries for trend detection
    trend_degradation_warn: true  # Warn in completion report on degrading trend
```

All settings are optional. Defaults shown above. When `discipline.echoes.enabled` is
`false`, no discipline echoes are written (existing echoes remain queryable).

---

## See Also

- [metrics-schema.md](metrics-schema.md) — SCR, first-pass rate, and other discipline metrics
- [failure-codes.md](failure-codes.md) — F1-F17 failure code registry
- [evidence-convention.md](evidence-convention.md) — Evidence directory layout and summary.json schema
- [anti-rationalization.md](anti-rationalization.md) — Rationalization patterns and detection
- [../../rune-echoes/SKILL.md](../../rune-echoes/SKILL.md) — Rune Echoes memory lifecycle

---

## 6. DEFERRED Accountability Protocol (v2.9.0)

Classification rules for DEFERRED findings in gap remediation. Prevents AI agents from
"shirking" by deferring small wiring/routing tasks that create dead code.

### Classification Rules

| Condition | Classification | Action |
|-----------|---------------|--------|
| Wiring/routing task (regex match + small scope) | SHIRKING | MUST FIX — cannot defer |
| AC requires feature to work (file referenced in ACs) | SHIRKING | MUST FIX — AC overrides timeline |
| Deferring creates dead code (FIXED dependents exist) | SHIRKING | MUST FIX — dead code = immediate debt |
| Feature genuinely too large (needs own plan) | LEGITIMATE | OK to defer with dedicated plan reference |
| Feature is optional/nice-to-have | LEGITIMATE | OK to defer |
| Unclear classification | REVIEW_NEEDED | Flag for human decision |

### Dead Code Detection Heuristic

A DEFERRED finding creates dead code when:
1. Other FIXED findings reference it (dependency chain)
2. Implemented code has no entry point without it (routing/registration)
3. Documentation describes a feature users cannot invoke

### Enforcement Points

| Phase | Mechanism | Gate |
|-------|-----------|------|
| Gap Remediation (5.8) | `canDefer()` called before every DEFERRED classification | Hard — non-deferrable findings forced into fix queue |
| Pre-Ship Validation (8.5) | Gate 4 checks AC commands are routable | Soft (WARN) — promoted to BLOCK after 5+ arc validations |
| QA Gates | GAP-CMP-03 audits DEFERRED classifications | Scoring — SHIRKING=0, LEGITIMATE=75, none=100 |
| Post-Arc | Deferred Audit in completion report | Informational — SHIRKING/LEGITIMATE labels visible to user |

### Tracking Fields

| Field | Type | Description |
|---|---|---|
| `deferred_classifications` | array | Per-finding `{ id, classification, reason }` from canDefer() |
| `forced_fix_count` | integer | Count of findings forced from DEFERRED to FIX by anti-shirking |
| `shirking_count` | integer | Count of SHIRKING-classified items in post-arc audit |

**Why track**: Rising `shirking_count` across arc runs indicates agent discipline around wiring
tasks is degrading. `forced_fix_count > 0` means the anti-shirking protocol is actively catching
deferred wiring tasks that would have created dead code.
