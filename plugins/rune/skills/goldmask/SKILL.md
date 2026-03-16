---
name: goldmask
description: |
  Use when assessing blast radius of changes, when understanding WHY code was written a
  certain way, when planning risky modifications, or when a refactor could have hidden
  side effects. Traces WHAT changes, WHY it exists (git archaeology), and HOW RISKY
  the area is (churn + ownership metrics). Keywords: impact analysis, blast radius,
  risk assessment, code archaeology, why was this written.

  <example>
  Context: Running standalone impact analysis
  user: "/rune:goldmask HEAD~3..HEAD"
  assistant: "Loading goldmask for cross-layer impact analysis"
  </example>

  <example>
  Context: Checking blast radius before a refactor
  user: "/rune:goldmask src/auth/ src/payment/"
  assistant: "Loading goldmask for impact + wisdom + lore analysis on specified files"
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[diff-spec or file list]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Agent
  - TeamCreate
  - TeamDelete
  - TaskCreate
  - TaskList
  - TaskGet
  - TaskUpdate
  - SendMessage
---

# Goldmask Skill — Cross-Layer Impact Analysis

**Load skills**: `rune-orchestration`, `context-weaving`, `team-sdk`, `polling-guard`, `zsh-compat`

Three-layer investigation that answers: **WHAT** must change (Impact), **WHY** it was built that way (Wisdom), and **HOW RISKY** the area is (Lore). Includes Collateral Damage Detection (CDD) to predict blast radius.

## ATE-1 ENFORCEMENT

**CRITICAL**: Every `Agent` call in this skill MUST include `team_name`. Bare `Agent` calls without `team_name` cause context explosion and are blocked by the `enforce-teams.sh` hook.

## Architecture — Goldmask's Three Eyes

```
                    +---------------------------------------+
                    |       GOLDMASK COORDINATOR            |
                    |       (Sonnet)                        |
                    |                                       |
                    |  Synthesize all three layers:          |
                    |  1. WHAT must change (Impact)          |
                    |  2. WHY it was built (Wisdom)          |
                    |  3. HOW RISKY is this area (Lore)      |
                    |                                       |
                    |  Produce: GOLDMASK.md + findings.json  |
                    +-------------------+-------------------+
                                        | reads all layer outputs
            +--------------------------++--------------------------+
            |                           |                           |
    +-------v--------+   +-------------v---------+   +-------------v------+
    |  IMPACT LAYER   |   |   WISDOM LAYER         |   |  LORE LAYER        |
    |  5 Tracers      |   |   1 Sage (Sonnet)       |   |  1 Analyst (Haiku) |
    |  (Haiku each)   |   |   - git blame            |   |  - git log          |
    |  - grep/glob    |   |   - commit context       |   |  - risk scoring     |
    |  - dependency   |   |   - intent classify      |   |  - co-change graph  |
    |    tracing      |   |   - caution scoring      |   |  - hotspot detect   |
    +----------------+   +------------------------+   +-------------------+
```

## Modes

| Mode | Trigger | Agents | Output |
|------|---------|--------|--------|
| **Full investigation** | `/rune:goldmask <diff-spec>` | 8 (5+1+1+1) | GOLDMASK.md + findings.json + risk-map.json |
| **Quick check** | `/rune:goldmask --quick <files>` | 0 (deterministic) | Warnings only — compares predicted vs actual |
| **Intelligence** | `/rune:goldmask --lore <diff-spec>` | 1 (Lore only) | risk-map.json for file sorting |

### MCP-First Tracer Discovery (v1.170.0+)

Investigation agents (tracers) can be discovered via MCP search:

```pseudocode
# Phase 1: Tracer Selection
tracers = []

if mcp_available:
  candidates = agent_search({
    query: "impact analysis tracing investigation risk",
    phase: "goldmask",
    category: "investigation",
    limit: 10
  })
  tracers = candidates
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")

if not tracers:
  # Fallback: hardcoded tracer list (current behavior)
  tracers = DEFAULT_GOLDMASK_TRACERS
```

This enables user-defined investigation agents (e.g., "compliance-tracer" for audit trails)
to participate in Goldmask analysis alongside the 8 built-in tracers.

## Phase Sequencing

```
Phase 1: LORE ANALYSIS (parallel with Phase 2)
    |  Lore Analyst --> risk-map.json
    |  (Haiku, ~15-30s)
    |
Phase 2: IMPACT TRACING (parallel with Phase 1, 5 tracers)
    |  Data, API, Business, Event, Config Tracers --> 5 reports
    |  (Haiku x 5, ~30-60s)
    |
    +-- Lore + Impact complete --> Phase 3 starts
    |
Phase 3: WISDOM INVESTIGATION (sequential — needs Impact output)
    |  Wisdom Sage receives:
    |    - All MUST-CHANGE + SHOULD-CHECK findings from Impact
    |    - risk-map.json from Lore (for risk tier context)
    |  Wisdom Sage --> intent classifications + caution scores
    |  (Sonnet, ~60-120s)
    |
Phase 3.5: CODEX RISK AMPLIFICATION (parallel with Phase 3, v1.51.0+)
    |  Codex traces 2nd/3rd-order risk chains
    |  Reads Impact outputs + risk-map.json
    |  --> risk-amplification.md (CDX-RISK prefix)
    |  (codex exec, opt-in, ~600s)
    |
Phase 4: COORDINATION + CDD
    |  Goldmask Coordinator merges all three layers
    |  --> GOLDMASK.md + findings.json
    |  (Sonnet, ~60-90s)
    |
Total estimated time: 3-5 minutes
Total agents: 8 (5 Haiku tracers + 1 Haiku lore-analyst + 1 Sonnet wisdom-sage + 1 Sonnet coordinator)
```

## Orchestration Protocol

**Phases 0-3**: Parse input (diff-spec or file list, SEC-10 flag injection + path traversal guards), resolve changed files via `git diff --name-only`, generate session ID + output dir (SEC-5 validated), write inscription.json, acquire workflow lock (reader), pre-create guard + TeamCreate, write state file with session isolation.

See [orchestration-protocol.md](references/orchestration-protocol.md) for full pseudocode.

**Phases 4-6**: Create 8 tasks (1 Lore + 5 Impact tracers parallel → 1 Wisdom Sage sequential → 1 Coordinator sequential). Optional Phase 3.5 Codex Risk Amplification. POLL-001 compliant monitoring. Each layer degrades independently — any combination is better than a single layer.

See [phase-4-5-6-tasks-monitor-degradation.md](references/phase-4-5-6-tasks-monitor-degradation.md) for task creation, spawn contracts, polling config, and degradation rules. See [codex-risk-amplification.md](references/codex-risk-amplification.md) for Phase 3.5.

**Phase 7**: Standard 5-component team cleanup. See [phase7-cleanup.md](references/phase7-cleanup.md).

**Phase 8**: Read and present `GOLDMASK.md` summary.

## Quick Check (--quick) / Intelligence (--lore) / Output Paths

`--quick`: No agents — deterministic comparison of predicted vs committed MUST-CHANGE files. `--lore`: Lore Analyst only → risk-map.json. Output: `tmp/goldmask/{session_id}/` with 10 files.

See [modes-and-output.md](references/modes-and-output.md) for mode protocols and output directory structure.

## Reference Files

- [trace-patterns.md](references/trace-patterns.md) — Grep/Glob patterns per language per layer
- [confidence-scoring.md](references/confidence-scoring.md) — Noisy-OR formula + caution scoring
- [intent-signals.md](references/intent-signals.md) — Design intent classification patterns
- [output-format.md](references/output-format.md) — GOLDMASK.md + findings.json + risk-map.json schemas
- [investigation-protocol.md](references/investigation-protocol.md) — 5-step protocol for Impact tracers
- [wisdom-protocol.md](references/wisdom-protocol.md) — 6-step protocol for Wisdom Sage
- [lore-protocol.md](references/lore-protocol.md) — Risk scoring formula for Lore Analyst

### Shared Cross-Skill References

These files are consumed by other skills (forge, mend, inspect, devise) via cross-skill links:

- [goldmask-quick-check.md](references/goldmask-quick-check.md) — Quick check protocol (used by forge, mend)
- [lore-layer-integration.md](references/lore-layer-integration.md) — Lore Layer integration patterns (used by forge, inspect, devise, mend)
- [risk-tier-sorting.md](references/risk-tier-sorting.md) — Risk tier sorting utilities (used by forge, mend)
