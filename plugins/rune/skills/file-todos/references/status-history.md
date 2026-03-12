# Status History — Structured Audit Trail

Every todo file includes a `## Status History` section that records every status transition as an append-only log. This section provides a full audit trail: who changed the status, when, and why.

## Entry Format

The Status History section is a markdown table appended to the todo body (after `## Work Log`):

```markdown
## Status History

| Timestamp | From | To | Actor | Reason |
|-----------|------|----|-------|--------|
| 2026-02-25T12:00:00Z | — | pending | appraise:1771234 | Created from TOME finding SEC-001 |
| 2026-02-25T12:30:00Z | pending | ready | user | Triage approved |
| 2026-02-25T13:00:00Z | ready | in_progress | rune-smith-1 | Claimed for wave 1 |
| 2026-02-25T14:00:00Z | in_progress | complete | mend-fixer-2 | Fixed: parameterized query |
```

### Column Definitions

| Column | Format | Notes |
|--------|--------|-------|
| `Timestamp` | ISO 8601 datetime (`YYYY-MM-DDTHH:MM:SSZ`) | UTC. Set by the orchestrator at write time. |
| `From` | Status string or `—` | `—` for the initial creation entry (no prior status). |
| `To` | Status string | The new status after this transition. |
| `Actor` | `{skill}:{id}` or agent name or `user` | Who triggered the transition. See Actor Format below. |
| `Reason` | Free-text string | Why the transition occurred. Pipe characters (`|`) must be escaped. |

### Actor Format

| Scenario | Actor Value | Example |
|----------|-------------|---------|
| Created by triage workflow | `{skill}:{identifier}` | `appraise:1771234` |
| Created by strive workflow | `strive:{timestamp}` | `strive:1771890` |
| Claimed by worker | `{worker-name}` | `rune-smith-1` |
| Completed by mend fixer | `{fixer-name}` | `mend-fixer-2` |
| Manual action by user | `user` | `user` |
| Interrupted by cleanup | `cleanup:{phase}` | `cleanup:phase6` |

## Append Protocol

### `appendStatusHistory(todoPath, fromStatus, toStatus, actor, reason)`

```javascript
/**
 * Appends a status transition entry to a todo's Status History table.
 * MUST be called only by the orchestrator (Tarnished) — not by workers directly.
 * Workers signal status changes to the orchestrator via the signal directory.
 *
 * @param {string} todoPath    - Absolute path to the todo markdown file
 * @param {string|null} fromStatus - Previous status, or null for creation entries
 * @param {string} toStatus    - New status after transition
 * @param {string} actor       - Who triggered the transition (agent name, skill:id, or "user")
 * @param {string} reason      - Human-readable explanation for the transition
 * @throws {Error} If todoPath does not exist or is not readable
 */
function appendStatusHistory(todoPath: string, fromStatus: string | null, toStatus: string, actor: string, reason: string): void {
  const timestamp = new Date().toISOString()

  // Escape pipe characters in reason and actor to prevent markdown table corruption.
  // Use Unicode DIVIDES (U+2223, ∣) as a safe visual replacement.
  const safeReason = (reason || '').replace(/\|/g, '∣')
  const safeActor = (actor || 'unknown').replace(/\|/g, '∣')

  const fromCell = fromStatus || '—'
  const entry = `| ${timestamp} | ${fromCell} | ${toStatus} | ${safeActor} | ${safeReason} |`

  const content = Read(todoPath)

  if (!content.includes('## Status History')) {
    // Add Status History section before end of file
    const header = '## Status History\n\n| Timestamp | From | To | Actor | Reason |\n|-----------|------|----|-------|--------|'
    Edit(todoPath, {
      old_string: content.trimEnd(),
      new_string: content.trimEnd() + '\n\n' + header + '\n' + entry + '\n'
    })
  } else {
    // Append to existing table — find the last row of the Status History table
    // and insert after it. Uses section-targeted Edit for atomic replacement.
    // findLastStatusHistoryRow: extract the Status History section, then find
    // the last markdown table row (line matching /^\| .* \|$/).
    const statusSection = content.substring(content.indexOf('## Status History'))
    const tableRows = statusSection.match(/^\| .* \|$/gm) || []
    const lastTableRow = tableRows[tableRows.length - 1]  // last data row (or header separator)
    if (!lastTableRow) {
      warn(`Todo update: no table rows found in Status History section of ${todoPath}`)
      return
    }
    Edit(todoPath, {
      old_string: lastTableRow,
      new_string: lastTableRow + '\n' + entry
    })
  }
}
```

### Concurrency Safety

Status History appends MUST be serialized through the orchestrator (Tarnished):

1. **Workers do NOT call `appendStatusHistory()` directly**. Workers signal status changes by writing to the signal directory (`tmp/.rune-signals/{team}/{worker-name}-status.json`).
2. **The orchestrator processes signals sequentially** and calls `appendStatusHistory()` for each. Since signals are processed one at a time, no file locking is needed.
3. **Edit() atomicity**: The Edit tool performs atomic section replacement — no partial writes.

This matches the single-writer principle from the existing concurrency model for todo files.

### `assigned_to` Collision Guard

When a worker claims a todo (transition to `in_progress`), the orchestrator MUST verify `assigned_to` is still `null` before writing. This implements compare-and-swap semantics:

```javascript
function claimTodo(todoPath: string, workerName: string): boolean {
  const frontmatter = parseFrontmatter(Read(todoPath))

  if (frontmatter.assigned_to !== null) {
    // Another worker already claimed this todo — reject the claim
    return false
  }

  // Safe to claim — write atomically
  updateFrontmatter(todoPath, {
    status: 'in_progress',
    assigned_to: workerName,
    claimed_at: new Date().toISOString()
  })
  appendStatusHistory(todoPath, 'ready', 'in_progress', workerName, `Claimed for wave ${frontmatter.wave ?? 'manual'}`)
  return true
}
```

## Integration Points

Who calls `appendStatusHistory()` and when:

| Caller | Transition | Actor Format | Reason Pattern |
|--------|-----------|--------------|----------------|
| Triage subcommand | `pending → ready` | `user` | `"Triage approved"` |
| Triage subcommand | `pending → wont_fix` | `user` | Free-text triage reason |
| Strive orchestrator | `— → pending` (creation) | `strive:{timestamp}` | `"Created from plan task: {task subject}"` |
| Strive orchestrator | `ready → in_progress` (claim) | `{worker-name}` | `"Claimed for wave {N}"` |
| Worker via orchestrator | `in_progress → complete` | `{worker-name}` | `"Fixed: {brief description}"` |
| Worker via orchestrator | `in_progress → blocked` | `{worker-name}` | `"Blocked by: {dependency ID}"` |
| Mend orchestrator | `pending → in_progress` | `{fixer-name}` | `"Claimed by mend fixer"` |
| Mend orchestrator | `in_progress → complete` | `{fixer-name}` | `"Fixed: {brief description}"` |
| Review Phase 5.4 | `— → pending` (creation) | `appraise:{identifier}` | `"Created from TOME finding {finding_id}"` |
| Cleanup Phase 6 | `in_progress → interrupted` | `cleanup:phase6` | `"Session ended before completion"` |
| Session resume | `interrupted → ready` | `user` or `{skill}:{timestamp}` | `"Session resumed"` |
| Manual | any → any | `user` | Free-text reason |

## Placement in Todo Body

The `## Status History` section is always the **last section** in a todo file, after `## Work Log`:

```markdown
# {Title}

## Problem Statement
...

## Findings
...

## Proposed Solutions
...

## Recommended Action
...

## Acceptance Criteria
...

## Work Log
...

## Status History

| Timestamp | From | To | Actor | Reason |
|-----------|------|----|-------|--------|
| {entries...} |
```

**Never insert content after `## Status History`** — the append protocol assumes the table extends to EOF.

## Initial Entry on Creation

Every todo MUST have a Status History entry when it is created, recording the `— → pending` (or `— → ready` for pre-triaged todos) transition:

```markdown
| 2026-02-25T12:00:00Z | — | pending | appraise:1771234 | Created from TOME finding SEC-001 |
```

This ensures the audit trail is complete from the very first moment of the todo's existence.
