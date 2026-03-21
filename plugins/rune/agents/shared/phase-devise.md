<!-- Source: Extracted from agents/utility/knowledge-keeper.md,
     agents/utility/scroll-reviewer.md, agents/utility/decree-arbiter.md -->

# Phase Devise — Shared Reference

Common patterns for devise-phase review agents (plan quality reviewers).

## Devise Review Agent Lifecycle

```
1. TaskList() → find available tasks
2. Claim task: TaskUpdate({ taskId, owner, status: "in_progress" })
3. Read the plan file from task context
4. Evaluate plan against assigned quality dimensions
5. Write review to output_path
6. Mark complete: TaskUpdate({ taskId, status: "completed" })
7. Send Seal to team-lead (max 50 words summary)
```

## Plan Review Agents

Three agents review plans from complementary perspectives:

| Agent | Focus | Verdict Type |
|-------|-------|-------------|
| decree-arbiter | Technical soundness, architecture fit, feasibility | PASS / CONCERN / BLOCK |
| knowledge-keeper | Documentation coverage, API docs, migration guides | PASS / CONCERN / BLOCK |
| scroll-reviewer | Document quality, clarity, actionability | A/B/C/D/F grade |

## Structured Verdict Markers

Plan review agents MUST include machine-parseable verdict markers for
arc Phase 2 circuit breaker:

```
<!-- VERDICT:{agent-name}:PASS -->
<!-- VERDICT:{agent-name}:CONCERN -->
<!-- VERDICT:{agent-name}:BLOCK -->
```

### Verdict Derivation (knowledge-keeper, decree-arbiter)

| Condition | Verdict |
|-----------|---------|
| Any BLOCK in any dimension | BLOCK |
| 2+ CONCERN across dimensions | CONCERN |
| 1 CONCERN, rest PASS | PASS (with notes) |
| All PASS | PASS |

### Quality Score (scroll-reviewer)

| Average Rating | Grade |
|---------------|-------|
| 4.5-5.0 | A |
| 3.5-4.4 | B |
| 2.5-3.4 | C |
| 1.5-2.4 | D |
| 1.0-1.4 | F |

**Critical override**: If Actionability or Completeness ≤ 2, grade capped at D.

## Evidence Format: Knowledge Trace

Plan reviewers verify claims against the actual codebase:

```markdown
- **Knowledge Trace:**
  - **Plan proposes:** "{quoted change from the plan}"
  - **Documentation impact:** {what docs exist and what needs updating}
    (discovered via {tool} `{query}`)
  - **Coverage:** COVERED | GAP | UNKNOWN
```

## Mandatory Codebase Exploration

Before writing ANY findings, plan reviewers MUST:

1. List top-level project structure (Glob `*`)
2. Glob for relevant files matching the plan's scope
3. Grep for references to APIs/interfaces the plan proposes to change
4. Check if existing code/docs reference concepts the plan modifies

Include `codebase_files_read: N` in output. If 0, output flagged as unreliable.

## Common Evaluation Criteria

### Scroll Reviewer Dimensions

| Dimension | What It Checks |
|-----------|---------------|
| Clarity | Is each section unambiguous? |
| Completeness | Are all necessary sections present? |
| Consistency | Do sections contradict each other? |
| Actionability | Can a developer implement from this? |
| Structure | Does the document flow logically? |

### Additional Checks (All Agents)

- **No Time Estimates**: Flag durations or level-of-effort language
- **Writing Style**: Flag passive voice, vague quantifiers
- **Traceability**: Acceptance criteria connect to problem statement
- **Self-Consistency**: Proposed solutions match technical approach

## Output Budget

Write full review to output file. Return only a 1-sentence summary
to team-lead via SendMessage (max 50 words).

## Hard Rule

> **"Suggest concrete fix text, not vague advice."**
> Every issue MUST include specific replacement text or rewrite suggestion.

## Agent-Specific Content (NOT in this shared file)

- 6-dimension documentation evaluation matrix (knowledge-keeper)
- Technical soundness checklist (decree-arbiter)
- Architecture fit assessment criteria (decree-arbiter)
- Critical challenge / devil's advocate lens (scroll-reviewer)
- Severity classification details per agent
- Echo integration query patterns per domain
