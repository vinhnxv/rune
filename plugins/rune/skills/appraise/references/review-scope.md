# Review Scope Algorithms — Reference

This reference covers detailed diff scope algorithms: staged/unstaged/HEAD~N detection, chunk orchestration routing, and file filtering logic for `/rune:appraise`.

## Phase 0: Diff Scope Engine

```bash
# Determine what to review
branch=$(git branch --show-current)
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
if [ -z "$default_branch" ]; then
  default_branch=$(git rev-parse --verify origin/main >/dev/null 2>&1 && echo "main" || echo "master")
fi
repo_root=$(git rev-parse --show-toplevel)

# Get changed files — unified scope builder
if [ "--partial" in flags ]; then
  # Partial mode: staged files only (explicit choice — user knows what they're reviewing)
  changed_files=$(git -C "$repo_root" diff --cached --name-only)
else
  # Default: full scope — committed + staged + unstaged + untracked
  committed=$(git -C "$repo_root" diff --name-only --diff-filter=ACMR "${default_branch}...HEAD")
  staged=$(git -C "$repo_root" diff --cached --name-only --diff-filter=ACMR)
  unstaged=$(git -C "$repo_root" diff --name-only)
  untracked=$(git -C "$repo_root" ls-files --others --exclude-standard)
  # Merge and deduplicate, remove non-existent files and symlinks
  changed_files=$(echo "$committed"$'\n'"$staged"$'\n'"$unstaged"$'\n'"$untracked" | sort -u | grep -v '^$')
  changed_files=$(echo "$changed_files" | while read f; do
    [ -f "$repo_root/$f" ] && [ ! -L "$repo_root/$f" ] && echo "$f"
  done)
fi
```

<!-- v3.x: defaults baked from former talisman.review; see references/v3-defaults.md -->
### Diff Range Generation

Generate line-level diff ranges for downstream TOME tagging (Phase 5.3) and scope-aware mend filtering. See `rune-orchestration/references/diff-scope.md` for the full algorithm.

```javascript
// v3.x: diff_scope.enabled hardcoded to true, expansion hardcoded to 8

let diffScope = { enabled: false }

if (changed_files.length > 0) {
  // SEC-WS-001: Validate defaultBranch before shell interpolation
  const BRANCH_NAME_REGEX = /^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/
  if (!BRANCH_NAME_REGEX.test(default_branch) || default_branch.includes('..')) {
    warn(`Invalid default branch name: ${default_branch} — disabling diff scope`)
  } else {
    // Single-invocation diff — O(1) shell calls (see diff-scope.md STEP 2-3)
    const EXPANSION_ZONE = 8
    let diffOutput
    if (flags['--partial']) {
      diffOutput = Bash(`git diff --cached --unified=0 -M`)
    } else {
      // SEC-003 FIX: BRANCH_NAME_REGEX (line 104) is the correct defense against argument injection.
      // Do NOT use `--` separator here — it causes git to interpret the revision range as a file path,
      // silently producing zero diff output (BACK-005).
      diffOutput = Bash(`git diff --unified=0 -M "${default_branch}...HEAD"`)
    }

    if (diffOutput.exitCode !== 0) {
      warn(`git diff failed (exit ${diffOutput.exitCode}) — disabling diff scope`)
    } else {
      // Parse diff output into per-file line ranges
      // See diff-scope.md STEP 3 for full parsing algorithm
      const headSha = Bash(`git rev-parse HEAD`).trim()
      const ranges = parseDiffRanges(diffOutput, EXPANSION_ZONE)  // diff-scope.md STEP 3-4

      diffScope = {
        enabled: true,
        base: default_branch,
        expansion: EXPANSION_ZONE,
        ranges: ranges,
        head_sha: headSha,
        version: 1
      }
    }
  }
}

// Write diff ranges to file for large diffs (>50 files)
if (diffScope.enabled && Object.keys(diffScope.ranges).length > 50) {
  Write(`tmp/reviews/${identifier}/diff-ranges.json`, JSON.stringify(diffScope.ranges))
  log(`Diff ranges written to tmp/reviews/${identifier}/diff-ranges.json (${Object.keys(diffScope.ranges).length} files)`)
}
```

### Scope File Override (--scope-file)

When `--scope-file` is provided, override git-diff-based `changed_files`:

```javascript
// --scope-file: Override changed_files from a JSON focus file (used by arc convergence controller)
if (flags['--scope-file']) {
  const scopePath = flags['--scope-file']
  // Security pattern: SAFE_FILE_PATH — see security-patterns.md
  const SAFE_FILE_PATH = /^[a-zA-Z0-9._\-\/]+$/
  if (!SAFE_FILE_PATH.test(scopePath) || scopePath.includes('..') || scopePath.startsWith('/')) {
    error(`Invalid --scope-file path: ${scopePath}`)
    return
  }
  try {
    const scopeData = JSON.parse(Read(scopePath))
    if (Array.isArray(scopeData?.focus_files) && scopeData.focus_files.length > 0) {
      // SEC-001: Validate each entry against SAFE_FILE_PATH before use
      changed_files = scopeData.focus_files.filter(f =>
        typeof f === 'string' && SAFE_FILE_PATH.test(f) && !f.includes('..') && !f.startsWith('/') && exists(f) && !isSymlink(f)
      )
      log(`Scope override: ${changed_files.length} files from ${scopePath}`)
    } else {
      warn(`--scope-file ${scopePath} has no focus_files — falling back to git diff scope`)
    }
  } catch (e) {
    warn(`Failed to parse --scope-file: ${e.message} — falling back to git diff scope`)
  }
}
```

## Chunk Decision Routing

After file collection, determine review path:

```javascript
// v3.x: chunk_threshold=20, chunk_target_size=15, max_chunks=5 (hardcoded)
// SEC-006 FIX: parseInt with explicit radix 10
// BACK-012 FIX: --chunk-size overrides CHUNK_THRESHOLD (file count trigger), not CHUNK_TARGET_SIZE
const rawChunkSize = flags['--chunk-size'] ? parseInt(flags['--chunk-size'], 10) : NaN
const CHUNK_THRESHOLD = (!Number.isNaN(rawChunkSize) && rawChunkSize >= 5 && rawChunkSize <= 200)
  ? rawChunkSize
  : 20
const CHUNK_TARGET_SIZE = 15
const MAX_CHUNKS = 5

// BACK-013 FIX: Normalize flags access — use object key lookup consistently (not .includes())
if (changed_files.length > CHUNK_THRESHOLD && !flags['--no-chunk']) {
  // Route to chunked review — delegate to chunk-orchestrator.md
  // All existing single-pass phases (1-7) run INSIDE each chunk iteration
  // See chunk-orchestrator.md for the full algorithm:
  //   - File scoring (chunk-scoring.md)
  //   - Chunk grouping (directory-aware, flat fallback)
  //   - Per-chunk Roundtable Circle (distinct team names: rune-review-{id}-chunk-{N})
  //   - Convergence loop (convergence-gate.md)
  //   - Cross-chunk TOME merge
  log(`Chunked review: ${changed_files.length} files > threshold ${CHUNK_THRESHOLD}`)
  log(`Token cost scales ~${Math.min(Math.ceil(changed_files.length / CHUNK_THRESHOLD), MAX_CHUNKS)}x vs single-pass.`)
  // QUAL-003 FIX: Correct argument order — definition is (changed_files, identifier, flags)
  runChunkedReview(changed_files, identifier, flags)
  return  // Phase 0 routing complete
}
// else: continue with single-pass review below (zero behavioral change)
```

**Single-pass path** continues for `changed_files.length <= CHUNK_THRESHOLD` or when `--no-chunk` is set.

**Scope summary** (displayed after file collection in non-partial mode):
```
Review scope:
  Committed: {N} files (vs {default_branch})
  Staged: {N} files
  Unstaged: {N} files (local modifications)
  Untracked: {N} files (new, not yet in git)
  Total: {N} unique files
```

## Abort Conditions

- No changed files → "Nothing to review. Make some changes first."
- Only non-reviewable files (images, lock files) → "No reviewable changes found."
- All doc-extension files fell below line threshold AND code/infra files exist → summon only always-on Ashes

**Docs-only override:** Promote all doc files when no code files exist. See `rune-gaze.md` for the full algorithm.

## Multi-Pass Cycle Wrapper (--cycles)

When `--cycles N` is specified with N > 1, Phase 2 through Phase 7 run inside a cycle loop:

```javascript
// Parse --cycles (validated as numeric 1-5 in flag parsing)
const cycleCount = flags['--cycles'] ? parseInt(flags['--cycles'], 10) : 1
if (Number.isNaN(cycleCount) || cycleCount < 1 || cycleCount > 5) {
  error(`Invalid --cycles value: ${flags['--cycles']}. Must be numeric 1-5.`)
  return
}

if (cycleCount > 1) {
  log(`Multi-pass review: ${cycleCount} cycles requested`)
  const cycleTomes = []

  // SEC-002: Defense-in-depth — re-validate identifier before constructing cycleIdentifier
  if (!/^[a-zA-Z0-9_-]+$/.test(identifier)) {
    error(`Invalid identifier in multi-pass wrapper: ${identifier}`)
    return
  }

  for (let cycle = 1; cycle <= cycleCount; cycle++) {
    const cycleIdentifier = `${identifier}-cycle-${cycle}`
    log(`\n--- Cycle ${cycle}/${cycleCount} (team: rune-review-${cycleIdentifier}) ---`)

    // BACK-011 FIX: Explicit invocation pattern for Phase 2-7 per cycle.
    // Each cycle creates its own team, runs the full Roundtable Circle,
    // and produces a TOME at tmp/reviews/{cycleIdentifier}/TOME.md
    runSinglePassReview(changed_files, cycleIdentifier, flags)

    // After cycle completes, collect the TOME path
    const cycleTomePath = `tmp/reviews/${cycleIdentifier}/TOME.md`
    // SEC-001 FIX: Use strict equality instead of .includes()
    if (exists(cycleTomePath) && Bash(`test -L "${cycleTomePath}" && echo symlink 2>/dev/null`).trim() !== 'symlink') {
      cycleTomes.push(cycleTomePath)
    } else {
      warn(`Cycle ${cycle} produced no TOME — skipping in merge`)
    }
  }

  // Ensure merge destination directory exists (runSinglePassReview only creates {identifier}-cycle-N dirs)
  Bash(`mkdir -p "tmp/reviews/${identifier}"`)

  // Merge cycle TOMEs into final TOME
  if (cycleTomes.length === 0) {
    warn(`All ${cycleCount} cycles produced no findings.`)
  } else if (cycleTomes.length === 1) {
    Bash(`cp -- "${cycleTomes[0]}" "tmp/reviews/${identifier}/TOME.md"`)
  } else {
    // Multi-TOME merge: deduplicate by finding ID, keep highest severity
    log(`Merging ${cycleTomes.length} cycle TOMEs...`)
    const mergedFindings = []
    const seenFindings = new Set()  // Track by file:line:prefix to dedup

    for (const tomePath of cycleTomes) {
      const tomeContent = Read(tomePath)
      const findings = extractFindings(tomeContent)  // Parse RUNE:FINDING markers
      for (const f of findings) {
        const dedupKey = `${f.file}:${f.line}:${f.prefix}`
        if (!seenFindings.has(dedupKey)) {
          seenFindings.add(dedupKey)
          mergedFindings.push(f)
        }
        // If duplicate, keep existing (first-seen wins — consistent with Runebinder)
      }
    }

    // Write merged TOME
    Write(`tmp/reviews/${identifier}/TOME.md`, formatMergedTome(mergedFindings, cycleTomes.length))
  }

  // Auto-mend for multi-pass (v3.x: review.auto_mend hardcoded to false; only flag triggers)
  const autoMendMulti = flags['--auto-mend']
  const mergedTomePath = `tmp/reviews/${identifier}/TOME.md`
  if (autoMendMulti && exists(mergedTomePath)) {
    const mergedTome = Read(mergedTomePath)
    const mp1 = (mergedTome.match(/severity="P1"/g) || []).length
    const mp2 = (mergedTome.match(/severity="P2"/g) || []).length
    if (mp1 + mp2 > 0) {
      log(`Auto-mend (multi-pass): ${mp1} P1 + ${mp2} P2 findings. Invoking /rune:mend...`)
      Skill("rune:mend", mergedTomePath)
    } else {
      log("Auto-mend (multi-pass): no P1/P2 findings in merged TOME. Skipping mend.")
    }
  }

  return
}

// Single-pass (cycleCount === 1): continue with standard Phase 2-7 below
```

**NOTE**: When `cycleCount === 1` (default), this wrapper is a no-op and the standard single-pass path continues unchanged. Multi-pass is only available in standalone `/rune:appraise` — arc convergence uses the Phase 7.5 convergence controller instead.

## Chunked Review (Large Changesets)

When `changed_files.length > CHUNK_THRESHOLD` (default: 20) and `--no-chunk` is not set, review is routed to the chunked path. The inner Roundtable Circle pipeline (Phases 1–7) runs unchanged for each chunk — chunking wraps, never modifies the core review.

**Key behaviors:**
- Each chunk gets a distinct team lifecycle (`rune-review-{id}-chunk-{N}`) with pre-create guard applied between chunks
- Finding IDs use standard `{PREFIX}-{NUM}` format with a `chunk="N"` attribute in the `<!-- RUNE:FINDING -->` HTML comment (not a prefix, to preserve dedup/parsing compatibility)
- Cross-chunk dedup runs on `(file, line_range_bucket)` keys — strip any chunk context before keying
- Per-chunk timeout scales with `chunk.totalComplexity`; max 5 chunks (circuit breaker)
- Files beyond MAX_CHUNKS are logged to Coverage Gaps in the unified TOME

**Output paths:**
- Per-chunk TOMEs: `tmp/reviews/{id}/chunk-{N}/TOME.md`
- Unified TOME: `tmp/reviews/{id}/TOME.md`
- Convergence report: `tmp/reviews/{id}/convergence-report.md`
- Cross-cutting findings (optional): `tmp/reviews/{id}/cross-cutting.md`

**Reference files:**
- Full chunking algorithm: [`chunk-orchestrator.md`](../../roundtable-circle/references/chunk-orchestrator.md)
- File scoring and grouping: [`chunk-scoring.md`](../../roundtable-circle/references/chunk-scoring.md)
- Convergence metrics, thresholds, and decision matrix: [`convergence-gate.md`](../../roundtable-circle/references/convergence-gate.md)
