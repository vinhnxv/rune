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

### Step 2: Element Inventory & Component Discovery

**BEFORE any extraction**, enumerate ALL elements in the design using the composition model.
This inventory becomes the ground truth — nothing in the design should be missing from it.

```
// Step 2a: Full element inventory (prefer Framelink — compressed, cheaper)
// This step MUST run before per-component extraction to establish what exists.
rawData = fetchDesign(parsedUrl)  // uses composition: Framelink preferred, Rune fallback

inventory = {
  frames: [],        // top-level frames/screens
  components: [],    // component instances and sets
  icons: [],         // icon nodes (INSTANCE matching icon patterns, small FRAME/GROUP with vectors)
  separators: [],    // LINE nodes and thin RECTANGLE (height≤2px)
  borders: [],       // nodes with strokes (border-width > 0)
  images: [],        // IMAGE fills or RECTANGLE with image fills
  textNodes: [],     // TEXT nodes with content
  overlays: []       // absolutely-positioned nodes (potential z-index issues)
}

function buildInventory(node, depth=0):
  // Classify every node — NOTHING should be skipped
  if node.type == "FRAME" OR node.type == "GROUP":
    if depth == 0: inventory.frames.push(node)
    if isIcon(node): inventory.icons.push(node)
  if node.type == "COMPONENT_SET" OR node.type == "COMPONENT":
    inventory.components.push(node)
  if node.type == "INSTANCE":
    if isIcon(node): inventory.icons.push(node)
    else: inventory.components.push(node)
  if isSeparator(node):
    inventory.separators.push(node)
  if node.strokes?.length > 0 AND node.strokes[0].weight > 0:
    inventory.borders.push({ node, strokeWeight: node.strokes[0].weight, strokeColor: node.strokes[0].color })
  if node.type == "TEXT":
    inventory.textNodes.push(node)
  if node.layoutPositioning == "ABSOLUTE":
    inventory.overlays.push(node)
  // Recurse
  for child in (node.children ?? []):
    buildInventory(child, depth + 1)

buildInventory(rawData)

// Log inventory summary — this is the "contract" of what MUST appear in VSM
log(`Element inventory: ${inventory.frames.length} frames, ${inventory.components.length} components, ` +
    `${inventory.icons.length} icons, ${inventory.separators.length} separators, ` +
    `${inventory.borders.length} bordered nodes, ${inventory.overlays.length} overlays`)

// Step 2b: Component discovery from inventory
components = inventory.components

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
   colors = extractColors(tree)             // Fill, stroke → token mapping
   spacing = extractPerSideSpacing(tree)    // Per-side padding (pt/pr/pb/pl), margin, gap
   typography = extractTypography(tree)     // Font, size, weight, leading
   effects = extractEffects(details)        // Shadows, blur → elevation
   borders = extractFullBorders(details)    // Stroke width, color, style + radius (NOT just radius)
   icons = extractIcons(tree)               // Icon nodes → name, library, size, color

3. Build region tree:
   regions = decompose(tree)                // Recursive region identification
   For each node:
     - Classify: FRAME→container, TEXT→content, RECTANGLE→element,
                 LINE→separator, THIN_RECT→separator, ICON→icon
     - Determine layout: auto-layout → flex, grid → grid, absolute → static
     - Extract sizing: fixed|fill|hug
     - Extract stacking: absolutePosition → z-index annotation
     - Detect separators: see Separator Detection Algorithm below

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

## Separator Detection Algorithm

Figma separators are commonly missed because they appear as thin RECTANGLE or LINE nodes.
This algorithm ensures they are preserved in the Region Tree.

```
function isSeparator(node):
  // LINE nodes are always separators
  if node.type == "LINE": return true

  // Thin RECTANGLEs: height ≤ 2px (horizontal) or width ≤ 2px (vertical)
  if node.type == "RECTANGLE":
    if node.height <= 2 AND node.width > node.height * 10: return true  // horizontal divider
    if node.width <= 2 AND node.height > node.width * 10: return true   // vertical divider

  // Auto-layout itemSpacing with strokesIncludedInLayout
  if node.parent?.layoutMode AND node.parent?.strokesIncludedInLayout: return true

  return false

// In decompose():
if isSeparator(node):
  classify as "separator"
  emit: **Separator** — `<hr>`, border-t, border-{color-token}
  DO NOT skip or merge into parent
```

## Icon Detection Algorithm

Icons are commonly extracted as generic "element" nodes, losing the icon identity.

```
function isIcon(node):
  // Figma icons are typically: INSTANCE of a component named with icon convention
  if node.type == "INSTANCE" AND node.componentName?.match(/icon|arrow|chevron|close|search|plus|minus|check|x|menu/i):
    return true
  // Or: FRAME/GROUP containing only vectors, sized 12-48px
  if (node.type == "FRAME" OR node.type == "GROUP"):
    if node.children.every(c => c.type == "VECTOR") AND
       node.width >= 12 AND node.width <= 48 AND node.height >= 12 AND node.height <= 48:
      return true
  return false

function extractIcons(tree):
  icons = []
  for each node in tree (recursive):
    if isIcon(node):
      icons.push({
        region: parentRegionName(node),
        name: inferIconName(node),          // from componentName or parent name
        library: inferIconLibrary(node),     // lucide, heroicons, etc. from project deps
        size: `${node.width}px`,
        colorToken: extractFillColor(node)
      })
  return icons
```

## Full Border Extraction

Previous extraction only captured border-radius. Full border extraction captures width, color, style.

```
function extractFullBorders(details):
  borders = []
  for each node with strokes:
    for each stroke in node.strokes:
      borders.push({
        property: resolveBorderSide(stroke),  // border, border-t, border-b, etc.
        width: stroke.weight + "px",
        color: rgbaToToken(stroke.color),
        style: stroke.dashPattern ? "dashed" : "solid",
        radius: node.cornerRadius ?? 0       // still extract radius
      })
  return borders

// Border side resolution:
// Figma strokeAlign: "INSIDE"|"OUTSIDE"|"CENTER"
// Figma individualStrokeWeights: { top, right, bottom, left }
function resolveBorderSide(node):
  if node.individualStrokeWeights:
    sides = []
    if node.individualStrokeWeights.top > 0: sides.push("border-t")
    if node.individualStrokeWeights.right > 0: sides.push("border-r")
    if node.individualStrokeWeights.bottom > 0: sides.push("border-b")
    if node.individualStrokeWeights.left > 0: sides.push("border-l")
    return sides
  return ["border"]  // all sides
```

## Per-Side Spacing Extraction

Previous extraction collapsed all padding into a single value. Per-side extraction preserves asymmetric spacing.

```
function extractPerSideSpacing(node):
  spacing = {}

  // Padding (from auto-layout paddingLeft/Right/Top/Bottom)
  if node.paddingTop != node.paddingBottom OR node.paddingLeft != node.paddingRight:
    // Asymmetric — track per-side
    spacing.pt = snapToScale(node.paddingTop)
    spacing.pr = snapToScale(node.paddingRight)
    spacing.pb = snapToScale(node.paddingBottom)
    spacing.pl = snapToScale(node.paddingLeft)
  else:
    // Symmetric — use shorthand
    spacing.px = snapToScale(node.paddingLeft)
    spacing.py = snapToScale(node.paddingTop)

  // Gap (from auto-layout itemSpacing)
  if node.itemSpacing:
    spacing.gap = snapToScale(node.itemSpacing)

  // Margin (inferred from parent's gap or absolute position offset)
  // NOTE: Figma has no native "margin" — infer from parent gap or absolute positioning
  if node.parent?.layoutMode:
    spacing.parentGap = snapToScale(node.parent.itemSpacing)  // acts as margin between siblings

  return spacing
```

## Stacking Context Detection

z-index issues occur when absolutely-positioned elements overlap interactive components.

```
function extractStackingContext(node):
  if node.layoutPositioning == "ABSOLUTE":
    return {
      position: "absolute",
      zIndex: inferZIndex(node),   // from layer order in Figma
      offset: { top: node.y, left: node.x }
    }
  if node.type == "FRAME" AND hasOverlappingChildren(node):
    return { position: "relative", createsContext: true }
  return null

function inferZIndex(node):
  // Figma uses layer order (top of list = highest z)
  // Map to CSS z-index: higher layer index = higher z-index
  siblings = node.parent.children
  layerIndex = siblings.indexOf(node)
  totalSiblings = siblings.length
  // Map to z-index scale: 0, 10, 20, 30, 40, 50
  return Math.round((layerIndex / totalSiblings) * 50 / 10) * 10
```

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

## MCP Provider Composition

The design-sync skill uses **provider composition** — each provider contributes its unique capabilities rather than being an exclusive choice. The `providers` object from Phase 0 state file determines what's available.

| Capability | figma-context-mcp (Framelink) | Rune MCP | Notes |
|------------|-------------------------------|----------|-------|
| Data extraction | `get_figma_data(fileKey, nodeId?)` — AI-optimized, ~90% compression | `figma_fetch_design(url, depth)` — raw IR node tree | figma-context-mcp preferred (smaller, LLM-optimized) |
| Component listing | `get_figma_data(fileKey, depth=1)` + parse | `figma_list_components(url)` | figma-context-mcp preferred |
| Deep node inspection | _(no equivalent)_ | `figma_inspect_node(url)` | Rune-only — graceful skip when unavailable |
| Code generation | _(no equivalent)_ | `figma_to_react(url)` | Rune-only — VSM-only path when unavailable |
| Image download | `download_figma_images(fileKey, nodes, format?)` | _(no equivalent)_ | Framelink-only — optional enrichment |

**Key differences:**
- Framelink uses `fileKey` + `nodeId` as separate parameters (not full URLs)
- Framelink `nodeId` format: colon-separated `"1:3"` (same as Figma internal format)
- Rune tools accept full Figma URLs; Framelink uses the same `fileKey`/`nodeId` params from [figma-url-parser.md](figma-url-parser.md)

### Extraction Algorithm with Provider Composition

```
state = readWorkflowState()
providers = state.providers ?? { framelink: false, rune: true, desktop: false }

function fetchDesign(parsedUrl):
  // Prefer Framelink — AI-optimized compressed data, better for LLM context
  if providers.framelink:
    return get_figma_data(
      fileKey=parsedUrl.file_key,
      nodeId=parsedUrl.node_id  // Already colon-separated from parser
    )
  else if providers.rune:
    return figma_fetch_design(url=parsedUrl.original_url, depth=3)
  else:
    return null  // Should not reach here — Phase 0 ensures at least one provider

function listComponents(parsedUrl):
  // Prefer Framelink — compressed response, lower token cost
  if providers.framelink:
    rawData = get_figma_data(fileKey=parsedUrl.file_key, depth=1)
    return parseComponentsFromData(rawData)
  else if providers.rune:
    return figma_list_components(url=parsedUrl.original_url)
  else:
    return []

function inspectNode(parsedUrl):
  // Rune-only capability — graceful skip when unavailable
  if providers.rune:
    return figma_inspect_node(url=parsedUrl.original_url)
  return null  // Effects and borders extracted from design tree fallback

function generateReferenceCode(parsedUrl):
  // Rune-only capability — graceful skip when unavailable
  if providers.rune:
    return figma_to_react(url=parsedUrl.original_url)
  return null  // VSM-only path: Phase 1.3 component match uses VSM regions directly

function downloadImages(parsedUrl, nodeIds):
  // Framelink-only capability — optional enrichment
  if providers.framelink:
    return download_figma_images(fileKey=parsedUrl.file_key, nodes=nodeIds)
  return null  // Screenshot comparison skipped

function fetchDesignTokens(parsedUrl):
  // Neither provider has a dedicated token endpoint
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
