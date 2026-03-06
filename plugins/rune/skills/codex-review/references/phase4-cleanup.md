# Phase 4: Cleanup

Standard 5-component team cleanup for codex-review.

```javascript
// Remove readonly marker (review complete)
Bash(`rm -f tmp/.rune-signals/${teamName}/.readonly-active`)

// Dynamic member discovery — reads team config to find ALL teammates
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = Read(`${CHOME}/teams/${teamName}/config.json`)
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: all possible Claude + Codex agents (safe to send shutdown to absent members)
  allMembers = ["claude-security-reviewer", "claude-bug-hunter", "claude-quality-analyzer",
    "claude-dead-code-finder", "claude-performance-analyzer",
    "codex-security", "codex-bugs", "codex-quality", "codex-performance"]
}

// Shutdown all discovered members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Codex review complete" })
}

// Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash(`sleep 20`)
}

// TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`codex-review cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
// Process-level kill — terminate orphaned teammate processes (step 5a)
if (!cleanupTeamDeleteSucceeded) {
  const ownerPid = Bash(`echo $PPID`).trim()
  if (ownerPid && /^\d+$/.test(ownerPid)) {
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
    Bash(`sleep 3`)
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  }
}
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// Update state file
updateStateFile(identifier, { phase: "completed", status: "completed" })
```
