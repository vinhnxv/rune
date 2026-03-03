# Wave-Based Execution (Phase 2)

When `totalWaves > 1`, workers are spawned per-wave with bounded task assignments. Each wave:
1. Slice tasks for this wave from the priority-ordered list
2. Distribute tasks across workers via `TaskUpdate({ owner })`
3. Spawn fresh workers (named `rune-smith-w{wave}-{idx}`)
4. Monitor this wave via `waitForCompletion` with `taskFilter`
5. Shutdown workers after wave completes
6. Apply commits via commit broker
7. Proceed to next wave

**Single-wave optimization**: When `totalWaves === 1`, all tasks are assigned upfront and the existing behavior applies (no wave overhead).

```javascript
// Wave loop (Phase 2 + 3 combined)
for (let wave = 0; wave < totalWaves; wave++) {
  const waveStart = wave * waveCapacity
  const waveTasks = priorityOrderedTasks.slice(waveStart, waveStart + waveCapacity)

  // Distribute tasks to workers for this wave
  for (let i = 0; i < waveTasks.length; i++) {
    const workerIdx = i % workerCount
    const workerName = totalWaves === 1
      ? `rune-smith-${workerIdx + 1}`
      : `rune-smith-w${wave}-${workerIdx + 1}`
    TaskUpdate({ taskId: waveTasks[i].id, owner: workerName })
  }

  // Spawn fresh workers for this wave
  // Workers receive pre-assigned tasks (no dynamic claiming)
  // See worker-prompts.md for wave-aware prompt template

  // Per-worker artifact tracking (non-blocking — skip if library unavailable)
  // Records each worker's initial system prompt as input.md for debugging/inspection
  for (let i = 0; i < workerCount; i++) {
    const workerName = totalWaves === 1
      ? `rune-smith-${i + 1}`
      : `rune-smith-w${wave}-${i + 1}`
    try {
      const _wkRunDir = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/run-artifacts.sh 2>/dev/null && type rune_artifact_init &>/dev/null && rune_artifact_init "work" "${timestamp}" "${workerName}" "${teamName}"`)?.trim() || null
      if (_wkRunDir) {
        Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/run-artifacts.sh 2>/dev/null && rune_artifact_write_input "${_wkRunDir}" "Worker system prompt for ${workerName} (see worker-prompts.md)"`)
      }
    } catch (e) { /* artifact tracking is non-blocking */ }
  }

  // Monitor this wave
  waitForCompletion(teamName, waveTasks.length, {
    timeoutMs: totalWaves === 1 ? 1_800_000 : 600_000,  // 30 min single / 10 min per wave
    staleWarnMs: 300_000,
    pollIntervalMs: 30_000,
    label: `Work wave ${wave + 1}/${totalWaves}`,
    taskFilter: waveTasks.map(t => t.id)
  })

  // Apply commits for this wave via commit broker
  commitBroker(waveTasks)

  // Shutdown wave workers before next wave
  if (wave < totalWaves - 1) {
    shutdownWaveWorkers(wave)
  }
}
```

## Per-Task File-Todos (Mandatory, v2)

The orchestrator creates per-task todo files in `{todos_base}/work/` (resolved via `resolveTodosDir(workflowOutputDir, "work")`). Always `tmp/work/{timestamp}/todos/work/` for standalone; `tmp/arc/{id}/todos/work/` when invoked from arc. File-todos are mandatory — there is no `--todos=false` option. Workers read their assigned todo for context (dependencies, priority, wave) and append Work Log entries. See `file-todos` skill for schema. Per-worker session logs relocated to `tmp/work/{timestamp}/worker-logs/` (not in todos/).

## Security

**SEC-002**: Sanitize plan content before interpolation into worker prompts using `sanitizePlanContent()` (strips HTML comments, code fences, image/link injection, markdown headings, Truthbinding markers, YAML frontmatter, inline HTML tags, and truncates to 8000 chars).

**Non-goals extraction (v1.57.0+)**: Before summoning workers, extract `non_goals` from plan YAML frontmatter and present in worker prompts as nonce-bounded data blocks.

## Worktree Mode: Wave-Based Worker Spawning

When `worktreeMode === true`, workers are spawned per-wave instead of all at once. Each worker gets `isolation: "worktree"`. Workers commit directly (one commit per task) and store their branch in task metadata. Do NOT push. Do NOT merge. The Tarnished handles merging via the merge broker.

See [worktree-merge.md](worktree-merge.md) for the merge broker called between waves.
