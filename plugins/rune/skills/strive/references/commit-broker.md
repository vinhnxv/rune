# Commit Broker — Edge Case Handling

The commit broker is the centralized commit authority in `/rune:strive` workflows. Workers produce
patches (via git diff or file writes); the broker validates and applies them as atomic commits.
This document covers edge cases that arise in parallel worker execution.

## Empty Patch Handling

When a worker completes a task but produces no net changes (e.g., reverted all edits, or determined
no changes were needed):

1. Detect empty patch: `git diff --cached --stat` returns empty output after staging worker changes
2. Log the event: write `{ "task_id": id, "status": "completed-no-change", "reason": "empty_patch" }` to worker log
3. Flag in work-summary: include the task in the summary with a `no_changes: true` marker so the orchestrator knows it completed without output
4. Skip commit: do NOT create an empty commit — proceed to the next task in the queue

**Why this matters**: Workers may legitimately produce no changes (e.g., a task to "add error handling"
where the existing code already handles the case). Treating empty patches as failures would cause
unnecessary retries.

## Conflict Resolution

When applying a worker's patch conflicts with changes already committed by another worker:

1. **First attempt** — standard apply:
   ```bash
   git apply --check "${patchFile}"  # dry-run first
   git apply "${patchFile}"
   ```

2. **Fallback** — three-way merge:
   ```bash
   git apply --3way "${patchFile}"
   ```
   This uses the merge machinery to resolve conflicts where possible.

3. **If both fail** — escalate to orchestrator:
   - Mark the task as `needs-manual-merge` in TaskUpdate metadata
   - Warn the orchestrator via SendMessage: `"Task #${id} patch conflicts with prior commits — needs manual merge"`
   - Do NOT force-apply or silently drop the patch
   - The orchestrator can reassign the task for a fresh attempt against the updated HEAD

**Why this matters**: In parallel execution, Worker A and Worker B may both modify overlapping files.
The first commit wins; the second worker's patch must be reconciled against the new state.

## Validation Failures

When pre-commit hooks reject a commit:

1. Capture the hook failure output (stderr from `git commit`)
2. Block the commit — do NOT use `--no-verify` to bypass hooks
3. Return the task to the pool with status `pending` and metadata:
   ```json
   {
     "retry_reason": "pre_commit_hook_failure",
     "hook_output": "<truncated stderr, max 500 chars>",
     "retry_count": N
   }
   ```
4. The task can be claimed by another worker (or the same worker on a fresh attempt)
5. After 3 retries, escalate to the orchestrator as a blocking issue

**Why this matters**: Pre-commit hooks enforce project quality gates (linting, type checking,
formatting). Bypassing them would ship broken code. Retrying gives the next worker a chance to
produce a clean patch.

## Dedup Guard

Prevents double-commits when a task is retried after a transient failure (e.g., worker timeout
followed by successful completion on retry):

1. Maintain a committed task set: `Set<string>` of task IDs that have been successfully committed
2. Before committing, check: `if (committedTaskIds.has(taskId)) { skip }`
3. Log skipped duplicates: `"Dedup: task #${id} already committed, skipping"`
4. The set persists for the duration of the work session (not across sessions)

```javascript
const committedTaskIds = new Set()

function commitTaskPatch(taskId, patchFile) {
  if (committedTaskIds.has(String(taskId))) {
    log(`Dedup: task #${taskId} already committed, skipping`)
    return { status: "skipped", reason: "duplicate" }
  }

  // ... apply patch, run hooks, commit ...

  committedTaskIds.add(String(taskId))
  return { status: "committed" }
}
```

**Why this matters**: In swarm execution with retries, a worker may timeout (appears failed) but
actually complete its commit just before a retry worker also completes. Without dedup, the same
change gets committed twice — potentially causing merge conflicts or duplicated code.
