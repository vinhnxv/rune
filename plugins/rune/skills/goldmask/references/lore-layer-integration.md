# Lore Layer Integration (Orchestrator-Side)

Shared integration pattern for skills that consume Goldmask Lore Layer risk scoring. Covers the orchestrator-side gate logic, data discovery, lore-analyst spawning, and polling timeout. Used by forge (Phase 1.5), inspect (Phase 1.3), and devise (Phase 2.3).

**Inputs**: `talisman` (config object), `scopeFiles` or `uniqueFiles` (string[]), `outputDir` (string), `timestamp` or `identifier` (string), `teamName` (string, optional — only when team already exists)
**Outputs**: `riskMap` (string | null), `riskMapSource` (string), optionally `wisdomData` (string | null)
**Preconditions**: Git repo detected, talisman config loaded, scope files extracted from prior phase

## Step 1: Skip Gate

Check talisman kill switches, git repo availability, CLI flags, and G5 commit guard:

```javascript
const goldmaskEnabled = talisman?.goldmask?.enabled !== false
const workflowGoldmaskEnabled = talisman?.goldmask?.{workflow}?.enabled !== false  // forge, inspect, devise
const loreEnabled = talisman?.goldmask?.layers?.lore?.enabled !== false
const isGitRepo = Bash("git rev-parse --is-inside-work-tree 2>/dev/null").trim() === "true"
const noLoreFlag = args.includes("--no-lore")

let riskMap = null
let riskMapSource = "none"

if (!goldmaskEnabled || !workflowGoldmaskEnabled || !loreEnabled || !isGitRepo || noLoreFlag) {
  warn("Phase N: Lore Layer skipped — " + skipReason)
} else if (scopeFiles.length === 0) {
  warn("Phase N: Lore Layer skipped — no file references found")
} else {
  // G5 guard: require minimum commit history
  const lookbackDays = talisman?.goldmask?.layers?.lore?.lookback_days ?? 180
  const commitCount = parseInt(
    Bash(`git rev-list --count HEAD --since='${lookbackDays} days ago' 2>/dev/null || echo 0`).trim()
  )
  if (commitCount < 5) {
    warn("Phase N: Lore Layer skipped — fewer than 5 commits (G5 guard)")
  } else {
    // Proceed to Step 2
  }
}
```

## Step 2: Discover Existing Risk-Map or Spawn Lore-Analyst

```javascript
// Option A: Reuse existing risk-map from prior workflows
// See data-discovery.md for the full discovery protocol
const existing = discoverGoldmaskData({
  needsRiskMap: true,
  maxAgeDays: 3,
  scopeFiles: scopeFiles  // 30% overlap validation
})

if (existing?.riskMap) {
  riskMap = existing.riskMap
  riskMapSource = existing.riskMapPath
  warn(`Phase N: Reusing existing risk-map from ${existing.riskMapPath}`)
} else {
  // Option B: Spawn lore-analyst as bare Agent (ATE-1 EXEMPTION — no team exists yet)
  // Uses subagent_type: "general-purpose" with identity via prompt
  // (enforce-teams.sh only allows Explore/Plan as named types)
  Agent({
    subagent_type: "general-purpose",
    name: "{workflow}-lore-analyst",
    // NO team_name — ATE-1 exemption (pre-team phase)
    // OR with team_name if team already exists (e.g., devise Phase 2.3)
    prompt: `You are rune:investigation:lore-analyst — a Goldmask Lore Layer analyst.

Analyze git history risk metrics for the following files:
${scopeFiles.join("\n")}

Lookback window: ${lookbackDays} days

Write risk-map.json to: ${outputDir}/risk-map.json

Follow the lore-analyst protocol: compute per-file churn frequency, ownership concentration,
co-change coupling, and assign risk tiers (CRITICAL, HIGH, MEDIUM, LOW, STALE).
Output format: { "files": [{ "path", "tier", "risk_score", "metrics": { "frequency", "ownership": { "distinct_authors", "top_contributor" }, "co_changes": [{ "coupled_file", "coupling_pct" }] } }] }`
  })

  // Wait for lore-analyst output (30s timeout — non-blocking)
  const LORE_TIMEOUT_MS = 30_000
  const LORE_POLL_MS = 5_000
  const maxPolls = Math.ceil(LORE_TIMEOUT_MS / LORE_POLL_MS)
  for (let poll = 0; poll < maxPolls; poll++) {
    Bash(`sleep ${LORE_POLL_MS / 1000}`, { run_in_background: true })
    try {
      riskMap = Read(`${outputDir}/risk-map.json`)
      if (riskMap && riskMap.trim().length > 0) {
        riskMapSource = `${outputDir}/risk-map.json`
        break
      }
    } catch (readError) {
      continue  // Not ready yet
    }
  }

  if (!riskMap) {
    warn("Phase N: Lore analyst timed out — proceeding without risk data")
  }

  // FIX: Kill orphaned bare lore-analyst process (no team = no SendMessage shutdown)
  // Without this, the agent process lingers on the bottom bar until session ends.
  // Uses the same process-kill pattern as engines.md step 5a.
  const loreOwnerPid = Bash(`echo $PPID`).trim()
  if (loreOwnerPid && /^\d+$/.test(loreOwnerPid)) {
    Bash(`for pid in $(pgrep -P ${loreOwnerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio \&\& continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
  }
}
```

## Skip Conditions Summary

| Condition | Effect |
|-----------|--------|
| `talisman.goldmask.enabled === false` | Skip entirely |
| `talisman.goldmask.{workflow}.enabled === false` | Skip entirely |
| `talisman.goldmask.layers.lore.enabled === false` | Skip entirely |
| `--no-lore` CLI flag | Skip entirely |
| Non-git repo | Skip entirely |
| No scope files (0 files) | Skip entirely |
| < 5 commits in lookback window (G5 guard) | Skip entirely |
| Existing risk-map found (>30% overlap) | Reuse instead of spawning agent |

## Workflow-Specific Variations

| Workflow | Team Context | Scope Source | Extra Outputs |
|----------|-------------|--------------|---------------|
| **forge** (Phase 1.5) | Pre-team (ATE-1 exemption) | `uniqueFiles` from Phase 1.3 file refs | `tmp/forge/{timestamp}/risk-map.json` |
| **inspect** (Phase 1.3) | Pre-team (ATE-1 exemption) | `scopeFiles` from Phase 1 Glob/Grep | `tmp/inspect/{identifier}/risk-map.json` + wisdom passthrough |
| **devise** (Phase 2.3) | Within plan team (`rune-plan-{timestamp}`) | `predictedFiles` from Phase 1 research | `tmp/plans/{timestamp}/goldmask-prediction/risk-map.json` |

**Key difference**: Devise spawns lore-analyst WITH `team_name` (team exists at Phase 2.3). Forge and inspect spawn WITHOUT `team_name` (ATE-1 exemption — pre-team phase).
