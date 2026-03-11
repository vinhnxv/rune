# Phase -1: Team Bootstrap

Create the Agent Team before any agents spawn. This ensures Phase 0 agents (elicitation sages, design-pipeline-agent) can join the team and comply with ATE-1 enforcement.

```javascript
// teamTransition protocol — moved from research-phase.md to run before Phase 0
// STEP 1: Validate (defense-in-depth)
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid plan identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected in plan identifier')

// STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
let teamDeleteSucceeded = false
const RETRY_DELAYS = [0, 3000, 8000]
for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
  if (attempt > 0) {
    warn(`teamTransition: TeamDelete attempt ${attempt + 1} failed, retrying in ${RETRY_DELAYS[attempt]/1000}s...`)
    Bash(`sleep ${RETRY_DELAYS[attempt] / 1000}`)
  }
  try {
    TeamDelete()
    teamDeleteSucceeded = true
    break
  } catch (e) {
    if (attempt === RETRY_DELAYS.length - 1) {
      warn(`teamTransition: TeamDelete failed after ${RETRY_DELAYS.length} attempts. Using filesystem fallback.`)
    }
  }
}

// STEP 3: Filesystem fallback (only when STEP 2 failed — avoids blast radius on happy path)
// CDX-003 FIX: Gate behind !teamDeleteSucceeded to prevent cross-workflow scan from
// wiping concurrent workflows when TeamDelete already succeeded cleanly.
if (!teamDeleteSucceeded) {
  // Scoped cleanup — only remove THIS session's team/task dirs (not all rune-*/arc-*)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-plan-${timestamp}/" "$CHOME/tasks/rune-plan-${timestamp}/" 2>/dev/null`)
  try { TeamDelete() } catch (e2) { /* proceed to TeamCreate */ }
}

// STEP 4: TeamCreate with "Already leading" catch-and-recover
// Match: "Already leading" — centralized string match for SDK error detection
try {
  TeamCreate({ team_name: "rune-plan-{timestamp}" })
} catch (createError) {
  if (/already leading/i.test(createError.message)) {
    warn(`teamTransition: Leadership state leak detected. Attempting final cleanup.`)
    try { TeamDelete() } catch (e) { /* exhausted */ }
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-plan-${timestamp}/" "$CHOME/tasks/rune-plan-${timestamp}/" 2>/dev/null`)
    try {
      TeamCreate({ team_name: "rune-plan-{timestamp}" })
    } catch (finalError) {
      throw new Error(`teamTransition failed: unable to create team after exhausting all cleanup strategies. Run /rune:rest --heal to manually clean up, then retry. (${finalError.message})`)
    }
  } else {
    throw createError
  }
}

// STEP 5: Post-create verification
Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -f "$CHOME/teams/rune-plan-${timestamp}/config.json" || echo "WARN: config.json not found after TeamCreate"`)

// STEP 6: Write workflow state file with session isolation fields
// CRITICAL: This state file activates the ATE-1 hook (enforce-teams.sh) which blocks
// bare Agent calls without team_name. Without this file, agents spawn as local subagents
// instead of Agent Team teammates, causing context explosion.
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write(`tmp/.rune-plan-${timestamp}.json`, {
  team_name: `rune-plan-${timestamp}`,
  started: new Date().toISOString(),
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  feature: feature
})
```
