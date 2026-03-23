# Brainstorm Output Template

Template for the persistent brainstorm document written to `docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md`.

## Filename Convention

```
docs/brainstorms/YYYY-MM-DD-<topic-slug>-brainstorm.md
```

Examples:
- `docs/brainstorms/2026-03-02-real-time-notifications-brainstorm.md`
- `docs/brainstorms/2026-03-02-auth-system-redesign-brainstorm.md`
- `docs/brainstorms/2026-03-02-api-versioning-brainstorm.md`

Topic slug: lowercase, hyphens, max 50 chars, derived from feature description.

## Template

```markdown
---
title: "{feature title}"
date: YYYY-MM-DD
mode: "{solo|roundtable|deep}"
quality_score: {0.00-1.00}
quality_tier: "{excellent|good|developing|early}"
workspace: "tmp/brainstorm-{timestamp}"
advisors: ["{advisor-1}", "{advisor-2}", "{advisor-3}", "{advisor-4}"]  # omit for solo; advisor-4 = reality-arbiter (Team/Deep only)
scope_classification: "{QUICK-WIN|TACTICAL|STRATEGIC|MOONSHOT|null}"  # from Reality Arbiter or Solo scope question
effort_estimate: "{range or null}"  # from Reality Arbiter or Solo assessment
rounds_completed: {N}
approach_selected: "{chosen approach name}"
devise_ready: {true|false}
---

# Brainstorm: {Feature Title}

## What We're Building

{1-3 paragraph synthesis of what was explored and decided. Written as a clear statement
of intent — what the feature IS, not what it might be.}

## Advisor Perspectives

> **Note**: This section is present only in Roundtable and Deep modes.

### User Advocate

{Key observations about user needs, personas, pain points. Grounded in codebase
research — references to actual docs, README, user-facing code.}

### Tech Realist

{Key observations about feasibility, existing patterns, complexity. References
to actual files and patterns found in the codebase.}

### Devil's Advocate

{Key challenges raised, simpler alternatives proposed, YAGNI assessments.
References to git history, prior attempts, churn data.}

### Reality Arbiter

> **Note**: This section is present only in Roundtable and Deep modes.

{Scope classification, effort reality check, comparable analysis.
Grounded in git history and codebase complexity metrics.}

## Scope & Effort

**Scope Classification**: {QUICK-WIN | TACTICAL | STRATEGIC | MOONSHOT}
**Rationale**: {1-2 sentences explaining classification}
**Realistic effort**: {range, e.g., "3-5 days total"}
**Comparable work**: {commit/PR reference, or "No comparable found — elevated risk"}
**Hidden costs**: {list: tests, docs, migration, monitoring, etc.}
**Confidence**: {HIGH | MEDIUM | LOW}

> **Note**: In Solo mode, this section is simplified from the Lead's inline assessment.
> In Team/Deep mode, populated from the Reality Arbiter's output.

## Trade-offs

| Trade-off | What We Gain | What We Lose | Why Acceptable |
|-----------|-------------|-------------|----------------|
| {trade-off 1} | {gain} | {loss} | {rationale} |
| {trade-off 2} | {gain} | {loss} | {rationale} |

**Rejected alternatives**:
- {alt 1}: {why rejected} — reconsider if {condition}

## False Equivalence Warnings

> **Note**: This section is present only when false equivalences were flagged during Phase 3.

- [FALSE_EQUIVALENCE] {description and why it matters}

## Chosen Approach

**Approach**: {name of selected approach}

**Why**: {rationale for selection — synthesized from advisor perspectives}

**Trade-offs accepted**:
- {trade-off 1}
- {trade-off 2}

## Key Constraints

- {constraint 1 — from discussion}
- {constraint 2 — from discussion}
- {constraint 3 — from codebase research}

## Non-Goals

Explicitly out-of-scope items. Listed to prevent scope creep.

- {item 1} — {why excluded}
- {item 2} — {why excluded}

## Constraint Classification

| Constraint | Priority | Rationale |
|------------|----------|-----------|
| {constraint 1} | MUST | {why non-negotiable} |
| {constraint 2} | SHOULD | {why important but flexible} |
| {constraint 3} | NICE-TO-HAVE | {why desirable but deferrable} |

## Success Criteria

Measurable outcomes (distinct from acceptance criteria — these measure business/user impact).

- {criterion 1 — metric and target}
- {criterion 2 — metric and target}

## Scope Boundary

### In-Scope
- {item 1}
- {item 2}

### Out-of-Scope
- {item 1} (see Non-Goals)
- {item 2}

## Open Questions

Questions to resolve during planning/research (not during brainstorm).

- [ ] {question 1}
- [ ] {question 2}

## Design Assets

> **Note**: This section is present only when Figma URLs or design keywords were detected.

- **Figma URLs**: ${safeFigmaUrls.length > 0
    ? safeFigmaUrls.map((url, i) => `\n  ${i + 1}. [${url}](${url})`).join('')
    : 'none detected'}
- **Design keywords**: ${detectedKeywords || 'none'}
- **Status**: ${figmaUrl ? (wasUserProvided ? 'user-provided' : 'auto-detected') : 'none'}
- **design_sync_candidate**: ${design_sync_candidate}

## Elicitation Insights

> **Note**: This section is present only in Deep mode.

### {Method 1 Name}

{Summary of structured reasoning output from elicitation sage}

### {Method 2 Name}

{Summary of structured reasoning output from elicitation sage}

## State Machine Analysis

> **Note**: This section is present only when state-weaver pre-validation triggered (>= 5 phase indicators).

- **Verdict**: {PASS | CONCERN | BLOCK}
- **Findings**: {summary of state-weaver analysis}
```

## Mandatory Sections Checklist

Every brainstorm output MUST include these sections, regardless of mode:

- [ ] What We're Building
- [ ] Chosen Approach (with rationale)
- [ ] Key Constraints
- [ ] Non-Goals (at least 1 item)
- [ ] Constraint Classification (at least 2 rows)
- [ ] Success Criteria (at least 2 items)
- [ ] Scope Boundary (In-Scope + Out-of-Scope)
- [ ] Open Questions

Mandatory in Team/Deep mode (simplified in Solo):
- [ ] Scope & Effort (scope classification + effort reality check)
- [ ] Trade-offs (gain/lose/rationale table)

Conditional sections (include when applicable):
- [ ] Advisor Perspectives (Roundtable/Deep only)
- [ ] Reality Arbiter (Roundtable/Deep only)
- [ ] Design Assets (when Figma detected)
- [ ] Elicitation Insights (Deep only)
- [ ] State Machine Analysis (Deep, when triggered)
- [ ] False Equivalence Warnings (when flagged during Phase 3)

## Validation

If Non-Goals section is empty after brainstorm: warn user "Non-Goals section is empty — consider adding at least one exclusion to prevent scope creep."

If Key Constraints section has fewer than 2 items: warn user "Key Constraints section has fewer than 2 items — consider identifying technical or business constraints."

If Success Criteria section has fewer than 2 items: warn user "Success Criteria section has fewer than 2 items — consider adding measurable outcomes."

## Devise Consumption

When `/rune:devise --brainstorm-context tmp/brainstorm-{timestamp}/` reads this document:
- Frontmatter `quality_score` determines research confidence level
- `approach_selected` becomes the starting point for Phase 1 research
- `scope_classification` auto-selects plan detail level (STRATEGIC → Comprehensive, TACTICAL → Standard, QUICK-WIN → Minimal)
- `effort_estimate` pre-populates plan effort field (optional field access: `meta?.effort_estimate ?? null`)
- Non-Goals, Success Criteria, Scope Boundary are pre-populated into the plan
- Scope & Effort section feeds plan body for forge enrichment downstream
- Trade-offs section feeds plan body for forge enrichment downstream
- Open Questions guide research agent focus areas
- Advisor Perspectives provide starting context for research agents
