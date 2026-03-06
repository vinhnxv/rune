# Phase 6: Cleanup & Report

```javascript
// 0. Cache task list BEFORE team cleanup (TaskList() requires active team)
const allTasks = TaskList()

// 1. Dynamic member discovery — reads team config to find ALL teammates
//    (fallback: `spawnedWorkerNames` from Phase 2 — includes wave-based names like rune-smith-w0-1)
// 2. Send shutdown_request to all members
// 2.5. Grace period — sleep 20s to let teammates deregister before TeamDelete
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
// 3. Cleanup team with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
//    Total budget: 20s grace + 30s retry = 50s max
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`strive cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
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
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/rune-work-${timestamp}/" "$CHOME/tasks/rune-work-${timestamp}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}
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

## Completion Report

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
