# Discipline — Creation Log

## Problem Statement

Multi-agent pipelines lacked a shared, loadable reference for proof-based orchestration principles. Workers implementing tasks in strive/arc workflows had no canonical skill to inject discipline context: proof type selection, evidence artifact format, anti-rationalization counters, and the Separation Principle. Without a discipline skill, each workflow had to re-document these concepts inline, leading to drift between implementations.

The `docs/discipline-engineering.md` foundational document (v2.3.0) existed but was 110KB — too large to inject directly into agent contexts. A distilled skill with targeted reference documents provides the same discipline guarantees at fraction of the token cost.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Inline discipline rules in each worker prompt | Leads to drift — different workers apply different subsets of the rules |
| Load full `docs/discipline-engineering.md` per agent | 110KB is prohibitive for agent context injection |
| Hook-only enforcement (no skill) | Hooks enforce structure but cannot teach workers which proof type to choose |

## Key Design Decisions

- **`user-invocable: false`**: Discipline is background knowledge that auto-loads into workers — not a slash command. Workers don't invoke discipline; the orchestrator ensures it is active.
- **Iron Law at top**: Following `inner-flame` convention, the Iron Law (DISC-001) is the first substantive content. This ensures the absolute constraint is read before any implementation detail.
- **Proof schema in references/**: Full proof type definitions, tool mappings, and the evidence artifact schema go in `references/proof-schema.md` — not inline in SKILL.md. SKILL.md stays under 500 lines; references are loaded on demand.
- **Five-layer summary, not specification**: SKILL.md contains one-line summaries of each discipline layer. Full specification lives in `docs/discipline-engineering.md`. This prevents SKILL.md from becoming a redundant copy of the source document.

## Iteration History

| Date | Version | Change | Trigger |
|------|---------|--------|---------|
| 2026-03-16 | v1.0 | Initial creation — SKILL.md + proof-schema.md | Discipline Engineering foundation shard (strive Task 1.1, 1.2) |
