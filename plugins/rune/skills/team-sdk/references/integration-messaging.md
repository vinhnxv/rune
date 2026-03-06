# Integration Messaging — Dependency-Resolved Notifications

> Convention for notifying teammates when task dependencies are resolved. Ensures blocked tasks start promptly after their blockers complete.

## Overview

When a teammate completes a task that has `addBlocks` dependencies, it should notify the owners of newly-unblocked tasks. This prevents idle time where a teammate is waiting for work that is already available.

### Lifecycle Position

```
TaskUpdate(completed) → Dependency notification → Seal (SendMessage) → idle/exit
```

**Critical ordering**: Dependency notifications happen AFTER `TaskUpdate({ status: "completed" })` but BEFORE the Seal message. The Seal remains the LAST action a teammate takes.

## Scope

| Workflow | Uses dependency notifications? | Reason |
|----------|-------------------------------|--------|
| strive | Yes | Tasks have explicit dependency chains (addBlocks/addBlockedBy) |
| mend | Yes | Fix groups may depend on prior fixes (e.g., shared utility first) |
| appraise | No | Independent agents — no task dependencies |
| audit | No | Independent agents — no task dependencies |
| devise | No | Sequential phases managed by orchestrator, not task dependencies |
| forge | No | Single enrichment pass — no inter-task dependencies |
| inspect | No | Independent inspector Ashes — no task dependencies |

## Protocol

### When to Send

A dependency notification is sent when ALL of these conditions are true:

1. The completing task has `blocks` entries (tasks it was blocking)
2. The blocked task's remaining `blockedBy` list is now empty (all dependencies resolved)
3. The blocked task has an `owner` assigned

If the blocked task has no owner, notify `"team-lead"` instead so the lead can assign or spawn a worker.

### Message Format

```javascript
SendMessage({
  type: "message",
  recipient: "{blocked-task-owner}" || "team-lead",
  content: "Dependency resolved: task #{id} ({subject}) is done. You can proceed with task #{blocked-id}.",
  summary: "Dependency #{id} resolved"
})
```

### Implementation Pattern

After completing a task, check for unblocked dependents:

```javascript
// 1. Complete the task
TaskUpdate({ taskId: myTaskId, status: "completed" })

// 2. Check for newly unblocked tasks
const allTasks = TaskList()
for (const task of allTasks) {
  // Skip tasks that aren't pending or still have other blockers
  if (task.status !== "pending") continue
  if (task.blockedBy && task.blockedBy.length > 0) continue

  // Check if this task was blocked by the one we just completed
  // (TaskList returns updated blockedBy after TaskUpdate)
  // If the task was previously blocked and is now unblocked, notify
  const recipient = task.owner || "team-lead"
  SendMessage({
    type: "message",
    recipient: recipient,
    content: `Dependency resolved: task #${myTaskId} (${myTaskSubject}) is done. You can proceed with task #${task.id}.`,
    summary: `Dependency #${myTaskId} resolved`
  })
}

// 3. Send Seal (LAST action)
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "Seal: task #...",
  summary: "Seal: task #... done"
})
```

### Simplified Pattern (for spawn prompts)

When adding to agent spawn prompts, use this concise version:

```
After TaskUpdate(completed), call TaskList(). For any task that was blocked by yours
and now has empty blockedBy, send:
  SendMessage({ type: "message", recipient: "{owner}" or "team-lead",
    content: "Dependency resolved: task #{your-id} done. You can proceed with task #{blocked-id}.",
    summary: "Dependency #{your-id} resolved" })
```

## Rules

1. **One notification per unblocked task**: Send exactly one message per newly-unblocked task. Do not send multiple notifications for the same task.
2. **Fallback to team-lead**: If the blocked task has no `owner`, notify `"team-lead"`.
3. **Best-effort**: If `SendMessage` fails, do not retry — proceed to the Seal. The team lead's polling loop will detect the unblocked task regardless.
4. **No self-notification**: If the completing teammate owns the unblocked task, skip the notification and simply claim it via `TaskUpdate({ taskId, status: "in_progress" })`.
5. **Order preservation**: Dependency notifications come AFTER TaskUpdate(completed) and BEFORE the Seal.

## Anti-Patterns

### NEVER: Notify before TaskUpdate

```javascript
// WRONG — task is not yet completed, blockedBy not updated
SendMessage({ recipient: "worker-2", content: "Dependency resolved..." })
TaskUpdate({ taskId: myId, status: "completed" })
```

The `blockedBy` list is only updated after `TaskUpdate(completed)`. Notifying before creates a race condition.

### NEVER: Broadcast dependency resolution

```javascript
// WRONG — broadcasts to ALL teammates, wasteful
SendMessage({ type: "broadcast", content: "Task #3 is done!" })
```

Use targeted `type: "message"` to the specific task owner or team-lead.

### NEVER: Poll for blocked tasks in a loop

```javascript
// WRONG — one TaskList call is sufficient
while (true) {
  const tasks = TaskList()
  // ... check for unblocked tasks
  sleep(5)
}
```

A single `TaskList()` call after `TaskUpdate(completed)` is sufficient.

## Cross-References

- [seal-protocol.md](seal-protocol.md) — Seal completion format (sent AFTER dependency notifications)
- [monitoring.md](monitoring.md) — Team lead polling loop that also detects unblocked tasks
- [engines.md](engines.md) — Task creation with `addBlocks`/`addBlockedBy` dependencies
