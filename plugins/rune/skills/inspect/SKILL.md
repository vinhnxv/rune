---
name: inspect
description: |
  Plan-vs-implementation deep audit using Agent Teams. Parses a plan file (or inline description),
  extracts requirements, and summons 4 Inspector Ashes to measure implementation completeness,
  quality across 10 dimensions, and gaps across 9 categories. Produces a VERDICT.md with
  requirement matrix, dimension scores, gap analysis, and actionable recommendations.

  <example>
  user: "/rune:inspect plans/feat-user-auth-plan.md"
  assistant: "The Tarnished gazes upon the land, measuring what has been forged against what was decreed..."
  </example>

  <example>
  user: "/rune:inspect Add user authentication with JWT tokens and rate limiting"
  assistant: "The Tarnished inspects the codebase against the inline plan..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[plan-file.md | inline description] [--mode plan|implementation] [--focus <dimension>] [--dry-run] [--fix]"
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
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# /rune:inspect — Plan-vs-Implementation Deep Audit

Orchestrate a multi-agent inspection that measures implementation completeness and quality against a plan. Each Inspector Ash gets its own dedicated context window via Agent Teams.

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `team-sdk`, `polling-guard`, `zsh-compat`, `goldmask`, `codex-cli`

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--focus <dimension>` | Focus on a specific dimension: correctness, completeness, security, failure-modes, performance, design, observability, tests, maintainability, design-fidelity | All dimensions |
| `--max-agents <N>` | Limit total Inspector Ashes (1-4) | 4 |
| `--dry-run` | Show scope, requirements, and inspector assignments without summoning agents | Off |
| `--threshold <N>` | Override completion threshold for READY verdict (0-100) | 80 |
| `--fix` | After VERDICT, spawn gap-fixer to auto-fix FIXABLE findings | Off |
| `--max-fixes <N>` | Cap on fixable gaps per run | 20 |
| `--mode <mode>` | Inspection mode: `implementation` (default) or `plan` | implementation |
| `--no-lore` | Disable Phase 1.3 Lore Layer (git history risk scoring) | Off |

**Dry-run mode** executes Phase 0 + Phase 0.5 + Phase 1 only. Displays: extracted requirements with IDs and priorities, inspector assignments, relevant codebase files, estimated team size. No teams, tasks, state files, or agents are created.

## 4 Inspector Ashes

| Inspector | Dimensions | Priority |
|-----------|-----------|----------|
| `grace-warden` | Correctness, Completeness | 1st |
| `ruin-prophet` | Security, Failure Modes | 2nd |
| `sight-oracle` | Performance, Design | 3rd |
| `vigil-keeper` | Observability, Tests, Maintainability | 4th |

For full prompt templates, focus mode, --max-agents redistribution, and --fix gap-fixer protocol — see [inspector-prompts.md](references/inspector-prompts.md).

## Phase 0: Pre-flight

Parses input (file path or inline description), validates with SEC-003 path guard, reads talisman config with runtime clamping (RUIN-001), and generates a base-36 identifier.

See [phase-0-preflight.md](references/phase-0-preflight.md) for the full pseudocode (Steps 0.1–0.3).

## Phase 0.5: Classification

Extracts requirements from plan using [plan-parser.md](../roundtable-circle/references/plan-parser.md) algorithm, assigns to inspectors via keyword classification, applies `--focus` and `--max-agents` redistribution.

See [phase-0-preflight.md](references/phase-0-preflight.md) for Steps 0.5.1–0.5.4. See [inspector-prompts.md](references/inspector-prompts.md) for assignment logic.

## Phase 1: Scope

Identifies relevant codebase files by type (file → Glob, code → Grep, config → Grep with glob filter), deduplicates, caps at 120 files. In `--dry-run`, displays scope + assignments and stops.

See [phase-1-scope.md](references/phase-1-scope.md) for the full scope resolution code and dry-run output.

## Phase 1.3: Lore Layer (Risk Intelligence)

Runs AFTER scope (Phase 1), BEFORE team creation (Phase 2). Discovers existing risk-map or spawns `lore-analyst`. Re-sorts `scopeFiles` by risk tier and enriches requirement classification.

See [phase-1-scope.md](references/phase-1-scope.md) for skip conditions, discovery steps, and the dual-inspector gate. See [lore-layer-integration.md](../goldmask/references/lore-layer-integration.md) for the shared protocol and [risk-tier-sorting.md](../goldmask/references/risk-tier-sorting.md) for sorting.

## Phase 1.5: Codex Drift Detection (v1.51.0)

Cross-model comparison of plan intent vs code semantics before inspector team creation. Flags semantic drift where code implements something different from what the plan specified. Default OFF (greenfield). Non-blocking — drift report is additional context, not a gate.

**Output**: `tmp/inspect/{identifier}/drift-report.md`

See [codex-drift-detection.md](references/codex-drift-detection.md) for the full protocol — detection infrastructure, prompt generation, and drift report injection into Phase 3 inspector prompts.

### MCP-First Inspector Discovery (v1.170.0+)

Inspector agents can be discovered via MCP search, enabling user-defined inspectors:

```pseudocode
# Phase 2: Inspector Selection
inspectors = []

if mcp_available:
  # Discover phase-appropriate inspectors
  candidates = agent_search({
    query: "inspect plan requirements completeness correctness",
    phase: "inspect",
    limit: 8
  })
  inspectors = candidates.filter(c => c.categories.includes("inspection") or c.categories.includes("investigation"))

  # Write signal
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")

if not inspectors or len(inspectors) < 4:
  # Fallback: use hardcoded inspector list
  inspectors = [
    { name: "grace-warden-inspect", mode: "inspect" },
    { name: "ruin-prophet-inspect", mode: "inspect" },
    { name: "sight-oracle-inspect", mode: "inspect" },
    { name: "vigil-keeper-inspect", mode: "inspect" }
  ]

# For plan-review mode, swap "-inspect" variants with "-plan-review":
if mode == "plan-review":
  inspectors = inspectors.map(i => {
    name: i.name.replace("-inspect", "-plan-review"),
    mode: "plan-review"
  })
```

This allows users to register custom inspectors (e.g., "compliance-inspector" for regulatory projects)
that participate alongside the 4 built-in inspectors.

## Phase 2: Forge Team

Writes state file (with session isolation: `config_dir`, `owner_pid`, `session_id`), creates output directory + inscription.json, acquires workflow lock (reader), runs pre-create guard (teamTransition), TeamCreate + signal directory, creates tasks per inspector + aggregator.

See [phase-2-forge-team.md](references/phase-2-forge-team.md) for the full pseudocode (Steps 2.1–2.6).

## Phase 3: Summon Inspectors

Read and execute [inspector-prompts.md](references/inspector-prompts.md) for the full prompt generation contract, mode-aware template selection, inline plan sanitization, and --focus single-inspector logic.

**Key rules:**
- Summon all inspectors in a **single message** (parallel, `run_in_background: true`)
- All inspectors get full `scopeFiles` — they filter by relevance internally
- `model: resolveModelForAgent(inspector, talisman)` for each inspector (cost tier mapping)
- Template path: `agents/investigation/{inspector}-inspect.md` (or `{inspector}-plan-review.md` for `--mode plan`)

### Step 3.1 — Risk Context Injection (Goldmask Enhancement)

If `riskMap` is available from Phase 1.3, inject risk context (file tiers, wisdom advisories, inspector-specific guidance) into each inspector's prompt. Only inject when non-empty. See [risk-context-injection.md](references/risk-context-injection.md) for the full injection protocol and [risk-context-template.md](../goldmask/references/risk-context-template.md) for rendering rules.

## Phase 4: Monitor

Poll TaskList every 30s with stale detection (3 consecutive no-progress → break with warning). See [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) for the shared polling utility.

## Phase 5 + Phase 6: Verdict

Read and execute [verdict-synthesis.md](references/verdict-synthesis.md) for the full Verdict Binder aggregation, score aggregation, evidence verification, gap classification, and VERDICT.md structure.

**Summary:**
1. **Phase 5.2 (Verdict Binder)**: Aggregates inspector outputs. Produces VERDICT.md with requirement matrix, 10 dimension scores, gap analysis (9 categories), recommendations.
2. **Phase 5.3 (Wait)**: TaskList polling, 2-min timeout, 10s interval.
3. **Phase 6.1 (Evidence check)**: Verify up to 10 file references in VERDICT.md against disk.
4. **Phase 6.2 (Display)**: Show verdict summary (verdict, completion %, finding counts, report path).

### Phase 5-6 Enhancement: Historical Risk Assessment in VERDICT.md

If `riskMap` is available from Phase 1.3, the Verdict Binder appends a Historical Risk Assessment section (file risk distribution, bus factor warnings, inspection coverage vs risk) to VERDICT.md. Optional — omitted on null/parse error. See [verdict-synthesis.md](references/verdict-synthesis.md) "Historical Risk Assessment" section.

## 10 Dimensions + 9 Gap Categories

### 10 Dimensions

| Dimension | Inspector | Description |
|-----------|-----------|-------------|
| Correctness | grace-warden | Logic implements requirements correctly |
| Completeness | grace-warden | All requirements implemented, no gaps |
| Security | ruin-prophet | Vulnerabilities, auth, input validation |
| Failure Modes | ruin-prophet | Error handling, retries, circuit breakers |
| Performance | sight-oracle | Bottlenecks, N+1 queries, memory leaks |
| Design | sight-oracle | Architecture, coupling, SOLID principles |
| Observability | vigil-keeper | Logging, metrics, tracing |
| Tests | vigil-keeper | Unit/integration coverage, test quality |
| Maintainability | vigil-keeper | Documentation, naming, complexity |
| Design Fidelity | grace-warden | Design spec compliance — COMPLETE/PARTIAL/MISSING/DEVIATED (conditional: design_sync.enabled + design refs) |

### 9 Gap Categories

| Category | Description |
|----------|-------------|
| MISSING | Requirement not implemented at all |
| INCOMPLETE | Partially implemented — edge cases missing |
| INCORRECT | Implemented but wrong — logic error |
| INSECURE | Security vulnerability or missing control |
| FRAGILE | Works but likely to break — missing error handling |
| UNOBSERVABLE | No logging/metrics/tracing |
| UNTESTED | No tests or insufficient coverage |
| UNMAINTAINABLE | Hard to change — excessive coupling, magic values |
| UNWIRED | Integration point not connected — file not modified, pattern not registered (WIRE- prefix, NOT auto-fixable) |

## Phase 7: Cleanup

See [verdict-synthesis.md](references/verdict-synthesis.md) for full cleanup protocol.

**Summary:**
1. Shutdown all inspectors + verdict-binder (`SendMessage shutdown_request`)
2. `TeamDelete` with filesystem fallback (CHOME pattern)
3. Update state file to "completed" (preserve `config_dir`, `owner_pid`, `session_id`, verdict, completion)
4. Release workflow lock: `Bash(\`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "inspect"\`)`
5. Persist echo if P1 findings exist
6. If `--fix`: run Phase 7.5 remediation (gap-fixer team, 2-min timeout, append results to VERDICT.md)
7. Post-inspection: `AskUserQuestion` with options (View VERDICT, Fix gaps /rune:strive, /rune:appraise, Done)

## Error Handling

| Error | Recovery |
|-------|----------|
| Plan file not found | Error with file path suggestion |
| No requirements extracted | Error with plan format guidance |
| Inspector timeout | Proceed with available outputs |
| All inspectors failed | Error — no VERDICT possible |
| TeamCreate fails | Retry with pre-create guard |
| TeamDelete fails | Filesystem fallback (CHOME pattern) |
| VERDICT.md not created | Manual aggregation from inspector outputs |
| Lore-analyst timeout (Phase 1.3) | Proceed without risk data (WARN) |
| risk-map.json parse error (Phase 1.3) | Proceed without risk data (WARN) |
| Wisdom passthrough unavailable (Phase 3) | Skip wisdom injection (INFO) |
| Risk section render error (Phase 5-6) | Omit Historical Risk section from VERDICT (WARN) |

## Security

- Plan path validated with `/^[a-zA-Z0-9._\/-]+$/` before shell interpolation
- Team name validated with `/^[a-zA-Z0-9_-]+$/` before rm -rf
- Inspector outputs treated as untrusted (Truthbinding protocol)
- CHOME pattern used for all filesystem operations
- Inline plan sanitized before prompt injection (SEC-002, SEC-004)
- Inspector Ashes are read-only — they cannot modify the codebase
