---
name: devise
description: |
  Multi-agent planning workflow using Agent Teams. Combines brainstorm, research,
  validation, synthesis, shatter assessment, forge enrichment, and review into a
  single orchestrated pipeline with dependency-aware task scheduling.

  <example>
  user: "/rune:devise"
  assistant: "The Tarnished begins the planning ritual — full pipeline with brainstorm, forge, and review..."
  </example>

  <example>
  user: "/rune:devise --quick"
  assistant: "The Tarnished begins a quick planning ritual — research, synthesize, review only..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[--quick] [--brainstorm-context PATH] [--no-brainstorm] [--no-forge] [--no-arena] [--no-verify-research] [--exhaustive]"
allowed-tools:
  - Agent
  - TaskCreate
  - TaskList
  - TaskUpdate
  - TaskGet
  - TeamCreate
  - TeamDelete
  - SendMessage
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
  - WebSearch
  - WebFetch
---

# /rune:devise — Multi-Agent Planning Workflow

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `elicitation`, `codex-cli`, `team-sdk`, `polling-guard`, `zsh-compat`

Orchestrates a planning pipeline using Agent Teams with dependency-aware task scheduling.

## Usage

```
/rune:devise                              # Full pipeline (brainstorm + research + validate + synthesize + shatter? + forge + review)
/rune:devise --quick                      # Quick: research + synthesize + review only (skip brainstorm, forge, shatter)
/rune:devise --brainstorm-context PATH    # Skip Phase 0, use existing brainstorm workspace for rich research context
```

### Legacy Flags (still functional, undocumented)

```
/rune:devise --no-brainstorm              # Skip brainstorm only (granular)
/rune:devise --no-forge                   # Skip forge only (granular)
/rune:devise --no-arena                   # Skip Arena only (granular)
/rune:devise --no-verify-research          # Skip research output verification (Phase 1C.5)
/rune:devise --exhaustive                 # Exhaustive forge mode (lower threshold, research-budget agents)
/rune:devise --brainstorm                 # No-op (brainstorm is already default)
/rune:devise --forge                      # No-op (forge is already default)
```

## Pipeline Overview

```
Phase -1: Team Bootstrap (TeamCreate + state file — enables ATE-1 enforcement)
    ↓
Phase 0: Gather Input (3 paths: --brainstorm-context → read workspace, --quick → skip, default → delegate to brainstorm protocol)
    ↓
Phase 1: Research (up to 8 agents, conditional — join existing team)
    ├─ Phase 1A: LOCAL RESEARCH (always — repo-surveyor, echo-reader, git-miner)
    ├─ Phase 1B: RESEARCH DECISION (talisman plan config bypass, risk + local sufficiency scoring, URL sanitization)
    ├─ Phase 1C: EXTERNAL RESEARCH (conditional — practice-seeker + Context7 MCP, lore-scholar + Context7, codex-researcher)
    ├─ Phase 1C.5: RESEARCH VERIFICATION (conditional — research-verifier, serial/blocking)
    └─ Phase 1D: SPEC VALIDATION (always — flow-seer)
    ↓ (all research tasks converge)
Phase 1.5: Research Consolidation Validation (AskUserQuestion checkpoint)
    ↓
Phase 1.8: Solution Arena (competitive evaluation — skip with --quick or --no-arena)
    ↓
Phase 2: Synthesize (lead consolidates findings, detail level selection)
    ↓
Phase 2.3: Predictive Goldmask (risk scoring + wisdom advisories — skip with --quick)
    ↓
Phase 2.5: Shatter Assessment (complexity scoring → optional decomposition)
    ↓
Phase 3: Forge (default — skipped with --quick)
    ↓
Phase 4: Plan Review (scroll review + optional iterative refinement)
    ↓
Phase 4.5: Technical Review (optional — decree-arbiter + knowledge-keeper + codex-plan-reviewer)
    ↓
Phase 5: Echo Persist (save learnings to .claude/echoes/)
    ↓
Phase 6: Cleanup & Present (shutdown teammates, TeamDelete, present plan)
    ↓
Output: plans/YYYY-MM-DD-{type}-{name}-plan.md
        (or plans/YYYY-MM-DD-{type}-{name}-shard-N-plan.md if shattered)
```

## Workflow Lock (planner)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "planner"`)
// Planner conflicts are ADVISORY only — inform, never block
if (lockConflicts.includes("CONFLICT") || lockConflicts.includes("ADVISORY")) {
  warn(`Active workflow(s) detected:\n${lockConflicts}`)
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "devise" "planner"`)
```

## Phase -1: Team Bootstrap

Creates the Agent Team before any agents spawn using the `teamTransition` protocol (6-step: validate → TeamDelete with retry → filesystem fallback → TeamCreate with "Already leading" recovery → post-create verification → state file write). Enables ATE-1 enforcement for all subsequent phases.

See [team-bootstrap.md](references/team-bootstrap.md) for the full protocol.

## Phase 0: Gather Input

Three paths based on flags:

1. **`--brainstorm-context PATH`**: Read existing brainstorm workspace. Skip brainstorm entirely. Inject workspace context (advisor research, decisions, quality score) into Phase 1 research agents. Quality score from `workspace-meta.json` determines confidence level (>= 0.70: high-confidence, < 0.70: flag as "exploratory").

2. **`--quick`**: Skip brainstorm entirely. Ask user for a feature description via AskUserQuestion. Proceed directly to Phase 1.

3. **Default**: Delegate to the brainstorm protocol defined in `skills/brainstorm/SKILL.md`. Brainstorm runs with these devise-specific overrides: advisors join existing `rune-plan-{timestamp}` team (not a separate team), workspace co-located at `tmp/brainstorm-{timestamp}/`, also writes to `tmp/plans/{timestamp}/brainstorm-decisions.md` (legacy location), skips the brainstorm handoff phase (devise continues to research).

**Elicitation**: After approach selection, summons 1-3 elicitation-sage teammates (keyword-count fan-out, 15-keyword list). Skippable via `talisman.elicitation.enabled: false`.

**Output**: `tmp/plans/{timestamp}/brainstorm-decisions.md` with mandatory sections: Non-Goals, Constraint Classification, Success Criteria, Scope Boundary.

### Design Signal Detection & Inventory Agent

Scans user description for Figma URLs (`FIGMA_URL_PATTERN`), sets `designAware` flag, and conditionally spawns `design-inventory-agent` to call `figma_list_components` MCP for component pre-population. Includes `--quick` fallback for re-scanning feature description when Phase 0 is skipped.

See [design-signal-detection.md](references/design-signal-detection.md) for the full detection logic and inventory agent spawn protocol.

See [brainstorm-phase.md](references/brainstorm-phase.md) for the delegation protocol, `--brainstorm-context` workspace reading, and devise-specific overrides.

Read and execute when Phase 0 runs.

### Design System & Builder Discovery (Phase 0.5)

Runs design system and UI builder discovery after Figma URL detection, before Phase 1. Zero cost when no design system or builder is detected. Loads companion skill (e.g., `untitledui-mcp`) when a builder is found.

See [design-system-discovery/SKILL.md](../design-system-discovery/SKILL.md) for the full algorithms. See [ux-and-mcp-discovery.md](references/ux-and-mcp-discovery.md) for the inline discovery code.

### Phase 0.3: UX Research (conditional)

Spawns `ux-pattern-analyzer` to assess current UX maturity when `ux.enabled` is true and frontend files are detected. Runs AFTER Design System Discovery (Phase 0.5), BEFORE Phase 1 Research. Zero cost when UX is disabled or no frontend files exist.

**Skip conditions**: `talisman.ux.enabled` is not `true`, or no frontend files detected.

**Output**: `brainstormContext.ux_maturity` — consumed by Phase 2 (Synthesize) to enrich the plan with UX pattern recommendations.

See [ux-and-mcp-discovery.md](references/ux-and-mcp-discovery.md) for the full agent spawn code, skip logic, and UX maturity schema.

### MCP Integration Discovery (Phase 0, conditional)

Resolve active MCP integrations for the `devise` phase. Zero cost when no integrations configured.

See [ux-and-mcp-discovery.md](references/ux-and-mcp-discovery.md) for the inline integration code. See `strive/references/mcp-integration.md` for the shared resolver algorithm.

## Phase 1: Research (Conditional, up to 8 agents)

Spawns local research agents (repo-surveyor, echo-reader, git-miner), evaluates risk/sufficiency scores to decide on external research (practice-seeker, lore-scholar, codex-researcher), optionally verifies external research outputs for trustworthiness (research-verifier, Phase 1C.5), then runs spec validation (flow-seer). Includes research consolidation validation checkpoint. Phase 1B reads `talisman.plan` config for `external_research` bypass modes (`always`/`auto`/`never`) and `research_urls` with SSRF-defensive URL sanitization. External research agents use Context7 MCP for framework documentation alongside WebSearch. Phase 1C.5 scores findings across 5 dimensions (relevance, accuracy, freshness, cross-validation, security) and maps verdicts (TRUSTED/CAUTION/UNTRUSTED/FLAGGED) — skipped with `--quick`, `--no-verify-research`, or when no external research ran.

**Inputs**: `feature` (sanitized string, from Phase 0), `timestamp` (validated identifier), talisman config (plan section for research control)
**Outputs**: Research agent outputs in `tmp/plans/{timestamp}/research/`, `inscription.json`
**Error handling**: TeamDelete fallback on cleanup, identifier validation before rm-rf, agent timeout (5 min) proceeds with partial findings

See [research-phase.md](references/research-phase.md) for the full protocol.

#### MCP Tool Context in Research Agents

When `mcpIntegrations.length > 0`, append MCP context to research agent prompts (practice-seeker, lore-scholar, repo-surveyor). See [ux-and-mcp-discovery.md](references/ux-and-mcp-discovery.md) for injection code.

## Phase 1.8: Solution Arena

Generates competing solutions from research, evaluates on weighted dimensions, challenges with adversarial agents, and presents a decision matrix for approach selection.

**Skip conditions**: `--quick`, `--no-arena`, bug fixes, high-confidence refactors (confidence >= 0.9), sparse research (<2 viable approaches).

See [solution-arena.md](references/solution-arena.md) for full protocol (sub-steps 1.8A through 1.8D).

**Inputs**: Research outputs from `tmp/plans/{timestamp}/research/`, brainstorm-decisions.md (optional)
**Outputs**: `tmp/plans/{timestamp}/arena/arena-selection.md` (winning solution with rationale)
**Error handling**: Complexity gate skip → log reason. Sparse research → skip Arena. Agent timeout → proceed with partial. All solutions killed → recovery protocol.

## Phase 2: Synthesize

Tarnished consolidates research findings into a plan document. User selects detail level (Minimal/Standard/Comprehensive). Includes plan templates, formatting best practices, and the Plan Section Convention (contracts before pseudocode).

**Inputs**: Research outputs from `tmp/plans/{timestamp}/research/`, user detail level selection, `designAware` (boolean from Phase 0), `figmaUrls` (string[] from Phase 0), `figmaUrl` (string or null — first entry, backward compat)
**Outputs**: `plans/YYYY-MM-DD-{type}-{feature-name}-plan.md`
**Error handling**: Missing research files -> proceed with available data
**Comprehensive only**: Re-runs flow-seer on the drafted plan for a second SpecFlow pass
**Design-aware**: When `design_sync_candidate === true`, adds `figma_urls` array and `design_sync: true` to frontmatter, and emits a "Design Implementation" section in the plan body (with component inventory from design-inventory-agent if available)

See [synthesize.md](references/synthesize.md) for the full protocol.

#### MCP Integration Context in Synthesis

When active MCP integrations are available, include MCP tools, companion skills, and library metadata in the synthesis prompt. See [ux-and-mcp-discovery.md](references/ux-and-mcp-discovery.md) for injection code.

## Phase 2.3: Predictive Goldmask

Runs predictive risk analysis on files likely affected by the plan. Supports 3 depth modes (basic/enhanced/full) controlled via `talisman.goldmask.devise.depth`.

**Skip conditions**: `--quick` mode, `goldmask.enabled === false`, `goldmask.devise.enabled === false`, non-git repo.

See [goldmask-prediction.md](references/goldmask-prediction.md) for the full protocol — depth modes, agent spawning, plan injection, and error handling.

## Phase 2.3.5: Research Conflict Tiebreaker (Codex)

**CONDITIONAL** — only runs when research agents produce conflicting recommendations (~20% trigger rate).

See [conflict-tiebreaker.md](references/conflict-tiebreaker.md) for the full protocol.

## Phase 2.5: Shatter Assessment

Skipped when `--quick` is passed. Assesses plan complexity and optionally decomposes into shards or hierarchical children.

### Complexity Scoring

| Signal | Weight | Threshold |
|--------|--------|-----------|
| Task count | 40% | >= 8 tasks |
| Phase count | 30% | >= 3 phases |
| Cross-cutting concerns | 20% | >= 2 shared deps |
| Estimated effort | 10% | >= 2 L-size phases |

Score >= 0.65: Offer shatter. Score < 0.65: Skip to forge.

See [shatter-assessment.md](references/shatter-assessment.md) for the full protocol — shard generation, hierarchical decomposition, and coherence checks.
```

## Phase 3: Forge (Default — skipped with `--quick`)

Forge runs by default. Uses **Forge Gaze** (topic-aware agent matching) to select the best specialized agents for each plan section.

**Auto-trigger**: If user message contains ultrathink keywords (ULTRATHINK, DEEP, ARCHITECT), auto-enable `--exhaustive` forge mode.

### Default `--forge` Mode

- Parse plan into sections (## headings)
- Run Forge Gaze matching: threshold 0.30, max 3 agents/section, enrichment-budget agents only
- Summon throttle: max 5 concurrent, max 8 total agents
- Elicitation sages: up to MAX_FORGE_SAGES=6 per eligible section (keyword pre-filter)

### `--exhaustive` Mode

- Threshold: 0.15, max 5 agents/section, max 12 total
- Includes research-budget agents
- Two-tier aggregation
- Cost warning before summoning

**Fallback**: If no agent scores above threshold, use inline generic Task prompt for standard enrichment.

**Truthbinding**: All forge prompts include ANCHOR/RE-ANCHOR blocks. Plan content sanitized before injection (strip HTML comments, code fences, headings, HTML entities, zero-width chars).

See [forge-gaze.md](../roundtable-circle/references/forge-gaze.md) for the full topic registry and matching algorithm.

## Phase 4: Plan Review (Iterative)

Runs scroll-reviewer for document quality, then automated verification gate (deterministic checks including talisman patterns, universal checks, CommonMark compliance, measurability, filler detection). Optionally summons decree-arbiter, knowledge-keeper, and codex-plan-reviewer for technical review.

**Inputs**: Plan document from Phase 2/3, talisman config
**Outputs**: `tmp/plans/{timestamp}/scroll-review.md`, `tmp/plans/{timestamp}/decree-review.md`, `tmp/plans/{timestamp}/knowledge-review.md`, `tmp/plans/{timestamp}/codex-plan-review.md`
**Error handling**: BLOCK verdict -> address before presenting; CONCERN verdicts -> include as warnings
**Iterative**: Max 2 refinement passes for HIGH severity issues

See [plan-review.md](references/plan-review.md) for the full protocol.

## Phase 5: Echo Persist

Persist planning learnings to Rune Echoes:

```javascript
if (exists(".claude/echoes/planner/")) {
  appendEchoEntry(".claude/echoes/planner/MEMORY.md", {
    layer: "inscribed",
    source: `rune:devise ${timestamp}`,
    // ... key learnings from this planning session
  })
}
```

## Phase 6: Cleanup & Present

Standard 5-component team cleanup: dynamic member discovery (with 30+ member fallback array covering all conditional phases), shutdown_request broadcast, grace period, retry-with-backoff TeamDelete (4 attempts), process-level kill + filesystem fallback (QUAL-012 gated), workflow lock release, then present plan to user.

See [phase6-cleanup.md](references/phase6-cleanup.md) for the full cleanup protocol.

## Output

Plan file written to: `plans/YYYY-MM-DD-{type}-{feature-name}-plan.md`

**Filename examples**:
- `plans/2026-02-12-feat-user-authentication-plan.md`
- `plans/2026-02-12-fix-checkout-race-condition-plan.md`
- `plans/2026-02-12-refactor-api-client-plan.md`

After presenting the plan, offer next steps using AskUserQuestion:
- `/rune:strive` → `Skill("rune:strive", plan_path)`
- `/rune:forge` → `Skill("rune:forge", plan_path)`
- Open in editor → `Bash("open plans/${path}")` (macOS)
- Create issue → See [issue-creation.md](../rune-orchestration/references/issue-creation.md)

## Issue Creation

See [issue-creation.md](../rune-orchestration/references/issue-creation.md) for the full algorithm.

Read and execute when user selects "Create issue".

## Error Handling

| Error | Recovery |
|-------|----------|
| Research agent timeout (>5 min) | Proceed with partial research |
| Research verification timeout (>5 min) | Proceed with unverified research + warning |
| No git history (git-miner) | Skip, report gap |
| No echoes (echo-reader) | Skip, proceed without history |
| Solution Arena: all solutions killed | Recovery protocol — relax constraints, re-evaluate (see solution-arena.md) |
| Solution Arena: sparse research (<2 approaches) | Skip Arena, proceed to synthesize |
| Forge agent timeout (>5 min) | Proceed with partial enrichment |
| Forge: no agent above threshold | Use inline generic Task prompt for standard enrichment |
| Predictive Goldmask agent failure | Non-blocking — proceed with partial data or skip injection |
| Predictive Goldmask: enhanced budget exceeded | Fallback to basic mode (2 agents) |
| TeamCreate failure ("Already leading") | Catch-and-recover via teamTransition protocol |
| TeamDelete failure (cleanup) | Retry-with-backoff (3 attempts), filesystem fallback |
| Scroll review finds critical gaps | Address before presenting |
| Plan review BLOCK verdict | Address blocking issues before presenting plan |

## Guardrails

Do not generate implementation code, test files, or configuration changes. This command produces research and plan documents only. If a research agent or forge agent starts writing implementation code, stop it and redirect to plan documentation. Code examples in plans are illustrative pseudocode only.
