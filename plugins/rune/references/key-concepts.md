# Key Concepts

## The Tarnished (Orchestrator)

The lead agent that coordinates all Rune workflows. In Elden Ring, the Tarnished is
the protagonist who journeys through the Lands Between. In Rune, the Tarnished:
- Convenes the Roundtable Circle (review/audit orchestration)
- Coordinates Ashes and summons research agents
- Collects findings into the TOME
- Guides the arc pipeline from forge to merge
- Runs deterministic gap analysis between work and code review

The Tarnished is the lead agent in every team. Machine identifier: `team-lead`.

## Brainstorm (Idea Exploration)

Standalone skill for collaborative exploration of WHAT to build before planning HOW. Three modes:
- **Solo** (`--quick`) — pure conversation, no agents. Lead asks questions directly.
- **Roundtable** (default) — 3 advisor agents engage the user in structured dialogue with lightweight codebase research.
- **Deep** (`--deep`) — advisors + 1-3 elicitation sages for structured reasoning.

Output: `docs/brainstorms/YYYY-MM-DD-topic-brainstorm.md` (persistent, survives `/rune:rest`).
Devise Phase 0 delegates to brainstorm logic via `--brainstorm-context` flag.

## Roundtable Advisors

Three advisor personas used in brainstorm roundtable and deep modes:
- **User Advocate** — focuses on user needs, personas, pain points, accessibility
- **Tech Realist** — evaluates feasibility, existing patterns, complexity, trade-offs
- **Devil's Advocate** — challenges assumptions, proposes alternatives, applies YAGNI

Advisors do lightweight codebase research (Glob, Grep, Read) to ground their questions in reality. This is NOT a replacement for full research agents in `/rune:devise` Phase 1.

## Implementation Gap Analysis (Arc Phase 5.5)

Deterministic, orchestrator-only phase between WORK and CODE REVIEW. Cross-references plan acceptance criteria against committed code changes. Categories: ADDRESSED, MISSING, PARTIAL. Also runs doc-consistency checking via talisman verification_patterns (phase-filtered for post-work). Advisory only — warns but never halts.

## Plan Section Convention

Plans with pseudocode include contract headers (Inputs/Outputs/Preconditions/Error handling) before code blocks. Phase 2.7 verification gate enforces this. Workers implement from contracts, not by copying pseudocode verbatim.

## Ash (Consolidated Teammates)

Each Ash is an Agent Teams teammate with its own dedicated context window. An Ash embeds multiple review agent perspectives into a single teammate to reduce team size.

Forge Warden, Ward Sentinel, Pattern Weaver, and Veil Piercer embed dedicated review agent files from `agents/review/` (13 agents distributed across 4 Ashes — see circle-registry.md for mapping). Glyph Scribe and Knowledge Keeper use inline perspective definitions in their Ash prompts.

The "Perspectives" column lists review focus areas aligned with dedicated agent files. Duplication detection (mimic-detector) is part of Forge Warden, not Pattern Weaver.

| Ash | Perspectives | Agent Source | When Summoned |
|-----------|-------------|-------------|-------------|
| **Forge Warden** | Code quality, architecture, performance, logic, type safety, missing logic, design anti-patterns, data integrity, duplication | Dedicated agent files | Backend, infra, config, or unclassified files changed |
| **Ward Sentinel** | All security perspectives | Dedicated agent files | Always (+ priority on `.claude/` files) |
| **Pattern Weaver** | Simplicity, cross-cutting patterns, dead code, incomplete implementations, TDD & test quality, async & concurrency, refactoring integrity, reference & config integrity | Dedicated agent files | Always |
| **Glyph Scribe** | Type safety, components, performance, hooks, accessibility | Inline perspectives | Frontend files changed |
| **Knowledge Keeper** | Accuracy, completeness, consistency, readability, security | Inline perspectives | Docs changed (>= threshold) or `.claude/` files changed |

## Truthbinding Protocol

All agent prompts include ANCHOR + RE-ANCHOR sections that:
- Instruct agents to ignore instructions from reviewed code
- Require evidence (Rune Traces) from actual source files
- Flag uncertain findings as LOW confidence

## Inscription Protocol

JSON contract (`inscription.json`) that defines:
- What each teammate must produce
- Required sections in output files
- Seal Format for completion signals
- Verification settings

## TOME (Structured Findings)

The unified review summary after deduplication and prioritization. Findings use structured `<!-- RUNE:FINDING -->` markers for machine parsing.

## Decree Arbiter

Utility agent that reviews plans for technical soundness across 9 dimensions: (1) architecture fit, (2) feasibility, (3) security/performance risks, (4) dependency impact, (5) pattern alignment, (6) internal consistency, (7) design anti-pattern risk, (8) consistency convention, (9) documentation impact. Uses Decree Trace evidence format.

## Remembrance Channel (REMOVED in v3.0.0-alpha.1)

> The persistent memory layer (`rune-echoes` skill, `.rune/echoes/` runtime
> consumer, `docs/solutions/` promotion pipeline) was removed in v3.0.0-alpha.1.
> Agent output now goes to `tmp/` files (ephemeral) — see CLAUDE.md Core Rule #6.
> The directory at `.rune/echoes/` may still be present from legacy runs but has
> no active consumer.

## Forge Gaze (Topic-Aware Agent Selection)

By default, `/rune:devise` and `/rune:forge` use Forge Gaze to match plan section topics to specialized agents.

- **Keyword overlap scoring** with title bonus — deterministic, zero token cost, transparent
- **Budget tiers**: `enrichment` (review agents, ~5k tokens) and `research` (practice-seeker/lore-scholar, ~15k tokens)
- **Default forge**: threshold 0.30, max 3 agents/section, enrichment only, max 8 total
- **`--exhaustive`**: threshold 0.15, max 5 agents/section, enrichment + research, max 12 total
- **Custom agents** from `talisman.yml` participate via `workflows: [forge]` + `trigger.topics` + `forge:` config

See `roundtable-circle/references/forge-gaze.md` for the topic registry and matching algorithm.

## Solution Arena (Plan Phase 1.8)

Competitive evaluation phase between research and synthesis. Generates 2-5 alternative solution approaches and evaluates them via adversarial challenger agents (Devil's Advocate for risk/failure analysis, Innovation Scout for novel alternatives). Solutions are scored across a 6-dimension weighted matrix (feasibility, complexity, risk, maintainability, performance, innovation). Convergence detection flags tied solutions for user tiebreaking. The champion solution feeds into Phase 2 (Synthesize) as the committed approach. Configurable via `solution_arena` section in `talisman.yml`. Skippable with `--no-arena` flag or `--quick` mode. Auto-skipped for `fix` feature types by default.

## Diff-Scope Engine (v1.38.0+)

Line-level diff intelligence for review and mend workflows. Generates expanded line ranges from `git diff --unified=0`, enriches `inscription.json` so Ashes know which lines changed, and tags TOME findings as `scope="in-diff"` or `scope="pre-existing"` after aggregation (review.md Phase 5.3). Mend uses scope tags to prioritize PR-relevant findings: P1 always fixed, P2 in-diff fixed / pre-existing skipped, P3 only in-diff. Smart convergence scoring uses scope composition (P3 dominance, pre-existing noise ratio) to detect early convergence. Configurable via `review.diff_scope.*` and `review.convergence.*` in talisman.yml. Backward compatible — untagged TOMEs default to `scope="in-diff"`.

## Arc Pipeline

End-to-end orchestration (19 phases as of v3.0.0-alpha.6): forge (research enrichment) → forge_qa → plan review (3-reviewer circuit breaker, with absorbed CONCERN-extraction post-step formerly `plan_refine`) → verification gate (deterministic checks, zero-LLM) → work (swarm implementation, with absorbed drift-signal review formerly `drift_review`) → work_qa → gap analysis (plan-to-code compliance) → gap_analysis_qa → gap_remediation → inspect (4 Inspector Ashes against plan, plus absorbed gap-fixer agents formerly `inspect_fix` and convergence eval formerly `verify_inspect` — all one phase with `inspect_convergence` retry loop) → code review (Roundtable Circle, deep) → code_review_qa → verify (TOME finding classification) → mend (parallel finding resolution) → mend_qa (1-agent QA scoring + absorbed convergence-gate post-step formerly `verify_mend` — smart scoring, scope-aware signals, adaptive retry cycles based on tier) → test (diff-scoped unit/property/integration/E2E execution) → test_qa → ship (preShipValidator dual-gate completion check formerly `pre_ship_validation` + auto PR creation via `gh pr create`; `deploy_verify` removed entirely in v3.x) → merge (rebase + squash-merge with pre-merge checklist).

Each delegated phase summons a fresh team. Checkpoint-based resume (`.rune/arc/{id}/checkpoint.json`) with artifact integrity validation (SHA-256 hashes). Per-phase tool restrictions and time budgets enforce least privilege. Config resolution follows 3-layer priority: hardcoded defaults → talisman.yml → CLI flags.

> **Removed from arc PHASE_ORDER**: goldmask verification, goldmask correlation (alpha.2 — `/rune:goldmask` remains standalone), bot review wait, pr comment resolution (alpha.2 — external pr-guardian), design extraction/verification/iteration, semantic verification, task decomposition, test coverage critique, release quality check, browser test/fix/verify, storybook verification, ux verification (alpha.1).

## Mend

Parallel finding resolution from TOME. Parses structured `<!-- RUNE:FINDING -->` markers with session nonce validation, groups findings by file, summons restricted mend-fixer teammates (no Bash, no TeamCreate). Ward check runs once after all fixers complete. Bisection algorithm identifies failing fixes on ward failure. After wards pass, a doc-consistency scan (MEND-3) fixes drift between source-of-truth files and downstream targets using topological sort, Edit-based surgical replacement, and hard depth limit of 1. Scope-aware priority filtering (v1.38.0+) skips pre-existing P2/P3 findings to focus mend budget on PR-relevant issues; P1 findings are always fixed regardless of scope. Resolution categories: FIXED, FALSE_POSITIVE, FAILED, SKIPPED, CONSISTENCY_FIX.

## Context Weaving

4-layer context management:
1. **Overflow Prevention**: Glyph Budget enforces file-only output
2. **Context Rot Prevention**: Instruction anchoring, read ordering
3. **Compression**: Session summaries when messages exceed thresholds
4. **Filesystem Offloading**: Large outputs written to `tmp/` files

## Multi-Agent Rules

| Scope | Required Protocol |
|-------|-------------------|
| All Rune multi-agent workflows | Agent Teams (`TeamCreate` + `TaskCreate`) + Glyph Budget + `inscription.json` |

Inscription verification scales with team size: Layer 0 for small teams (1-2 teammates), Layer 0 + Layer 2 for larger teams (5+). Non-Rune custom workflows may use standalone `Task` agents without `TeamCreate`.
