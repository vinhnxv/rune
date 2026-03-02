# Rune

**Multi-agent engineering orchestration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).**

Plan, implement, review, test, and audit your codebase using coordinated Agent Teams — each teammate with its own dedicated context window.

[![Version](https://img.shields.io/badge/version-1.128.0-blue)](.claude-plugin/marketplace.json)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Agents](https://img.shields.io/badge/agents-94-purple)](#agents)
[![Skills](https://img.shields.io/badge/skills-45-orange)](#skills)

---

## Why Multi-Agent?

Claude Code is powerful on its own — but a single agent has a single context window. As tasks grow in scope (reviewing a 50-file diff, planning a feature across multiple services, running a full implementation pipeline), one context window becomes the bottleneck:

- **Context saturation** — A single agent reviewing 40 files loses focus on file 35. Rune gives each reviewer its own full context window, so the last file gets the same attention as the first.
- **Specialization over generalization** — One agent trying to catch security issues, performance bugs, and naming inconsistencies simultaneously does none of them well. Rune dispatches Ward Sentinel for security, Ember Oracle for performance, and Pattern Seer for consistency — each focused on what it does best.
- **Parallelism** — Sequential work on 6 implementation tasks takes 6x as long. Swarm workers claim and complete tasks independently, bounded only by file-level conflicts.
- **Separation of concerns** — Planning, implementing, reviewing, and testing in one context creates confirmation bias (the same agent reviews code it just wrote). Rune enforces phase boundaries: different agents plan, build, and critique.

The trade-off is token cost — multi-agent workflows consume more tokens than a single session. Rune is designed for cases where quality, thoroughness, and coverage matter more than minimizing API usage.

---

<a name="token-warning"></a>

> [!WARNING]
> **Rune is token-intensive and time-intensive.**
>
> Each workflow spawns multiple agents, each with its own dedicated context window. This means higher token consumption and longer runtimes than single-agent usage.
>
> | Workflow | Typical Duration | Why |
> |----------|-----------------|-----|
> | `/rune:devise` | 10–30 min | Up to 7 agents across 7 phases (brainstorm, research, synthesize, forge, review) |
> | `/rune:appraise` | 5–20 min | Up to 8 review agents analyzing your diff in parallel — scales with LOC changed |
> | `/rune:audit` | 10–30 min | Full codebase scan — same agents, broader scope |
> | `/rune:strive` | 10–30 min | Swarm workers implementing tasks in parallel |
> | `/rune:arc` | **1–2 hours** | Full 26-phase pipeline (forge → plan review → work → gap analysis → code review → mend → test → ship → merge) |
> | `/rune:arc` (complex) | **up to 3 hours** | Large plans with multiple review-mend convergence loops |
>
> `/rune:arc` is intentionally slow because it runs the **entire software development lifecycle** autonomously — planning enrichment, parallel implementation, multi-agent code review, automated fixes, 3-tier testing, and PR creation. Each phase spawns and tears down a separate agent team. The result is higher quality, but it takes time.
>
> **Want faster iterations?** Run the steps individually instead of the full pipeline:
>
> ```
> /rune:plan   →  /rune:work   →  /rune:review
>  (10–30 min)    (10–30 min)     (5–20 min)
> ```
>
> This gives you the same core workflow (plan → implement → review) in **25–80 minutes** with manual control between steps — versus 1–3 hours for `/rune:arc` which adds forge enrichment, gap analysis, automated mend loops, 3-tier testing, and PR creation on top.
>
> **Claude Max ($200/month) or higher recommended.** Use `--dry-run` where available to preview scope before committing.

---

## Install

```bash
/plugin marketplace add https://github.com/vinhnxv/rune-plugin
/plugin install rune
```

Restart Claude Code after installation.

<details>
<summary>Local development</summary>

```bash
claude --plugin-dir /path/to/rune-plugin
```
</details>

### Setup

Rune requires [Agent Teams](https://code.claude.com/docs/en/agent-teams). Enable it in `.claude/settings.json` or `.claude/settings.local.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "includedGitignorePatterns": [
    "plans/",
    "todos/",
    "tmp/",
    "reviews/",
    ".claude/arc/",
    ".claude/echoes/",
    ".claude/arc-batch-loop.local.md",
    ".claude/arc-phase-loop.local.md",
    ".claude/arc-hierarchy-loop.local.md",
    ".claude/arc-issues-loop.local.md",
    ".claude/CLAUDE.local.md",
    ".claude/talisman.yml"
  ]
}
```

`includedGitignorePatterns` lets Claude Code read Rune's output directories that are typically gitignored.

### Quick Configuration (Optional)

Generate a `talisman.yml` tailored to your project's tech stack:

```bash
/rune:talisman init      # Auto-detect stack and generate .claude/talisman.yml
/rune:talisman audit     # Check existing config for missing/outdated sections
/rune:talisman status    # Overview of current configuration health
```

See the [Talisman deep dive](docs/guides/rune-talisman-deep-dive-guide.en.md) for full configuration coverage.

---

## How It Works

Rune orchestrates **multi-agent workflows** where specialized AI teammates collaborate through shared task lists and file-based communication. Instead of one agent doing everything in a single context window, Rune splits work across purpose-built agents — each with its own full context window.

```
You ──► /rune:devise ──► Plan
                           │
         /rune:arc ◄───────┘
             │
             ├─ Forge & Validate     enrich plan, review architecture, refine
             ├─ Work                 swarm workers implement in parallel
             ├─ Gap Analysis         detect and remediate implementation gaps
             ├─ Review & Mend        multi-agent code review + auto-fix findings
             ├─ Test                 3-tier testing (unit → integration → E2E)
             ├─ Ship                 validate and create PR
             └─ Merge               rebase and merge
```

---

## Workflows

### Quick Start (New Users)

| Command | What it does | Alias for |
|---------|-------------|-----------|
| `/rune:plan` | Plan a feature or task | `/rune:devise` |
| `/rune:work` | Implement a plan with AI workers | `/rune:strive` |
| `/rune:review` | Review your code changes | `/rune:appraise` |

### `/rune:tarnished` — The Unified Entry Point

Don't remember which command to use? `/rune:tarnished` is the intelligent master command that routes natural language to the correct Rune workflow. It understands both English and Vietnamese.

```bash
# Route by keyword — passes through to the right skill
/rune:tarnished plan add user authentication
/rune:tarnished work plans/my-plan.md
/rune:tarnished review
/rune:tarnished arc plans/my-plan.md
/rune:tarnished arc-batch plans/*.md
/rune:tarnished arc-issues --label "rune:ready"

# Chain workflows — multi-step with confirmation between steps
/rune:tarnished review and fix
/rune:tarnished plan then work

# Natural language — classifies intent automatically
/rune:tarnished implement the latest plan
/rune:tarnished fix the findings from the last review

# Guidance — ask Rune anything
/rune:tarnished help
/rune:tarnished what should I do next?
/rune:tarnished khi nào nên dùng audit vs review?
```

When run with no arguments, `/rune:tarnished` scans your project state (plans, reviews, git changes) and suggests the most logical next action.

### Core Commands

| Command | What it does | Agents | Duration |
|---------|-------------|--------|----------|
| [`/rune:devise`](#devise) | Turn ideas into structured plans with parallel research | up to 7 | 10–30 min |
| [`/rune:strive`](#strive) | Execute plans with self-organizing swarm workers | 2-6 | 10–30 min |
| [`/rune:appraise`](#appraise) | Multi-agent code review on your diff | up to 8 | 5–20 min |
| [`/rune:audit`](#audit) | Full codebase audit with specialized reviewers | up to 8 | 10–30 min |
| [`/rune:arc`](#arc) | End-to-end pipeline: plan → work → review → test → ship | varies | **1–3 hours** |
| [`/rune:mend`](#mend) | Parallel resolution of review findings | 1-5 | 3–10 min |
| [`/rune:forge`](#forge) | Deepen a plan with topic-aware research enrichment | 3-12 | 5–15 min |
| [`/rune:goldmask`](#goldmask) | Impact analysis — what breaks if you change this? | 8 | 5–10 min |
| [`/rune:inspect`](#inspect) | Plan-vs-implementation gap audit (9 dimensions) | 4 | 5–10 min |
| [`/rune:elicit`](#elicit) | Structured reasoning (Tree of Thoughts, Pre-mortem, 5 Whys) | 0 | 2–5 min |

### Batch & Automation

| Command | What it does |
|---------|-------------|
| `/rune:arc-batch` | Run `/rune:arc` across multiple plans sequentially |
| `/rune:arc-issues` | Fetch GitHub issues by label, generate plans, run arc for each |
| `/rune:arc-hierarchy` | Execute hierarchical parent/child plan decompositions |

### Utilities

| Command | What it does |
|---------|-------------|
| `/rune:rest` | Clean up `tmp/` artifacts from completed workflows |
| `/rune:echoes` | Manage persistent agent memory (show, prune, reset) |
| `/rune:learn` | Extract CLI corrections and review recurrences from session history into Echoes |
| `/rune:file-todos` | Structured file-based todo tracking with YAML frontmatter |
| `/rune:cancel-arc` | Gracefully stop a running arc pipeline |
| `/rune:cancel-review` | Stop an active code review |
| `/rune:cancel-audit` | Stop an active audit |

---

## Workflow Details

### <a name="devise"></a> `/rune:devise` — Planning

Transforms a feature idea into a structured plan through a multi-phase pipeline:

1. **Brainstorm** — structured exploration with elicitation methods
2. **Research** — parallel agents scan your repo, git history, echoes, and external docs
3. **Solution Arena** — competing approaches evaluated on weighted dimensions
4. **Synthesize** — consolidate findings into a plan document
5. **Predictive Goldmask** — risk scoring for files the plan will touch
6. **Forge** — topic-aware enrichment by specialist agents
7. **Review** — automated verification + optional technical review

```bash
/rune:devise                  # Full pipeline
/rune:devise --quick          # Skip brainstorm + forge (faster)
```

Output: `plans/YYYY-MM-DD-{type}-{name}-plan.md`

### <a name="arc"></a> `/rune:arc` — End-to-End Pipeline

The full pipeline from plan to merged PR, with 26 phases:

```
Forge → Plan Review → Refinement → Verification → Semantic Verification
  → Design Extraction → Task Decomposition → Work → Design Verification
  → Gap Analysis → Codex Gap Analysis → Gap Remediation
  → Goldmask Verification → Code Review (--deep) → Goldmask Correlation
  → Mend → Verify Mend → Design Iteration → Test → Test Coverage Critique
  → Pre-Ship Validation → Release Quality Check → Ship
  → Bot Review Wait → PR Comment Resolution → Merge
```

```bash
/rune:arc plans/my-plan.md
/rune:arc plans/my-plan.md --resume        # Resume from checkpoint
/rune:arc plans/my-plan.md --no-forge      # Skip forge enrichment
/rune:arc plans/my-plan.md --skip-freshness  # Bypass plan freshness check
```

Features: checkpoint-based resume, adaptive review-mend convergence loop (3 tiers: LIGHT/STANDARD/THOROUGH), diff-scoped review, co-author propagation.

**How arc phases work:** Arc uses Claude Code's [Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks) to drive the phase loop — when one phase finishes, the stop hook reads state from `.claude/arc-phase-loop.local.md`, determines the next phase, and re-injects a prompt. Each phase is literally a new Claude Code turn with its own fresh context window. This solves the context degradation problem (phase 18 gets the same quality as phase 1) but means the stop hook chain is a critical path — a bug in any hook silently breaks the pipeline. See [`docs/state-machine.md`](docs/state-machine.md) for the full phase graph.

### <a name="strive"></a> `/rune:strive` — Swarm Execution

Self-organizing workers parse a plan into tasks and claim them independently:

```bash
/rune:strive plans/my-plan.md
/rune:strive plans/my-plan.md --approve    # Require human approval per task
```

### <a name="appraise"></a> `/rune:appraise` — Code Review

Multi-agent review of your git diff with up to 8 specialized Ashes:

```bash
/rune:appraise                # Standard review
/rune:appraise --deep         # Multi-wave deep review (up to 18 Ashes across 3 waves)
```

Built-in reviewers include: Ward Sentinel (security), Pattern Seer (consistency), Flaw Hunter (logic bugs), Ember Oracle (performance), Depth Seer (missing logic), and more. Stack-aware intelligence auto-adds specialist reviewers based on your tech stack.

### <a name="audit"></a> `/rune:audit` — Codebase Audit

Full-scope analysis of your entire codebase (not just the diff):

```bash
/rune:audit                   # Deep audit (default)
/rune:audit --standard        # Standard depth
/rune:audit --deep            # Multi-wave investigation
/rune:audit --incremental     # Stateful audit with priority scoring and coverage tracking
```

### <a name="mend"></a> `/rune:mend` — Fix Findings

Parse a TOME (aggregated review findings) and dispatch parallel fixers:

```bash
/rune:mend tmp/reviews/{id}/TOME.md
```

### <a name="forge"></a> `/rune:forge` — Plan Enrichment

Deepen a plan with Forge Gaze — topic-aware agent matching that selects the best specialists for each section:

```bash
/rune:forge plans/my-plan.md
/rune:forge plans/my-plan.md --exhaustive  # Lower threshold, more agents
```

### <a name="goldmask"></a> `/rune:goldmask` — Impact Analysis

Three-layer analysis: **Impact** (what changes), **Wisdom** (why it was written that way), **Lore** (how risky the area is):

```bash
/rune:goldmask                # Analyze current diff
```

### <a name="inspect"></a> `/rune:inspect` — Gap Audit

Compares a plan against its implementation across 9 quality dimensions:

```bash
/rune:inspect plans/my-plan.md
/rune:inspect plans/my-plan.md --focus "auth module"
```

### <a name="elicit"></a> `/rune:elicit` — Structured Reasoning

24 curated methods for structured thinking: Tree of Thoughts, Pre-mortem Analysis, Red Team vs Blue Team, 5 Whys, ADR, and more.

```bash
/rune:elicit
```

---

## Agents

**91 specialized agents** across 6 categories:

### Review Agents (40)

Core reviewers active in every `/rune:appraise` and `/rune:audit` run. Stack specialists (below) are additionally auto-activated based on detected tech stack:

| Agent | Focus |
|-------|-------|
| Ward Sentinel | Security (OWASP Top 10, auth, secrets) |
| Pattern Seer | Cross-cutting consistency (naming, error handling, API design) |
| Flaw Hunter | Logic bugs (null handling, race conditions, silent failures) |
| Ember Oracle | Performance (N+1 queries, algorithmic complexity) |
| Depth Seer | Missing logic (error handling gaps, state machine incompleteness) |
| Void Analyzer | Incomplete implementations (TODOs, stubs, placeholders) |
| Wraith Finder | Dead code (unused exports, orphaned files, unwired DI) |
| Tide Watcher | Async/concurrency (waterfall awaits, race conditions) |
| Forge Keeper | Data integrity (migration safety, transaction boundaries) |
| Trial Oracle | Test quality (TDD compliance, assertion quality) |
| Simplicity Warden | Over-engineering (YAGNI violations, premature abstractions) |
| Rune Architect | Architecture (layer boundaries, SOLID, dependency direction) |
| Mimic Detector | Code duplication (DRY violations) |
| Blight Seer | Design anti-patterns (God Service, leaky abstractions) |
| Refactor Guardian | Refactoring completeness (orphaned callers, broken imports) |
| Reference Validator | Import paths and config reference correctness |
| Phantom Checker | Dynamic references (getattr, decorators, string dispatch) |
| Naming Intent Analyzer | Name-behavior mismatches |
| Type Warden | Type safety (mypy strict, modern Python idioms) |
| Doubt Seer | Cross-agent claim verification |
| Assumption Slayer | Premise validation (solving the right problem?) |
| Reality Arbiter | Production viability (works in isolation vs. real conditions) |
| Entropy Prophet | Long-term consequence prediction |
| Schema Drift Detector | Schema drift between migrations and ORM/model definitions |
| Agent Parity Reviewer | Agent-native parity, orphan features, context starvation |
| Senior Engineer Reviewer | Persona-based senior engineer review, production thinking |
| Cross-Shard Sentinel | Cross-shard consistency for Inscription Sharding (naming drift, pattern inconsistency, auth boundary gaps) |

**Stack Specialists** (auto-activated by detected tech stack):

| Agent | Stack |
|-------|-------|
| Python Reviewer | Python 3.10+ (type hints, async, Result patterns) |
| TypeScript Reviewer | Strict TypeScript (discriminated unions, exhaustive matching) |
| Rust Reviewer | Rust (ownership, unsafe, tokio) |
| PHP Reviewer | PHP 8.1+ (type declarations, enums, readonly) |
| FastAPI Reviewer | FastAPI (Pydantic, IDOR, dependency injection) |
| Django Reviewer | Django + DRF (ORM, CSRF, admin, migrations) |
| Laravel Reviewer | Laravel (Eloquent, Blade, middleware, gates) |
| Axum Reviewer | Axum/SQLx (extractor ordering, N+1 queries, IDOR, transaction boundaries) |
| SQLAlchemy Reviewer | SQLAlchemy (async sessions, N+1, eager loading) |
| TDD Compliance Reviewer | TDD practices (test-first, coverage, assertion quality) |
| DDD Reviewer | Domain-Driven Design (aggregates, bounded contexts) |
| DI Reviewer | Dependency Injection (scope, circular deps, service locator) |
| Design Implementation Reviewer | Design-to-code fidelity (tokens, layout, responsive, a11y, variants) |

### Investigation Agents (24)

Used by `/rune:goldmask`, `/rune:inspect`, and `/rune:audit --deep`:

| Category | Agents |
|----------|--------|
| Impact Tracers | API Contract, Business Logic, Data Layer, Config Dependency, Event Message |
| Quality Inspectors | Grace Warden, Ruin Prophet, Sight Oracle, Vigil Keeper |
| Deep Analysis | Breach Hunter, Decay Tracer, Decree Auditor, Ember Seer, Fringe Watcher, Hypothesis Investigator, Order Auditor, Rot Seeker, Ruin Watcher, Signal Watcher, Strand Tracer, Truth Seeker |
| Synthesis | Goldmask Coordinator, Lore Analyst, Wisdom Sage |

### Research Agents (5)

| Agent | Purpose |
|-------|---------|
| Repo Surveyor | Codebase structure and pattern analysis |
| Echo Reader | Surfaces relevant past learnings from Rune Echoes |
| Git Miner | Git archaeology — commit history, contributors, code evolution |
| Lore Scholar | Framework docs via Context7 MCP + web search fallback |
| Practice Seeker | External best practices and industry patterns |

### Work Agents (4)

| Agent | Purpose |
|-------|---------|
| Rune Smith | TDD-driven code implementation |
| Trial Forger | Test generation following project patterns |
| Design Sync Agent | Figma extraction and Visual Spec Map creation |
| Design Iterator | Iterative design refinement (screenshot-analyze-fix loop) |

### Utility Agents (14)

| Agent | Purpose |
|-------|---------|
| Runebinder | Aggregates multi-agent review outputs into TOME |
| Mend Fixer | Applies targeted code fixes for review findings |
| Elicitation Sage | Structured reasoning method execution |
| Scroll Reviewer | Document quality review |
| Flow Seer | Feature spec analysis for completeness |
| Decree Arbiter | Technical soundness validation |
| Knowledge Keeper | Documentation coverage review |
| Horizon Sage | Strategic depth assessment |
| State Weaver | Plan state machine validation (phases, transitions, I/O contracts) |
| Veil Piercer | Plan reality-gap analysis |
| Evidence Verifier | Factual claim validation with grounding scores |
| Research Verifier | Research output quality verification |
| Truthseer Validator | Audit coverage quality validation |
| Deployment Verifier | Deployment artifact generation (Go/No-Go checklists, rollback plans) |

### Testing Agents (4)

| Agent | Purpose |
|-------|---------|
| Unit Test Runner | Diff-scoped unit test execution |
| Integration Test Runner | API, database, and business logic tests |
| E2E Browser Tester | Browser automation via agent-browser CLI |
| Test Failure Analyst | Root cause analysis of test failures |

---

## Skills

43 skills providing background knowledge, workflow orchestration, and tool integration:

| Skill | Type | Purpose |
|-------|------|---------|
| `devise` | Workflow | Multi-agent planning pipeline |
| `strive` | Workflow | Swarm work execution |
| `appraise` | Workflow | Multi-agent code review |
| `audit` | Workflow | Full codebase audit |
| `arc` | Workflow | End-to-end pipeline orchestration |
| `arc-batch` | Workflow | Sequential batch arc execution |
| `arc-hierarchy` | Workflow | Hierarchical plan execution |
| `arc-issues` | Workflow | GitHub Issues-driven batch arc |
| `forge` | Workflow | Plan enrichment with Forge Gaze |
| `goldmask` | Workflow | Cross-layer impact analysis |
| `inspect` | Workflow | Plan-vs-implementation gap audit |
| `mend` | Workflow | Parallel finding resolution |
| `elicitation` | Reasoning | 24 structured reasoning methods |
| `roundtable-circle` | Orchestration | Review/audit 7-phase lifecycle |
| `rune-orchestration` | Orchestration | Core coordination patterns |
| `context-weaving` | Orchestration | Context overflow prevention |
| `rune-echoes` | Memory | 5-tier persistent agent memory |
| `stacks` | Intelligence | Stack-aware detection and routing |
| `frontend-design-patterns` | Intelligence | Design-to-code patterns (tokens, a11y, responsive, components) |
| `design-sync` | Workflow | Figma design sync (extraction, implementation, fidelity review) |
| `inner-flame` | Quality | Universal self-review protocol |
| `ash-guide` | Reference | Agent invocation guide |
| `tarnished` | Routing | Unified entry point — natural language to workflow |
| `using-rune` | Reference | Workflow discovery and routing |
| `codex-cli` | Integration | Cross-model verification |
| `testing` | Testing | 3-tier test orchestration |
| `agent-browser` | Testing | E2E browser automation knowledge |
| `systematic-debugging` | Debugging | 4-phase debugging methodology |
| `file-todos` | Tracking | Structured file-based todos |
| `git-worktree` | Isolation | Worktree-based parallel execution |
| `polling-guard` | Reliability | Monitoring loop fidelity |
| `zsh-compat` | Compatibility | macOS zsh shell safety |
| `chome-pattern` | Compatibility | Multi-account config resolution |
| `resolve-gh-pr-comment` | Workflow | Resolve a single GitHub PR review comment |
| `resolve-all-gh-pr-comments` | Workflow | Batch resolve all open PR review comments |
| `skill-testing` | Development | TDD for skill development |
| `debug` | Debugging | ACH-based parallel hypothesis debugging |
| `codex-review` | Workflow | Cross-model code review (Claude + Codex in parallel) |
| `learn` | Memory | Session self-learning (CLI corrections, review recurrences) |
| `figma-to-react` | Integration | Figma-to-React MCP server knowledge |
| `status` | Reporting | Worker status reporting for swarm execution |
| `talisman` | Configuration | Deep talisman.yml management (init, audit, update, guide, status) |

---

## Configuration

Rune is configured via `talisman.yml` (dozens of top-level sections, 100+ keys):

```bash
# Project-level (highest priority)
.claude/talisman.yml

# User-global
~/.claude/talisman.yml
```

**Quickest way to configure:** Run `/rune:talisman init` to auto-detect your stack and generate a tailored config.

<details>
<summary>Example configuration</summary>

```yaml
version: 1

# File classification — decides which Ashes get summoned
rune-gaze:
  backend_extensions: [.py]
  skip_patterns: ["**/migrations/**", "**/__pycache__/**"]

# Work execution
work:
  ward_commands: ["ruff check .", "mypy .", "pytest --tb=short -q"]
  max_workers: 3

# Arc pipeline
arc:
  timeouts:
    forge: 900000               # 15 min
    work: 2100000               # 35 min
    code_review: 900000         # 15 min
  ship:
    auto_pr: true
    merge_strategy: "squash"

# Review settings
review:
  diff_scope:
    enabled: true
    expansion: 8

# Goldmask impact analysis
goldmask:
  enabled: true
  devise:
    depth: enhanced             # basic | enhanced | full

# Cross-model verification
codex:
  enabled: true
  workflows: [devise, arc, appraise]

# Custom Ashes
ashes:
  custom:
    - name: "my-reviewer"
      agent: "my-custom-agent"
      source: ".claude/agents/my-custom-agent.md"
```
</details>

See [`talisman.example.yml`](plugins/rune/talisman.example.yml) for the full schema with all options.

---

## Codex CLI Integration (Optional)

Rune supports [OpenAI Codex CLI](https://github.com/openai/codex) as a cross-model verification layer. If you have a **ChatGPT Pro** subscription, you can enable Codex to add a second AI perspective alongside Claude — giving you higher-confidence results through independent cross-verification.

### What Codex adds

| Workflow | Codex Role |
|----------|-----------|
| `/rune:arc` | Gap analysis phase — Codex independently reviews implementation gaps |
| `/rune:appraise` | Cross-model review — Claude and Codex review in parallel, findings are cross-verified |
| `/rune:devise` | Plan validation — Codex provides a second opinion on plan feasibility |
| `/rune:codex-review` | Dedicated cross-model review — runs Claude + Codex agents side by side |

Findings are tagged with confidence levels: **CROSS-VERIFIED** (both models agree), **STANDARD** (single model), or **DISPUTED** (models disagree).

### Trade-off: quality vs. time

Enabling Codex **increases runtime** for every workflow that uses it — each Codex invocation adds an extra verification pass. For `/rune:arc`, this can add 10–20 minutes on top of the already 1–3 hour pipeline. Enable it when correctness matters more than speed.

### Enable / Disable

Codex integration is controlled via `talisman.yml`:

```yaml
# .claude/talisman.yml
codex:
  enabled: true                          # Set to false to disable entirely
  workflows: [devise, arc, appraise]     # Which workflows use Codex
```

To disable: set `codex.enabled: false` or remove the `codex` section. Rune auto-detects whether the `codex` CLI is installed and authenticated — if not available, Codex phases are silently skipped.

### Prerequisites

1. [ChatGPT Pro](https://openai.com/chatgpt/pricing/) subscription (for Codex API access)
2. Codex CLI installed: `npm install -g @openai/codex`
3. Authenticated: `codex login`
4. `.codexignore` file in project root (required for `--full-auto` mode)

---

## Architecture

```
rune-plugin/
├── .claude-plugin/
│   └── marketplace.json          # Marketplace registry
└── plugins/
    └── rune/                     # Main plugin
        ├── .claude-plugin/
        │   └── plugin.json       # Plugin manifest (v1.128.0)
        ├── agents/               # 95 agent definitions
        │   ├── review/           #   41 review agents
        │   ├── investigation/    #   24 investigation agents
        │   ├── utility/          #   15 utility agents
        │   ├── research/         #    5 research agents
        │   ├── testing/          #    4 testing agents
        │   └── work/             #    6 work agents
        ├── skills/               # 44 skills
        ├── commands/             # 15 slash commands
        ├── hooks/                # Event-driven hooks
        │   └── hooks.json
        ├── scripts/              # Hook & utility scripts (99 .sh/.py files)
        ├── .mcp.json             # MCP server config (3 servers: echo-search, figma-to-react, context7)
        ├── talisman.example.yml  # Configuration reference
        ├── CLAUDE.md             # Plugin instructions
        ├── CHANGELOG.md
        └── README.md             # Detailed component reference
```

### State Machine Reference

Every Rune workflow is an explicit state machine with named phases, conditional gates, and error recovery tiers. See [`docs/state-machine.md`](docs/state-machine.md) for mermaid diagrams of all 10 workflows — useful for debugging pipeline failures, understanding phase transitions, and verifying correctness.

### Key Concepts

| Term | Meaning |
|------|---------|
| **Tarnished** | The orchestrator/lead agent that coordinates workflows |
| **Ash** | Any teammate agent (reviewer, worker, researcher) |
| **TOME** | Aggregated findings document from a review |
| **Talisman** | Configuration file (`talisman.yml`) |
| **Forge Gaze** | Topic-aware agent matching for plan enrichment |
| **Rune Echoes** | 5-tier persistent agent memory (`.claude/echoes/`) |
| **Inscription** | Contract file (`inscription.json`) for agent coordination |
| **Seal** | Deterministic completion marker emitted by Ashes |

---

## Known Gotchas

A few things to know when working with Rune — especially if you're debugging a pipeline failure or writing custom hooks/scripts:

| Gotcha | Details |
|--------|---------|
| **macOS bash is 3.2** | The system `bash` on macOS is ancient (3.2). No associative arrays, no `readarray`, no `\|&`. Rune's `enforce-zsh-compat.sh` hook auto-fixes 5 common patterns at runtime, but custom scripts must target bash 3.2. |
| **`status` is read-only in zsh** | zsh (macOS default shell) treats `status` as read-only. Using `status=` in any script will silently fail or crash. Use `task_status` or `tstat` instead. Enforced by `enforce-zsh-compat.sh`. |
| **Hook timeout budget is tight** | PreToolUse hooks: 5s. Stop hooks: 15s (arc-phase) or 30s (detect-workflow). A slow `git` or `gh` call in a hook can cause silent timeout — the hook is killed and the phase loop breaks. |
| **Stop hooks chain in sequence** | 6 Stop hooks fire in order: `arc-phase-stop-hook.sh` (inner) → `arc-batch-stop-hook.sh` → `arc-hierarchy-stop-hook.sh` → `arc-issues-stop-hook.sh` → `detect-workflow-complete.sh` → `on-session-stop.sh` (outer). A crash in an inner hook breaks all outer hooks. |
| **SEAL convention for completion** | Ashes emit `<seal>TAG</seal>` as their last output line. The `on-teammate-idle.sh` hook checks for this marker to distinguish "done writing" from "idle mid-task". Missing seals cause premature aggregation. |

See the [Troubleshooting guide](docs/guides/rune-troubleshooting-and-optimization-guide.en.md) for more operational details.

---

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with plugin support
- **Claude Max ($200/month) or higher recommended** — see [token and runtime warning](#token-warning) above

---

## Links

- [Detailed component reference](plugins/rune/README.md) — all agents, skills, commands, hooks
- [Documentation hub](docs/README.md) — start here to choose the right user guide
- [Rune user guide (English): arc + arc-batch](docs/guides/rune-arc-and-batch-guide.en.md) — operational guide with greenfield/brownfield use cases
- [Hướng dẫn Rune (Tiếng Việt): arc + arc-batch](docs/guides/rune-arc-and-batch-guide.vi.md) — hướng dẫn vận hành kèm use case greenfield/brownfield
- [Rune planning guide (English): devise + forge + plan-review + inspect](docs/guides/rune-planning-and-plan-quality-guide.en.md) — how to write and validate plan files correctly
- [Hướng dẫn planning Rune (Tiếng Việt): devise + forge + plan-review + inspect](docs/guides/rune-planning-and-plan-quality-guide.vi.md) — cách lập plan và review plan đúng chuẩn
- [Rune code review and audit guide (English): appraise + audit + mend](docs/guides/rune-code-review-and-audit-guide.en.md) — multi-agent review, codebase audit, and finding resolution
- [Hướng dẫn review và audit Rune (Tiếng Việt): appraise + audit + mend](docs/guides/rune-code-review-and-audit-guide.vi.md) — review đa agent, audit codebase, và xử lý finding
- [Rune work execution guide (English): strive + goldmask](docs/guides/rune-work-execution-guide.en.md) — swarm implementation and impact analysis
- [Hướng dẫn thực thi Rune (Tiếng Việt): strive + goldmask](docs/guides/rune-work-execution-guide.vi.md) — implementation swarm và phân tích tác động
- [Rune advanced workflows guide (English): arc-hierarchy + arc-issues + echoes](docs/guides/rune-advanced-workflows-guide.en.md) — hierarchical execution, GitHub Issues batch, and agent memory
- [Hướng dẫn workflow nâng cao Rune (Tiếng Việt): arc-hierarchy + arc-issues + echoes](docs/guides/rune-advanced-workflows-guide.vi.md) — thực thi phân cấp, batch GitHub Issues, và bộ nhớ agent
- [Rune getting started guide (English)](docs/guides/rune-getting-started.en.md) — quick start for first-time users
- [Hướng dẫn bắt đầu nhanh Rune (Tiếng Việt)](docs/guides/rune-getting-started.vi.md) — hướng dẫn nhanh cho người mới
- [Thuật ngữ Rune (Tiếng Việt)](docs/guides/rune-glossary.vi.md) — bảng giải thích thuật ngữ ngắn gọn
- [Rune command reference (English)](docs/guides/rune-command-reference.en.md) — complete slash-command catalog by workflow
- [Bảng tra lệnh Rune (Tiếng Việt)](docs/guides/rune-command-reference.vi.md) — danh mục đầy đủ lệnh slash theo workflow
- [Rune talisman deep dive (English)](docs/guides/rune-talisman-deep-dive-guide.en.md) — full talisman configuration reference
- [Hướng dẫn talisman chuyên sâu Rune (Tiếng Việt)](docs/guides/rune-talisman-deep-dive-guide.vi.md) — tham chiếu đầy đủ cấu hình talisman
- [Rune custom agents and extensions (English)](docs/guides/rune-custom-agents-and-extensions-guide.en.md) — build custom Ashes, CLI-backed reviewers, Forge Gaze integration
- [Hướng dẫn custom agent và mở rộng Rune (Tiếng Việt)](docs/guides/rune-custom-agents-and-extensions-guide.vi.md) — xây dựng custom Ash, CLI reviewer, tích hợp Forge Gaze
- [Rune troubleshooting and optimization (English)](docs/guides/rune-troubleshooting-and-optimization-guide.en.md) — debug failures, reduce token cost, tune performance
- [Hướng dẫn xử lý sự cố và tối ưu Rune (Tiếng Việt)](docs/guides/rune-troubleshooting-and-optimization-guide.vi.md) — chẩn đoán lỗi, giảm token, tối ưu hiệu suất
- [Rune engineering solutions (English)](docs/solutions/architecture/rune-engineering-solutions.en.md) — 30 unique solutions across 200+ commits
- [Giải pháp kỹ thuật Rune (Tiếng Việt)](docs/solutions/architecture/rune-engineering-solutions.vi.md) — 30 giải pháp đặc biệt qua hơn 200 commits
- [State machine reference](docs/state-machine.md) — mermaid diagrams of all 10 workflow state machines
- [Changelog](plugins/rune/CHANGELOG.md) — release history
- [Configuration guide](plugins/rune/talisman.example.yml) — full talisman schema

---

## License

[MIT](LICENSE)
