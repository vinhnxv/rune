# agents/shared/ — Shared Agent Reference Files

Shared reference files extracted from duplicated content across multiple agent definitions.
Agents load these via `Read()` directives in their Bootstrap Context section.

## Architecture: Two-Track Self-Read

Rune has two distinct spawn patterns for teammates. The Self-Read approach handles both:

| Pattern | subagent_type | Agent .md body loaded? | Read() in body works? | Used by |
|---------|--------------|----------------------|----------------------|---------|
| **Track 1** | `rune:{category}:{name}` | YES — body = system prompt | YES | strive, arc, mend, inspect |
| **Track 2** | `general-purpose` | NO — only prompt param | NO | appraise, devise plan-review |

### Track 1 — Custom subagent_type (body IS loaded)

Add `## Bootstrap Context` as **first content** in agent .md body:

```markdown
## Bootstrap Context (MANDATORY — Read ALL before any work)
1. Read `plugins/rune/agents/shared/communication-protocol.md`
2. Read `plugins/rune/agents/shared/context-checkpoint-protocol.md`
```

The agent reads shared files from disk at startup. Zero lead context burden.

### Track 2 — general-purpose (body NOT loaded)

Prepend Read() directives in the spawn prompt composition:

```javascript
const bootstrapDirectives = `
## Bootstrap Context (MANDATORY — Read ALL before any work)
1. Read plugins/rune/agents/shared/quality-gate-template.md
`
const composedPrompt = bootstrapDirectives + '\n' + agentBody
```

5-line bootstrap (~50 tokens) vs 400-line inline rules (~3000 tokens) = **95% lead context reduction per spawn**.

## Shared Files

### Core Protocols

| File | Lines | Track 1 Consumers (Read() in agent .md) | Track 2 Consumers (injected by orchestrator) | Content |
|------|-------|----------------------------------------|----------------------------------------------|---------|
| `communication-protocol.md` | ~36 | rune-smith, trial-forger, mend-fixer, gap-fixer, verdict-binder, grace-warden-inspect, sight-oracle-inspect, vigil-keeper-inspect, ruin-prophet-inspect | — | Seal format, shutdown handling, SendMessage conventions, exit conditions |
| `quality-gate-template.md` | ~37 | rune-smith, trial-forger, grace-warden-inspect, sight-oracle-inspect, vigil-keeper-inspect, ruin-prophet-inspect | ward-sentinel, knowledge-keeper (via devise/arc orchestrators) | Confidence calibration, Inner Flame supplementary, self-review pass |
| `context-checkpoint-protocol.md` | ~39 | rune-smith, trial-forger | — | Adaptive reset depth, Seal summary requirements, context rot detection |
| `iron-law-protocol.md` | ~31 | — | — | Iron Law enforcement wrapper ("this rule is absolute"), agent-specific law statements remain inline |
| `truthbinding-protocol.md` | ~96 | rune-smith, trial-forger, mend-fixer, gap-fixer, ward-sentinel, pattern-seer, flaw-hunter, lore-analyst, goldmask-coordinator, grace-warden-inspect, sight-oracle-inspect, vigil-keeper-inspect, ruin-prophet-inspect | — | ANCHOR/RE-ANCHOR Truthbinding security framing, untrusted content handling, injection defense |
| `finding-format-template.md` | ~62 | ward-sentinel, pattern-seer, flaw-hunter, grace-warden-inspect, knowledge-keeper | — | Standardized finding output format, severity levels, evidence requirements |

### Phase-Specific Protocols

| File | Lines | Track 1 Consumers (Read() in agent .md) | Content |
|------|-------|----------------------------------------|---------|
| `phase-review.md` | ~149 | ward-sentinel, pattern-seer, flaw-hunter, knowledge-keeper | Review-phase conventions, file scope, output format, review workflow |
| `phase-work.md` | ~112 | rune-smith, trial-forger | Work-phase swarm worker patterns, TDD cycle, ward checks, task lifecycle |
| `phase-goldmask.md` | ~101 | lore-analyst, goldmask-coordinator | Goldmask investigation patterns, risk scoring, lore layer conventions |
| `phase-inspect.md` | ~120 | grace-warden-inspect, sight-oracle-inspect, vigil-keeper-inspect, ruin-prophet-inspect | Inspect investigation patterns, requirement matrix, gap categories |
| `phase-devise.md` | ~121 | knowledge-keeper, scroll-reviewer, decree-arbiter | Devise/planning utility patterns, plan review conventions, enrichment workflow |

> **Note**: Track 2 consumers are general-purpose agents whose Read() directives are composed by orchestrator skills, not embedded in agent .md files. The `validate-agent-shared-refs.sh` script only validates Track 1 references. Track 2 validation is out of scope for the current script — broken Track 2 references are discovered at runtime.

## Rules

1. **DO NOT duplicate** — if content exists in a shared file, do not inline it in agent .md
2. **Extraction header** — every shared file has a `<!-- Source: -->` comment listing origin agents and date
3. **Agent-specific stays inline** — ANCHOR/RE-ANCHOR blocks, Iron Law statements, and role-specific rules remain in each agent's .md file
4. **Flat structure** — no transitive includes; shared files do not Read() other shared files
5. **Size cap** — shared files should stay under 150 lines each
6. **Bootstrap abort-on-failure** — if any Read() fails, agents should STOP and report to team-lead

## Enforcement Limitations

Bootstrap abort-on-failure (Rule #6) is **prompt-level enforcement only**. There is no hook, script, or programmatic check that verifies an agent actually stops when a `Read()` returns an error. The LLM may continue processing despite the error, especially under context pressure.

**Accepted risk**: Shared files are git-tracked and versioned. Accidental deletion or rename would be caught by PR review and the `validate-agent-shared-refs.sh` validation script (Check 1: SHARED-001 verifies file existence). The residual risk of an agent proceeding without shared protocol content is low-probability and bounded — agents would produce malformed output that downstream aggregation would reject.

**Future hardening options** (not currently implemented):
1. `SubagentStart` hook that validates shared file existence before the agent starts
2. `PreToolUse:TaskUpdate` hook that checks Bootstrap Read() completion before task claiming
3. PostToolUse:Read hook that tracks which shared files were successfully loaded
