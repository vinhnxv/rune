# Phase 1: FORGE — Full Algorithm

Invoke `/rune:forge` logic on the plan. Forge Gaze topic-aware enrichment with Codex Oracle and custom Ashes.

**Team**: `rune-forge-{timestamp}` (delegated to `/rune:forge` — manages its own TeamCreate/TeamDelete with guards)
**Tools**: Forge agents receive read-only tools (Read, Glob, Grep, Write for own output file only)
**Timeout**: 15 min (PHASE_TIMEOUTS.forge = 900_000 — inner 10m + 5m setup)
**Inputs**: planFile (string, validated at arc init), id (string, validated at arc init)
**Outputs**: `tmp/arc/{id}/enriched-plan.md` (enriched copy of original plan)
**Error handling**: Forge timeout — proceed with original plan copy (warn user, offer `--no-forge`). No enrichments — use original plan copy. Team lifecycle failure — delegated to forge cleanup (see [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md)).
**Consumers**: SKILL.md (Phase 1 stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

**Forge Gaze features** (all handled internally by `/rune:forge`):
- Topic-to-agent matching: each plan section gets specialized agents based on keyword overlap scoring
- Codex Oracle: conditional cross-model enrichment if `codex` CLI available and `forge` in `talisman.codex.workflows`
- Custom Ashes: talisman.yml `ashes.custom` with `workflows: [forge]`
- Enrichment Output Format: Best Practices, Performance, Implementation Details, Edge Cases, References

## Arc-Context Adaptations

When forge detects arc context (`planPath.startsWith("tmp/arc/")`), it automatically:
- Skips Phase 3 (scope confirmation) — arc is automated, no user gate
- Skips Phase 6 post-enhancement options — arc continues to Phase 2

## Algorithm

```javascript
// STEP 1: Create working copy for forge to enrich
// Forge edits in-place via Edit; arc needs the original preserved.
// SEC-007 FIX: Local validation of id — defense-in-depth (SKILL.md validates upstream)
if (!/^arc-[a-zA-Z0-9_-]+$/.test(id)) throw new Error('Invalid arc id')
if (id.includes('..')) throw new Error('Path traversal detected in arc id')
Bash(`mkdir -p "tmp/arc/${id}"`)
Bash(`cp -- "${planFile}" "tmp/arc/${id}/enriched-plan.md"`)
const forgePlanPath = `tmp/arc/${id}/enriched-plan.md`

// STEP 2: Delegate to /rune:forge
// /rune:forge manages its own team lifecycle (TeamCreate, Forge Gaze agent selection,
// section-level enrichment, Codex Oracle, custom Ashes, cleanup, TeamDelete).
// Arc records the team_name for cancel-arc discovery.
// Delegation pattern: /rune:forge creates its own team (e.g., rune-forge-{timestamp}).
// Arc reads the team name from the forge state file.
// SEC-002 FIX: Clean stale forge state files before delegation to prevent TOCTOU confusion.
// Only remove completed/cancelled/expired files — preserve active sessions (< 30 min old).
// DOC-006 FIX: staleForgeFiles = pre-delegation cleanup (lines below); forgeStateFiles = post-delegation discovery (line 65+)
// ZSH-SAFE: MUST use Glob() for wildcard resolution, then rm per-file with quoted path.
// NEVER use raw glob in Bash (e.g., `rm -f tmp/.rune-forge-*.json`) — ZSH NOMATCH kills the command.
const staleForgeFiles = Glob("tmp/.rune-forge-*.json")
for (const sf of staleForgeFiles) {
  try {
    const state = JSON.parse(Read(sf))
    const age = Date.now() - new Date(state.started).getTime()
    // SEC-007 FIX: NaN guard — malformed state.started produces NaN age, should be treated as stale
    if (state.status === "completed" || state.status === "cancelled" || (!Number.isNaN(age) && age > 1800000)) {
      Bash(`rm -f "${sf}" 2>/dev/null`)  // "${sf}" is a resolved path from Glob — no shell glob expansion
    }
    // Preserve active files < 30 min old — concurrent /rune:forge sessions depend on these
  } catch (e) {
    // Unparseable state file — remove as stale
    Bash(`rm -f "${sf}" 2>/dev/null`)  // "${sf}" is a resolved path — safe
  }
}
// SEC-12 FIX: Use Glob() to resolve wildcard — Read() does not support glob expansion.
// CDX-2 NOTE: Glob matches ALL forge state files — [0] is most recent by mtime.
// After /rune:forge invocation completes, read state file to discover team name:
const forgeStateFiles = Glob("tmp/.rune-forge-*.json")
if (forgeStateFiles.length > 1) warn(`Multiple forge state files found (${forgeStateFiles.length}) — using most recent`)
let forgeTeamName = forgeStateFiles.length > 0
  ? JSON.parse(Read(forgeStateFiles[0])).team_name
  : `rune-forge-${Date.now()}`
// SEC-001 FIX: Validate BEFORE any Bash interpolation (team_name from state file is untrusted)
if (!/^[a-zA-Z0-9_-]+$/.test(forgeTeamName)) throw new Error(`Invalid team_name from state file: ${forgeTeamName}`)
// SEC-002 FIX: Verify team actually exists (defense against stale state files from prior runs)
// TOME-5 FIX: Use CHOME-based check instead of bare ~/.claude/ path
const forgeTeamExists = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -f "$CHOME/teams/${forgeTeamName}/config.json" && echo "exists"`).trim() === "exists"
if (forgeStateFiles.length > 0 && !forgeTeamExists) {
  warn(`Forge state file references team "${forgeTeamName}" but team does not exist — using fallback`)
  forgeTeamName = `rune-forge-${Date.now()}`
}
updateCheckpoint({ phase: "forge", status: "in_progress", phase_sequence: 1, team_name: forgeTeamName })

// STEP 3: Verify enriched plan exists and has content
const enrichedPlan = Read(forgePlanPath)
if (!enrichedPlan || enrichedPlan.trim().length === 0) {
  warn("Forge produced empty output. Using original plan.")
  Bash(`cp -- "${planFile}" "${forgePlanPath}"`)
}

// STEP 4: Update checkpoint
const writtenContent = Read(forgePlanPath)
updateCheckpoint({
  phase: "forge", status: "completed",
  artifact: forgePlanPath, artifact_hash: sha256(writtenContent), phase_sequence: 1
})
```

**Output**: `tmp/arc/{id}/enriched-plan.md`

**Failure policy**: Proceed with original plan copy if forge fails or times out. Warn user and offer `--no-forge` on retry.

> **Note**: The `--no-forge` skip is handled by SKILL.md dispatcher (checks `noForgeFlag` before entering this phase). This file executes only when forge is not skipped.

## Team Lifecycle

Delegated to `/rune:forge` — manages its own TeamCreate/TeamDelete with guards (see [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md)). Arc records the actual `team_name` in checkpoint for cancel-arc discovery.

Arc MUST record the actual `team_name` created by `/rune:forge` in the checkpoint. This enables `/rune:cancel-arc` to discover and shut down the forge team if the user cancels mid-pipeline. The forge command creates its own team with its own naming convention — arc reads the team name back after delegation.

Arc runs `prePhaseCleanup(checkpoint)` before delegation (ARC-6) and `postPhaseCleanup(checkpoint, "forge")` after checkpoint update. See SKILL.md Inter-Phase Cleanup Guard section and [arc-phase-cleanup.md](arc-phase-cleanup.md).
