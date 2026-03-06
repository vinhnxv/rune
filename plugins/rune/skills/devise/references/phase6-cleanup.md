# Phase 6: Cleanup & Present

Standard 5-component team cleanup with devise-specific member discovery fallback.

```javascript
// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// 1. Dynamic member discovery — reads team config to find ALL teammates
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/rune-plan-${timestamp}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: known teammates across all devise phases (some are conditional — safe to send shutdown to absent members)
  allMembers = [
    // Phase 0: Brainstorm
    "elicitation-sage-1", "elicitation-sage-2", "elicitation-sage-3",
    "design-inventory-agent",
    // Phase 0.3: UX Research (conditional — ux.enabled)
    "ux-pattern-analyzer",
    // Phase 1A: Local Research
    "repo-surveyor", "echo-reader", "git-miner",
    // Phase 1C: External Research (conditional)
    "practice-seeker", "lore-scholar", "codex-researcher",
    // Phase 1C.5: Research Verification (conditional)
    "research-verifier",
    // Phase 1D: Spec Validation
    "flow-seer",
    // Phase 1.8: Solution Arena (conditional)
    "devils-advocate", "innovation-scout", "codex-arena-judge",
    // Phase 2.3: Predictive Goldmask (conditional, 2-8 agents)
    "devise-lore", "devise-wisdom", "devise-business", "devise-data", "devise-api", "devise-coordinator",
    // Phase 4A: Scroll Review
    "scroll-reviewer",
    // Phase 4C: Technical Review (conditional)
    "decree-arbiter", "knowledge-keeper", "veil-piercer-plan",
    "horizon-sage", "evidence-verifier", "state-weaver", "doubt-seer", "codex-plan-reviewer",
    "elicitation-sage-review-1", "elicitation-sage-review-2", "elicitation-sage-review-3"
  ]
}

// Shutdown all discovered members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Planning workflow complete" })
}

// 2. Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash(`sleep 20`)
}

// 2.5. Mark state file as completed (deactivates ATE-1 enforcement for this workflow)
try {
  const stateFile = `tmp/.rune-plan-${timestamp}.json`
  const state = JSON.parse(Read(stateFile))
  Write(stateFile, { ...state, status: "completed" })
} catch (e) { /* non-blocking — state file may already be cleaned */ }

// 3. Cleanup team — QUAL-004: retry-with-backoff
// CRITICAL: Validate timestamp (/^[a-zA-Z0-9_-]+$/) before rm -rf — path traversal guard
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid plan identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected')
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`plan cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
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
// QUAL-012: Filesystem fallback ONLY when TeamDelete failed
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-plan-${timestamp}/" "$CHOME/tasks/rune-plan-${timestamp}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// 3.5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "devise"`)

// 4. Present plan to user
Read("plans/YYYY-MM-DD-{type}-{feature-name}-plan.md")
```
