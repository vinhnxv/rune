# Goldmask Quick Check (Deterministic)

Deterministic blast-radius verification comparing mend output against Goldmask predictions. No agents — pure set comparison of MUST-CHANGE files vs actually modified files.

**Inputs**: `talisman` (config object), `goldmaskData` (discovery result with `goldmaskMd`), `allFindings` (finding[]), `preMendSha` (string), `mendOutputDir` (string), `id` (string)
**Outputs**: `tmp/mend/{id}/goldmask-quick-check.md`, `quickCheckResults` object for resolution report
**Preconditions**: Phase 0.5 ran (goldmaskData may be null), all fixes applied and verified, preMendSha captured at Phase 2

## Skip Conditions

| Condition | Effect |
|-----------|--------|
| No `goldmaskData.goldmaskMd` found | Skip entirely |
| No MUST-CHANGE files overlap with TOME scope | Skip entirely |

## Algorithm

```javascript
// Skip conditions
const quickCheckEnabled = talisman?.goldmask?.mend?.quick_check !== false  // default: true
const goldmaskEnabled = talisman?.goldmask?.enabled !== false

if (!goldmaskEnabled || !quickCheckEnabled) {
  warn("Phase 5.95: Goldmask Quick Check disabled (talisman kill switch)")
} else if (!goldmaskData?.goldmaskMd) {
  warn("Phase 5.95: No GOLDMASK.md found — skipping quick check")
} else {
  // Extract MUST-CHANGE files from GOLDMASK.md
  // Parse "MUST-CHANGE" classification from findings table in Impact Clusters section
  // normalize: canonical root-relative POSIX path (no ./ prefix, no trailing slash, lowercase)
  const normalize = f => f.replace(/^\.\//, '').replace(/\/$/, '').toLowerCase()
  const mustChangeFiles = extractMustChangeFiles(goldmaskData.goldmaskMd)
    .filter(f => !f.includes('..'))  // Strip path traversal
    .map(normalize)

  // Intersect with TOME scope to avoid false positive "untouched" warnings
  // (P0 concern: mustChangeFiles may reference files not in this TOME's scope)
  const tomeFiles = allFindings.map(f => normalize(f.file))
  const scopedMustChange = mustChangeFiles.filter(f => tomeFiles.includes(f))

  if (scopedMustChange.length === 0) {
    warn("Phase 5.95: No MUST-CHANGE files overlap with TOME scope — skipping")
  } else {
    // Get files actually modified by mend fixers (working tree + staged, not just commits)
    // Derive from git diff against preMendSha (captured at Phase 2)
    const mendedFilesRaw = Bash(`git diff --name-only ${preMendSha} 2>/dev/null`)
    // normalize: canonical root-relative POSIX path (no ./ prefix, no trailing slash, lowercase)
    const mendedFiles = mendedFilesRaw.trim().split('\n').filter(Boolean).map(normalize)

    // Check: did mend touch MUST-CHANGE files?
    const untouchedMustChange = scopedMustChange.filter(f => !mendedFiles.includes(f))
    const unexpectedTouches = mendedFiles.filter(f =>
      !scopedMustChange.includes(f) && !tomeFiles.includes(f)
    )

    // Build quick check report
    let quickCheckReport = `# Goldmask Quick Check -- rune-mend-${id}\n\n`
    quickCheckReport += `Generated: ${new Date().toISOString()}\n\n`

    // BACK-002: This gate is intentionally advisory-only (warn) — it does NOT halt the pipeline.
    // GOLDMASK predictions are probabilistic; blocking on mismatches would cause false failures.
    // Warnings are surfaced in the resolution report for human review.
    if (untouchedMustChange.length > 0) {
      warn(`Phase 5.95: ${untouchedMustChange.length} MUST-CHANGE files not modified by mend`)
      quickCheckReport += `## Untouched MUST-CHANGE Files\n\n`
      quickCheckReport += `${untouchedMustChange.length} files predicted as MUST-CHANGE were not modified:\n\n`
      for (const f of untouchedMustChange) {
        quickCheckReport += `- \`${f}\` (predicted MUST-CHANGE but not fixed)\n`
      }
      quickCheckReport += `\n`
    }

    if (unexpectedTouches.length > 0) {
      warn(`Phase 5.95: ${unexpectedTouches.length} unexpected file modifications`)
      quickCheckReport += `## Unexpected Modifications\n\n`
      quickCheckReport += `${unexpectedTouches.length} files modified that were NOT in TOME or MUST-CHANGE:\n\n`
      for (const f of unexpectedTouches) {
        quickCheckReport += `- \`${f}\` (unexpected modification)\n`
      }
      quickCheckReport += `\n`
    }

    if (untouchedMustChange.length === 0 && unexpectedTouches.length === 0) {
      quickCheckReport += `## Result: CLEAN\n\nAll MUST-CHANGE files in scope were addressed. No unexpected modifications.\n`
    }

    quickCheckReport += `\n## Summary\n\n`
    quickCheckReport += `- MUST-CHANGE files in scope: ${scopedMustChange.length}\n`
    quickCheckReport += `- Modified by mend: ${scopedMustChange.length - untouchedMustChange.length}\n`
    quickCheckReport += `- Untouched: ${untouchedMustChange.length}\n`
    quickCheckReport += `- Unexpected modifications: ${unexpectedTouches.length}\n`

    Write(`${mendOutputDir}/goldmask-quick-check.md`, quickCheckReport)

    // Store results for Phase 6 resolution report
    quickCheckResults = {
      scopedMustChange,
      untouchedMustChange,
      unexpectedTouches,
      reportPath: `${mendOutputDir}/goldmask-quick-check.md`
    }
  }
}
```

## Performance

~1-5s (git diff + file reads + set operations). No agents spawned.

## Output Contract

`quickCheckResults` object (or `undefined` if skipped):

```typescript
{
  scopedMustChange: string[],     // MUST-CHANGE files that overlap with TOME scope
  untouchedMustChange: string[],  // Subset of scopedMustChange not modified by mend
  unexpectedTouches: string[],    // Files modified that were NOT in TOME or MUST-CHANGE
  reportPath: string              // Path to the quick check report file
}
```
