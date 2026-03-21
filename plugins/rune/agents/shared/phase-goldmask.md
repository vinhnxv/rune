<!-- Source: Extracted from agents/investigation/lore-analyst.md,
     agents/investigation/goldmask-coordinator.md -->

# Phase Goldmask — Shared Reference

Common patterns for Goldmask investigation agents (Impact + Wisdom + Lore layers).

## Goldmask Architecture

The Goldmask pipeline synthesizes findings across three layers:

| Layer | Agents | Purpose |
|-------|--------|---------|
| Impact | 5 tracers (API, business-logic, data-layer, config-dependency, event-message) | WHAT changed and WHERE it ripples |
| Wisdom | wisdom-sage | WHY code was written (git archaeology, developer intent) |
| Lore | lore-analyst | Risk scores from quantitative git history analysis |

The **goldmask-coordinator** merges all three layers into a unified GOLDMASK.md report.

## Investigation Agent Lifecycle

```
1. TaskList() → find available tasks
2. Claim task: TaskUpdate({ taskId, owner, status: "in_progress" })
3. Read task context (diff spec, file list, plan references)
4. Execute analysis protocol (layer-specific)
5. Write findings to output_path
6. Mark complete: TaskUpdate({ taskId, status: "completed" })
7. Send Seal to team-lead
```

## Lore Layer — Risk Scoring

The lore-analyst computes per-file risk scores using quantitative git metrics:

| Metric | Weight | What It Measures |
|--------|--------|-----------------|
| Churn rate | 0.30 | Change frequency (commits/month) |
| Defect correlation | 0.25 | Fix-commit density |
| Author concentration | 0.20 | Bus factor (ownership spread) |
| Recency | 0.15 | Time since last change |
| Complexity proxy | 0.10 | File size as complexity estimate |

### Risk Tiers

| Tier | Score Range | Meaning |
|------|------------|---------|
| CRITICAL | 80-100 | Highest risk — frequent changes, many fixes, few owners |
| HIGH | 60-79 | Elevated risk |
| MEDIUM | 40-59 | Moderate risk |
| LOW | 20-39 | Lower risk |
| STALE | 0-19 | Rarely touched — may indicate abandonment |

Output: `risk-map.json` with per-file scores, tiers, and co-change clusters.

## Coordinator Synthesis Protocol

The goldmask-coordinator merges layer outputs using a 3D priority formula:

```
priority = 0.40 * impact + 0.35 * caution + 0.25 * risk
```

### Synthesis Steps

1. Read Impact Layer outputs (5 tracer reports)
2. Read Wisdom Layer output (intent analysis)
3. Read Lore Layer output (risk-map.json)
4. Build correlation graph (file → [impact, caution, risk])
5. Compute 3D priority scores
6. Assess collateral damage (files affected by changes)
7. Detect swarm patterns (multiple findings converging on same area)
8. Double-check top 5 findings
9. Produce GOLDMASK.md + findings.json

## Output Format

```markdown
# GOLDMASK — Cross-Layer Impact Analysis

## Priority Matrix
| File | Impact | Caution | Risk | Priority | Category |

## Collateral Damage Assessment
{Files affected indirectly by changes}

## Swarm Detection
{Areas where multiple findings converge}

## Top Findings
{Prioritized by 3D formula}
```

## Agent-Specific Content (NOT in this shared file)

- Individual tracer analysis protocols (API, business-logic, etc.)
- Git command sequences for lore-analyst metrics
- Guard checks G1-G5 (lore-analyst validation)
- Wisdom-sage intent classification taxonomy
- Co-change graph construction algorithm
- Percentile normalization details
