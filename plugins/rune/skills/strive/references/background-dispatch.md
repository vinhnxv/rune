# Background Dispatch — Non-Blocking Strive Mode (Phase 3)

Non-blocking dispatch mode for `/rune:strive`. Workers run in the background after the
orchestrator exits its current turn. Progress is checked via `/rune:status` between sessions.

**SDK constraint (REAL-005)**: Background workers cannot block the main session turn.
This mode follows the arc-batch Stop hook pattern — the orchestrator sets up the dispatch
state, returns, and a Stop hook fires to launch workers when Claude finishes responding.
This is NOT a persistent background orchestrator; it is a one-shot wave dispatch.

## Invocation

```
/rune:strive --background [plan.md]
/rune:strive -bg [plan.md]
```

To check progress after dispatch:
```
/rune:status [timestamp]
```

To gather results once complete:
```
/rune:strive --collect [timestamp]
```

---

## Dispatch State File Schema

Written to `tmp/.rune-dispatch-{timestamp}.json` before the orchestrator exits.

```json
{
  "timestamp": "20260226-014500",
  "plan_path": "plans/feature-plan.md",
  "team_name": "rune-work-20260226-014500",
  "started_at": "2026-02-26T01:45:00Z",
  "status": "dispatched",

  // Session isolation triple (SEC-004)
  "config_dir": "/Users/alice/.claude",
  "owner_pid": "12345",
  "session_id": "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),

  // Worker inventory
  "worker_count": 2,
  "expected_task_count": 8,

  // Signal directory for progress (PERF-002)
  "signal_dir": "tmp/.rune-signals/rune-work-20260226-014500/",

  // Question relay directory
  "question_dir": "tmp/work/20260226-014500/questions/",

  // Lock file path (PERF-005)
  "lock_path": "tmp/.rune-dispatch-20260226-014500.lock"
}
```

**State file location**: `tmp/.rune-dispatch-{timestamp}.json` (gitignored, session-scoped).

---

## Dispatch Lock File Enforcement (PERF-005)

Only one active background dispatch per session is allowed. Before writing the dispatch
state file, the orchestrator checks for an existing lock:

```javascript
// PERF-005: Single active dispatch per session
const lockFiles = Glob("tmp/.rune-dispatch-*.lock")
const currentPid = Bash("echo $PPID").trim()
const activeLocks = lockFiles.filter(f => {
  try {
    const lock = JSON.parse(Read(f))
    // SEC-003 FIX: Verify PID liveness before treating lock as active
    if (lock.status !== "active") return false
    const pidAlive = Bash(`kill -0 ${lock.owner_pid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (pidAlive === "dead") {
      // Orphan lock — prior session is dead, clean up
      Bash(`rm -f "${f}"`)
      return false
    }
    return lock.owner_pid === currentPid
  } catch { return false }
})

if (activeLocks.length > 0) {
  const existingTimestamp = activeLocks[0].match(/\.rune-dispatch-(.+)\.lock/)?.[1]
  error(`A background dispatch is already active for this session (${existingTimestamp}).`)
  error(`Check status: /rune:status ${existingTimestamp}`)
  error(`Or collect results: /rune:strive --collect ${existingTimestamp}`)
  return
}

// SEC-005 FIX: Atomic lock write — write to temp file then mv (prevents race window)
Bash(`mkdir -m 700 -p tmp/`)
const lockContent = JSON.stringify({
  timestamp,
  owner_pid: currentPid,
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  status: "active",
  created_at: new Date().toISOString()
})
const lockTmpPath = `tmp/.rune-dispatch-${timestamp}.lock.tmp`
Write(lockTmpPath, lockContent)
Bash(`mv "${lockTmpPath}" "tmp/.rune-dispatch-${timestamp}.lock"`)
```

Lock file is removed when `--collect` gathers results or when the dispatch is explicitly cancelled.

---

## Signal Directory for Progress (PERF-002)

Workers write `.done` signal files when tasks complete, making progress visible without
requiring TaskList API calls on every poll:

```
tmp/.rune-signals/{team_name}/{task-id}.done
```

The `/rune:status` skill reads the signal directory first and only calls `TaskList` when
the signal count differs from the expected task count. This reduces API overhead for
long-running dispatches (PERF-002).

Signal directory created with restricted permissions (SEC-005):

```bash
mkdir -m 700 -p "tmp/.rune-signals/${team_name}/"
```

---

## Question Cap (SEC-006)

Background workers cannot use `AskUserQuestion` — there is no user session to respond.
Workers write questions to files instead:

```
tmp/work/{timestamp}/questions/{task-id}.question   # worker writes question
tmp/work/{timestamp}/questions/{task-id}.answer     # orchestrator or user writes answer
```

**SEC-006**: Workers may ask at most 3 questions per task (configured via
`question_relay.max_questions_per_worker` in talisman.yml). After the cap is reached,
the worker auto-resolves using its best judgment and logs the decision in its worker log.
This prevents unbounded blocking in background mode.

**QUAL-003: Background vs Foreground Path Difference**: In foreground mode, question/answer
persistence uses the signal directory at `tmp/.rune-signals/rune-work-{timestamp}/`. In
background mode, workers write to `tmp/work/{timestamp}/questions/` instead. The signal
directory is orchestrator-owned (for compaction recovery), while the questions directory is
worker-owned (for file-based IPC when no user session exists). The compaction recovery scan
in `question-relay.md` only reads from the signal directory — it will NOT discover
background-mode question files.

---

## --collect Flag

Gather background dispatch results after workers complete:

```
/rune:strive --collect [timestamp]
```

The collect phase:
1. Reads `tmp/.rune-dispatch-{timestamp}.json` state file
2. Runs ward check across all modified files
3. Runs commit broker to commit accepted patches
4. Generates worker log summary at `tmp/work/{timestamp}/worker-logs/_summary.md`
5. Removes lock file and marks dispatch state as `completed`

---

## SDK Constraints Acknowledgment (REAL-005)

Background mode does NOT implement a persistent background orchestrator. The design models
after the arc-batch Stop hook pattern (Forge Revision 3):

1. Orchestrator parses plan, creates tasks, and writes dispatch state file
2. Orchestrator exits its turn (returns to user)
3. Stop hook fires: reads dispatch state, writes arc-batch-style loop file
4. Next Claude turn: loop file detected → workers spawned as teammates
5. Workers run in-process (tmux or in-process teammate mode)

This means workers are launched in the NEXT Claude session turn, not truly in the background.
The term "background" refers to the user's perspective — they can start other tasks while
the dispatch runs.

**What this is NOT**:
- Not a daemon process running while Claude is idle
- Not truly async (workers block the Claude session they run in)
- Not multi-session (workers share the session that drives the next turn)

---

## Talisman Configuration

Configure background dispatch under `dispatch:` in `.claude/talisman.yml`:

```yaml
dispatch:
  enabled: true                          # Default: true. Set false to disable --background flag.
  default_mode: foreground               # QUAL-007 FIX: "background" | "foreground". Default: foreground.
                                         # Change to "background" to make --background the default for all strive runs.
  auto_collect_on_complete: true         # Auto-run --collect after all workers finish. Default: true.
  status_poll_interval_seconds: 30       # /rune:status refresh interval. Default: 30.
  # DOC-003 FIX: question cap is configured via question_relay.max_questions_per_worker (not here)
  lock_enforcement: true                 # Enforce single active dispatch per session (PERF-005). Default: true.
```

---

## Security Requirements

| Requirement | Reference | Enforcement |
|-------------|-----------|-------------|
| Session isolation triple in state file | SEC-004 | config_dir + owner_pid + session_id fields |
| Signal dir created with owner-only perms | SEC-005 | `mkdir -m 700` |
| Lock file created with owner-only perms | SEC-005 | `mkdir -m 700` before touch |
| Question cap prevents unbounded blocking | SEC-006 | Worker checks question count before writing |
| Timestamp format validated before path use | SEC-004 | `/^\d{8}-\d{6}$/` regex in /rune:status |
