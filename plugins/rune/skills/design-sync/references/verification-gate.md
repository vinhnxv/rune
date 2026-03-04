# Cross-Verification Gate

## Purpose

Validates that VSM regions are covered by design extraction output before proceeding
to implementation. Prevents workers from implementing with incomplete data.

## Algorithm

After Phase 1 extraction (VSM created) and before Phase 1.5 (user confirmation):

```
vsm_regions = parseVsmRegions(vsm_files)
extraction_regions = parseExtractionOutput(reference_code, design_context)

unmatched = vsm_regions.filter(r => !extraction_regions.covers(r))
mismatch_pct = (unmatched.length / vsm_regions.length) * 100
```

## Verdicts

| Mismatch % | Verdict | Action |
|------------|---------|--------|
| <= warn_threshold (default 20%) | **PASS** | Proceed to implementation |
| > warn_threshold and <= block_threshold | **WARN** | Show gap summary, user decides: proceed / pause / manual extraction |
| > block_threshold (default 40%) | **BLOCK** | Stop — try smaller Figma node, break into parts, or manual extraction |

**Boundary rule**: Code uses strict `>` comparisons. A mismatch exactly at the threshold gets the lower verdict (e.g., exactly 40% = WARN, not BLOCK). Mismatch is a float (0.0-100.0).

## Configurable Thresholds

```yaml
# talisman.yml
design_sync:
  verification_gate:
    warn_threshold: 20     # % mismatch to trigger WARN (default: 20)
    block_threshold: 40    # % mismatch to trigger BLOCK (default: 40)
    enabled: true          # Master toggle (default: true)
```

## WARN Output Format

```
Warning: VERIFICATION GATE: WARN ({mismatch_pct}% regions unmatched)

Matched: {matched_count}/{total_count} regions
Unmatched regions:
| # | Region Name | Category | Priority | Suggested Action |
|---|-------------|----------|----------|-----------------|
| 1 | Floating Badge | overlay | P2 | Manual extraction |
| 2 | Footer Links | footer | P3 | Search UntitledUI "footer navigation" |

Options:
1. Proceed with matched regions (unmatched -> fallback to Tailwind)
2. Pause and manually extract missing regions
3. Try a smaller Figma node (less complexity)
```

## BLOCK Output Format

```
Error: VERIFICATION GATE: BLOCK ({mismatch_pct}% regions unmatched)

Only {matched_count}/{total_count} regions were successfully extracted.
This is below the minimum threshold for reliable implementation.

Recommended actions:
1. Break the design into smaller Figma nodes (select specific frames)
2. Manually extract missing regions using the template below
3. Check Figma MCP connectivity (some nodes may have failed silently)
```

## Integration Points

- **design-sync Phase 1.4**: Run gate BEFORE user confirmation AskUserQuestion
- **arc Phase 3**: Run gate after extraction, before VSM collection.
  WARN -> log + proceed. BLOCK -> set phase status "needs_attention" + continue pipeline (non-blocking in arc)
- **design-sync standalone**: WARN -> AskUserQuestion. BLOCK -> AskUserQuestion + STOP option.

## Source Tracking

Each region in the element inventory MUST have a Source column:

| Source | Meaning |
|--------|---------|
| Code | Extracted from `get_design_context()` or `figma_to_react()` |
| Visual | Identified from screenshot VSM analysis only |
| Both | Confirmed by both code extraction and visual analysis |
| Manual | Added by user during WARN/BLOCK resolution |
