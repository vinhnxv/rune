# Resume Detection Protocol (Phase 0)

When `--resume` is passed, the orchestrator scans for a valid checkpoint from a prior crashed or interrupted session and reconstructs the task pool with completed tasks pre-marked.

## Implementation

```javascript
// Parse --resume flag
const resumeRequested = args.includes("--resume")

if (resumeRequested) {
  const checkpointMaxAgeMs = readTalismanSection("work")?.checkpoint_max_age_ms ?? 86400000  // 24h default
  const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
  let checkpointFile = null
  let checkpoint = null

  // Auto-detect: find most recent checkpoint matching this plan
  const candidates = Glob("tmp/work/*/strive-checkpoint.json")
  for (const candidate of candidates.sort().reverse()) {  // newest first by timestamp dir
    let parsed
    try {
      parsed = JSON.parse(Read(candidate))
    } catch (e) {
      log(`Resume: skipping corrupted checkpoint ${candidate}`)
      continue  // corrupted JSON → skip
    }

    // Session isolation: config_dir must match
    if (parsed.config_dir !== configDir) continue

    // Plan match check
    if (parsed.plan_path !== planPath) continue

    // Staleness check (configurable, default 24h)
    if ((Date.now() - parsed.updated_at) > checkpointMaxAgeMs) {
      log(`Resume: skipping stale checkpoint ${candidate} (age > ${checkpointMaxAgeMs}ms)`)
      continue
    }

    // Live session check: skip if another live session owns this checkpoint
    if (parsed.owner_pid) {
      // SEC-001: Validate owner_pid is purely numeric before shell use
      if (!/^\d+$/.test(String(parsed.owner_pid))) {
        log(`Resume: skipping checkpoint with invalid owner_pid format`)
        continue
      }
      const pidAlive = Bash(`kill -0 ${parsed.owner_pid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
      if (pidAlive === "alive" && String(parsed.owner_pid) !== String(Bash("echo $PPID").trim())) {
        log(`Resume: skipping checkpoint owned by live session PID ${parsed.owner_pid}`)
        continue
      }
    }

    checkpointFile = candidate
    checkpoint = parsed
    break
  }

  if (!checkpointFile) {
    log("Resume: no valid checkpoint found for this plan. Starting fresh.")
    // Fall through to normal flow
  } else {
    // Plan modification detection: compare plan file mtime
    // SEC-006: Validate planPath before shell use
    if (!/^[a-zA-Z0-9._\-\/]+$/.test(planPath) || planPath.includes('..')) {
      log(`Resume: invalid planPath format — skipping modification check`)
    } else {
    const currentMtime = Bash(`stat -f '%m' "${planPath}" 2>/dev/null || stat -c '%Y' "${planPath}" 2>/dev/null`).trim()
    if (checkpoint.plan_mtime && currentMtime !== checkpoint.plan_mtime) {
      log("Resume: WARNING — plan file modified since checkpoint. Changes may affect task definitions.")
      // Warn user but proceed (plan modifications may be intentional refinements)
    }

    // Reconstruct task pool with completion status
    const completedTaskIds = (checkpoint.completed_tasks || []).map(id => String(id))
    for (const task of extractedTasks) {
      const taskIdStr = String(task.id)
      if (completedTaskIds.includes(taskIdStr)) {
        // Verify completed task artifacts still exist
        const artifactInfo = checkpoint.task_artifacts?.[taskIdStr]
        const taskFiles = artifactInfo?.files || []
        let allFilesExist = true
        for (const file of taskFiles) {
          // SEC-002: Validate artifact file path before shell use
          if (!/^[a-zA-Z0-9._\-\/]+$/.test(file) || file.includes('..')) {
            log(`Resume: skipping artifact with invalid path format: ${file}`)
            allFilesExist = false
            break
          }
          const exists = Bash(`test -f "${file}" && echo "yes" || echo "no"`).trim()
          if (exists !== "yes") {
            log(`Resume: completed task ${taskIdStr} artifact missing: ${file} — re-adding to pool`)
            allFilesExist = false
            break
          }
        }

        if (allFilesExist) {
          task.status = "completed"
          task.resumed = true
        }
        // If files missing, task stays pending (re-added to pool)
      }
    }

    const remainingTasks = extractedTasks.filter(t => t.status !== "completed")
    log(`Resume: ${completedTaskIds.length} tasks already done, ${remainingTasks.length} remaining`)

    // Re-validate dependency graph: prune blockedBy edges to completed tasks
    for (const task of remainingTasks) {
      if (task.blockedBy) {
        task.blockedBy = task.blockedBy.filter(depId =>
          !completedTaskIds.includes(String(depId))
        )
      }
    }
  }  // end SEC-006 else (valid planPath)
  }  // end checkpointFile else
}
```

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Plan modified since checkpoint | Warn via log, proceed (user refinements are common) |
| Checkpoint from different config_dir | Skipped (session isolation) |
| Checkpoint > 24h old | Skipped as stale (configurable via `work.checkpoint_max_age_ms`) |
| Live session owns checkpoint | Skipped if owner PID alive and not current session |
| Completed task files deleted | Artifact verification catches this → re-added to pool |
| Corrupted checkpoint JSON | Caught by try/catch → skipped with warning |
| `--resume` with no checkpoint | Warning, falls through to fresh start |
| Task ID type mismatch | All IDs cast to `String()` at read boundaries |
| Circular deps after filtering completed tasks | `blockedBy` edges to completed tasks pruned eagerly |
