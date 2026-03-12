# Per-Source Manifest Schema

Reference for `todos-{source}-manifest.json` files — the per-source orchestration manifests that replace `.todo-index.json` (v1 performance cache).

## Overview

Each source subdirectory gets its own focused manifest file:

```
{todos_base}/
├── work/
│   ├── 001-ready-p2-implement-auth.md
│   ├── 002-pending-p3-add-logging.md
│   └── todos-work-manifest.json       ← per-source manifest
├── review/
│   ├── 001-pending-p1-fix-sql-injection.md
│   └── todos-review-manifest.json     ← per-source manifest
├── audit/
│   ├── 001-pending-p3-dead-code.md
│   └── todos-audit-manifest.json      ← per-source manifest
└── todos-cross-index.json             ← optional cross-source index
```

**Why per-source (not monolithic)**:
- **Reduced LLM context**: Strive reads only `todos-work-manifest.json` (~50KB for 100 work todos) instead of all 500 todos across sources
- **Phase isolation**: Each workflow phase processes only its own manifest — mend reads review manifest, strive reads work manifest
- **Smaller writes**: Updating a single source manifest is faster and less prone to concurrent write conflicts
- **Incremental rebuild**: Only the dirty source needs rebuilding — others are untouched

## Per-Source Manifest Schema

**File location**: `{todos_base}/{source}/todos-{source}-manifest.json`

```json
{
  "schema_version": 2,
  "source": "work",
  "generated_at": "2026-02-25T12:00:00Z",
  "generated_by": "manifest-build",

  "session": {
    "workflow": "strive",
    "session_id": "1771991022",
    "started_at": "2026-02-25T11:00:00Z",
    "todos_base": "tmp/work/1771991022/todos/"
  },

  "summary": {
    "total": 12,
    "by_status": {
      "pending": 0,
      "ready": 3,
      "in_progress": 2,
      "complete": 5,
      "blocked": 1,
      "wont_fix": 0,
      "interrupted": 1
    },
    "by_priority": { "p1": 2, "p2": 8, "p3": 2 }
  },

  "todos": [
    {
      "id": "work/001",
      "file": "001-ready-p2-implement-auth.md",
      "status": "complete",
      "priority": "p2",
      "finding_id": null,
      "assigned_to": "rune-smith-1",
      "dependencies": [],
      "dependents": ["work/003"],
      "related_todos": ["review/001"],
      "resolution": "fixed",
      "resolved_by": "rune-smith-1",
      "resolved_at": "2026-02-25T14:00:00Z",
      "execution_order": 1,
      "wave": 1,
      "workflow_chain": ["strive:1771991022"],
      "title": "Implement auth module"
    }
  ],

  "dependency_graph": {
    "edges": [
      { "from": "work/003", "to": "work/001", "type": "blocked_by" }
    ],
    "topological_order": ["work/001", "work/002", "work/003"],
    "waves": [
      { "wave": 1, "todos": ["work/001", "work/002"] },
      { "wave": 2, "todos": ["work/003"] }
    ],
    "has_cycles": false,
    "unresolved_deps": [],
    "cross_source_refs": ["review/001"]
  },

  "resolution_log": [
    {
      "id": "work/001",
      "resolution": "fixed",
      "resolution_reason": "Implemented with tests",
      "resolved_by": "rune-smith-1",
      "resolved_at": "2026-02-25T14:00:00Z"
    }
  ]
}
```

## Schema Fields Reference

### Top-Level Fields

| Field | Type | Description |
|-------|------|-------------|
| `schema_version` | int | Always `2` for per-source manifests |
| `source` | string | Source identifier: `work`, `review`, `audit`, `pr-comment`, `tech-debt` |
| `generated_at` | string | ISO datetime when manifest was last built |
| `generated_by` | string | Always `"manifest-build"` (for audit traceability) |

### `session` Object

Captures the workflow session that created this todo source:

| Field | Type | Description |
|-------|------|-------------|
| `workflow` | string | Originating skill: `strive`, `appraise`, `audit`, `mend` |
| `session_id` | string | Workflow timestamp identifier |
| `started_at` | string | ISO datetime when workflow session started |
| `todos_base` | string | Path to the todos base directory for this session |

### `summary` Object

At-a-glance counts for fast status reporting:

| Field | Type | Description |
|-------|------|-------------|
| `total` | int | Total todo count for this source |
| `by_status` | object | Count per status value (includes `interrupted`) |
| `by_priority` | object | Count per priority value (`p1`, `p2`, `p3`) |

### `todos` Array — Per-Todo Entry

Each entry is a flattened projection of the todo's YAML frontmatter plus computed fields:

| Field | Type | Source | Description |
|-------|------|--------|-------------|
| `id` | string | Computed | Qualified ID: `{source}/{issue_id}` (e.g., `work/001`) |
| `file` | string | Computed | Filename only (not full path) — relative to source subdir |
| `status` | string | Frontmatter | Current status value |
| `priority` | string | Frontmatter | Priority level: `p1`, `p2`, `p3` |
| `finding_id` | string\|null | Frontmatter | RUNE:FINDING reference (for review/audit sources) |
| `assigned_to` | string\|null | Frontmatter | Worker claim or `null` |
| `dependencies` | string[] | Frontmatter | Qualified IDs this todo is blocked by |
| `dependents` | string[] | **Computed** | Reverse of `dependencies` — todos blocked by this one |
| `related_todos` | string[] | Frontmatter | Cross-source related IDs |
| `resolution` | string\|null | Frontmatter | Resolution category (`fixed`, `false_positive`, etc.) |
| `resolved_by` | string | Frontmatter | Agent or user who resolved |
| `resolved_at` | string | Frontmatter | ISO datetime of resolution |
| `execution_order` | int\|null | **Computed** | Topological sort position (1-indexed, `null` until built) |
| `wave` | int\|null | **Computed** | Parallel wave group number (1-indexed) |
| `workflow_chain` | string[] | Frontmatter | Ordered workflow events: `["{skill}:{timestamp}", ...]` |
| `title` | string | Computed | First H1 heading from todo body (after frontmatter) |

**`dependents` computation**: The `dependents` field is NEVER stored in todo frontmatter — it is computed by `manifest build` by inverting the adjacency list. Cross-source dependents (e.g., a `review` todo that depends on a `work` todo) appear in `cross_source_refs` of the dependency_graph, not in `dependents`.

**`execution_order` semantics**: `null` means "not yet computed" (manifest build hasn't run). `0` is a reserved sentinel only — `1` is the first valid position (1-indexed, consistent with `wave`). Consumers MUST check `=== null`, not `!execution_order`.

### `dependency_graph` Object

DAG metadata computed by Kahn's algorithm during `manifest build`:

| Field | Type | Description |
|-------|------|-------------|
| `edges` | object[] | Directed edges within this source: `{ from, to, type }` |
| `topological_order` | string[] | Qualified IDs sorted in dependency order (roots first) |
| `waves` | object[] | Wave assignments: `[{ wave: N, todos: [...ids] }, ...]` |
| `has_cycles` | bool | `true` if circular dependencies detected (build still proceeds with warnings) |
| `unresolved_deps` | string[] | IDs that could not be topologically sorted (part of cycles) |
| `cross_source_refs` | string[] | Dependencies/related_todos that reference other sources — triggers cross-source index |

**Edge types**:
- `blocked_by` — The `from` todo cannot start until `to` is complete
- `related` — Informational link (not a blocking dependency)

### `resolution_log` Array

Chronological log of all resolutions for this source. Appended on each resolution; fully rebuilt on `manifest build`:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Qualified ID of the resolved todo |
| `resolution` | string | Resolution category |
| `resolution_reason` | string | Free-text explanation |
| `resolved_by` | string | Agent or user who resolved |
| `resolved_at` | string | ISO datetime of resolution |

## Cross-Source Index Schema

**File location**: `{todos_base}/todos-cross-index.json`

Built when:
- `manifest build --cross-source` — explicit request
- `dedup` subcommand — needs cross-source comparison
- `manifest graph --all-sources` — visualizing full DAG
- Arc completion — for the completion report summary

NOT built by default (only per-source manifests are built).

```json
{
  "schema_version": 2,
  "generated_at": "2026-02-25T12:00:00Z",
  "sources": ["work", "review", "audit"],

  "cross_source_edges": [
    { "from": "work/003", "to": "review/001", "type": "blocked_by" },
    { "from": "work/005", "to": "review/001", "type": "related" }
  ],

  "dedup_candidates": [
    {
      "group": "sql-injection-fixes",
      "todos": ["review/001", "audit/003"],
      "reason": "Same file (src/db.ts), similar finding (SQL injection)",
      "confidence": 0.85
    }
  ],

  "aggregate_summary": {
    "total": 25,
    "by_source": { "review": 10, "work": 12, "audit": 3 },
    "by_status": {
      "pending": 5,
      "ready": 8,
      "in_progress": 3,
      "complete": 7,
      "blocked": 1,
      "wont_fix": 1,
      "interrupted": 0
    },
    "false_positives": 1,
    "duplicates": 2
  }
}
```

### Cross-Source Index Fields

| Field | Type | Description |
|-------|------|-------------|
| `sources` | string[] | All source directories included in this index |
| `cross_source_edges` | object[] | Directed edges that span source boundaries |
| `dedup_candidates` | object[] | Potential duplicate groups (populated by `--dedup`) |
| `aggregate_summary` | object | Combined counts across all sources |

**`dedup_candidates` entry fields**:
- `group` — Auto-generated group name (based on common title tokens)
- `todos` — Qualified IDs of potential duplicates
- `reason` — Human-readable explanation of why they were flagged
- `confidence` — Score 0.0–1.0 (>= 0.70 = flagged, >= 0.90 = auto-resolvable)

## Dirty Signal Protocol

Dirty signals are **per-source subdirectory** to enable incremental rebuilds:

| Signal File | Trigger | Cleared By |
|------------|---------|-----------|
| `{todos_base}/{source}/.dirty` | Any todo file modification in this source | `manifest build` after rebuilding that source |
| `{todos_base}/.cross-dirty` | Any cross-source ref changes | `manifest build --cross-source` after rebuilding |

**Dirty signal rules**:
- Any subcommand that modifies a todo file (Edit frontmatter, append Work Log) MUST touch `{source}/.dirty`
- `manifest build` checks each source's dirty signal independently
- Only dirty sources are rebuilt — clean sources skip (use cached manifest)
- Dirty signals are session-local — no cross-session interference (located inside session's `todos_base`)

**Incremental rebuild performance**: For 100 todos per source, full rebuild takes <20ms. Full 500-todo rebuild across all sources: <100ms. No optimization beyond dirty-signal skipping is needed.

## Manifest Build Algorithm

```javascript
/**
 * Build per-source manifests for all dirty sources.
 * @param {string} todosBase - Base directory for this session's todos
 * @param {object} options - { all: bool, crossSource: bool, dedup: bool }
 */
function buildManifests(todosBase: string, options: BuildOptions): BuildResult {
  // 1. Discover source subdirectories
  const sources = discoverSources(todosBase)
  // sources = ["work", "review", "audit"] (from existing subdirs)

  const results = []
  for (const source of sources) {
    const isDirty = fileExists(`${todosBase}/${source}/.dirty`)
    if (!options.all && !isDirty) {
      results.push({ source, skipped: true, reason: "clean" })
      continue
    }

    // 2a. Scan todo files (tolerant: v2 3-digit, 4-digit, AND strive task-N naming)
    const files = Glob(`${todosBase}/${source}/[0-9][0-9][0-9]-*.md`)
      .concat(Glob(`${todosBase}/${source}/[0-9][0-9][0-9][0-9]-*.md`))
      .concat(Glob(`${todosBase}/${source}/task-[0-9]*.md`))

    // 2b. Parse frontmatter (v1 and v2 compatible)
    // Guard: skip files with corrupt or missing frontmatter (no silent ghost todos)
    const todos = files.map(f => {
      try { return parseTodoFile(f, source) }
      catch (e) { warn(`WARN: skipped corrupt todo file ${f} (${e.message})`); return null }
    }).filter(Boolean)

    // 2c. Build dependency graph + topological sort + wave assignment
    const dagResult = buildDependencyDAG(todos)
    if (dagResult.hasCycles) {
      warn(`WARN ${source}/: cycle detected — todos [${dagResult.unresolvedDeps.join(', ')}] excluded from wave assignment`)
    }
    const waves = assignWaves(dagResult.order, todos)
    const critPath = criticalPath(todos, dagResult.graph, dagResult.reverse, dagResult.order)

    // 2d. Collect cross-source refs
    const crossSourceRefs = collectCrossSourceRefs(todos)

    // 2e. Compute derived fields (dependents, execution_order, title)
    const enrichedTodos = enrichTodos(todos, dagResult, waves, critPath)

    // 2f. Build manifest object
    const manifest = buildManifestObject(source, todosBase, enrichedTodos, dagResult, waves, crossSourceRefs)

    // 2g. Atomic write: tmp → rename
    const tmpPath = `${todosBase}/${source}/todos-${source}-manifest.json.tmp`
    const finalPath = `${todosBase}/${source}/todos-${source}-manifest.json`
    Write(tmpPath, JSON.stringify(manifest, null, 2))
    Bash(`mv "${tmpPath}" "${finalPath}"`)

    // 2h. Remove dirty signal
    Bash(`rm -f "${todosBase}/${source}/.dirty"`)

    // 2i. Set cross-dirty if cross-source refs changed
    if (crossSourceRefs.length > 0) {
      Bash(`touch "${todosBase}/.cross-dirty"`)
    }

    results.push({ source, built: true, count: todos.length })
  }

  // 3. Optional: build cross-source index
  if (options.crossSource || options.dedup) {
    const crossIndex = buildCrossSourceIndex(todosBase, sources, options.dedup)
    const tmpPath = `${todosBase}/todos-cross-index.json.tmp`
    Write(tmpPath, JSON.stringify(crossIndex, null, 2))
    Bash(`mv "${tmpPath}" "${todosBase}/todos-cross-index.json"`)
    Bash(`rm -f "${todosBase}/.cross-dirty"`)
  }

  return { sources: results }
}
```

## Size Estimation

| Session Size | Todos/Source | Manifest Size | 6x vs. Monolithic |
|-------------|-------------|---------------|-------------------|
| Small | 20 | ~14KB | ~84KB monolithic |
| Medium | 100 | ~70KB | ~420KB monolithic |
| Large | 500 | ~350KB | 2.1MB monolithic |

Each todo entry in the manifest is approximately 700 bytes (serialized JSON with all fields). The per-source approach keeps LLM context lean — Strive reads only the `work` manifest, not all 500 todos.

## Backward Compatibility

- `schema_version: 1` manifests (old `.todo-index.json`) are obsolete — readers should rebuild if they encounter v1 format
- All consumers that previously read `.todo-index.json` MUST be updated to read per-source manifests
- The `manifest build` command checks for the v1 cache file and removes it on first run: `rm -f "{todos_base}/.todo-index.json"`

## Integration Points

| Consumer | Reads | Purpose |
|----------|-------|---------|
| Strive (wave executor) | `todos-work-manifest.json` | Wave assignment, dependency ordering |
| Appraise (Phase 5.4) | `todos-review-manifest.json` | Resolution tracking |
| Mend orchestrator | `todos-review-manifest.json` | Finding priority + wave assignment |
| Audit (Phase 5.4) | `todos-audit-manifest.json` | Finding priority + resolution |
| `manifest graph` | Per-source or cross-index | Dependency visualization |
| `manifest validate` | Per-source | Integrity checking |
| Arc completion report | Cross-index | Summary statistics |
| `dedup` subcommand | Cross-index | Duplicate candidate detection |
