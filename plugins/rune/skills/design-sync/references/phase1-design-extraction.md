# Phase 1: Design Extraction Algorithm

Detailed algorithm for extracting Figma design data and creating Visual Spec Maps (VSM).

## Extraction Pipeline

### Step 1: URL Resolution

```
1. Parse figmaUrl into { file_key, node_id?, branch_name? }
2. If node_id present → extract specific component/frame
3. If node_id absent → extract all top-level frames from the page
4. Validate file_key format: [A-Za-z0-9]+
```

### Step 2: Component Discovery

```
components = figma_list_components(url=figmaUrl)

Categorize:
- COMPONENT_SET → multi-variant component (e.g., Button with size/state)
- COMPONENT → single-variant component
- INSTANCE → usage of a component (skip — analyze the source)

Filter out:
- Internal/private components (names starting with _ or .)
- Duplicate instances (same component_id used multiple times)
```

### Step 3: Per-Component Extraction

For each target component:

```
1. Fetch detailed data:
   tree = figma_fetch_design(url=componentUrl, depth=3)
   details = figma_inspect_node(url=componentUrl)

2. Extract tokens:
   colors = extractColors(tree)        // Fill, stroke → token mapping
   spacing = extractSpacing(tree)      // Padding, gap → scale mapping
   typography = extractTypography(tree) // Font, size, weight, leading
   effects = extractEffects(details)   // Shadows, blur → elevation
   borders = extractBorders(details)   // Stroke, radius → scale

3. Build region tree:
   regions = decompose(tree)           // Recursive region identification
   For each node:
     - Classify: FRAME→container, TEXT→content, RECTANGLE→element
     - Determine layout: auto-layout → flex, grid → grid, absolute → static
     - Extract sizing: fixed|fill|hug

4. Map variants (for COMPONENT_SET):
   For each variant property:
     - Classify: prop (user-selectable) vs state (CSS pseudo-class)
     - Extract token differences per variant value
     - Generate prop interface skeleton

5. Infer responsive behavior:
   - Check for frame variants at different widths
   - Check for "Mobile", "Tablet", "Desktop" named frames
   - Check auto-layout wrap mode (implies responsive wrap)

6. Derive accessibility requirements:
   - Interactive elements → keyboard + focus requirements
   - Text content → contrast requirements
   - Images → alt text requirements
   - Forms → label requirements
```

### Step 4: VSM Output

Write one VSM file per component to `{workDir}/vsm/{component-name}.md`.

See [vsm-spec.md](vsm-spec.md) for the output schema.

## Token Mapping Strategy

```
For each color value:
  1. Check project design tokens (CSS custom properties, Tailwind config)
  2. If exact match → use token name
  3. If no exact match → snap to nearest Tailwind palette (RGB distance < 20)
  4. If no snap → flag as "unmatched" in VSM with hex value

For each spacing value:
  1. Round to nearest spacing scale value
  2. If within 2px → map to scale token
  3. If off-scale by >2px → flag as "off-scale" with both values
```

See [design-token-mapping.md](design-token-mapping.md) for detailed snapping algorithm.

## MCP Provider Tool Mapping

The design-sync skill supports two MCP providers. The provider is determined from the workflow state file (`mcpProvider` field). Default is `rune` when field is absent.

| Rune MCP Tool | Official MCP Equivalent | Notes |
|---------------|------------------------|-------|
| `figma_fetch_design(url)` | `mcp__plugin_figma_figma__get_design_context(fileKey, nodeId)` | Official returns structured context; Rune returns IR node tree |
| `figma_list_components(url)` | `mcp__plugin_figma_figma__get_metadata(fileKey)` | Official returns XML — needs parsing; Rune returns JSON component inventory |
| `figma_inspect_node(url)` | `mcp__plugin_figma_figma__get_code_connect_map(fileKey, nodeIds)` | `nodeIds` is array of colon-separated IDs (e.g. `["1:3"]`) |
| _(no equivalent)_ | `mcp__plugin_figma_figma__get_variable_defs(fileKey)` | Bonus: retrieves named design tokens (colors, spacing, typography as variables) |

**Key differences:**
- Official MCP uses `fileKey` + `nodeId` as separate parameters (not full URLs)
- Official `nodeId` format: colon-separated `"1:3"` (same as Figma internal format)
- Rune tools accept full Figma URLs; use [figma-url-parser.md](figma-url-parser.md) `convertToOfficialParams()` to convert

### Extraction Algorithm with Provider Branching

```
state = readWorkflowState()
mcpProvider = state.mcpProvider ?? "rune"

function fetchDesign(parsedUrl):
  if mcpProvider == "rune":
    return figma_fetch_design(url=parsedUrl.original_url, depth=3)
  else:  // "official"
    params = convertToOfficialParams(parsedUrl)
    return mcp__plugin_figma_figma__get_design_context(
      fileKey=params.fileKey,
      nodeId=params.nodeId
    )

function listComponents(parsedUrl):
  if mcpProvider == "rune":
    return figma_list_components(url=parsedUrl.original_url)
  else:  // "official"
    params = convertToOfficialParams(parsedUrl)
    rawXml = mcp__plugin_figma_figma__get_metadata(fileKey=params.fileKey)
    return parseComponentsFromXml(rawXml)  // Extract name/node_id from XML tree

function inspectNode(parsedUrl):
  if mcpProvider == "rune":
    return figma_inspect_node(url=parsedUrl.original_url)
  else:  // "official"
    params = convertToOfficialParams(parsedUrl)
    return mcp__plugin_figma_figma__get_code_connect_map(
      fileKey=params.fileKey,
      nodeIds=[params.nodeId]  // Colon-separated format: "1:3"
    )

function fetchDesignTokens(parsedUrl):
  // Only available via Official MCP — Rune has no equivalent
  if mcpProvider == "official":
    params = convertToOfficialParams(parsedUrl)
    return mcp__plugin_figma_figma__get_variable_defs(fileKey=params.fileKey)
  else:
    return null  // Fall back to token extraction from design tree
```

## Error Handling

| Error | Action |
|-------|--------|
| Figma API rate limit | Back off 60s, retry 3x, then fail task |
| Node not found | Log warning, skip node, continue extraction |
| Large file (>500 nodes) | Paginate with max_length/start_index |
| Network timeout | Retry with increased timeout, fail after 3 attempts |
| Invalid token (401) | Fail immediately, report to Tarnished — user must fix FIGMA_TOKEN |

## Cross-References

- [vsm-spec.md](vsm-spec.md) — VSM output schema
- [design-token-mapping.md](design-token-mapping.md) — Token snapping algorithm
- [figma-url-parser.md](figma-url-parser.md) — URL format handling
