# Integration Guide — Rune Workflows and File-Todos

> **STANDALONE ONLY (v1.153.0+)**: File-todos are no longer integrated into Rune workflow pipelines (arc, strive, appraise, mend, audit). The workflow integration described below is **historical reference only**. File-todos now run as standalone tools via `/rune:file-todos` and `/rune:resolve-todos`. The directory resolution and template patterns below remain valid for standalone use.

## Overview

File-todos can connect to Rune workflows as both producers (creating todos) and consumers (reading/updating todos). This document describes the session-scoped model introduced in v1.101.0. As of v1.153.0, these integrations are **not active** — file-todos must be invoked manually.

## Standalone Usage

File-todos are invoked directly by the user when needed:
- `/rune:file-todos create` — Create a todo from a finding or task
- `/rune:file-todos status` — Check current todo state
- `/rune:resolve-todos` — Resolve pending todos using Agent Teams

## Session-Scoped Model (v1.101.0+)

All todos live inside each workflow's `tmp/{workflow}/{id}/` directory. There is no persistent `todos/` at the project root. This means:

- **No gitignore conflict** — all todo files live in `tmp/`, which is already gitignored
- **No cross-session pollution** — todos from one arc run never interfere with another
- **No talisman override needed** — the workflow output dir encodes all context

**Migration note (CC-4)**: If you previously used `talisman.file_todos.dir`, remove that key — todos are now session-scoped and no project-root override is supported. If you used the `archive` subcommand, completed session data is now available in Rune Echoes (`.rune/echoes/`) and git history.

## Directory Resolution

All todo-producing and todo-consuming skills resolve the target directory through two shared pseudo-functions. These are defined **inline** — not as a shared module (per plugin convention).

### resolveTodosBase(workflowOutputDir)

> **NOTE**: Callers that inline this function MUST include the `SAFE_PATH_PATTERN` validation.
> Omitting it creates a path traversal vulnerability.

Resolves the **base** todos directory (without source subdirectory). Each workflow knows its own output directory from its state file or orchestrator context.

```javascript
// NEW: resolveTodosBase() — session-scoped only
// Each workflow knows its own output directory from its state file
// workflowOutputDir: string — absolute or relative path to workflow output dir
// Returns: string — base todos path ending with "/"
function resolveTodosBase(workflowOutputDir: string): string {
  const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
  if (!workflowOutputDir || !SAFE_PATH_PATTERN.test(workflowOutputDir) || workflowOutputDir.includes('..')) {
    throw new Error(`Invalid workflow output dir: ${workflowOutputDir}`)
  }
  const base = workflowOutputDir.endsWith('/') ? workflowOutputDir : workflowOutputDir + '/'
  return `${base}todos/`
}

// Examples:
//   strive:   resolveTodosBase("tmp/work/1771991022")  → "tmp/work/1771991022/todos/"
//   appraise: resolveTodosBase("tmp/reviews/abc123")   → "tmp/reviews/abc123/todos/"
//   audit:    resolveTodosBase("tmp/audit/def456")     → "tmp/audit/def456/todos/"
//   mend:     writes to review's todos_base (cross-write isolation, see §Mend below)
//   arc:      resolveTodosBase("tmp/arc/arc-1771234")  → "tmp/arc/arc-1771234/todos/"
```

### resolveTodosDir(workflowOutputDir, source)

Resolves a **source-qualified** todos path for a specific workflow. Appends the source subdirectory to the base.

```javascript
// resolveTodosDir(): Returns source-qualified path for a specific workflow
// workflowOutputDir: string — output directory for this workflow session
// source: "work" | "review" | "audit" | "test-browser" | "gap" | "test"
// Returns: string — source-qualified todos path ending with "/"
const VALID_SOURCES = new Set(["work", "review", "audit", "pr-comment", "tech-debt", "test-browser", "gap", "test"])

function resolveTodosDir(workflowOutputDir: string, source: string): string {
  if (!VALID_SOURCES.has(source)) throw new Error(`Invalid todo source: ${source}`)
  return `${resolveTodosBase(workflowOutputDir)}${source}/`
}

// Examples:
//   strive:   resolveTodosDir("tmp/work/1771991022", "work")     → "tmp/work/1771991022/todos/work/"
//   appraise: resolveTodosDir("tmp/reviews/abc123", "review")    → "tmp/reviews/abc123/todos/review/"
//   arc:      resolveTodosDir("tmp/arc/arc-1771234", "work")     → "tmp/arc/arc-1771234/todos/work/"
//   arc:      resolveTodosDir("tmp/arc/arc-1771234", "review")   → "tmp/arc/arc-1771234/todos/review/"
```

### Directory Layout Convention

```
tmp/{workflow}/{identifier}/
├── todos/                                          # resolveTodosBase()
│   ├── work/                                       # source: work (strive tasks)
│   │   ├── 001-ready-p1-implement-auth.md
│   │   ├── 002-ready-p2-add-tests.md
│   │   ├── todos-work-manifest.json                # per-source manifest (work only)
│   │   └── .dirty                                  # dirty signal for this source
│   ├── review/                                     # source: review (appraise findings)
│   │   ├── 001-pending-p1-fix-injection.md
│   │   └── todos-review-manifest.json              # per-source manifest (review only)
│   ├── audit/                                      # source: audit (audit findings)
│   │   └── todos-audit-manifest.json               # per-source manifest (audit only)
│   ├── todos-cross-index.json                      # OPTIONAL: cross-source edges + dedup
│   └── .cross-dirty                                # dirty signal for cross-source index
├── TOME.md                                         # review/audit output
├── patches/                                        # strive patches
├── worker-logs/                                    # per-worker session logs (NOT in todos/)
└── ...                                             # other workflow artifacts
```

- **ID sequences are per-subdirectory** — `work/001-*`, `review/001-*` are independent
- **Mend scans review's subdirectory** — reads manifest from review/audit session's `todos_base` (cross-write isolation pattern)
- **No `archive/` subdirectory** — completed session data goes to Rune Echoes + git history

## Mend Cross-Write Isolation

Mend is a special case — it does NOT create its own `todos/` directory. Instead, mend writes to the **original review/audit session's** todo directory. This is intentional cross-write isolation:

- Mend resolves `todos_base` from the TOME path: `tmp/reviews/{identifier}/TOME.md` → `tmp/reviews/{identifier}/todos/`
- Mend reads `{todos_base}/review/todos-review-manifest.json` to find matching finding IDs
- Mend updates todo frontmatter (status, resolution, mend_fixer_claim) in the review's todos directory
- Mend does NOT create `tmp/mend/{id}/todos/` — there is no mend-owned todo directory

**Mend cross-source scan** (finding matching todos by finding_id):

```javascript
// Mend reads review/audit session's todos_base (NOT its own session dir)
// The TOME path encodes the review session: tmp/reviews/{id}/TOME.md → todos_base
const reviewOutputDir = tomePath.replace('/TOME.md', '')  // e.g., "tmp/reviews/abc123"
const todosBase = resolveTodosBase(reviewOutputDir)       // "tmp/reviews/abc123/todos/"

// Read per-source manifest to find matching findings
const reviewManifest = JSON.parse(Read(`${todosBase}review/todos-review-manifest.json`))
const matchingTodo = reviewManifest.todos.find(t => t.finding_id === finding.id)
```

## Worker-Logs Concurrency Model

Per-worker session logs are located at `tmp/work/{timestamp}/worker-logs/` (NOT in `todos/`). This separation was introduced in v1.101.0 to eliminate the previous ambiguity between per-worker logs and per-task file-todos.

- **`worker-logs/`**: Created by workers during execution. Contains `{worker-name}.md` logs and `_summary.md`. Concurrent writes are safe because each worker owns exactly one file.
- **`todos/work/`**: Created by the orchestrator before workers start. Status updates route through the orchestrator (sole-writer pattern) to avoid concurrent frontmatter edits.

## Integration: /rune:strive (Work)

**Direction**: Plan tasks → File-Todos (mandatory producer + consumer)

**When**: During plan parsing (Phase 1) and worker execution (Phase 2+).

**Todos are mandatory** — strive ALWAYS creates file-todos. There is no `--todos=false` escape hatch.

**Flow — Production (Phase 1)**:

1. Parse plan for tasks
2. Compute `todos_base = resolveTodosBase(workflowOutputDir)` where `workflowOutputDir = "tmp/work/{timestamp}/"`
3. For each task:
   - Create `TaskCreate` entry (existing behavior, unchanged)
   - Create corresponding todo file with `schema_version: 2` in `{todos_base}/work/`
   - Set `claimed_at` when assigning to worker, `wave` from wave grouping
   - Map risk tier to priority: `critical` → `p1`, `high` → `p2`, default → `p3`
   - Set initial status to `ready` (work tasks are pre-triaged)
   - Append `workflow_chain: ["strive:{timestamp}"]` on creation
4. Run `manifest build` → compute `todos-work-manifest.json` with DAG ordering + wave assignment
5. Record `todos_base` in state file for resume support

**Flow — Consumption (Phase 2+)**:

1. Workers read their assigned todo file for context (dependencies, priority, wave)
2. Workers append Work Log entries as they progress
3. On completion: worker signals orchestrator; orchestrator updates `status: complete`, `completed_by`, `completed_at`, `resolution: fixed`
4. On block: worker signals orchestrator; orchestrator updates `status: blocked`

**Phase 4.1 — Summary generation**:

- _summary.md relocated to `tmp/work/{timestamp}/worker-logs/_summary.md` (was `todos/`)
- Per-task todos in `{todos_base}/work/` updated with final completion status
- `todos-work-manifest.json` rebuilt with final status summary

**State file records `todos_base`**:

```json
{
  "team_name": "rune-work-1771991022",
  "status": "active",
  "todos_base": "tmp/work/1771991022/todos/",
  "..."
}
```

## Integration: /rune:appraise (Review)

**Direction**: Review TOME → File-Todos (mandatory producer)

**When**: After TOME.md is written and diff-scope tagging is complete (Phase 5.4 in Roundtable Circle).

**Todos are mandatory** — appraise ALWAYS creates file-todos. Remove `--todos=false` check.

**Flow (Phase 5.4)**:

1. Compute `todos_base = resolveTodosBase(outputDir)` where `outputDir = "tmp/reviews/{id}/"`
2. Resolve `todosDir = resolveTodosDir(outputDir, "review")` → `"tmp/reviews/{id}/todos/review/"`
3. Parse TOME.md for structured findings (`RUNE:FINDING` markers)
4. Filter non-actionable findings (question, nit, FALSE_POSITIVE, pre-existing P2/P3)
5. Set `schema_version: 2` on all created todos
6. Include Status History section with creation entry
7. Set `workflow_chain: ["appraise:{identifier}"]` on creation
8. Build `todos-review-manifest.json` after all todos created (DAG from finding dependencies)
9. Record `todos_base` in state file for mend consumption

**Frontmatter mapping**:

```yaml
source: review
source_ref: "tmp/reviews/{id}/TOME.md"    # full relative path
finding_id: "SEC-001"                      # RUNE:FINDING id attribute
finding_severity: "P1"                     # from finding priority
priority: p1                               # mapped from finding severity
workflow_chain:
  - "appraise:{identifier}"
```

## Integration: /rune:audit (Audit)

**Direction**: Audit TOME → File-Todos (mandatory producer)

**When**: After audit TOME.md is written (same phase as review).

**Todos are mandatory** — audit ALWAYS creates file-todos.

**Flow**: Identical to appraise but with `source: audit` and `todos_base = tmp/audit/{identifier}/todos/`.

## Integration: /rune:mend (Resolution)

**Direction**: File-Todos ← Mend fixer (consumer + updater via cross-write isolation)

**When**: After mend-fixer resolves a TOME finding.

**Cross-write isolation (CC-3)**: Mend writes to the original review/audit session's todo directory. It does NOT create its own `todos/` directory. See §Mend Cross-Write Isolation above.

**Flow**:

1. Resolve `todos_base` from TOME path (extract `outputDir` from TOME location)
2. Read per-source manifest: `{todos_base}/review/todos-review-manifest.json` (or audit)
3. Match finding IDs to todo entries within the manifest
4. Set `mend_fixer_claim: {fixer-name}` before updating (prevents concurrent edits)
5. Verify `mend_fixer_claim` is unset or matches current fixer before writing
6. Set `resolution: fixed`, `resolution_reason`, `resolved_by: {fixer-name}`, `resolved_at`
7. Set `completed_by: {fixer-name}`, `completed_at`
8. Append `workflow_chain` entry: `"mend:{identifier}"`
9. Append Status History entry on resolution
10. Mark `{todos_base}/review/.dirty` for manifest rebuild
11. Rebuild `todos-review-manifest.json` at end of mend phase

## Integration: /rune:arc (Orchestrator)

**Direction**: Arc orchestrator → all phases (thread-through)

**When**: Arc scaffolding pre-Phase 5 sets up `todos_base` for all phases.

**Arc already uses `tmp/arc/{id}/todos/` — this is the model all workflows now follow.**

**Changes from prior arc integration**:

- Remove `--todos-dir` flag passing — each phase detects arc context automatically
- Each delegated phase (strive, appraise) detects the active arc checkpoint and redirects todos to `tmp/arc/{id}/todos/` instead of their own output directory
- After each phase, mark source-specific dirty: `{todos_base}/work/.dirty`, `{todos_base}/review/.dirty`
- Arc completion report reads all per-source manifests and aggregates summary
- Arc checkpoint records `todos_base` for `--resume` restoration

**Arc context detection pattern** (used by strive Phase 1 and roundtable-circle Phase 5.4):

```javascript
// Scan for active arc checkpoint with the relevant phase in_progress
let todosOutputDir = workflowOutputDir  // default: own output dir
const arcCheckpoints = Glob(".rune/arc/*/checkpoint.json")
for (const ckpt of arcCheckpoints) {
  try {
    const c = JSON.parse(Read(ckpt))
    // strive checks: c.phases?.work?.status === "in_progress"
    // appraise checks: c.phases?.code_review?.status === "in_progress"
    if (c.todos_base && relevantPhaseIsInProgress) {
      todosOutputDir = c.todos_base.replace(/todos\/?$/, '')  // "tmp/arc/{id}/"
      break
    }
  } catch {}
}
// todosOutputDir now points to arc's dir when inside arc, own dir when standalone
```

This ensures strive creates `tmp/arc/{id}/todos/work/` and appraise creates `tmp/arc/{id}/todos/review/` — both under the same `todos_base` that arc reads from its checkpoint.

**Phase-to-source mapping**:

| Phase | Skill | todos_base | source |
|-------|-------|------------|--------|
| Phase 5 (WORK) | `/rune:strive` | `tmp/arc/{id}/todos/` | `work` |
| Phase 6 (CODE REVIEW) | `/rune:appraise` | `tmp/arc/{id}/todos/` | `review` |
| Phase 7 (MEND) | `/rune:mend` | reads review's `todos_base` | (cross-write) |

> **Arc exception**: In arc context, only `work/` and `review/` subdirectories are created.
> `audit/` is NOT created because arc Phase 6 uses `/rune:appraise` (source=review), not `/rune:audit`.

## Resume Flow

When a session resumes (`--resume` for arc, or session continuation for standalone):

```javascript
// Resume reconstruction:
// 1. Read checkpoint/state file → extract todos_base
// 2. Verify todos_base directory still exists
// 3. Rebuild any dirty per-source manifests
// 4. Read manifests → reconstruct in-memory state
// 5. Resume from last known state

function resumeTodoState(checkpoint: { todos_base: string }): object | null {
  const todosBase = checkpoint.todos_base
  if (!todosBase || !exists(todosBase)) {
    warn(`Todo directory ${todosBase} missing — session artifacts may have been cleaned`)
    return null
  }

  // Rebuild any dirty manifests before reading
  const sources: string[] = Glob(`${todosBase}*/`).map((d: string) => basename(d))
  for (const source of sources) {
    if (exists(`${todosBase}${source}/.dirty`)) {
      buildSourceManifest(todosBase, source)
    }
  }

  // Read all per-source manifests
  const manifests: Record<string, object> = {}
  for (const source of sources) {
    const manifestPath = `${todosBase}${source}/todos-${source}-manifest.json`
    if (exists(manifestPath)) {
      manifests[source] = JSON.parse(Read(manifestPath))
    }
  }

  // Mark interrupted todos as ready for re-claim
  for (const [source, manifest] of Object.entries(manifests)) {
    for (const todo of (manifest as any).todos ?? []) {
      if (todo.status === 'interrupted') {
        updateTodoFrontmatter(todo.file, { status: 'ready', assigned_to: null })
        appendStatusHistory(todo.file, 'interrupted', 'ready', 'resume', 'Session resumed')
      }
    }
  }

  return manifests
}
```

## Concurrency Model

### Single-Writer Principle

Only the orchestrator (Tarnished) creates, updates status on, and deletes todo files. Workers only append to Work Log sections of their assigned todo. This eliminates all write coordination issues.

### Claim Protocol

When a worker claims a todo:

1. Orchestrator sets `assigned_to: {worker-name}` in frontmatter
2. Orchestrator sets `status: in_progress`, `claimed_at: {timestamp}`
3. Worker reads and appends to Work Log only
4. On completion, worker signals orchestrator (not direct file update)

### Mend Claim Lock

Mend-fixers set `mend_fixer_claim: {fixer-name}` before updating. If field is already set by another fixer, skip the update (prevents concurrent mend writes to the same todo file).

## Integration Implementation Patterns

### Frontmatter Update Pattern

All workflow integrations that update todo frontmatter should use section-targeted `Edit()` — modify only the YAML frontmatter block (between `---` delimiters), not the full file.

```javascript
// Pattern: update only frontmatter fields
const content: string = Read(todoPath)
const fmEnd: number = content.indexOf('---', content.indexOf('---') + 3)
const oldFrontmatter: string = content.substring(0, fmEnd + 3)
const newFrontmatter: string = oldFrontmatter.replace(
  /^status: .*/m, `status: ${newStatus}`
).replace(
  /^resolved_by: .*/m, `resolved_by: ${actor}`
)
Edit(todoPath, { old_string: oldFrontmatter, new_string: newFrontmatter })
```

### workflow_chain Append Pattern

Each workflow appends its identifier. Since YAML arrays in frontmatter are multiline, use the existing array format:

```yaml
workflow_chain:
  - "appraise:1771234"
  - "mend:1771235"    # Appended by mend integration
```

### Manifest Rebuild Trigger

Workflow phases should set `{todos_base}/{source}/.dirty` after modifying any todo file, rather than calling `manifest build` directly. The per-source dirty signal is checked by downstream phases that need manifest data.

### Checkpoint Integration

Every workflow state file (`tmp/.rune-{type}-*.json`) MUST record `todos_base` for resume support:

```json
{
  "team_name": "rune-work-1771991022",
  "status": "active",
  "todos_base": "tmp/work/1771991022/todos/"
}
```
