---
name: strive
description: |
  Multi-agent work execution using Agent Teams. Parses a plan into tasks,
  summons swarm workers that claim and complete tasks independently,
  and runs quality gates before completion.

  <example>
  user: "/rune:strive plans/feat-user-auth-plan.md"
  assistant: "The Tarnished marshals the Ash to forge the plan..."
  </example>

  <example>
  user: "/rune:strive"
  assistant: "No plan specified. Looking for recent plans..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[plan-path] [--approve] [--worktree] [--background|-bg] [--collect]"
allowed-tools:
  - Agent
  - TaskCreate
  - TaskList
  - TaskUpdate
  - TaskGet
  - TeamCreate
  - TeamDelete
  - SendMessage
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

**Runtime context** (preprocessor snapshot):
- Active workflows: !`find tmp -maxdepth 1 -name '.rune-*-*.json' -exec grep -l '"active"' {} + 2>/dev/null | wc -l | tr -d ' '`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:strive — Multi-Agent Work Execution

Parses a plan into tasks with dependencies, summons swarm workers, and coordinates parallel implementation.

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `codex-cli`, `git-worktree` (when worktree mode active), `polling-guard`, `zsh-compat`, `frontend-design-patterns` + `figma-to-react` + `design-sync` (when design context active)

## Usage

```
/rune:strive plans/feat-user-auth-plan.md              # Execute a specific plan
/rune:strive plans/feat-user-auth-plan.md --approve    # Require plan approval per task
/rune:strive plans/feat-user-auth-plan.md --worktree   # Use git worktree isolation (experimental)
/rune:strive plans/feat-user-auth-plan.md --background # Background dispatch (workers run across sessions)
/rune:strive --collect [timestamp]                      # Gather results from a background dispatch
/rune:strive                                            # Auto-detect recent plan
```

> **Note**: File-todos are always generated (mandatory). There is no `--todos=false` option.

## Pipeline Overview

```
Phase 0: Parse Plan -> Extract tasks, clarify ambiguities, detect --worktree flag
    |
Phase 0.5: Environment Setup -> Branch check, stash dirty files, SDK canary (worktree)
    |
Phase 1: Forge Team -> TeamCreate + TaskCreate pool
    1. Task Pool Creation (complexity ordering, time estimation)
    1.5. Design Context Discovery (conditional, zero cost if no artifacts)
    1.6. MCP Integration Discovery (conditional, zero cost if no integrations)
    1.7. File Ownership and Task Pool (static serialization via blockedBy)
    2. Signal Directory Setup (event-driven fast-path infrastructure)
    3. Per-Task File-Todos Creation (mandatory, session-scoped)
    → TeamCreate + TaskCreate pool
    |
Phase 2: Summon Workers -> Self-organizing swarm
    | (workers claim -> implement -> complete -> repeat)
Phase 3: Monitor -> TaskList polling, stale detection
    |
Phase 3.5: Commit/Merge Broker -> Apply patches or merge worktree branches (orchestrator-only)
    |
Phase 3.7: Codex Post-monitor Critique -> Architectural drift detection (optional, non-blocking)
    |
Phase 4: Ward Check -> Quality gates + verification checklist
    |
Phase 4.1: Todo Summary -> Generate _summary.md from per-worker todo files (orchestrator-only)
    |
Phase 4.3: Doc-Consistency -> Non-blocking version/count drift detection (orchestrator-only)
    |
Phase 4.4: Quick Goldmask -> Compare predicted CRITICAL files vs committed (orchestrator-only)
    |
Phase 4.5: Codex Advisory -> Optional plan-vs-implementation review (non-blocking)
    |
Phase 5: Echo Persist -> Save learnings
    |
Phase 6: Cleanup -> Shutdown workers, TeamDelete
    |
Phase 6.5: Ship -> Push + PR creation (optional)
    |
Output: Feature branch with commits + PR (optional)
```

## Phase 0: Parse Plan

See [parse-plan.md](references/parse-plan.md) for detailed task extraction, shard context, ambiguity detection, and user confirmation flow.

**Summary**: Read plan file, validate path, extract tasks with dependencies, classify as impl/test, detect ambiguities, confirm with user.

### Worktree Mode Detection (Phase 0)

Parse `--worktree` flag from `$ARGUMENTS` and read talisman configuration. This follows the same pattern as `--approve` flag parsing.

```javascript
// Parse --worktree flag from $ARGUMENTS (same pattern as --approve)
const args = "$ARGUMENTS"
const worktreeFlag = args.includes("--worktree")

// readTalismanSection: "work"
const work = readTalismanSection("work")
const worktreeEnabled = work?.worktree?.enabled || false

// worktreeMode: flag wins, talisman is fallback default
const worktreeMode = worktreeFlag || worktreeEnabled
```

When `worktreeMode === true`:
- Load `git-worktree` skill for merge strategy knowledge
- Phase 1 computes wave groupings after task extraction (step 5.3)
- Phase 2 spawns workers with `isolation: "worktree"` per wave
- Phase 3 uses wave-aware monitoring loop
- Phase 3.5 uses `mergeBroker()` instead of `commitBroker()`
- Workers commit directly instead of generating patches

## Phase 0.5: Environment Setup

Before forging the team, verify the git environment is safe for work. Checks branch safety (warns on `main`/`master`), handles dirty working trees with stash UX, and validates worktree prerequisites when in worktree mode.

**Skip conditions**: Invoked via `/rune:arc` (arc handles COMMIT-1), or `work.skip_branch_check: true` in talisman.

See [env-setup.md](references/env-setup.md) for the full protocol — branch check, dirty tree detection, stash UX, and worktree validation.

## Phase 0.7: Workflow Lock (writer)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "writer"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "strive" "writer"`)
```

## Phase 1: Forge Team

```javascript
// Pre-create guard: teamTransition protocol (see team-lifecycle-guard.md)
// STEP 1: Validate (defense-in-depth)
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid work identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected in work identifier')

// STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
// STEP 3: Filesystem fallback (only when STEP 2 failed)
// STEP 4: TeamCreate with "Already leading" catch-and-recover
// STEP 5: Post-create verification

// Create signal directory for event-driven sync
const signalDir = `tmp/.rune-signals/rune-work-${timestamp}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(extractedTasks.length))
Write(`${signalDir}/inscription.json`, JSON.stringify({
  workflow: "rune-work",
  timestamp: timestamp,
  output_dir: `tmp/work/${timestamp}/`,
  teammates: [
    { name: "rune-smith", output_file: "work-summary.md" },
    { name: "trial-forger", output_file: "work-summary.md" }
  ]
}))

// Create output directories (worker-logs replaces todos/ for per-worker session logs)
Bash(`mkdir -p "tmp/work/${timestamp}/patches" "tmp/work/${timestamp}/proposals" "tmp/work/${timestamp}/worker-logs"`)

// Per-task file-todos: always created (mandatory, session-scoped)
// See file-todos/references/integration-guide.md for resolveTodosBase() contract
const workflowOutputDir = `tmp/work/${timestamp}/`

// Arc context detection: when running inside arc, redirect todos to arc's directory
// so all phases (work, review, mend) share a single todos_base at tmp/arc/{id}/todos/
// Detection: check for active arc checkpoint with work phase in_progress
let todosOutputDir = workflowOutputDir  // default: "tmp/work/{timestamp}/"
const arcCheckpoints = Glob(".claude/arc/*/checkpoint.json")
for (const ckpt of arcCheckpoints) {
  try {
    const c = JSON.parse(Read(ckpt))
    if (c.phases?.work?.status === "in_progress" && c.todos_base) {
      // Extract arc output dir from todos_base: "tmp/arc/{id}/todos/" → "tmp/arc/{id}/"
      todosOutputDir = c.todos_base.replace(/todos\/?$/, '')
      break
    }
  } catch {}
}
const todosBase = resolveTodosBase(todosOutputDir)   // arc: "tmp/arc/{id}/todos/", standalone: "tmp/work/{timestamp}/todos/"
const todosDir = resolveTodosDir(todosOutputDir, "work")  // arc: "tmp/arc/{id}/todos/work/", standalone: "tmp/work/{timestamp}/todos/work/"
Bash(`mkdir -p "${todosDir}"`)

// --- Per-task file-todo creation (inline, mandatory) ---
const today = new Date().toISOString().slice(0, 10)
for (const task of extractedTasks) {
  const priority = task.risk_tier === 'critical' ? 'p1' : task.risk_tier === 'high' ? 'p2' : 'p3'
  const slug = task.subject.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
  const filename = `task-${task.id}-${slug}.md`
  Write(`${todosDir}${filename}`, [
    '---',
    `id: task-${task.id}-${slug}`,
    `title: "${task.subject}"`,
    `status: ready`,
    `priority: ${priority}`,
    `source: work`,
    `task_id: "${task.id}"`,
    `files:`, ...(task.fileTargets?.map(f => `  - ${f}`) || []),
    `created_at: "${new Date().toISOString()}"`,
    '---', '',
    `## Task`, '', task.description || task.subject, '',
    `## Checklist`, '', '- [ ] Implementation', '- [ ] Verification',
  ].join('\n'))
}

// --- Complexity-aware task ordering (sort before wave computation) ---
// Gate: readTalismanSection("work")?.complexity_ordering?.enabled !== false
//
// Scoring is additive: Score = (fileCount × wFile) + (wTest if test task) + (wRefactor if refactor keyword)
//                             + (wLargeScope if fileCount > 5)
// Tasks are sorted descending by score so highest-complexity tasks start first.
// Score is a relative ranking, not a time estimate — use estimateTaskMinutes() for time budgeting.
// Default weights (overridable via talisman complexity_ordering.weights):
//   wFile=2: cost per touched file — more files → more risk of conflicts
//   wTest=3: test tasks are slightly harder (require understanding existing coverage)
//   wRefactor=5: refactors touch structural patterns and carry high regression risk
//   wLargeScope=3: bonus for >5 files — coordination overhead grows super-linearly
// Used in both scoreTaskComplexity() and estimateTaskMinutes()
const REFACTOR_KEYWORDS = ["refactor", "restructure", "extract", "migrate", "rename", "reorganize"]

const complexityConfig = readTalismanSection("work")?.complexity_ordering
if (complexityConfig?.enabled !== false) {
  const weights = complexityConfig?.weights ?? {}
  const wFile = weights.file_count ?? 2
  const wTest = weights.test ?? 3
  const wRefactor = weights.refactor ?? 5
  const wLargeScope = weights.large_scope ?? 3

  function scoreTaskComplexity(task) {
    const fileCount = (task.fileTargets?.length ?? 0) + (task.dirTargets?.length ?? 0)
    if (fileCount === 0 && !task.subject && !task.description) return 0  // missing metadata → 0

    let estimate = fileCount * wFile
    if (task.type === "test") estimate += wTest
    const text = `${task.subject ?? ''} ${task.description ?? ''}`.toLowerCase()
    if (REFACTOR_KEYWORDS.some(kw => text.includes(kw))) estimate += wRefactor
    if (fileCount > 5) estimate += wLargeScope
    return estimate
  }

  // Score and sort descending (highest complexity first)
  for (const task of extractedTasks) {
    task._complexityScore = scoreTaskComplexity(task)
    log(`COMPLEXITY-SCORE: task #${task.id} "${task.subject}" → ${task._complexityScore}`)
  }
  extractedTasks.sort((a, b) => b._complexityScore - a._complexityScore)
}

// --- Task time estimation (stored in metadata for Phase 3 reassignment) ---
function estimateTaskMinutes(task) {
  const fileCount = (task.fileTargets?.length ?? 0) + (task.dirTargets?.length ?? 0)
  let estimate = fileCount <= 2 ? 5 : fileCount <= 5 ? 10 : 15
  if (task.type === "test") estimate = 8
  const text = `${task.subject ?? ''} ${task.description ?? ''}`.toLowerCase()
  if (REFACTOR_KEYWORDS.some(kw => text.includes(kw))) estimate = Math.min(20, Math.round(estimate * 1.5))
  return estimate
}
for (const task of extractedTasks) {
  task.metadata = task.metadata ?? {}
  task.metadata.estimated_minutes = estimateTaskMinutes(task)
}

// Wave-based execution: bounded batches with fresh worker context
const TODOS_PER_WORKER = talisman?.work?.todos_per_worker ?? 3
const totalTodos = extractedTasks.length
const maxWorkers = talisman?.work?.max_workers ?? 3
const waveCapacity = maxWorkers * TODOS_PER_WORKER  // e.g. 3 workers * 3 = 9
const totalWaves = Math.ceil(totalTodos / waveCapacity)

// Compute total worker count (scaling logic in worker-prompts.md)
const workerCount = smithCount + forgerCount

// Write state file with session identity for cross-session isolation
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write("tmp/.rune-work-{timestamp}.json", {
  team_name: "rune-work-{timestamp}",
  started: new Date().toISOString(),
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}",
  plan: planPath,
  expected_workers: workerCount,
  total_waves: totalWaves,
  todos_per_worker: TODOS_PER_WORKER,
  todos_base: todosBase,  // session-scoped todos base for resume support
  ...(worktreeMode && { worktree_mode: true, waves: [], current_wave: 0, merged_branches: [] })
})
```

### Design Context Discovery (conditional, zero cost if no artifacts)

See [design-context.md](references/design-context.md) for the 4-strategy cascade (design-package → arc-artifacts → design-sync → figma-url-only), conditional skill loading, and task annotation flow.

**Summary**: Triple-gated (`design_sync.enabled` + frontend task signals + artifact presence). When active, loads `frontend-design-patterns`, `figma-to-react`, `design-sync` skills and injects DCD/VSM content into worker prompts.

### MCP Integration Discovery (conditional, zero cost if no integrations)

See [mcp-integration.md](references/mcp-integration.md) for the resolver algorithm, trigger evaluation, and prompt block builder.

**Summary**: Triple-gated (`integrations.mcp_tools` exists in talisman + phase match for "strive" + trigger match against task files/description). When active, loads companion skills via `loadMCPSkillBindings()` and passes `buildMCPContextBlock()` output to worker prompt builder.

```javascript
// After design context discovery, before file ownership
const mcpIntegrations = resolveMCPIntegrations("strive", {
  changedFiles: extractedTasks.flatMap(t => t.metadata?.file_targets || []),
  taskDescription: planContent
})

if (mcpIntegrations.length > 0) {
  // Load companion skills
  const mcpSkills = loadMCPSkillBindings(mcpIntegrations)
  loadedSkills.push(...mcpSkills)

  // Build context block for worker prompts (injected in Phase 2)
  const mcpContextBlock = buildMCPContextBlock(mcpIntegrations)
  // mcpContextBlock passed to worker prompt builder alongside designContextBlock
}
```

### File Ownership and Task Pool

See [file-ownership.md](references/file-ownership.md) for file target extraction, risk classification, SEC-STRIVE-001 enforcement via inscription.json, and quality contract.

**Summary**: Extract file targets per task → detect overlaps → serialize via `blockedBy` → create task pool with quality contract → write `task_ownership` to inscription.json. Flat-union allowlist enforced by `validate-strive-worker-paths.sh` hook.

## Phase 2: Summon Swarm Workers

See [worker-prompts.md](references/worker-prompts.md) for full worker prompt templates, scaling logic, and the scaling table.

**Summary**: Summon rune-smith (implementation) and trial-forger (test) workers. Workers receive pre-assigned task lists and work through them sequentially. Commits are handled through the Tarnished's commit broker. Do not run `git add` or `git commit` directly.

See [todo-protocol.md](references/todo-protocol.md) for the worker todo file protocol that MUST be included in all spawn prompts.

### Wave-Based Execution

See [wave-execution.md](references/wave-execution.md) for the wave loop algorithm, per-task file-todos, SEC-002 sanitization, non-goals extraction, and worktree mode spawning.

**Summary**: Tasks split into bounded waves (`maxWorkers × todosPerWorker`). Each wave: distribute → spawn → monitor → commit broker → shutdown → next wave. Single-wave optimization skips overhead when `totalWaves === 1`.

## Phase 3: Monitor

Poll TaskList with timeout guard to track progress. See [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) for the shared polling utility.

> **ANTI-PATTERN — NEVER DO THIS:**
> `Bash("sleep 60 && echo poll check")` — This skips TaskList entirely. You MUST call `TaskList` every cycle.

```javascript
const result = waitForCompletion(teamName, taskCount, {
  timeoutMs: 1_800_000,      // 30 minutes
  staleWarnMs: 300_000,      // 5 minutes — warn about stalled worker
  autoReleaseMs: 600_000,    // 10 minutes — release task for reclaim
  pollIntervalMs: 30_000,
  label: "Work",
  onCheckpoint: (cp) => { ... }
})
```

### Signal Checks (Phase 3 — Inline)

Two signal checks run inside the monitoring loop, checked each poll cycle after `TaskList`:

```javascript
// Check for context-critical shutdown signal (Layer 1)
const shutdownSignal = (() => {
  try {
    const sessionId = Bash(`echo "$CLAUDE_SESSION_ID"`).trim()
    const signalPath = `tmp/.rune-shutdown-signal-${sessionId}.json`
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "context_warning"
  } catch { return false }
})()

if (shutdownSignal) {
  warn("CTX-WARNING: Context pressure detected. Initiating early teammate shutdown.")
  goto_cleanup = true
  break
}

// Check for "all tasks done" signal from TeammateIdle hook (Layer 4)
const allDoneSignal = (() => {
  try {
    Read(`tmp/.rune-signals/${teamName}/all-tasks-done`)
    return true
  } catch { return false }
})()

if (allDoneSignal) {
  break
}

// Check for force_shutdown signal from guard-context-critical.sh (Layer 3)
const forceShutdownSignal = (() => {
  try {
    const sessionId = Bash(`echo "$CLAUDE_SESSION_ID"`).trim()
    const signalPath = `tmp/.rune-force-shutdown-${sessionId}.json`
    const signal = JSON.parse(Read(signalPath))
    return signal?.signal === "force_shutdown"
  } catch { return false }
})()

if (forceShutdownSignal) {
  warn("FORCE SHUTDOWN: Context critically low. Sending shutdown_request to ALL workers.")
  // Send shutdown_request to all workers
  for (const worker of activeWorkers) {
    SendMessage({ type: "shutdown_request", recipient: worker.name, content: "Context critically low — emergency shutdown." })
  }
  goto_cleanup = true
  break
}
```

### Smart Reassignment (Phase 3 — Inline)

Check whether in-progress tasks have exceeded their estimated time and reassign to idle workers. Runs per poll cycle, BEFORE stuck worker detection. Gated by `work.reassignment.enabled` (default: `true`).

```javascript
// --- Smart reassignment (per poll cycle, before stuck worker detection) ---
const reassignConfig = readTalismanSection("work")?.reassignment
if (reassignConfig?.enabled !== false) {
  const multiplier = reassignConfig?.multiplier ?? 2.0
  const graceSeconds = reassignConfig?.grace_seconds ?? 60

  const tasks = TaskList()
  const idleWorkers = Object.keys(workerSpawnTimes).filter(w =>
    !tasks.some(t => t.owner === w && t.status === "in_progress")
  )

  for (const task of tasks) {
    if (task.status !== "in_progress") continue
    const estimatedMin = task.metadata?.estimated_minutes ?? 10
    const elapsed = Date.now() - (task.metadata?.claimed_at ?? Date.now())
    const thresholdMs = multiplier * estimatedMin * 60_000

    // F15: max 2 reassignments per task
    const reassignCount = task.metadata?.reassignment_count ?? 0
    if (reassignCount >= 2) continue

    if (elapsed > thresholdMs) {
      if (!task.metadata?.reassignment_warned) {
        // First trigger: warn and set grace period
        log(`REASSIGN-CHECK: task #${task.id} exceeded ${multiplier}x estimate (${estimatedMin}min). Sending progress check.`)
        SendMessage({ type: "message", recipient: task.owner, content: `Progress check: task #${task.id} has exceeded its time estimate. Please report status.`, summary: `Progress check for task #${task.id}` })
        TaskUpdate({ taskId: task.id, metadata: { reassignment_warned: true, warned_at: Date.now() } })
      } else {
        // Grace period elapsed — re-read task status (F8 fix)
        const freshTask = TaskGet(task.id)
        if (freshTask.status === "in_progress") {
          const warnedAt = task.metadata?.warned_at ?? 0
          if (Date.now() - warnedAt > graceSeconds * 1000 && idleWorkers.length > 0) {
            log(`REASSIGN-FORCE: task #${task.id} still in_progress after grace period. Force-releasing.`)
            // F9: clear reassignment metadata on release
            TaskUpdate({
              taskId: task.id,
              status: "pending",
              owner: "",
              metadata: { reassignment_warned: null, warned_at: null, reassignment_count: reassignCount + 1 }
            })
            // Clean up file lock signal for the released task's worker
            try {
              Bash(`rm -f "tmp/.rune-signals/${teamName}/${task.owner}-files.json"`)
            } catch {}
          }
        }
      }
    }
  }
}
```

### Stale File Lock Scan (Phase 3 — Inline)

Sweep `tmp/.rune-signals/{team}/*-files.json` for stale lock signals. Runs per poll cycle after smart reassignment. See [file-ownership.md](references/file-ownership.md) for signal format.

```javascript
// --- Stale lock scan (F1) ---
const staleLockThreshold = readTalismanSection("work")?.file_lock_signals?.stale_threshold_ms ?? 600_000
try {
  const lockFiles = Glob(`tmp/.rune-signals/${teamName}/*-files.json`)
  for (const lockFile of lockFiles) {
    try {
      const signal = JSON.parse(Read(lockFile))
      if (signal.timestamp && Date.now() - signal.timestamp > staleLockThreshold) {
        Bash(`rm -f "${lockFile}"`)
        warn(`Stale file lock removed: ${lockFile} (age: ${Math.round((Date.now() - signal.timestamp) / 60000)}min)`)
      }
    } catch {} // skip malformed signals
  }
} catch {} // no lock files — nothing to scan
```

### Stuck Worker Detection (Phase 3 — Inline)

Track worker spawn times and enforce `max_runtime_minutes` (default: 20). Workers exceeding the runtime budget receive a `shutdown_request` and have their tasks released for reclaim.

**Setup**: In Phase 2, record spawn timestamps:
```javascript
// After spawning each worker in Phase 2:
const workerSpawnTimes = {}  // Map<workerName, Date>
// When spawning:
workerSpawnTimes[workerName] = Date.now()
```

**Detection** (runs per poll cycle in Phase 3, after signal checks):
```javascript
const maxRuntimeMinutes = readTalismanSection("teammate_lifecycle")?.max_runtime_minutes ?? 20
const maxRuntimeMs = maxRuntimeMinutes * 60 * 1000

for (const [workerName, spawnTime] of Object.entries(workerSpawnTimes)) {
  const elapsed = Date.now() - spawnTime
  if (elapsed > maxRuntimeMs) {
    warn(`STUCK WORKER: ${workerName} exceeded ${maxRuntimeMinutes}min runtime (${Math.round(elapsed/60000)}min). Sending shutdown_request.`)
    SendMessage({ type: "shutdown_request", recipient: workerName, content: `Runtime budget exceeded (${maxRuntimeMinutes}min). Shutting down.` })
    // Release any in_progress task owned by this worker
    const tasks = TaskList()
    for (const task of tasks) {
      if (task.owner === workerName && task.status === "in_progress") {
        TaskUpdate({ taskId: task.id, status: "pending", owner: "" })
        warn(`Released task #${task.id} from stuck worker ${workerName}`)
      }
    }
    delete workerSpawnTimes[workerName]  // Don't re-trigger
  }
}
```

#### Stuck Worker Detection Config

| Setting | Default | Description |
|---------|---------|-------------|
| `teammate_lifecycle.max_runtime_minutes` | `20` | Workers exceeding this runtime receive a `shutdown_request` and have their tasks released for reclaim |

**Purpose**: Detects workers that have exceeded their runtime budget — e.g., stuck in an infinite loop, waiting on a blocking tool call, or stalled on a hard task. Without this gate, a single stuck worker can block wave completion indefinitely.

**Tuning guidance**:
- Default `20` minutes is appropriate for most implementation tasks
- Set to `999` to effectively disable stuck worker detection (useful when tasks are known to be long-running)
- Reduce to `10` for resource-constrained environments where you want faster reclaim of stalled tasks

**Wave-aware monitoring (worktree mode)**: Sequential waves, each monitored independently via `waitForCompletion` with `taskFilter`, merge broker runs between waves. Per-wave timeout: 10 minutes.

### Question Relay Detection (Phase 3 — Inline)

During Phase 3, the orchestrator handles worker questions reactively. Worker questions arrive via `SendMessage` (auto-delivered — no polling required). Compaction recovery uses a fast-path signal scan.

See [question-relay.md](references/question-relay.md) for full protocol details — `relayQuestionToUser()`, compaction recovery (ASYNC-004), SEC-002/SEC-006 enforcement, live vs recovery paths, and talisman configuration.

**Talisman gate**: Check `question_relay.enabled` (default: `true`) before activating. If disabled, workers proceed on best-effort without question surfacing.

### Phase 3.5: Commit Broker (Orchestrator-Only, Patch Mode)

The Tarnished is the **sole committer** — workers generate patches, the orchestrator applies and commits them. Serializes all git index operations through a single writer, eliminating `.git/index.lock` contention.

Key steps: validate patch path, read patch + metadata, skip empty patches, dedup by taskId, apply with `--3way` fallback, reset staging area, stage specific files via `--pathspec-from-file`, commit with `-F` message file.

**Recovery on restart**: Scan `tmp/work/{timestamp}/patches/` for metadata JSON with no recorded commit SHA — re-apply unapplied patches.

### Phase 3.5: Merge Broker (Worktree Mode, Orchestrator-Only)

Replaces the commit broker when `worktreeMode === true`. Called between waves. See [worktree-merge.md](references/worktree-merge.md) for the complete algorithm, conflict resolution flow, and cleanup procedures.

Key guarantees: sorted by task ID for deterministic merge order, dedup guard, `--no-ff` merge, file-based commit message, escalate conflicts to user via `AskUserQuestion` (NEVER auto-resolve), worktree cleanup on completion.

### Phase 3.7: Codex Post-monitor Architectural Critique (Optional, Non-blocking)

After all workers complete and the commit/merge broker finishes, optionally run Codex to detect architectural drift between committed code and the plan. Non-blocking, opt-in via `codex.post_monitor_critique.enabled`.

**Skip conditions**: Codex unavailable, `codex.disabled`, feature not enabled, `work` not in `codex.workflows`, or `total_worker_commits <= 3`.

See [codex-post-monitor.md](references/codex-post-monitor.md) for the full protocol — feature gate, nonce-bounded prompt injection, codex-exec.sh invocation, error classification, and ward check integration.

## Phase 4: Quality Gates

Read and execute [quality-gates.md](references/quality-gates.md) before proceeding.

**Phase 4 — Ward Check**: Discover wards from Makefile/package.json/pyproject.toml, execute each with SAFE_WARD validation, run 10-point verification checklist. On ward failure, create fix task and summon worker.

**Phase 4.1 — Todo Summary**: Orchestrator generates `worker-logs/_summary.md` after all workers exit. See [todo-protocol.md](references/todo-protocol.md) for full algorithm. Also updates per-task todo frontmatter status to `complete` for finished tasks and `blocked` for failed tasks. Rebuilds `todos-work-manifest.json` with final status summary. Scans `resolveTodosDir(todosOutputDir, "work")` only (not other source subdirectories). Uses arc-aware `todosOutputDir` from Phase 1.

**Phase 4.3 — Doc-Consistency**: Non-blocking version/count drift detection. See `doc-consistency.md` in `roundtable-circle/references/`.

**Phase 4.4 — Quick Goldmask**: Compare plan-time CRITICAL file predictions against committed files. Emits WARNINGs only. Non-blocking.

**Phase 4.5 — Codex Advisory**: Optional plan-vs-implementation review via `codex exec`. INFO-level findings only. Talisman kill switch: `codex.work_advisory.enabled: false`.

## Phase 5: Echo Persist

```javascript
if (exists(".claude/echoes/workers/")) {
  appendEchoEntry(".claude/echoes/workers/MEMORY.md", {
    layer: "inscribed",
    source: `rune:strive ${timestamp}`,
  })
}
```

## Phase 6: Cleanup & Report

```javascript
// 0. Cache task list BEFORE team cleanup (TaskList() requires active team)
const allTasks = TaskList()

// 1. Dynamic member discovery — reads team config to find ALL teammates
//    (fallback: `spawnedWorkerNames` from Phase 2 — includes wave-based names like rune-smith-w0-1)
// 2. Send shutdown_request to all members
// 2.5. Grace period — sleep 15s to let teammates deregister before TeamDelete
// 2.7. Finalize per-worker artifacts (non-blocking — skip if runs/ absent)
//      Scan tmp/work/{timestamp}/runs/ for agents with status "running"
//      and mark as completed/failed based on worker output presence
try {
  const workRunsDir = `tmp/work/${timestamp}/runs/`
  const runMetas = Glob(`${workRunsDir}*/meta.json`)
  for (const metaPath of runMetas) {
    try {
      const meta = JSON.parse(Read(metaPath))
      if (meta.status === "running") {
        const agentRunDir = metaPath.replace(/\/meta\.json$/, '')
        const agentName = agentRunDir.split('/').pop()
        // Check if worker completed any tasks
        const workerTasks = allTasks.filter(t => t.owner === agentName && t.status === "completed")
        const agentStatus = workerTasks.length > 0 ? "completed" : "failed"
        Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/run-artifacts.sh 2>/dev/null && type rune_artifact_finalize &>/dev/null && rune_artifact_finalize "${agentRunDir}" "${agentStatus}"`)
      }
    } catch (e) { /* per-agent finalization failure is non-blocking */ }
  }
} catch (e) { /* artifact finalization is non-blocking */ }
// 3. Cleanup team with retry-with-backoff (3 attempts: 0s, 5s, 10s)
//    Total budget: 15s grace + 15s retry = 30s max
//    Filesystem fallback when TeamDelete fails
// 3.5: Fix stale todo file statuses (FLAW-008 — active → interrupted)
// 3.55: Per-task file-todos cleanup:
//       Scope to resolveTodosDir(todosOutputDir, "work") — work/ subdirectory only (arc-aware)
//       Filter by work_session == timestamp (session isolation)
//       Mark in_progress todos as interrupted for this session's tasks
// 3.6: Worktree garbage collection (worktree mode only)
//      git worktree prune + remove orphaned worktrees matching rune-work-*
// 3.7: Restore stashed changes if Phase 0.5 stashed (git stash pop)
// 4. Update state file to completed (preserve session identity fields)
// 5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "strive"`)
```

## Phase 6.5: Ship (Optional)

See [ship-phase.md](references/ship-phase.md) for gh CLI pre-check, ship decision flow, PR template generation, and smart next steps.

**Summary**: Offer to push branch and create PR. Generates PR body from plan metadata, task list, ward results, verification warnings, and todo summary. See [todo-protocol.md](references/todo-protocol.md) for PR body Work Session format. The PR body also includes a file-todos status table sourced from `resolveTodosDir(todosOutputDir, "work")` (counts by status/priority, arc-aware).

### Completion Report

```
The Tarnished has claimed the Elden Throne.

Plan: {planPath}
Branch: {currentBranch}

Tasks: {completed}/{total}
Workers: {smith_count} Rune Smiths, {forger_count} Trial Forgers
Wards: {passed}/{total} passed
Commits: {commit_count}
Time: {duration}

Files changed:
- {file list with change summary}

Artifacts: tmp/work/{timestamp}/
```

## --approve Flag (Plan Approval Per Task)

When `--approve` is set, each worker proposes an implementation plan before coding.

**Flow**: Worker reads task → writes proposal to `tmp/work/{timestamp}/proposals/{task-id}.md` → sends to leader → leader presents via `AskUserQuestion` → user approves/rejects/skips → max 2 rejection cycles → timeout 3 minutes → auto-REJECT (fail-closed).

**Proposal format**: Markdown with `## Approach`, `## Files to Modify`, `## Files to Create`, `## Risks` sections.

**Arc integration**: When used via `/rune:arc --approve`, the flag applies ONLY to Phase 5 (WORK), not to Phase 7 (MEND).

## Incremental Commits

Each task produces exactly one commit via the commit broker: `rune: <task-subject> [ward-checked]`.

Task subjects are sanitized: strip newlines + control chars, limit to 72 chars, use `git commit -F <message-file>` (not inline `-m`).

Only the Tarnished (orchestrator) updates plan checkboxes — workers do not edit the plan file.

## Key Principles

### For the Tarnished (Orchestrator)

- **Ship complete features**: Verify wards pass, plan checkboxes are checked, and offer to create a PR.
- **Fail fast on ambiguity**: Ask clarifying questions in Phase 0, not after workers have started implementing.
- **Branch safety first**: Do not let workers commit to `main` without explicit user confirmation.
- **Serialize git operations**: All commits go through the commit broker.

### For Workers (Rune Smiths & Trial Forgers)

- **Match existing patterns**: Read similar code before writing new code.
- **Test as you go**: Run wards after each task, not just at the end. Fix failures immediately.
- **One task, one patch**: Each task produces exactly one patch.
- **Self-review before ward**: Re-read every changed file before running quality gates.
- **Exit cleanly**: No tasks after 3 retries → idle notification → exit. Approve shutdown requests immediately.

## Error Handling

| Error | Recovery |
|-------|----------|
| Worker stalled (>5 min) | Warn lead, release after 10 min |
| Total timeout (>30 min) | Final sweep, collect partial results, commit applied patches |
| Worker crash | Task returns to pool for reclaim |
| Ward failure | Create fix task, summon worker to fix |
| All workers crash | Abort, report partial progress |
| Plan has no extractable tasks | Ask user to restructure plan |
| Conflicting file edits | File ownership serializes via blockedBy; commit broker handles residual conflicts |
| Empty patch (worker reverted) | Skip commit, log as "completed-no-change" |
| Patch conflict (two workers on same file) | `git apply --3way` fallback; mark NEEDS_MANUAL_MERGE on failure |
| `git push` failure (Phase 6.5) | Warn user, skip PR creation, show manual push command |
| `gh pr create` failure (Phase 6.5) | Warn user (branch was pushed), show manual command |
| Detached HEAD state | Abort with error — require user to checkout a branch first |
| `git stash push` failure (Phase 0.5) | Warn and continue with dirty tree |
| `git stash pop` failure (Phase 6) | Warn user — manual restore needed: `git stash list` |
| Merge conflict (worktree mode) | Escalate to user via AskUserQuestion — never auto-resolve |
| Worker crash in worktree | Worktree cleaned up on Phase 6, task returned to pool |
| Orphaned worktrees (worktree mode) | Phase 6 garbage collection: `git worktree prune` + force removal |

## Common Pitfalls

| Pitfall | Prevention |
|---------|------------|
| Committing to `main` | Phase 0.5 branch check (fail-closed) |
| Building wrong thing from ambiguous plan | Phase 0 clarification sub-step |
| 80% done syndrome | Phase 6.5 ship phase |
| Over-reviewing simple changes | Review guidance heuristic in completion report |
| Workers editing same files | File ownership conflict detection (Phase 1, step 5.1) serializes via blockedBy |
| Stale worker blocking pipeline | Stale detection (5 min warn, 10 min auto-release) |
| Ward failure cascade | Auto-create fix task, summon fresh worker |
| Dirty working tree conflicts | Phase 0.5 stash check |
| `gh` CLI not installed | Pre-check with fallback to manual instructions |
| Partial file reads | Step 5: "Read FULL target files" |
| Fixes that introduce new bugs | Step 6.5: Self-review checklist |
