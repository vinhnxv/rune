---
name: file-todos
description: |
  Structured file-based todo tracking for Rune workflows. Each todo is a markdown
  file with YAML frontmatter and lifecycle status. Source-aware templates adapt for
  review findings, work tasks, PR comments, tech debt, and audit findings.
  Session-scoped: todos live in tmp/{workflow}/{timestamp}/todos/, cleaned by /rune:rest.
  Use when creating, triaging, resolving, or querying todos from any Rune workflow.

  <example>
  user: "/rune:file-todos status"
  assistant: "Scanning session todos for current state..."
  </example>

  <example>
  user: "/rune:file-todos create"
  assistant: "Creating new todo with source-aware template..."
  </example>

  <example>
  user: "/rune:file-todos manifest build"
  assistant: "Building per-source manifests with DAG ordering..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[create|triage|status|list|next|search|resolve|dedup|manifest] [--status=pending] [--priority=p1] [--source=review]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# File-Todos — Structured File-Based Todo Tracking

Session-scoped, source-aware todo tracking across all Rune workflows. Each todo is a standalone markdown file with YAML frontmatter for structured metadata and lifecycle tracking. Todos are co-located with their workflow artifacts in `tmp/`.

## Architecture

### Directory Structure

Todos are session-scoped — each workflow session owns its own `todos/` subdirectory inside `tmp/`:

| Workflow | Todo Base Directory |
|----------|-------------------|
| `/rune:strive` | `tmp/work/{timestamp}/todos/` |
| `/rune:appraise` | `tmp/reviews/{identifier}/todos/` |
| `/rune:audit` | `tmp/audit/{identifier}/todos/` |
| `/rune:mend` | *(uses review/audit session todos — cross-write isolation)* |
| `/rune:arc` | `tmp/arc/{id}/todos/` |

Within each `todos_base`, per-source subdirectories organize todos by origin:

```
tmp/work/1771991022/todos/
├── work/                                     # source: work (from strive)
│   ├── 001-ready-p2-implement-auth-flow.md
│   ├── 002-ready-p3-add-validation.md
│   └── todos-work-manifest.json              # per-source manifest (built by manifest build)
├── review/                                   # source: review (from appraise)
│   ├── 001-pending-p1-fix-sql-injection.md
│   ├── 002-pending-p2-missing-docs.md
│   └── todos-review-manifest.json
├── audit/                                    # source: audit (from audit)
│   ├── 001-pending-p3-dead-code.md
│   └── todos-audit-manifest.json
└── todos-cross-index.json                    # optional cross-source index
```

**ID sequences are per-subdirectory** — `work/001-*` and `review/001-*` are independent. Sessions with >999 todos use 4-digit IDs (`0001-9999`).

### File Naming Convention

```
{issue_id}-{status}-{priority}-{slug}.md
```

| Component | Format | Values |
|-----------|--------|--------|
| `issue_id` | 3-digit padded (4-digit for >999) | `001`, `002`, ... `999`, `1000` |
| `status` | lowercase | `pending`, `ready`, `complete` |
| `priority` | lowercase | `p1` (critical), `p2` (important), `p3` (nice-to-have) |
| `slug` | kebab-case | Max 40 chars, derived from title |

**Priority normalization**: When reading todo files, normalize priority values from various formats to canonical `p1`/`p2`/`p3`: `high`/`critical` -> `p1`, `medium`/`important` -> `p2`, `low`/`nice-to-have` -> `p3`. This ensures backward compatibility with strive-generated todos that use `priority: medium` instead of `priority: p2`.

**Tolerant file naming**: The reader side accepts BOTH v2 naming (`001-ready-p2-slug.md`) AND strive-generated naming (`task-1.md`, `task-2.md`). The v2 format remains canonical for the `create` subcommand. Glob patterns throughout this spec include `task-[0-9]*.md` alongside the standard `[0-9][0-9][0-9]-*.md` patterns.

**Option A (CRITICAL)**: Filename encodes INITIAL status only. Files are NEVER renamed on status transition. The frontmatter `status` field is authoritative. The `in_progress` status exists only in frontmatter, never in the filename.

### Slug Algorithm

The slug algorithm MUST be identical everywhere it is used (orchestrator, workers, integrations):

```
slugify(s):
  1. Convert to lowercase
  2. Replace all non-alphanumeric sequences with a single hyphen
  3. Trim leading/trailing hyphens
  4. Truncate to 40 characters

  Regex: s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
```

### ID Generation

Sequential padded IDs, **independent per source subdirectory**. Use 3-digit format (001-999); auto-upgrade to 4-digit (0001-9999) for sessions with >999 todos. Use zsh-safe glob for counting existing files:

```bash
# zsh-safe: (N) prevents NOMATCH error on empty directory
# source = "work" | "review" | "audit"
# Tolerant: count both v2 naming (NNN-*.md) and strive naming (task-N*.md)
setopt nullglob
existing_3=("${todos_base}/${source}"/[0-9][0-9][0-9]-*.md(N))
existing_4=("${todos_base}/${source}"/[0-9][0-9][0-9][0-9]-*.md(N))
existing_task=("${todos_base}/${source}"/task-[0-9]*.md(N))
total=$(( ${#existing_3[@]} + ${#existing_4[@]} + ${#existing_task[@]} + 1 ))
if (( total > 999 )); then
  next_id=$(printf "%04d" $total)
else
  next_id=$(printf "%03d" $total)
fi
```

This means `work/001-*` and `review/001-*` are independent sequences.

**Sole-orchestrator pattern**: Only the orchestrator creates todo files. Workers send completion signals; the orchestrator writes. This eliminates TOCTOU race conditions in ID generation.

## YAML Frontmatter Schema

Schema v2 adds resolution metadata, ownership audit fields, cross-source linking, and ordering metadata. Schema v1 files remain valid — missing fields default to empty/null.

```yaml
---
schema_version: 2
status: pending           # pending | ready | in_progress | complete | blocked | wont_fix | interrupted
priority: p1              # p1 (critical) | p2 (important) | p3 (nice-to-have)
issue_id: "001"
source: review            # review | work | pr-comment | tech-debt | audit
source_ref: ""            # path or reference back to origin
finding_id: ""            # RUNE:FINDING id (for review/audit sources)
finding_severity: ""      # P1/P2/P3 (for display without re-parsing)
tags: []
dependencies: []          # qualified IDs this is blocked by: ["review/001", "work/003"]
files: []                 # affected files (from source)
assigned_to: null         # worker claim tracking
work_session: ""          # DEPRECATED in v2 — retained for backward compat, not populated
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"

# Resolution metadata (v2)
resolution: null          # null | "fixed" | "false_positive" | "duplicate" | "wont_fix" | "out_of_scope" | "superseded"
resolution_reason: ""     # Free-text explanation (required when resolution is set)
resolved_by: ""           # Agent or user who resolved (e.g., "mend-fixer-1", "user")
resolved_at: ""           # ISO datetime of resolution

# Ownership audit (v2)
claimed_at: ""            # ISO datetime when assigned_to was set
completed_by: ""          # Agent or user who completed (may differ from assigned_to)
completed_at: ""          # ISO datetime of completion

# Cross-source linking (v2)
duplicate_of: ""          # Qualified ID of the original: "{source}/{issue_id}" (when resolution=duplicate)
related_todos: []         # Qualified IDs of related todos: ["review/003", "work/005"]
workflow_chain: []        # Ordered workflow events: ["appraise:1771234", "mend:1771235"]

# Ordering metadata (v2 — computed by manifest build)
execution_order: null     # Topological sort position (null until manifest build runs)
wave: null                # Wave group number (null for manual todos)
---
```

**Status lifecycle** (full):

```
pending --> ready --> in_progress --> complete
  |           |           |             (resolution: fixed)
  |           |           |
  |           |           +--> blocked --> in_progress (when unblocked)
  |           |
  +-----------+---------------> wont_fix
  |                             (resolution: false_positive | duplicate | out_of_scope | superseded | wont_fix)
  |
  +-- in_progress --> interrupted (session ended before completion)
                       --> ready (on session resume)
```

- `pending` — Created, awaiting triage
- `ready` — Triaged and approved for work
- `in_progress` — Actively being worked on (frontmatter-only, NEVER in filename)
- `complete` — Work finished, acceptance criteria met (`resolution: fixed`)
- `blocked` — Blocked by unresolved dependencies
- `wont_fix` — Not being addressed; `resolution` field specifies why
- `interrupted` — Session ended before completion; transitions back to `ready` on resume

Note: `wont_fix` is both a status value AND a resolution outcome. The `resolution` field provides the specific reason within `wont_fix` (false_positive, duplicate, out_of_scope, superseded, or wont_fix for risk-accepted).

## Configuration

File-todos are always active in all Rune workflows. Todos are mandatory — every workflow produces and consumes file-todos as the foundation for task management and teammate assignment.

```yaml
# .claude/talisman.yml
file_todos:
  triage:
    auto_approve_p1: false   # auto-approve P1 findings (skip triage)
```

The `triage` block controls auto-approval behavior. The `dir` key is removed in v2 — todos are session-scoped in `tmp/{workflow}/{timestamp}/todos/`, not at project root.

## Session-Scoped Design

Todos live inside their workflow's `tmp/` directory and are cleaned by `/rune:rest`. This means:
- No stale todos from abandoned sessions
- Each session owns its todo space (no cross-session interference)
- Todos co-locate with TOME, patches, and other workflow artifacts for traceability
- `/rune:file-todos` subcommands auto-detect the most recent active session's `todos_base`

## Sub-Command Dispatch

Route sub-commands via `$ARGUMENTS`. Parse the first argument as the sub-command name. See [subcommands.md](references/subcommands.md) for full implementation details, validation patterns, and helper functions.

```javascript
const args = "$ARGUMENTS".trim()
const subcommand = args.split(/\s+/)[0] || ""
const restArgs = args.slice(subcommand.length).trim()

switch (subcommand) {
  case "create":   // -> create workflow
  case "triage":   // -> triage v2 (resolution-aware)
  case "status":   // -> status report
  case "list":     // -> filtered listing
  case "next":     // -> next ready todo
  case "search":   // -> full-text search
  case "resolve":  // -> mark resolution with metadata
  case "dedup":    // -> detect potential duplicates
  case "manifest": // -> manifest subcommand: build | graph | validate
  default:         // -> show usage help
}
```

For the `manifest` subcommand, parse the second argument as the manifest subcommand:
```javascript
case "manifest": {
  const manifestSub = restArgs.split(/\s+/)[0] || ""
  switch (manifestSub) {
    case "build":    // -> build per-source manifests
    case "graph":    // -> dependency graph visualization
    case "validate": // -> validate manifest integrity
    default:         // -> show manifest usage
  }
}
```

### Validation Patterns

All user-supplied filter values MUST be validated before use. Invalid values produce a clear error message, NOT an empty list.

```
STATUS_PATTERN  = /^(pending|ready|in_progress|complete|blocked|wont_fix|interrupted)$/
PRIORITY_PATTERN = /^p[1-3]$/
SOURCE_PATTERN  = /^(review|work|pr-comment|tech-debt|audit)$/
TAG_PATTERN     = /^[a-zA-Z0-9_-]+$/
TODO_ID_PATTERN = /^[0-9]{3,4}$/
```

## Sub-Commands

### create — Interactive Todo Creation

```
/rune:file-todos create
```

1. Prompt for title/priority/source/files via AskUserQuestion (source selection determines subdirectory)
2. Ensure source subdirectory exists: `mkdir -p {todos_base}/{source}/`
3. Generate next sequential ID from source subdirectory (zsh-safe `(N)` glob, per-subdirectory sequence)
4. Compute slug, write file using [todo-template.md](references/todo-template.md)
5. Report: "Created `{todos_base}/{source}/{filename}`"

**Zero-state**: Auto-creates `{todos_base}/{source}/` if missing.

### triage — Batch Triage Pending Items (v2)

```
/rune:file-todos triage
```

Scan all source subdirectories. Process pending todos sorted by priority (P1 first), capped at 10 per session. See [triage-protocol.md](references/triage-protocol.md) for the full v1 workflow; see [subcommands.md](references/subcommands.md) for the full v2 implementation with resolution-aware options.

**v2 options per item**: Approve (ready), Defer (keep pending), False Positive (wont_fix + resolution), Duplicate (wont_fix + duplicate_of), Out of Scope (wont_fix + out_of_scope), Superseded (wont_fix + superseded).

If `talisman.file_todos.triage.auto_approve_p1 === true`, P1 items auto-approve without user confirmation.

**Zero-state**: "No pending todos found. All items have been triaged."

### status — Summary Report

```
/rune:file-todos status
```

Scan all source subdirectories (`{todos_base}/*/[0-9][0-9][0-9]-*.md`) and display counts grouped by source subdirectory, status, and priority. Output is PLAIN TEXT with no emoji.

```
File-Todos Status
------------------------------
 Pending:     3 (needs triage)
 Ready:       5 (approved)
 In Progress: 2 (active)
 Complete:    12 (done)
 Blocked:     1
 Wont Fix:    0
------------------------------
 P1:  2 pending, 1 ready
 P2:  1 pending, 3 ready
 P3:  0 pending, 1 ready
------------------------------
 By Source Subdirectory:
   work/       7 (4 complete, 2 ready, 1 in_progress)
   review/     8 (5 complete, 2 pending, 1 blocked)
   audit/      3 (2 pending, 1 complete)
   pr-comment/ 2 (1 complete, 1 pending)
------------------------------
```

**Scan pattern**: Tolerant glob matching all naming formats:
```javascript
Glob(`${todosBase}/*/[0-9][0-9][0-9]-*.md`)
  .concat(Glob(`${todosBase}/*/[0-9][0-9][0-9][0-9]-*.md`))
  .concat(Glob(`${todosBase}/*/task-[0-9]*.md`))
```
where `todosBase` is resolved via `resolveSessionContext($ARGUMENTS)`. Only scans the current session's `todos_base`. Arc todos, work todos, and review todos are all session-scoped and accessible via this mechanism.

**Zero-state**: "No todos found. Run `/rune:file-todos create` or run a review/work workflow to auto-generate todos."

### list — Filtered Listing

```
/rune:file-todos list [--status=pending] [--priority=p1] [--source=review] [--tags=security,api]
```

Scans all source subdirectories using tolerant globs (`{todos_base}/*/[0-9][0-9][0-9]-*.md`, `*/[0-9][0-9][0-9][0-9]-*.md`, and `*/task-[0-9]*.md`). Filters compose as intersection. The `--source` filter restricts to a specific subdirectory (e.g., `--source=review` scans only `{todos_base}/review/`). Invalid filter values produce a clear error, not an empty list. Sort: priority (P1 first), then issue_id ascending. See [subcommands.md](references/subcommands.md) for filter parsing and intersection logic.

**Zero-state**: "No todos match the given filters." or "No todos found."

### next — Highest Priority Unblocked Ready Todo

```
/rune:file-todos next [--auto]
```

Scans all source subdirectories using tolerant globs (`*/[0-9][0-9][0-9]-*.md`, `*/[0-9][0-9][0-9][0-9]-*.md`, and `*/task-[0-9]*.md`). Show highest-priority unblocked todo with `status: ready` and no `assigned_to`. Checks `dependencies` against non-complete todos.

**`--auto` flag**: Output JSON, claim atomically via lockfile guard (temp-file-then-rename, NOT flock). Sets `assigned_to`, `claimed_at`, `status: in_progress` in frontmatter. See [subcommands.md](references/subcommands.md) for atomic claim protocol.

**Zero-state distinctions**:
- No todos at all: "No todos found."
- All complete: "All todos are complete."
- All claimed: "All ready todos are assigned. Check in-progress items."
- None ready: "No ready todos. Run `/rune:file-todos triage` to approve pending items."
- All blocked: "All ready todos are blocked by unresolved dependencies."

### search — Full-Text Search

```
/rune:file-todos search <query>
```

Case-insensitive search across all source subdirectories using tolerant globs (`*/[0-9][0-9][0-9]-*.md`, `*/[0-9][0-9][0-9][0-9]-*.md`, and `*/task-[0-9]*.md`). Searches todo titles, problem statements, and work logs. Validates query length (2-200 chars), sanitizes regex metacharacters before Grep. Results grouped by file with metadata, showing source subdirectory. See [subcommands.md](references/subcommands.md) for sanitization and display details.

**Zero-state**: "No matches found for '{query}'."

### resolve — Mark Resolution with Metadata

```
/rune:file-todos resolve 001 --false-positive "Constant value, not user input"
/rune:file-todos resolve 003 --duplicate-of review/001 "Same SQL injection issue"
/rune:file-todos resolve 005 --wont-fix "Legacy code, planned removal in Q2"
/rune:file-todos resolve 007 --out-of-scope "Performance optimization for next sprint"
/rune:file-todos resolve 009 --superseded "Rolled into refactor plan"
/rune:file-todos resolve 003 --undo
```

Set resolution metadata on a todo. Updates `resolution`, `resolution_reason`, `resolved_by`, `resolved_at`, and `status`. `--undo` reverts a resolution to the previous status. See [subcommands.md](references/subcommands.md) for full protocol.

**Zero-state**: "Todo #NNN not found in current session."

### dedup — Detect Potential Duplicates

```
/rune:file-todos dedup
/rune:file-todos dedup --auto-resolve
```

Scan session todos for potential duplicates using composite scoring (Jaro-Winkler + Jaccard file overlap + finding type + source_ref). Flags pairs with confidence >= 0.70. `--auto-resolve` auto-marks >= 0.90 confidence pairs as duplicate. See [subcommands.md](references/subcommands.md) for algorithm details.

**Zero-state**: "No duplicate candidates found."

### manifest build — Build Per-Source Manifests

```
/rune:file-todos manifest build
/rune:file-todos manifest build --all
/rune:file-todos manifest build --cross-source
/rune:file-todos manifest build --dedup
```

Build (or incrementally rebuild) `todos-{source}-manifest.json` files for the current session. Runs Kahn's topological sort, wave assignment, and critical path analysis. See [manifest-schema.md](references/manifest-schema.md) for schema and [dag-ordering.md](references/dag-ordering.md) for algorithm.

**Zero-state**: "No source subdirectories found in current session."

### manifest graph — Dependency Visualization

```
/rune:file-todos manifest graph [--source=work] [--all-sources] [--waves] [--mermaid]
```

Display ASCII dependency graph (default) or Mermaid diagram (`--mermaid`). Auto-detects primary source for the active workflow. `--all-sources` requires cross-index (build with `manifest build --cross-source`). See [subcommands.md](references/subcommands.md) for output examples.

### manifest validate — Validate Integrity

```
/rune:file-todos manifest validate
```

Validate per-source manifests for circular dependencies, dangling references, missing resolution reasons, and schema issues. P1 errors are blocking; P2 warnings are advisory. See [subcommands.md](references/subcommands.md) for validation tier table.

## Performance: Per-Source Manifest Cache

For sessions with >100 todos, per-source manifests (`todos-{source}-manifest.json`) avoid re-parsing all frontmatter. Per-source dirty-signal invalidation: any modifying sub-command writes `{source}/.dirty`; next `manifest build` rebuilds only dirty sources via atomic tmp-rename. Manifest is optional — fallback to direct parsing on missing or corrupt manifest. See [manifest-schema.md](references/manifest-schema.md) and [subcommands.md](references/subcommands.md) for full protocol.

## Integration Points

| Trigger | Flow | Source | Reference |
|---------|------|--------|-----------|
| `/rune:appraise` | TOME findings -> per-finding todos | `review` | [integration-guide.md](references/integration-guide.md) |
| `/rune:audit` | TOME findings -> per-finding todos | `audit` | [integration-guide.md](references/integration-guide.md) |
| `/rune:strive` | Plan tasks -> per-task todos | `work` | [integration-guide.md](references/integration-guide.md) |
| `/rune:mend` | Resolution tracking -> todo updates | updates existing | [integration-guide.md](references/integration-guide.md) |
| `/rune:test-browser` | E2E failures -> per-route todos | `test-browser` | [integration-guide.md](references/integration-guide.md) |
| PR comments | gh API -> per-comment todos | `pr-comment` | [integration-guide.md](references/integration-guide.md) |

## Concurrent Access

| Operation | Who Can Perform | Safe? |
|-----------|----------------|-------|
| Create todo (Write) | Orchestrator only | Yes — single writer |
| Read todo (Read) | Anyone | Yes — reads are safe |
| Append Work Log (Edit) | Worker assigned to task only | Yes — one worker per task |
| Update frontmatter status | Orchestrator or mend-fixer | Conditional — needs claim lock |
| Delete (cleanup) | `/rune:rest` cleanup phase only | Yes — after workflow completes |

## References

- [todo-template.md](references/todo-template.md) — Source-aware todo template with YAML frontmatter schema (v2)
- [lifecycle.md](references/lifecycle.md) — Status transitions and lifecycle rules (resolution-aware v2)
- [triage-protocol.md](references/triage-protocol.md) — Batch triage workflow for pending items
- [integration-guide.md](references/integration-guide.md) — How each Rune workflow feeds/consumes todos
- [subcommands.md](references/subcommands.md) — Full sub-command implementation details, helpers, session context, and manifest protocol
- [manifest-schema.md](references/manifest-schema.md) — Per-source manifest JSON schema and cross-source index format
- [dag-ordering.md](references/dag-ordering.md) — Kahn's algorithm, wave assignment, and critical path implementation
