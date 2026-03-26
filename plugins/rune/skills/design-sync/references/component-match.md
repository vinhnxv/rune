# Phase 1.3: Component Match

Only runs when `builderProfile.capabilities.search` is available. Zero overhead otherwise.

```
// Step 1: Read builder profile (written by discoverUIBuilder())
builderProfile = null
try:
  builderProfile = Read("{workDir}/../builder-profile.yaml")
catch:
  // No builder — skip Phase 1.3 entirely, proceed to Phase 1.5
  warn("No UI builder detected. Using figma-to-react reference output (~50-60% component match) or VSM-only path. To enable enhanced component matching (85-95%), configure a builder MCP — see docs/guides/ui-builder-protocol.en.md")
  goto Phase1_5

if NOT builderProfile?.capabilities?.search:
  // Builder exists but has no search capability — skip
  goto Phase1_5

// Step 2: Read reference code produced in Phase 1 by figma_to_react() (if available)
// NOTE: figma_to_react() is a Rune MCP-only capability. When only Framelink is available,
// referenceCode will be null and component matching uses VSM region names/types directly.
referenceCodePath = "{workDir}/figma-reference.tsx"
referenceCode = null
try:
  referenceCode = Read(referenceCodePath)
catch:
  // No reference code (Rune MCP unavailable or figma_to_react failed)
  // Fallback: use VSM region names + types as search queries instead
  referenceCode = null

// Step 3: Read VSM files to extract region list
vsmFiles = Glob("{workDir}/vsm/*.md")
enrichedVsm = {}  // will be written as enriched-vsm.json

// Phase-level circuit breaker: if 3 consecutive MCP calls fail, skip remaining
consecutiveFailures = 0
CIRCUIT_BREAKER_THRESHOLD = 3
CALL_TIMEOUT_MS = 10000  // 10s per MCP call
PHASE_TIMEOUT_MS = 60000 // 60s total for this phase
phaseStartTime = Date.now()

// Step 4: For each VSM region, search builder library for real components
for each vsm in vsmFiles:
  if (Date.now() - phaseStartTime) > PHASE_TIMEOUT_MS:
    warn("Phase 1.3 timeout ({PHASE_TIMEOUT_MS}ms) — using partial results")
    break

  vsmContent = Read(vsm.path)
  regions = parseVsmRegions(vsmContent)  // extract top-level regions from VSM

  const skippedRegions = []  // Track regions skipped by circuit breaker

  for each region in regions:
    if consecutiveFailures >= CIRCUIT_BREAKER_THRESHOLD:
      // Track remaining regions as skipped for downstream observability
      const remaining = regions.slice(regions.indexOf(region))
      skippedRegions.push(...remaining.map(r => ({ name: r.name, reason: 'circuit_breaker' })))
      warn("Phase 1.3 circuit breaker: {consecutiveFailures} consecutive MCP failures — skipping {remaining.length} remaining regions")
      break

    // Step 4a: Build search query from region + reference code visual intent
    // Reference code is analyzed here as a visual intent source (not applied as code)
    searchQuery = buildSearchQuery(region, referenceCode)
    // e.g., { type: "sidebar", layout: "vertical" } + "<nav className='w-64'>" →
    //        "sidebar navigation vertical"

    // Step 4b: Call builder search MCP tool (agent-mediated MCP call)
    // The spawned worker has MCP access to the builder's server
    // Per-call timeout: 10s; consecutive failure tracking: circuit breaker at 3
    try:
      results = callMCPTool(
        builderProfile.capabilities.search,
        { query: searchQuery, limit: 5 },
        timeout: CALL_TIMEOUT_MS
      )
      consecutiveFailures = 0  // reset on success

      // Step 4c: Score results against region requirements
      const lowThreshold = config?.design_sync?.trust_hierarchy?.low_confidence_threshold ?? 0.60
      const highThreshold = config?.design_sync?.trust_hierarchy?.high_confidence_threshold ?? 0.80
      matches = scoreMatches(results, region, threshold: lowThreshold)
      region.component_matches = matches.map(m => ({
        name: m.name,
        score: m.score,
        confidence: m.score >= highThreshold ? 'high' : m.score >= lowThreshold ? 'medium' : 'low'
      }))

      // Step 4d: If match found, get full component source for worker context
      if matches.length > 0 AND builderProfile.capabilities.details:
        try:
          region.component_details = callMCPTool(
            builderProfile.capabilities.details,
            { name: matches[0].name },
            timeout: CALL_TIMEOUT_MS
          )
        catch:
          // Details call failed — matches still useful without source
          consecutiveFailures++

    catch:
      // Search call failed — mark region as unmatched, increment failure count
      region.component_matches = []
      consecutiveFailures++

  // Multi-URL namespace: use URL-prefixed keys to prevent collisions (e.g., "url-1/Button.md")
  const vsmKey = figmaUrls.length > 1 ? `url-${urlIndex}/${vsm.name}` : vsm.name
  enrichedVsm[vsmKey] = regions

// Step 5: Check for page-level template match (requires PRO tier or OAuth, optional)
// Only attempt when builder reports templates capability AND access tier is 'pro'
// Access tier is resolved by resolveMCPIntegrations() — 'pro' when access_token_env is set or OAuth authenticated
if builderProfile.capabilities.templates AND NOT flags.skipTemplates AND builderProfile.accessTier === 'pro':
  try:
    templates = callMCPTool(builderProfile.capabilities.templates, {}, timeout: CALL_TIMEOUT_MS)
    enrichedVsm._page_template = matchPageTemplate(templates, Object.values(enrichedVsm).flat())
  catch:
    // Template check failed — not fatal

## Consuming Page Template Matches

When `enrichedVsm._page_template` is set (Step 5 output), downstream consumers should:
1. Use the template as a page-level starting skeleton
2. Fill component-level customizations per-region from the component matches
3. Template provides layout structure; component matches provide widget-level detail
4. If template score < 0.80, ignore _page_template and use per-component assembly

PRO tier gating: _page_template is only populated when accessTier === "pro"

// Step 6: Write enriched VSM (includes skipped regions metadata for observability)
Bash("mkdir -p {workDir}/vsm")
if (skippedRegions.length > 0) {
  enrichedVsm._metadata = enrichedVsm._metadata ?? {}
  enrichedVsm._metadata.skipped_regions = skippedRegions
  enrichedVsm._metadata.circuit_breaker_fired = true
  enrichedVsm._metadata.skipped_count = skippedRegions.length
  warn(`Phase 1.3: ${skippedRegions.length} regions skipped due to circuit breaker — workers will receive incomplete enrichment`)
}
Write("{workDir}/vsm/enriched-vsm.json", JSON.stringify(enrichedVsm, null, 2))

// Step 7: Update state
updateState({ phase: "component-match", builder_skill: builderProfile.builder_skill,
              matched_regions: countMatches(enrichedVsm) })
```

**Phase 1.3 notes**:
- `callMCPTool()` = agent-mediated MCP invocation (the spawned worker has the builder MCP configured)
- Circuit breaker prevents hanging on a disconnected MCP server (3 consecutive failures → skip)
- Phase timeout (60s) prevents blocking the full pipeline on slow library searches
- Unmatched regions fall back to Tailwind-based implementation in Phase 2 (graceful degradation)
- `buildSearchQuery()` uses both the VSM region type and the reference code's structural hints
