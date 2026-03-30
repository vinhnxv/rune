# Rune

Multi-agent engineering orchestration for [Claude Code](https://claude.ai/claude-code). Plan features, implement with swarm workers, review code, and ship — all with parallel AI agents that each get their own dedicated context window.

<!-- DEMO_PLACEHOLDER — GIF/asciicast will be added in Phase 2 -->

## What Is This?

This is the **Rune plugin** — the detailed component reference for the Rune multi-agent orchestration system. It documents all 151 agents, 61 skills, 16 commands, 5 MCP servers, and the hook infrastructure that powers Rune's workflows.

For the high-level overview, see the [root README](../../README.md).

## Why This Exists

A single Claude Code agent reviewing 50 files loses focus by file 35. One agent hunting for security issues, performance bugs, and naming inconsistencies simultaneously does none well. Rune solves this by giving each task to a **specialized agent with its own full context window** — Ward Sentinel for security, Ember Oracle for performance, Pattern Seer for consistency — running in parallel.

The trade-off is token cost. Rune is designed for cases where quality, thoroughness, and coverage matter more than minimizing API usage. See [Cost Guide](#cost-guide).

## Quick Start

New to Rune? Three commands to go from idea to reviewed code:

```
/rune:plan  →  /rune:work  →  /rune:review
   Plan          Build          Review
```

```bash
# 1. Plan a feature
/rune:plan add user authentication with JWT

# 2. Implement the plan
/rune:work

# 3. Review the code
/rune:review
```

These are beginner-friendly aliases for `/rune:devise`, `/rune:strive`, and `/rune:appraise`.

**Want the full pipeline?** Run `/rune:arc plans/my-plan.md` for an automated 44-phase pipeline: plan enrichment → code review → auto-fix → testing → PR → merge.

**Not sure which command?** Use `/rune:tarnished` — the intelligent entry point that routes natural language to the right workflow (English and Vietnamese supported).

See the [Getting Started Guide](../../docs/guides/rune-getting-started.en.md) | [Hướng dẫn bắt đầu (VI)](../../docs/guides/rune-getting-started.vi.md) for a complete walkthrough.

## Install

### 1. Add the Plugin

```bash
/plugin marketplace add https://github.com/vinhnxv/rune
/plugin install rune
```

Restart Claude Code after installation.

### 2. Enable Agent Teams (Required)

Add to your `.claude/settings.json` or `.claude/settings.local.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### Recommended Settings

Include Rune output directories in Claude Code's context:

```json
{
  "includedGitignorePatterns": [
    "plans/", "todos/", "tmp/", "reviews/", ".rune/",
    ".claude/CLAUDE.local.md"
  ]
}
```

### MCP Server Dependencies (Auto-Installed)

Rune's MCP servers install their Python dependencies automatically on first use. No manual setup needed for most users.

<details>
<summary>Manual installation (advanced)</summary>

If auto-install fails or you prefer manual control:

```bash
# Using a virtual environment (recommended)
python3 -m venv ~/.rune-venv
source ~/.rune-venv/bin/activate
pip install "mcp[cli]>=1.2.0" "httpx>=0.27.0" "pydantic>=2.0"

# Or system-wide (macOS/Linux with protected Python)
python3 -m pip install "mcp[cli]>=1.2.0" "httpx>=0.27.0" "pydantic>=2.0" --break-system-packages
```

</details>

### Local Development

```bash
claude --plugin-dir /path/to/rune-plugin
```

## How It Works

Rune orchestrates multi-agent workflows through Claude Code's **Agent Teams**:

1. **You invoke a command** — e.g., `/rune:review` or `/rune:arc plans/my-plan.md`
2. **The Tarnished (orchestrator)** analyzes the scope, selects specialized agents, and creates a team
3. **Ash teammates spawn** — each in its own context window, with file-based coordination via `inscription.json`
4. **Work completes in parallel** — reviewers review, workers implement, researchers research
5. **Results aggregate** — findings merge into a TOME (review report), or code commits merge into a branch
6. **Team cleans up** — teammates shut down, temp files remain in `tmp/` until `/rune:rest`

For the full workflow state machines, see [docs/state-machine.md](../../docs/state-machine.md).

## Setup Process Details

1. **Install the plugin** via marketplace or local development (see [Install](#install))
2. **Enable Agent Teams** — add `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"` to settings
3. **Include output directories** — add `includedGitignorePatterns` for `plans/`, `tmp/`, `.rune/`
4. **(Optional) Initialize talisman** — run `/rune:talisman init` to generate `.rune/talisman.yml` tailored to your stack
5. **(Optional) Enable MCP servers** — Rune's 5 MCP servers (echo-search, figma-to-react, agent-search, context7, figma-context) auto-install dependencies on first use

## Platform Requirements & Compatibility

| Requirement | Minimum | Recommended |
|------------|---------|-------------|
| OS | macOS 12+, Linux (Ubuntu 20.04+) | macOS 14+, Ubuntu 22.04+ |
| Shell | bash 3.2+ or zsh 5.0+ | zsh (macOS default) |
| Claude Code | **2.1.81+** | Latest |
| Python | 3.11+ (for MCP servers) | 3.12+ |
| Node.js | 18+ (for Context7 MCP) | 20+ |
| jq | 1.6+ | Latest |
| git | 2.25+ | Latest |
| Claude Plan | Pro ($20/mo) for basic use | Max ($200/mo) for full Arc (end-to-end pipeline) |

> **Windows**: Not currently supported. WSL2 with Ubuntu may work but is untested.

## Cost Guide

Rune is a token-intensive multi-agent system. Each workflow summons multiple agents with dedicated context windows.

| Workflow | Tokens (est.) | Cost (est.) | Best for |
|----------|--------------|-------------|----------|
| `/rune:review` | ~10-30k | ~$0.30-1.00 | Quick code review |
| `/rune:plan` | ~30-60k | ~$1-3 | Feature planning |
| `/rune:arc` | ~200-500k | ~$5-15 | Full end-to-end pipeline |

> **We recommend Claude Max ($200/month).** A single `/rune:arc` run can use a significant portion of a lower-tier weekly limit. Use `--dry-run` to preview scope before committing.

## Core Workflows

| Command | What It Does |
|---------|-------------|
| `/rune:plan` | Plan a feature with multi-agent research |
| `/rune:work` | Implement a plan with swarm workers |
| `/rune:review` | Multi-agent code review (changed files) |
| `/rune:audit` | Full codebase audit (all files) |
| `/rune:arc` | End-to-end: plan → work → review → fix → test → ship → merge |
| `/rune:brainstorm` | Explore ideas before planning |
| `/rune:mend` | Auto-fix findings from a review |
| `/rune:inspect` | Compare plan vs. implementation |
| `/rune:goldmask` | Impact/blast-radius analysis |
| `/rune:debug` | Parallel hypothesis-based debugging |
| `/rune:tarnished` | Intelligent router — figures out which command to run |

### Batch & Automation

| Command | What It Does |
|---------|-------------|
| `/rune:arc-batch plans/*.md` | Run Arc (end-to-end pipeline) on multiple plans sequentially |
| `/rune:arc-issues --label "rune:ready"` | Process GitHub Issues → Plans → PRs automatically |
| `/rune:arc-hierarchy plans/parent.md` | Execute hierarchical child plans in dependency order |
| `/rune:arc-quick` | Quick 3-phase pipeline: plan -> work -> review (25-60 min) |

### Utilities

| Command | What It Does |
|---------|-------------|
| `/rune:echoes` | Manage persistent agent memory |
| `/rune:rest` | Clean up tmp/ artifacts |
| `/rune:talisman` | Configure Rune settings |
| `/rune:elicit` | Structured reasoning (Tree of Thoughts, Pre-mortem, etc.) |
| `/rune:self-audit` | Meta-QA audit of Rune's own system health |
| `/rune:cancel-arc` | Cancel active pipeline |

For the full command reference with all flags and options, see the [Command Reference Guide](../../docs/guides/rune-command-reference.en.md).

## Key Concepts

| Term | Plain Name | Description |
|------|-----------|-------------|
| Ash | Review agent | Specialized agent with its own context window |
| TOME | Review report | Consolidated findings from parallel reviewers |
| Tarnished | Orchestrator | The lead agent that coordinates workflows |
| Forge | Plan enrichment | Research phase that deepens a plan |
| Mend | Auto-fix findings | Parallel resolution of review findings |
| Arc | End-to-end pipeline | 44-phase automated workflow |
| Echoes | Persistent memory | Cross-session project knowledge |
| Roundtable Circle | Parallel review | Pattern for orchestrating multiple Ash (review agent) teammates |

See the [Glossary](../../docs/guides/rune-glossary.en.md) for the complete terminology reference.

## How It Works

### Review (`/rune:appraise`)

1. **Detects scope** — classifies changed files by extension
2. **Selects Ash (review agents)** — picks 3-9 specialized reviewers
3. **Reviews in parallel** — each Ash (review agent) gets its own context window
4. **Aggregates** — deduplicates and prioritizes findings into a TOME (review report)

### Plan → Work → Review

1. **Plan** (`/rune:devise`) — multi-agent research, synthesis, and review
2. **Work** (`/rune:strive`) — swarm workers implement tasks with incremental commits
3. **Review** (`/rune:appraise`) — parallel review with structured findings

### Arc (End-to-End Pipeline)

Chains 44 phases: Forge (plan enrichment) → Plan Review → Work → Gap Analysis → Code Review → Mend (auto-fix findings) → Test → Ship → Merge. Checkpoint-based resume (`--resume`) available if interrupted.

For detailed Arc (end-to-end pipeline) phase documentation, see the [Arc & Batch Guide](../../docs/guides/rune-arc-and-batch-guide.en.md).

## Configuration

Rune is configured via `.rune/talisman.yml`. Initialize with:

```bash
/rune:talisman init
```

Key settings: review depth, convergence tiers, cost optimization, custom Ash (review agent) definitions, and more. See the [Talisman Deep Dive Guide](../../docs/guides/rune-talisman-deep-dive-guide.en.md).

## User Documentation

| Guide | Topics |
|-------|--------|
| [Getting Started](../../docs/guides/rune-getting-started.en.md) | Plan → Work → Review in 3 commands |
| [Arc & Batch Guide](../../docs/guides/rune-arc-and-batch-guide.en.md) | Full pipeline, batch mode, arc-issues |
| [Planning Guide](../../docs/guides/rune-planning-and-plan-quality-guide.en.md) | devise, forge, plan-review, inspect |
| [Code Review & Audit](../../docs/guides/rune-code-review-and-audit-guide.en.md) | appraise, audit, mend |
| [Work Execution](../../docs/guides/rune-work-execution-guide.en.md) | strive, goldmask |
| [Advanced Workflows](../../docs/guides/rune-advanced-workflows-guide.en.md) | arc-hierarchy, arc-issues, echoes |
| [Talisman Configuration](../../docs/guides/rune-talisman-deep-dive-guide.en.md) | All configuration options |
| [Troubleshooting](../../docs/guides/rune-troubleshooting-and-optimization-guide.en.md) | Common issues and optimization |
| [FAQ](../../docs/guides/rune-faq.en.md) | Frequently asked questions |
| [Quick Cheat Sheet](../../docs/guides/rune-quick-cheat-sheet.en.md) | Command reference card |
| [Glossary](../../docs/guides/rune-glossary.en.md) | Terminology reference |

Vietnamese guides are also available — see `docs/guides/*-vi.md`.

## Community & Contributing

- [Contributing Guide](../../CONTRIBUTING.md) — how to contribute
- [Code of Conduct](../../CODE_OF_CONDUCT.md) — community standards
- [GitHub Discussions](https://github.com/vinhnxv/rune/discussions) — questions, ideas, show & tell
- [Issue Tracker](https://github.com/vinhnxv/rune/issues) — bug reports ([template](https://github.com/vinhnxv/rune/issues/new?template=bug_report.md)), feature requests ([template](https://github.com/vinhnxv/rune/issues/new?template=feature_request.md))

## Advanced Topics

<details>
<summary>MCP Servers</summary>

| Server | Purpose |
|--------|---------|
| `echo-search` | Full-text search over Echoes (persistent memory) using SQLite FTS5 |
| `figma-to-react` | Convert Figma designs to React + Tailwind CSS v4 components |
| `agent-search` | Agent registry search for workflow orchestrators |
| `context7` | Live framework documentation via Context7 |
| `figma-context` | AI-optimized Figma data extraction (~90% compression vs raw API) |

</details>

<details>
<summary>Codex Oracle (Cross-Model Verification)</summary>

When the `codex` CLI is installed, Rune adds Codex Oracle as a built-in Ash (review agent) for cross-model verification — a second AI perspective catching single-model blind spots. See [Advanced Workflows Guide](../../docs/guides/rune-advanced-workflows-guide.en.md).

</details>

<details>
<summary>Design Workflow</summary>

Rune includes domain-aware design intelligence: automatic project domain inference (ecommerce, saas, healthcare, fintech, media, social, education, productivity), industry-weighted UX scoring, and domain-specific design recommendations. The design system discovery pipeline (`discoverDesignSystem()`) detects installed component libraries, token systems, and project domain to provide contextual design guidance during planning and review. See reference files: [domain-inference.md](skills/design-system-discovery/references/domain-inference.md), [domain-design-guide.md](skills/frontend-design-patterns/references/domain-design-guide.md), [industry-weights.md](skills/ux-design-process/references/industry-weights.md).

</details>

<details>
<summary>Discipline Engineering</summary>

Rune implements proof-based orchestration ensuring specification compliance. Plans with YAML acceptance criteria (`AC-*` blocks) activate the Discipline Work Loop — an 8-phase convergence cycle. See [Discipline Engineering](../../docs/discipline-engineering.md).

</details>

<details>
<summary>Agent Architecture</summary>

Rune includes 151 specialized agents across 8 categories — 108 core (in `agents/`) + 43 extended (in `registry/`) — spanning review, research, work, utility, investigation, testing, qa, and meta-qa. Each agent gets its own dedicated context window via Agent Teams. Custom agents can be defined via `talisman.yml`. See the [Ash Guide skill](skills/ash-guide/SKILL.md) for the full registry.

</details>

## Requirements

- [Claude Code](https://claude.ai/claude-code) 2.1.81+
- Agent Teams enabled (see Install section)
- Python 3.11+ (for MCP servers)
- macOS or Linux

## Resources Overview

| Resource | Description |
|----------|-------------|
| [Root README](../../README.md) | High-level overview, workflow details, full agent catalog |
| [Documentation Hub](../../docs/README.md) | Guide index (English + Vietnamese) |
| [Getting Started](../../docs/guides/rune-getting-started.en.md) | First-time user walkthrough |
| [Arc & Batch Guide](../../docs/guides/rune-arc-and-batch-guide.en.md) | End-to-end pipeline, batch mode |
| [Talisman Deep Dive](../../docs/guides/rune-talisman-deep-dive-guide.en.md) | Full configuration reference |
| [Troubleshooting](../../docs/guides/rune-troubleshooting-and-optimization-guide.en.md) | Debugging, cost, optimization |
| [State Machines](../../docs/state-machine.md) | Mermaid diagrams of all 10 workflows |
| [Discipline Engineering](../../docs/discipline-engineering.md) | Proof-based architecture foundation |
| [Changelog](CHANGELOG.md) | Release history |
| [talisman.example.yml](talisman.example.yml) | Full configuration schema with all options |

## License

MIT
