# Smart Selection — Ash Scope Assignment

> Assigns files to Ash based on extension, priority, and context budget.

## Lore Layer Pre-Sort (Phase 0.5)

When the Lore Layer is active (Phase 0.5 in review/audit), `changed_files` / `all_files` are **pre-sorted by risk tier** before Rune Gaze runs. CRITICAL files appear first, then HIGH, MEDIUM, LOW, STALE. This ensures that when Rune Gaze assigns files to Ashes, CRITICAL files are prioritized within each Ash's subset.

**Interaction with Rune Gaze**: Rune Gaze classifies files by extension to assign them to Ashes (each Ash gets a subset). Within each Ash's subset, the Lore Layer sort order is preserved — CRITICAL files of that extension appear before MEDIUM ones.

**When Lore Layer is skipped** (non-git repo, `--no-lore` flag, `goldmask.layers.lore.enabled: false`, <5 commits), file lists retain their original git diff order. Rune Gaze operates identically regardless.

See `review.md` Phase 0.5 and `audit.md` Phase 0.5 for the full Lore Layer implementation.

## File Classification

### Extension → Ash Mapping

| Extension Group | Ash | Priority Within Group |
|----------------|-----------|----------------------|
| `*.py, *.go, *.rs, *.rb, *.java, *.kt, *.scala` | Forge Warden | Entry points > services > core modules > utils > tests |
| `*.ts, *.tsx, *.js, *.jsx, *.vue, *.svelte` | Glyph Scribe | Pages/routes > components > hooks > utils |
| `*.md` (>= 10 lines changed) | Knowledge Keeper | README > CLAUDE.md > docs/ > other .md |
| ALL files | Ward Sentinel | Auth files > API routes > config > infrastructure > other |
| ALL files | Pattern Weaver | Largest files first (highest complexity risk) |

### Skip List (Never Reviewed)

```
*.png, *.jpg, *.gif, *.svg, *.ico, *.woff, *.woff2, *.ttf, *.eot
*.lock, package-lock.json, yarn.lock, bun.lockb, Cargo.lock
*.min.js, *.min.css, *.map
*.pyc, __pycache__/, .git/, node_modules/, dist/, build/, .next/
```

## Source Code Classification

BACK-003 FIX: Canonical `isSourceCode()` definition — referenced by convergence-gate.md for chunk type classification.

```javascript
// isSourceCode: returns true for code extensions, false for doc/config extensions.
// Used by convergence-gate.md (chunk type classification) and selectConvergenceTier (all-doc detection).
const SOURCE_CODE_EXTENSIONS = new Set([
  'py', 'go', 'rs', 'rb', 'java', 'kt', 'scala',  // Backend
  'ts', 'tsx', 'js', 'jsx', 'vue', 'svelte',        // Frontend
  'sql', 'sh', 'bash', 'zsh',                        // DB/shell
  'c', 'cpp', 'h', 'hpp', 'cs', 'swift', 'zig',     // Systems
])

function isSourceCode(filePath) {
  const ext = (filePath ?? '').split('.').pop()?.toLowerCase() ?? ''
  return SOURCE_CODE_EXTENSIONS.has(ext)
}
```

## Three-Way Classification

`select_scope()` returns one of:

| Classification | Meaning | Assigned To |
|---------------|---------|-------------|
| `code` | Source code file | Forge Warden and/or Glyph Scribe + always-on |
| `docs` | Documentation file | Knowledge Keeper + Ward Sentinel (for `.claude/`) |
| `skip` | Non-reviewable file | No Ash |
| `critical_deletion` | Important file deleted | Flagged in TOME.md |

### Dual Classification

Some files are assigned to multiple Ash intentionally:

| File Type | Ash | Reason |
|-----------|------------|--------|
| `.claude/**/*.md` | Knowledge Keeper + Ward Sentinel | Docs accuracy + prompt injection risk |
| `Dockerfile` | Ward Sentinel + Forge Warden | Security + build patterns |
| CI/CD configs | Ward Sentinel + Pattern Weaver | Security + convention consistency |
| Test files | Pattern Weaver + Forge Warden | Quality patterns + logic correctness |

## Review Mode Selection

### Scope Parameter

| Scope | Source | Used By |
|-------|--------|---------|
| `diff` | `git diff` (changed files only) | `/rune:appraise` (default) |
| `full` | `find .` (all project files) | `/rune:appraise --scope full`, `/rune:audit` (implicit) |

The scope parameter determines the file collection strategy. It is an internal orchestration parameter (not a user-facing flag) — `/rune:audit` always uses `scope=full` implicitly.

### Review (`/rune:appraise`)

```
1. Run: git diff --name-only main..HEAD
2. Classify each file by extension
3. Sort by recency: new files first, modified files second
4. Cap per Ash by context budget
5. Files beyond budget → "Coverage Gaps" in TOME.md
```

### Audit (`/rune:audit`)

```
1. Run: find . -type f (filtered by skip list)
2. Classify each file by extension
3. Sort by importance: entry points > core > services > utils > tests
4. Cap per Ash by context budget (stricter due to volume)
5. Files beyond budget → "Coverage Gaps" in TOME.md
```

### Incremental Audit (`/rune:audit --incremental`)

When `--incremental` flag is set, the file list is pre-filtered by the incremental layer (Phase 0.1-0.4) before reaching Smart Selection:

```
1. Phase 0.1-0.4 produces a priority-scored batch (default 30 files)
2. The batch replaces all_files — Smart Selection operates on the batch only
3. Classify batch files by extension (same as standard audit)
4. Sort by priority score (from incremental scoring), then by importance
5. Cap per Ash by context budget
6. Files beyond budget → recorded in audit state as coverage_gaps
```

**IMPORTANT**: This incremental pre-filtering ONLY activates when `--incremental` flag is set. Without the flag, Smart Selection operates identically to the standard audit path. This is gated at the parameter level to prevent any behavioral change to default audits (Concern 1: regression safety).

**Audit-history-aware budget**: When `--incremental` is active, prefer assigning files to Ashes that have NOT previously audited them (from `state.json.files[path].audited_by`). This increases reviewer diversity across sessions.

## Inscription Sharding vs Standard Selection (v1.98.0+)

When `depth=standard` and `scope=diff` and `totalFiles > shard_threshold` (default 15),
the standard Ash selection path is BYPASSED in favour of Inscription Sharding.

| Condition | Path |
|-----------|------|
| `depth=deep` | Wave scheduling → specialist Ashes (standard, no sharding) |
| `depth=standard`, `scope=diff`, `totalFiles > shard_threshold` | **Inscription Sharding** — domain-affinity shard reviewers |
| `depth=standard`, `scope=diff`, `totalFiles <= shard_threshold` | Standard Ash selection (this section) |
| `depth=standard`, `scope=full` (audit) | Standard Ash selection (this section) |

When sharding is active, `selectedAsh` is NOT populated from Rune Gaze. Instead,
`buildShardReviewerPrompt()` generates prompts per shard from `inscription.sharding.shards`.
See [shard-allocator.md](shard-allocator.md) for domain group assignment and bin-packing.

**Rationale — why deep mode does NOT use sharding**: Deep mode agents (rot-seeker, breach-hunter,
strand-tracer, etc.) are highly specialized investigators. They benefit from seeing the full file
set within their specialty — sharding generalist reviewers makes sense because each covers ALL
dimensions, but sharding specialists would split their domain expertise across arbitrary file
boundaries. Deep mode's wave system already handles context management by running specialist
waves sequentially with context forwarding.

**Convergence re-review**: When the convergence loop retries the review phase (arc Phase 7.5),
`allocateShards()` runs again on the narrowed progressive-focus file set. Since mend typically
touches 5-15 files, this almost always falls below `SHARD_THRESHOLD` → standard specialist review.
If re-review scope exceeds `reshard_threshold` (default: 30), standard review is forced rather
than re-sharding, because re-sharding breaks finding prefix continuity and impairs oscillation
detection. See `talisman.review.reshard_threshold`.

## Wave Assignment

After Rune Gaze selects Ashes based on file classification, wave scheduling determines execution order for `depth=deep` mode. Standard depth bypasses wave scheduling entirely.

### Integration with selectWaves()

```
1. Rune Gaze classifies files → produces selectedAsh set (Wave 1 candidates)
2. If depth === "standard": return selectedAsh as single wave (no scheduling)
3. If depth === "deep":
   a. Pass selectedAsh + circleEntries to selectWaves()
   b. selectWaves() reads wave/deepOnly from circle-registry.md
   c. Wave 1: filtered by selectedAsh (conditional Ashes may be excluded)
   d. Wave 2+: all deepOnly agents included automatically
   e. mergeSmallWaves() consolidates undersized trailing waves
   f. distributeTimeouts() allocates time budget per wave
4. Each wave executes as an independent Roundtable Circle pass
```

### Wave Context Forwarding

Later waves receive prior wave findings as read-only context:
- **Wave 2** receives Wave 1 TOME output (aggregated findings)
- **Wave 3** receives Wave 1 + Wave 2 findings

This enables deep investigation agents to build on core reviewer discoveries rather than duplicating effort.

See [wave-scheduling.md](wave-scheduling.md) for the full scheduling algorithm (selectWaves, mergeSmallWaves, distributeTimeouts).

### Focus Mode (`--focus <area>`)

| Focus Area | Ash Summoned | Budget Increase |
|-----------|-------------------|-----------------|
| `security` | Ward Sentinel only | 2x (40 files) |
| `performance` | Forge Warden only | 2x (60 files) |
| `quality` | Pattern Weaver only | 2x (60 files) |
| `frontend` | Glyph Scribe only | 2x (50 files) |
| `docs` | Knowledge Keeper only | 2x (50 files) |
| `backend` | Forge Warden + Ward Sentinel | 1.5x each |
| `full` | All (default) | Standard |

Focus mode increases context budget because fewer Ash compete for lead attention.

## Context Budget

| Ash | Default Budget | Audit Budget | Focus Budget |
|-----------|---------------|-------------|-------------|
| Forge Warden | 30 files | 30 files | 60 files |
| Ward Sentinel | 20 files | 20 files | 40 files |
| Pattern Weaver | 30 files | 30 files | 60 files |
| Glyph Scribe | 25 files | 25 files | 50 files |
| Knowledge Keeper | 25 files | 25 files | 50 files |

### Budget Enforcement

```
for each selected Ash:
  1. Collect files matching extension group
  2. Sort by scope priority (defined above)
  3. Cap at context budget
  4. Remaining files → listed in TOME.md "Coverage Gaps"
```

## Large File Warning

If a single file exceeds 500 lines, it consumes significant context. For files > 500 lines:
- Use `offset`/`limit` to read relevant sections
- Prioritize reading the first 200 lines + any functions flagged by `grep`
- Note in findings if only partial file was reviewed

## Chunk-Aware Budget Enforcement

When chunked review is active (file count exceeds `chunk_threshold`), budget enforcement operates per-chunk rather than globally.

### Per-Chunk Budget Rules

- Each chunk's file count must not exceed `MIN_ASH_BUDGET` (20 — Ward Sentinel's cap). Files exceeding this limit are split into a new chunk by the chunk orchestrator before review begins.
- Budget allocation per Ash is computed per-chunk: each chunk is treated as an independent review scope with its own file assignments.
- Each chunk gets its own `select_scope()` pass using the standard extension → Ash mapping, applied only to the chunk's files.
- Coverage Gaps in a chunk TOME reflect only the files within that chunk that exceeded budget — not files in other chunks (which have their own TOME).

### Security-Pinned Files

Files matching `SECURITY_CRITICAL_PATTERNS` (e.g., `**/auth/**`, `**/middleware/auth*`, `**/security/**`, `**/validators/**`, `**/*permission*`) are treated as read-only context in every chunk:

- Security-pinned files are included in every chunk's Ward Sentinel scope regardless of which chunk they are assigned to.
- They do NOT count against the per-chunk file budget (they are injected as context, not as review targets).
- This ensures Ward Sentinel always has auth/validation context when reviewing any chunk, preventing context-split vulnerabilities where auth logic in one chunk is invisible to reviewers of another chunk.

### Chunk Budget Flow

```
for each chunk:
  1. Classify chunk files using standard extension → Ash mapping
  2. Sort by scope priority (same as single-pass)
  3. Cap at MIN_ASH_BUDGET per Ash
  4. Inject SECURITY_CRITICAL_PATTERNS files as read-only context (not counted against budget)
  5. Files beyond budget → listed in chunk TOME "Coverage Gaps"
```

## References

- [Rune Gaze](rune-gaze.md) — Extension classification rules
- [Circle Registry](circle-registry.md) — Agent-to-Ash mapping, wave assignments, deepOnly flags
- [Wave Scheduling](wave-scheduling.md) — Wave selection, merge logic, timeout distribution
- [Shard Allocator](shard-allocator.md) — Domain-affinity bin-packing for Inscription Sharding (v1.98.0+)
