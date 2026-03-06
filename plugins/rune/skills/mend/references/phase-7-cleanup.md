# Phase 7: CLEANUP

1. **Dynamic member discovery** — read team config for ALL teammates (fallback: `spawnedFixerNames` from Phase 3 — includes wave-based names like `mend-fixer-w1-1`)
2. **Shutdown all members** — `SendMessage(shutdown_request)` to each
3. **Grace period** — `sleep 20` for teammate deregistration
4. **ID validation** — defense-in-depth `..` check + regex guard (SEC-003)
5. **TeamDelete with retry-with-backoff** (4 attempts: 0s, 5s, 10s, 15s) + process kill + filesystem fallback
6. **Update state file** — status → `"completed"` or `"partial"`
7. **Release workflow lock** — `rune_release_lock "mend"`
8. **Persist learnings** to Rune Echoes (TRACED layer)

```javascript
// 1. Dynamic member discovery — read team config for ALL teammates
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
let allMembers = []
try {
  const teamConfig = Read(`${CHOME}/teams/rune-mend-${id}/config.json`)
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: config.json read failed — use spawnedFixerNames from Phase 3.
  // This includes wave-based names (mend-fixer-w1-1, mend-fixer-w2-3, etc.),
  // not just base inscription names (mend-fixer-1, mend-fixer-2).
  allMembers = [...spawnedFixerNames]
}

// 2. Shutdown all discovered members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Mend complete" })
}

// 3. Grace period — let teammates deregister
if (allMembers.length > 0) {
  Bash("sleep 20")
}

// 4. TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error(`Invalid mend id: ${id}`)
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
let cleanupTeamDeleteSucceeded = false
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
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
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-mend-${id}/" "$CHOME/tasks/rune-mend-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// 7. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "mend"`)
```

See [engines.md](../../team-sdk/references/engines.md) § cleanup for full cleanup retry pattern.
