# Phase 3: Risk Context Injection (Goldmask Enhancement)

Injects Goldmask risk context into each mend-fixer's prompt when data is available from Phase 0.5. Three context sections: risk tiers, wisdom advisories, and blast-radius warnings.

**Inputs**: `parsedRiskMap` (from Phase 0.5), `goldmaskData` (from Phase 0.5), `fixers` (fixer assignment list)
**Outputs**: Enriched fixer prompts with `## Risk Context (Goldmask)` section appended
**Preconditions**: Phase 0.5 Goldmask data discovery complete, fixer assignments determined

**Load reference**: [risk-context-template.md](../../goldmask/references/risk-context-template.md)

```javascript
// For each mend-fixer, inject Goldmask context for their assigned files
// v3.x: goldmask.mend.inject_context is hardcoded true (see ../../../references/v3-defaults.md goldmask).

if (parsedRiskMap || goldmaskData?.wisdomReport || goldmaskData?.goldmaskMd) {
  for (const fixer of fixers) {
    let goldmaskContext = ""

    // Section 1: Risk tiers for assigned files (from risk-context-template.md)
    if (parsedRiskMap) {
      const riskEntries = fixer.assignedFiles
        .map(f => parsedRiskMap.files?.find(r => r.path === f))
        .filter(Boolean)

      if (riskEntries.length > 0) {
        // Render Section 1 (File Risk Tiers) from risk-context-template.md
        goldmaskContext += renderRiskContextTemplate(riskEntries, fixer.assignedFiles)
      }
    }

    // Section 2: Wisdom advisories for assigned files
    if (goldmaskData?.wisdomReport) {
      // filterWisdomForFiles(wisdomReport: string, files: string[]) => { file: string, intent: string, cautionScore: number, advisory: string }[]
      // Input: wisdomReport — raw markdown string from GOLDMASK wisdom layer (contains WISDOM-NNN: heading blocks)
      //        files — array of root-relative POSIX paths for the fixer's assigned files
      // Output: array of advisory objects matching those paths, one entry per matched WISDOM-NNN block
      const advisories = filterWisdomForFiles(goldmaskData.wisdomReport, fixer.assignedFiles)
      // filterWisdomForFiles: parse WISDOM-NNN headings, match file paths,
      // return { file, intent, cautionScore, advisory }[]
      if (advisories.length > 0) {
        goldmaskContext += "\n\n### Caution Zones\n\n"
        for (const adv of advisories) {
          // SEC-001: Sanitize wisdom advisory content before interpolation into fixer prompts
          // to prevent prompt injection via adversarial advisory text.
          const safeAdvisory = sanitizeFindingText(adv.advisory)
          goldmaskContext += `- **\`${adv.file}\`** -- ${adv.intent} intent (caution: ${adv.cautionScore}). ${safeAdvisory}\n`
        }
        goldmaskContext += "\n**IMPORTANT**: Preserve the original design intent of these code sections. Your changes must not break the defensive, constraint, or compatibility behavior described above.\n"
      }
    }

    // Section 3: Blast-radius warnings for assigned files
    if (goldmaskData?.goldmaskMd) {
      // extractMustChangeFiles contract (BACK-007): returns root-relative POSIX paths,
      // no ./ prefix, no trailing slash. Filter path traversal before use.
      const mustChangeFiles = extractMustChangeFiles(goldmaskData.goldmaskMd)
        .filter(f => !f.includes('..'))
      const affectedAssigned = fixer.assignedFiles.filter(f => mustChangeFiles.includes(f))
      if (affectedAssigned.length > 0) {
        goldmaskContext += `\n\n### Blast Radius Warning\n\nThese files have WIDE blast radius: ${affectedAssigned.map(f => '\`' + f + '\`').join(', ')}. Changes here affect downstream dependencies. Test thoroughly.\n`
      }
    }

    // Append to fixer prompt (only if non-empty)
    if (goldmaskContext.trim()) {
      fixer.prompt += "\n\n## Risk Context (Goldmask)\n" + goldmaskContext
    }
  }
}
```

**Skip condition**: When no Goldmask data exists, fixer prompts remain unchanged. (v3.x: injection is unconditional when data is present.)

## Helper Functions

Implement inline — no shared module:

- `renderRiskContextTemplate(riskEntries, files)` — renders Section 1 table from risk-context-template.md. Returns empty string when no entries.
- `filterWisdomForFiles(wisdomReport, files)` — parses `WISDOM-NNN:` headings, returns `{ file, intent, cautionScore, advisory }[]` for matching files.
- `extractMustChangeFiles(goldmaskMd)` — parses "MUST-CHANGE" classification from GOLDMASK.md findings table. Returns root-relative POSIX paths without `./` prefix or trailing slash. Strips `../` for path traversal safety.
- `sanitizeFindingText(text)` — strips HTML comments, code fences, image syntax, zero-width chars, angle brackets; caps at 500 chars. Shared with CDX-010 finding sanitization. Apply to all wisdom advisory content before prompt interpolation (SEC-001).
