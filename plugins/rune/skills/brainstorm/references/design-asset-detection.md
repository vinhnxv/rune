# Phase 3.5: Design Asset Detection (conditional, all modes)

Reuse existing Figma URL detection pattern:

```javascript
// SYNC: figma-url-pattern — shared with devise SKILL.md
const FIGMA_URL_PATTERN = /https?:\/\/[^\s]*figma\.com\/[^\s]+/g
const DESIGN_KEYWORD_PATTERN = /\b(figma|design|mockup|wireframe|prototype|ui\s*kit|design\s*system|style\s*guide|component\s*library)\b/i

// Also scan round transcripts for Figma URLs shared during discussion
const roundFiles = Glob(`tmp/brainstorm-${timestamp}/rounds/*.md`)
const roundContent = roundFiles.map(f => Read(f)).join(" ")
const searchText = featureDescription + " " + selectedApproach + " " + roundContent

const figmaUrls = searchText.match(FIGMA_URL_PATTERN) || []

// SEC: SSRF defense — sanitize URLs extracted from user-provided round transcripts.
// Round transcripts contain user input, so extracted URLs must be validated.
// Reuses the same SSRF blocklist as devise research-phase.md (URL Sanitization section).
const SSRF_BLOCKLIST = [
  /^https?:\/\/localhost/i,
  /^https?:\/\/127\./,
  /^https?:\/\/0\.0\.0\.0/,
  /^https?:\/\/10\./,
  /^https?:\/\/192\.168\./,
  /^https?:\/\/172\.(1[6-9]|2[0-9]|3[01])\./,
  /^https?:\/\/169\.254\./,
  /^https?:\/\/\[::1\]/,
  /^https?:\/\/\[::ffff:127\./,
  /^https?:\/\/[^/]*\.(local|internal|corp|test|example|invalid|localhost)(\/|$)/i,
]
// SSRF: domain-anchored filter (replaces bypassable url.includes("figma.com"))
// SYNC: figma-domain-pattern — shared with devise/references/design-signal-detection.md
const FIGMA_DOMAIN_PATTERN = /^https:\/\/(www\.)?figma\.com\//
const safeFigmaUrls = figmaUrls
  .map(url => url.replace(/[\r\n)>\]|"]/g, ''))  // Strip injection chars
  .filter(url => FIGMA_DOMAIN_PATTERN.test(url))   // Domain-anchored whitelist
  .filter(url => !SSRF_BLOCKLIST.some(re => re.test(url)))  // Keep blocklist as defense-in-depth
  .map(url => url.slice(0, 2048))  // Cap per-URL length to prevent token bloat
const figmaUrl = safeFigmaUrls.length > 0 ? safeFigmaUrls[0] : null
const hasDesignKeywords = DESIGN_KEYWORD_PATTERN.test(searchText)

if (figmaUrl) {
  design_sync_candidate = true

  // Persist design URLs to workspace metadata for devise handoff
  const metaPath = `tmp/brainstorm-${timestamp}/workspace-meta.json`
  let existingMeta = {}
  try { existingMeta = JSON.parse(Read(metaPath) || '{}') } catch (e) { /* start fresh */ }
  existingMeta.design_urls = safeFigmaUrls
  existingMeta.design_url_primary = figmaUrl
  existingMeta.design_sync_candidate = true
  existingMeta.design_keywords_detected = hasDesignKeywords
  const tmpMeta = metaPath + '.tmp'
  Write(tmpMeta, JSON.stringify(existingMeta, null, 2))
  Bash(`mv "${tmpMeta}" "${metaPath}"`)

  // Append Design Assets section to brainstorm context

  // Component preview: call figma_list_components when design_sync enabled
  const miscConfig = readTalismanSection("misc") || {}
  const designSyncEnabled = miscConfig.design_sync?.enabled === true

  if (designSyncEnabled) {
    try {
      // SSRF defense: figmaUrl already validated by safeFigmaUrls filter above (lines 266-280)
      const components = mcp__plugin_rune_figma_to_react__figma_list_components({ url: figmaUrl })
      const componentNames = (components || []).slice(0, 10).map(c => c.name)
      if (componentNames.length > 0) {
        const totalCount = (components || []).length
        const previewList = componentNames.join(", ")
        const suffix = totalCount > 10 ? ` (and ${totalCount - 10} more)` : ""
        // Present component preview in brainstorm output
        log(`Found ${totalCount} components: ${previewList}${suffix}`)
        // Append to brainstorm context for advisor rounds
        designPreviewBlock = `\n### Figma Component Preview\nFound ${totalCount} components: ${previewList}${suffix}\nFull design pipeline available via /rune:devise.`
        // designPreviewBlock injection points:
        // 1. Appended to round context for advisors in Phase 2 (featureDescription += designPreviewBlock)
        // 2. Included in brainstorm-decisions.md output (Phase 6 capture)
      }
    } catch (e) {
      // Non-blocking: preview failure does not block brainstorm
      warn(`Figma component preview unavailable: ${e.message}. URL saved for /rune:devise.`)
    }
  }
} else if (hasDesignKeywords) {
  AskUserQuestion({ question: "Design keywords detected — do you have a Figma file URL to include?" })
}
```
