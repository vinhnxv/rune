---
name: team-sdk
description: |
  Centralized team management SDK for Rune workflows. Provides ExecutionEngine
  interface (TeamEngine), shared lifecycle protocols (teamTransition, cleanup,
  session isolation), preset system, and monitoring utilities.
  Use when spawning agent teams, monitoring teammates, or cleaning up workflows.
  Loaded automatically by workflow skills (appraise, strive, devise, mend, etc).
  Keywords: team management, team lifecycle, teamTransition, cleanup, agent teams,
  TeamCreate, TeamDelete, spawnAgent, shutdown, wave execution.
user-invocable: false
disable-model-invocation: false
---

# Team Management SDK

Centralizes Agent Team lifecycle operations that are currently duplicated across 11+ workflow skills (~900 lines of shared patterns). Provides a single ExecutionEngine interface with 10 methods covering the full team lifecycle: creation, idempotent bootstrap, agent spawning, monitoring, shutdown, and cleanup.

**Load skills**: `chome-pattern`, `polling-guard`, `zsh-compat`

## Why This Exists

Every Rune workflow that uses Agent Teams (strive, devise, mend, appraise, audit, forge, arc, inspect, etc.) independently implements the same patterns:

- **teamTransition** (6-step pre-create guard): ~45 lines duplicated per skill
- **Dynamic cleanup** (5-component shutdown): ~40 lines duplicated per skill
- **Session isolation** (state file with config_dir/owner_pid/session_id): ~15 lines duplicated
- **Monitoring** (waitForCompletion polling loop): referenced but configured per-skill

This SDK extracts those patterns into a single reference. Workflow skills call SDK methods instead of inlining the full protocol. Inline cleanup fallbacks are retained in each skill for resilience — if the SDK skill is not loaded during compaction recovery, cleanup still works.

## One-Team-Per-Lead Constraint

The Claude Agent SDK enforces a strict one-team-per-lead constraint: a session can only lead one team at a time. `TeamCreate` fails with "Already leading team" if a previous team was not cleaned up. The teamTransition protocol (Step 4 catch-and-recover) handles this transparently.

**Implication**: Workflows that need multiple teams (e.g., arc phases) must create and destroy teams sequentially — never concurrently.

## Iron Law -- NO AGENTS WITHOUT TEAM (TEAM-001)

> **This rule is absolute. No exceptions.**
>
> Every `Agent()` call in a Rune workflow MUST include `team_name`.
> Every `team_name` MUST reference a team created via `TeamEngine.createTeam()` or `TeamEngine.ensureTeam()`.
>
> If you find yourself spawning agents without calling createTeam() first, STOP.
> The enforce-teams.sh hook (ATE-1) will block bare Agent() calls, but
> prevention is better than correction.
>
> **Preferred pattern**: Use `ensureTeam()` which is idempotent -- safe to call
> even if a team already exists. When in doubt, call ensureTeam().

### Rationalization Red Flags

| Rationalization | Why It's Wrong |
|----------------|----------------|
| "Just one agent, no need for a team" | One bare agent causes context explosion. ATE-1 exists for a reason. |
| "TeamCreate is slow, skip it" | TeamCreate takes <1s. Context explosion recovery takes minutes. |
| "The state file isn't important" | Without the state file, ATE-1 hook cannot protect subsequent Agent calls. |
| "I'll create the team after spawning" | Agents spawned before TeamCreate run as plain subagents. Order matters. |

## ExecutionEngine Interface

All team lifecycle operations go through this interface. Currently only `TeamEngine` implements it (see [engines.md](references/engines.md)). `resolveEngine()` always returns `TeamEngine`.

### Method Signatures

```
ExecutionEngine {
  createTeam(config)      → TeamHandle
  ensureTeam(config)      → TeamHandle
  spawnAgent(handle, spec) → AgentRef
  spawnWave(handle, specs) → AgentRef[]
  shutdownWave(handle)     → void
  monitor(handle, opts)    → MonitorResult
  sendMessage(handle, msg) → void
  shutdown(handle)         → void
  cleanup(handle)          → void
  getStatus(handle)        → TeamStatus
}
```

### Method Contracts

#### createTeam(config) -> TeamHandle

Creates a new Agent Team using the 6-step teamTransition protocol. Returns a TeamHandle for use in subsequent calls.

```
config: {
  teamName:    string       // e.g., "rune-work-20260305-143022"
  workflow:    string       // e.g., "strive", "devise", "mend"
  identifier:  string       // Timestamp or hash for state file naming
  stateFilePrefix: string   // e.g., "tmp/.rune-work"
  metadata:    object       // Workflow-specific fields (plan path, feature name, etc.)
}

TeamHandle: {
  teamName:    string
  workflow:    string
  identifier:  string
  configDir:   string       // Resolved CLAUDE_CONFIG_DIR
  ownerPid:    string       // $PPID
  sessionId:   string       // CLAUDE_SESSION_ID
  stateFile:   string       // Path to state JSON
  createdAt:   string       // ISO-8601 timestamp
}
```

**Protocol**: Executes the full teamTransition (6 steps):
1. Validate identifier (`/^[a-zA-Z0-9_-]+$/`, no `..`)
2. TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
3. Filesystem fallback (only when step 2 failed — QUAL-012)
4. TeamCreate with "Already leading" catch-and-recover
5. Post-create verification (config.json exists)
6. Write state file with session isolation fields

See [engines.md](references/engines.md) for full implementation.

#### ensureTeam(config) -> TeamHandle

Idempotent team creation — safe to call multiple times. If the team already exists AND belongs to the current session, returns a recovered handle. If the team doesn't exist or belongs to a different session, calls `createTeam()`. Recommended for compaction recovery and auto-bootstrap patterns.

Same `config` input as `createTeam()`. See [engines.md](references/engines.md) for full implementation.

#### spawnAgent(handle, spec) -> AgentRef

Spawns a single teammate into the existing team. Creates a task via `TaskCreate`, then spawns via `Agent` with `team_name` (ATE-1 compliant). Accepts either a TeamHandle (from createTeam/ensureTeam) or a config object for auto-bootstrap (calls ensureTeam internally).

```
spec: {
  name:        string       // Agent name (e.g., "rune-smith-1")
  prompt:      string       // Full agent prompt
  taskSubject: string       // TaskCreate subject
  taskDescription: string   // TaskCreate description (optional)
  activeForm:  string       // Present continuous for spinner
  tools:       string[]     // Tool allowlist (optional)
  maxTurns:    number       // Safety cap (optional, default from category)
  metadata:    object       // Task metadata (optional)
}

AgentRef: {
  name:        string
  taskId:      string
  spawnedAt:   number       // Date.now() timestamp
}
```

**Key rule**: Always use `subagent_type: "general-purpose"` — never `"explore"` or `"plan"` for teammates.

#### spawnWave(handle, specs) -> AgentRef[]

Batch spawns multiple agents for wave-based execution. Calls `spawnAgent` for each spec in parallel. Returns array of AgentRefs for monitoring. Accepts either a TeamHandle (from createTeam/ensureTeam) or a config object for auto-bootstrap (calls ensureTeam internally).

```
specs: AgentSpec[]          // Array of spawnAgent specs
```

Used by strive (worker waves) and mend (fixer waves).

#### shutdownWave(handle) -> void

Shuts down the current wave's agents without tearing down the team. Used between waves when the team persists across multiple wave cycles.

1. Read team config to discover current members
2. Send `shutdown_request` to all wave members
3. Grace period (15s)
4. Delete completed tasks (prepare task pool for next wave)

Does NOT call TeamDelete — the team continues for the next wave.

#### monitor(handle, opts) -> MonitorResult

Polls TaskList with configurable timeouts and stale detection. Wraps the shared `waitForCompletion` utility.

```
opts: {
  timeoutMs:      number    // Total timeout (default: varies by workflow)
  staleWarnMs:    number    // Warn threshold (default: 300_000 — 5 min)
  autoReleaseMs:  number    // Auto-release threshold (optional)
  pollIntervalMs: number    // Poll interval (default: 30_000 — 30s)
  label:          string    // Display label (e.g., "Work", "Review")
  taskFilter:     function  // Optional filter for wave-scoped monitoring
  onCheckpoint:   function  // Milestone callback (optional)
}

MonitorResult: {
  completed:   Task[]
  incomplete:  Task[]
  timedOut:    boolean
}
```

See [monitoring.md](references/monitoring.md) for per-workflow configuration table and signal check patterns.

#### sendMessage(handle, msg) -> void

Sends a message to a teammate. Thin wrapper over `SendMessage` with SEC-4 name validation.

```
msg: {
  type:      "message" | "shutdown_request" | "broadcast"
  recipient: string       // Must match /^[a-zA-Z0-9_-]+$/
  content:   string
  summary:   string       // Optional summary for message type
}
```

#### shutdown(handle) -> void

Executes the 5-component cleanup protocol to tear down the team:

1. **Dynamic member discovery** — read `$CHOME/teams/{teamName}/config.json`
   Fallback: use `handle.spawnedAgents` list from spawn phase
2. **Shutdown all members** — `SendMessage(shutdown_request)` to each
3. **Grace period** — `sleep 15` for teammate deregistration
4. **TeamDelete with retry-with-backoff** (3 attempts: 0s, 5s, 10s)
5. **Filesystem fallback** — only if TeamDelete never succeeded (QUAL-012)
   `rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/"`

See [engines.md](references/engines.md) for full implementation with SEC-4 validation.

#### cleanup(handle) -> void

Post-shutdown state management. Called after `shutdown()`:

1. Update state file status to `"completed"` (preserve session identity fields)
2. Release workflow lock via `rune_release_lock`
3. Clean up signal directory (`tmp/.rune-signals/{teamName}/`)

#### getStatus(handle) -> TeamStatus

Returns current team status by reading config and task list.

```
TeamStatus: {
  teamName:   string
  members:    { name: string, status: string }[]
  tasks:      { id: string, subject: string, status: string, owner: string }[]
  stateFile:  object       // Parsed state file contents
  healthy:    boolean      // true if team dir + config.json exist
}
```

## Engine Selection

```
function resolveEngine(workflow) {
  // All workflows use TeamEngine. No LocalEngine (YAGNI).
  return TeamEngine
}
```

**Design note**: The interface exists to allow future engine implementations without modifying consuming skills. Currently, only `TeamEngine` is implemented. `LocalEngine` was explicitly deferred per YAGNI — do not implement it until there is a concrete need validated across multiple workflows.

## Deadlock Risk (TLC-001 — Advisory Only)

The `enforce-team-lifecycle.sh` hook (TLC-001) uses `permissionDecision: "allow"` with `additionalContext` for stale team detection. It NEVER uses `deny` for stale detection — doing so would deadlock the teamTransition Step 4 catch-and-recover block. Hard `deny` is reserved ONLY for invalid team names (shell injection prevention).

This is an **advisory-only** posture by design — see [engines.md](references/engines.md) § Advisory Enforcement for the D-1 rationale.

## Presets

Workflow-specific configurations that combine team naming, timeout, and monitoring parameters. Each workflow skill uses a preset instead of inline configuration.

See [presets.md](references/presets.md) for the full preset registry.

### Preset Quick Reference

| Workflow | Team Prefix | Timeout | Poll Interval | Stale Warn |
|----------|------------|---------|---------------|------------|
| strive   | `rune-work` | 30 min | 30s | 5 min |
| devise   | `rune-plan` | 15 min | 30s | 5 min |
| mend     | `rune-mend` | 15 min | 30s | 5 min |
| appraise | `rune-review` | 10 min | 30s | 5 min |
| audit    | `rune-audit` | 15 min | 30s | 5 min |
| forge    | `rune-forge` | 10 min | 30s | 5 min |
| arc      | per-phase | per-phase | 30s | 5 min |

## Protocols

Shared protocols that all team lifecycle operations depend on:

1. **Session Isolation** — config_dir + owner_pid + session_id triple
2. **Workflow Lock** — wraps `scripts/lib/workflow-lock.sh`
3. **Signal Detection** — `tmp/.rune-signals/` for fast completion
4. **Handle Serialization** — persist/recover TeamHandle across compaction

See [protocols.md](references/protocols.md) for full protocol specifications.

## Usage Pattern

Workflow skills use the SDK like this:

### Standard Pattern (explicit handle)

```javascript
// 1. Create team (MUST be first — activates ATE-1 enforcement)
const handle = TeamEngine.createTeam({
  teamName: `rune-work-${timestamp}`,
  workflow: "strive",
  identifier: timestamp,
  stateFilePrefix: "tmp/.rune-work",
  metadata: { plan: planPath }
})

// 2. Spawn agents
const agents = TeamEngine.spawnWave(handle, workerSpecs)

// 3. Monitor
const result = TeamEngine.monitor(handle, { timeoutMs: 1_800_000, label: "Work" })

// 4. Shutdown + cleanup (always in try/finally)
try {
  // ... process results ...
} finally {
  TeamEngine.shutdown(handle)
  TeamEngine.cleanup(handle)
}
```

### Auto-Bootstrap Pattern (idempotent — recommended)

```javascript
// ensureTeam() is idempotent — creates if not exists, recovers if exists.
// Safe to call multiple times (e.g., after compaction recovery).
const config = {
  teamName: `rune-work-${timestamp}`,
  workflow: "strive",
  identifier: timestamp,
  stateFilePrefix: "tmp/.rune-work",
  metadata: { plan: planPath }
}

const handle = TeamEngine.ensureTeam(config)

// Or: spawnAgent/spawnWave auto-call ensureTeam() when given config instead of handle
const agents = TeamEngine.spawnWave(config, workerSpecs)  // auto-bootstraps team

// Monitor and cleanup remain the same
const result = TeamEngine.monitor(handle, { timeoutMs: 1_800_000, label: "Work" })
try { /* ... */ } finally {
  TeamEngine.shutdown(handle)
  TeamEngine.cleanup(handle)
}
```

**Inline fallback rule**: Each consuming skill MUST retain enough inline cleanup context (at minimum: dynamic member discovery + TeamDelete retry + filesystem fallback) so that cleanup works even if this SDK skill is not loaded during compaction recovery.

## Non-Standard Bootstrap Coverage

Some workflows need to override default teamTransition behavior:

| Config Override | Purpose | Used By |
|-----------------|---------|---------|
| `retryDelays` | Custom retry timing (e.g., `[0, 1000, 3000]` for fast recovery) | arc phase transitions |
| `fallbackOnFailure` | Skip team creation if all attempts fail (degrade to local) | None currently (reserved) |
| `skipPreCreateGuard` | Skip Steps 2-3 when caller guarantees clean state | arc `prePhaseCleanup` (already cleaned) |

## References

- [engines.md](references/engines.md) — Full TeamEngine implementation with all 10 methods, teamTransition protocol, and cleanup patterns (canonical reference, consolidated from team-lifecycle-guard.md)
- [protocols.md](references/protocols.md) — Session isolation, workflow lock, signal detection, handle serialization
- [presets.md](references/presets.md) — Per-workflow preset configurations
- [monitoring.md](references/monitoring.md) — Monitoring patterns, signal checks, per-command config table
- [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) — Shared waitForCompletion polling utility
