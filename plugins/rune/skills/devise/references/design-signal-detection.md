# Design Signal Detection & Inventory Agent

## Design Signal Detection (Phase 0 pre-step)

Before brainstorm questions, scan the user description for Figma URLs. When detected, enables design-aware planning throughout the pipeline. With `--quick` (Phase 0 skipped), a fallback applies `FIGMA_URL_PATTERN` to the feature description before Phase 1 agents spawn.

```javascript
// SYNC: figma-url-pattern — shared with brainstorm/SKILL.md Phase 3.5
const FIGMA_URL_PATTERN = /https?:\/\/[^\s]*figma\.com\/[^\s]+/g
const DESIGN_KEYWORD_PATTERN = /\b(figma|design|mockup|wireframe|prototype|ui\s*kit|design\s*system|style\s*guide|component\s*library)\b/i

// Phase 0 detection (brainstorm mode)
const miscConfig = readTalismanSection("misc") || {}
const maxFigmaUrls = miscConfig.design_sync?.max_figma_urls ?? 10
let figmaUrls = (userDescription.match(FIGMA_URL_PATTERN) || []).slice(0, maxFigmaUrls)
if (figmaUrls.length > 5) warn(`Found ${figmaUrls.length} Figma URLs — processing first ${maxFigmaUrls}`)
let figmaUrl = figmaUrls[0] ?? null  // primary URL for single-URL consumers (backward compat)
let designAware = figmaUrls.length > 0

// --quick fallback: Phase 0 is skipped, so apply detection before Phase 1
// The feature description is still available from the user prompt
if (quickMode && !designAware) {
  // Re-scan: user may have provided Figma URL as part of quick description
  const quickFigmaUrls = (featureDescription.match(FIGMA_URL_PATTERN) || []).slice(0, maxFigmaUrls)
  if (quickFigmaUrls.length > 0) {
    figmaUrls.push(...quickFigmaUrls)
    figmaUrl = figmaUrls[0]
    designAware = true
  }
}

// --brainstorm-context fallback: extract from workspace metadata
// This runs AFTER the user description scan and --quick fallback
if (!designAware && brainstormContextFlag) {
  try {
    const bsMeta = JSON.parse(Read(`${brainstormContextFlag}/workspace-meta.json`))
    const bsUrls = bsMeta.design_urls || []
    if (bsUrls.length > 0) {
      figmaUrls = bsUrls.slice(0, maxFigmaUrls)
      figmaUrl = bsUrls[0]
      designAware = true
      design_sync_candidate = true
    }
  } catch (e) {
    // workspace-meta.json missing or malformed — proceed without design context
  }
}

// Pass designAware, figmaUrls (full array), and figmaUrl (primary, backward compat) downstream:
// - brainstorm phase (Phase 3.5 design asset detection)
// - synthesize phase (figma_urls frontmatter array + Design Implementation section)
// - design-pipeline-agent (iterates figmaUrls for multi-file inventory)
let design_sync_candidate = designAware

if (designAware) {
  loadedSkills.push('design-sync')
  loadedSkills.push('frontend-design-patterns')
}
```

## Design Pipeline Agent (conditional, Phase 0 post-step)

When `design_sync_candidate === true` AND `talisman.design_sync.enabled === true`, spawn a design-pipeline-agent that runs a mandatory element analysis step BEFORE the prototype pipeline.

### MANDATORY: Pre-Implementation Element Analysis

**Before ANY extraction or prototype generation**, the agent MUST use `get_figma_data` (Framelink, preferred) to enumerate all elements in the design. This prevents missing data, elements, or components during implementation.

```
// Step 0: Deep element analysis via figma-context-mcp (MANDATORY)
// This runs BEFORE the 3-stage pipeline to establish the complete element inventory.
// Prefer Framelink because its AI-optimized output captures element relationships
// that raw Figma API nodes miss (compressed but semantically complete).

const parsedUrl = parseFigmaUrl(figmaUrls[0])
let elementInventory = null

try {
  // Framelink preferred — AI-optimized, captures all elements including thin separators
  const rawData = get_figma_data(fileKey=parsedUrl.fileKey, nodeId=parsedUrl.nodeId)
  elementInventory = analyzeDesignElements(rawData)
} catch (e) {
  // Fallback to Rune MCP
  try {
    const rawData = figma_fetch_design(url=figmaUrls[0], depth=5)
    elementInventory = analyzeDesignElements(rawData)
  } catch (e2) {
    warn("Cannot analyze design elements — both Framelink and Rune MCP unavailable")
  }
}

function analyzeDesignElements(data):
  return {
    total_nodes: countNodes(data),
    frames: listFrames(data),
    components: listComponents(data),           // buttons, inputs, cards, etc.
    icons: listIcons(data),                     // icon instances + small vector groups
    separators: listSeparators(data),           // LINE + thin RECTANGLE nodes
    bordered_elements: listBorderedElements(data), // nodes with strokes
    overlapping_elements: listOverlays(data),    // absolute-positioned nodes (z-index risk)
    text_nodes: listTextNodes(data),
    images: listImages(data)
  }

// Write inventory for pipeline stages
Write(`${outputDir}/element-inventory.json`, JSON.stringify(elementInventory, null, 2))
log(`Design analysis complete: ${elementInventory.total_nodes} nodes, ` +
    `${elementInventory.components.length} components, ${elementInventory.icons.length} icons, ` +
    `${elementInventory.separators.length} separators, ${elementInventory.bordered_elements.length} bordered, ` +
    `${elementInventory.overlapping_elements.length} overlays`)
```

This inventory becomes the verification checklist — after implementation, every separator, border, icon, and overlay in the inventory MUST have a corresponding element in the output.

### Pipeline Stages

After element analysis, runs the design-prototype 3-stage pipeline (extract, match, synthesize) to produce `design-references/` with prototypes, library matches, and UX flow mapping. The element inventory is passed to each stage as context.

Falls back to `figma_list_components`-only inventory when the design-prototype skill is not installed.

```javascript
// Conditional design pipeline agent — only when design_sync_candidate + talisman enabled
const designSyncEnabled = (readTalismanSection("misc") || {}).design_sync?.enabled === true

if (design_sync_candidate && designSyncEnabled && figmaUrls.length > 0) {
  // SEC: SSRF defense — validate Figma URLs before embedding in agent prompts.
  // Canonical source: brainstorm/SKILL.md Phase 3.5 SSRF filter (lines 266-280).
  const FIGMA_DOMAIN_PATTERN = /^https:\/\/(www\.)?figma\.com\//
  figmaUrls = figmaUrls
    .map(url => url.replace(/[\r\n]/g, ''))  // Strip newlines (prevent instruction injection)
    .filter(url => FIGMA_DOMAIN_PATTERN.test(url))
  if (figmaUrls.length === 0) return  // All URLs filtered by SSRF validation

  // Resolve output directory — explicitly passed to avoid path mismatch
  // (design-prototype defaults to design-references/{timestamp}, but devise needs tmp/plans/{timestamp}/design-references/)
  const outputDir = `tmp/plans/${timestamp}/design-references`

  // Check if design-prototype skill is installed (Shard 1 dependency)
  const pluginRoot = Bash("echo ${RUNE_PLUGIN_ROOT}").trim()
  const designPrototypeInstalled = Glob("plugins/rune/skills/design-prototype/SKILL.md").length > 0
    || (pluginRoot && Glob(`${pluginRoot}/skills/design-prototype/SKILL.md`).length > 0)

  // ATE-1 COMPLIANT: Agent joins rune-plan-{timestamp} team created in Phase -1.
  TaskCreate({
    subject: "Run design prototype pipeline",
    description: designPrototypeInstalled
      ? "Run full 3-stage pipeline: extract → match → synthesize. Output to design-references/"
      : "Fallback: extract component inventory via figma_list_components only",
    activeForm: "Running design pipeline"
  })

  if (designPrototypeInstalled) {
    // Option A: Inline delegation — extend agent prompt with full pipeline stages
    Agent({
      name: 'design-pipeline-agent',
      subagent_type: 'general-purpose',
      team_name: `rune-plan-${timestamp}`,
      prompt: `You are a design prototype pipeline specialist.

        ## Assignment
        Figma URLs (${figmaUrls.length} total): ${JSON.stringify(figmaUrls)}
        Primary URL: ${figmaUrls[0]}
        Output directory: ${outputDir}
        Max components: ${miscConfig.design_sync?.max_reference_components ?? 5}

        ## Pipeline Overview
        Run the design-prototype 3-stage pipeline inline. Each stage has independent
        error boundaries — Stage 2 failures must NOT abort Stage 1 outputs.

        ## MCP Tool Availability
        Two Figma MCP namespaces may be available. Try in this order:
        1. **figma-context-mcp** (Framelink, preferred for data — AI-optimized ~90% compression): get_figma_data, download_figma_images
        2. **Rune tools** (unique capabilities — deep inspect + code gen): figma_list_components, figma_fetch_design, figma_inspect_node, figma_to_react

        **IMPORTANT — MCP namespace verification**: Before calling any MCP tool, verify it exists
        in your available MCP server list. Use BOTH providers when available (composition model):
        - Framelink for component listing (get_figma_data with depth=1)
        - Rune for code generation (figma_to_react) — skip gracefully if unavailable
        If neither is available, abort the pipeline.

        To extract fileKey from the Figma URL for figma-context-mcp tools:
        - Parse: https://www.figma.com/design/{fileKey}/{name}?node-id={nodeId}
        - fileKey is the alphanumeric segment after /design/ or /file/
        - nodeId in URL uses hyphens ("1-3"); figma-context-mcp needs colons ("1:3")

        ## Stage 1: Extract (REQUIRED — abort pipeline only if this fails entirely)
        1. Claim the "Run design prototype pipeline" task via TaskList/TaskUpdate
        2. Create output directory: Bash("mkdir -p ${outputDir}/extractions ${outputDir}/prototypes")
        3. For EACH URL in the Figma URLs list:
           a. Component listing (prefer Framelink for compressed data):
              - Try get_figma_data(fileKey, depth=1) first → parse components
              - If unavailable: fall back to figma_list_components(url="{url}")
           b. Cap to maxComponents (sorted by visual hierarchy)
           c. For each component: call figma_to_react(nodeId) to get reference JSX + Tailwind (Rune-only)
              - On success: write to ${outputDir}/extractions/{safeName}.tsx
              - On failure or Rune unavailable: skip code gen, component still in inventory
           d. Record which providers were used in output
        4. Write ${outputDir}/tokens-snapshot.json with design token summary
        5. Write ${outputDir}/inventory.json with component list:
           Format: { "components": [{ "name": "...", "node_id": "...", "type": "...", "source_url": "...", "extraction_path": "..." }], "figma_urls": [...], "mcpProvider": "rune|framelink" }

        If ALL extractions fail for ALL URLs → write inventory.json with error entries,
        skip Stages 2-3, proceed to Stage 1 output finalization, then mark task complete.

        ## Stage 2: Match (CONDITIONAL — requires UI builder MCP, failures are non-fatal)
        **Error boundary**: Stage 2 runs inside its own try/catch. Any failure here
        preserves all Stage 1 outputs intact.

        1. Check if a UI builder MCP is available (e.g., search_components tool)
           - If not available: skip Stage 2 entirely, log "No UI builder MCP — skipping library match"
        2. For each extracted component:
           a. Search builder library: search_components("{component.name}")
           b. Circuit breaker: 3 consecutive failures → skip remaining matches
           c. Record match result with confidence score
        3. Write ${outputDir}/match-report.json with all match results
        4. Write ${outputDir}/library-manifest.json with install commands for matched components

        ## Stage 3: Synthesize (CONDITIONAL — requires at least 1 extraction from Stage 1)
        **Error boundary**: Per-component try/catch. One failure does not abort others.

        1. For each extracted component:
           a. If library match exists (from Stage 2): merge reference structure with library API
           b. If no match: use Figma reference code with Tailwind styling as-is
           c. Write ${outputDir}/prototypes/{componentName}/prototype.tsx
           d. Write ${outputDir}/prototypes/{componentName}/prototype.stories.tsx (CSF3 format)
              - Include data state stories: Default, Empty, Loading, Error
              - Include interaction states where applicable
        2. If >= 2 components extracted: generate UX flow mapping
           a. Analyze inter-component relationships (navigation, data flow)
           b. Write ${outputDir}/flow-map.md with screen-to-screen navigation map
           c. Write ${outputDir}/ux-patterns.md with notification/status patterns
        3. Write ${outputDir}/prototypes-manifest.json listing all generated prototypes:
           Format: { "components": [{ "name": "...", "prototype_path": "...", "story_path": "...", "has_library_match": bool }] }
        4. Write ${outputDir}/SUMMARY.md with per-component visual intent + recommendation

        ## Finalization
        1. Verify output directory has at minimum: inventory.json
        2. Mark task complete via TaskUpdate

        ## Error Handling
        - Stage 1 failure (all URLs fail): write error inventory.json, skip Stages 2-3
        - Stage 2 failure: preserve Stage 1 output, skip Stage 2, continue to Stage 3
        - Stage 3 per-component failure: skip failed component, continue with others
        - MCP timeout: use talisman design_sync.reference_timeout_ms (default: 15000ms)`,
      run_in_background: true
    })
  } else {
    // Fallback: design-prototype skill not installed — inventory only (matches pre-Shard-2 behavior)
    Agent({
      name: 'design-pipeline-agent',
      subagent_type: 'general-purpose',
      team_name: `rune-plan-${timestamp}`,
      prompt: `You are a design inventory specialist (fallback mode — design-prototype skill not installed).

        ## Assignment
        Figma URLs (${figmaUrls.length} total): ${JSON.stringify(figmaUrls)}
        Primary URL: ${figmaUrls[0]}
        Output directory: ${outputDir}

        ## MCP Tool Availability (Composition Model)
        Two Figma MCP namespaces may be available. Use BOTH for best results:
        1. **figma-context-mcp** (Framelink, preferred for data — AI-optimized ~90% compression): get_figma_data, download_figma_images
        2. **Rune tools** (unique capabilities — deep inspect): figma_list_components, figma_fetch_design, figma_inspect_node

        **IMPORTANT — MCP namespace verification**: Before calling any MCP tool, verify it exists
        in your available MCP server list. Use whichever providers are available — prefer
        Framelink for component listing (compressed data), Rune for deep node inspection.

        To extract fileKey from the Figma URL for figma-context-mcp tools:
        - Parse: https://www.figma.com/design/{fileKey}/{name}?node-id={nodeId}
        - fileKey is the alphanumeric segment after /design/ or /file/
        - nodeId in URL uses hyphens ("1-3"); figma-context-mcp needs colons ("1:3")

        ## Lifecycle
        1. Claim the "Run design prototype pipeline" task via TaskList/TaskUpdate
        2. Create output directory: Bash("mkdir -p ${outputDir}")
        3. For EACH URL in the Figma URLs list:
           a. **Prefer Framelink** for component listing: get_figma_data(fileKey, depth=1)
              - Parse component names and node IDs from compressed response
           b. **If Framelink unavailable**: fall back to Rune: figma_list_components(url="{url}")
              - Extract component names, node IDs, and types from result
           c. Record which providers were used in output
        4. Write component inventory to: ${outputDir}/inventory.json
           Format: { "components": [{ "name": "...", "node_id": "...", "type": "...", "source_url": "..." }], "figma_urls": [...], "providers": { "framelink": bool, "rune": bool } }
        5. If BOTH tool namespaces fail for a URL, record:
           { "error": "Figma MCP not available", "figma_url": "{url}" } in components array
        6. Do not write implementation code. Inventory only.
        7. Mark task complete via TaskUpdate`,
      run_in_background: true
    })
  }

  // Store output path in plan frontmatter for downstream consumers (forge, strive, synthesize)
  // design_references_path: tmp/plans/{timestamp}/design-references/
  // library_match_count: populated after pipeline completes (read from match-report.json)
}
```
