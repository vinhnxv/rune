# Triage Protocol — Batch Processing for Pending Todos

## Overview

Triage is the process of reviewing pending todos and deciding their disposition: approve (move to ready), defer (keep pending), reject (mark wont_fix), or reprioritize.

## Workflow

### Step 1: Gather Pending Todos

```bash
# zsh-safe glob (tolerant: v2 naming + strive task-N naming)
pending_files=()
for f in todos/*/[0-9][0-9][0-9]-*.md(N) \
         todos/*/[0-9][0-9][0-9][0-9]-*.md(N) \
         todos/*/task-[0-9]*.md(N); do
  pending_files+=("$f")
done
```

Filter to only those with frontmatter `status: pending`.

### Step 2: Sort by Priority

Process P1 first, then P2, then P3. Within the same priority, process by creation date (oldest first, using `issue_id` as proxy).

### Step 3: Cap at 10 Per Session

To prevent decision fatigue and maintain quality, process a maximum of 10 pending todos per triage session. If more than 10 are pending, report the remaining count after processing.

### Step 4: For Each Pending Todo

1. Read the todo file
2. Display summary:
   ```
   Todo #{issue_id} [{priority}] — {title}
   Source: {source} | Files: {files count} | Created: {created}

   Problem: {first 2 lines of Problem Statement}
   ```
3. Present triage options:
   - **Approve** — Set `status: ready`. Todo is now available for work.
   - **Defer** — Keep `status: pending`. No changes. Revisit in next triage.
   - **Reject** — Set `status: wont_fix`. Add reason to Work Log.
   - **Reprioritize** — Change `priority` (e.g., P2 to P1). Keep status as pending or approve.

### Step 5: Apply Decision

For each decision:

1. Edit frontmatter `status` field
2. Edit `updated` date to today
3. If rejected: add Work Log entry with rejection reason
4. If reprioritized: edit `priority` field

### Step 6: Report

After processing all items (or reaching the 10-item cap):

```
Triage Complete
─────────────────────────
 Approved:      4 (moved to ready)
 Deferred:      2 (kept pending)
 Rejected:      1 (marked wont_fix)
 Reprioritized: 1 (priority changed)
─────────────────────────
 Remaining pending: 3
```

## Auto-Approve Rules

If `talisman.file_todos.triage.auto_approve_p1` is `true`:

- P1 todos are automatically approved (pending -> ready) without user interaction
- Report auto-approved items separately:
  ```
  Auto-approved: 2 P1 items (talisman.file_todos.triage.auto_approve_p1)
  ```

## Triage Criteria Guidelines

When assisting with triage decisions, consider:

| Factor | Approve | Defer | Reject |
|--------|---------|-------|--------|
| Severity | P1 critical | P3 cosmetic | False positive |
| Scope | Clear fix path | Needs investigation | Out of scope |
| Dependencies | None / resolved | Blocked by other work | Superseded |
| Effort | Reasonable | Needs decomposition | Cost > benefit |

## Batch Triage from Review

When multiple todos are generated from a single review/audit TOME:

1. Group by priority tier (P1 → P2 → P3)
2. Auto-approve P1 if configured
3. Present P2 items with TOME context (finding description + recommended fix)
4. Present P3 items as a summary list (approve all / reject all option)

This reduces the number of individual decisions while maintaining quality for high-priority items.
