<!-- v3.x: defaults baked from former talisman.review; see references/v3-defaults.md -->

# Diff-Scope Engine — Line-Level Diff Range Generation

Generates per-file line ranges from `git diff` output. Used by `/rune:appraise` Phase 0 to enrich inscription.json with diff scope data, enabling downstream TOME tagging (Phase 5.3) and scope-aware mend filtering.

## Algorithm

**Inputs**: `defaultBranch` (string), `flags` (partial mode flag)
**Outputs**: `diff_scope` object for inscription.json enrichment
**Error handling**: On git diff failure, set `diff_scope.enabled = false` and default all findings to `scope="in-diff"` (preserving current behavior)

### STEP 1: Validate Default Branch

```javascript
// SEC-WS-001: Validate defaultBranch against branch name regex before shell interpolation
const BRANCH_NAME_REGEX = /^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/
if (!BRANCH_NAME_REGEX.test(defaultBranch) || defaultBranch.includes('..')) {
  error(`Invalid default branch name: ${defaultBranch}`)
  return { enabled: false, reason: 'invalid_default_branch' }
}
```

### STEP 2: Generate Raw Diff (Single Invocation)

```javascript
// Performance: Single invocation — O(1) shell calls instead of O(N) per-file calls.
// Three-dot syntax uses merge base, handling merge commits correctly.
// v3.x: expansion baked at 8 (was former talisman.review).
const expansion = 8

let diffOutput
if (flags['--partial']) {
  // Partial mode: staged changes only
  diffOutput = Bash(`git diff --cached --unified=0 -M`)
} else {
  diffOutput = Bash(`git diff --unified=0 -M "${defaultBranch}...HEAD"`)
}

// Fallback: if git diff exits non-zero or produces empty output when changed files exist
if (diffOutput.exitCode !== 0) {
  warn(`git diff failed (exit ${diffOutput.exitCode}) — disabling diff scope`)
  return { enabled: false, reason: 'git_diff_failed' }
}

// Pin HEAD SHA for stale-range detection at Phase 5.3
const headSha = Bash(`git rev-parse HEAD`).trim()
```

### STEP 3: Parse Diff Output

```javascript
// Split output by file boundaries: "diff --git a/... b/..."
const FILE_BOUNDARY = /^diff --git a\/(.+) b\/(.+)$/m
const HUNK_HEADER = /^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@/

const ranges = {}

// Parse file boundaries from unified output
const fileSections = diffOutput.split(/(?=^diff --git )/m).filter(Boolean)

for (const section of fileSections) {
  const fileMatch = section.match(FILE_BOUNDARY)
  if (!fileMatch) continue

  const filePath = fileMatch[2]  // Use b/ path (destination after rename)

  // Path normalization: POSIX forward-slash, NFC form, repo-root-relative
  const normalizedPath = filePath
    .replace(/\\/g, '/')          // Windows backslash to forward slash
    .replace(/\/+/g, '/')         // SEC-011 FIX: Collapse double-slashes (key mismatch prevention)
    .normalize('NFC')             // NFC normalization for macOS compatibility

  // Security: validate path before use
  if (!normalizedPath || normalizedPath.includes('..') || normalizedPath.startsWith('/')) {
    warn(`Unsafe path in diff: ${filePath} — skipping`)
    continue
  }

  // Check for binary file (no @@ headers)
  if (section.includes('Binary files')) {
    // Binary files: assign full scope [1, null] or skip
    ranges[normalizedPath] = [[1, null]]
    continue
  }

  // Check for rename (git diff -M detects renames)
  const isRename = section.includes('rename from') || section.includes('similarity index')

  // Check for new file
  const isNewFile = section.includes('new file mode')

  if (isNewFile || isRename) {
    // New files and renames: entire file is in scope
    ranges[normalizedPath] = [[1, null]]
    continue
  }

  // Parse hunk headers
  const hunks = []
  for (const line of section.split('\n')) {
    // STEP 3a: Anchor to line start to prevent crafted function names from creating phantom ranges
    const hunkMatch = line.match(HUNK_HEADER)
    if (hunkMatch) {
      const start = parseInt(hunkMatch[1], 10)
      const count = hunkMatch[2] ? parseInt(hunkMatch[2], 10) : 1
      if (count === 0) continue  // Pure deletion hunk (0 lines added)
      hunks.push([start, start + count - 1])
    }
  }

  // Edge case: file appears in diff --stat but produces 0 parseable hunks
  if (hunks.length === 0) {
    warn(`File ${normalizedPath} in diff but has 0 parseable hunks — assigning full scope`)
    ranges[normalizedPath] = [[1, null]]
    continue
  }

  // STEP 3b: Expand by ±EXPANSION_ZONE
  const expandedHunks = hunks.map(([start, end]) => [
    Math.max(1, start - expansion),
    end + expansion
  ])

  // STEP 3c: Merge overlapping ranges (sort by start, sweep)
  expandedHunks.sort((a, b) => a[0] - b[0])
  const merged = [expandedHunks[0]]
  for (let i = 1; i < expandedHunks.length; i++) {
    const prev = merged[merged.length - 1]
    const curr = expandedHunks[i]
    if (curr[0] <= prev[1] + 1) {
      // Overlapping or adjacent — extend
      prev[1] = Math.max(prev[1], curr[1])
    } else {
      merged.push(curr)
    }
  }

  ranges[normalizedPath] = merged
}
```

### STEP 4: Build diff_scope Object

```javascript
const diffScope = {
  enabled: true,
  base: defaultBranch,
  expansion: expansion,
  ranges: ranges,
  head_sha: headSha,
  version: 1              // Schema version for future evolution
}

// Pathological diff guard: cap at 200 files
if (Object.keys(ranges).length > 200) {
  warn(`Large diff: ${Object.keys(ranges).length} files — capping diff_scope.ranges to top 200`)
  const sortedFiles = Object.entries(ranges)
    .sort((a, b) => {
      // Prioritize files with more specific ranges over full-file [1, null]
      const aFull = a[1].length === 1 && a[1][0][1] === null
      const bFull = b[1].length === 1 && b[1][0][1] === null
      if (aFull !== bFull) return aFull ? 1 : -1
      return 0
    })
    .slice(0, 200)
  diffScope.ranges = Object.fromEntries(sortedFiles)
}

return diffScope
```

## Scope Tagging (Phase 5.3)

Tags each RUNE:FINDING in the TOME with `scope="in-diff"` or `scope="pre-existing"`.
Runs after Phase 5 (Aggregation) and BEFORE Phase 5.5 (Cross-Model Verification in `/rune:appraise`; not to be confused with Arc Phase 5.5 Gap Analysis).

```javascript
// STEP 1: Read TOME and diff_scope from inscription.json
const tome = Read(`tmp/reviews/${identifier}/TOME.md`)
const inscription = JSON.parse(Read(`tmp/reviews/${identifier}/inscription.json`))
const diffScope = inscription.diff_scope

if (!diffScope?.enabled || !diffScope?.ranges) {
  log("Diff-scope tagging skipped: diff_scope not enabled or no ranges")
  return tome  // Return unmodified
}

// STEP 1b: Verify HEAD hasn't changed (stale range detection)
const currentHead = Bash(`git rev-parse HEAD`).trim()
if (diffScope.head_sha && currentHead !== diffScope.head_sha) {
  warn(`HEAD changed since diff range generation (${diffScope.head_sha} → ${currentHead}). Ranges may be stale.`)
}

// STEP 2: Parse all RUNE:FINDING markers
const FINDING_PATTERN = /<!-- RUNE:FINDING\s+([^>]+)-->/g
const findings = []
let match
while ((match = FINDING_PATTERN.exec(tome)) !== null) {
  const attrs = match[1]
  const file = attrs.match(/file="([^"]+)"/)?.[1]
  const line = parseInt(attrs.match(/line="(\d+)"/)?.[1], 10)
  const severity = attrs.match(/severity="([^"]+)"/)?.[1]

  // SEC-002 FIX: Validate attribute values at extraction time
  // Severity must be P1/P2/P3 (case-insensitive, normalized to uppercase)
  const normalizedSeverity = severity?.toUpperCase()
  if (normalizedSeverity && !/^P[1-3]$/.test(normalizedSeverity)) {
    warn(`Invalid severity "${severity}" in FINDING marker — skipping`)
    continue
  }
  // File path must pass safe-path check (no path traversal, no special chars)
  const SAFE_FILE_PATH = /^[a-zA-Z0-9._\/-]+$/
  if (file && (!SAFE_FILE_PATH.test(file) || file.includes('..'))) {
    warn(`Unsafe file path "${file}" in FINDING marker — skipping`)
    continue
  }

  if (file && !isNaN(line)) {
    findings.push({ file, line, severity: normalizedSeverity, offset: match.index, fullMatch: match[0] })
  }
}

// STEP 3: Tag each finding
for (const finding of findings) {
  const normalizedFile = finding.file.replace(/^\.\//, '').normalize('NFC')
  const fileRanges = diffScope.ranges[normalizedFile]

  if (!fileRanges) {
    // File not in diff at all — definitely pre-existing
    finding.scope = "pre-existing"
  } else if (fileRanges.length === 1 && fileRanges[0][1] === null) {
    // New file / rename / binary — everything is in-diff
    finding.scope = "in-diff"
  } else {
    // Check if finding line falls within any expanded range
    const inRange = fileRanges.some(([start, end]) =>
      finding.line >= start && finding.line <= end
    )
    finding.scope = inRange ? "in-diff" : "pre-existing"
  }
}

// STEP 4: SEC-WS-003 — Strip ALL non-canonical attributes BEFORE injecting scope
// An Ash (or reviewed code via prompt injection) could pre-insert scope="in-diff"
// or inject arbitrary attributes (fake severity, etc.)
// SEC-001 FIX: Apply strip-loop to remove ALL occurrences (not just first per marker)
// SEC-017 FIX: Strip ALL non-canonical attributes, not just scope.
// Canonical attributes: nonce, id, file, line, severity, scope
const CANONICAL_ATTRS = new Set(['nonce', 'id', 'file', 'line', 'severity', 'scope'])
let taggedTome = tome
taggedTome = taggedTome.replace(
  /<!-- RUNE:FINDING\s+([^>]+)-->/g,
  (marker, attrs) => {
    // Parse all key="value" pairs, keep only canonical ones (excluding scope — re-injected in STEP 5)
    const kept = []
    const attrPattern = /(\w+)="([^"]*)"/g
    let m
    while ((m = attrPattern.exec(attrs)) !== null) {
      if (CANONICAL_ATTRS.has(m[1]) && m[1] !== 'scope') {
        kept.push(`${m[1]}="${m[2]}"`)
      }
    }
    return `<!-- RUNE:FINDING ${kept.join(' ')} -->`
  }
)

// STEP 5: Inject scope attribute into RUNE:FINDING markers
// Work from end to start to preserve offsets
for (const finding of [...findings].reverse()) {
  // Find the marker in the (potentially modified) TOME
  const markerPattern = new RegExp(
    `<!-- RUNE:FINDING\\s+[^>]*?file="${finding.file.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]*?line="${finding.line}"[^>]*?-->`
  )
  taggedTome = taggedTome.replace(markerPattern, (match) => {
    // Insert scope before closing -->
    return match.replace(/\s*-->/, ` scope="${finding.scope}" -->`)
  })
}

// STEP 6: Validate tagged TOME — re-parse and confirm finding count matches
const retaggedFindings = (taggedTome.match(/<!-- RUNE:FINDING/g) || []).length
if (retaggedFindings !== findings.length) {
  warn(`Tagging validation failed: expected ${findings.length} findings, found ${retaggedFindings}. Using original TOME.`)
  return tome  // Rollback: return unmodified TOME
}

// STEP 7: Write tagged TOME
Write(`tmp/reviews/${identifier}/TOME.md`, taggedTome)

// STEP 8: Log tagging summary
const inDiff = findings.filter(f => f.scope === "in-diff").length
const preExisting = findings.filter(f => f.scope === "pre-existing").length
log(`Diff-scope tagging: ${inDiff} in-diff, ${preExisting} pre-existing (of ${findings.length} total)`)

return taggedTome
```

## Sentinel Values

- **`null`** sentinel in ranges: `[1, null]` means "to end of file" — used for new files, renames, and binary files. JSON-safe unlike `"Infinity"`.
- Consumers check `range[1] === null` to detect full-file scope.
- Expansion zone of `0` produces exact hunk boundaries only.
