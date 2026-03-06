# Phase 7: Cleanup

Standard 5-component team cleanup for goldmask with session-specific state file removal.

```javascript
// 1. Dynamic member discovery with hardcoded fallback
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${session_id}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: hardcoded list of all 8 goldmask teammates
  allMembers = [
    "lore-analyst",
    "data-layer-tracer",
    "api-contract-tracer",
    "business-logic-tracer",
    "event-message-tracer",
    "config-dependency-tracer",
    "wisdom-sage",
    "goldmask-coordinator"
  ]
}

// 2. Shutdown all teammates
for (const member of allMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Goldmask complete" }) } catch (e) { /* member may have already exited */ }
}

// 3. Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) { Bash("sleep 20") }

// SEC-5: Validate session_id before rm-rf (project convention)
if (!/^[a-zA-Z0-9_-]+$/.test(session_id)) { error("Invalid session_id"); return }

// 4. TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`goldmask cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5a. Process-level kill — terminate orphaned teammate processes
if (!cleanupTeamDeleteSucceeded) {
  const ownerPid = Bash(`echo $PPID`).trim()
  if (ownerPid && /^\d+$/.test(ownerPid)) {
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
    Bash(`sleep 3`)
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  }
}

// 5b. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${session_id}/" "$CHOME/tasks/${session_id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// 6. Clean up state file
Bash(`rm -f "tmp/.rune-goldmask-${session_id}.json" 2>/dev/null`)

// 7. Release workflow lock
Bash(`CWD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && source "\${CWD}/plugins/rune/scripts/lib/workflow-lock.sh" && rune_release_lock "goldmask"`)
```
