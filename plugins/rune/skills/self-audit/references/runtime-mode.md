# Runtime Mode — Self-Audit Reference

Full reference for `/rune:self-audit --mode runtime`.

## Overview

Runtime Mode analyzes completed arc run artifacts to detect systemic quality issues:

| Phase | Name | Description |
|-------|------|-------------|
| R0 | Locate Arc Artifacts | Auto-detect or explicit `--arc-id`, build artifact inventory |
| R1 | Spawn Runtime Agents | Parallel: hallucination-detector, effectiveness-analyzer, convergence-analyzer |
| R2 | Collect + Compute Metrics | Parse findings → `metrics.json`, cross-run comparison |
| R3 | Merge into Report | Add "Runtime Analysis" section to SELF-AUDIT-REPORT.md |

## Artifact Locations

| Artifact Type | Location | Notes |
|---------------|----------|-------|
| Checkpoint | `.rune/arc/{id}/checkpoint.json` | Persistent state — phases, retries, durations |
| Phase artifacts | `tmp/arc/{id}/` | TOME, QA verdicts, phase-log.jsonl, worker reports |
| TOME | `tmp/arc/{id}/TOME.md` | Aggregated review findings |
| QA verdicts | `tmp/arc/{id}/qa/` | Per-phase QA check results |
| Phase log | `tmp/arc/{id}/phase-log.jsonl` | Execution log with timestamps |
| Work summary | `tmp/arc/{id}/work-summary.md` | Worker task completion summary |

**CRITICAL**: Checkpoints live at `.rune/arc/{id}/checkpoint.json` (NOT `tmp/arc/`).
Phase artifacts live at `tmp/arc/{id}/`.

## Auto-Detection Algorithm

```javascript
function locateLatestArc() {
  const arcDirs = Glob(".rune/arc/arc-*")
  if (arcDirs.length === 0) return null

  // Reverse = newest first (IDs are timestamp-based: arc-XXXXXXXXXX)
  for (const dir of arcDirs.reverse()) {
    const checkpointPath = `${dir}/checkpoint.json`
    try {
      const checkpoint = JSON.parse(Read(checkpointPath))
      // Accept arc as "completed" if ship OR merge finished
      if (checkpoint.phases?.merge?.status === "completed" ||
          checkpoint.phases?.ship?.status === "completed") {
        const arcId = dir.split("/").pop()
        return {
          id: arcId,
          checkpointPath,
          artifactDir: `tmp/arc/${arcId}`,
          checkpoint
        }
      }
    } catch { continue }
  }
  return null  // No completed arcs found
}
```

## Multi-Run Collection (Trend Analysis)

```javascript
function collectRecentArcs(maxRuns = 5) {
  const arcDirs = Glob(".rune/arc/arc-*")
  const completed = []
  for (const dir of arcDirs.reverse()) {
    if (completed.length >= maxRuns) break
    try {
      const ckpt = JSON.parse(Read(`${dir}/checkpoint.json`))
      if (ckpt.phases?.ship?.status === "completed") {
        const arcId = dir.split("/").pop()
        completed.push({
          id: arcId,
          checkpointPath: `${dir}/checkpoint.json`,
          artifactDir: `tmp/arc/${arcId}`,
          checkpoint: ckpt
        })
      }
    } catch { continue }
  }
  return completed
}
```

## Runtime Agents

### hallucination-detector

Located at: `plugins/rune/agents/meta-qa/hallucination-detector.md`

**Purpose**: Detects phantom claims, inflated scores, evidence fabrication.

**Key checks**:

| Check ID | Check | Severity |
|----------|-------|----------|
| HD-PHANTOM-01 | Worker completion without evidence | HIGH |
| HD-PHANTOM-02 | Phantom artifact claims (file claimed but missing) | HIGH |
| HD-INFLATE-01 | QA score inflation (>50% PASS with no evidence) | MEDIUM |
| HD-INFLATE-02 | Copy-paste detection (>60% text similarity) | MEDIUM |
| HD-EVIDENCE-01 | Fabricated file:line references (file/line doesn't exist) | HIGH |
| HD-GHOST-01 | Ghost delegation (claimed agent count > actual) | LOW |

**Output**: `tmp/self-audit/{ts}/hallucination-findings.md`

**Output format**:
```markdown
# Hallucination Detection Findings

## HD-PHANTOM-01: Worker Completion Without Evidence
[Findings...]

## HD-INFLATE-01: QA Score Inflation
[Findings...]

## Summary
Total flags: N
```

### effectiveness-analyzer

Located at: `plugins/rune/agents/meta-qa/effectiveness-analyzer.md`

**Purpose**: Analyzes per-agent effectiveness metrics — finding accuracy, false-positive rates.

**Key metrics**:

| Metric | Formula | Target |
|--------|---------|--------|
| false_positive_rate | resolved_false_positive / total_findings | < 20% |
| unique_rate | unique_findings / total_findings | > 30% |
| findings_per_minute | finding_count / (duration_ms / 60000) | varies |

**Output**: `tmp/self-audit/{ts}/effectiveness-findings.md`

### convergence-analyzer

Located at: `plugins/rune/agents/meta-qa/convergence-analyzer.md`

**Purpose**: Analyzes retry patterns, quality trajectory, stagnation.

**Key checks**:

| Check ID | Description |
|----------|-------------|
| CV-RETRY-01 | Retry efficiency (score improvement per retry) |
| CV-STAGNATION-01 | Review-mend loops that didn't converge |
| CV-BOTTLENECK-01 | Phases with disproportionate duration |
| CV-TRAJECTORY-01 | Quality score trend across phases |

**Output**: `tmp/self-audit/{ts}/convergence-findings.md`

## Metrics Schema

The `metrics.json` file follows this schema (schema_version ensures future evolution):

```json
{
  "schema_version": "1.0",
  "arc_id": "arc-XXXXXXXXXX",
  "timestamp": "20260319-120000",
  "hallucination": {
    "phantom_claims": 0,
    "inflated_scores": 0,
    "fabricated_evidence": 0,
    "total_flags": 0
  },
  "effectiveness": {
    "agents_analyzed": 0,
    "avg_false_positive_rate": 0.0,
    "agents_with_high_fp": [],
    "agents_with_low_unique": []
  },
  "convergence": {
    "total_retries": 0,
    "wasted_retries": 0,
    "stagnation_phases": [],
    "bottleneck_phase": null
  },
  "trend": {
    "runs_compared": 1,
    "improving": [],
    "degrading": [],
    "stable": []
  }
}
```

## Error Recovery

| Failure Mode | Recovery |
|--------------|---------|
| No arc runs in `.rune/arc/` | Exit with "Run /rune:arc first" message |
| Arc found but no completed status | Skip to next arc candidate |
| No completed arcs found | Exit gracefully (no crash) |
| Agent output file missing | Skip that dimension (partial analysis > crash) |
| Artifact file missing (TOME, QA, etc.) | Mark dimension as "artifacts unavailable", continue |
| Checkpoint parse failure | Skip arc, log warning, continue scanning |

## Cross-Run Trend Analysis

When 2+ completed arcs are available, report trend per dimension:

```
Trend Analysis (last N runs):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Dimension           │ Run -3  │ Run -2  │ Latest  │ Trend
────────────────────┼─────────┼─────────┼─────────┼────────
Hallucination flags │ 4       │ 2       │ 1       │ ↓ Improving
FP rate (avg)       │ 0.25    │ 0.28    │ 0.22    │ ~ Stable
Wasted retries      │ 2       │ 5       │ 3       │ ~ Stable
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Trend symbols:
- `↓ Improving` — metric is decreasing (good for flags/rates/retries)
- `↑ Degrading` — metric is increasing (bad for flags/rates/retries)
- `~ Stable` — within ±10% variance

## Output Directory Structure

```
tmp/self-audit/{timestamp}/
├── SELF-AUDIT-REPORT.md      # Main report (static + runtime)
├── metrics.json              # Structured quantitative metrics
├── static-findings.md        # Phase 1 static audit output
├── hallucination-findings.md # hallucination-detector output
├── effectiveness-findings.md # effectiveness-analyzer output
└── convergence-findings.md   # convergence-analyzer output
```
