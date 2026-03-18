# Key Concepts

## The Tarnished (Orchestrator)

The lead agent that coordinates all Rune workflows. In Elden Ring, the Tarnished is
the protagonist who journeys through the Lands Between. In Rune, the Tarnished:
- Convenes the Roundtable Circle (review/audit orchestration)
- Coordinates Ashes and summons research agents
- Collects findings into the TOME
- Guides the arc pipeline from forge to audit
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

Forge Warden, Ward Sentinel, Pattern Weaver, and Veil Piercer embed dedicated review agent files from `agents/review/` (21 agents distributed across 4 Ashes — see circle-registry.md for mapping). Glyph Scribe, Knowledge Keeper, and Codex Oracle use inline perspective definitions in their Ash prompts. Codex Oracle wraps `codex exec` via Bash to provide cross-model verification using GPT-5.3-codex.

The "Perspectives" column lists review focus areas aligned with dedicated agent files (e.g., Forge Warden's 8 perspectives map to 8 agents in `agents/review/`). Duplication detection (mimic-detector) is part of Forge Warden, not Pattern Weaver.

| Ash | Perspectives | Agent Source | When Summoned |
|-----------|-------------|-------------|-------------|
| **Forge Warden** | Code quality, architecture, performance, logic, type safety, missing logic, design anti-patterns, data integrity, duplication | Dedicated agent files | Backend, infra, config, or unclassified files changed |
| **Ward Sentinel** | All security perspectives | Dedicated agent files | Always (+ priority on `.claude/` files) |
| **Pattern Weaver** | Simplicity, cross-cutting patterns, dead code, incomplete implementations, TDD & test quality, async & concurrency, refactoring integrity, reference & config integrity | Dedicated agent files | Always |
| **Glyph Scribe** | Type safety, components, performance, hooks, accessibility | Inline perspectives | Frontend files changed |
| **Knowledge Keeper** | Accuracy, completeness, consistency, readability, security | Inline perspectives | Docs changed (>= threshold) or `.claude/` files changed |
| **Codex Oracle** | Cross-model security, logic, quality (via GPT-5.3-codex) | Inline perspectives (codex exec) | `codex` CLI available AND `talisman.codex.disabled` is not true |

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

## Remembrance Channel

Human-readable knowledge documents in `docs/solutions/` promoted from high-confidence Rune Echoes. See `rune-echoes/references/remembrance-schema.md` for the promotion rules and YAML frontmatter schema.

## Rune Echoes

Project-level agent memory in `.rune/echoes/` with 3-layer lifecycle:
1. **Etched**: Permanent project knowledge (architecture, conventions) — never auto-pruned
2. **Inscribed**: Tactical patterns from reviews/audits — pruned after 90 days unreferenced
3. **Traced**: Session observations — pruned after 30 days

Agents persist learnings automatically after workflows. Future workflows read echoes to avoid repeating mistakes. See `rune-echoes` skill for full lifecycle.

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

End-to-end orchestration across 17 phases: forge (research enrichment), plan review (3-reviewer circuit breaker), plan refinement (concern extraction, orchestrator-only), verification gate (deterministic checks, zero-LLM), semantic verification (Codex cross-model analysis, v1.39.0+), work (swarm implementation), gap analysis (plan-to-code compliance, deterministic, orchestrator-only), codex gap analysis (Codex cross-model gap detection, v1.39.0+), code review (Roundtable Circle), mend (parallel finding resolution), verify mend (convergence gate with smart scoring, scope-aware signals, and adaptive retry cycles based on tier), test (diff-scoped unit/integration/E2E execution, v1.43.0+), goldmask verification (blast-radius analysis via investigation agents, v1.47.0+), goldmask correlation (synthesis of investigation findings, v1.47.0+), audit (final gate), ship (auto PR creation via `gh pr create`, v1.40.0+), and merge (rebase + squash-merge with pre-merge checklist, v1.40.0+). Each delegated phase summons a fresh team. Checkpoint-based resume (`.rune/arc/{id}/checkpoint.json`) with artifact integrity validation (SHA-256 hashes). Per-phase tool restrictions and time budgets enforce least privilege. Config resolution follows 3-layer priority: hardcoded defaults → talisman.yml → CLI flags.

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
