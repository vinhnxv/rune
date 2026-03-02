# Todo Generation from TOME (Phase 5.4)

> Standalone reference for Phase 5.4 of the Roundtable Circle orchestration. Extracts actionable findings from TOME and generates per-finding todo files with YAML frontmatter.

## Contract

| Field | Value |
|-------|-------|
| **Input** | `TOME.md` with `<!-- RUNE:FINDING -->` markers (post Phase 5/5.2/5.3) |
| **Output** | Per-finding todo files in `{todosDir}` |
| **Mandatory** | YES — no skip conditions, no `--todos=false` escape hatch |
| **Sole writer** | Tarnished orchestrator only (workers append Work Log sections only) |
| **Runs after** | Phase 5.3 (diff-scope tagging) so scope attributes are available |

## Step 1: Resolve Directories

Inline `resolveTodosBase(workflowOutputDir)` + `resolveTodosDir(workflowOutputDir, source)`:

```javascript
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
if (!workflowOutputDir || !SAFE_PATH_PATTERN.test(workflowOutputDir) || workflowOutputDir.includes('..')) {
  throw new Error(`Invalid workflow output dir: ${workflowOutputDir}`)
}

// Arc context detection: when running inside arc, redirect todos to arc's directory
// so all phases (work, review, mend) share a single todos_base at tmp/arc/{id}/todos/
// Detection: check for active arc checkpoint with code_review phase in_progress
let todosOutputDir = workflowOutputDir
const arcCheckpoints = Glob(".claude/arc/*/checkpoint.json")
for (const ckpt of arcCheckpoints) {
  try {
    const c = JSON.parse(Read(ckpt))
    if (c.phases?.code_review?.status === "in_progress" && c.todos_base) {
      // Extract arc output dir from todos_base: "tmp/arc/{id}/todos/" → "tmp/arc/{id}/"
      todosOutputDir = c.todos_base.replace(/todos\/?$/, '')
      break
    }
  } catch {}
}

// CRITICAL: omitting SAFE_PATH_PATTERN is a path traversal vulnerability
const todosBase = `${todosOutputDir.replace(/\/?$/, '/')}todos/`
const VALID_SOURCES = new Set(["work", "review", "audit", "pr-comment", "tech-debt"])
if (!VALID_SOURCES.has(source)) throw new Error(`Invalid source: ${source}`)
const todosDir = `${todosBase}${source}/`  // source = "review" | "audit"
Bash(`mkdir -p "${todosDir}"`)
// Examples:
//   standalone: tmp/reviews/{id}/todos/review/, tmp/audit/{id}/todos/audit/
//   arc context: tmp/arc/{id}/todos/review/ (redirected via arc checkpoint detection)
```

## Step 2: Session Nonce Recovery

**GUARD (SEC-010 / BACK-005)**: `sessionNonce` MUST be defined before extraction. Re-read from `inscription.json` if lost (post-compaction). Validate format: 8 char hex (`/^[0-9a-f]{8}$/i`).

```javascript
if (!sessionNonce) {
  const inscription = JSON.parse(Read(`${outputDir}inscription.json`))
  sessionNonce = inscription.session_nonce  // snake_case in inscription.json
  if (typeof sessionNonce !== 'string' || !/^[0-9a-f]{8}$/i.test(sessionNonce))
    throw new Error('sessionNonce not recoverable — aborting to prevent SEC-010 bypass')
}
```

## Step 3: Extract Findings (3-Layer Pipeline)

### Layer 1: Marker + Nonce (strict)

```javascript
let allFindings = extractFindings(tomeContent, sessionNonce)
// Strict nonce validation — cross-session markers rejected
```

### Layer 2: Lenient Fallback (nonce-MISSING only)

If Layer 1 returns 0 findings AND markers exist without any `nonce=` attribute:

```javascript
if (allFindings.length === 0 && markerCount > 0) {
  const hasAnyNonce = /<!-- RUNE:FINDING [^>]*nonce="/.test(tomeContent)
  if (!hasAnyNonce) {
    // nonce-MISSING: safe to recover (Runebinder omission)
    allFindings = extractFindingsLenient(tomeContent)
    allFindings.forEach(f => f.nonce_fallback = true)
  } else {
    // nonce-MISMATCHED: SEC-010 block — NO fallback
    warn('Markers have non-matching nonce. Rejecting (SEC-010).')
  }
}
```

> **CRITICAL**: nonce-MISSING (safe fallback) vs nonce-MISMATCHED (SEC-010 block, no fallback).

### Layer 3: Heading Fallback (no markers at all)

For audit TOMEs without HTML comment markers:

```javascript
if (allFindings.length === 0 && markerCount === 0) {
  const headingFindings = extractFindingsFromHeadings(tomeContent)
  // BACK-012: Validate required fields before accepting
  const valid = headingFindings.filter(f =>
    f && typeof f.id === 'string' && typeof f.file === 'string' && typeof f.severity === 'string'
  )
  if (valid.length > 0) {
    allFindings = valid
    allFindings.forEach(f => f.marker_format = 'heading')
  }
}
```

> **BACK-003**: Hybrid TOMEs (mixed markers + headings) are NOT handled — known limitation. Heading extraction is skipped when `markerCount > 0`.

## Step 4: Filter Non-Actionable

```javascript
const todoableFindings = allFindings.filter(f =>
  f &&
  (f.interaction || '') !== 'question' &&           // Q findings — non-actionable
  (f.interaction || '') !== 'nit' &&                // N findings — non-actionable
  (f.status || '') !== 'FALSE_POSITIVE' &&          // Already dismissed
  !/\[UNVERIFIED:/.test(f.title || '') &&           // Phase 5.2: hallucinated citations
  !((f.scope || '') === 'pre-existing' && f.severity !== 'P1')  // Skip pre-existing P2/P3
)
```

**Kept**: Pre-existing P1 findings (critical regardless of scope). SUSPECT findings (fixer applies extra caution per Phase 5.2).

## Step 5: Generate Todo Files

Sequential ID per source subdirectory (`001`-`999`, 4-digit if >999). Idempotency: dedup on `finding_id` + `source_ref` in existing todo frontmatter.

```javascript
const existingFiles = Glob(`${todosDir}[0-9][0-9][0-9]-*.md`)
let nextId = existingFiles.length > 0
  ? Math.max(...existingFiles.map(f => parseInt(f.split('/').pop().match(/^(\d+)-/)?.[1] || '0', 10))) + 1
  : 1
// Per finding: skip if existing todo has same finding_id + source_ref (idempotent)
```

### Write Todo File

```javascript
const priority = finding.severity.toLowerCase()  // P1->p1, P2->p2, P3->p3
const slug = finding.title.toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
const paddedId = String(nextId).padStart(3, '0')
const filename = `${paddedId}-pending-${priority}-${slug}.md`

Write(`${todosDir}${filename}`, generateTodoFromFinding(finding, {
  schema_version: 2,
  status: "pending",
  priority,
  issue_id: paddedId,
  source: workflowType,          // "review" | "audit"
  source_ref: tomePath,
  finding_id: finding.id,        // from RUNE:FINDING id attribute
  finding_severity: finding.severity,
  tags: finding.tags || [],
  files: finding.files || [],
  workflow_chain: [`${workflowType === 'review' ? 'appraise' : 'audit'}:${identifier}`],
  created: new Date().toISOString().slice(0, 10),
  updated: new Date().toISOString().slice(0, 10)
}))
```

## Step 6: Build Manifest

```javascript
// Use todosBase from Step 1 (arc-aware — resolves to tmp/arc/{id}/todos/ in arc context)
buildSourceManifest(todosBase, workflowType)
// Produces: {todosDir}/todos-{source}-manifest.json with DAG ordering
```

See [manifest-schema.md](../../file-todos/references/manifest-schema.md) for manifest format.

## Step 7: Record State

```javascript
const currentState = JSON.parse(Read(`${stateFilePrefix}-${identifier}.json`))
Write(`${stateFilePrefix}-${identifier}.json`, {
  ...currentState,
  todos_base: todosBase
})
```

`todos_base` is consumed by mend (for finding resolution) and by resume support.

## Frontmatter Mapping

| Field | Review | Audit |
|-------|--------|-------|
| `source` | `review` | `audit` |
| `source_ref` | `tmp/reviews/{id}/TOME.md` | `tmp/audit/{id}/TOME.md` |
| `finding_id` | from `RUNE:FINDING` `id` attribute (e.g., `SEC-001`) | same (e.g., `PERF-003`) |
| `finding_severity` | from finding priority (e.g., `P1`) | same (e.g., `P2`) |
| `priority` | mapped: P1->p1, P2->p2, P3->p3 | same |
| `workflow_chain` | `["appraise:{identifier}"]` | `["audit:{identifier}"]` |

## Verification Checklist

- [ ] `todosDir` created with `mkdir -p`
- [ ] At least 1 todo file written (or 0 actionable findings — log count)
- [ ] `todos_base` recorded in state file
- [ ] Per-source manifest built at `{todosDir}/todos-{source}-manifest.json`
- [ ] `execution_order` check uses `=== null` (0 is reserved sentinel)
- [ ] No `--todos-dir` flag referenced (session-scoped model — no override)
- [ ] `SAFE_PATH_PATTERN` validation present in directory resolution

## Related References

- [orchestration-phases.md](orchestration-phases.md) — Full Phase 5.4 pseudocode in context
- [integration-guide.md](../../file-todos/references/integration-guide.md) — Session-scoped model and cross-write isolation
- [manifest-schema.md](../../file-todos/references/manifest-schema.md) — Manifest format and DAG ordering
- [todo-template.md](../../file-todos/references/todo-template.md) — Todo file template with YAML frontmatter
