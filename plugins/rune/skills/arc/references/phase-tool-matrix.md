# Per-Phase Tool Restrictions (F8)

The arc orchestrator passes only phase-appropriate tools when creating each phase's team.

| Phase | Tools | Rationale |
|-------|-------|-----------|
| Phase 1 (FORGE) | Delegated to `/rune:forge` (read-only agents + Edit for enrichment merge) | Enrichment only, no codebase modification |
| Phase 2 (PLAN REVIEW) | Read, Glob, Grep, Write (own output file only) | Review -- no codebase modification |
| Phase 2.5 (PLAN REFINEMENT) | Read, Write, Glob, Grep | Orchestrator-only -- extraction, no team |
| Phase 2.7 (VERIFICATION) | Read, Glob, Grep, Write, Bash (git history) | Orchestrator-only -- deterministic checks |
| Phase 5 (WORK) | Full access (Read, Write, Edit, Bash, Glob, Grep) | Implementation requires all tools |
| Phase 5.5 (GAP ANALYSIS) | Read, Glob, Grep, Write (VERDICT.md only) | Team: `arc-inspect-{id}` — Inspector Ashes (enhanced with 9-dimension scoring) |
| Phase 5.8 (GAP REMEDIATION) | Full access (Read, Write, Edit, Bash, Glob, Grep) | Team: `arc-gap-fix-{id}` — fix FIXABLE gaps before code review |
| Phase 6 (CODE REVIEW, deep) | Read, Glob, Grep, Write (own output file only). Deep mode runs multi-wave (Wave 1-3). | Review -- no codebase modification |
| Phase 7 (MEND) | Orchestrator: full. Fixers: restricted (see mend-fixer) | Least privilege for fixers |
| Phase 7.5 (VERIFY MEND) | Read, Glob, Grep, Write, Bash (git diff) | Orchestrator-only — convergence controller (no team) |
| Phase 7.7 (TEST) | Full access (Read, Write, Edit, Bash, Glob, Grep) | Team: `arc-test-{id}` — diff-scoped test execution |
| Phase 8.5 (PRE-SHIP VALIDATION) | Read, Write, Grep | Orchestrator-only — deterministic dual-gate check |
| Phase 9 (SHIP) | Read, Write, Bash (git push, gh pr create) | Orchestrator-only — push + PR creation |
| Phase 9.5 (MERGE) | Read, Write, Bash (git rebase, gh pr merge) | Orchestrator-only — rebase + merge + CI wait |

## Extended Tool Restriction Details (Conditional Phases)

The conditional design family (`design_extraction`, `design_prototype`,
`design_verification`, `design_iteration`) was removed from the plugin in
v3.0.0-alpha.1. No conditional phase contracts ship in v3.0.0-alpha.2.

> v3.0.0-alpha.2: `goldmask_verification`, `goldmask_correlation`, `bot_review_wait`,
> `pr_comment_resolution` removed from the default arc PHASE_ORDER. Goldmask is now a
> standalone command (`/rune:goldmask`); PR-comment work moves to external pr-guardian
> harness or `/rune:resolve-all-gh-pr-comments`.
>
> v3.0.0-alpha.2 (codex-strip sync, self-audit 1778278942): `semantic_verification`,
> `task_decomposition`, `test_coverage_critique`, `release_quality_check` also
> removed — they were dropped from JS PHASE_ORDER earlier (commit ed157fa4) but
> bash and these reference tables had not been updated.
>
> v3.0.0-alpha.1: The design family of phases (design_extraction, design_prototype,
> design_verification, design_iteration) was removed.

Worker and fixer agent prompts include: "Do not modify files in `.rune/arc/`". Only the arc orchestrator writes to checkpoint.json.

## Time Budget per Phase

| Phase | Timeout | Notes |
|-------|---------|-------|
| FORGE | 15 min | Inner 10m + 5m setup budget |
| PLAN REVIEW | 15 min | Inner 10m + 5m setup budget |
| PLAN REFINEMENT | 3 min | Orchestrator-only, no agents |
| VERIFICATION | 30 sec | Deterministic checks, no LLM |
| WORK | 35 min | Inner 30m + 5m setup budget |
| GAP ANALYSIS | 12 min | Enhanced with Inspector Ashes (arc-inspect-{id} team) |
| GAP REMEDIATION | 15 min | New phase — gap auto-fix team (arc-gap-fix-{id}) |
| CODE REVIEW (deep) | 15 min | Inner 10m + 5m setup budget. Deep mode extends internally via wave timeout distribution |
| MEND | 23 min | Inner 15m + 5m setup + 3m ward/cross-file |
| VERIFY MEND | 4 min | Convergence evaluation (orchestrator-only); re-review cycles run as separate Phase 6+7 |
| TEST | 25 min | Inner 20m + 5m setup; dynamic 50 min with E2E (arc-test-{id} team) |
| PRE-SHIP VALIDATION | 6 min | Orchestrator-only, deterministic dual-gate check |
| SHIP | 5 min | Orchestrator-only, push + PR creation |
| MERGE | 10 min | Orchestrator-only, rebase + merge + CI wait |

**Total pipeline hard ceiling**: Dynamic (156-320 min based on tier; hard cap 320 min). See `calculateDynamicTimeout()` in SKILL.md.

Delegated phases use inner-timeout + 60s buffer so the delegated command handles its own timeout first; the arc timeout is a safety net only.
