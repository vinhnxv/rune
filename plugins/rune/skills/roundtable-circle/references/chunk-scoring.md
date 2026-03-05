# Chunk Scoring — File Complexity Engine

> Scores files by complexity and groups them into balanced chunks for chunked review.
> Used when `changed_files.length > CHUNK_THRESHOLD` to partition work across multiple Roundtable Circle passes.

## Constants

```javascript
// QUAL-001 + QUAL-008 FIX: Config namespace is `review:` (not `rune-gaze:`).
// talisman.example.yml and review.md both use `review:` — reference docs must match.
// QUAL-009 NOTE: CHUNK_THRESHOLD default (20) appears in: chunk-scoring.md, chunk-orchestrator.md, review.md.
// The authoritative value is talisman.review.chunk_threshold. These are documentation defaults only —
// all runtime code reads from config ?? 20. If changing the default, update all 3 files.
const CHUNK_THRESHOLD   = 20   // Files above this trigger chunking (configurable: review.chunk_threshold)
const CHUNK_TARGET_SIZE = 15   // Target files per chunk (configurable: review.chunk_target_size)
const MAX_CHUNKS        = 5    // Circuit breaker — prevents runaway review loops (configurable: review.max_chunks)
const MIN_ASH_BUDGET    = 20   // Ward Sentinel's cap — no chunk should exceed this
```

## File Type Weights

```javascript
const TYPE_WEIGHTS = {
  // Dynamic typing → higher review complexity
  py: 1.5, rb: 1.5, js: 1.5,
  // Static types reduce review burden
  go: 1.0, java: 1.0, ts: 1.0, rs: 1.2,
  // UI components add complexity
  tsx: 1.3, jsx: 1.5,
  // DB and shell are error-prone
  sql: 1.5, sh: 1.3,
  // Docs are lower complexity
  md: 0.5, txt: 0.3,
}
```

## Security-Critical Patterns

```javascript
// Files matching these patterns are pinned as read-only context in EVERY chunk,
// even if assigned to a different chunk. Ward Sentinel can cross-reference auth
// context across all chunk reviews.
const SECURITY_CRITICAL_PATTERNS = [
  '**/auth/**', '**/middleware/auth*', '**/security/**',
  '**/validators/**', '**/*permission*', '**/crypto/**',
  '**/payment/**', '**/migrate/**', '**/migration*',
]
```

## `scoreFile(file, diffStats)`

**Inputs**:
- `file` — string: relative file path
- `diffStats` — `{ [file]: { insertions, deletions, status } }` from `git diff --numstat`

**Outputs**: `{ file, complexity, type, riskFactor, ext }`

**Error handling**: Missing `diffStats[file]` defaults to `linesChanged = 1` (not 0 — prevents zero-complexity invisibility). Missing file on disk → complexity = 1.0.

```javascript
function scoreFile(file, diffStats) {
  // SEC-003 FIX: Guard against prototype property access on diffStats.
  // File paths from git diff are user-derived — use Object.hasOwn to prevent
  // 'constructor', 'toString', etc. from matching prototype properties.
  const stat = Object.hasOwn(diffStats, file) ? diffStats[file] : undefined
  // CRITICAL: Math.max floor prevents zero-complexity for renamed/permission-changed files
  const linesChanged = Math.max(
    (stat?.insertions ?? 0) + (stat?.deletions ?? 0),
    1
  )
  // Fallback: wc -l for untracked files not in diffStats
  // SEC-011 FIX: Validate file path before shell interpolation in wcLines.
  // File paths with backticks, $(), or semicolons could execute arbitrary commands.
  const SAFE_PATH = /^[a-zA-Z0-9._\-\/]+$/
  const effectiveLines = stat ? linesChanged
    : (SAFE_PATH.test(file) ? (wcLines(file) || 1) : 1)

  const sizeFactor = Math.min(effectiveLines / 50, 3.0)
  const typeFactor = TYPE_WEIGHTS[ext(file)] ?? 1.0

  let riskFactor = 1.0
  if (matchesAnyPattern(file, SECURITY_CRITICAL_PATTERNS)) riskFactor = 2.0
  if (stat?.status === 'A') riskFactor *= 1.5   // New file — no history, higher review risk
  if (isTestFile(file))     riskFactor *= 0.5   // Tests lower relative risk

  const complexity = sizeFactor * typeFactor * riskFactor
  const type = classify(file)  // 'code' | 'docs' | 'skip' | 'critical_deletion'

  return { file, complexity, type, riskFactor, ext: ext(file) }
}
```

## `groupByDirectory(scoredFiles)`

**Inputs**: `scoredFiles` — `{ file, complexity, type, riskFactor }[]`

**Outputs**: `{ dir, files, totalComplexity }[]` — one entry per unique parent directory

**Error handling**: Root-level files (no `/` in path) use `<root>` sentinel directory. Empty input returns `[]`.

```javascript
function groupByDirectory(scoredFiles) {
  if (scoredFiles.length === 0) return []

  const dirMap = new Map()  // dir → { files: [], totalComplexity: 0 }

  for (const scored of scoredFiles) {
    const lastSlash = scored.file.lastIndexOf('/')
    // Files like 'README.md' or 'Dockerfile' at repo root → '<root>' sentinel
    const dir = lastSlash >= 0 ? scored.file.slice(0, lastSlash) : '<root>'

    if (!dirMap.has(dir)) {
      dirMap.set(dir, { dir, files: [], totalComplexity: 0 })
    }
    const group = dirMap.get(dir)
    group.files.push(scored)
    group.totalComplexity += scored.complexity
  }

  return Array.from(dirMap.values())
}
```

## `avgComplexity(scoredFiles)`

**Inputs**: `scoredFiles` — `{ complexity }[]`

**Outputs**: `number` — mean complexity across all files

**Error handling**: Empty array returns `1.0` (safe default; prevents NaN in bin-packing calculation).

```javascript
function avgComplexity(scoredFiles) {
  if (scoredFiles.length === 0) return 1.0
  return scoredFiles.reduce((sum, f) => sum + f.complexity, 0) / scoredFiles.length
}
```

## `splitChunk(chunk, maxSize)`

**Inputs**:
- `chunk` — `{ files, totalComplexity, chunkIndex }` — oversized chunk to split
- `maxSize` — `number` — max files per sub-chunk (defaults to `MIN_ASH_BUDGET`)

**Outputs**: `{ files, totalComplexity, chunkIndex }[]` — two or more balanced sub-chunks

**Error handling**: Single-file chunk returns it unchanged. Empty chunk returns `[]`.

```javascript
function splitChunk(chunk, maxSize = MIN_ASH_BUDGET) {
  if (chunk.files.length <= maxSize) return [chunk]
  if (chunk.files.length === 0) return []

  // Sort by complexity descending — interleave high/low for balance
  const sorted = [...chunk.files].sort((a, b) => b.complexity - a.complexity)
  const subChunks = []
  // BACK-005 FIX: Sub-chunks get temporary chunkIndex from parent. Step 5 of groupIntoChunks()
  // re-indexes ALL chunks sequentially after split, so duplicate indices here are transient.
  // Added comment to clarify the intentional re-index at step 5.
  let current = { files: [], totalComplexity: 0, chunkIndex: chunk.chunkIndex }

  for (const scored of sorted) {
    if (current.files.length >= maxSize) {
      subChunks.push(current)
      current = { files: [], totalComplexity: 0, chunkIndex: chunk.chunkIndex }
    }
    current.files.push(scored)
    current.totalComplexity += scored.complexity
  }
  if (current.files.length > 0) subChunks.push(current)

  return subChunks
}
```

## `groupIntoChunks(scoredFiles, targetSize)`

**Inputs**:
- `scoredFiles` — scored file array (output of `scoreFile` mapped across changed files)
- `targetSize` — `number` default `CHUNK_TARGET_SIZE`

**Outputs**: `{ files, totalComplexity, chunkIndex }[]` — balanced, directory-aware chunks

**Error handling**: Chunks exceeding `MAX_CHUNKS` are redistributed into larger chunks (not silently dropped). Files in excess are logged to Coverage Gaps in TOME.

```javascript
function groupIntoChunks(scoredFiles, targetSize = CHUNK_TARGET_SIZE) {
  // 1. Group by parent directory (preserves cross-file context)
  const dirGroups = groupByDirectory(scoredFiles)

  // 2. Sort directories by total complexity — highest first (first-fit decreasing)
  dirGroups.sort((a, b) => b.totalComplexity - a.totalComplexity)

  // 3. Bin-pack directories into chunks
  const avg = avgComplexity(scoredFiles)
  const maxChunkComplexity = targetSize * avg
  const chunks = []

  for (const group of dirGroups) {
    // Try to fit this directory into an existing chunk
    const target = chunks.find(c =>
      c.files.length + group.files.length <= targetSize &&
      c.totalComplexity + group.totalComplexity <= maxChunkComplexity
    )
    if (target) {
      target.files.push(...group.files)
      target.totalComplexity += group.totalComplexity
    } else {
      chunks.push({
        files: [...group.files],
        totalComplexity: group.totalComplexity,
        chunkIndex: chunks.length,
      })
    }
  }

  // 4. Split any chunk that exceeds MIN_ASH_BUDGET
  const splitChunks = chunks.flatMap(chunk =>
    chunk.files.length > MIN_ASH_BUDGET ? splitChunk(chunk) : [chunk]
  )

  // 5. Re-index after split (chunkIndex must be sequential, 0-based)
  splitChunks.forEach((c, i) => { c.chunkIndex = i })

  // 6. Circuit breaker — MAX_CHUNKS hard cap
  if (splitChunks.length > MAX_CHUNKS) {
    const dropped = splitChunks.slice(MAX_CHUNKS)
    const droppedFiles = dropped.flatMap(c => c.files.map(f => f.file))
    warn(`Chunk count ${splitChunks.length} exceeds MAX_CHUNKS=${MAX_CHUNKS}. Redistributing ${droppedFiles.length} files into larger chunks.`)

    // BACK-009 FIX: Redistribute excess files round-robin across ALL allowed chunks
    // instead of dumping into the last chunk. Prevents imbalanced 60+ file last chunk.
    const allowedChunks = splitChunks.slice(0, MAX_CHUNKS)
    const excessFiles = dropped.flatMap(c => c.files)
    const excessComplexity = dropped.reduce((s, c) => s + c.totalComplexity, 0)
    for (let i = 0; i < excessFiles.length; i++) {
      const targetChunk = allowedChunks[i % MAX_CHUNKS]
      targetChunk.files.push(excessFiles[i])
      targetChunk.totalComplexity += excessFiles[i].complexity
    }

    // Log files that pushed any chunk beyond MIN_ASH_BUDGET as Coverage Gaps
    for (const chunk of allowedChunks) {
      if (chunk.files.length > MIN_ASH_BUDGET) {
        const gapFiles = chunk.files.slice(MIN_ASH_BUDGET).map(f => f.file)
        warn(`Coverage Gaps (chunk ${chunk.chunkIndex + 1} exceeds per-Ash budget): ${gapFiles.join(', ')}`)
      }
    }

    return allowedChunks
  }

  return splitChunks
}
```

## Security Pinning

After `groupIntoChunks()`, collect security-critical files that must appear in every chunk as read-only context:

```javascript
function collectSecurityPins(scoredFiles) {
  return scoredFiles
    .filter(f => matchesAnyPattern(f.file, SECURITY_CRITICAL_PATTERNS))
    .map(f => f.file)
}

// Usage in chunk orchestrator:
// const securityPins = collectSecurityPins(scoredFiles)
// Each chunk review receives: { files: chunk.files, contextFiles: securityPins }
// contextFiles are read-only — Ashes can reference them but they don't count toward chunk budget
```

## References

- [Smart Selection](smart-selection.md) — Ash budget enforcement and file classification
- [Chunk Orchestrator](chunk-orchestrator.md) — How chunks are reviewed and merged
- [Security Patterns](security-patterns.md) — SAFE_PATH_PATTERN and validation
- [Team SDK engines.md](../../team-sdk/references/engines.md) — teamTransition and pre-create guard pattern
