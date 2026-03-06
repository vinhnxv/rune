# Design Signal Detection & Inventory Agent

## Design Signal Detection (Phase 0 pre-step)

Before brainstorm questions, scan the user description for Figma URLs. When detected, enables design-aware planning throughout the pipeline. With `--quick` (Phase 0 skipped), a fallback applies `FIGMA_URL_PATTERN` to the feature description before Phase 1 agents spawn.

```javascript
// SYNC: figma-url-pattern — shared with brainstorm-phase.md Step 3.2
const FIGMA_URL_PATTERN = /https?:\/\/[^\s]*figma\.com\/[^\s]+/g
const DESIGN_KEYWORD_PATTERN = /\b(figma|design|mockup|wireframe|prototype|ui\s*kit|design\s*system|style\s*guide|component\s*library)\b/i

// Phase 0 detection (brainstorm mode)
const maxFigmaUrls = talisman?.design_sync?.max_figma_urls ?? 10
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

// Pass designAware, figmaUrls (full array), and figmaUrl (primary, backward compat) downstream:
// - brainstorm phase (Step 3.2 design asset detection)
// - synthesize phase (figma_urls frontmatter array + Design Implementation section)
// - design-inventory-agent (iterates figmaUrls for multi-file inventory)
let design_sync_candidate = designAware

if (designAware) {
  loadedSkills.push('design-sync')
  loadedSkills.push('frontend-design-patterns')
}
```

## Design Inventory Agent (conditional, Phase 0 post-step)

When `design_sync_candidate === true` AND `talisman.design_sync.enabled === true`, spawn a lightweight design-inventory-agent that calls `figma_list_components` MCP tool to pre-populate the component inventory for the plan.

```javascript
// Conditional design research agent — only when design_sync_candidate + talisman enabled
const designSyncEnabled = talisman?.design_sync?.enabled === true

if (design_sync_candidate && designSyncEnabled && figmaUrls.length > 0) {
  // ATE-1 COMPLIANT: Agent joins rune-plan-{timestamp} team created in Phase -1.
  TaskCreate({
    subject: "Extract Figma design inventory",
    description: "Call figma_list_components MCP tool, extract component inventory for all Figma URLs",
    activeForm: "Extracting design inventory"
  })

  Agent({
    name: 'design-inventory-agent',
    subagent_type: 'general-purpose',
    team_name: `rune-plan-${timestamp}`,
    prompt: `You are a design inventory specialist.

      ## Assignment
      Figma URLs (${figmaUrls.length} total): ${JSON.stringify(figmaUrls)}
      Primary URL: ${figmaUrls[0]}

      ## MCP Tool Availability
      Two Figma MCP namespaces may be available. Try in this order:
      1. **Rune tools** (preferred): figma_list_components, figma_fetch_design, figma_inspect_node
      2. **Official Figma MCP** (fallback): mcp__claude_ai_Figma__get_metadata, mcp__claude_ai_Figma__get_design_context

      **IMPORTANT — MCP namespace verification**: Before calling any MCP tool, verify it exists
      in your available MCP server list. Tool name resolution relies on Claude Code's MCP
      namespace isolation — the same tool may be unavailable if its server is not registered.
      If figma_list_components is not listed in your available tools, skip to the Official MCP
      fallback (step 2). Do not attempt to call a tool that is not present in your tool list.

      To extract fileKey from the Figma URL for Official MCP tools:
      - Parse: https://www.figma.com/design/{fileKey}/{name}?node-id={nodeId}
      - fileKey is the alphanumeric segment after /design/ or /file/
      - nodeId in URL uses hyphens ("1-3"); Official MCP needs colons ("1:3")

      ## Lifecycle
      1. Claim the "Extract Figma design inventory" task via TaskList/TaskUpdate
      2. For EACH URL in the Figma URLs list:
         a. **Try Rune tools first**: Call figma_list_components(url="{url}")
            - On success: extract component names, node IDs, and types from result
            - Record mcpProvider: "rune" in output
         b. **If Rune tools fail** (tool not found / MCP unavailable): fall back to Official MCP:
            - Extract fileKey from the Figma URL
            - Call mcp__claude_ai_Figma__get_metadata(fileKey="{fileKey}")
            - Parse component names and node IDs from XML response
            - Record mcpProvider: "official" in output
      3. Write combined component inventory to: tmp/plans/${timestamp}/design-inventory.json
         Format: { "components": [{ "name": "...", "node_id": "...", "type": "...", "source_url": "..." }], "figma_urls": [...], "mcpProvider": "rune|official" }
      4. If BOTH tool namespaces fail for a URL, record:
         { "error": "Figma MCP not available", "figma_url": "{url}" } in components array
      5. Do not write implementation code. Inventory only.
      6. Mark task complete via TaskUpdate`,
    run_in_background: true
  })
  // Output is read during Phase 2 (Synthesize) to populate Component Inventory table
}
```
