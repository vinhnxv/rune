# Phase 5.0: Pre-Aggregate — Reference Algorithm

> Deterministic marker-based extraction of Ash findings before Runebinder ingestion. Threshold-gated — no behavioral change for small reviews. No LLM calls — pure text processing at Tarnished level.

Phase 5.0 sits between Phase 4 (Monitor) and Phase 5 (Aggregate). When combined Ash output exceeds a configurable byte threshold, it extracts structured RUNE:FINDING blocks, discards boilerplate prose, and writes condensed copies for Runebinder consumption. Original files are never modified.

> **Phase ordering dependency (VEIL-005)**: Phase 5.0 MUST run after Phase 4 Monitor signals
> completion (all Ash outputs written and flushed to disk). Running pre-aggregation while Ash
> files are still being written will produce incomplete condensed outputs. The `orchestration-phases.md`
> Phase 5.0 integration point enforces this ordering — do not invoke `preAggregate()` before
> `waitForCompletion()` confirms Phase 4 has finished.

## Configuration

Talisman keys under `review.pre_aggregate`:

**User-tunable keys** (the only two most users need to change):

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Master toggle. Set `false` to disable entirely (opt-OUT). |
| `threshold_bytes` | number | `25000` | Combined Ash output size (bytes) that triggers compression. **Configurable default — not empirically validated against production Ash outputs. Tune this based on observed review sizes and Runebinder latency.** |

**Internal constants** (hardcoded defaults — do not change unless you have a specific reason):

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `preserve_priorities` | string[] | `["P1", "P2"]` | Severity levels preserved with zero information loss. Changing this breaks Runebinder assumptions — leave as-is. |
| `truncate_trace_lines` | number | `3` | Max Rune Trace code lines retained for P3 findings. Hardcoded in practice; no use case for adjustment. |
| `nit_summary_only` | boolean | `true` | Convert N (nit) findings to single-line summaries. Always true — no use case for false. |

**Config access pattern**: `talisman?.review?.pre_aggregate ?? {}` — follows standard `readTalisman()` convention.

## Main Algorithm: preAggregate()

```javascript
// Phase 5.0: Pre-Aggregate (conditional on combined size)
//
// INPUT:  {output_dir}/ containing Ash output files (*.md, excluding TOME*, _*)
// OUTPUT: {output_dir}/condensed/{ash-slug}.md for each Ash
//         {output_dir}/condensed/_compression-report.md
//
// THRESHOLD: talisman.review.pre_aggregate.threshold_bytes (default 25000)
// SKIP WHEN: combined size < threshold OR pre_aggregate.enabled === false
// RUNS AT:   Tarnished level — NO subagent spawned (would add context pressure)

function preAggregate(outputDir, talisman) {
  const config = talisman?.review?.pre_aggregate ?? {}
  if (config.enabled === false) return  // Master toggle

  const threshold = config.threshold_bytes ?? 25000
  const preservePriorities = config.preserve_priorities ?? ["P1", "P2"]
  const truncateTraceLines = config.truncate_trace_lines ?? 3
  const nitSummaryOnly = config.nit_summary_only ?? true

  // 1. Discover Ash output files (exclude TOME and internal files)
  const ashFiles = Glob(`${outputDir}*.md`)
    .filter(f => !basename(f).startsWith('TOME') && !basename(f).startsWith('_'))

  if (ashFiles.length === 0) return  // No Ash outputs (EC-1 variant)

  // 2. Measure combined size
  //    IMPORTANT: parseInt with radix 10 — wc -c returns a string
  //
  //    ASSUMPTION NOTE (VEIL-005): This loop spawns one Bash process per Ash file.
  //    Process spawning typically costs 5-15ms per invocation, so 7 files = ~35-105ms
  //    just for size measurement — even on the "fast path" (under threshold). The fast
  //    path is not free. To reduce overhead to a single process spawn, consider:
  //      Bash(`find "${outputDir}" -maxdepth 1 -name '*.md' ! -name 'TOME*' ! -name '_*' -exec wc -c {} + | tail -1`)
  //    This is a future optimization; current implementation favors simplicity.
  let combinedBytes = 0
  for (const f of ashFiles) {
    const stat = Bash(`wc -c < "${f}"`)
    combinedBytes += parseInt(stat.trim(), 10)
  }

  if (combinedBytes < threshold) return  // Under threshold — skip (fast path)

  // 3. Create condensed/ directory
  //
  //    LIMITATION NOTE (BACK-004): mkdir -p failure is not checked here.
  //    If this fails (permissions, full disk, symlink attack), subsequent Write()
  //    calls will throw individually — but there is no pre-flight error check.
  //    In practice, Tarnished-level execution is not permission-constrained, but
  //    production hardening should add:
  //      if (!Bash(`mkdir -p "${outputDir}condensed/" && echo ok`).includes('ok')) throw ...
  Bash(`mkdir -p "${outputDir}condensed/"`)

  // 4. For each Ash file, extract and condense
  const metrics = []
  for (const ashFile of ashFiles) {
    const slug = basename(ashFile, '.md')
    const content = Read(ashFile)
    const originalBytes = content.length

    // 4a. Extract header (Ash identity — first lines before ## sections)
    const header = extractHeader(content)

    // 4b. Extract all RUNE:FINDING blocks via marker parsing
    const findings = extractFindingBlocks(content)

    // 4c. Apply priority-based compression per finding
    const compressed = findings.map(f => compressFinding(f, {
      preservePriorities,
      truncateTraceLines,
      nitSummaryOnly
    }))

    // 4d. Extract ## Reviewer Assumptions section (if present)
    const assumptions = extractSection(content, '## Reviewer Assumptions')

    // 4e. Extract ## Summary section (if present)
    const summary = extractSection(content, '## Summary')

    // 4f. Assemble and write condensed file
    const condensed = [
      header,
      ...compressed,
      assumptions,
      summary
    ].filter(Boolean).join('\n\n')

    Write(`${outputDir}condensed/${slug}.md`, condensed)

    metrics.push({
      ash: slug,
      originalBytes,
      condensedBytes: condensed.length,
      findingCount: findings.length,
      ratio: (condensed.length / originalBytes * 100).toFixed(1)
    })
  }

  // 5. Write compression report for observability + echo persistence
  writeCompressionReport(`${outputDir}condensed/_compression-report.md`, metrics, {
    combinedOriginal: combinedBytes,
    combinedCondensed: metrics.reduce((s, m) => s + m.condensedBytes, 0),
    threshold
  })
}
```

**Key invariants**:
- Original Ash output files are NEVER modified (condensed copies only)
- All RUNE:FINDING marker attributes (nonce, id, file, line, severity, confidence, confidence_score) are preserved through compression
- Dedup is NOT applied here — that is Runebinder's responsibility (see [dedup-runes.md](dedup-runes.md))
- No LLM calls — all extraction is regex-based

## Finding Extraction: extractFindingBlocks()

Extracts all `<!-- RUNE:FINDING ... -->` ... `<!-- /RUNE:FINDING ... -->` blocks from an Ash output file. Returns structured objects with parsed marker attributes for downstream compression decisions.

```javascript
// Extracts all RUNE:FINDING marker-delimited blocks from content.
// Returns array of finding objects with parsed attributes.
//
// Marker format (see review-checklist.md for canonical spec):
//   Opening: <!-- RUNE:FINDING nonce="..." id="SEC-001" file="api/users.py" line="42" severity="P1" ... -->
//   Closing: <!-- /RUNE:FINDING id="SEC-001" -->
//
// Handles: multi-line content, nested code blocks, markdown formatting
//
// KNOWN REGEX LIMITATIONS (BACK-004):
//   - Nested HTML comments: <!-- ... <!-- RUNE:FINDING --> --> will confuse the outer
//     regex and may produce incorrect startIdx/endIdx ranges.
//   - Very large files (>500KB): The /g exec loop on MARKER_OPEN may run slowly.
//     No timeout guard exists — regex cannot be interrupted.
//   - ID collisions: If two findings share the same id= attribute, closeMatch will
//     always match the first occurrence, potentially creating overlapping blocks.
//   - Attribute ordering: parseMarkerAttributes depends on key="value" format only.
//     Any other quoting style (single quotes, unquoted values) silently drops the attr.

function extractFindingBlocks(content) {
  const blocks = []
  const MARKER_OPEN = /<!-- RUNE:FINDING\s+([^>]+)-->/g
  const MARKER_CLOSE = (id) => new RegExp(`<!-- /RUNE:FINDING\\s+id="${id}"\\s*-->`)

  let match
  while ((match = MARKER_OPEN.exec(content)) !== null) {
    const attrs = parseMarkerAttributes(match[1])
    const startIdx = match.index
    const afterOpen = match.index + match[0].length
    const closeMatch = content.slice(afterOpen).match(MARKER_CLOSE(attrs.id))

    if (closeMatch) {
      // Marker validation step — reject malformed or unsafe attributes before
      // adding to blocks. This guards against buggy or adversarial Ash output.
      //
      // Validation rules (per VEIL-008 recommendation):
      //   - id:    must match known prefix pattern (ALPHA-NNN or ALPHA-NNN-Q/N)
      //   - file:  must not contain path traversal sequences (..) or start with /
      //   - nonce: must be present and non-empty (required by SEC-010)
      //   - line:  if present, must be numeric
      //
      // Validation failures are counted and surfaced in the compression report.
      // If >10% of extracted markers fail validation, a warning is emitted.
      const VALID_ID = /^[A-Z][A-Z0-9]+-\d+(-[QN])?$/
      const hasPathTraversal = (attrs.file || '').includes('..') || (attrs.file || '').startsWith('/')
      const validId = !attrs.id || VALID_ID.test(attrs.id)
      const hasNonce = attrs.nonce && attrs.nonce.length > 0
      const validLine = !attrs.line || /^\d+$/.test(attrs.line)

      if (!validId || hasPathTraversal || !hasNonce || !validLine) {
        // Skip malformed marker — logged in report as validation failure
        // (counts toward the >10% threshold warning)
        continue
      }

      // Full block: opening marker + content + closing marker
      const endIdx = afterOpen + closeMatch.index + closeMatch[0].length
      const block = content.slice(startIdx, endIdx)
      blocks.push({
        fullBlock: block,
        marker: match[0],
        closingMarker: closeMatch[0],
        id: attrs.id,
        file: attrs.file,
        line: attrs.line,
        severity: attrs.severity,
        interaction: attrs.interaction,      // "question" | "nit" | undefined
        confidence: attrs.confidence,
        confidence_score: attrs.confidence_score,
        nonce: attrs.nonce
      })
    }
    // EC-2: If closing marker is missing, skip this finding (logged in report)
  }
  return blocks
}
```

## Marker Attribute Parsing: parseMarkerAttributes()

Parses key="value" pairs from the attribute string inside a RUNE:FINDING marker. All attributes defined in [review-checklist.md](agent-patterns/review-checklist.md) are extracted.

```javascript
// Parses 'nonce="abc" id="SEC-001" file="api/users.py" line="42" severity="P1"'
// into { nonce: "abc", id: "SEC-001", file: "api/users.py", line: "42", severity: "P1" }
//
// Known attributes (all preserved through compression):
//   nonce, id, file, line, severity, confidence, confidence_score, interaction
//
// BOUNDS NOTE (BACK-008): The regex /(\w+)="([^"]*)"/g silently ignores:
//   - Unquoted values: id=SEC-001 (no quotes) → key not captured
//   - Single-quoted: id='SEC-001' → not matched
//   - Escaped double quotes: message="found \"string\"" → truncated at first escaped quote
//   If an Ash emits nonce with single quotes (nonce='abc'), the nonce key will be absent
//   from the returned attrs object, causing the VEIL-008 validation to reject the finding.
//   The canonical Ash marker format (review-checklist.md) mandates double-quoted values,
//   so this is an edge case only for non-conforming Ash output.
//
// METRICS NOTE (BACK-008): `confidence_score` values are floating point (e.g., 0.95).
//   No overflow protection: if an Ash emits an unreasonably large value, parseInt/parseFloat
//   on downstream consumers may produce Infinity. Add bounds checks in consumers if
//   confidence_score is used in arithmetic (e.g., weighted dedup scoring).

function parseMarkerAttributes(attrString) {
  const attrs = {}
  const ATTR_PATTERN = /(\w+)="([^"]*)"/g
  let m
  while ((m = ATTR_PATTERN.exec(attrString)) !== null) {
    attrs[m[1]] = m[2]
  }
  return attrs
}
```

## Priority-Based Compression: compressFinding()

Applies compression rules based on finding severity and interaction type. P1/P2 findings are fully preserved — all marker attributes and body text are byte-identical to the original (marker-level preservation). P3 findings get truncated Rune Traces. Q (question) findings lose traces entirely. N (nit) findings become single-line summaries.

> **Qualification (VEIL-002)**: "Zero information loss" refers to marker attribute and block
> content preservation, not semantic completeness for all downstream consumers. Boilerplate
> prose between markers is discarded for non-P1/P2 findings. If Runebinder requires detailed
> context from all P1/P2 block body text (not just marker attributes), this claim holds — but
> it has not been empirically verified against dedup quality metrics.

**Severity detection order**: Check the `interaction` marker attribute FIRST (canonical source), then fall back to ID suffix (`-Q`/`-N`) for backward compatibility with older Ash output formats.

```javascript
// Compresses a single finding based on its severity and interaction type.
//
// Compression tiers:
//   P1/P2 (preservePriorities): Full preservation — byte-identical to original
//   P3:                         Rune Trace code blocks truncated to truncateTraceLines
//   Q (question):               Rune Trace removed entirely (question text kept)
//   N (nit):                    Converted to single-line summary (when nitSummaryOnly=true)
//   Default:                    Full preservation (unknown types are safe)

function compressFinding(finding, config) {
  const { preservePriorities, truncateTraceLines, nitSummaryOnly } = config

  // P1/P2: Full preservation (zero information loss)
  if (preservePriorities.includes(finding.severity)) {
    return finding.fullBlock
  }

  // P3: Truncate Rune Trace code blocks
  if (finding.severity === 'P3') {
    return truncateRuneTrace(finding.fullBlock, truncateTraceLines)
  }

  // Q (Questions): Check interaction attribute FIRST, then ID suffix as fallback
  if (finding.interaction === 'question' || finding.id.endsWith('-Q')) {
    return truncateRuneTrace(finding.fullBlock, 0)  // Remove trace entirely
  }

  // N (Nits): 1-line summary only (when enabled)
  if (nitSummaryOnly && (finding.interaction === 'nit' || finding.id.endsWith('-N'))) {
    return convertToOneLiner(finding)
  }

  // Default: full preservation (unknown severity/interaction — safe fallback)
  return finding.fullBlock
}
```

## Trace Truncation: truncateRuneTrace()

Truncates ```` ``` ```` code blocks within **Rune Trace** sections. Used for P3 findings (partial truncation) and Q findings (full removal).

```javascript
// Truncates code blocks that appear in Rune Trace sections.
//
// maxLines=0:   Remove entire Rune Trace section (for Q findings)
// maxLines=3:   Keep first 3 lines + "# ... truncated ..." marker
// maxLines>=N:  Keep code blocks that are already <= N lines unchanged

function truncateRuneTrace(block, maxLines) {
  return block.replace(
    /(\*\*Rune Trace:\*\*\s*\n\s*```[^\n]*\n)([\s\S]*?)(```)/g,
    (match, open, code, close) => {
      if (maxLines === 0) return ''  // Remove trace entirely
      const lines = code.split('\n')
      if (lines.length <= maxLines) return match  // Already short enough
      return open + lines.slice(0, maxLines).join('\n') + '\n    # ... truncated ...\n' + close
    }
  )
}
```

## Nit Compression: convertToOneLiner()

Converts an N (nit) finding block to a single-line summary. Preserves the RUNE:FINDING markers for downstream nonce validation (SEC-010) and dedup.

```javascript
// Converts a nit finding to a minimal single-line representation.
//
// Output format contract (VEIL-006):
//   <!-- RUNE:FINDING ... -->
//   - [ ] **[PREFIX-NNN-N] Title** in `file:line` _(compressed)_
//   <!-- /RUNE:FINDING ... -->
//
// Format contract details:
//   - The RUNE:FINDING opening/closing markers are preserved byte-for-byte (required by SEC-010).
//   - The _(compressed)_ suffix is a stable marker that Runebinder can detect to identify
//     nit-compressed findings in the TOME (used for compression audit trail).
//   - Title extraction regex expects: **[ID] Title text** in `location`
//     This matches the canonical Ash nit output format from review-checklist.md.
//     If Ash format changes, this regex MUST be updated in sync.
//
// If the title pattern is not parseable, falls back to full preservation
// (safety over compression — never lose data silently).

function convertToOneLiner(finding) {
  // Extract title: **[ID] Title** in `file:line`
  const titleMatch = finding.fullBlock.match(/\*\*\[([^\]]+)\]\s*([^*]+)\*\*\s*in\s*`([^`]+)`/)
  if (titleMatch) {
    const [, id, title, location] = titleMatch
    return `${finding.marker}\n- [ ] **[${id}] ${title.trim()}** in \`${location}\` _(compressed)_\n${finding.closingMarker}`
  }
  return finding.fullBlock  // Fallback: keep original if title not parseable
}
```

## Section Extraction: extractSection()

Extracts a named `## ` section from markdown content. Returns the section header and body text up to the next `## ` section or end of file.

```javascript
// Extracts a ## section by heading text.
// Returns the section content (heading + body) or null if not found.
//
// Used for:
//   - "## Reviewer Assumptions" — preserved for Runebinder assumption analysis
//   - "## Summary" — preserved for TOME statistics

function extractSection(content, heading) {
  const headingEscaped = heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const pattern = new RegExp(
    `(${headingEscaped}\\n[\\s\\S]*?)(?=\\n## |$)`,
    'm'
  )
  const match = content.match(pattern)
  // Return contract: { found: boolean, content: string | null }
  //   found=false, content=null  → section heading not present in file at all
  //                                (older Ash prompt that never emitted this section)
  //   found=true,  content=""    → section heading is present but body is whitespace-only
  //                                (Ash explicitly emitted the section with no content;
  //                                 intentional — structured output, not incomplete processing)
  //   found=true,  content="..."→ normal non-empty section
  //
  // NOTE: The caller uses .filter(Boolean) on the return value, so both null and ""
  // are excluded from the condensed output — this is correct for assembly purposes.
  // However, metrics should distinguish these two cases to audit Ash compliance drift.
  // Callers that need the distinction should check the `found` flag rather than
  // testing content for truthiness.
  if (!match) return null          // Section not found (found=false)
  const body = match[1].trim()
  return body || null              // Empty section returns null (collapses with "not found" for output)
  // TODO(BACK-006): Return { found: true, content: body } to distinguish empty-but-present
  // from absent sections in metrics. Requires caller updates to destructure result.
}
```

## Header Extraction: extractHeader()

Extracts the header portion of an Ash output file — everything before the first `## ` section. This preserves Ash identity (name, role, timestamp) so Runebinder can correctly attribute findings in the TOME.

```javascript
// Extracts lines before the first ## section.
// Preserves Ash identity for Runebinder attribution.
//
// Fallback: If no ## section exists (unusual), return first 500 chars
// to prevent unbounded output.

function extractHeader(content) {
  const firstSection = content.indexOf('\n## ')
  if (firstSection === -1) return content.slice(0, 500)  // Fallback: first 500 chars
  return content.slice(0, firstSection).trim()
}
```

## Compression Report: writeCompressionReport()

Writes a single-pass metrics summary for observability. The report lives alongside condensed files in `condensed/` and is cleaned up with the parent review directory.

> **Scope note (QUAL-004)**: The structured per-Ash table is provided for debugging convenience.
> No current Ash or Runebinder code reads this report programmatically — echo persistence
> integration is future work. If observability is added later, prefer structured JSON emission
> over parsing this markdown table.

```javascript
// Writes compression metrics to _compression-report.md.
// Format is both human-readable and parseable for echo persistence.
//
// The report lives in condensed/ alongside the compressed files and is
// cleaned up with the parent review directory (no special cleanup needed).

function writeCompressionReport(path, perAshMetrics, totals) {
  const overallRatio = (totals.combinedCondensed / totals.combinedOriginal * 100).toFixed(1)
  const savings = totals.combinedOriginal - totals.combinedCondensed
  const reductionPct = (100 - totals.combinedCondensed / totals.combinedOriginal * 100).toFixed(1)

  const report = `# Pre-Aggregation Compression Report

**Threshold**: ${totals.threshold} bytes
**Combined original**: ${totals.combinedOriginal} bytes
**Combined condensed**: ${totals.combinedCondensed} bytes
**Overall ratio**: ${overallRatio}%
**Savings**: ${savings} bytes (${reductionPct}% reduction)

## Per-Ash Breakdown

| Ash | Original | Condensed | Findings | Ratio |
|-----|----------|-----------|----------|-------|
${perAshMetrics.map(m =>
  \`| \${m.ash} | \${m.originalBytes}B | \${m.condensedBytes}B | \${m.findingCount} | \${m.ratio}% |\`
).join('\\n')}
`
  Write(path, report)
}
```

## Edge Cases

### EC-1: Zero findings in Ash output

**Scenario**: An Ash produces output with no RUNE:FINDING markers (clean review or all unverified).
**Handling**: `extractFindingBlocks()` returns empty array. Condensed file contains only header + Reviewer Assumptions + Summary. Runebinder handles clean Ash outputs normally.

### EC-2: Malformed RUNE:FINDING markers

**Scenario**: Closing marker missing, mismatched ID, or marker attribute validation failure (invalid id format, path traversal in file, missing nonce, non-numeric line).
**Handling**: `extractFindingBlocks()` skips unclosed markers and markers that fail attribute validation. The compression report documents the skipped count. Original file remains in the parent directory.
**Fallback**: If `extractFindingBlocks()` extracts 0 findings from a file that appears to have markers (regex detects `<!-- RUNE:FINDING` but no valid blocks pass validation), skip compression for that file — copy original to `condensed/` to prevent data loss.

> **Error handling note (BACK-001)**: The fallback copy (original → `condensed/`) must itself
> be protected against write failure. If `Write(condensedPath, originalContent)` throws (disk
> full, permissions), the condensed directory will be incomplete and Runebinder may silently
> mix condensed + original inputs. Implementation should catch write errors here and log to
> the compression report with a COPY_FAILED status so Runebinder can be informed that this
> Ash file's condensed copy is unavailable.

### EC-3: Reviewer Assumptions section missing

**Scenario**: An Ash does not emit `## Reviewer Assumptions` (older prompt or custom Ash).
**Handling**: `extractSection()` returns `null`. Condensed file omits the section. Runebinder already handles missing assumption sections (records as "partial (no assumptions)" in Coverage Gaps).

### EC-4: Condensed file larger than original

**Scenario**: Very short Ash output where header + finding blocks approximate the original size (minimal boilerplate).
**Handling**: This is correct — small files have little to compress. Per-Ash metrics in the compression report show ~100% ratio. Overall savings come from larger Ash outputs in the batch.

## Multi-Wave Support (Planned — Not Yet Released)

> **Note**: Multi-wave review is not yet implemented or tested in production as of v1.116.0.
> This section documents the intended future architecture. Do not rely on this behavior
> until it is released and validated. (QUAL-003)

When `depth=deep` activates multi-wave review (Wave 1 + Wave 2+), Phase 5.0 is designed to run **per wave** before each wave's Runebinder pass. Each wave would have its own `output_dir`, so `condensed/` would be created per wave with no cross-wave interaction.

```
Wave 1 Ashes → output_dir_w1/ → Phase 5.0 → condensed/ → Runebinder (TOME-w1.md)
Wave 2 Ashes → output_dir_w2/ → Phase 5.0 → condensed/ → Runebinder (TOME-w2.md)
Merge → Final TOME.md
```

The threshold check and compression are designed to be independent per wave. A wave with small output (under threshold) would skip pre-aggregation even if another wave triggered it.

## Performance Budget

| Scenario | Operations | Expected Time |
|----------|-----------|---------------|
| Under threshold (fast path) | `wc -c` per Ash file + 1 comparison | ~5-10ms for 7 files |
| Over threshold (full compression) | Read + regex extract + write per Ash file | ~50-100ms for 7 files |

**Breakdown (over threshold)**:
- File I/O dominates (~5-10ms per file for read + write)
- Regex extraction on ~5KB text is sub-millisecond per file
- No model calls — zero LLM cost
- Total for 7 Ashes: well under 100ms

**Runebinder savings**:
- 40-60% less text to read = fewer Read tool calls _(estimate — not yet empirically measured; actual ratio depends on finding distribution, see VEIL-003/VEIL-004)_
- Smaller context window = faster TOME generation
- Designed to reduce stalling on reviews with 5-8 Ashes (>30KB combined) — empirical timeout correlation pending

> **Assumption notes (VEIL-003, VEIL-004)**:
> - The 40-60% compression range is a design estimate. Actual ratio depends heavily on the
>   distribution of finding severities in each review. Reviews dominated by P1/P2 findings
>   (which are fully preserved) will see minimal compression. The estimate assumes P3/N
>   findings make up a significant portion of combined output — this has not been measured
>   across production reviews.
> - To calibrate: collect histogram of per-severity finding counts across 20+ production
>   reviews and correlate with actual compression report ratios.

> **Bash dependency (VEIL-003)**: Error recovery paths (fallback to original on write failure,
> `mkdir -p` for condensed/ directory) assume Bash is available in the execution environment.
> This algorithm runs at Tarnished level where Bash is always available. If ported to a
> non-Bash environment, these error paths require adaptation.

## References

- [review-checklist.md](agent-patterns/review-checklist.md) — Canonical RUNE:FINDING marker format and attribute spec
- [dedup-runes.md](dedup-runes.md) — Deduplication hierarchy (applied by Runebinder AFTER pre-aggregation)
- [orchestration-phases.md](orchestration-phases.md) — Phase 5.0 integration point and Phase 5 condensed input redirect
- [monitor-utility.md](monitor-utility.md) — Phase 4 monitoring that precedes pre-aggregation
