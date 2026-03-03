---
name: rune:file-todos
description: |
  Manage file-based todos — create, triage, list, search, resolve, dedup, and track
  structured todo files with YAML frontmatter and source-aware templates.
  Session-scoped: todos live in tmp/{workflow}/{id}/todos/, cleaned by /rune:rest.

  <example>
  user: "/rune:file-todos status"
  assistant: "Scanning session todos for current state..."
  </example>

  <example>
  user: "/rune:file-todos create"
  assistant: "Creating new todo with source-aware template..."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
argument-hint: "[create|triage|status|list|next|search|resolve|dedup|manifest] [--status=pending] [--priority=p1] [--source=review] [--session tmp/work/...]"
---

# /rune:file-todos — Manage File-Based Todos

Manage structured file-based todos in session-scoped `tmp/{workflow}/{id}/todos/`.

## Usage

```
/rune:file-todos create             # Interactive todo creation
/rune:file-todos triage             # Batch triage pending items
/rune:file-todos status             # Summary: counts by status, priority, source
/rune:file-todos list [--status=pending] [--priority=p1] [--source=review]
/rune:file-todos next [--auto]      # Highest-priority unblocked ready todo
/rune:file-todos search <query>     # Full-text search across titles and notes
/rune:file-todos resolve <id> --false-positive|--duplicate-of|--wont-fix|--out-of-scope|--superseded "reason"
/rune:file-todos dedup [--auto-resolve]  # Detect potential duplicates
/rune:file-todos manifest build|graph|validate  # Per-source manifest management
```

Use `--session tmp/work/20260226-100322/` to target a specific session.

## Execution

Load and execute the `file-todos` skill (`skills/file-todos/SKILL.md`) with all arguments passed through.
The skill contains `resolveSessionContext()`, `$ARGUMENTS` parsing, and all subcommand dispatch logic.
Without loading the skill first, none of the subcommands below will work.

## Subcommands

### create — Interactive Todo Creation

1. Ask for title, priority, source, affected files
2. Generate next sequential ID (zsh-safe)
3. Compute slug from title
4. Write file using todo template
5. Report created file path

### triage — Batch Triage Pending Items (v2)

Process pending todos sorted by priority (P1 first). Capped at 10 per session.

Options per item:
- Approve (pending -> ready)
- Defer (keep pending)
- False Positive (mark wont_fix + resolution)
- Duplicate (mark wont_fix + duplicate_of)
- Out of Scope (mark wont_fix + out_of_scope)
- Superseded (mark wont_fix + superseded)

### status — Summary Report

Scan session todos and display counts by status, priority, and source. Plain text output (no emoji).

### list — Filtered Listing

List todos with optional filters. Filters compose as intersection. Invalid filter values produce a clear error, not an empty list.

### next — Next Ready Todo

Show highest-priority unblocked todo with `status: ready`. Use `--auto` for JSON output with atomic claim for programmatic use by workers.

### search — Full-Text Search

Search across todo titles, problem statements, and work logs. Case-insensitive. Results grouped by file with context lines.

### resolve — Mark Resolution with Metadata

Set resolution metadata on a todo. Supports `--false-positive`, `--duplicate-of`, `--wont-fix`, `--out-of-scope`, `--superseded`, and `--undo`.

### dedup — Detect Potential Duplicates

Scan session todos for potential duplicates using composite scoring (Jaro-Winkler + Jaccard file overlap). Use `--auto-resolve` for >= 0.90 confidence auto-resolution.

### manifest build — Build Per-Source Manifests

Build (or incrementally rebuild) per-source manifests with DAG ordering.

### manifest graph — Dependency Visualization

Display ASCII dependency graph or Mermaid diagram (`--mermaid`).

### manifest validate — Validate Integrity

Validate per-source manifests for circular dependencies, dangling references, and schema issues.
