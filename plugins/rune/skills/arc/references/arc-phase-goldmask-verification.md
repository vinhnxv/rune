# Phase 5.7: GOLDMASK VERIFICATION — Full Algorithm

Blast-radius analysis via investigation agents. Delegates to `/rune:goldmask` skill.

**Team**: Delegated to `/rune:goldmask` (manages its own team with `goldmask-` prefix)
**Tools**: Delegated — goldmask skill controls tool access for its agents
**Timeout**: 15 min (PHASE_TIMEOUTS.goldmask_verification = 900_000 — inner 10m + 5m setup)
**Inputs**: id, baseBranch, workBranch (from checkpoint), enriched-plan.md (optional: for prediction comparison)
**Outputs**: `tmp/arc/{id}/goldmask-verification.md`, `tmp/arc/{id}/goldmask-findings.json`
**Error handling**: Non-blocking. Skill failure → status "skipped" with reason. Team cleanup via ARC_TEAM_PREFIXES "goldmask-".
**Consumers**: SKILL.md (Phase 5.7 stub), Phase 6.5 (GOLDMASK CORRELATION)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Design Note: Skill Delegation

Phase 5.7 delegates to the standalone `/rune:goldmask` skill rather than inlining the 3-layer investigation logic. This matches the Phase 1 FORGE delegation pattern — the skill manages its own team lifecycle, agent summoning, and output aggregation.

**subagent_type**: The goldmask skill uses `general-purpose` agents (not `rune:investigation:*` types) with prompts that inject agent protocol files. This is intentional — general-purpose agents avoid "agent not found" errors and can read any protocol file, though it means agent-level `allowed-tools` frontmatter restrictions are advisory, not enforced.

## Algorithm

```javascript
// ═══════════════════════════════════════════════════════
// STEP 0: PRE-FLIGHT GUARDS
// ═══════════════════════════════════════════════════════

if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error(`Phase 5.7: unsafe id value: "${id}"`)

const goldmaskEnabled = talisman?.goldmask?.enabled !== false
const isGitRepo = Bash("git rev-parse --is-inside-work-tree 2>/dev/null").exitCode === 0

if (!goldmaskEnabled) {
  warn(`Phase 5.7: skipped — goldmask.enabled is false in talisman`)
  updateCheckpoint({
    phase: "goldmask_verification", status: "skipped",
    phase_sequence: 5.7
  })
  return
}

if (!isGitRepo) {
  warn(`Phase 5.7: skipped — not a git repository`)
  updateCheckpoint({
    phase: "goldmask_verification", status: "skipped",
    phase_sequence: 5.7
  })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 1: PREPARE DIFF SPEC
// ═══════════════════════════════════════════════════════

const workBranch = checkpoint.phases.work?.branch ?? 'HEAD'
const baseBranch = checkpoint.base_branch ?? 'main'
const diffSpec = `${baseBranch}...${workBranch}`

// ═══════════════════════════════════════════════════════
// STEP 2: CLEANUP + DELEGATE TO /rune:goldmask
// ═══════════════════════════════════════════════════════

prePhaseCleanup(checkpoint)  // Evict stale goldmask- teams (EC-4.2)

updateCheckpoint({
  phase: "goldmask_verification", status: "in_progress",
  phase_sequence: 5.7
})

// Delegate to goldmask skill — it manages its own team
// The skill reads agents/investigation/*.md and summons:
//   - 5 Impact Tracers (Haiku): api-contract, business-logic, data-layer, config-dependency, event-message
//   - Wisdom Sage (Sonnet): git blame + intent classification
//   - Lore Analyst (Haiku): risk-map.json + co-change clusters
//   - Goldmask Coordinator (Sonnet): 3-layer synthesis + GOLDMASK.md
try {
  Skill("rune:goldmask", diffSpec)
} catch (e) {
  warn(`Phase 5.7: goldmask skill failed — ${e.message ?? 'unknown error'}`)
  updateCheckpoint({
    phase: "goldmask_verification", status: "skipped",
    phase_sequence: 5.7
  })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 3: COLLECT OUTPUT
// ═══════════════════════════════════════════════════════

// Goldmask writes to tmp/goldmask/ — copy to arc artifacts
// Path resolution: goldmask skill writes GOLDMASK.md and findings.json to tmp/goldmask/
let goldmaskReport = null
let findings = null

try {
  // Try arc-context path first, then standalone path
  const reportPath = exists(`tmp/goldmask/GOLDMASK.md`)
    ? `tmp/goldmask/GOLDMASK.md`
    : null
  const findingsPath = exists(`tmp/goldmask/findings.json`)
    ? `tmp/goldmask/findings.json`
    : null

  if (reportPath) {
    goldmaskReport = Read(reportPath)
    Write(`tmp/arc/${id}/goldmask-verification.md`, goldmaskReport)
  }
  if (findingsPath) {
    const findingsRaw = Read(findingsPath)
    findings = JSON.parse(findingsRaw)
    Write(`tmp/arc/${id}/goldmask-findings.json`, findingsRaw)
  }
} catch (e) {
  warn(`Phase 5.7: Failed to collect goldmask output — ${e.message ?? 'unknown'}`)
}

if (!goldmaskReport) {
  warn(`Phase 5.7: No GOLDMASK.md produced — marking skipped`)
  updateCheckpoint({
    phase: "goldmask_verification", status: "skipped",
    phase_sequence: 5.7
  })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 4: PREDICTION COMPARISON (optional)
// ═══════════════════════════════════════════════════════

// If plan-time prediction exists (from Phase 2.3 Predictive Goldmask),
// compare predicted MUST-CHANGE files vs actual findings
const planFile = checkpoint.plan_file
let predictionPath = null
if (planFile) {
  // Derive plan timestamp from checkpoint
  const planTimestamp = checkpoint.plan_timestamp ?? null
  if (planTimestamp && exists(`tmp/plans/${planTimestamp}/risk-map.json`)) {
    predictionPath = `tmp/plans/${planTimestamp}/risk-map.json`
  }
}

if (predictionPath && findings?.findings) {
  try {
    const predicted = JSON.parse(Read(predictionPath))
    const predictedCritical = Object.entries(predicted.files ?? {})
      .filter(([_, v]) => v.tier === 'CRITICAL')
      .map(([path]) => path)
    const actualFindings = findings.findings
      .filter(f => f.priority >= 0.80)
      .map(f => f.file)

    const confirmed = predictedCritical.filter(p => actualFindings.includes(p))
    const missed = predictedCritical.filter(p => !actualFindings.includes(p))
    const unexpected = actualFindings.filter(a => !predictedCritical.includes(a))

    log(`Goldmask Verification — Prediction Comparison:`)
    log(`  Predicted CRITICAL: ${predictedCritical.length}`)
    log(`  Confirmed: ${confirmed.length}`)
    log(`  Missed predictions: ${missed.length}`)
    log(`  Unexpected findings: ${unexpected.length}`)
  } catch (e) {
    // Prediction comparison is advisory — silent skip on failure
  }
}

// ═══════════════════════════════════════════════════════
// STEP 5: UPDATE CHECKPOINT
// ═══════════════════════════════════════════════════════

const findingCount = findings?.findings?.length ?? 0
const criticalCount = findings?.findings?.filter(f => f.priority >= 0.80).length ?? 0

updateCheckpoint({
  phase: "goldmask_verification", status: "completed",
  artifact: `tmp/arc/${id}/goldmask-verification.md`,
  artifact_hash: sha256(goldmaskReport),
  phase_sequence: 5.7,
  finding_count: findingCount,
  critical_count: criticalCount
})
postPhaseCleanup(checkpoint, "goldmask_verification")
```

## Crash Recovery

If this phase crashes before cleanup:

| Resource | Location |
|----------|----------|
| Goldmask team | `$CHOME/teams/goldmask-*/` (where `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`) |
| Goldmask tasks | `$CHOME/tasks/goldmask-*/` (where `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`) |
| Goldmask output | `tmp/goldmask/` |
| Arc artifacts | `tmp/arc/{id}/goldmask-verification.md`, `tmp/arc/{id}/goldmask-findings.json` |

Recovery: `prePhaseCleanup()` handles team/task cleanup via ARC_TEAM_PREFIXES which includes `"goldmask-"`. `postPhaseCleanup()` provides additional prefix-based sweep after phase completion. Goldmask output in `tmp/goldmask/` is cleaned by `/rune:rest`.

---

## Agent Completion Contract (v2.58.0+, ARC-QA-001/002)

Agents spawned by this phase MUST follow the durable-first completion contract. Inject into every agent spawn prompt:

```
COMPLETION CONTRACT (mandatory — ARC-QA-001):
When your task is complete, you MUST do ALL THREE:
1. Write your artifact to its canonical path (e.g., tmp/arc/{id}/{agent}-findings.md)
2. Write a sentinel to tmp/arc/{id}/.done/{your-agent-name}.done with a one-line JSON payload:
   {"agent":"{your-name}","status":"completed","verdict_path":"<artifact-path>","timestamp":"<ISO8601 UTC>"}
3. Call TaskUpdate(status:"completed") AND SendMessage to team-lead

The sentinel (step 2) is the primary completion signal — survives TeamDelete. Steps 1 and 3
are required for downstream consumers but the leader polls step 2 (ARC-QA-001 Sentinel check).

Do NOT skip step 2 even if you completed steps 1 and 3.
```

See `roundtable-circle/references/monitor-utility.md` `countCompletedAgents()` for the leader-side fusion protocol.
