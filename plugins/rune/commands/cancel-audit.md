---
name: rune:cancel-audit
description: |
  Cancel an active Roundtable Circle audit and gracefully shutdown all Ash teammates.
  Partial results remain in tmp/audit/ for manual inspection.

  <example>
  user: "/rune:cancel-audit"
  assistant: "The Tarnished dismisses the audit Circle..."
  </example>
user-invocable: true
allowed-tools:
  - TaskList
  - TaskUpdate
  - TaskGet
  - TeamDelete
  - SendMessage
  - Read
  - Write
  - Bash
  - Glob
  - AskUserQuestion
---

# /rune:cancel-audit — Cancel Active Audit

Cancel an active Roundtable Circle audit and gracefully shutdown all teammates.

## Steps

### 1. Find Active Audit

```bash
# Find active audit state files, most recent first
# (deep audits now use same state file prefix — depth is a parameter, not a separate workflow)
ls -t tmp/.rune-audit-*.json 2>/dev/null
```

If no state files found: "No active audit to cancel."

### 2. Select & Read State

Read each state file and filter to active ones. If multiple active audits exist, let the user choose which to cancel:

```javascript
// Read each state file, find active ones
// ── Resolve session identity for ownership check ──
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

const activeStates = stateFiles
  .map(f => ({ path: f, state: Read(f) }))
  .filter(s => s.state.status === "active")
  .map(s => {
    // ── Ownership detection: warn if this belongs to another session ──
    const isForeign = (s.state.config_dir && s.state.config_dir !== configDir) ||
      (s.state.owner_pid && /^\d+$/.test(s.state.owner_pid) && s.state.owner_pid !== ownerPid &&
       Bash(`kill -0 ${s.state.owner_pid} 2>/dev/null && echo alive`).trim() === "alive")
    return { ...s, isForeign }
  })
  .sort((a, b) => new Date(b.state.started) - new Date(a.state.started))

if (activeStates.length === 0) {
  return "No active audit to cancel."
}

let state, identifier, team_name

if (activeStates.length === 1) {
  // Single active audit — auto-select
  state = activeStates[0].state
  identifier = state.team_name.replace("rune-audit-", "")
  if (!/^[a-zA-Z0-9_-]+$/.test(identifier)) { warn("Invalid derived identifier: " + identifier); return }
  team_name = state.team_name
} else {
  // Multiple active — ask user which to cancel
  const choice = AskUserQuestion({
    questions: [{
      question: `Multiple active audits found (${activeStates.length}). Which to cancel?`,
      header: "Session",
      options: activeStates.map(s => ({
        label: s.state.team_name,
        description: `Started: ${s.state.started}, Files: ${s.state.expected_files?.length || '?'}`
      })),
      multiSelect: false
    }]
  })
  const selected = activeStates.find(s => s.state.team_name === choice)
  state = selected.state
  identifier = state.team_name.replace("rune-audit-", "")
  if (!/^[a-zA-Z0-9_-]+$/.test(identifier)) { warn("Invalid derived identifier: " + identifier); return }
  team_name = state.team_name
}

// QUAL-005 FIX: Null guard for team_name (matches cancel-arc.md pattern)
if (!team_name) { warn("No team_name in state file — cannot cancel."); return }

// ── Foreign session warning (warn, don't block) ──
const target = activeStates.find(s => s.state.team_name === team_name) || activeStates[0]
if (target?.isForeign) {
  warn(`WARNING: This audit (${team_name}) appears to belong to another active session (PID: ${target.state.owner_pid}). Cancelling may disrupt that session's workflow. Proceeding anyway.`)
}
```

### 3. Broadcast Cancellation

```javascript
SendMessage({
  type: "broadcast",
  content: "Audit cancelled by user. Please finish current file and shutdown.",
  summary: "Audit cancelled"
})
```

### 4. Shutdown All Teammates

```javascript
// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// Read team config to get member list — with fallback if config is missing/corrupt
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${team_name}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: all possible audit agents (safe to send shutdown to absent members)
  allMembers = ["forge-warden", "ward-sentinel", "pattern-weaver", "veil-piercer",
    "glyph-scribe", "knowledge-keeper", "codex-oracle", "runebinder", "doubt-seer",
    "rot-seeker", "strand-tracer", "decree-auditor", "fringe-watcher",
    "runebinder-deep", "runebinder-merge", "cross-shard-sentinel",
    "elicitation-sage-security-1", "elicitation-sage-security-2"]
}

for (const member of allMembers) {
  SendMessage({
    type: "shutdown_request",
    recipient: member,
    content: "Audit cancelled by user"
  })
}
```

### 5. Grace Period (20s)

Let teammates process shutdown_request and deregister before TeamDelete.

```javascript
if (allMembers.length > 0) {
  Bash(`sleep 20`, { run_in_background: true })
}
```

### 6. Cleanup

```javascript
// Delete team with retry-with-backoff + CHOME fallback (see team-sdk/references/engines.md)
// Validate team_name before shell interpolation
if (!/^[a-zA-Z0-9_-]+$/.test(team_name)) throw new Error("Invalid team_name")
// TeamDelete with retry-with-backoff (4 attempts: 0s, 3s, 6s, 10s)
const RETRY_DELAYS = [0, 3000, 6000, 10000]
let cleanupTeamDeleteSucceeded = false
for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
  if (attempt > 0) {
    warn(`Cancel cleanup: TeamDelete attempt ${attempt + 1} failed, retrying in ${RETRY_DELAYS[attempt]/1000}s...`)
    Bash(`sleep ${RETRY_DELAYS[attempt] / 1000}`)
  }
  try {
    TeamDelete()
    cleanupTeamDeleteSucceeded = true
    break
  } catch (e) {
    if (attempt === RETRY_DELAYS.length - 1) {
      warn(`Cancel cleanup: TeamDelete failed after ${RETRY_DELAYS.length} attempts. Using filesystem fallback.`)
    }
  }
}
// Process-level kill — terminate orphaned teammate processes (step 5a)
if (!cleanupTeamDeleteSucceeded) {
  const ownerPid = Bash(`echo $PPID`).trim()
  if (ownerPid && /^\d+$/.test(ownerPid)) {
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
    Bash(`sleep 3`, { run_in_background: true })
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  }
}
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
// Clean main team + any wave-suffixed teams
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${team_name}/" "$CHOME/tasks/${team_name}/" 2>/dev/null`)
  // Clean wave-suffixed teams (deep audits use rune-audit-{id}-w2, -w3, etc.)
  // Wave 1 uses the base team name; waves 2+ get -wN suffix
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && for n in 2 3 4; do rm -rf "$CHOME/teams/${team_name}-w${n}/" "$CHOME/tasks/${team_name}-w${n}/" 2>/dev/null; done`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// NOTE: identifier is derived from team_name via .replace("rune-audit-", "").
// The team_name regex guard above implicitly validates identifier (it's a substring).

// Update state file
Write("tmp/.rune-audit-{identifier}.json", {
  ...state,
  status: "cancelled",
  cancelled_at: new Date().toISOString()
})

// Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "audit"`)
```

### 7. Report

```
Audit cancelled.

Partial results (if any) remain in: tmp/audit/{identifier}/
- {list of files that were written before cancellation}

To re-run: /rune:audit
```

## Notes

- Partial results are NOT deleted — they remain for manual inspection
- State file is updated to "cancelled" to prevent conflicts
- Team resources are fully cleaned up
- Wave-suffixed teams (`rune-audit-{id}-w2`, `-w3`, `-w4`) are cleaned up alongside the main team
