# File Ownership and Task Pool (Phase 1)

## Task Pool Creation

1. Extract file targets (`fileTargets`, `dirTargets`) per task from plan
2. Classify risk tiers — see `risk-tiers.md` in `roundtable-circle/references/`
3. Detect overlapping file ownership via set intersection (O(n²) cap: 200 targets)
4. Serialize conflicting tasks via `blockedBy` links
5. Create task pool via `TaskCreate` with quality contract embedded in description
6. Link dependencies using mapped IDs — see [dependency-patterns.md](dependency-patterns.md) for named patterns and anti-patterns
7. Compute wave groupings (worktree mode only) using DFS depth algorithm
8. Write `task_ownership` to inscription.json for runtime enforcement (SEC-STRIVE-001)

## Runtime File Ownership Enforcement (SEC-STRIVE-001)

After creating the task pool, write `task_ownership` to `inscription.json` mapping each task to its file/dir targets. The `validate-strive-worker-paths.sh` PreToolUse hook reads this at runtime to block writes outside assigned scope.

```javascript
// Build task_ownership mapping for inscription.json
const taskOwnership = {}
for (const task of extractedTasks) {
  const targets = extractFileTargets(task)
  if (targets.files.length > 0 || targets.dirs.length > 0) {
    taskOwnership[task.id] = {
      owner: task.assignedWorker || "unassigned",
      files: targets.files,
      dirs: targets.dirs
    }
  }
  // Tasks with no extractable targets are unrestricted (not added to task_ownership)
}
```

### Inscription Format

```json
{
  "workflow": "rune-work",
  "timestamp": "20260225-015124",
  "task_ownership": {
    "task-1": { "owner": "rune-smith-1", "files": ["src/auth.ts"], "dirs": ["src/auth/"] },
    "task-2": { "owner": "rune-smith-2", "files": ["src/api/users.ts"], "dirs": ["src/api/"] }
  }
}
```

The hook uses a **flat union** approach: all tasks' file targets are merged into one allowlist. This means worker-A can write to worker-B's files, but files NOT in ANY task's target list are blocked. Talisman `work.unrestricted_shared_files` array is appended to every task's allowlist (for shared config files like `package.json`).

## Dynamic File Lock Signals

Runtime file lock layer that complements static `blockedBy` serialization. Gated by `work.file_lock_signals.enabled` (default: `true`).

### How It Works

Workers write signal files to `tmp/.rune-signals/{team}/{worker-name}-files.json` before starting implementation. Each signal declares which files the worker is actively modifying. Other workers check for overlapping locks before claiming a task:

```json
{
  "worker": "rune-smith-w0-1",
  "task_id": "3",
  "files": ["src/auth.ts", "src/auth/middleware.ts"],
  "timestamp": 1709568000000
}
```

**Lifecycle**: Signal file is created at step 4.8 (after ownership check, before file reads) and deleted at step 8.5/9.5 (after task completion or ward failure).

### TOCTOU Mitigation

The check-then-write pattern is inherently subject to time-of-check-to-time-of-use (TOCTOU) races. Mitigations:

1. **Static serialization first**: `blockedBy` links (Phase 1) catch most overlaps at planning time. File lock signals are a second layer for dynamic overlap that static analysis missed.
2. **Atomic signal writes**: Workers write signal files atomically (write to temp file + rename).
3. **Conservative conflict resolution**: On conflict, the worker defers (releases task) rather than proceeding. False positives (unnecessary deferrals) are preferred over false negatives (concurrent edits).
   > **Note:** At 5+ workers, dual-defer retry storms become more likely. Consider exponential backoff jitter (30s → 45s → 60s) for large plans. Current retry cycle is 3 × 30s = 90s minimum. This is a deliberate trade-off: correctness (no concurrent edits) is prioritized over throughput (retry overhead). With fewer than 5 workers the collision probability is low enough that fixed 30s retries are acceptable.
4. **Idempotent release**: Workers delete their own signal file on both success and failure paths.

### Stale Lock Prevention

The orchestrator's Phase 3 monitoring loop includes a stale lock scan that sweeps `tmp/.rune-signals/{team}/*-files.json`. Signals older than `work.file_lock_signals.stale_threshold_ms` (default: 600000ms / 10 minutes) are deleted.

> **Threshold rationale:** The default `stale_threshold_ms` of 600000 (10 minutes) acts as a filesystem janitor for crashed workers, not a real-time safety net. A worker that crashes leaves its signal file behind; the janitor sweeps it up on the next monitoring cycle. For tighter protection against long-running workers blocking tasks, reduce to 180000 (3 minutes = 1 long task + buffer). The 10-minute default is conservative to avoid false positives on slow I/O or temporarily hung workers. Adjust via `work.file_lock_signals.stale_threshold_ms` in `talisman.yml`.

This handles:

- Worker crashes (signal file left behind without cleanup)
- Workers that exceed their runtime budget and get force-shutdown
- Orphaned signals from previous waves

### Talisman Configuration

```yaml
work:
  file_lock_signals:
    enabled: true                # default: true
    stale_threshold_ms: 600000   # default: 10 minutes
```

## Quality Contract

Embedded in every task description:

```
Quality requirements (mandatory):
- Type annotations on ALL function signatures (params + return types)
- Use `from __future__ import annotations` at top of every Python file
- Docstrings on all public functions, classes, and modules
- Specific exception types (no bare except, no broad Exception catch)
- Tests must cover edge cases (empty input, None values, type mismatches)
```
