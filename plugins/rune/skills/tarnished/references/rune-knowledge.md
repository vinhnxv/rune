# Rune Deep Knowledge

Comprehensive knowledge base for `/rune:tarnished` to guide and educate developers.

## What is Rune?

Rune is a multi-agent engineering orchestration plugin for Claude Code. It coordinates
teams of specialized AI agents (called "Ashes") to plan, implement, review, and audit
code. Think of it as a CI/CD pipeline — but for AI-assisted development.

The name comes from Elden Ring — the Tarnished (you/Claude) coordinates Ashes (agents)
through the Lands Between (your codebase).

## Core Workflow: Brainstorm → Plan → Work → Review

The most common Rune workflow is a 4-step cycle:

```
/rune:brainstorm  →  Explore the idea (optional but recommended)
     ↓
/rune:plan        →  Create a detailed plan for a feature
     ↓
/rune:work        →  AI agents implement the plan
     ↓
/rune:review      →  AI agents review the code changes
```

Start with `/rune:brainstorm` when the idea is vague, or skip to `/rune:plan` when requirements are clear.

## When to Use Which Command

### I want to...

| Goal | Command | Notes |
|------|---------|-------|
| **Explore an idea** | `/rune:brainstorm idea` | 3 modes: solo, roundtable, deep |
| **Quick brainstorm** | `/rune:brainstorm --quick idea` | Solo conversation, no agents |
| **Deep brainstorm** | `/rune:brainstorm --deep idea` | Advisors + elicitation sages |
| **Plan a feature** | `/rune:plan description` | Multi-agent research + synthesis |
| **Quick plan** | `/rune:plan --quick description` | Skip brainstorm + forge |
| **Implement a plan** | `/rune:work plans/my-plan.md` | Swarm workers execute tasks |
| **Review code changes** | `/rune:review` | Up to 7 review agents |
| **Deep review** | `/rune:review --deep` | Multi-wave with 18+ agents |
| **Full codebase audit** | `/rune:audit` | Scans all files, not just diff |
| **Fix review findings** | `/rune:mend tmp/.../TOME.md` | Parallel fix agents |
| **Enrich a plan** | `/rune:forge plans/my-plan.md` | Add expert perspectives |
| **End-to-end pipeline** | `/rune:arc plans/my-plan.md` | Plan → work → review → fix → ship |
| **Impact analysis** | `/rune:goldmask` | What will break if I change this? |
| **Structured thinking** | `/rune:elicit` | 24 reasoning methods |
| **Clean up temp files** | `/rune:rest` | Remove workflow artifacts |

### Decision Tree

```
Do you have a plan file?
├── No → Do you know what to build?
│   ├── Yes → /rune:plan "your feature"
│   └── No → /rune:brainstorm "your idea" (explore first)
│       └── After brainstorm → /rune:plan (auto-suggested)
└── Yes → Do you want full automation?
    ├── Yes → /rune:arc plans/my-plan.md
    └── No → /rune:work plans/my-plan.md

After implementation:
├── Quick review → /rune:review
├── Deep review → /rune:review --deep
├── Full audit → /rune:audit
└── Fix findings → /rune:mend tmp/.../TOME.md
```

## Key Concepts Explained

### Brainstorm (Idea Exploration)
The brainstorm skill (`/rune:brainstorm`) explores ideas before planning. Three modes:
- **Solo** — pure conversation, no agents. Fastest option.
- **Roundtable** — 3 advisor agents (User Advocate, Tech Realist, Devil's Advocate) engage you through structured discussion rounds. Advisors do lightweight codebase research.
- **Deep** — advisors + 1-3 elicitation sages for structured reasoning.

Output: `docs/brainstorms/YYYY-MM-DD-topic-brainstorm.md` (persistent project knowledge).
When ready to plan, brainstorm hands off to `/rune:devise --brainstorm-context` which reads the full workspace for rich research context.

**When to use brainstorm vs devise**:
- Use brainstorm when the idea is vague, you want to explore trade-offs, or multiple approaches exist
- Use devise directly when requirements are clear and specific

### Ashes (Agents)
Each "Ash" is a specialized AI agent with its own context window. Rune has 116 agents (74 core + 42 extended, plus 13 shared resources):

Core agents in `agents/`:
- **13 review agents** — code quality, security, architecture, performance, type safety, etc.
- **23 investigation agents** — impact analysis, business logic tracing, hypothesis investigation
- **16 utility agents** — aggregation, deployment verification, reasoning, condensing
- **7 research agents** — codebase analysis, git history, best practices
- **5 work agents** — implementation (rune-smith, trial-forger, gap-fixer, blind-verifier, micro-evaluator)
- **1 qa agent** — `phase-qa-verifier` (consolidated from 7 specialist verifiers in v3.0.0 Day-2)
- **9 meta-qa agents** — convergence-analyzer, effectiveness-analyzer, hallucination-detector, hook-integrity-auditor, improvement-advisor, necessity-analyzer, prompt-linter, rule-consistency-auditor, workflow-auditor

Extended agents in `registry/`:
- **25 review agents** — language/framework specialists
- **6 testing agents** — unit, integration, E2E, contract validator, etc.
- **5 utility agents**, **4 work agents**, **2 investigation agents**

Plus **13 shared resources** in `agents/shared/` (templates and protocols, not standalone agents).

Core agents live in `agents/` (always loaded). Extended agents live in `registry/` (discovered via agent_search MCP).
See [agent-registry.md](../../../references/agent-registry.md) for the full per-agent listing.

### TOME (Review Output)
The "TOME" is the unified review summary after all agents complete their analysis.
It contains deduplicated, prioritized findings with structured markers for machine parsing.
Location: `tmp/reviews/{id}/TOME.md` or `tmp/audit/{id}/TOME.md`

### Inscription (Agent Contract)
The `inscription.json` defines what each agent must produce — required sections,
output format, and seal markers for completion detection.

### Forge (Plan Enrichment)
The Forge phase enriches a plan with expert perspectives using "Forge Gaze" —
topic-aware agent matching that assigns domain experts to plan sections.

### Arc (Full Pipeline)
The Arc is Rune's end-to-end pipeline: forge → plan review → work → gap analysis →
code review → mend → test → ship → merge. It's the "do everything" command.

### Persistent Memory — Removed in v3.0.0-alpha.1

The `rune-echoes` project-memory runtime was removed in v3.0.0-alpha.1; agent output
is now ephemeral (`tmp/`). See CLAUDE.md Core Rule #6.

## MCP Integration — Extending Rune with External Tools

Rune v3.x consumes third-party MCP (Model Context Protocol) servers via the standard
Claude Code config (`.mcp.json`), with optional companion skills for workflow-aware
routing. Workflow-level config of MCP servers (the v2.x `talisman.yml integrations`
layer) was removed in v3.0.0-alpha.4 — see `references/v3-defaults.md`.

### What is MCP Integration?

MCP servers provide AI-accessible tools via a standard protocol. Rune integrates these
at the workflow level — controlling which phases can use which tools, and when to activate them.

### v3.x Integration Model

Rune v3.x has **two tiers** of MCP integration (vocabulary aligned: tier-1 / tier-2):

```
Tier 1 (Basic): .mcp.json only
├── Tools available to Claude across all sessions
└── Example: claude mcp add --transport http my-tool https://api.example.com

Tier 2 (Full): tier-1 + companion skill that carries domain knowledge
├── A skill with `name: <tool>-mcp` describes when and how Rune agents should
│   call the MCP tools (no bundled reference implementation in v3.x — the
│   pattern is documented but not shipped).
└── No workflow-aware tool routing in v3.x (former `talisman.yml integrations`
    layer was removed in v3.0.0-alpha.4).
```

### Setting Up an MCP Integration

**Step 1**: Add the MCP server
```bash
claude mcp add --transport http my-tool https://api.example.com
```

**Step 2**: (Optional) Add a companion skill at `plugins/rune/skills/<tool>-mcp/SKILL.md`
or `.claude/skills/<tool>-mcp/SKILL.md` describing the tool surface and usage patterns.
Without a companion skill, agents can still call MCP tools but lack project-specific
guidance.

### MCP Integration Tips

For MCP integration troubleshooting in v3.x: edit `.mcp.json` directly and validate JSON
syntax. The legacy `/rune:talisman` configurator was removed in v3.0.0-alpha.4 — there is
no `talisman.yml` config layer to inspect. See [`v3-defaults.md`](../../../references/v3-defaults.md)
for the `integrations` defaults inventory.

## Common Pitfalls & Tips

### 1. "Which plan do I use?"
Plans are in `plans/` directory, named by date. The most recent one is usually what you want.
Use `Glob("plans/*.md")` to find available plans.

### 2. "The review found too many issues"
Start with `/rune:review` (standard). Only use `--deep` when you want exhaustive analysis.
P1 findings are critical, P2 are important, P3 are nice-to-have.

### 3. "The work phase is taking too long"
Swarm workers operate in parallel. Complex plans with many tasks take longer.
Use `--approve` flag to auto-approve worker commits for faster execution.

### 4. "I want to skip some arc phases"
Use `--no-forge` to skip enrichment. Or break the arc into individual steps:
plan → work → review (manually, without the full arc pipeline).

### 5. "How do I resume a failed arc?"
Use `/rune:arc --resume` — it reads the checkpoint file and continues from where it stopped.

### 6. "What's the difference between review and audit?"
- **Review** (`/rune:appraise`) — only reviews changed files (git diff)
- **Audit** (`/rune:audit`) — reviews the entire codebase

### 7. "Can I customize which agents run?"
Yes — wire custom Ashes via the orchestration layer (`.claude/agents/<name>.md`). See `plugins/rune/skills/roundtable-circle/references/custom-ashes.md` for the wiring pattern.

- Rune v3.x ships with hardcoded defaults. To inspect baked-in values, see `plugins/rune/references/v3-defaults.md`. There is no user-config layer to initialize, audit, or update.

## Advanced Workflows

### Incremental Audits
Track audit coverage over time: `/rune:audit --incremental`

> **v3.0.0-alpha.1 removed**: `/rune:arc-batch`, `/rune:arc-issues`, `/rune:arc-hierarchy`,
> `/rune:design-sync`, `/rune:design-prototype`, `/rune:ux-design-process`,
> `/rune:elevate`, `/rune:learn`. Run individual `/rune:arc plans/{file}.md`
> invocations or external orchestration in place of the removed batch commands.
