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

| File | Lines | Source Agents | Content |
|------|-------|---------------|---------|
| `communication-protocol.md` | ~25 | rune-smith, trial-forger, mend-fixer, gap-fixer | Seal format, shutdown handling, SendMessage conventions, exit conditions |
| `quality-gate-template.md` | ~30 | ward-sentinel, knowledge-keeper | Confidence calibration, Inner Flame supplementary, self-review pass |
| `context-checkpoint-protocol.md` | ~30 | rune-smith, trial-forger | Adaptive reset depth, Seal summary requirements, context rot detection |

## Rules

1. **DO NOT duplicate** — if content exists in a shared file, do not inline it in agent .md
2. **Extraction header** — every shared file has a `<!-- Source: -->` comment listing origin agents and date
3. **Agent-specific stays inline** — ANCHOR/RE-ANCHOR blocks, Iron Law statements, and role-specific rules remain in each agent's .md file
4. **Flat structure** — no transitive includes; shared files do not Read() other shared files
5. **Size cap** — shared files should stay under 150 lines each
6. **Bootstrap abort-on-failure** — if any Read() fails, agents should STOP and report to team-lead
