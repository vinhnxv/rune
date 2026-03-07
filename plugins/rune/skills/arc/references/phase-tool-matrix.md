# Per-Phase Tool Restrictions (F8)

The arc orchestrator passes only phase-appropriate tools when creating each phase's team.

| Phase | Tools | Rationale |
|-------|-------|-----------|
| Phase 1 (FORGE) | Delegated to `/rune:forge` (read-only agents + Edit for enrichment merge). Codex Oracle (if detected) additionally requires Bash for `codex exec` | Enrichment only, no codebase modification |
| Phase 2 (PLAN REVIEW) | Read, Glob, Grep, Write (own output file only) | Review -- no codebase modification |
| Phase 2.5 (PLAN REFINEMENT) | Read, Write, Glob, Grep | Orchestrator-only -- extraction, no team |
| Phase 2.7 (VERIFICATION) | Read, Glob, Grep, Write, Bash (git history) | Orchestrator-only -- deterministic checks |
| Phase 2.8 (SEMANTIC VERIFICATION) | Read, Write, Bash (codex exec), Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | Team: `arc-codex-sv-{id}` — delegated to codex-phase-handler teammate |
| Phase 5 (WORK) | Full access (Read, Write, Edit, Bash, Glob, Grep) | Implementation requires all tools |
| Phase 5.5 (GAP ANALYSIS) | Read, Glob, Grep, Write (VERDICT.md only) | Team: `arc-inspect-{id}` — Inspector Ashes (enhanced with 9-dimension scoring) |
| Phase 5.6 (CODEX GAP ANALYSIS) | Read, Write, Bash (codex exec), Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | Team: `arc-codex-ga-{id}` — delegated to codex-phase-handler teammate |
| Phase 5.8 (GAP REMEDIATION) | Full access (Read, Write, Edit, Bash, Glob, Grep) | Team: `arc-gap-fix-{id}` — fix FIXABLE gaps before code review |
| Phase 5.7 (GOLDMASK VERIFICATION) | Delegated to `/rune:goldmask` (manages own team + tools) | Risk validation -- delegates to standalone skill |
| Phase 6 (CODE REVIEW, deep) | Read, Glob, Grep, Write (own output file only). Codex Oracle (if detected) additionally requires Bash for `codex exec`. Deep mode runs multi-wave (Wave 1-3). | Review -- no codebase modification |
| Phase 6.5 (GOLDMASK CORRELATION) | Read, Write, Glob, Grep | Orchestrator-only -- deterministic correlation |
| Phase 7 (MEND) | Orchestrator: full. Fixers: restricted (see mend-fixer) | Least privilege for fixers |
| Phase 7.5 (VERIFY MEND) | Read, Glob, Grep, Write, Bash (git diff) | Orchestrator-only — convergence controller (no team) |
| Phase 7.7 (TEST) | Full access (Read, Write, Edit, Bash, Glob, Grep) | Team: `arc-test-{id}` — diff-scoped test execution |
| Phase 7.8 (TEST COVERAGE CRITIQUE) | Read, Write, Bash (codex exec), Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | Team: `arc-codex-tc-{id}` — delegated to codex-phase-handler teammate |
| Phase 8.5 (PRE-SHIP VALIDATION) | Read, Write, Grep | Orchestrator-only — deterministic dual-gate check |
| Phase 8.55 (RELEASE QUALITY CHECK) | Read, Write, Bash (codex exec), Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | Team: `arc-codex-rq-{id}` — delegated to codex-phase-handler teammate |
| Phase 9 (SHIP) | Read, Write, Bash (git push, gh pr create) | Orchestrator-only — push + PR creation |
| Phase 9.1 (BOT REVIEW WAIT) | Bash (gh), Read, Write | Denied: Edit, TeamCreate — monitor CI/bot feedback only |
| Phase 9.2 (PR COMMENT RESOLUTION) | Bash (gh, git, jq), Read, Write, Edit, Glob, Grep | Denied: TeamCreate — orchestrator resolves comments inline |
| Phase 9.5 (MERGE) | Read, Write, Bash (git rebase, gh pr merge) | Orchestrator-only — rebase + merge + CI wait |

## Extended Tool Restriction Details (New Phases)

Phases added in v1.100+ that require explicit allowed/denied tool contracts:

| Phase | Allowed Tools | Denied Tools | Timeout |
|-------|--------------|-------------|---------|
| design_extraction (3) | Read, Write, Bash, Glob, Grep + Figma MCP | TeamCreate, TeamDelete | 5 min |
| design_verification (5.2) | Read, Glob, Grep | Write, Edit, Bash | 5 min |
| semantic_verification (2.8) | Read, Write, Bash, Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | N/A | 12 min |
| task_decomposition (4.5) | Read, Write, Bash, Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | N/A | 10 min |
| codex_gap_analysis (5.6) | Read, Write, Bash, Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | N/A | 16 min |
| design_iteration (7.6) | Read, Write, Edit, Bash, Glob, Grep + agent-browser | TeamCreate, TeamDelete | 10 min |
| test_coverage_critique (7.8) | Read, Write, Bash, Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | N/A | 15 min |
| release_quality_check (8.55) | Read, Write, Bash, Agent, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList | N/A | 10 min |
| bot_review_wait (9.1) | Bash (gh), Read, Write | Edit, TeamCreate | 15 min |
| pr_comment_resolution (9.2) | Bash (gh, git, jq), Read, Write, Edit, Glob, Grep | TeamCreate | 20 min |

Worker and fixer agent prompts include: "Do not modify files in `.claude/arc/`". Only the arc orchestrator writes to checkpoint.json.

## Time Budget per Phase

| Phase | Timeout | Notes |
|-------|---------|-------|
| FORGE | 15 min | Inner 10m + 5m setup budget |
| PLAN REVIEW | 15 min | Inner 10m + 5m setup budget |
| PLAN REFINEMENT | 3 min | Orchestrator-only, no agents |
| VERIFICATION | 30 sec | Deterministic checks, no LLM |
| SEMANTIC VERIFICATION | 12 min | Delegated to codex-phase-handler teammate (arc-codex-sv-{id}) |
| WORK | 35 min | Inner 30m + 5m setup budget |
| GAP ANALYSIS | 12 min | Enhanced with Inspector Ashes (arc-inspect-{id} team) |
| CODEX GAP ANALYSIS | 16 min | Delegated to codex-phase-handler teammate (arc-codex-ga-{id}) |
| GAP REMEDIATION | 15 min | New phase — gap auto-fix team (arc-gap-fix-{id}) |
| GOLDMASK VERIFICATION | 15 min | Delegated to /rune:goldmask skill (manages own team) |
| CODE REVIEW (deep) | 15 min | Inner 10m + 5m setup budget. Deep mode extends internally via wave timeout distribution |
| GOLDMASK CORRELATION | 1 min | Orchestrator-only, deterministic TOME-to-Goldmask correlation |
| MEND | 23 min | Inner 15m + 5m setup + 3m ward/cross-file |
| VERIFY MEND | 4 min | Convergence evaluation (orchestrator-only); re-review cycles run as separate Phase 6+7 |
| TEST | 25 min | Inner 20m + 5m setup; dynamic 50 min with E2E (arc-test-{id} team) |
| PRE-SHIP VALIDATION | 6 min | Orchestrator-only, deterministic dual-gate check |
| RELEASE QUALITY CHECK | 10 min | Delegated to codex-phase-handler teammate (arc-codex-rq-{id}) |
| SHIP | 5 min | Orchestrator-only, push + PR creation |
| BOT REVIEW WAIT | 15 min | Orchestrator-only, polling for bot reviews (disabled by default — opt-in via talisman or `--bot-review`) |
| PR COMMENT RESOLUTION | 20 min | Orchestrator-only, multi-round comment resolution loop (disabled by default) |
| MERGE | 10 min | Orchestrator-only, rebase + merge + CI wait |

**Total pipeline hard ceiling**: Dynamic (156-320 min based on tier; hard cap 320 min). See `calculateDynamicTimeout()` in SKILL.md.

Delegated phases use inner-timeout + 60s buffer so the delegated command handles its own timeout first; the arc timeout is a safety net only.
