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

| Rune MCP Tool | Framelink Equivalent | Notes |
|---------------|---------------------|-------|
| `figma_fetch_design(url)` | `get_figma_data(fileKey, nodeId?)` | Framelink returns AI-optimized compressed data (~90% smaller); Rune returns IR node tree |
| `figma_list_components(url)` | `get_figma_data(fileKey, depth=1)` | Parse components from compressed response structure |
| `figma_inspect_node(url)` | _(no equivalent)_ | Falls back to Rune primary; Framelink lacks per-node inspection |
| _(no equivalent)_ | `download_figma_images(fileKey, nodes, format?)` | Download rendered images of specific nodes |

**Key differences:**
- Framelink uses `fileKey` + `nodeId` as separate parameters (not full URLs)
- Framelink `nodeId` format: colon-separated `"1:3"` (same as Figma internal format)
- Rune tools accept full Figma URLs; Framelink uses the same `fileKey`/`nodeId` params from [figma-url-parser.md](figma-url-parser.md)

### Extraction Algorithm with Provider Branching

```
state = readWorkflowState()
mcpProvider = state.mcpProvider ?? "rune"

function fetchDesign(parsedUrl):
  if mcpProvider == "rune":
    return figma_fetch_design(url=parsedUrl.original_url, depth=3)
  else:  // "framelink"
    return get_figma_data(
      fileKey=parsedUrl.file_key,
      nodeId=parsedUrl.node_id  // Already colon-separated from parser
    )

function listComponents(parsedUrl):
  if mcpProvider == "rune":
    return figma_list_components(url=parsedUrl.original_url)
  else:  // "framelink"
    rawData = get_figma_data(fileKey=parsedUrl.file_key, depth=1)
    return parseComponentsFromData(rawData)  // Extract components from compressed response

function inspectNode(parsedUrl):
  if mcpProvider == "rune":
    return figma_inspect_node(url=parsedUrl.original_url)
  else:  // "framelink" — no equivalent, fall back to Rune primary
    return null

function fetchDesignTokens(parsedUrl):
  // Neither Rune nor Framelink has a dedicated token endpoint
  // Fall back to token extraction from design tree (universal fallback)
  return null
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
