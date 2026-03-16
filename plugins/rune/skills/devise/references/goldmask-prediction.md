# Phase 2.3: Predictive Goldmask

After the plan is synthesized but before shatter assessment, runs a predictive Goldmask analysis to identify which existing files are likely to be affected, surface Wisdom advisories (caution zones) for risky areas, trace dependency chains (Impact Layer), and inform the shatter decision with risk data.

**Inputs**: `talisman` (config object), `timestamp` (validated identifier), `planPath` (string), `args` (CLI arguments)
**Outputs**: `tmp/plans/{timestamp}/goldmask-prediction/risk-map.json`, `tmp/plans/{timestamp}/goldmask-prediction/wisdom-report.md`, `tmp/plans/{timestamp}/goldmask-prediction/GOLDMASK-PREDICTION.md`
**Preconditions**: Phase 1 research completed, plan team (`rune-plan-{timestamp}`) already exists

**Note**: Phase 2.3 runs AFTER Phase 1, which creates the plan team (`rune-plan-{timestamp}`). All Agent calls MUST use `team_name` (ATE-1 compliance — unlike Phase 0 sages which run before team creation).

**Timeout inheritance**: Arc timeouts (from `talisman.arc.timeouts`) are NOT automatically propagated to Phase 2.3 devise agents. Phase 2.3 uses its own internal ceiling (`PHASE_23_TOTAL_CEILING_MS = 360_000`). If arc timeout is tighter than 6 min, Phase 2.3 agents may outlive the arc phase budget — ensure arc `forge` timeout accounts for Phase 2.3's contribution.

**Non-blocking**: If any agent fails, the pipeline continues with partial data. All failures are recoverable.

## Depth Modes

| Mode | Agents | Time | When to use |
|------|--------|------|-------------|
| `basic` (default) | 2 (lore + wisdom) | 50-170s | Standard planning — opt-in to enhanced for richer analysis |
| `enhanced` | 6 (lore + 3 tracers + wisdom + coordinator) | 2.5-5.5 min | Explicit opt-in: `goldmask.devise.depth: enhanced`. Budget ceiling: 6 min |
| `full` | 8 (lore + 5 tracers + wisdom + coordinator) | 3-6 min | Major architectural changes — explicit opt-in only |

**Talisman config**: `goldmask.devise.depth` — `basic` (default) | `enhanced` | `full`

## Step 0: Extract Predicted Files

Derive predicted affected files from Phase 1 research outputs (structured artifact),
NOT from regex parsing of free-form plan prose.

```javascript
const goldmaskEnabled: boolean = talisman?.goldmask?.enabled !== false
const goldmaskDeviseEnabled: boolean = talisman?.goldmask?.devise?.enabled !== false
const isGitRepo: boolean = Bash("git rev-parse --is-inside-work-tree 2>/dev/null").trim() === "true"
const isQuick: boolean = args.includes("--quick")

if (!goldmaskEnabled || !goldmaskDeviseEnabled || !isGitRepo || isQuick) {
  const skipReason: string = !goldmaskEnabled ? "goldmask.enabled=false"
    : !goldmaskDeviseEnabled ? "goldmask.devise.enabled=false"
    : !isGitRepo ? "not a git repo" : "--quick flag"
  warn(`Phase 2.3: Predictive Goldmask skipped — ${skipReason}`)
  // Continue to Phase 2.5
} else {
  const deviseDepth: string = talisman?.goldmask?.devise?.depth ?? "basic"
  // Validate depth value — fallback to basic for unrecognized values
  const validDepths: string[] = ["basic", "enhanced", "full"]
  const effectiveDepth: string = validDepths.includes(deviseDepth) ? deviseDepth : "basic"
  if (deviseDepth !== effectiveDepth) {
    warn(`Phase 2.3: Unrecognized depth "${deviseDepth}" — defaulting to "basic"`)
  }

  // Extract predicted files from Phase 1 research outputs (structured)
  // Prefer repo-surveyor output (contains file inventory), then git-miner (changed files)
  const predictedFiles: string[] = []
  try {
    const surveyorOutput: string = Read(`tmp/plans/${timestamp}/research/repo-analysis.md`)
    // Parse file paths from surveyor's file inventory section
    for (const match of surveyorOutput.matchAll(/`([^`]+\.\w+)`/g)) {
      const fp: string = match[1]
      if (fp && !fp.includes('..') && !predictedFiles.includes(fp)) {
        predictedFiles.push(fp)
      }
    }
  } catch (readError) {
    // Surveyor output unavailable — try git-miner
  }
  if (predictedFiles.length === 0) {
    try {
      const gitMinerOutput: string = Read(`tmp/plans/${timestamp}/research/git-history.md`)
      for (const match of gitMinerOutput.matchAll(/`([^`]+\.\w+)`/g)) {
        const fp: string = match[1]
        if (fp && !fp.includes('..') && !predictedFiles.includes(fp)) {
          predictedFiles.push(fp)
        }
      }
    } catch (readError) {
      // Git-miner output unavailable
    }
  }

  if (predictedFiles.length === 0) {
    warn("Phase 2.3: No predicted files found — falling back to basic mode")
    // Fall through to basic mode below
  }

  const outputDir: string = `tmp/plans/${timestamp}/goldmask-prediction`
  Bash(`mkdir -p "${outputDir}"`)
```

## MCP-First Tracer Discovery (v1.171.0+)

Before spawning tracers, query agent-search MCP for phase-appropriate investigation agents:

```javascript
  // MCP-First investigation agent discovery for Predictive Goldmask
  let goldmaskTracers = []
  try {
    const candidates = agent_search({
      query: "impact analysis risk scoring git history investigation tracing",
      phase: "goldmask",
      category: "investigation",
      limit: 10
    })
    Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")
    goldmaskTracers = candidates?.results || []
  } catch (e) {
    // MCP unavailable — proceed with hardcoded defaults
  }
  // Fallback: if MCP returned nothing, use hardcoded tracer names below
```

## Basic Mode (2 agents)

```javascript
  if (effectiveDepth === "basic" || predictedFiles.length === 0) {
    // Legacy behavior: lore-analyst + wisdom-sage only
    TaskCreate({ subject: "Lore analysis — risk scoring for predicted files" })
    TaskCreate({ subject: "Wisdom analysis — design intent for CRITICAL/HIGH files" })

    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-lore",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:lore-analyst — a Goldmask Lore Layer analyst.

Analyze git history risk metrics for: ${predictedFiles.join(", ")}
Write risk-map.json to: ${outputDir}/risk-map.json

YOUR LIFECYCLE:
1. TaskList() -> claim "Lore analysis" task
2. Analyze git history, compute risk tiers
3. Write output, mark complete
4. Exit`,
      run_in_background: true
    })

    // Wait for lore, then spawn wisdom
    // ... standard polling (30s interval, 120s timeout)

    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-wisdom",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:wisdom-sage — a Goldmask Wisdom Layer analyst.

Read risk-map: ${outputDir}/risk-map.json
Classify design intent for CRITICAL/HIGH risk files.
Write wisdom-report.md to: ${outputDir}/wisdom-report.md

YOUR LIFECYCLE:
1. TaskList() -> claim "Wisdom analysis" task
2. Read risk-map, analyze CRITICAL/HIGH files via git blame
3. Write wisdom report, mark complete
4. Exit`,
      run_in_background: true
    })

    // Wait for wisdom (120s timeout) — non-blocking on failure
```

## Enhanced Mode (6 agents — opt-in)

```javascript
  } else if (effectiveDepth === "enhanced") {
    // Phase 2.3a: 4 agents in parallel (lore + 3 Impact tracers)
    const PHASE_23A_TIMEOUT_MS: number = 90_000  // 90s for parallel phase
    const PHASE_23_TOTAL_CEILING_MS: number = 360_000  // 6 min hard ceiling
    // PER_AGENT_TIMEOUT_MS: lore=120s, each tracer=90s, wisdom=120s, coordinator=120s
    // Total sequential-worst-case: 90s (2.3a) + 120s (wisdom) + 120s (coordinator) = 330s < 360s ceiling
    // BACK-003: Enforce timeout budget before spawning 6 agents
    const phaseStartMs: number = Date.now()
    const perAgentTimeout: number = 120_000  // 2 min per agent (conservative upper bound)
    const estimatedTotalMs: number = PHASE_23A_TIMEOUT_MS + perAgentTimeout + perAgentTimeout  // 2.3a + wisdom + coordinator
    if (estimatedTotalMs > PHASE_23_TOTAL_CEILING_MS) {
      warn(`Phase 2.3: Enhanced mode estimated time (${Math.round(estimatedTotalMs / 1000)}s) exceeds hard ceiling (${Math.round(PHASE_23_TOTAL_CEILING_MS / 1000)}s) — falling back to basic mode`)
      // Explicit fallback: run basic mode agents (lore + wisdom) instead of doing nothing
      TaskCreate({ subject: "Lore analysis — risk scoring for predicted files" })
      TaskCreate({ subject: "Wisdom analysis — design intent for CRITICAL/HIGH files" })
      // ... spawn basic-mode lore-analyst and wisdom-sage (same as basic mode above)
    } else {

    TaskCreate({ subject: "Lore analysis — risk scoring for predicted files" })
    TaskCreate({ subject: "Business logic tracing — domain rule dependencies" })
    TaskCreate({ subject: "Data layer tracing — schema/ORM/migration cascade" })
    TaskCreate({ subject: "API contract tracing — endpoint/validator/doc impact" })

    // Spawn 4 agents in parallel
    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-lore",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:lore-analyst — a Goldmask Lore Layer analyst.

Analyze git history risk metrics for: ${predictedFiles.join(", ")}
Lookback: ${talisman?.goldmask?.layers?.lore?.lookback_days ?? 180} days
Write risk-map.json to: ${outputDir}/risk-map.json

YOUR LIFECYCLE:
1. TaskList() -> claim "Lore analysis" task
2. Analyze git history, compute risk tiers (CRITICAL/HIGH/MEDIUM/LOW/STALE)
3. Write output, mark complete, exit`,
      run_in_background: true
    })

    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-business",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:business-logic-tracer — a Goldmask Impact Layer tracer.

Trace business logic dependencies for: ${predictedFiles.join(", ")}
Identify domain rules, validation logic, and business constraints that depend on these files.
Write to: ${outputDir}/business-logic.md

YOUR LIFECYCLE:
1. TaskList() -> claim "Business logic tracing" task
2. Trace dependencies via Grep/Read, document domain rule chains
3. Write output, mark complete, exit`,
      run_in_background: true
    })

    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-data",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:data-layer-tracer — a Goldmask Impact Layer tracer.

Trace data layer dependencies for: ${predictedFiles.join(", ")}
Identify schema definitions, ORM models, serializers, migrations that cascade from changes.
Write to: ${outputDir}/data-layer.md

YOUR LIFECYCLE:
1. TaskList() -> claim "Data layer tracing" task
2. Trace data flow via Grep/Read, document cascade paths
3. Write output, mark complete, exit`,
      run_in_background: true
    })

    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-api",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:api-contract-tracer — a Goldmask Impact Layer tracer.

Trace API contract dependencies for: ${predictedFiles.join(", ")}
Identify endpoints, request/response schemas, validators, and documentation that would need updates.
Write to: ${outputDir}/api-contract.md

YOUR LIFECYCLE:
1. TaskList() -> claim "API contract tracing" task
2. Trace API surface via Grep/Read, document contract dependencies
3. Write output, mark complete, exit`,
      run_in_background: true
    })

    // Wait for Phase 2.3a agents (partial-ready gate: 3/4 complete within 90s starts wisdom early)
    // Standard polling: 30s interval, 90s timeout
    const phase23aStart: number = Date.now()
    let completedCount: number = 0
    while (Date.now() - phase23aStart < PHASE_23A_TIMEOUT_MS) {
      Bash("sleep 30")
      const tasks = TaskList()
      completedCount = countCompleted(tasks, ["Lore analysis", "Business logic", "Data layer", "API contract"])
      if (completedCount >= 4) break
      if (completedCount >= 3) {
        warn(`Phase 2.3a: ${completedCount}/4 complete — starting Wisdom Sage early (partial-ready gate)`)
        break
      }
    }
    if (completedCount < 3) {
      warn(`Phase 2.3a: Only ${completedCount}/4 agents completed within 90s — proceeding with partial data`)
    }

    // Phase 2.3b: Wisdom Sage (sequential — needs Impact outputs for context)
    TaskCreate({ subject: "Wisdom analysis — intent classification for CRITICAL/HIGH files" })
    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-wisdom",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:wisdom-sage — a Goldmask Wisdom Layer analyst.

Classify developer intent for CRITICAL/HIGH risk files.
Read these inputs (skip any that are missing — partial data is acceptable):
- Risk map: ${outputDir}/risk-map.json
- Business logic report: ${outputDir}/business-logic.md
- Data layer report: ${outputDir}/data-layer.md
- API contract report: ${outputDir}/api-contract.md

Write wisdom-report.md to: ${outputDir}/wisdom-report.md

YOUR LIFECYCLE:
1. TaskList() -> claim "Wisdom analysis" task
2. Read available inputs, classify intent for CRITICAL/HIGH files
3. Write wisdom report with caution scores, mark complete, exit`,
      run_in_background: true
    })

    // Wait for Wisdom Sage (120s timeout)
    // ... standard polling (30s interval)

    // Phase 2.3c: Coordinator synthesis (sequential — needs all layer outputs)
    TaskCreate({ subject: "Coordinator synthesis — merge all layers into plan risk section" })
    Agent({
      team_name: `rune-plan-${timestamp}`,
      name: "devise-coordinator",
      subagent_type: "general-purpose",
      prompt: `You are rune:investigation:goldmask-coordinator — Goldmask synthesis coordinator.

Synthesize predictive Goldmask analysis for planning. Read all available outputs from ${outputDir}/.

Produce GOLDMASK-PREDICTION.md with these sections:
1. "## Risk & Dependency Analysis (Goldmask Prediction)" — summary table
2. "### Predicted File Impact" — table with File, Risk Tier, Impact Type, Must Change?, Dependencies
3. "### Caution Zones" — wisdom advisories for CRITICAL/HIGH files
4. "### Collateral Damage Predictions" — what could break, cascade effects
5. "### MUST-CHANGE Files" — files the plan must address
6. "### SHOULD-CHECK Files" — files that may need changes

Write to: ${outputDir}/GOLDMASK-PREDICTION.md

YOUR LIFECYCLE:
1. TaskList() -> claim "Coordinator synthesis" task
2. Read all available layer outputs (skip missing — partial synthesis is OK)
3. Write GOLDMASK-PREDICTION.md, mark complete, exit`,
      run_in_background: true
    })

    // Wait for coordinator (120s timeout) — non-blocking on failure
    } // end enhanced-mode budget check
```

## Full Mode (8 agents)

```javascript
  } else if (effectiveDepth === "full") {
    // Full Goldmask: inline all 8 agents into existing plan team
    // NOTE: Cannot use Skill("rune:goldmask") here because it calls TeamCreate
    // internally, violating one-team-per-lead constraint. Instead, inline the
    // same agents directly into the rune-plan-{timestamp} team.
    warn("Phase 2.3: Full mode — inlining 8 Goldmask agents into plan team (3-5 min)")

    // Same as enhanced, but adds event-message-tracer and config-dependency-tracer
    // ... (lore + 5 tracers + wisdom + coordinator)
    // Implementation follows same pattern as enhanced with 2 additional tracers:
    //   devise-event (event-message-tracer) and devise-config (config-dependency-tracer)
    // Phase 2.3a spawns 6 agents (lore + 5 tracers) in parallel
    // Phase 2.3b and 2.3c remain identical to enhanced mode
  }
```

## Plan Injection

After coordinator completes, inject the prediction into the plan document:

```javascript
  // Read coordinator output
  try {
    const prediction: string = Read(`${outputDir}/GOLDMASK-PREDICTION.md`)
    // BACK-005: Validate all required sections are present before injecting
    const REQUIRED_SECTIONS: string[] = [
      "## Risk & Dependency Analysis (Goldmask Prediction)",
      "### Predicted File Impact",
      "### Caution Zones",
      "### Collateral Damage Predictions",
      "### MUST-CHANGE Files",
      "### SHOULD-CHECK Files"
    ]
    const missingSections: string[] = REQUIRED_SECTIONS.filter(s => !prediction.includes(s))
    if (missingSections.length > 0) {
      warn(`Phase 2.3: Coordinator output missing sections: ${missingSections.join(", ")} — skipping plan injection`)
    } else if (prediction && prediction.trim().length > 0) {
      // Insert after "## Non-Goals" section in the plan (before implementation phases)
      Edit(planPath, {
        old_string: "## Non-Goals",  // Find the Non-Goals heading
        new_string: `## Non-Goals`   // Keep it, insert prediction AFTER it via separate Edit
      })
      // Append prediction as new section after Non-Goals
      // Use section-end detection to find the right insertion point
      const planContent: string = Read(planPath)
      const nonGoalsEnd: number = findSectionEnd(planContent, "## Non-Goals")
      if (nonGoalsEnd > 0) {
        const insertionPoint: string = planContent.substring(nonGoalsEnd - 50, nonGoalsEnd)
        Edit(planPath, {
          old_string: insertionPoint,
          new_string: insertionPoint + "\n\n" + prediction
        })
        log("Phase 2.3: GOLDMASK-PREDICTION.md injected into plan")
      }
    }
  } catch (readError) {
    warn("Phase 2.3: Coordinator output missing — proceeding without prediction injection")
  }
} // end goldmask enabled check
```

## Phase Sequencing (Enhanced Mode)

```
Phase 2.3a (parallel, ~25-50s):
    +-- lore-analyst -> risk-map.json
    +-- business-logic-tracer -> business-logic.md
    +-- data-layer-tracer -> data-layer.md
    +-- api-contract-tracer -> api-contract.md

Phase 2.3b (sequential, ~60-120s):
    +-- wisdom-sage -> wisdom-report.md
        (reads impact reports + risk-map for context)

Phase 2.3c (sequential, ~60-90s):
    +-- goldmask-coordinator -> GOLDMASK-PREDICTION.md
        (synthesizes all layers into plan section)

Total: 2.5-4.5 min | Hard ceiling: 5 min
```

## Error Handling — Phase 2.3

| Phase | Error | Recovery | Severity |
|-------|-------|----------|----------|
| 2.3 | `extractPredictedFiles` returns 0 files | Fallback to basic mode | WARN |
| 2.3a | 1 of 3 Impact tracers fails | Proceed with partial — 2 of 3 reports | WARN |
| 2.3a | All 3 Impact tracers fail | Proceed Lore-only, coordinator gets minimal input | ERROR |
| 2.3a | All 4 parallel agents fail | Abort enhanced mode, skip to Phase 2.5 | ERROR |
| 2.3b | Wisdom Sage fails | Coordinator gets impact+lore without intent context | WARN |
| 2.3b | Wisdom Sage timeout (120s) | Same as failure — proceed without wisdom | WARN |
| 2.3c | Coordinator timeout (120s) | Skip plan injection, all upstream work wasted | ERROR |
| 2.3c | Malformed GOLDMASK-PREDICTION.md | Skip plan injection, warn user | ERROR |
| 2.3 | Unrecognized `depth` value | Treat as "basic", log warning | WARN |
| 2.3 | Team spawn failure | Fallback to basic mode | ERROR |

### Phase 0.8 Feedback Loop (v1.165.0)

After Predictive Goldmask (Phase 2.3) completes, compare findings with Phase 0.8 issue inventory:

1. **Cross-reference**: Match Goldmask risk findings against Phase 0.8 discovered issues
2. **New risks**: Issues found by Goldmask but missed by Phase 0.8 → append to plan's "Existing Issues" section
3. **Validated risks**: Issues found by both → increase priority (confirmed by two independent analyses)
4. **Plan update**: If new risks are critical, update the plan's task list before proceeding to Phase 3

This creates a feedback loop: pre-plan audit → plan → post-plan verification → plan update.
