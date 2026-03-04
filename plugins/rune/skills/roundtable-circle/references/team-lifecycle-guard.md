<!-- NOTE: This is a subset of the canonical version at ../../rune-orchestration/references/team-lifecycle-guard.md. Core patterns (Pre-Create Guard, Dynamic Cleanup, Cancel Pattern) are kept in sync; arc-specific sections are omitted. -->

# Team Lifecycle Guard — Safe TeamCreate/TeamDelete

Defensive patterns for Agent Teams lifecycle management. Prevents "Already leading team" and "Cannot cleanup team with N active members" errors. Every command that creates an Agent Team MUST follow these patterns.

## Problem

The Claude Agent SDK has two constraints:
1. **One team per lead** — `TeamCreate` fails if a previous team wasn't cleaned up
2. **TeamDelete requires deregistration** — agents may not deregister in time even after approving shutdown

Both are observed in production and cause workflow failures if not handled.

## Pre-Create Guard (teamTransition Protocol)

Before `TeamCreate`, safely transition from the current team to a new one using the
inlined teamTransition protocol. This replaces the previous 3-step escalation (v1.33.0).

```javascript
// teamTransition: Safely transition from current team to a new one.
// Contract:
//   Input:  newTeamName (string, pre-validated with /^[a-zA-Z0-9_-]+$/)
//   Effect: Current team destroyed, new team created, leadership transferred
//   Throws: If TeamCreate fails after all cleanup attempts
//
// MUST be inlined at every TeamCreate call site. No exceptions.
// This protocol replaces the previous 3-step escalation (v1.33.0).

// STEP 1: Validate (defense-in-depth — caller should also validate)
if (!/^[a-zA-Z0-9_-]+$/.test(newTeamName)) throw new Error(`Invalid team name: ${newTeamName}`)
if (newTeamName.includes('..')) throw new Error('Path traversal detected')

// STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
// Rationale: Members need time to finish current tool call and approve shutdown.
// 3s covers most cases; 8s covers complex file writes. Total max 11s wait.
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
  // rm -rf unconditionally — no exists() guard (eliminates TOCTOU window)
  // CHOME: Must use CLAUDE_CONFIG_DIR pattern for multi-account support
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${newTeamName}/" "$CHOME/tasks/${newTeamName}/" 2>/dev/null`)
  // Cross-workflow scan — clean ANY stale rune/arc team dirs
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" \) -exec rm -rf {} + && find "$CHOME/tasks/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" \) -exec rm -rf {} + 2>/dev/null`)
  // Retry TeamDelete after filesystem cleanup (SDK state may be unblocked now)
  try { TeamDelete() } catch (e2) { /* proceed to TeamCreate */ }
}

// STEP 4: TeamCreate with "Already leading" catch-and-recover
// Match: "Already leading" — centralized string match for SDK error detection
try {
  TeamCreate({ team_name: newTeamName })
} catch (createError) {
  if (/already leading/i.test(createError.message)) {
    warn(`teamTransition: Leadership state leak detected. Attempting final cleanup.`)
    try { TeamDelete() } catch (e) { /* exhausted */ }
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${newTeamName}/" "$CHOME/tasks/${newTeamName}/" 2>/dev/null`)
    // Final attempt — TOME-4 FIX: wrap in try/catch with actionable error message
    try {
      TeamCreate({ team_name: newTeamName })
    } catch (finalError) {
      throw new Error(`teamTransition failed: unable to create team after exhausting all cleanup strategies. Run /rune:rest --heal to manually clean up, then retry. (${finalError.message})`)
    }
  } else {
    throw createError
  }
}

// STEP 5: Post-create verification
// CHOME pattern for multi-account support
Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -f "$CHOME/teams/${newTeamName}/config.json" || echo "WARN: config.json not found after TeamCreate"`)
```

**Key safety properties:**
- Identifier validation and `rm -rf` are co-located (same code block)
- The regex `/^[a-zA-Z0-9_-]+$/` prevents shell metacharacters and path traversal
- The `..` check is redundant but provides defense-in-depth
- `TeamDelete` retries with backoff (0s, 3s, 8s) before filesystem fallback
- "Already leading" catch-and-recover handles SDK leadership state leaks
- Post-create verification confirms team directory was created
- All Bash commands resolve `CLAUDE_CONFIG_DIR` via `CHOME` — never hardcode `~/.claude`

**When to use**: Before EVERY `TeamCreate` call. No exceptions.

## Session Ownership

Team directories are tagged with session identity via `.session` marker files (TLC-004). This enables session-scoped stale detection and cross-session safety.

- **`.session` file**: Written by `stamp-team-session.sh` after TeamCreate. Contains raw `session_id`.
- **Ownership contract**: match=own, mismatch+live=skip, mismatch+dead=orphan, absent=legacy orphan.
- **State file fields**: `config_dir`, `owner_pid`, `session_id` — verified by cancel commands and hooks.

See canonical version at [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md) for the full Session Ownership contract.

## Centralized Hook Guards (TLC-001/002/003/004)

See canonical version at [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md) for full details.
Four hooks supplement the inlined teamTransition protocol: TLC-001 (PreToolUse:TeamCreate name validation + stale detection + advisory context injection), TLC-002 (PostToolUse:TeamDelete zombie check), TLC-003 (SessionStart:startup|resume orphan scan), TLC-004 (PostToolUse:TeamCreate session marker). Advisory-only for stale detection; hard block only for invalid team names.

## Cleanup Fallback

At session end, after shutting down all teammates:

> **DEPRECATED**: The static cleanup pattern (hardcoded teammate list) is superseded by the **Dynamic Cleanup with Member Discovery** pattern below. All new code MUST use the dynamic pattern. The static pattern is not shown here to prevent accidental copying — see git history for the old example if needed.

**Always use** the Dynamic Cleanup with Member Discovery pattern at EVERY workflow cleanup point — both normal completion and cancellation.

## Cancel Command Pattern

Cancel commands use the Dynamic Cleanup pattern (below) with broadcast + task cancellation prepended:

```javascript
// 1. Broadcast cancellation
SendMessage({ type: "broadcast", content: "Cancelled by user. Shutdown.", summary: "Cancelled" })

// 2. Cancel pending/in-progress tasks
tasks = TaskList()
for (const task of tasks) {
  if (task.status === "pending" || task.status === "in_progress") {
    TaskUpdate({ taskId: task.id, status: "deleted" })
  }
}

// 3. Dynamic member discovery + shutdown (see Dynamic Cleanup pattern below)
// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
let allMembers = []
try {
  const teamConfig = Read(`${CHOME}/teams/${team_name}/config.json`)
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  allMembers = [...fallbackList]
}
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Cancelled" })
}

// 4. Grace period — let teammates deregister (15s)
if (allMembers.length > 0) {
  Bash(`sleep 15`)
}

// 5. TeamDelete with retry-with-backoff (0s, 5s, 10s)
const CLEANUP_DELAYS = [0, 5000, 10000]
let cleanupTeamDeleteSucceeded = false
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {}
}
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamPrefix}-${identifier}/" "$CHOME/tasks/${teamPrefix}-${identifier}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}
```

## Dynamic Cleanup with Member Discovery

Static teammate lists in cleanup phases can miss dynamically-added members or leave "zombie" teammates running after cleanup completes. The solution: read the team's `config.json` at cleanup time to discover ALL active members, regardless of how many were spawned or what they're named.

### Why dynamic?

When a workflow spawns teammates, the set of active members may differ from what was originally planned:
- A teammate may have been added mid-workflow (e.g., extra workers spawned for load balancing)
- A teammate may have crashed and been replaced with a differently-named instance
- The orchestrator's local list may be stale after compaction or session resume

Hardcoding teammate names in cleanup logic creates a **zombie teammate problem** — members not in the static list survive shutdown and hold resources indefinitely. Dynamic discovery from `config.json` eliminates this class of bug.

### config.json Schema

The Agent SDK maintains a team config file at `$CHOME/teams/{team_name}/config.json` (where `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`):

```javascript
// $CHOME/teams/{team_name}/config.json (managed by Agent SDK)
{
  "team_name": "rune-review-abc123",
  "members": [
    { "name": "ash-iron-abc123", "status": "active" },
    { "name": "ash-silver-abc123", "status": "active" }
    // SDK excludes team-lead from members array
  ]
}
```

Key properties:
- `members` — array of all active teammate entries (team-lead is excluded by the SDK)
- Each member has a `name` field matching the name used in `SendMessage`
- The SDK maintains this file automatically as teammates are spawned/removed

### Dynamic Discovery Pattern

```javascript
// 1. Read team config to discover ALL active teammates
// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
let allMembers = []
try {
  const teamConfig = Read(`${CHOME}/teams/${team_name}/config.json`)
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
  // Defense-in-depth: SDK already excludes team-lead from config.members
} catch (e) {
  // FALLBACK: Config read failed — use known teammate list from command context
  // Each command provides its own fallback (e.g., allWorkers, allFixers, selectedAsh)
  allMembers = [...fallbackList]
}

// 2. Shutdown all discovered members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Workflow complete" })
}

// 3. Grace period — let teammates process shutdown_request and deregister
// Without this, TeamDelete fires before teammates approve shutdown → "active members" error.
// 15s covers most cases (teammate receives msg, processes, calls shutdown_response, SDK deregisters).
if (allMembers.length > 0) {
  Bash(`sleep 15`)
}

// 4. TeamDelete with retry-with-backoff (3 attempts: 0s, 5s, 10s)
// Total max wait: 15s grace + 0s + 5s + 10s = 30s (matches documented "max 30s")
// SEC-9 FIX: Re-validate team_name before rm -rf (defense-in-depth — team_name was read from config.json)
if (!/^[a-zA-Z0-9_-]+$/.test(team_name)) throw new Error(`Invalid team_name: ${team_name}`)

// Retry-with-backoff: 0s, 5s, 10s (15s total retry budget after 15s grace period)
const CLEANUP_DELAYS = [0, 5000, 10000]
let cleanupTeamDeleteSucceeded = false
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${team_name}/" "$CHOME/tasks/${team_name}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}
```

**When to use**: In ALL cleanup phases — both normal completion and cancellation — where the teammate list may not be statically known. This replaces iterating over a hardcoded array of teammate names.

## Team Completion Verification (Anti-Zombie Contract)

Every team lifecycle MUST end with this 4-step sequence. Skipping any step risks zombie state.

### Step 1: Dynamic Member Discovery
Read `$CHOME/teams/{team_name}/config.json` to get ALL members (Read() resolves CLAUDE_CONFIG_DIR automatically).
Do NOT rely on static lists — they miss dynamically-added teammates.

### Step 2: Shutdown All Members
```javascript
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Workflow complete" })
}
// Grace period: let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash(`sleep 15`)  // 15s grace + 15s retry budget = 30s max
}
```

### Step 3: TeamDelete (SDK state + filesystem)
```javascript
try { TeamDelete() } catch (e) {
  // Fallback: rm -rf (filesystem only — SDK state already cleared by TeamDelete attempt)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
}
```

### Step 4: Verify No Zombie State
```javascript
// Check that team directory is actually gone
// CHOME: Must use CLAUDE_CONFIG_DIR pattern for multi-account support
Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -d "$CHOME/teams/${teamName}/" && echo "WARN: Zombie team detected: ${teamName}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
```

### Critical ordering rules
1. `TeamDelete()` MUST run BEFORE `rm -rf` (SDK needs dirs to clear leadership)
2. `rm -rf` is the FALLBACK, never the primary cleanup path
3. In `prePhaseCleanup` (multi-team), `TeamDelete` runs ONCE first (own team), then `rm -rf` loop runs for all checkpoint teams (including foreign teams)
4. In pre-create guard, cross-workflow scan (`find`) cleans ALL stale rune/arc dirs — retry `TeamDelete()` after to clear SDK internal state

### Existing Implementations

The cancel commands already use this dynamic discovery pattern:
- `cancel-review.md` — reads `$CHOME/teams/${team_name}/config.json`, iterates `config.members`
- `cancel-audit.md` — same pattern as cancel-review
- `cancel-arc.md` — reads `$CHOME/teams/${phase_team}/config.json`, iterates `teamConfig.members`

These serve as canonical examples of the pattern. All new cleanup logic should follow the same approach.

## Input Validation

Validate team names before interpolating into `rm -rf` commands.

```javascript
// Validate team_name matches safe pattern (alphanumeric, hyphens, underscores only)
if (!/^[a-zA-Z0-9_-]+$/.test(team_name)) {
  throw new Error(`Invalid team_name: ${team_name}`)
}
```

For commands where `team_name` is hardcoded with a known-safe prefix (e.g., `rune-review-{timestamp}`), the risk is low since the prefix anchors the path. For cancel commands where `team_name` is read from a state file, validation is **required** since the state file could be tampered with.

## Team Naming Conventions

| Command | Team Prefix | Identifier Source |
|---------|------------|-------------------|
| `/rune:appraise` | `rune-review` | `{identifier}` (git hash or user-provided) |
| `/rune:audit` | `rune-audit` | `{identifier}` |
| `/rune:devise` | `rune-plan` | `{timestamp}` (YYYYMMDD-HHMMSS) |
| `/rune:strive` | `rune-work` | `{timestamp}` |
| `/rune:mend` | `rune-mend` | `{id}` (from TOME path or generated) |
| `/rune:forge` | `rune-forge` | `{id}` |
| `/rune:arc` (plan review) | `arc-plan-review` | `{id}` (arc session id) |
| `/rune:arc` (delegated) | per sub-command | per sub-command |

## Arc Phase Teams

| Phase | Team Owner | Lifecycle |
|-------|-----------|-----------|
| Phase 1: FORGE | `/rune:forge` (delegated) | Forge manages own lifecycle |
| Phase 2: PLAN REVIEW | Arc orchestrator | `arc-plan-review-{id}` |
| Phase 2.5: REFINE | Orchestrator-only (no team) | N/A |
| Phase 2.7: VERIFY | Orchestrator-only (no team) | N/A |
| Phase 5: WORK | `/rune:strive` (delegated) | Work manages own lifecycle |
| Phase 5.5: GAP ANALYSIS | Orchestrator-only (no team) | N/A |
| Phase 6: REVIEW | `/rune:appraise` (delegated) | Review manages own lifecycle |
| Phase 7: MEND | `/rune:mend` (delegated) | Mend manages own lifecycle |
| Phase 7.5: VERIFY MEND | Orchestrator-only (no team) | N/A |

## Consumers

All multi-agent commands: plan.md, work.md, arc SKILL.md, mend.md, review.md, audit.md, forge.md, cancel-review.md, cancel-audit.md, cancel-arc.md, research-phase.md

## Notes

- The filesystem fallback (`rm -rf $CHOME/teams/...`) is safe — these directories only contain Agent SDK coordination state, not user data
- For additional defense-in-depth, commands that delete user-facing directories (e.g., `/rune:rest`) should use `realpath` containment checks in addition to team name validation
- Do not interpolate unsanitized external input into team names — validate first
- Always update workflow state files (e.g., `tmp/.rune-review-{id}.json`) AFTER team cleanup, not before
- The 30s wait budget is: 15s grace period (sleep) + 15s retry-with-backoff (0s + 5s + 10s). Some agents may need longer for complex file writes — the filesystem fallback handles this
- Arc pipelines call TeamCreate/TeamDelete per-phase, so each phase transition needs the pre-create guard

## CDX-7 Crash Recovery (Cross-Reference)

For crash recovery patterns (CDX-7), including `safeTeamCleanup()`, `isStale()`, and the three-layer orphan defense, see the canonical version at `plugins/rune/skills/rune-orchestration/references/team-lifecycle-guard.md`.
