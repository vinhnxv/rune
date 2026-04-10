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
Each "Ash" is a specialized AI agent with its own context window. Rune has 109 agents (66 core + 43 extended):
- **35+ review agents** — code quality, security, architecture, performance, design fidelity, UX, etc.
- **5 research agents** — codebase analysis, git history, best practices
- **24 investigation agents** — impact analysis, business logic tracing, hypothesis investigation
- **23+ utility agents** — aggregation, deployment verification, reasoning, condensing, design analysis
- **6+ work agents** — implementation (rune-smith, trial-forger, design-sync-agent, design-iterator, storybook-reviewer, storybook-fixer)
- **6 testing agents** — unit, integration, E2E, failure analysis, extended test runner, contract validator

Core agents live in `agents/` (always loaded). Extended agents live in `registry/` (discovered via MCP agent_search).

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

### Rune Echoes (Project Memory)
Agents persist learnings to `.rune/echoes/` after workflows. Future workflows
read these to avoid repeating mistakes. Five tiers:
- **Etched** — permanent project knowledge
- **Notes** — working notes (no TTL)
- **Inscribed** — tactical patterns (90-day TTL)
- **Observations** — auto-promoted patterns (60-day TTL)
- **Traced** — session observations (30-day TTL)

## MCP Integration — Extending Rune with External Tools

Rune supports third-party MCP (Model Context Protocol) servers as tool integrations.
This lets Rune agents use external tools during workflows like planning, implementation, and review.

### What is MCP Integration?

MCP servers provide AI-accessible tools via a standard protocol. Rune integrates these
at the workflow level — controlling which phases can use which tools, and when to activate them.

### 3 Levels of Integration

```
Level 1 (Basic): .mcp.json only
├── Tools available to Claude but NOT workflow-aware
├── No phase routing, no trigger conditions
└── Example: claude mcp add --transport http my-tool https://api.example.com

Level 2 (Talisman): + integrations.mcp_tools in talisman.yml
├── Phase routing: which Rune phases can use the tools (devise/strive/forge/arc...)
├── Trigger conditions: auto-activate based on file types, paths, keywords
├── Skill binding: auto-load companion skill when active
└── Rules injection: inject project-specific rules into agent prompts

Level 3 (Full): + companion skill + rules files + metadata
├── Dedicated skill with deep domain knowledge
├── Project-specific rules for quality enforcement
├── Metadata for discoverability (library name, homepage, MCP endpoint)
└── Example: untitledui-mcp skill (canonical reference implementation)
```

### Setting Up an MCP Integration

**Step 1**: Add the MCP server
```bash
claude mcp add --transport http my-tool https://api.example.com
```

**Step 2**: Configure in talisman (for workflow-aware integration)
```yaml
# .rune/talisman.yml
integrations:
  mcp_tools:
    my-tool:
      server_name: "my-tool"
      tools:
        - name: "search_items"
          category: "search"
        - name: "get_item_details"
          category: "details"
      phases:
        devise: true     # Available during planning
        strive: true     # Available during implementation
        forge: true      # Available during enrichment
      trigger:
        extensions: [".tsx", ".jsx"]
        keywords: ["frontend", "ui"]
```

**Step 3** (optional): Use `/rune:talisman init` — it auto-detects custom MCP servers
in `.mcp.json` and scaffolds the integrations section for you.

### UntitledUI — Canonical MCP Integration Example

UntitledUI is the first full Level 3 MCP integration in Rune. It provides:
- **6 MCP tools**: `search_components`, `list_components`, `get_component`, `get_component_bundle`, `get_page_templates`, `get_page_template_files`
- **Companion skill**: `untitledui-mcp` (auto-loaded by design-system-discovery)
- **Agent conventions**: React Aria `Aria*` prefix, Tailwind v4.1 semantic colors, kebab-case files
- **Builder Protocol**: Structured SEARCH → GET → CUSTOMIZE → VALIDATE workflow

**Setup**:
```bash
# Free tier (no auth needed)
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp

# PRO tier (with API key)
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp \
  --header "Authorization: Bearer YOUR_API_KEY"
```

**Key functions** (used by strive, devise, forge):
- `resolveMCPIntegrations(phase, context)` — triple-gated activation (config + phase + trigger)
- `buildMCPContextBlock(integrations)` — generates prompt injection for agents
- `buildBuilderWorkflowBlock(uiBuilder)` — generates structured workflow guidance

### MCP Integration Tips

1. Use `/rune:talisman guide integrations` for detailed configuration help
2. Use `/rune:talisman audit` to validate your integration config
3. Use `/rune:talisman status` to check if MCP servers are connected
4. The `trigger.always: true` setting forces the integration active for all matching phases
5. File-based triggers (`extensions`, `paths`) only fire during strive/forge (not devise, since no files exist yet during planning)

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
Yes, via `talisman.yml` configuration. You can disable agents, add custom agents,
adjust thresholds, and configure review behavior. Use `/rune:talisman` for deep
configuration management:
- `/rune:talisman init` — scaffold a new talisman.yml for your project
- `/rune:talisman audit` — find missing or outdated configuration keys
- `/rune:talisman guide codex` — learn about specific configuration sections
- `/rune:talisman update` — add missing sections to existing talisman

## Advanced Workflows

### Hierarchical Plans
For large features, `/rune:devise` can decompose into child plans (Phase 2.5 Shatter).
Execute with `/rune:arc-hierarchy` for dependency-aware child plan execution.

### Batch Execution
Run multiple plans overnight: `/rune:arc-batch plans/*.md`

### GitHub Issues Integration
Auto-generate plans from issues: `/rune:arc-issues --label "rune:ready"`

### Incremental Audits
Track audit coverage over time: `/rune:audit --incremental`
