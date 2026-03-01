# Todo Lifecycle — Status Transitions

## Status Definitions

| Status | Meaning | In Filename? | In Frontmatter? |
|--------|---------|:------------:|:---------------:|
| `pending` | Created, awaiting triage | Yes (initial) | Yes |
| `ready` | Triaged and approved for work | Yes (initial) | Yes |
| `in_progress` | Actively being worked on | NEVER | Yes |
| `complete` | Work finished, criteria met | Yes (initial, rare) | Yes |
| `blocked` | Blocked by dependencies | NEVER | Yes |
| `wont_fix` | Rejected during triage or risk-accepted | NEVER | Yes |
| `interrupted` | Session ended before completion | NEVER | Yes |

**`interrupted` status**: Applied by cleanup Phase 6 when a session ends with todos still `in_progress`. Prevents stale `in_progress` todos from blocking future sessions. Can transition back to `ready` when the session resumes or is picked up by a new session.

## Transition Diagram

```
                    ┌──────────────┐
                    │   pending    │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            │            ▼
      ┌──────────────┐    │    ┌──────────────────────┐
      │    ready      │    │    │   wont_fix            │
      └──────┬───────┘    │    │  resolution: *         │
             │            │    │  resolution_reason: *   │
             ▼            │    └──────────────────────┘
      ┌──────────────┐    │
      │ in_progress  │    │
      └──────┬───────┘    │
             │            │
        ┌────┼────┐       │
        │    │    │       │
        ▼    ▼    ▼       │
┌──────────────┐ ┌────────────┐ ┌──────────────┐
│  complete    │ │  blocked   │ │ interrupted  │
│  resolution: │ └─────┬──────┘ │  (session    │
│    fixed     │       │        │   ended)     │
│  resolved_by │       ▼        └──────┬───────┘
│  resolved_at │ ┌──────────────┐      │
└──────────────┘ │ in_progress  │      ▼ (on resume)
                 └──────────────┘ ┌──────────────┐
                                  │    ready      │
                                  └──────────────┘
```

## Transition Rules

### Valid Transitions

| From | To | Required Fields | Triggered By | Action |
|------|----|----------------|-------------|--------|
| `pending` | `ready` | — | Triage approval | Edit frontmatter `status: ready` |
| `pending` | `wont_fix` | `resolution` + `resolution_reason` + `resolved_by` + `resolved_at` | Triage rejection | Edit frontmatter `status: wont_fix`, set resolution fields |
| `pending` | `complete` | `resolution: fixed` + `resolved_by` + `resolved_at` | Direct resolution (e.g., mend) | Edit frontmatter `status: complete`, set resolution fields |
| `ready` | `in_progress` | `assigned_to` + `claimed_at` | Worker claims todo | Edit frontmatter `status: in_progress`, set `assigned_to`, `claimed_at` |
| `in_progress` | `complete` | `resolution: fixed` + `resolved_by` + `resolved_at` + `completed_by` + `completed_at` | Worker/fixer completion | Edit frontmatter `status: complete`, set all completion fields, add Work Log |
| `in_progress` | `blocked` | `dependencies` updated | Dependency found | Edit frontmatter `status: blocked`, add to `dependencies` |
| `in_progress` | `interrupted` | `resolution_reason` | Cleanup Phase 6 (session ended) | Edit frontmatter `status: interrupted`, set `resolution_reason: "Session ended before completion"` |
| `in_progress` | `wont_fix` | `resolution` + `resolution_reason` + `resolved_by` + `resolved_at` | Manual or triage override | Edit frontmatter `status: wont_fix`, set resolution fields |
| `blocked` | `in_progress` | — | Dependency resolved | Edit frontmatter `status: in_progress` |
| `interrupted` | `ready` | — | Session resume or new session pickup | Edit frontmatter `status: ready`, clear `assigned_to` |
| Any | `wont_fix` | `resolution` (one of: `false_positive`, `duplicate`, `wont_fix`, `out_of_scope`, `superseded`) + `resolution_reason` + `resolved_by` + `resolved_at` | Manual or triage | Edit frontmatter `status: wont_fix`, set resolution fields |

### Invalid Transitions

- `complete` → any other status (final state)
- `wont_fix` → any other status (final state)
- Any status → `in_progress` without `assigned_to` being set
- Any status → `in_progress` without `claimed_at` being set

### Validation Contract

When setting `resolution` (any value):
- `resolution_reason` is **REQUIRED** (non-empty string)
- `resolved_by` is **REQUIRED** (agent name or `"user"`)
- `resolved_at` is **REQUIRED** (ISO datetime)
- When `resolution === "duplicate"`: `duplicate_of` is **REQUIRED** (qualified ID of existing todo: `"{source}/{issue_id}"`)

When transitioning to `complete`:
- `resolution` MUST be `"fixed"` (or another valid category for direct resolution)
- `completed_by` is **REQUIRED**
- `completed_at` is **REQUIRED**

## Option A: No File Renames

Filenames encode the INITIAL status at creation time. Files are NEVER renamed when status changes.

**Why**: Renaming files during status transitions creates race conditions when multiple agents read/write concurrently. With Option A, filenames are stable references that never change.

**The frontmatter `status` field is authoritative.** When reading todo status, always parse frontmatter — never infer status from the filename.

**Example**: A file named `001-pending-p1-fix-injection.md` may have frontmatter `status: complete` after being resolved by mend. The filename still says `pending` but the authoritative status is `complete`.

## Status Queries

To find todos by current status, parse frontmatter:

```bash
# Find all in-progress todos (zsh-safe, tolerant of all naming formats)
for f in todos/*/[0-9][0-9][0-9]-*.md(N) \
         todos/*/[0-9][0-9][0-9][0-9]-*.md(N) \
         todos/*/task-[0-9]*.md(N); do
  if grep -q '^status: in_progress' "$f"; then
    echo "$f"
  fi
done
```

Do NOT use filename patterns to determine current status. The filename is a creation-time artifact only.

## Stale Detection

Todos can become stale when:

1. **Orphaned work session**: `work_session` (v1, deprecated) references a session that no longer exists
2. **Long-running in_progress**: No Work Log updates for extended period — session may have ended without cleanup
3. **Unresolved blocked**: Dependencies never resolved
4. **Lingering interrupted**: `interrupted` todos that were never resumed

**Prevention**: Todos are session-scoped in `tmp/{workflow}/{id}/todos/`. Cleanup Phase 6 of each workflow MUST transition any remaining `in_progress` todos to `interrupted` before the session ends. Cleanup logic must scope to the current session only — do not modify todos from other sessions.

**Recovery**: On session resume, `interrupted` todos should transition back to `ready` so they can be re-claimed by workers.

## Idempotency

Re-running a workflow that generates todos (e.g., re-running review on the same TOME) must not create duplicates. Before creating a todo:

1. Check for existing todo with matching `finding_id` + `source_ref`
2. If match found, skip creation
3. If no match, create new todo with next sequential ID

## Cleanup

In v2, todos are session-scoped inside `tmp/{workflow}/{id}/todos/`. They are cleaned up when `/rune:rest` removes the `tmp/` directory for that session. There is no persistent project-root `todos/` directory.

Cleanup options for session todos:
- **Automatic via `/rune:rest`**: Removes entire `tmp/{workflow}/{id}/` including todos
- **Manual deletion**: Remove specific todo files with confirmation
- **Leave until rest**: Session todos persist until explicitly cleaned

Cleanup is always manual or orchestrator-initiated, never automatic during active workflows.
