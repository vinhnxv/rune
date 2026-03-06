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
