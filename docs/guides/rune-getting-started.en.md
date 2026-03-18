# Getting Started with Rune

Welcome to Rune! This guide will get you from zero to productive with three simple commands.

## What Is Rune?

Rune is a multi-agent orchestration plugin for [Claude Code](https://claude.ai/claude-code). It coordinates teams of AI agents to plan, implement, and review your code — all from the command line.

**You don't need to learn everything at once.** Start with three commands and expand from there.

## Quick Read (2 Minutes)

- If you are new to Rune, read this guide from top to bottom.
- If setup is done, jump to `Plan -> Work -> Review`.
- If you want copy-paste command flows, use the [Quick Cheat Sheet](rune-quick-cheat-sheet.en.md).
- If you want short answers to common questions, check [Rune FAQ](rune-faq.en.md).
- If terms are unclear, see [Rune Glossary](rune-glossary.en.md).

## Installation

```bash
/plugin marketplace add https://github.com/vinhnxv/rune
/plugin install rune
```

Restart Claude Code after installation.

## Setup

### 1. Enable Agent Teams

Rune uses [Agent Teams](https://code.claude.com/docs/en/agent-teams) — multiple AI agents working together, each with its own context window. This feature must be enabled first.

Add this to `.claude/settings.json` or `.claude/settings.local.json` in your project:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### 2. Include Rune Output Directories (Recommended)

Rune generates output files (plans, reviews, temporary artifacts) in directories that are typically gitignored. To let Claude Code read these files, add `includedGitignorePatterns` to the same settings file:

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
    ".rune/",
    ".claude/CLAUDE.local.md"
  ]
}
```

> **Where to put settings:**
> - `.claude/settings.json` — project-level, committable (shared with your team)
> - `.claude/settings.local.json` — project-level, gitignored (your personal preferences)
>
> Use `settings.local.json` if you don't want to commit these settings to your repository.

### 3. Configure Your Project (Optional)

Generate a `talisman.yml` configuration file tailored to your project's tech stack:

```bash
/rune:talisman init
```

This auto-detects your stack (Python, TypeScript, Rust, PHP, Go, etc.) and generates `.rune/talisman.yml` with appropriate ward commands, file classification, and agent settings. You can skip this step — Rune works with sensible defaults.

See the [Talisman Deep Dive](rune-talisman-deep-dive-guide.en.md) for all configuration options.

### 4. Verify

After saving the settings, restart Claude Code. You should now be able to run `/rune:plan` and see agents being spawned.

---

## The Basic Workflow: Plan → Work → Review

Rune's daily workflow follows three steps:

```
/rune:plan  →  /rune:work  →  /rune:review
   Plan          Build          Review
```

That's it. Three commands for your daily tasks.

---

## Step 1: Plan (`/rune:plan`)

Tell Rune what you want to build. It will research your codebase and create a detailed plan.

```bash
# Describe what you want to build
/rune:plan add user authentication with JWT

# Quick plan (faster, less thorough)
/rune:plan --quick fix the search pagination bug
```

**What happens behind the scenes:**
1. AI agents brainstorm approaches for your feature
2. They research your codebase — existing patterns, git history, dependencies
3. Findings are synthesized into a structured plan with tasks and acceptance criteria
4. The plan is reviewed for completeness

**Output:** A plan file at `plans/YYYY-MM-DD-{type}-{name}-plan.md`

**Duration:** 5-15 minutes (full) | 2-5 minutes (quick)

### Tips
- Use `--quick` for bug fixes and small tasks
- The plan is a markdown file — you can edit it before implementing
- Plans include acceptance criteria so you know when you're done

---

## Step 2: Work (`/rune:work`)

Give Rune your plan and it will implement it using a team of AI workers.

```bash
# Implement a specific plan
/rune:work plans/2026-02-25-feat-user-auth-plan.md

# Auto-detect the most recent plan
/rune:work
```

**What happens behind the scenes:**
1. The plan is parsed into individual tasks
2. AI workers claim tasks and implement them independently
3. Quality gates run (linting, type checks)
4. Code is committed when all tasks pass

**Duration:** 10-30 minutes depending on plan size

### Tips
- Run `/rune:work` without arguments — it finds the latest plan automatically
- Use `--approve` if you want to review each task before it's implemented
- Workers create real code changes in your repository

---

## Step 3: Review (`/rune:review`)

After implementation, review your code changes with multiple specialized AI reviewers.

```bash
# Review your current changes (git diff)
/rune:review

# Deep review (more thorough, takes longer)
/rune:review --deep
```

**What happens behind the scenes:**
1. Your git diff is analyzed automatically
2. Up to 7 specialized reviewers examine your code:
   - Security vulnerabilities
   - Performance bottlenecks
   - Logic bugs and edge cases
   - Code patterns and consistency
   - Dead code and incomplete implementations
3. Findings are deduplicated, prioritized, and compiled into a report

**Output:** A review report (TOME) at `tmp/reviews/{id}/TOME.md`

**Duration:** 3-10 minutes (standard) | 5-15 minutes (deep)

### After Review: Fix Findings

If the review found issues, fix them automatically:

```bash
/rune:mend tmp/reviews/{id}/TOME.md
```

---

## Your First Session

Here's a complete example session:

```bash
# 1. Plan a feature
/rune:plan add a dark mode toggle to the settings page

# 2. Implement the plan (auto-detects the plan from step 1)
/rune:work

# 3. Review the implementation
/rune:review

# 4. Fix any issues found (if needed)
/rune:mend tmp/reviews/{id}/TOME.md
```

---

## Quick Reference Card

| Command | What it does | Alias for |
|---------|-------------|-----------|
| `/rune:plan` | Create an implementation plan | `/rune:devise` |
| `/rune:plan --quick` | Quick lightweight plan | `/rune:devise --quick` |
| `/rune:work` | Implement a plan with AI workers | `/rune:strive` |
| `/rune:work --approve` | Implement with human approval per task | `/rune:strive --approve` |
| `/rune:review` | Multi-agent code review | `/rune:appraise` |
| `/rune:review --deep` | Thorough multi-wave review | `/rune:appraise --deep` |
| `/rune:mend` | Auto-fix review findings | — |
| `/rune:test-browser` | Standalone browser E2E testing | — |
| `/rune:learn` | Mine session for reusable patterns | — |
| `/rune:debug` | Parallel hypothesis debugging | — |
| `/rune:rest` | Clean up temporary files | — |

## Common Flags

| Flag | Available on | Effect |
|------|-------------|--------|
| `--quick` | `/rune:plan` | Faster planning (skip brainstorm and forge) |
| `--deep` | `/rune:review` | More thorough review (multiple waves) |
| `--approve` | `/rune:work` | Require your approval before each task |
| `--dry-run` | `/rune:review` | Preview what would be reviewed without running |
| `--worktree` | `/rune:work` | Use git worktree isolation (experimental) |
| `--smart-sort` | `/rune:arc-batch` | Force smart ordering on plan inputs |
| `--headed` | `/rune:test-browser` | Run browser tests with visible browser |

---

## `/rune:tarnished` — The Unified Entry Point

Don't remember which command to use? `/rune:tarnished` is the intelligent master command that routes your request to the correct Rune workflow. It understands both English and Vietnamese.

```bash
# Just say what you want — tarnished figures out the right command
/rune:tarnished plan add user authentication
/rune:tarnished work
/rune:tarnished review
/rune:tarnished arc plans/my-plan.md

# Chain multiple steps with "and" / "then"
/rune:tarnished review and fix
/rune:tarnished plan then work

# Natural language works too
/rune:tarnished implement the latest plan
/rune:tarnished fix the findings from the last review

# Ask for guidance
/rune:tarnished help
/rune:tarnished what should I do next?
```

When run with no arguments, `/rune:tarnished` scans your project state (plans, reviews, git changes) and suggests the most logical next action.

| Keyword | Routes to |
|---------|-----------|
| `plan` | `/rune:devise` |
| `work` | `/rune:strive` |
| `review` | `/rune:appraise` |
| `arc` | `/rune:arc` |
| `arc-batch` | `/rune:arc-batch` |
| `arc-issues` | `/rune:arc-issues` |
| `audit` | `/rune:audit` |
| `forge` | `/rune:forge` |
| `mend` | `/rune:mend` |
| `help` | Guidance mode |

---

## Going Further

Once you're comfortable with the basic workflow, explore these advanced commands:

| When you need... | Use |
|-----------------|-----|
| End-to-end pipeline (plan → work → review → ship) | `/rune:arc plans/...` |
| Full codebase audit (not just your changes) | `/rune:audit` |
| Enrich a plan with more detail | `/rune:forge plans/...` |
| Impact analysis of your changes | `/rune:goldmask` |
| Structured reasoning (trade-off analysis, etc.) | `/rune:elicit` |
| Cross-model code review (Claude + Codex) | `/rune:codex-review` |
| Standalone browser E2E testing | `/rune:test-browser` |
| Parallel hypothesis debugging | `/rune:debug` |
| Extract session learnings to memory | `/rune:learn` |
| Process GitHub issues as work queue | `/rune:arc-issues --label "rune:ready"` |

### Related Guides

- [Arc and batch guide](rune-arc-and-batch-guide.en.md) — End-to-end pipelines
- [Planning guide](rune-planning-and-plan-quality-guide.en.md) — Advanced planning
- [Code review and audit guide](rune-code-review-and-audit-guide.en.md) — Deep reviews
- [Work execution guide](rune-work-execution-guide.en.md) — Swarm workers
- [Advanced workflows guide](rune-advanced-workflows-guide.en.md) — Hierarchical plans, GitHub Issues, self-learning
- [Custom agents and extensions guide](rune-custom-agents-and-extensions-guide.en.md) — Custom reviewers and CLI-backed Ashes
- [Talisman deep dive guide](rune-talisman-deep-dive-guide.en.md) — Full configuration reference
- [Troubleshooting and optimization guide](rune-troubleshooting-and-optimization-guide.en.md) — Debugging, cost optimization

---

## FAQ

**Q: Do I need to use the alias commands (`plan`/`work`/`review`)?**
No. They are convenience shortcuts. `/rune:devise`, `/rune:strive`, and `/rune:appraise` work exactly the same way with the same flags.

**Q: How much does a typical session cost in tokens?**
A plan+work+review cycle for a medium feature uses significant tokens. We recommend Claude Max ($200/month) or higher. Use `--dry-run` to preview scope.

**Q: Can I edit the plan before implementing it?**
Yes! Plans are markdown files in `plans/`. Edit freely before running `/rune:work`.

**Q: What if the review finds too many issues?**
Use `/rune:mend` to auto-fix findings. For false positives, you can ignore specific findings.

**Q: Do I need Agent Teams enabled?**
Yes, it's required. See the [Setup](#setup) section above for instructions.

**Q: Can I test browser flows without running the full arc pipeline?**
Yes! Use `/rune:test-browser` for standalone browser E2E testing. It runs a 9-step inline workflow without spawning agent teams.

**Q: How do I debug a complex bug with AI agents?**
Use `/rune:debug` — it spawns multiple hypothesis-investigator agents in parallel using the Analysis of Competing Hypotheses (ACH) method.

**Q: Can I get a second opinion from a different AI model?**
Yes. `/rune:codex-review` runs Claude and OpenAI Codex in parallel, cross-verifies findings, and merges consensus issues into a unified TOME.

**Q: How does Rune learn from past sessions?**
Use `/rune:learn` to extract CLI correction patterns and review recurrence findings from your session history. These are persisted to Rune Echoes for future sessions.

**Q: What is the talisman shard resolver?**
Starting from v1.114.0, Rune pre-processes `talisman.yml` into per-namespace JSON shards at session start, giving a 94% token reduction. This happens automatically — no configuration needed.
