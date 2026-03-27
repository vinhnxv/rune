---
name: using-rune
description: |
  Use when the user asks to review code, plan features, brainstorm ideas,
  audit a codebase, implement a plan, fix review findings, debug failed
  builds, analyze code impact, or run end-to-end workflows. Also use when
  the user seems unsure which Rune command to use, when the user says
  "review", "plan", "brainstorm", "explore idea", "audit", "implement",
  "fix findings", "ship it", "check my code", "what changed", or
  "help me think through this". Routes user intent to the correct
  /rune:* command. Keywords: which command, what to use, rune help, workflow
  routing, review, audit, plan, brainstorm, explore, implement.
user-invocable: false
disable-model-invocation: false
---

# Using Rune — Workflow Discovery & Routing

When a user's request matches a Rune workflow, **suggest the appropriate command before responding**.
Do not auto-invoke heavyweight commands — suggest and let the user confirm.

## Intent Routing Table

| User Says | Suggest | Why |
|-----------|---------|-----|
| "Review my code" / "check this PR" / "code review" | `/rune:appraise` | Multi-agent review of changed files |
| "Audit the codebase" / "security scan" / "full review" | `/rune:audit` | Comprehensive codebase analysis (all files, not just diff) |
| "Inspect Claude Code" / "check Claude config" | `/rune:cc-inspect` | Run Claude Code built-in inspection script |
| "Check implementation" / "plan vs code" / "verify completeness" | `/rune:inspect` | Plan-vs-implementation deep audit with Inspector Ashes |
| "Brainstorm" / "explore idea" / "what should we build" / "thảo luận" | `/rune:brainstorm` | Collaborative idea exploration (3 modes: solo, roundtable, deep) |
| "Plan a feature" / "design this" / "how should we build" | `/rune:devise` | Multi-agent planning pipeline (brainstorm + research + synthesize) |
| "Quick plan" / "just outline it" | `/rune:devise --quick` | Lightweight planning (research + synthesize, skip brainstorm/forge) |
| "Quick run" / "fast" / "plan and build" / "nhanh" / "chạy nhanh" | `/rune:arc-quick` | Lightweight 3-phase pipeline: plan -> work+evaluate loop -> review |
| "Implement this" / "build it" / "execute the plan" | `/rune:strive plans/...` | Swarm workers execute a plan file |
| "Fix these findings" / "resolve the review" | `/rune:mend tmp/.../TOME.md` | Parallel resolution of review findings |
| "Run everything" / "ship it" / "end to end" | `/rune:arc plans/...` | Full 43-phase pipeline (forge → work → review → mend → test → goldmask → ship → merge). Use `--status` to check current phase and progress |
| "Batch arc" / "run all plans" / "overnight" / "multiple plans" | `/rune:arc-batch plans/*.md` | Sequential batch arc execution with auto-merge and crash recovery |
| "Process GitHub issues" / "run issues" / "issue backlog" / "auto-implement from issues" | `/rune:arc-issues --label "rune:ready"` | GitHub Issues-driven batch arc — fetches issues, generates plans, runs arc, comments results |
| "Run child plans" / "hierarchical execution" | `/rune:arc-hierarchy` | Execute parent/child plan decomposition with dependency DAGs |
| "Deepen this plan" / "add more detail" / "enrich" | `/rune:forge plans/...` | Forge Gaze topic-aware enrichment |
| "What changed?" / "blast radius" / "impact analysis" | `/rune:goldmask` | Cross-layer impact analysis (Impact + Wisdom + Lore) |
| "Help me think through" / "structured reasoning" | `/rune:elicit` | Interactive elicitation method selection |
| "Configure Rune" / "setup talisman" / "init talisman" / "rune config" | `/rune:talisman` | Initialize, audit, or guide talisman.yml configuration |
| "Clean up" / "remove temp files" | `/rune:rest` | Remove tmp/ artifacts from completed workflows |
| "Cancel the review" / "stop the audit" | `/rune:cancel-review` or `/rune:cancel-audit` | Graceful shutdown of active workflows |
| "Cross-model review" / "codex review" / "second opinion" | `/rune:codex-review` | Cross-model code review — Claude + Codex in parallel |
| "prototype from figma" / "preview design" / "storybook from figma" / "generate components from figma" | `/rune:design-prototype` | Standalone prototype generator |
| "Sync design" / "figma sync" / "design workflow" | `/rune:design-sync` | Figma design synchronization (extract → implement → review) |
| "Promote echoes" / "elevate learnings" / "global echoes" | `/rune:elevate` | Promote project echoes to global scope |
| "Track todos" / "file todos" / "manage todos" | `/rune:file-todos` | Structured file-based TODO tracking |
| "Learn from session" / "extract patterns" / "self-learn" | `/rune:learn` | Session self-learning — extract correction patterns |
| "Resolve PR comments" / "fix all comments" / "batch resolve" | `/rune:resolve-all-gh-pr-comments` | Batch resolve all open PR review comments |
| "Fix this PR comment" / "resolve comment" | `/rune:resolve-gh-pr-comment` | Resolve a single GitHub PR review comment |
| "Resolve TODOs" / "fix TODOs" / "clean up TODOs" | `/rune:resolve-todos` | Resolve file-based TODOs with verify-before-fix pipeline |
| "Test skill" / "eval skill" / "pressure test" | `/rune:skill-testing` | TDD methodology for skill testing and evaluation |
| "Team status" / "check teammates" / "agent health" | `/rune:team-status` | Background team health dashboard |
| "Browser test" / "E2E test" / "test browser" | `/rune:test-browser` | Standalone browser E2E testing |
| "UX review" / "UX patterns" / "heuristic evaluation" | `/rune:ux-design-process` | UX design intelligence and heuristic evaluation |
| "Post findings to PR" / "share review on PR" / "post to GitHub" / "comment on PR with findings" | `/rune:post-findings` | Post Rune review findings to GitHub PR as formatted comment |
| "Self-audit" / "audit arc run" / "check arc quality" / "hallucination detection" / "agent effectiveness" / "check rune health" / "lint agents" / "meta-qa" | `/rune:self-audit` | Meta-QA self-audit — static analysis + runtime arc artifact analysis |

### Beginner Aliases

For users new to Rune, these simpler commands forward to the full versions:

| User Says | Suggest | Equivalent |
|-----------|---------|------------|
| "brainstorm" / "explore" | `/rune:brainstorm` | `/rune:brainstorm` skill |
| "plan" / "plan this" | `/rune:plan` | `/rune:devise` |
| "work" / "build" / "implement" | `/rune:work` | `/rune:strive` |
| "review" / "check my code" | `/rune:review` | `/rune:appraise` |
| "quick" / "nhanh" / "fast run" | `/rune:quick` | `/rune:arc-quick` |

## Routing Rules

1. **Suggest, don't auto-invoke.** Rune commands spawn agent teams. Always confirm first.
2. **One command per intent.** If ambiguous, ask which workflow they want.
3. **Check for prerequisites.** `/rune:strive` needs a plan file. `/rune:mend` needs a TOME. `/rune:arc` needs a plan.
4. **Recent artifacts matter.** Check `plans/` for recent plans, `tmp/reviews/` for recent TOMEs.

## Direct Actions (no Rune skill needed)

These are common requests that Claude should handle directly — no agent team required.

| User Says | Action | Details |
|-----------|--------|---------|
| "Merge PR" / "merge code" / "merge it" / "gộp code" / "gộp PR" | `gh pr merge` | NEVER use local `git merge` + `git push`. MANDATORY steps in order: (1) `command -v gh && gh auth status` — verify CLI available, (2) `source "${RUNE_PLUGIN_ROOT}/scripts/lib/gh-account-resolver.sh" && rune_gh_ensure_correct_account` — switch to correct account, STOP if ERROR, (3) `gh pr view --json number,state` — detect PR, STOP if no open PR, (4) `GH_PROMPT_DISABLED=1 gh pr merge <number> --squash --delete-branch`, (5) `git pull` to sync local. NEVER skip step 2. |

## When NOT to Route

- Simple questions about the codebase → answer directly
- Single-file edits → edit directly
- Git operations (except merge — see Direct Actions above) → use git directly
- Questions about Rune itself → use `ash-guide` skill

## Quick Reference: Command Capabilities

| Command | Spawns Agents? | Duration | Input Required |
|---------|---------------|----------|----------------|
| `/rune:appraise` | Yes (up to 8) | 3-10 min | Git diff (auto-detected) |
| `/rune:audit` | Yes (up to 8) | 5-15 min | None (scans all files) |
| `/rune:devise` | Yes (up to 7) | 5-15 min | Feature description |
| `/rune:strive` | Yes (swarm) | 10-30 min | Plan file path |
| `/rune:mend` | Yes (per file) | 3-10 min | TOME file path |
| `/rune:arc` | Yes (per phase) | 30-90 min | Plan file path |
| `/rune:arc-quick` | Yes (per phase) | 25-60 min | Prompt or plan file |
| `/rune:arc-batch` | Yes (per plan) | 45-240 min/plan | Plan glob or queue file |
| `/rune:arc-issues` | Yes (per issue) | 45-240 min/issue | GitHub issue labels or numbers |
| `/rune:forge` | Yes (per section) | 5-15 min | Plan file path |
| `/rune:goldmask` | Yes (8 tracers) | 5-10 min | Diff spec or file list |
| `/rune:elicit` | No | 2-5 min | Topic |
| `/rune:talisman` | No | 1-3 min | Subcommand (init/audit/update/guide/status) |
| `/rune:codex-review` | Yes (up to 4) | 5-15 min | Git diff (auto-detected) |
| `/rune:design-prototype` | Yes (0-5) | 5-15 min | Figma URL or text description |
| `/rune:rest` | No | <1 min | None |
| `/rune:brainstorm` | Yes (0-3 advisors) | 1-8 min | Feature idea |
| `/rune:design-sync` | Yes (per phase) | 10-30 min | Figma URL |
| `/rune:elevate` | No | 1-2 min | None (scans echoes) |
| `/rune:file-todos` | No | <1 min | Subcommand |
| `/rune:learn` | No | 2-5 min | None (scans session) |
| `/rune:resolve-all-gh-pr-comments` | Yes (per comment) | 5-20 min | PR number (auto-detected) |
| `/rune:resolve-gh-pr-comment` | No | 1-3 min | PR comment URL or ID |
| `/rune:resolve-todos` | Yes (per batch) | 5-15 min | TODO file path |
| `/rune:skill-testing` | No | 2-10 min | Skill name |
| `/rune:team-status` | No | <1 min | None |
| `/rune:test-browser` | No | 3-10 min | PR# or branch |
| `/rune:ux-design-process` | No | 2-5 min | None (auto-loaded) |
| `/rune:post-findings` | No | 1-3 min | TOME file path + PR number |
| `/rune:self-audit` | Yes (3 agents) | 2-5 min | None (auto-detects latest arc) |
| `/rune:plan` | (alias for `/rune:devise`) |||
| `/rune:work` | (alias for `/rune:strive`) |||
| `/rune:review` | (alias for `/rune:appraise`) |||
