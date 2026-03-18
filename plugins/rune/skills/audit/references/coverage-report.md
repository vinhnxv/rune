# Coverage Report — Incremental Audit Dashboard

> Template and generation protocol for the human-readable coverage report.

## Report Location

`coverage-report.md` is generated to `.rune/audit-state/coverage-report.md` and displayed when using `--status` flag.

## Report Template

```markdown
# Incremental Audit Coverage Report

> Generated: {timestamp} | Session #{session_number}

## Overall Progress

| Metric | File (Tier 1) | Workflow (Tier 2) | API (Tier 3) |
|--------|---------------|-------------------|--------------|
| Total | {total_files} | {total_workflows} | {total_apis} |
| Audited | {audited_files} | {audited_workflows} | {audited_apis} |
| Coverage | {file_coverage}% | {wf_coverage}% | {api_coverage}% |
| Target | {target}% | {target}% | {target}% |
| Sessions to target | ~{est_sessions_files} | ~{est_sessions_wf} | ~{est_sessions_api} |

## Freshness Distribution (Tier 1 — Files)

| Tier | Count | Percentage | Definition |
|------|-------|------------|------------|
| FRESH | {fresh} | {fresh_pct}% | Audited < {window/3} days ago |
| RECENT | {recent} | {recent_pct}% | Audited < {window*2/3} days ago |
| STALE | {stale} | {stale_pct}% | Audited < {window} days ago |
| ANCIENT | {ancient} | {ancient_pct}% | Audited > {window} days or never |

## Directory Coverage Treemap

{for each top-level directory}
- `{dir}/` — {audited}/{total} files ({pct}%)
  {if pct == 0} **BLIND SPOT**
  {if pct < 25} Low coverage
{end}

## Top 10 Highest-Priority Unaudited Files

| # | File | Priority | Staleness | Risk | Last Modified |
|---|------|----------|-----------|------|--------------|
{for top 10 by priority_score where status == "never_audited"}
| {n} | {path} | {score} | never | {risk_tier} | {modified_at} |
{end}

## Top 5 Highest-Priority Workflows (if Tier 2 enabled)

| # | Workflow | Priority | Status | Files |
|---|----------|----------|--------|-------|
{for top 5 workflows by priority}
| {n} | {name} | {score} | {status} | {file_count} |
{end}

## Top 5 Highest-Priority API Endpoints (if Tier 3 enabled)

| # | Endpoint | Priority | Status | Security |
|---|----------|----------|--------|----------|
{for top 5 apis by priority}
| {n} | {method} {path} | {score} | {status} | {sensitivity} |
{end}

## Session Progress Log

| Session | Date | Files Audited | Coverage Delta | Findings |
|---------|------|---------------|----------------|----------|
{for last 10 sessions from history}
| #{n} | {date} | {files_completed} | +{delta}% | {total_findings} |
{end}

## Coverage Gaps (persistent)

{if gaps > 0}
| File | Gap Sessions | Reason | First Seen |
|------|-------------|--------|------------|
{for top 10 gaps by gap_count}
| {path} | {gap_count} | {reason} | {first_seen} |
{end}
{else}
No persistent coverage gaps.
{end}

## Configuration

- Batch size: {batch_size}
- Staleness window: {staleness_window_days} days
- Coverage target: {coverage_target * 100}%
- Weights: S={staleness} R={recency} Rk={risk} C={complexity} N={novelty} Ro={role}
- Tiers: File={file_enabled} Workflow={wf_enabled} API={api_enabled}
```

## Freshness Tier Definitions

Derived from `staleness_window_days` (default: 90):

| Tier | Definition | Default Window |
|------|-----------|---------------|
| FRESH | Audited within `window / 3` | < 30 days |
| RECENT | Audited within `window * 2/3` | < 60 days |
| STALE | Audited within `window` | < 90 days |
| ANCIENT | Audited beyond `window` or never | > 90 days |

## Estimated Sessions to Target

```
sessions_remaining = ceil(
  (target_coverage - current_coverage) * total_auditable / avg_batch_size
)
```

Uses rolling average of last 5 sessions' batch sizes for the estimate.

## Echo Persistence

After report generation, write an inscribed echo entry:

```
Target: .rune/echoes/auditor/MEMORY.md
Layer: inscribed

Content:
## Audit Coverage — {date}
- File coverage: {file_coverage}% ({audited}/{total})
- Workflow coverage: {wf_coverage}% or N/A
- API coverage: {api_coverage}% or N/A
- Top blind spots: {list of 0% dirs}
- Finding density: {avg_findings_per_file} per file
- Sessions to target: ~{est_sessions}
```

## --status Flag Behavior

When `/rune:audit --incremental --status` is invoked:

1. Read `.rune/audit-state/state.json`
2. Read `.rune/audit-state/workflows.json` (if exists)
3. Read `.rune/audit-state/apis.json` (if exists)
4. Read last 10 history entries
5. Generate and display coverage report
6. **No audit is performed** — report-only mode
7. Exit cleanly (no teams, no agents, no state changes)

## Zero-Workflow / Zero-API Handling

When Tier 2 or Tier 3 has no entries:
- Show "N/A — no workflows detected" instead of "0%"
- Show "N/A — no API endpoints detected" instead of "0%"
- Omit the corresponding "Top 5" section entirely
