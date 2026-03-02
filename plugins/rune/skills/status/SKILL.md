---
name: status
description: |
  Check status of background-dispatched Rune workers. Use when /rune:strive was run with
  --background (-bg) flag and you want to see dispatch progress, pending questions, and
  worker health without blocking the main session. Also use to detect stale dispatches
  (>2h) and orphaned workers.

  <example>
  user: "/rune:status"
  assistant: "Reading dispatch state file for active background dispatch..."
  </example>

  <example>
  user: "/rune:status 20260226-014500"
  assistant: "Checking dispatch state for timestamp 20260226-014500..."
  </example>

user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, TaskList
argument-hint: "[timestamp]"
---

# /rune:status — Background Dispatch Status

Check status of workers launched via `/rune:strive --background`.

## Usage

```
/rune:status [timestamp]
```

- `timestamp`: Optional. Dispatch timestamp from the `--background` launch (e.g., `20260226-014500`).
  If omitted, discovers the most recent active dispatch state file.

## Protocol

### Step 1 — Resolve Dispatch State File

```javascript
// Prefer signal directory for progress first (PERF-002), fall back to state file
const timestamp = $ARGUMENTS[0] || null

let stateFile
if (timestamp) {
  // SEC-004: Validate timestamp format before using in path construction
  if (!/^\d{8}-\d{6}$/.test(timestamp)) {
    error(`Invalid timestamp format "${timestamp}". Expected YYYYMMDD-HHMMSS.`)
    return
  }
  stateFile = `tmp/.rune-dispatch-${timestamp}.json`
} else {
  // Auto-discover most recent active dispatch
  const allDispatchFiles = Glob("tmp/.rune-dispatch-*.json")
  if (allDispatchFiles.length === 0) {
    log("No active background dispatch found. Run /rune:strive --background to start one.")
    return
  }
  // SEC-008 FIX: Use Glob for discovery (safer than ls — ZSH NOMATCH kills raw globs).
  // Glob() returns files sorted by mtime (most recent first). No shell glob expansion needed.
  stateFile = allDispatchFiles[0]  // Already discovered by Glob above, sorted by mtime
  // Validate discovered file has expected timestamp format
  const discoveredMatch = stateFile.match(/tmp\/\.rune-dispatch-(\d{8}-\d{6})\.json$/)
  if (!discoveredMatch) {
    log("Could not parse timestamp from discovered dispatch file.")
    return
  }
}
```

### Step 2 — Read and Validate State File

```javascript
const stateRaw = Read(stateFile)
if (!stateRaw) {
  log(`Dispatch state file not found: ${stateFile}`)
  log("The dispatch may have completed. Run /rune:strive --collect to gather results.")
  return
}

let state
try {
  state = JSON.parse(stateRaw)
} catch (e) {
  error(`Dispatch state file is corrupt: ${stateFile}`)
  return
}

// SEC-009 FIX: Validate state.timestamp before using in any path construction
if (state.timestamp && !/^\d{8}-\d{6}$/.test(state.timestamp)) {
  error(`Invalid timestamp format in state file: ${state.timestamp}`)
  return
}

// Session isolation check (SEC-004): verify config_dir matches current session
const CHOME = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
if (state.config_dir && state.config_dir !== CHOME) {
  warn(`Dispatch belongs to a different config dir (${state.config_dir}). Showing read-only status.`)
}

// Stale dispatch detection (>2h) with warning
const dispatchAge = Date.now() - new Date(state.started_at).getTime()
const TWO_HOURS_MS = 2 * 60 * 60 * 1000
if (dispatchAge > TWO_HOURS_MS) {
  warn(`Dispatch started ${Math.round(dispatchAge / 3600000 * 10) / 10}h ago — may be stale.`)
  warn(`Consider running /rune:strive --collect ${state.timestamp} to gather partial results.`)
}
```

### Step 3 — Check Signal Directory for Live Progress (PERF-002)

```javascript
// Signal directory is cheaper to scan than TaskList (avoids API call on every poll)
const signalDir = `tmp/.rune-signals/${state.team_name}/`
const signalFiles = Glob(`${signalDir}*.done`) || []
const completedFromSignals = signalFiles.length

// Fall back to TaskList only when signal count differs from state expectation (PERF-002)
let taskSummary = null
if (completedFromSignals !== state.expected_task_count) {
  taskSummary = TaskList()
}
```

### Step 4 — Detect Pending Questions

```javascript
// Question files written by workers who cannot use AskUserQuestion in background mode
const questionFiles = Glob(`tmp/work/${state.timestamp}/questions/*.question`) || []
const unansweredQuestions = questionFiles.filter(f => {
  const answerFile = f.replace('.question', '.answer')
  return !fileExists(answerFile)
})
```

### Step 5 — Stale Worker Detection (PERF-003)

```javascript
// Detect workers that have not emitted a signal in >15 min (PERF-003: side effect)
const workerLogs = Glob(`tmp/work/${state.timestamp}/worker-logs/*.md`) || []
const staleWorkers = []
const WORKER_STALE_MS = 15 * 60 * 1000

for (const logFile of workerLogs) {
  const mtime = parseInt(Bash(`stat -f "%m" "${logFile}" 2>/dev/null || stat -c "%Y" "${logFile}" 2>/dev/null`).trim(), 10) * 1000
  if (Date.now() - mtime > WORKER_STALE_MS) {
    // SEC-003 FIX: Sanitize worker name to prevent filename injection / path traversal
    const rawName = logFile.split('/').pop().replace('.md', '')
    const safeName = rawName.replace(/[^a-zA-Z0-9_-]/g, '_')
    staleWorkers.push(safeName)
  }
}

if (staleWorkers.length > 0) {
  warn(`Stale workers detected (no activity >15min): ${staleWorkers.join(', ')}`)
}
```

### Step 6 — Render Status Report

```
/rune:status report
═══════════════════════════════════════════════
Dispatch:   ${state.timestamp}
Team:       ${state.team_name}
Started:    ${state.started_at}
Plan:       ${state.plan_path}

Progress:   ${completedFromSignals}/${state.expected_task_count} tasks complete
            [████████░░░░░░░░] ${Math.round(completedFromSignals/state.expected_task_count*100)}%

Workers:    ${state.worker_count} spawned, ${staleWorkers.length} stale
───────────────────────────────────────────────
Pending questions: ${unansweredQuestions.length}
${unansweredQuestions.map(f => `  ? ${Read(f).trim()}`).join('\n') || '  (none)'}
───────────────────────────────────────────────
${dispatchAge > TWO_HOURS_MS ? '⚠ WARNING: Dispatch is >2h old — may be stale' : 'Status: active'}
═══════════════════════════════════════════════
```

### Answering Pending Questions

When pending questions are detected, answer them by writing `.answer` files:

```bash
# Write answer to a pending question
echo "Use the existing auth module" > tmp/work/{timestamp}/questions/{task-id}.answer
```

Or use `/rune:strive --collect {timestamp}` once the dispatch is complete to gather results.

## Security Requirements

- **SEC-004**: Validate timestamp format (`\d{8}-\d{6}`) before path construction
- **SEC-005**: Dispatch signal directory created with `mkdir -m 700` — owner-only access
- **SEC-006**: Question cap — workers may ask at most 3 questions per task before auto-resolving

## Reference

For full background dispatch documentation, see [background-dispatch.md](../strive/references/background-dispatch.md).
