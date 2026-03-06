# Phase 3: Confirm Scope + Phase 3.5: Workflow Lock + Phase 4: Summon Forge Agents

## Phase 3: Confirm Scope

Before summoning agents, confirm with the user. **Skipped in arc context** — arc is automated, no user gate needed.

```javascript
if (!isArcContext) {
  AskUserQuestion({
    questions: [{
      question: `Forge Gaze selected ${totalAgents} agents across ${sectionCount} sections.\n\n${selectionSummary}\n\nProceed with enrichment?`,
      header: "Forge scope",
      options: [
        { label: "Proceed (Recommended)", description: "Summon agents and enrich plan" },
        { label: "Skip sections", description: "I'll tell you which sections to skip" },
        { label: "Cancel", description: "Exit without changes" }
      ],
      multiSelect: false
    }]
  })
}
// In arc context: proceed directly to Phase 4 (agent summoning)
```

## Phase 3.5: Workflow Lock (writer)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "writer"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "forge" "writer"`)
```

## Phase 4: Summon Forge Agents

Follow the `teamTransition` protocol (see [engines.md](../team-sdk/references/engines.md) § createTeam):
1. Validate timestamp: `!/^[a-zA-Z0-9_-]+$/` check
2. TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
3. Filesystem fallback if TeamDelete fails (gated on `!teamDeleteSucceeded`)
4. TeamCreate with "Already leading" catch-and-recover
5. Post-create verification via config.json check

After team creation:

```javascript
// Concurrent session check
const existingForge = Glob("tmp/.rune-forge-*.json")
for (const sf of existingForge) {
  let state
  try { state = JSON.parse(Read(sf)) } catch (e) { continue }  // Skip corrupt state files
  if (state.status === "active") {
    const age = Date.now() - new Date(state.started).getTime()
    if (age < 1800000) { // 30 minutes
      warn(`Active forge session detected: ${sf} (${Math.round(age/60000)}min old). Aborting.`)
      return
    }
  }
}

// ── Resolve session identity for cross-session isolation ──
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

const startedTimestamp = new Date().toISOString()
Write(`tmp/.rune-forge-${timestamp}.json`, {
  team_name: `rune-forge-${timestamp}`,
  plan: planPath,
  started: startedTimestamp,
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}"
})

// Create output directory + inscription.json
Bash(`mkdir -p "tmp/forge/${timestamp}"`)
```

See [forge-enrichment-protocol.md](forge-enrichment-protocol.md) for: inscription.json format, task creation, agent prompt templates, Elicitation Sage spawning, and Enrichment Output Format.

### MCP Context Injection (Phase 4)

When `mcpContextBlock` is non-empty (computed in Phase 1.6), inject it into each forge agent's spawn prompt after the section content and before the enrichment instructions:

```javascript
// Append to each forge agent prompt when MCP integrations are active
// mcpContextBlock from Phase 1.6 — empty string when no integrations (no-op)
const forgePromptSuffix = mcpContextBlock
  ? `\n${mcpContextBlock}\n    Consider these MCP tools when suggesting implementation details, best practices, and edge cases for this section.\n`
  : ''
// Injected into agent prompt AFTER section content, BEFORE enrichment output format
```

### Monitor

Uses the shared polling utility — see [`monitor-utility.md`](../roundtable-circle/references/monitor-utility.md) for full pseudocode and contract.

> **ANTI-PATTERN — NEVER DO THIS:**
> `Bash("sleep 60 && echo poll check")` — This skips TaskList entirely. You MUST call `TaskList` every cycle. See review Phase 4 for the correct inline loop template.

```javascript
// QUAL-006 MITIGATION (P2): Hard timeout to prevent runaway forge sessions.
const FORGE_TIMEOUT = 1_200_000 // 20 minutes

// See skills/roundtable-circle/references/monitor-utility.md
const result = waitForCompletion(teamName, totalEnrichmentTasks, {
  timeoutMs: FORGE_TIMEOUT,   // 20 minutes hard timeout
  staleWarnMs: 300_000,      // 5 minutes
  autoReleaseMs: 300_000,    // 5 minutes — enrichment tasks are reassignable
  pollIntervalMs: 30_000,    // 30 seconds
  label: "Forge"
})

if (result.timedOut) {
  warn(`Forge timed out after ${FORGE_TIMEOUT / 60_000} minutes. Proceeding with ${result.completed.length}/${totalEnrichmentTasks} enrichments.`)
}
```
