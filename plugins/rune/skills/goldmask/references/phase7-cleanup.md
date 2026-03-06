# Phase 7: Cleanup

Standard 5-component team cleanup for goldmask with session-specific state file removal.

```
# Dynamic member discovery with hardcoded fallback
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

# Shutdown all teammates
for (const member of allMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Goldmask complete" }) } catch (e) { /* member may have already exited */ }
}

# Grace period — let teammates deregister before TeamDelete
sleep 20

# SEC-5: Validate session_id before rm-rf (project convention)
if (!/^[a-zA-Z0-9_-]+$/.test(session_id)) { error("Invalid session_id"); return }

# TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
CLEANUP_DELAYS=(0 5 10 15)
cleanupTeamDeleteSucceeded=false
for delay in "${CLEANUP_DELAYS[@]}"; do
    [ "$delay" -gt 0 ] && sleep "$delay"
    if TeamDelete("{session_id}"); then cleanupTeamDeleteSucceeded=true; break; fi
done

# Process-level kill — terminate orphaned teammate processes (step 5a)
if [ "$cleanupTeamDeleteSucceeded" = false ]; then
    ownerPid=$PPID
    if [ -n "$ownerPid" ]; then
        for pid in $(pgrep -P "$ownerPid" 2>/dev/null); do
            case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac
        done
        sleep 3
        for pid in $(pgrep -P "$ownerPid" 2>/dev/null); do
            case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac
        done
    fi
fi
# Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if [ "$cleanupTeamDeleteSucceeded" = false ]; then
    CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    rm -rf "$CHOME/teams/${session_id}" "$CHOME/tasks/${session_id}" 2>/dev/null
    TeamDelete("{session_id}") 2>/dev/null || true  # best effort — clear SDK leadership state
fi

# Clean up state file
rm -f "tmp/.rune-goldmask-${session_id}.json" 2>/dev/null

# Release workflow lock
CWD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
source "${CWD}/plugins/rune/scripts/lib/workflow-lock.sh"
rune_release_lock "goldmask"
```
