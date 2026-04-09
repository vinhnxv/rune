# Phase 6.7: VERIFY — Finding Verification Gate

Verify TOME findings before mend dispatch. Classifies each finding as TRUE_POSITIVE, FALSE_POSITIVE, or NEEDS_CONTEXT with evidence chains. Prevents wasted mend-fixer effort on false positives.

**Team**: `arc-fv-{id}` (delegated to `/rune:verify` — manages its own TeamCreate/TeamDelete)
**Tools**: Verify agents receive Read, Glob, Grep (read-only source access)
**Timeout**: 10 min (PHASE_TIMEOUTS.verify = 600_000)
**Inputs**: TOME from `checkpoint.phases.code_review.artifact` (or round-aware TOME path)
**Outputs**: `tmp/arc/{id}/verify/VERDICTS.md`
**Error handling**: Verify timeout or failure — proceed to mend with all findings unverified (warn user). No verdicts — mend processes all findings normally (backward compatible).
**Consumers**: SKILL.md (Phase 6.7 stub), Phase 7 MEND (verdict filtering in parse-tome.md)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Skip Conditions

- `arc.verify.enabled: false` in talisman (SKIP_REASONS.VERIFY_DISABLED)
- `--no-verify` flag passed to arc
- Pre-computed in `checkpoint.skip_map.verify`

## Algorithm

```javascript
// ═══════════════════════════════════════════════════════
// STEP 0: PRE-FLIGHT GUARDS
// ═══════════════════════════════════════════════════════

if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error(`Phase 6.7: unsafe id value: "${id}"`)

// Skip if no TOME was produced in code_review phase
const round = checkpoint.convergence?.round ?? 0
const tomePath = round > 0
  ? `tmp/arc/${id}/tome-round-${round}.md`
  : checkpoint.phases.code_review?.artifact ?? `tmp/arc/${id}/tome.md`

if (!exists(tomePath)) {
  warn(`Phase 6.7: skipped — no TOME found at ${tomePath}`)
  updateCheckpoint({
    phase: "verify", status: "skipped",
    skip_reason: "no_tome",
    phase_sequence: checkpoint.phase_sequence + 1
  })
  return
}

updateCheckpoint({
  phase: "verify", status: "in_progress",
  phase_sequence: checkpoint.phase_sequence + 1
})

// ═══════════════════════════════════════════════════════
// STEP 1: DELEGATE TO /rune:verify
// ═══════════════════════════════════════════════════════

// Create output directory
Bash(`mkdir -p "tmp/arc/${id}/verify"`)

// Delegate to /rune:verify skill
// The skill manages its own team lifecycle (TeamCreate, agent spawning, TeamDelete).
// Arc records the team_name for cancel-arc discovery.
Skill("rune:verify", `${tomePath} --output-dir tmp/arc/${id}/verify --timeout ${PHASE_TIMEOUTS.verify}`)

// Discover team name from verify state file for checkpoint recording
const verifyStateFiles = Glob("tmp/.rune-verify-*.json")
let verifyTeamName = `arc-fv-${id}`
if (verifyStateFiles.length > 0) {
  try {
    const state = JSON.parse(Read(verifyStateFiles[0]))
    if (state.team_name && /^[a-zA-Z0-9_-]+$/.test(state.team_name)) {
      verifyTeamName = state.team_name
    }
  } catch (e) {
    // Use default team name
  }
}

// ═══════════════════════════════════════════════════════
// STEP 2: VERIFY OUTPUT
// ═══════════════════════════════════════════════════════

const verdictsPath = `tmp/arc/${id}/verify/VERDICTS.md`

if (!exists(verdictsPath)) {
  warn("Phase 6.7: /rune:verify produced no VERDICTS.md. Mend will process all findings.")
  updateCheckpoint({
    phase: "verify", status: "completed",
    artifact: null,
    team_name: verifyTeamName,
    phase_sequence: checkpoint.phase_sequence
  })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 3: UPDATE CHECKPOINT
// ═══════════════════════════════════════════════════════

const verdictsContent = Read(verdictsPath)
const verdictsHash = sha256(verdictsContent)

// Count verdicts for logging
const fpCount = (verdictsContent.match(/verdict:\s*FALSE_POSITIVE/g) || []).length
const tpCount = (verdictsContent.match(/verdict:\s*TRUE_POSITIVE/g) || []).length
const ncCount = (verdictsContent.match(/verdict:\s*NEEDS_CONTEXT/g) || []).length
log(`Phase 6.7 complete: ${tpCount} TRUE_POSITIVE, ${fpCount} FALSE_POSITIVE, ${ncCount} NEEDS_CONTEXT`)

updateCheckpoint({
  phase: "verify", status: "completed",
  artifact: verdictsPath,
  artifact_hash: verdictsHash,
  team_name: verifyTeamName,
  phase_sequence: checkpoint.phase_sequence
})
```

**Output**: `tmp/arc/{id}/verify/VERDICTS.md`

**Failure policy**: Proceed to mend with all findings if verify fails or times out. Log warning. The mend phase's parse-tome.md handles the absence of VERDICTS.md gracefully — all findings are processed normally when no verdicts exist.

## Team Lifecycle

Delegated to `/rune:verify` — manages its own TeamCreate/TeamDelete. Arc records the actual `team_name` in checkpoint for cancel-arc discovery.

Arc runs `prePhaseCleanup(checkpoint)` before delegation (ARC-6) and `postPhaseCleanup(checkpoint, "verify")` after checkpoint update. See SKILL.md Inter-Phase Cleanup Guard section and [arc-phase-cleanup.md](arc-phase-cleanup.md).

## Crash Recovery

If arc crashes during verify phase:
- Team `arc-fv-{id}` may be orphaned
- Recovery: `/rune:arc --resume` detects `verify` phase in_progress, re-runs from verify
- Manual: `/rune:cancel-arc` discovers team via `ARC_TEAM_PREFIXES` scan
