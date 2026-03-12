# Todo Template — Source-Aware

This template adapts based on the `source` field. Sections marked with source conditions should be included only when the source matches.

## YAML Frontmatter

```yaml
---
schema_version: 2

# --- Existing fields (unchanged) ---
status: pending
priority: p2
issue_id: "XXX"
source: review
source_ref: ""
finding_id: ""
finding_severity: ""
tags: []
dependencies: []
files: []
assigned_to: null
work_session: ""                   # DEPRECATED in v2 — redundant with session-scoped model (retained for backward compat, not populated)
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"

# --- NEW: Resolution metadata ---
resolution: null                    # null | "fixed" | "false_positive" | "duplicate" | "wont_fix" | "out_of_scope" | "superseded"
resolution_reason: ""               # Free-text explanation (required when resolution is set)
resolved_by: ""                     # Agent or user who resolved (e.g., "mend-fixer-1", "user")
resolved_at: ""                     # ISO datetime of resolution

# --- NEW: Ownership audit ---
claimed_at: ""                      # ISO datetime when assigned_to was set
completed_by: ""                    # Agent or user who completed (may differ from assigned_to)
completed_at: ""                    # ISO datetime of completion

# --- NEW: Mend fixer tracking ---
mend_fixer_claim: ""                # Fixer agent name that claimed this todo for mend (e.g., "mend-fixer-1")

# --- NEW: Cross-source linking ---
duplicate_of: ""                    # Qualified ID of the original (when resolution=duplicate): "{source}/{issue_id}"
related_todos: []                   # Qualified IDs of related todos across sources (e.g., ["review/003", "work/005"])
workflow_chain: []                  # Ordered list of workflow events: ["{skill}:{timestamp}", ...]

# --- NEW: Ordering metadata ---
execution_order: null               # Computed by manifest build (topological sort position, 1-indexed, null until computed). Check === null, not !execution_order (0 is reserved sentinel)
wave: null                          # Wave number assigned by strive/mend (null for manual todos). Multiple todos can share a wave.
---
```

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | Yes | Always `2` for current schema; `1` also accepted (backward compat) |
| `status` | string | Yes | `pending`, `ready`, `in_progress`, `complete`, `blocked`, `wont_fix`, `interrupted` |
| `priority` | string | Yes | `p1` (critical), `p2` (important), `p3` (nice-to-have) |
| `issue_id` | string | Yes | 3-digit padded sequential ID (`001`–`999`); 4-digit (`0001`–`9999`) when >999 todos per session |
| `source` | string | Yes | `review`, `work`, `pr-comment`, `tech-debt`, `audit` |
| `source_ref` | string | No | Path or reference to origin (e.g., TOME path, plan path) |
| `finding_id` | string | No | RUNE:FINDING id for review/audit sources |
| `finding_severity` | string | No | Original severity from TOME (P1/P2/P3) |
| `tags` | list | No | Categorization tags |
| `dependencies` | list | No | Qualified IDs this todo is blocked by: `["{source}/{issue_id}", ...]` |
| `files` | list | No | Affected file paths |
| `assigned_to` | string | No | Worker or agent assigned to this todo |
| `work_session` | string | No | **DEPRECATED v2** — retained for backward compat; not populated for new todos |
| `created` | string | Yes | ISO date of creation |
| `updated` | string | Yes | ISO date of last update |
| `resolution` | string\|null | No | Resolution category — null until resolved. See Resolution Categories below. |
| `resolution_reason` | string | When resolution set | Free-text explanation of WHY (required when resolution is non-null) |
| `resolved_by` | string | When resolution set | Agent name or "user" who resolved (required when resolution is non-null) |
| `resolved_at` | string | When resolution set | ISO datetime of resolution (required when resolution is non-null) |
| `claimed_at` | string | No | ISO datetime when `assigned_to` was set |
| `completed_by` | string | No | Agent or user who marked `status: complete` (may differ from `assigned_to`) |
| `completed_at` | string | No | ISO datetime when `status: complete` was set |
| `mend_fixer_claim` | string | No | Fixer agent name that claimed this todo for mend (e.g., `"mend-fixer-1"`) |
| `duplicate_of` | string | When resolution=duplicate | Qualified ID of the canonical original: `"{source}/{issue_id}"` |
| `related_todos` | list | No | Cross-source references: `["{source}/{issue_id}", ...]` |
| `workflow_chain` | list | No | Ordered workflow events (append-only, chronological): `["{skill}:{timestamp}", ...]` |
| `execution_order` | int\|null | No | Topological sort position (1-indexed, computed by manifest build). `null` = not yet computed. **Check `=== null`, not `!execution_order`** — `0` is a reserved sentinel only, `1` is the first valid position. |
| `wave` | int\|null | No | Wave assignment from strive/mend (1-indexed, null for manual todos). Multiple todos can share a wave. |

### Resolution Categories

| Category | When to Use | Example |
|----------|-------------|---------|
| `fixed` | Finding was addressed by code change | Mend fixer resolved the SQL injection |
| `false_positive` | Finding was incorrect — code is actually fine | Reviewer flagged safe constant as hardcoded secret |
| `duplicate` | Same issue as another todo | SEC-003 is the same as SEC-001 but in different file |
| `wont_fix` | Valid finding but won't address (risk accepted) | Legacy code slated for removal |
| `out_of_scope` | Not relevant to current task/sprint | Performance optimization for future sprint |
| `superseded` | Replaced by a newer, broader todo | Individual fixes rolled into refactor plan |

**Note**: `wont_fix` appears as both a **status value** and a **resolution category**. When used as a status, it means the todo was explicitly rejected during triage. When used as a resolution category (with `status: wont_fix`), it means the finding is valid but accepted risk. The resolution field provides the specific reason; the status field records the terminal state.

### Backward Compatibility

- Schema v1 files remain valid — missing fields default to empty/null
- `parseFrontmatter()` returns defaults for missing v2 fields: `resolution: null`, `resolution_reason: ""`, `resolved_by: ""`, `resolved_at: ""`, `claimed_at: ""`, `completed_by: ""`, `completed_at: ""`, `mend_fixer_claim: ""`, `duplicate_of: ""`, `related_todos: []`, `workflow_chain: []`, `execution_order: null`, `wave: null`
- No migration script needed — v2 reader handles both versions transparently

### Qualified ID Format

All cross-reference fields (`duplicate_of`, `related_todos`, `dependencies`, `workflow_chain`) use qualified ID formats:

- **Cross-todo references**: `{source}/{issue_id}` — e.g., `"review/001"`, `"work/042"`
- **Workflow events**: `{skill}:{timestamp}` — e.g., `"appraise:1771234"`, `"mend:1771235"`

The `issue_id` is the numeric prefix string as stored in frontmatter (not the full filename). IDs are per-source per-session: `work/001` and `review/001` are independent.

## Template Body

```markdown
# {Brief Task Title}

## Problem Statement

What is broken, missing, or needs improvement?

## Findings

{Source-conditional sections — include only the matching source block}
```

### Source: review / audit

Include when `source` is `review` or `audit`. Auto-populated from TOME findings.

```markdown
## Findings

- **Finding ID**: {finding_id}
- **File**: `{file}:{line}`
- **Rune Trace**:
  ```
  {code snippet from TOME finding}
  ```
- **Issue**: {description from TOME}
- **Severity**: {finding_severity}
- **Scope**: {diff-scope attribute if available}
```

### Source: work

Include when `source` is `work`. Auto-populated from plan tasks.

```markdown
## Findings

- **Plan task**: {task subject}
- **Plan ref**: `{source_ref}`
- **Risk tier**: {risk tier from plan metadata}
- **Description**: {task description from plan}
```

### Source: pr-comment

Include when `source` is `pr-comment`. Auto-populated from GitHub PR comments.

```markdown
## Findings

- **PR**: #{pr-number}
- **Comment**: {comment body}
- **File**: `{file}:{line}`
- **Author**: {comment author}
```

### Source: tech-debt

Include when `source` is `tech-debt`. Manually created or auto-detected.

```markdown
## Findings

- **Area**: {subsystem or module}
- **Debt type**: {duplication | complexity | coupling | obsolescence}
- **Impact**: {description of ongoing cost}
```

## Common Sections (All Sources)

These sections appear in every todo regardless of source.

```markdown
## Proposed Solutions

### Option 1: {Solution Name}

**Approach**: {description}
**Effort**: {estimate}
**Risk**: Low / Medium / High

## Recommended Action

_Filled during triage or auto-populated from TOME fix recommendation._

## Acceptance Criteria

- [ ] {criterion 1}
- [ ] {criterion 2}
- [ ] Tests pass
- [ ] Ward check clean

## Work Log

### {date} - Initial Discovery

**By**: {agent or user}
**Source**: {workflow that created this todo}

**Actions**:
- Created from {source_ref}

**Learnings**:
- {initial context}

## Status History

| Timestamp | From | To | Actor | Reason |
|-----------|------|----|-------|--------|
| {ISO datetime} | — | pending | {skill}:{id} | Created from {source_ref} |
```

## Work Log Entry Format

Each work session appends a new entry:

```markdown
### {date} - {phase description}

**By**: {agent name or user}

**Actions**:
- {what was done}
- {files modified with paths}

**Learnings**:
- {discoveries, gotchas, decisions}

**Subtasks**:
- [x] {completed item}
- [ ] {remaining item}
```

## Status History Section

The `## Status History` section is **always the last section** in a todo file. It records every status transition as an append-only markdown table.

**Placement**: After `## Work Log`, never add content after `## Status History`.

**Initial entry**: Every todo MUST include a creation entry (`— → pending`) when first written.

For the full append protocol, concurrency safety rules, and integration points, see [status-history.md](status-history.md).
