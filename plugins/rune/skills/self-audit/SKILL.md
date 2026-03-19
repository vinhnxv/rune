---
name: self-audit
description: |
  Use /rune:self-audit to audit the Rune plugin system itself — validating skill
  wiring, agent definitions, hook configurations, and (in runtime mode) analyzing
  arc run artifacts for hallucinations, effectiveness, and convergence patterns.

  Modes:
  - static (default): audits skill definitions, agent wiring, hook setup
  - runtime: analyzes a completed arc run's artifacts post-hoc
  - all: runs both static and runtime analyses

  Trigger keywords: self-audit, audit rune, audit the system, plugin health,
  skill wiring, agent wiring, hook audit, runtime audit, arc artifact analysis,
  hallucination detection, agent effectiveness, convergence analysis.

  <example>
  user: "/rune:self-audit"
  assistant: "Running static audit... Checking 52 skills, 112 agents, 38 hooks. Found 2 wiring issues."
  </example>

  <example>
  user: "/rune:self-audit --mode runtime"
  assistant: "Auto-detecting latest completed arc... Found arc-1773959688. Spawning 3 runtime agents."
  </example>

  <example>
  user: "/rune:self-audit --mode runtime --arc-id arc-1773959688"
  assistant: "Analyzing arc-1773959688 artifacts... Spawning hallucination-detector, effectiveness-analyzer, convergence-analyzer."
  </example>

  <example>
  user: "/rune:self-audit --mode all"
  assistant: "Running static + runtime audit combined..."
  </example>

  <example>
  user: "/rune:self-audit --history"
  assistant: "Showing past audit results with trends..."
  </example>
user-invocable: true
argument-hint: "[--mode static|runtime|all] [--arc-id ID] [--history]"
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - Grep
  - Agent
  - TaskCreate
  - TaskList
  - TaskGet
  - TaskUpdate
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
---

# /rune:self-audit — Plugin Self-Audit

Audit the Rune plugin system itself. Two modes: **static** (wiring validation) and **runtime** (arc artifact analysis).

## Invocation

```
/rune:self-audit                              # Static only (default)
/rune:self-audit --mode static                # Explicit static mode
/rune:self-audit --mode runtime               # Runtime only (new)
/rune:self-audit --mode runtime --arc-id ID   # Specific arc run
/rune:self-audit --mode all                   # Static + Runtime combined
/rune:self-audit --history                    # Show past audit results with trends
```

| Flag | Default | Description |
|------|---------|-------------|
| `--mode MODE` | static | `static`, `runtime`, or `all` |
| `--arc-id ID` | auto-detect | Specific arc run ID to analyze |
| `--history` | false | Show past self-audit results with trends |

## Phase 0: Parse Arguments

Read `$ARGUMENTS` and extract:
- `MODE` — `static` (default), `runtime`, or `all`
- `ARC_ID` — explicit arc ID, or `null` for auto-detect
- `HISTORY` — true if `--history` flag present

If `--history` flag:
1. Read all past audit reports from `tmp/self-audit/` subdirs
2. Display trend table (phase durations, retry counts, hallucination flags)
3. Exit (skip remaining phases)

```
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
AUDIT_DIR="tmp/self-audit/${TIMESTAMP}"
mkdir -p "${AUDIT_DIR}"
```

## Phase 1: Static Audit (skip when --mode runtime)

Scan the Rune plugin for wiring issues:

### 1a. Skill Inventory

```bash
PLUGIN_ROOT=$(git rev-parse --show-toplevel)/plugins/rune
SKILL_COUNT=$(find "${PLUGIN_ROOT}/skills" -name "SKILL.md" | wc -l)
```

For each `skills/*/SKILL.md`:
- Verify `name:` field present
- Verify `description:` field present
- Check reference links (`references/` subdirs)
- Flag bare `Skill("arc")` calls missing `rune:` prefix

### 1b. Agent Inventory

For each `agents/**/*.md`:
- Verify `name:` and `description:` present
- Check `maxTurns:` present (safety net)
- Verify spawn sites exist in skills (SDMT-001)
- Check YAML list format for `tools:` (not comma-separated)

### 1c. Hook Inventory

Read `hooks/hooks.json`:
- Verify all referenced scripts exist at path
- Check scripts are executable (`chmod +x` equivalent)
- Flag hooks referencing non-existent agents or skills

### 1d. Namespace Validation

```bash
# Check for bare Skill() calls missing rune: prefix
grep -rn "Skill(['\"]" "${PLUGIN_ROOT}/skills/" --include="*.md" | \
  grep -v "rune:" | grep -v CHANGELOG | grep -v "description:"
```

Flag any violations.

### 1e. Report Static Findings

Output a summary:
```
/rune:self-audit — Static Audit
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Skills:  N checked, N issues
Agents:  N checked, N issues
Hooks:   N checked, N issues
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Write findings to `${AUDIT_DIR}/static-findings.md`.

## Phase 2: Runtime Audit (skip when --mode static)

See [runtime-mode.md](references/runtime-mode.md) for full details.

### R0: Locate Arc Artifacts

If `--arc-id` was specified:
```javascript
// Direct lookup
const arcId = ARC_ID  // from --arc-id flag
const checkpointPath = `.rune/arc/${arcId}/checkpoint.json`
const artifactDir = `tmp/arc/${arcId}`
// Read checkpoint — fail if missing
const checkpoint = JSON.parse(Read(checkpointPath))
```

If no `--arc-id` specified (auto-detect):
```javascript
// Scan .rune/arc/ for latest completed checkpoint
// NOTE: Checkpoints live at .rune/arc/{id}/checkpoint.json (NOT tmp/arc/)
// Phase artifacts (TOME, QA verdicts, phase-log.jsonl) live at tmp/arc/{id}/
const arcDirs = Glob(".rune/arc/arc-*")
if (arcDirs.length === 0) {
  output("No arc runs found in .rune/arc/. Run /rune:arc first.")
  exit
}
let located = null
for (const dir of arcDirs.reverse()) {  // newest first (timestamp-based IDs)
  try {
    const checkpoint = JSON.parse(Read(`${dir}/checkpoint.json`))
    if (checkpoint.phases?.merge?.status === "completed" ||
        checkpoint.phases?.ship?.status === "completed") {
      const arcId = dir.split("/").pop()
      located = { id: arcId, checkpointPath: `${dir}/checkpoint.json`,
                  artifactDir: `tmp/arc/${arcId}`, checkpoint }
      break
    }
  } catch { continue }
}
if (!located) {
  output("No completed arc runs found. Only completed arcs can be analyzed.")
  exit
}
```

Collect up to 5 recent arc runs for trend analysis:
```javascript
// For cross-run comparison — collect recent completed arcs
const recentArcs = []
for (const dir of arcDirs.reverse()) {
  if (recentArcs.length >= 5) break
  try {
    const ckpt = JSON.parse(Read(`${dir}/checkpoint.json`))
    if (ckpt.phases?.ship?.status === "completed") {
      const arcId = dir.split("/").pop()
      recentArcs.push({ id: arcId, checkpointPath: `${dir}/checkpoint.json`,
                        artifactDir: `tmp/arc/${arcId}`, checkpoint: ckpt })
    }
  } catch { continue }
}
```

Output: `Analyzing arc: ${located.id} (artifacts at ${located.artifactDir})`

### R1: Spawn Runtime Analysis Agents

Create agent team and spawn 3 runtime agents in parallel:

```javascript
const teamName = `rune-self-audit-${TIMESTAMP}`
TeamCreate({ name: teamName })

// Create tasks before spawning agents (TEAM-002 contract)
TaskCreate({ subject: "Hallucination detection", owner: "" })
TaskCreate({ subject: "Effectiveness analysis", owner: "" })
TaskCreate({ subject: "Convergence analysis", owner: "" })

// Spawn 3 agents in parallel
Agent({
  team_name: teamName,
  name: "hallucination-detector",
  subagent_type: "rune:investigation:hallucination-detector",
  prompt: `Analyze arc run ${located.id} for hallucination patterns.

Arc artifacts at: ${located.artifactDir}
Checkpoint at: ${located.checkpointPath}

Write findings to: ${AUDIT_DIR}/hallucination-findings.md

Claim your task from TaskList, set it in_progress, complete your analysis,
write findings file, then mark task completed.`
})

Agent({
  team_name: teamName,
  name: "effectiveness-analyzer",
  subagent_type: "rune:investigation:effectiveness-analyzer",
  prompt: `Analyze agent effectiveness in arc run ${located.id}.

Arc artifacts at: ${located.artifactDir}
Checkpoint at: ${located.checkpointPath}

Write findings to: ${AUDIT_DIR}/effectiveness-findings.md

Claim your task from TaskList, set it in_progress, complete your analysis,
write findings file, then mark task completed.`
})

Agent({
  team_name: teamName,
  name: "convergence-analyzer",
  subagent_type: "rune:investigation:convergence-analyzer",
  prompt: `Analyze convergence patterns in arc run ${located.id}.

Arc artifacts at: ${located.artifactDir}
Checkpoint at: ${located.checkpointPath}

Write findings to: ${AUDIT_DIR}/convergence-findings.md

Claim your task from TaskList, set it in_progress, complete your analysis,
write findings file, then mark task completed.`
})
```

### R2: Collect + Compute Metrics

Wait for all 3 agents to complete (poll TaskList every 30s).

Parse agent findings and compute structured metrics:

```javascript
// Read agent outputs (handle missing files gracefully)
const hallucinationFindings = safeRead(`${AUDIT_DIR}/hallucination-findings.md`) || ""
const effectivenessFindings = safeRead(`${AUDIT_DIR}/effectiveness-findings.md`) || ""
const convergenceFindings = safeRead(`${AUDIT_DIR}/convergence-findings.md`) || ""

// Build metrics.json
const metrics = {
  schema_version: "1.0",
  arc_id: located.id,
  timestamp: TIMESTAMP,
  hallucination: {
    phantom_claims: countMatches(hallucinationFindings, /HD-PHANTOM/g),
    inflated_scores: countMatches(hallucinationFindings, /HD-INFLATE/g),
    fabricated_evidence: countMatches(hallucinationFindings, /HD-EVIDENCE/g),
    total_flags: 0  // sum of above
  },
  effectiveness: {
    agents_analyzed: 0,
    avg_false_positive_rate: 0.0,
    agents_with_high_fp: [],  // >20% FP rate
    agents_with_low_unique: []  // <30% unique findings
  },
  convergence: {
    total_retries: 0,
    wasted_retries: 0,  // retries without score improvement
    stagnation_phases: [],
    bottleneck_phase: null  // longest duration phase
  },
  trend: {
    runs_compared: recentArcs.length,
    improving: [],   // dimensions improving across runs
    degrading: [],   // dimensions degrading across runs
    stable: []
  }
}
metrics.hallucination.total_flags = metrics.hallucination.phantom_claims +
  metrics.hallucination.inflated_scores + metrics.hallucination.fabricated_evidence

// Write metrics JSON
Write(`${AUDIT_DIR}/metrics.json`, JSON.stringify(metrics, null, 2))
```

### R3: Merge into Self-Audit Report

Generate the final SELF-AUDIT-REPORT.md:

```markdown
# Rune Self-Audit Report
Generated: ${TIMESTAMP}
Mode: ${MODE}

## Static Analysis
[Include static findings if --mode all or --mode static]

## Runtime Analysis (arc: ${located.id})

### Hallucination Detection
[Include hallucination-findings.md content]

### Agent Effectiveness
[Include effectiveness-findings.md content]

### Convergence Analysis
[Include convergence-findings.md content]

### Metrics Summary
[Render metrics.json as human-readable table]

### Cross-Run Trends
[If multiple arcs found: show trend table]
```

Write to `${AUDIT_DIR}/SELF-AUDIT-REPORT.md`.

Output final summary to user:
```
/rune:self-audit — Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Arc analyzed: ${located.id}
Hallucination flags: N
Effectiveness issues: N agents with high FP rate
Convergence issues: N wasted retries
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Full report: ${AUDIT_DIR}/SELF-AUDIT-REPORT.md
Metrics:     ${AUDIT_DIR}/metrics.json
```

## Phase 3: Cleanup (runtime mode only)

After all agents complete, perform standard team cleanup:

```javascript
// 1. Dynamic member discovery
let allMembers = []
try {
  const CHOME = Bash(`echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  allMembers = ["hallucination-detector", "effectiveness-analyzer", "convergence-analyzer"]
}

// 2. Shutdown all members
let confirmedAlive = 0
for (const member of allMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Analysis complete" }); confirmedAlive++ }
  catch (e) {}
}

// 3. Adaptive grace period
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`)
} else {
  Bash("sleep 2")
}

// 4. TeamDelete with retry
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {}
}

// 5. Filesystem fallback (QUAL-012 — only if TeamDelete failed)
if (!cleanupTeamDeleteSucceeded) {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  Bash(`rm -rf "${CHOME}/teams/${teamName}/" "${CHOME}/tasks/${teamName}/" 2>/dev/null`)
}
```

## --history Subcommand

When `--history` flag is set, read all past `metrics.json` files and display a trend table.

```javascript
// Collect all past metrics.json files from self-audit runs
const metricsFiles = Glob("tmp/self-audit/*/metrics.json")
if (metricsFiles.length === 0) {
  output("No past audit results found. Run /rune:self-audit first.")
  exit
}

// Sort by timestamp directory name (newest first)
const runs = []
for (const mf of metricsFiles.sort().reverse()) {
  try {
    const metrics = JSON.parse(Read(mf))
    const dirTs = mf.split("/")[2]  // tmp/self-audit/{timestamp}/metrics.json
    runs.push({ timestamp: dirTs, metrics })
  } catch { continue }  // skip unparseable files
}

// Compute per-run scores
//   static_score: derived from static findings count (lower is better, invert to 0-100)
//   runtime_score: derived from hallucination total_flags + wasted_retries + high_fp agents
//   overall: weighted average (static 40%, runtime 60%)
function computeScores(metrics) {
  // Runtime score: start at 100, deduct for issues
  let runtime_score = 100
  runtime_score -= Math.min(30, (metrics.hallucination?.total_flags || 0) * 5)
  runtime_score -= Math.min(20, (metrics.convergence?.wasted_retries || 0) * 5)
  runtime_score -= Math.min(20, (metrics.effectiveness?.agents_with_high_fp?.length || 0) * 10)
  runtime_score = Math.max(0, runtime_score)
  return { runtime_score }
}

// Threshold-based trend classification (AC-9)
//   Compares each run to the PREVIOUS run, not to a baseline regression model
//   Thresholds: ≥5 point improvement = ↑ Improving, ≥5 point decline = ↓ Degrading, else ~ Stable
function classifyTrend(current, previous) {
  if (previous === null) return "—"
  const delta = current - previous
  if (delta >= 5) return "↑ Improving"
  if (delta <= -5) return "↓ Degrading"
  return "~ Stable"
}

// Build display table
const rows = []
let prevScore = null
for (const run of runs) {
  const { runtime_score } = computeScores(run.metrics)
  const trend = classifyTrend(runtime_score, prevScore)
  const delta = prevScore !== null ? runtime_score - prevScore : null
  rows.push({
    timestamp: run.timestamp,
    arc_id: run.metrics.arc_id || "N/A",
    halluc_flags: run.metrics.hallucination?.total_flags ?? "?",
    wasted_retries: run.metrics.convergence?.wasted_retries ?? "?",
    high_fp_agents: run.metrics.effectiveness?.agents_with_high_fp?.length ?? "?",
    runtime_score,
    trend,
    delta: delta !== null ? (delta >= 0 ? `+${delta}` : `${delta}`) : "—"
  })
  prevScore = runtime_score
}

// Display
output(`
/rune:self-audit — History (${rows.length} past audits)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Date/Time            │ Arc ID           │ Halluc │ Retries │ Score │ Trend
─────────────────────┼──────────────────┼────────┼─────────┼───────┼──────────
${rows.map(r =>
  `${r.timestamp.padEnd(21)}│ ${r.arc_id.padEnd(16)} │ ${String(r.halluc_flags).padEnd(6)} │ ${String(r.wasted_retries).padEnd(7)} │ ${String(r.runtime_score).padEnd(5)} │ ${r.trend} (${r.delta})`
).join("\n")}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Score: 100 = no issues. Deductions: -5/hallucination flag, -5/wasted retry, -10/high-FP agent
Trend: ↑ Improving (≥5pt gain) | ~ Stable (±4pt) | ↓ Degrading (≥5pt loss)
`)
```

## References

- [runtime-mode.md](references/runtime-mode.md) — Full runtime mode architecture and agent protocols
