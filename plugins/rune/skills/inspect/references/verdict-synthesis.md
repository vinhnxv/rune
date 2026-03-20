# Verdict Synthesis — Reference

This reference covers Phase 5 (Verdict Binder aggregation) through Phase 7.3 (state update) of `/rune:inspect`: score aggregation, gap classification, recommendation generation, and the requirement matrix.

## Phase 5: Aggregate

### Step 5.1 — Check Inspector Outputs

```javascript
const inspectorOutputs = []
for (const inspector of Object.keys(inspectorAssignments)) {
  const outputPath = `${outputDir}/${inspector}.md`
  if (exists(outputPath)) {
    inspectorOutputs.push({ inspector, path: outputPath, status: "complete" })
  } else {
    inspectorOutputs.push({ inspector, path: outputPath, status: "missing" })
    log(`WARNING: ${inspector} output missing at ${outputPath}`)
  }
}
```

### Step 5.2 — Summon Verdict Binder

If all (or most) inspector outputs exist, summon the Verdict Binder to aggregate:

```javascript
if (inspectorOutputs.filter(o => o.status === "complete").length === 0) {
  error("No inspector outputs found. Inspection failed completely.")
}

// Build verdict-binder prompt from template
const verdictPrompt = loadTemplate("verdict-binder.md", {
  output_dir: outputDir,
  inspector_files: inspectorOutputs
    .filter(o => o.status === "complete")
    .map(o => `${o.inspector}.md`)
    .join(", "),
  plan_path: planPath || "(inline)",
  requirement_count: requirements.length,
  inspector_count: Object.keys(inspectorAssignments).length,
  timestamp: new Date().toISOString()
})

// ATE-1: Uses general-purpose with runebinder-style aggregation prompt (same as review.md Runebinder)
Agent({
  prompt: verdictPrompt,
  subagent_type: "general-purpose",
  team_name: teamName,
  name: "verdict-binder",
  model: resolveModelForAgent("verdict-binder", talisman),  // Cost tier mapping
  run_in_background: true
})
```

### Step 5.3 — Wait for Verdict

```javascript
// BACK-004 FIX: Use TaskList-based polling instead of fileExists (Core Rule 9 compliance)
// SEC-007 FIX: Eliminates symlink-based TOCTOU race on VERDICT.md
const verdictResult = waitForCompletion(teamName, 1, {
  timeoutMs: 120_000,        // 2 minutes (aggregation is fast)
  staleWarnMs: 60_000,       // 1 minute
  pollIntervalMs: 10_000,    // 10 seconds
  label: "Verdict Binder"
})

if (verdictResult.timedOut) {
  warn("Verdict Binder timed out — checking for partial output")
}
if (!exists(`${outputDir}/VERDICT.md`) || Bash(`test -L "${outputDir}/VERDICT.md" && echo symlink`).trim() === 'symlink') {
  error("VERDICT.md not produced. Check Verdict Binder output for errors.")
}
```

## Phase 6: Verify

### Step 6.1 — Cross-Check Evidence

Read the VERDICT.md and perform lightweight verification:

```javascript
const verdict = Read(`${outputDir}/VERDICT.md`)

// Verify: does VERDICT reference real files?
const fileRefs = verdict.match(/`([^`]+:\d+)`/g) || []
let verified = 0
let total = fileRefs.length

for (const ref of fileRefs.slice(0, 10)) {  // Cap at 10 checks
  const [file, line] = ref.replace(/`/g, "").split(":")
  if (fileExists(file)) {
    verified++
  }
}

log(`Evidence verification: ${verified}/${Math.min(total, 10)} file references valid`)
```

### Step 6.2 — Display Verdict Summary

```javascript
// Extract key metrics from VERDICT.md
log("═══════════════════════════════════════════")
log("  INSPECTION VERDICT")
log("═══════════════════════════════════════════")
log(`  Plan: ${planPath || "(inline)"}`)
log(`  Requirements: ${requirements.length}`)
log(`  Verdict: ${extractVerdict(verdict)}`)
log(`  Completion: ${extractCompletion(verdict)}%`)
log(`  Findings: ${extractFindingCounts(verdict)}`)
log(`  Report: ${outputDir}/VERDICT.md`)
log("═══════════════════════════════════════════")
```

## Phase 7: Cleanup

### Step 7.1-7.2 — Shutdown and TeamDelete

**Fallback array** (when team config unreadable):

```javascript
// FALLBACK: config.json read failed — use exhaustive list of all possible inspect agents.
// Safe to send shutdown_request to absent members — SendMessage is a no-op for unknown names.
// Include BOTH base names (from classifyRequirements/inspectorAssignments) and suffixed names
// (from SKILL.md MCP discovery path) to cover all spawn code paths.
allMembers = [
  // Base names (inspector-prompts.md spawns with `name: inspector` from inspectorAssignments)
  "grace-warden", "ruin-prophet", "sight-oracle", "vigil-keeper",
  // Suffixed names (SKILL.md MCP discovery path uses suffixed names)
  "grace-warden-inspect", "ruin-prophet-inspect",
  "sight-oracle-inspect", "vigil-keeper-inspect",
  "grace-warden-plan-review", "ruin-prophet-plan-review",
  "sight-oracle-plan-review", "vigil-keeper-plan-review",
  // Aggregator + conditional agents
  "verdict-binder", "gap-fixer", "lore-analyst"
]
```

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

**Post-step:**

```javascript
// ID validation
if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) {
  throw new Error(`Invalid team_name: ${teamName}`)
}

```

### Step 7.3 — Update State File

```javascript
const stateFile = `tmp/.rune-inspect-${identifier}.json`
const state = JSON.parse(Read(stateFile))
state.status = "completed"
state.completed = new Date().toISOString()
state.config_dir = configDir    // preserve session identity
state.owner_pid = ownerPid
state.session_id = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
state.verdict = extractVerdict(verdict)
state.completion = extractCompletion(verdict)
Write(stateFile, JSON.stringify(state))

// Release workflow lock (AFTER state update — canonical order per engines.md)
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "inspect"`)
```

### Step 7.4 — Persist Echo (if significant findings)

```javascript
// Persist to Rune Echoes if there are P1 findings
const p1Count = extractP1Count(verdict)
if (p1Count > 0) {
  // PW-001 FIX: Use appendEchoEntry() for structured echo persistence
  if (exists(".rune/echoes/orchestrator/")) {
    appendEchoEntry(".rune/echoes/orchestrator/MEMORY.md", {
      layer: "traced", source: `rune:inspect ${identifier}`, confidence: 0.3,
      session_id: identifier,
      content: `## Inspection: ${planPath || "inline"}\nDate: ${new Date().toISOString()}\n`
        + `Verdict: ${extractVerdict(verdict)}\nP1 findings: ${p1Count}\n\n`
        + `Key gaps identified — see ${outputDir}/VERDICT.md`
    })
  }
}
```

## Helper Functions

### Score Extraction

```javascript
function extractVerdict(verdictContent) {
  const match = verdictContent.match(/Verdict\s*\|\s*\*\*(\w+)\*\*/)
  return match ? match[1] : "UNKNOWN"
}

function extractCompletion(verdictContent) {
  const match = verdictContent.match(/Overall Completion\s*\|\s*(\d+)%/)
  return match ? parseInt(match[1]) : 0
}

function extractP1Count(verdictContent) {
  const match = verdictContent.match(/P1:\s*(\d+)/)
  return match ? parseInt(match[1]) : 0
}

function extractFindingCounts(verdictContent) {
  const p1 = extractP1Count(verdictContent)
  const p2Match = verdictContent.match(/P2:\s*(\d+)/)
  const p3Match = verdictContent.match(/P3:\s*(\d+)/)
  return `${p1} P1, ${p2Match?.[1] ?? 0} P2, ${p3Match?.[1] ?? 0} P3`
}
```

## Verdict Structure (VERDICT.md)

The Verdict Binder produces VERDICT.md with the following sections:

| Section | Content |
|---------|---------|
| Verdict Summary | Overall verdict (READY/PARTIAL/NOT_READY), completion %, finding counts |
| Requirement Matrix | Per-requirement status (MET/PARTIAL/MISSING), evidence references |
| Dimension Scores | 10 dimension scores from 0-100 |
| Gap Analysis | P1/P2/P3 gaps organized by 9 gap categories |
| Recommendations | Actionable next steps prioritized by severity |

### Gap Categories

| Category | Description |
|----------|-------------|
| MISSING | Feature/requirement not implemented at all |
| INCOMPLETE | Partially implemented — core logic present but edge cases missing |
| INCORRECT | Implemented but wrong — logic error, wrong behavior |
| INSECURE | Security vulnerability or missing security control |
| FRAGILE | Works but likely to break — missing error handling, no retries |
| UNOBSERVABLE | No logging, metrics, or tracing for significant operations |
| UNTESTED | No tests, or tests don't cover the requirement |
| UNMAINTAINABLE | Hard to change — excessive coupling, missing docs, magic values |
| UNWIRED | Integration point not connected — file not modified, pattern not registered (NOT auto-fixable) |

### Completion Threshold

```javascript
// RUIN-001 FIX: Runtime clamping prevents misconfiguration-based DoS/bypass
completionThreshold = Math.max(0, Math.min(100,
  flag("--threshold") ?? inspectConfig.completion_threshold ?? 80))
```

Verdict mapping:
- `>= threshold` → **READY**
- `>= threshold - 20` → **PARTIAL**
- `< threshold - 20` → **NOT_READY**

## Historical Risk Assessment (Goldmask Enhancement)

If `riskMap` is available from Phase 1.3, the Verdict Binder appends a Historical Risk Assessment section to VERDICT.md AFTER the standard verdict sections. This section is optional — if `riskMap` is null or parsing fails, the section is simply omitted (non-blocking).

### Content

```javascript
if (riskMap) {
  try {
    const parsed = JSON.parse(riskMap)
    const riskFiles = parsed?.files ?? []
    const tierOrder = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3, STALE: 4 }

    // Categorize files by tier
    const criticalFiles = riskFiles.filter(f => f.tier === 'CRITICAL')
    const highFiles = riskFiles.filter(f => f.tier === 'HIGH')
    const mediumFiles = riskFiles.filter(f => f.tier === 'MEDIUM')
    const lowFiles = riskFiles.filter(f => f.tier === 'LOW')

    // Single-owner files (bus factor risk)
    const singleOwnerFiles = riskFiles.filter(f =>
      f.metrics?.ownership?.distinct_authors === 1
    )

    // Build Historical Risk section
    let riskSection = "## Historical Risk Assessment (Goldmask Lore)\n\n"
    riskSection += "### File Risk Distribution\n\n"
    riskSection += "| Tier | Count | Files |\n"
    riskSection += "|------|-------|-------|\n"
    riskSection += `| CRITICAL | ${criticalFiles.length} | ${criticalFiles.map(f => '\`' + f.path + '\`').join(', ') || '--'} |\n`
    riskSection += `| HIGH | ${highFiles.length} | ${highFiles.map(f => '\`' + f.path + '\`').join(', ') || '--'} |\n`
    riskSection += `| MEDIUM | ${mediumFiles.length} | ... |\n`
    riskSection += `| LOW | ${lowFiles.length} | ... |\n\n`

    // Bus factor warnings
    if (singleOwnerFiles.length > 0) {
      riskSection += "### Bus Factor Warnings\n\n"
      for (const f of singleOwnerFiles.slice(0, 10)) {
        riskSection += `- \`${f.path}\`: single owner (${f.metrics?.ownership?.top_contributor ?? 'unknown'})\n`
      }
      riskSection += "\n"
    }

    // Inspection coverage vs risk
    riskSection += "### Inspection Coverage vs Risk\n\n"
    riskSection += "| Requirement | Risk Tier | Inspector Coverage | Finding Count |\n"
    riskSection += "|-------------|-----------|-------------------|---------------|\n"
    for (const req of requirements) {
      const reqTier = req.inspectionPriority === 'HIGH' ? 'CRITICAL'
        : req.inspectionPriority === 'ELEVATED' ? 'HIGH' : 'UNKNOWN'
      riskSection += `| ${req.id ?? req.text?.slice(0, 40)} | ${reqTier} | ${req.assignedInspectors?.length ?? 1} | -- |\n`
    }
    riskSection += "\n**Note**: Requirements touching CRITICAL files with zero findings"
    riskSection += " warrant manual review — they may represent gaps in inspection coverage.\n"

    // Append to VERDICT.md
    verdictContent += "\n\n" + riskSection
  } catch (parseError) {
    warn("Phase 5-6: risk-map parse error — omitting Historical Risk section from VERDICT")
  }
}
```

### Rendering Rule

The Historical Risk Assessment section is optional. If `riskMap` is null or parsing fails, the section is simply omitted from VERDICT.md. This is non-blocking.
