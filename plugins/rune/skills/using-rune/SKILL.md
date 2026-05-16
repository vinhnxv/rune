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
| "Quick run" / "fast" / "plan and build" / "nhanh" / "chạy nhanh" | `/rune:arc --quick-mode` | Lightweight 4-phase pipeline: plan -> work+evaluate loop -> review -> mend |
| "Implement this" / "build it" / "execute the plan" | `/rune:strive plans/...` | Swarm workers execute a plan file |
| "Verify findings" / "check false positives" / "validate review" | `/rune:inspect --verify-tome tmp/.../TOME.md` | Classify TOME findings as TRUE_POSITIVE/FALSE_POSITIVE before mend |
| "Fix these findings" / "resolve the review" | `/rune:mend tmp/.../TOME.md` | Parallel resolution of review findings |
| "Run everything" / "ship it" / "end to end" | `/rune:arc plans/...` | End-to-end pipeline (forge → work → review → mend → test → ship → merge). Use `--status` to check current phase and progress |
| "Deepen this plan" / "add more detail" / "enrich" | `/rune:forge plans/...` | Forge Gaze topic-aware enrichment |
| "What changed?" / "blast radius" / "impact analysis" | `/rune:goldmask` | Cross-layer impact analysis (Impact + Wisdom + Lore) |
| "Help me think through" / "structured reasoning" | `/rune:elicit` | Interactive elicitation method selection |
| "Clean up" / "remove temp files" | `/rune:rest` | Remove tmp/ artifacts from completed workflows |
| "Cancel the review" / "stop the audit" | `/rune:cancel-review` or `/rune:cancel-audit` | Graceful shutdown of active workflows |
| "Resolve TODOs" / "fix TODOs" / "clean up TODOs" | `/rune:resolve-todos` | Resolve file-based TODOs with verify-before-fix pipeline |
| "Test skill" / "eval skill" / "pressure test" | `/rune:skill-testing` | TDD methodology for skill testing and evaluation |
| "Status" / "team status" / "check teammates" / "agent health" / "dispatch status" | `/rune:status` | Active-team dashboard + background-dispatch report |
| "Self-audit" / "audit arc run" / "check arc quality" / "hallucination detection" / "agent effectiveness" / "check rune health" / "lint agents" / "meta-qa" | `/rune:self-audit` | Meta-QA self-audit — static analysis + runtime arc artifact analysis |
| "Supply chain audit" / "dependency risk" / "check dependencies" / "package security" / "abandoned packages" | `/rune:supply-chain-audit` | Analyze project dependencies for maintainer risk, abandonment, and CVE history |

### Beginner Aliases

For users new to Rune, these simpler commands forward to the full versions:

| User Says | Suggest | Equivalent |
|-----------|---------|------------|
| "brainstorm" / "explore" | `/rune:brainstorm` | `/rune:brainstorm` skill |
| "plan" / "plan this" | `/rune:plan` | `/rune:devise` |
| "work" / "build" / "implement" | `/rune:work` | `/rune:strive` |
| "review" / "check my code" | `/rune:review` | `/rune:appraise` |
| "quick" / "nhanh" / "fast run" | `/rune:quick` | `/rune:arc --quick-mode` |

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
| `/rune:arc --quick-mode` | Yes (per phase) | 25-60 min | Prompt or plan file |
| `/rune:forge` | Yes (per section) | 5-15 min | Plan file path |
| `/rune:goldmask` | Yes (8 tracers) | 5-10 min | Diff spec or file list |
| `/rune:elicit` | No | 2-5 min | Topic |
| `/rune:rest` | No | <1 min | None |
| `/rune:brainstorm` | Yes (0-3 advisors) | 1-8 min | Feature idea |
| `/rune:resolve-todos` | Yes (per batch) | 5-15 min | TODO file path |
| `/rune:skill-testing` | No | 2-10 min | Skill name |
| `/rune:status` | No | <1 min | Optional: timestamp or team-name |
| `/rune:self-audit` | Yes (3 agents) | 2-5 min | None (auto-detects latest arc) |
| `/rune:plan` | (alias for `/rune:devise`) |||
| `/rune:work` | (alias for `/rune:strive`) |||
| `/rune:review` | (alias for `/rune:appraise`) |||
