# Phase 1.7: Codex Section Validation

Validates enrichment coverage cross-model after Lore Layer risk scoring. Identifies plan sections that reference high-risk files but have no Forge Gaze agent match.

**Inputs**: `sections` (parsed plan sections), `riskMap` (from Phase 1.5), `talisman` (config), `timestamp`
**Outputs**: `forceIncludeList` (section titles for Phase 2), `tmp/forge/{timestamp}/codex-section-validation.md`
**Preconditions**: Phase 1.5 (Lore Layer) complete, sections parsed

```javascript
// Phase 1.7: Codex Section Validation
// 4-condition detection gate (canonical pattern)
const codexAvailable = detectCodex()
const codexDisabled = talisman?.codex?.disabled === true
const sectionValidEnabled = talisman?.codex?.section_validation?.enabled !== false
const workflowIncluded = (talisman?.codex?.workflows ?? []).includes("forge")

let forceIncludeList = []  // Sections to force-include in Phase 2

if (codexAvailable && !codexDisabled && sectionValidEnabled && workflowIncluded) {
  const { timeout, reasoning, model: codexModel } = resolveCodexConfig(talisman, "section_validation", {
    timeout: 300, reasoning: "medium"  // medium — simple binary coverage check
  })

  // Skip if plan is small (few sections = all will be covered)
  if (sections.length > 5) {
    const nonce = Bash(`openssl rand -hex 16`).trim()
    const promptTmpFile = `tmp/forge/${timestamp}/.codex-prompt-section-validate.tmp`
    try {
      const sectionSummary = sections.map(s => `## ${s.title}\nFiles: ${extractFileRefs(s.content).join(", ") || "none"}`).join("\n\n")
      const riskMapSummary = riskMap ? riskMap.substring(0, 10000) : "No risk data available"
      const sanitizedSections = sanitizePlanContent(sectionSummary)
      const sanitizedRisk = sanitizePlanContent(riskMapSummary)
      const promptContent = `SYSTEM: You are a cross-model enrichment coverage validator.

Validate enrichment coverage: Which plan sections reference high-risk files but have no
Forge Gaze agent match? Which sections lack file references entirely?

=== PLAN SECTIONS ===
<<<NONCE_${nonce}>>>
${sanitizedSections}
<<<END_NONCE_${nonce}>>>

=== RISK MAP ===
<<<NONCE_${nonce}>>>
${sanitizedRisk}
<<<END_NONCE_${nonce}>>>

Output a JSON array of section titles that need force-inclusion in enrichment:
["Section Title 1", "Section Title 2"]

Only include sections that reference CRITICAL or HIGH risk files but would otherwise
be missed by topic-based agent matching. Output [] if all sections are covered.
Base assessment on actual file references, not assumptions.`

      Write(promptTmpFile, promptContent)
      const result = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${reasoning}" -t ${timeout} -j -g "${promptTmpFile}"`)
      const classified = classifyCodexError(result)

      if (classified === "SUCCESS") {
        try {
          // Parse force-include list from Codex output
          const jsonMatch = result.stdout.match(/\[.*\]/s)
          if (jsonMatch) forceIncludeList = JSON.parse(jsonMatch[0])
        } catch (e) { /* malformed JSON — proceed without force-include */ }
      }
      Write(`tmp/forge/${timestamp}/codex-section-validation.md`, formatSectionValidationReport(classified, result, forceIncludeList))
    } finally {
      Bash(`rm -f "${promptTmpFile}"`)  // Guaranteed cleanup
    }
  } else {
    Write(`tmp/forge/${timestamp}/codex-section-validation.md`, "# Codex Section Validation\n\nSkipped: plan_sections <= 5")
  }
} else {
  const skipReason = !codexAvailable ? "codex not available"
    : codexDisabled ? "codex.disabled=true"
    : !sectionValidEnabled ? "codex.section_validation.enabled=false"
    : "forge not in codex.workflows"
  Write(`tmp/forge/${timestamp}/codex-section-validation.md`, `# Codex Section Validation\n\nSkipped: ${skipReason}`)
}
```
