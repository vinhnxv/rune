# Rune

Multi-agent engineering orchestration for [Claude Code](https://claude.ai/claude-code). Plan features, implement with swarm workers, review code, and ship — all with parallel AI agents that each get their own dedicated context window.

**Current version**: [3.0.0-alpha.8](CHANGELOG.md) — v3 lean rebuild. Day 6.5 Tier-A skill trim retires 5 reference-only skills (zsh-compat, polling-guard, chome-pattern, runs, team-status); ZSH-001/POLL-001 hooks preserve runtime enforcement; CHOME pattern inlined as Core Rule #17.

## What Is This?

This is the **Rune plugin** — the detailed component reference for the Rune multi-agent orchestration system. It documents all 116 agents (74 core + 42 extended, plus 13 shared resources), 37 skills, 11 commands, and the hook infrastructure that powers Rune's workflows.

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

**Want the full pipeline?** Run `/rune:arc plans/my-plan.md` for an automated 16-phase pipeline (default; v3.0.0-alpha.7): plan enrichment → code review → auto-fix → testing → PR → merge.

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

> v3.0.0-alpha.1 removed all bundled MCP servers (echo-search, agent-search, context7, figma-to-react, figma-context). MCP integrations are now opt-in at the user level via `~/.claude/mcp.json`.

## Platform Requirements & Compatibility

| Requirement | Minimum | Recommended |
|------------|---------|-------------|
| OS | macOS 12+, Linux (Ubuntu 20.04+) | macOS 14+, Ubuntu 22.04+ |
| Shell | bash 3.2+ or zsh 5.0+ | zsh (macOS default) |
| Claude Code | **2.1.81+** | Latest |
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
| `/rune:inspect` | Compare plan vs. implementation (or `--verify-tome <path>` to classify TOME findings as TRUE_POSITIVE / FALSE_POSITIVE / NEEDS_CONTEXT) |
| `/rune:goldmask` | Impact/blast-radius analysis |
| `/rune:debug` | Parallel hypothesis-based debugging |
| `/rune:tarnished` | Intelligent router — figures out which command to run |

### Quick Pipeline

| Command | What It Does |
|---------|-------------|
| `/rune:arc --quick-mode` | Quick 4-phase pipeline: plan -> work -> review -> mend (25-60 min) |
| `/rune:quick` | Beginner alias — forwards to `/rune:arc --quick-mode` |

### Utilities

| Command | What It Does |
|---------|-------------|
| `/rune:rest` | Clean up tmp/ artifacts |
| `/rune:elicit` | Structured reasoning (Tree of Thoughts, Pre-mortem, etc.) |
| `/rune:self-audit` | Meta-QA audit of Rune's own system health |
| `/rune:pr-guardian` | Automated PR shepherd loop — cron-based auto-merge |
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
| Arc | End-to-end pipeline | 16-phase automated workflow (default; v3.0.0-alpha.7) |
| Roundtable Circle | Parallel review | Pattern for orchestrating multiple Ash (review agent) teammates |

> Persistent memory was removed in v3.0.0-alpha.1; agent output is now ephemeral (`tmp/`).

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

Chains 16 phases (default; v3.0.0-alpha.7): Forge (plan enrichment) → Plan Review → Work → Inspect (deterministic checks + plan-vs-impl audit + halt-gate + gap-fixer dispatch + convergence — all in one phase as of v3.0.0-alpha.7) → Code Review → Verify (finding verification) → Mend (auto-fix findings) → Test → Ship → Merge. Each phase has its own QA gate (forge_qa, work_qa, code_review_qa, mend_qa, test_qa). Checkpoint-based resume (`--resume`) available if interrupted.

For detailed Arc (end-to-end pipeline) phase documentation, see the [Arc & Batch Guide](../../docs/guides/rune-arc-and-batch-guide.en.md).

## Configuration

v3.x ships with baked-in defaults — there is no user config layer. See [`references/v3-defaults.md`](references/v3-defaults.md) for the inventory of every former-config knob and its baked v3.x value.

## User Documentation

| Guide | Topics |
|-------|--------|
| [Getting Started](../../docs/guides/rune-getting-started.en.md) | Plan → Work → Review in 3 commands |
| [Arc Guide](../../docs/guides/rune-arc-and-batch-guide.en.md) | Full pipeline, arc phases, checkpoint resume |
| [Planning Guide](../../docs/guides/rune-planning-and-plan-quality-guide.en.md) | devise, forge, plan-review, inspect |
| [Code Review & Audit](../../docs/guides/rune-code-review-and-audit-guide.en.md) | appraise, audit, mend |
| [Work Execution](../../docs/guides/rune-work-execution-guide.en.md) | strive, goldmask |
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

MCP servers are now opt-in at the user level via `~/.claude/mcp.json`. None are bundled with the plugin. (v3.0.0-alpha.1 removed all bundled MCP servers — `echo-search`, `agent-search`, `context7`, `figma-context`. `figma-to-react` was removed earlier in v2.69.0.)

**MCP/LSP Process Protection (MCP-PROTECT-004):** All MCP and LSP server processes are protected from accidental cleanup kills via a 3-layer detection strategy in `scripts/lib/process-tree.sh`:
1. **Known binary whitelist** — 60+ named MCP servers (Rune, Anthropic official, database, cloud, browser, search, UI) + 18+ LSP servers
2. **Transport markers** — `--stdio`, `--lsp`, `--sse`, `--transport` flags
3. **Generic pattern matching** — any process with `mcp`/`lsp` in its cmdline (both prefix and suffix)

</details>

<details>
<summary>Stop Hook Safety (v2.44.1)</summary>

Rune uses 10 Stop hooks for arc phase loop driving, workflow cleanup, and stale teammate detection. Session isolation uses `session_id` as the primary ownership signal (not `$PPID`, which is unreliable in hook subprocess context per Claude Code architecture). Key safety properties:
- **Fail-forward**: All operational hooks exit 0 on errors — never block the session
- **EXIT trap safety**: `arc-phase-stop-hook.sh` forces exit 0 on any unintended error, preserving exit 2 only for intentional phase injection
- **Conservative defer**: Cleanup hooks defer to active arc loops via freshness checks even when ownership cannot be determined
- **Timeout budgets**: Per-loop budget guards prevent jq-heavy iteration from exceeding hook timeouts

</details>

<details>
<summary>Discipline Engineering</summary>

Rune implements proof-based orchestration ensuring specification compliance. Plans with YAML acceptance criteria (`AC-*` blocks) activate the Discipline Work Loop — an 8-phase convergence cycle. See [Discipline Engineering](../../docs/discipline-engineering.md).

</details>

<details>
<summary>Agent Architecture</summary>

Rune includes 116 specialized agents — 74 core (in `agents/`: 13 review + 23 investigation + 16 utility + 7 research + 5 work + 1 qa + 9 meta-qa) + 42 extended (in `registry/`: 25 review + 6 testing + 5 utility + 4 work + 2 investigation), plus 13 shared resources in `agents/shared/`. Each agent gets its own dedicated context window via Agent Teams. Custom agents must be added directly to the plugin's agent registry. See the [Ash Guide skill](skills/ash-guide/SKILL.md) and [agent-registry.md](references/agent-registry.md) for the full registry.

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
| [Troubleshooting](../../docs/guides/rune-troubleshooting-and-optimization-guide.en.md) | Debugging, cost, optimization |
| [State Machines](../../docs/state-machine.md) | Mermaid diagrams of all 10 workflows |
| [Discipline Engineering](../../docs/discipline-engineering.md) | Proof-based architecture foundation |
| [Changelog](CHANGELOG.md) | Release history |
| [v3.x Defaults](references/v3-defaults.md) | Inventory of baked-in former-config values |

## License

MIT
