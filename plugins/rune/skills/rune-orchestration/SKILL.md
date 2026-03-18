---
name: rune-orchestration
description: |
  Use when choosing between supervisor, swarm, or pipeline coordination for
  multi-agent workflows, when two agents produce conflicting findings and
  deduplication is needed, when TOME aggregation fails or produces duplicate
  prefixes, or when output format mismatch causes downstream parse errors.
  Use when defining inscription contracts for file-based handoff, or when
  detecting which Ash type to use for a given review dimension.
  Keywords: orchestration, conflict detection, TOME aggregation, inscription,
  output format mismatch, file-based handoff, supervisor, swarm, pipeline.

  <example>
  Context: Running multi-agent code review
  user: "Review this PR with multiple agents"
  assistant: "I'll use rune-orchestration for context isolation and file-based handoff"
  </example>

  <example>
  Context: Coordinating a codebase audit
  user: "Run an audit with security and performance focus"
  assistant: "I'll use rune-orchestration for audit agent coordination and output format"
  </example>
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Agent
  - Read
  - Write
---

# Rune Orchestration Skill

Guides designing distributed multi-agent systems that partition work across multiple language model instances to overcome single-agent context limitations.

## Core Principle

**Sub-agents exist primarily to isolate context, not to anthropomorphize role division.**

The fundamental value lies in distributing cognitive load across separate context windows rather than simulating organizational hierarchies.

## When to Use

| Category | Workflows | Orchestration Pattern |
|----------|-----------|----------------------|
| **Reviews** | `/rune:appraise` | Ash Specialists |
| **Audits** | `/rune:audit` | Roundtable Circle (Fan-out / Fan-in) |
| **Research** | `/rune:devise` | Parallel Exploration |
| **Work** | `/rune:strive` | Swarm Workers |
| **Custom** | Any workflow summoning 3+ agents | Choose pattern from below |

**Generic trigger conditions:**
- Context window constraints from single-agent approach
- Complex tasks requiring specialized expertise in parallel
- Need for parallel processing of independent subtasks
- Any workflow summoning 3+ agents via Agent tool or Agent Teams

## Agent Coordination Patterns

### File-Based Handoff Pattern

Instead of supervisor synthesizing responses (telephone game), agents write directly to files:

| Workflow Type | Output Directory | Output Type | Example Contents |
|---------------|------------------|-------------|------------------|
| Reviews | `tmp/reviews/{pr-number}/` | Report (P1/P2/P3) | `forge-warden.md`, `ward-sentinel.md`, `TOME.md` |
| Audits | `tmp/audit/{audit-id}/` | Report (P1/P2/P3) | `security.md`, `performance.md`, `TOME.md` |
| Plan research | `tmp/plans/{timestamp}/research/` | Research | `repo-analysis.md`, `best-practices.md`, `framework-docs.md` |
| Work (swarm) | `tmp/work/{timestamp}/` | Patches | `patches/*.patch`, `proposals/*.md`, `inscription.json` |
| Custom | `tmp/{workflow-name}/` | Varies | Named by teammate role |

**Directory Purpose:**
- **Persistent** (`todos/`): Findings that become actionable items
- **Ephemeral** (`tmp/`): Intermediate artifacts consumed by coordinator

The workflow: Agents write findings → Coordinator reads files → Synthesizes into Tome (TOME.md)

**Structured output:** Ash MAY also write companion JSON files (`{ash}-findings.json`) for CI/CD integration. Legacy: `completion.json` was used in early versions but is no longer written by built-in workflows. Use Seal metadata + TOME.md for workflow results. See [Output Format](../roundtable-circle/references/output-format.md) for full specs.

## Agent Output Formats

Each agent writes findings in a format matching its workflow type. All formats require mandatory evidence blocks.

- **Report Format** (Reviews, Audits): P1/P2/P3 severity with Rune Traces. See [Output Formats](references/output-formats.md)
- **Research Format** (Plans): Knowledge synthesis with sources. See [Output Formats](references/output-formats.md)
- **Status Format** (Work): Implementation progress reports. See [Output Formats](references/output-formats.md)

## Conflict Resolution Rules

When multiple agents flag the same code with different priorities:

| Conflict | Resolution |
|----------|------------|
| P1 vs P2 | P1 wins (highest priority) |
| P1 vs P1 (different issues) | Both retained |
| Security vs Performance | Security wins |
| Same issue, different agents | Deduplicate, keep first |

### Priority Hierarchy

```
ward-sentinel P1 > any other agent P1
any agent P1 > any agent P2
any agent P2 > any agent P3
```

## Three Architectural Patterns

### 1. Supervisor/Orchestrator (Default)

Central coordinator delegates to specialists and aggregates results.

```
The Tarnished (orchestrator)
    ├── forge-warden   (backend review)
    ├── ward-sentinel  (security review)
    ├── pattern-weaver (quality patterns)
    ├── glyph-scribe   (frontend review)
    └── knowledge-keeper    (docs review)
```

**Used by:** `/rune:appraise`, `/rune:audit`

**Mitigate telephone game:** Use file-based handoff, not message passing.

### 2. Peer-to-Peer/Swarm

Direct agent-to-agent communication. Workers self-organize and race to claim tasks.

**Used by:** `/rune:strive`

**Example use case:** Multiple rune-smiths claiming independent tasks from a shared pool.

### 3. Hierarchical

Layered abstractions. Use for complex multi-phase workflows.

```
Strategy Layer (plan)
    └── Planning Layer (spec)
        └── Execution Layer (implement)
```

**Used by:** `/rune:devise` → `/rune:strive` → `/rune:appraise`

## Agent Role Patterns

Defines how agents are organized for each workflow type, including conditional summoning rules and validation pipelines.

- **Review Ash**: Parallel specialists writing to `tmp/reviews/{pr}/`. See [Role Patterns](references/role-patterns.md)
- **Audit Ash**: Fan-out/fan-in to `tmp/audit/{id}/`. See [Role Patterns](references/role-patterns.md)
- **Research Agents**: Parallel exploration to `tmp/plans/{timestamp}/research/`. See [Role Patterns](references/role-patterns.md)
- **Work Agents (Rune Smiths)**: Swarm workers to `tmp/work/`. See [Role Patterns](references/role-patterns.md)
- **Conditional Ash**: Summoned based on file types in scope. See [Role Patterns](references/role-patterns.md)
- **Validation Agents (Truthsight Pipeline)**: Post-review verification. See [Role Patterns](references/role-patterns.md)

## Token Economics

| Approach | Token Multiplier | When to Use |
|----------|------------------|-------------|
| Single agent | 1x | Simple tasks |
| Multi-agent | ~15x | Complex review, parallel analysis |

**Guideline:** Use multi-agent only when context isolation is necessary, not for simple division of labor.

## Essential Failure Mitigations

### 1. Supervisor Saturation

**Problem:** Coordinator overwhelmed by aggregating many agent responses.

**Solution:** Glyph Budget — each agent writes to file, returns only file path + 1-sentence summary (max 50 words).

### 2. Coordination Overhead

**Problem:** Too much time on handoff protocols.

**Solution:** Clear file-based handoff with consistent format.

### 3. Lack of Convergence

**Problem:** Agents disagree indefinitely.

**Solution:**
- Time-to-live limits (max 2 iterations)
- Priority hierarchy for conflicts
- Human review for unresolved conflicts

### 4. Error Propagation

**Problem:** Early agent error cascades.

**Solution:**
- Validate outputs between agents
- Each agent reads source code directly, not previous agent's summary

## Glyph Budget

Every agent in a parallel workflow:
1. Writes detailed findings to a file
2. Returns only: file path + 1-sentence summary (max 50 words)
3. Does not include analysis in the return message

See `context-weaving` skill for the full Glyph Budget protocol and pre-summon checklist.

## Inscription Protocol

All Rune multi-agent workflows use Agent Teams (`TeamCreate`) + `inscription.json`.

```
Rune command (any agent count) → Agent Teams + inscription.json
Custom workflow (3+ agents)    → Agent Teams + inscription.json
```

**Three steps:**
1. **Generate** `inscription.json` before summoning agents/teammates
2. **Inject** required sections + Seal Format into each agent prompt
3. **Validate** output files after completion (circuit breaker → per-file → gap report)

Agents send structured **Seal** messages (key-value: file, sections, findings, evidence-verified, confidence, self-reviewed, summary). TaskList `completed` is authoritative; Seal is supplementary metadata.

Full spec: [Inscription Protocol](references/inscription-protocol.md)

## Structured Reasoning Integration

Multi-agent workflows benefit from structured reasoning at key decision points.

**Three reasoning checkpoints for the Tarnished:**

| Checkpoint | When | Key Action |
|-----------|------|------------|
| Pre-summon | Before launching agents | 8-thought checklist (see `context-weaving`) |
| Mid-monitor | During agent execution | Intervene on timeout, clarification requests, partial failures |
| Post-aggregate | After collecting all outputs | Resolve conflicts between agents using branching analysis |

Full protocol: [Structured Reasoning](references/structured-reasoning.md)

## Compaction Recovery

On context compaction or session resume during any Rune workflow:

1. Read active team config: `~/.claude/teams/{team-name}/config.json`
2. Read task list via `TaskList()` to discover team state
3. Read inscription contract: `tmp/{workflow}/{id}/inscription.json`
4. For arc workflows: read `.rune/arc/{id}/checkpoint.json`
5. Resume from the last incomplete task — do not re-read completed agent outputs
6. If team config is missing: the workflow was interrupted before team creation — restart

Session handoff template: [session-handoff.md](../../references/session-handoff.md)

## References

- [Output Formats](references/output-formats.md) — Report, Research, and Status output templates
- [Role Patterns](references/role-patterns.md) — Agent organization per workflow type, conditional summoning, validation pipeline
- [Structured Reasoning](references/structured-reasoning.md) — Reasoning principles for lead + teammate reasoning
- [Inscription Protocol](references/inscription-protocol.md) — Output validation for all multi-agent workflows
- [Prompt Weaving](references/prompt-weaving.md) — 7-section prompt template, context rot prevention, instruction anchoring
- [Truthsight Pipeline](references/truthsight-pipeline.md) — 4-layer verification spec
- [Verifier Prompt](references/verifier-prompt.md) — Smart Verifier prompt template
- [Damage Control](references/damage-control.md) — 6 recovery procedures for agent failures (DC-1 through DC-6)
- Companion: `context-weaving` (Glyph Budget, pre-summon checklist)
- Review workflow: `roundtable-circle` skill
