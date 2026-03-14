# Phase 4: Cleanup

Standard 5-component team cleanup for design-sync workflow.

```javascript
// Step 1: Generate completion report
Write("{workDir}/report.md", completionReport)

// Step 2: Persist echoes
// Write design patterns learned to .claude/echoes/

// Step 3: Shutdown workers — dynamic member discovery with fallback
const teamName = `rune-design-sync-${timestamp}`
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // Fallback: known workers across all design-sync phases (max counts from talisman defaults)
  // Phase 1 (extraction): design-syncer-1, design-syncer-2
  // Phase 2 (implementation): rune-smith-1, rune-smith-2, rune-smith-3
  // Phase 3 (iteration): design-iter-1, design-iter-2, design-reviewer-1
  allMembers = ["design-syncer-1", "design-syncer-2",
    "rune-smith-1", "rune-smith-2", "rune-smith-3",
    "design-iter-1", "design-iter-2", "design-reviewer-1"]
}

for (const member of allMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Design sync complete" }) } catch (e) { /* member may have already exited */ }
}

// Grace period for shutdown acknowledgment
if (allMembers.length > 0) { Bash("sleep 20") }

// Step 4: Cleanup team — TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-sync cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
// Process-level kill — terminate orphaned teammate processes (step 5a)
if (!cleanupTeamDeleteSucceeded) {
  const ownerPid = Bash(`echo $PPID`).trim()
  if (ownerPid && /^\d+$/.test(ownerPid)) {
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
    Bash(`sleep 5`)
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  }
}
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// Step 5: Update state
updateState({ status: "completed", phase: "cleanup", fidelity_score: overallScore })

// Step 6: Report to user
"Design sync complete. Fidelity: {score}/100. Report: {workDir}/report.md"
```
