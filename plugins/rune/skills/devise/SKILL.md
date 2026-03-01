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
argument-hint: "[--quick] [--no-brainstorm] [--no-forge] [--no-arena] [--no-verify-research] [--exhaustive]"
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

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `elicitation`, `codex-cli`, `polling-guard`, `zsh-compat`

Orchestrates a planning pipeline using Agent Teams with dependency-aware task scheduling.

## Usage

```
/rune:devise                              # Full pipeline (brainstorm + research + validate + synthesize + shatter? + forge + review)
/rune:devise --quick                      # Quick: research + synthesize + review only (skip brainstorm, forge, shatter)
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
Phase 0: Gather Input (brainstorm by default — auto-skip when requirements are clear)
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

Create the Agent Team before any agents spawn. This ensures Phase 0 agents (elicitation sages, design-inventory-agent) can join the team and comply with ATE-1 enforcement.

```javascript
// teamTransition protocol — moved from research-phase.md to run before Phase 0
// STEP 1: Validate (defense-in-depth)
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid plan identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected in plan identifier')

// STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
let teamDeleteSucceeded = false
const RETRY_DELAYS = [0, 3000, 8000]
for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
  if (attempt > 0) {
    warn(`teamTransition: TeamDelete attempt ${attempt + 1} failed, retrying in ${RETRY_DELAYS[attempt]/1000}s...`)
    Bash(`sleep ${RETRY_DELAYS[attempt] / 1000}`)
  }
  try {
    TeamDelete()
    teamDeleteSucceeded = true
    break
  } catch (e) {
    if (attempt === RETRY_DELAYS.length - 1) {
      warn(`teamTransition: TeamDelete failed after ${RETRY_DELAYS.length} attempts. Using filesystem fallback.`)
    }
  }
}

// STEP 3: Filesystem fallback (only when STEP 2 failed — avoids blast radius on happy path)
// CDX-003 FIX: Gate behind !teamDeleteSucceeded to prevent cross-workflow scan from
// wiping concurrent workflows when TeamDelete already succeeded cleanly.
if (!teamDeleteSucceeded) {
  // Scoped cleanup — only remove THIS session's team/task dirs (not all rune-*/arc-*)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-plan-${timestamp}/" "$CHOME/tasks/rune-plan-${timestamp}/" 2>/dev/null`)
  try { TeamDelete() } catch (e2) { /* proceed to TeamCreate */ }
}

// STEP 4: TeamCreate with "Already leading" catch-and-recover
// Match: "Already leading" — centralized string match for SDK error detection
try {
  TeamCreate({ team_name: "rune-plan-{timestamp}" })
} catch (createError) {
  if (/already leading/i.test(createError.message)) {
    warn(`teamTransition: Leadership state leak detected. Attempting final cleanup.`)
    try { TeamDelete() } catch (e) { /* exhausted */ }
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-plan-${timestamp}/" "$CHOME/tasks/rune-plan-${timestamp}/" 2>/dev/null`)
    try {
      TeamCreate({ team_name: "rune-plan-{timestamp}" })
    } catch (finalError) {
      throw new Error(`teamTransition failed: unable to create team after exhausting all cleanup strategies. Run /rune:rest --heal to manually clean up, then retry. (${finalError.message})`)
    }
  } else {
    throw createError
  }
}

// STEP 5: Post-create verification
Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -f "$CHOME/teams/rune-plan-${timestamp}/config.json" || echo "WARN: config.json not found after TeamCreate"`)

// STEP 6: Write workflow state file with session isolation fields
// CRITICAL: This state file activates the ATE-1 hook (enforce-teams.sh) which blocks
// bare Agent calls without team_name. Without this file, agents spawn as local subagents
// instead of Agent Team teammates, causing context explosion.
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write(`tmp/.rune-plan-${timestamp}.json`, {
  team_name: `rune-plan-${timestamp}`,
  started: new Date().toISOString(),
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}",
  feature: feature
})
```

## Phase 0: Gather Input

Runs a structured brainstorm session by default. Auto-detects recent brainstorms in `docs/brainstorms/` and `tmp/plans/*/brainstorm-decisions.md`. Skips when requirements are already clear.

**Skip conditions**: `--quick` flag, user provided specific acceptance criteria, scope is constrained and well-defined.

**Elicitation**: After approach selection, summons 1-3 elicitation-sage teammates (keyword-count fan-out, 15-keyword list). Skippable via `talisman.elicitation.enabled: false`.

**Output**: `tmp/plans/{timestamp}/brainstorm-decisions.md` with mandatory sections: Non-Goals, Constraint Classification, Success Criteria, Scope Boundary.

### Design Signal Detection (Phase 0 pre-step)

Before brainstorm questions, scan the user description for Figma URLs. When detected, enables design-aware planning throughout the pipeline. With `--quick` (Phase 0 skipped), a fallback applies `FIGMA_URL_PATTERN` to the feature description before Phase 1 agents spawn.

```javascript
// SYNC: figma-url-pattern — shared with brainstorm-phase.md Step 3.2
const FIGMA_URL_PATTERN = /https?:\/\/[^\s]*figma\.com\/[^\s]+/g
const DESIGN_KEYWORD_PATTERN = /\b(figma|design|mockup|wireframe|prototype|ui\s*kit|design\s*system|style\s*guide|component\s*library)\b/i

// Phase 0 detection (brainstorm mode)
const figmaUrls = userDescription.match(FIGMA_URL_PATTERN) || []
const figmaUrl = figmaUrls.length > 0 ? figmaUrls[0] : null
const designAware = figmaUrl !== null

// --quick fallback: Phase 0 is skipped, so apply detection before Phase 1
// The feature description is still available from the user prompt
if (quickMode && !designAware) {
  // Re-scan: user may have provided Figma URL as part of quick description
  const quickFigma = featureDescription.match(FIGMA_URL_PATTERN)
  if (quickFigma) {
    figmaUrl = quickFigma[0]
    designAware = true
  }
}

// Pass designAware and figmaUrl to brainstorm phase (Step 3.2 design asset detection)
// Pass designAware and figmaUrl to synthesize phase (frontmatter + Design Implementation section)
let design_sync_candidate = designAware

if (designAware) {
  loadedSkills.push('design-sync')
  loadedSkills.push('frontend-design-patterns')
}
```

### Design Inventory Agent (conditional, Phase 0 post-step)

When `design_sync_candidate === true` AND `talisman.design_sync.enabled === true`, spawn a lightweight design-inventory-agent that calls `figma_list_components` MCP tool to pre-populate the component inventory for the plan.

```javascript
// Conditional design research agent — only when design_sync_candidate + talisman enabled
const designSyncEnabled = talisman?.design_sync?.enabled === true

if (design_sync_candidate && designSyncEnabled && figmaUrl) {
  // ATE-1 COMPLIANT: Agent joins rune-plan-{timestamp} team created in Phase -1.
  TaskCreate({
    subject: "Extract Figma design inventory",
    description: "Call figma_list_components MCP tool, extract component inventory",
    activeForm: "Extracting design inventory"
  })

  Agent({
    name: 'design-inventory-agent',
    subagent_type: 'general-purpose',
    team_name: `rune-plan-${timestamp}`,
    prompt: `You are a design inventory specialist.

      ## Assignment
      Figma URL: ${figmaUrl}

      ## Lifecycle
      1. Claim the "Extract Figma design inventory" task via TaskList/TaskUpdate
      2. Call the figma_list_components MCP tool with the Figma URL
      3. Extract component names, node IDs, and hierarchy
      4. Write component inventory to: tmp/plans/${timestamp}/design-inventory.json
         Format: { "components": [{ "name": "...", "node_id": "...", "type": "..." }] }
      5. If figma_list_components fails (MCP unavailable), write:
         { "components": [], "error": "Figma MCP not available", "figma_url": "${figmaUrl}" }
      6. Do not write implementation code. Inventory only.
      7. Mark task complete via TaskUpdate`,
    run_in_background: true
  })
  // Output is read during Phase 2 (Synthesize) to populate Component Inventory table
}
```

See [brainstorm-phase.md](references/brainstorm-phase.md) for the full protocol — all steps, elicitation sage spawning, decision capture templates, design asset detection (Step 3.2), and ATE-1 compliance notes.

Read and execute when Phase 0 runs.

## Phase 1: Research (Conditional, up to 8 agents)

Spawns local research agents (repo-surveyor, echo-reader, git-miner), evaluates risk/sufficiency scores to decide on external research (practice-seeker, lore-scholar, codex-researcher), optionally verifies external research outputs for trustworthiness (research-verifier, Phase 1C.5), then runs spec validation (flow-seer). Includes research consolidation validation checkpoint. Phase 1B reads `talisman.plan` config for `external_research` bypass modes (`always`/`auto`/`never`) and `research_urls` with SSRF-defensive URL sanitization. External research agents use Context7 MCP for framework documentation alongside WebSearch. Phase 1C.5 scores findings across 5 dimensions (relevance, accuracy, freshness, cross-validation, security) and maps verdicts (TRUSTED/CAUTION/UNTRUSTED/FLAGGED) — skipped with `--quick`, `--no-verify-research`, or when no external research ran.

**Inputs**: `feature` (sanitized string, from Phase 0), `timestamp` (validated identifier), talisman config (plan section for research control)
**Outputs**: Research agent outputs in `tmp/plans/{timestamp}/research/`, `inscription.json`
**Error handling**: TeamDelete fallback on cleanup, identifier validation before rm-rf, agent timeout (5 min) proceeds with partial findings

See [research-phase.md](references/research-phase.md) for the full protocol.

## Phase 1.8: Solution Arena

Generates competing solutions from research, evaluates on weighted dimensions, challenges with adversarial agents, and presents a decision matrix for approach selection.

**Skip conditions**: `--quick`, `--no-arena`, bug fixes, high-confidence refactors (confidence >= 0.9), sparse research (<2 viable approaches).

See [solution-arena.md](references/solution-arena.md) for full protocol (sub-steps 1.8A through 1.8D).

**Inputs**: Research outputs from `tmp/plans/{timestamp}/research/`, brainstorm-decisions.md (optional)
**Outputs**: `tmp/plans/{timestamp}/arena/arena-selection.md` (winning solution with rationale)
**Error handling**: Complexity gate skip → log reason. Sparse research → skip Arena. Agent timeout → proceed with partial. All solutions killed → recovery protocol.

## Phase 2: Synthesize

Tarnished consolidates research findings into a plan document. User selects detail level (Minimal/Standard/Comprehensive). Includes plan templates, formatting best practices, and the Plan Section Convention (contracts before pseudocode).

**Inputs**: Research outputs from `tmp/plans/{timestamp}/research/`, user detail level selection, `designAware` (boolean from Phase 0), `figmaUrl` (string or null)
**Outputs**: `plans/YYYY-MM-DD-{type}-{feature-name}-plan.md`
**Error handling**: Missing research files -> proceed with available data
**Comprehensive only**: Re-runs flow-seer on the drafted plan for a second SpecFlow pass
**Design-aware**: When `design_sync_candidate === true`, adds `figma_url` and `design_sync: true` to frontmatter, and emits a "Design Implementation" section in the plan body (with component inventory from design-inventory-agent if available)

See [synthesize.md](references/synthesize.md) for the full protocol.

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

```javascript
// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// 1. Dynamic member discovery — reads team config to find ALL teammates
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/rune-plan-${timestamp}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: known teammates across all devise phases (some are conditional — safe to send shutdown to absent members)
  allMembers = ["scroll-reviewer", "decree-arbiter", "knowledge-keeper", "veil-piercer-plan",
    "horizon-sage", "evidence-verifier", "research-verifier", "doubt-seer", "codex-plan-reviewer",
    "elicitation-sage-1", "elicitation-sage-2", "elicitation-sage-3", "design-inventory-agent"]
}

// Shutdown all discovered members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Planning workflow complete" })
}

// 2. Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash(`sleep 15`)
}

// 2.5. Mark state file as completed (deactivates ATE-1 enforcement for this workflow)
try {
  const stateFile = `tmp/.rune-plan-${timestamp}.json`
  const state = JSON.parse(Read(stateFile))
  Write(stateFile, { ...state, status: "completed" })
} catch (e) { /* non-blocking — state file may already be cleaned */ }

// 3. Cleanup team — QUAL-004: retry-with-backoff
// CRITICAL: Validate timestamp (/^[a-zA-Z0-9_-]+$/) before rm -rf — path traversal guard
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid plan identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected')
const CLEANUP_DELAYS = [0, 5000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`plan cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-plan-${timestamp}/" "$CHOME/tasks/rune-plan-${timestamp}/" 2>/dev/null`)

// 3.5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "devise"`)

// 4. Present plan to user
Read("plans/YYYY-MM-DD-{type}-{feature-name}-plan.md")
```

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
