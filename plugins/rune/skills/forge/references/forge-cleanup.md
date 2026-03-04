# Phase 6: Cleanup & Present

Shuts down all forge teammates, cleans up team resources, updates state file, presents completion report, and offers post-enhancement options.

**Inputs**: `timestamp`, `planPath`, `startedTimestamp`, `configDir`, `ownerPid`, `isArcContext`, `allMembers` (from team config)
**Outputs**: Updated state file (status: "completed"), completion report
**Preconditions**: Phase 5 (merge enrichments) complete

```javascript
// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// 1. Dynamic member discovery — reads team config to find ALL teammates
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/rune-forge-${timestamp}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  allMembers = []  // Team config unavailable — no members to shutdown
}

// Shutdown all discovered members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Forge workflow complete" })
}

// Grace period — let teammates process shutdown_request and deregister.
// Without this sleep, TeamDelete fires immediately → "active members" error → filesystem fallback.
if (allMembers.length > 0) {
  Bash(`sleep 15`)
}

// Validate identifier before rm -rf
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid forge identifier")

// Cleanup team with retry-with-backoff (3 attempts: 0s, 5s, 10s)
// Total budget: 15s grace + 15s retry = 30s max
const CLEANUP_DELAYS = [0, 5000, 10000]
let cleanupTeamDeleteSucceeded = false
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`forge cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-forge-${timestamp}/" "$CHOME/tasks/rune-forge-${timestamp}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// Update state file to completed (preserve session identity)
Write(`tmp/.rune-forge-${timestamp}.json`, {
  team_name: `rune-forge-${timestamp}`,
  plan: planPath,
  started: startedTimestamp,
  status: "completed",
  completed: new Date().toISOString(),
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}"
})
```

## Completion Report

```
The Tarnished has tempered the plan in forge fire.

Plan: {planPath}
Backup: tmp/forge/{timestamp}/original-plan.md
Sections enriched: {enrichedCount}/{totalSections}
Agents summoned: {agentCount}
Mode: {default|exhaustive}

Enrichments added:
- "Technical Approach" — rune-architect, pattern-seer, simplicity-warden
- "Security Requirements" — ward-sentinel, flaw-hunter
- ...
```

## Post-Enhancement Options

After presenting the completion report, offer next steps. **Skipped in arc context** — arc continues to Phase 2 (plan review) automatically.

```javascript
if (!isArcContext) {
  AskUserQuestion({
    questions: [{
      question: `Plan enriched at ${planPath}. What would you like to do next?`,
      header: "Next step",
      options: [
        { label: "/rune:strive (Recommended)", description: "Start implementing this plan with swarm workers" },
        { label: "View diff", description: "Show what the forge changed (diff against backup)" },
        { label: "Revert enrichment", description: "Restore the original plan from backup" },
        { label: "Deepen sections", description: "Re-run forge on specific sections for more depth" }
      ],
      multiSelect: false
    }]
  })
}
// In arc context: cleanup team and return — arc orchestrator handles next phase
```

**Action handlers**:
- `/rune:strive` → Invoke `Skill("rune:strive", planPath)`
- **View diff** → `Bash(\`diff -u "tmp/forge/{timestamp}/original-plan.md" "${planPath}" || true\`)` — display unified diff of all changes
- **Revert enrichment** → `Bash(\`cp "tmp/forge/{timestamp}/original-plan.md" "${planPath}"\`)` — restore original, confirm to user
- **Deepen sections** → Ask which sections to re-deepen via AskUserQuestion, then re-run Phase 2-5 targeting only those sections (reuse same `timestamp` and backup)
