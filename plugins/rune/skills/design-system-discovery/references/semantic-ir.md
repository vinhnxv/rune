# Semantic IR Schema

Library-agnostic intermediate representation for Figma-extracted components.
Sits between `figma_to_react` output (raw JSX) and library adapters (UntitledUI, shadcn/ui, Tailwind).

```
figma_to_react output (raw JSX) → IR Extraction → SemanticComponent[] → Library Adapter → Final Code
```

## SemanticComponent Interface

```
// Pseudocode — NOT implementation code
interface SemanticComponent {
  // Component classification
  type: ComponentType
  intent: ComponentIntent
  size: ComponentSize
  state: ComponentState

  // Icon slots
  icons: {
    leading?: string    // Figma icon name: "arrow-left"
    trailing?: string   // Figma icon name: "arrow-right"
  }

  // Content — v1 uses flat passthrough (see §Children/Nesting)
  children: string | null

  // Additional Figma-extracted properties not covered by structured fields
  props: Record<string, string | number | boolean>

  // Source metadata for traceability
  source: {
    figmaNodeId: string       // Figma node ID this was extracted from
    figmaComponentName: string // Original Figma component name
    confidence: number        // 0.0-1.0 extraction confidence
  }
}
```

## Type Enum (`ComponentType`)

Core component types supported by the IR. Adapters MUST handle all types;
unhandled types fall through to Tailwind fallback with a warning comment.

```
ComponentType =
  // Initial 8 (v1.0)
  | "button"
  | "input"
  | "select"
  | "badge"
  | "card"
  | "breadcrumb"
  | "pagination"
  | "avatar-group"

  // Extended types (DEPTH-004)
  | "dialog"
  | "table"
  | "tabs"
  | "toast"
  | "checkbox"
  | "tooltip"
  | "dropdown-menu"

  // Extended types (v2.12.0)
  | "toggle"
  | "radio"
  | "textarea"
  | "slider"
  | "progress"
  | "alert"
  | "sidebar"
  | "file-upload"
```

**Alias**: `"modal"` is NOT a separate type — it is an alias for `"dialog"`.
During IR extraction, `classifyComponentType()` normalizes `"modal"` → `"dialog"`.
This prevents adapter duplication while preserving Figma naming conventions.

**Fallback rule**: When an adapter does not implement a `ComponentType`, the code generator
MUST fall through to the Tailwind fallback adapter and emit a warning comment:
`// TODO: {type} not yet supported by {adapter.name} — using Tailwind fallback`

## Intent Enum (`ComponentIntent`)

Semantic purpose of the component. Maps to library-specific variant/color props.

```
ComponentIntent =
  // Action intents (buttons, links)
  | "primary"
  | "secondary"
  | "tertiary"
  | "destructive"
  | "link"
  | "ghost"

  // Feedback intents (DEPTH-005) — for badge, toast, alert components
  | "success"
  | "warning"
  | "info"
  | "error"
```

**Mapping guidance**: Action intents map to button `variant`/`color` props.
Feedback intents map to badge/toast/alert `status`/`variant` props.
See adapter files for per-library mappings.

## Size Enum (`ComponentSize`)

```
ComponentSize =
  | "xs"
  | "sm"
  | "md"
  | "lg"
  | "xl"
  | "2xl"
```

**Default**: `"md"` when size cannot be determined from Figma metadata.

## State Enum (`ComponentState`)

```
ComponentState =
  // Core states (v1.0)
  | "default"
  | "hover"
  | "focused"
  | "disabled"
  | "loading"

  // Extended states (DEPTH-006)
  | "active"
  | "selected"
  | "error"
  | "readonly"
  | "indeterminate"
```

**Null state handling**: When an adapter's `stateProps` mapping returns `null` for a state
(e.g., shadcn has no built-in `loading` prop), the adapter MUST:
1. Omit the state prop from generated JSX
2. Emit a comment: `// Note: "{state}" state not natively supported by {library}`

## Children / Nesting (DEPTH-009)

**v1 is flat with `{children}` passthrough.**

The IR does not support recursive `SemanticComponent[]` nesting in v1. Instead:

- `children` is a `string | null` containing text content or a `{children}` placeholder
- Compound components (e.g., shadcn `<Select>`) are handled by the adapter's `composability` pattern,
  not by IR nesting
- The adapter is responsible for wrapping flat IR into subcomponent hierarchies when needed

**Rationale**: Recursive IR adds traversal complexity without proportional benefit in v1.
Most Figma components map to single library components with props. Compound structures
(Select, Dialog, Table) have library-specific subcomponent patterns that cannot be
generalized into a recursive IR without per-library knowledge.

**Future extension**: v2 may introduce `children: string | SemanticComponent[]` with
depth-first recursive traversal. This would require adapters to implement a
`renderChildren(children: SemanticComponent[]): string` method.

## IR Extraction Step

The IR extraction step transforms raw `figma_to_react` output into `SemanticComponent[]`.
This is NOT a pass-through — it requires semantic analysis of the JSX output.

```
// Pseudocode — NOT implementation code
function extractSemanticIR(figmaToReactOutput, figmaApiResponse, nodeId):
  // Guard: validate inputs
  IF figmaToReactOutput is null OR figmaApiResponse is null:
    RETURN { components: [], confidence: 0.0, error: "missing_input" }

  node = figmaApiResponse.nodes[nodeId]
  IF node is null:
    RETURN { components: [], confidence: 0.0, error: "node_not_found" }

  components = []
  rawJSX = figmaToReactOutput.code

  // Step 1: Identify component boundaries in raw JSX
  // Look for top-level JSX elements that map to known ComponentTypes
  elements = parseJSXElements(rawJSX)

  // Step 2: Classify each element
  FOR element IN elements:
    type = classifyComponentType(element.tagName, element.className)
    IF type is null:
      CONTINUE  // Skip non-component elements (wrappers, containers)

    // Step 3: Extract intent from Figma variant metadata
    intent = extractIntent(element, node.components, node.componentSets)

    // Step 4: Extract size from Figma variant or CSS classes
    size = extractSize(element, node.components) ?? "md"

    // Step 5: Extract state
    state = extractState(element, node.components) ?? "default"

    // Step 6: Extract icons
    icons = extractIcons(element, node.components)

    // Step 7: Extract text content
    children = extractTextContent(element) ?? null

    components.push({
      type,
      intent,
      size,
      state,
      icons,
      children,
      props: extractAdditionalProps(element),
      source: {
        figmaNodeId: element.sourceNodeId ?? nodeId,
        figmaComponentName: element.sourceName ?? element.tagName,
        confidence: calculateExtractionConfidence(type, intent, size)
      }
    })

  overallConfidence = components.length > 0
    ? average(components.map(c => c.source.confidence))
    : 0.0

  RETURN {
    components,
    confidence: overallConfidence,
    componentCount: components.length,
    unmappedElements: elements.length - components.length
  }
```

### Component Type Classification

```
// Pseudocode — NOT implementation code
function classifyComponentType(tagName, className):
  // Direct tag name matching
  TAG_MAP = {
    "button": "button",  "Button": "button",
    "input": "input",    "Input": "input",
    "select": "select",  "Select": "select",
    "table": "table",    "Table": "table",
    "dialog": "dialog",  "Dialog": "dialog",
    "textarea": "textarea", "Textarea": "textarea",
    "progress": "progress", "Progress": "progress",
    "toggle": "toggle",  "Toggle": "toggle",
    "radio": "radio",    "Radio": "radio",
    "slider": "slider",  "Slider": "slider",
    "alert": "alert",    "Alert": "alert",
    "sidebar": "sidebar", "Sidebar": "sidebar",
    // Alias: "modal" normalizes to "dialog" (v2.12.0)
    "modal": "dialog",   "Modal": "dialog",
  }
  IF TAG_MAP.has(tagName): RETURN TAG_MAP[tagName]

  // Class-based heuristics (from figma_to_react Tailwind output)
  // IMPORTANT: Iteration order matters — toast MUST be checked before alert
  // to ensure fixed/absolute-positioned elements classify as toast, not alert.
  CLASS_PATTERNS = {
    "badge": /inline-flex.*rounded-full|badge/,
    "card": /rounded-.*shadow|border.*p-[46]/,
    "breadcrumb": /breadcrumb|nav.*ol.*li/,
    "pagination": /pagination|page.*prev.*next/,
    "avatar-group": /avatar.*-space-x|flex.*rounded-full/,
    "tabs": /tab-.*active|role="tablist"/,
    "toast": /toast|alert.*fixed/,
    "checkbox": /checkbox|type="checkbox"/,
    "tooltip": /tooltip|role="tooltip"/,
    "dropdown-menu": /dropdown|role="menu"/,
    // Extended types (v2.12.0)
    "toggle": /\btoggle\b|role="switch"/,
    "radio": /\bradio\b|role="radio"|type="radio"/,
    "textarea": /\btextarea\b|\bmultiline\b/,
    "slider": /\bslider\b|type="range"|role="slider"/,
    "progress": /\bprogress\b|role="progressbar"|\bmeter\b/,
    "alert": /alert(?!.{0,200}(fixed|absolute))|role="alert"|banner/,
    "sidebar": /\bsidebar\b|\baside\b|\bdrawer\b|nav.*w-\d{2,3}/,
    "file-upload": /file-upload|dropzone|type="file"|drag.*drop/,
  }
  FOR type, pattern IN CLASS_PATTERNS:
    IF pattern.test(className): RETURN type

  RETURN null  // Not a recognized component

// Exclusion guard: alert vs toast overlap (v2.12.0)
// Both alert and toast can match "alert" in class names.
// Disambiguation rule: if BOTH match, check for positional CSS.
// Fixed/absolute positioning → toast (transient notification).
// Static/relative positioning → alert (inline feedback).
// The "alert" pattern uses bounded negative lookahead (?!.{0,200}(fixed|absolute))
// to exclude fixed/absolute-positioned elements, classified as "toast" instead.
// Bounded quantifier (.{0,200}) prevents ReDoS on long input strings.
```

### Extended Types (v2.12.0)

8 new `ComponentType` values added in v2.12.0:

| Type | Semantic Role | Key Patterns |
|------|--------------|--------------|
| `toggle` | On/off switch control | Matches `role="switch"`, Figma `Toggle`/`Switch` components |
| `radio` | Single-selection from group | Matches `role="radio"`, `type="radio"` |
| `textarea` | Multi-line text input | Matches `<textarea>` tag, `multiline` class |
| `slider` | Numeric range input | Matches `role="slider"`, `type="range"` |
| `progress` | Determinate/indeterminate progress | Matches `role="progressbar"`, `<meter>` |
| `alert` | Inline feedback message | Matches `role="alert"`, `banner`; excludes fixed/absolute-positioned (→ toast) |
| `sidebar` | Persistent navigation panel | Matches `<aside>`, `drawer`, wide `<nav>` elements |
| `file-upload` | File input with drag-and-drop | Matches `dropzone`, `type="file"`, drag-and-drop patterns |

**Normalization**: `"modal"` is an alias for `"dialog"` — see TAG_MAP. During IR extraction,
`classifyComponentType()` normalizes modal → dialog to prevent adapter duplication.

**Alert/Toast disambiguation**: Both types may contain "alert" in class names. The alert regex
uses a bounded negative lookahead `(?!.{0,200}(fixed|absolute))` to exclude positionally-fixed
elements, which are classified as `toast` instead. CLASS_PATTERNS iteration order is significant:
toast must be checked before alert.

### Intent Extraction from Figma Variants

```
// Pseudocode — NOT implementation code
function extractIntent(element, components, componentSets):
  // Check Figma component variant props
  // UntitledUI: "Hierarchy=Primary" → "primary"
  // shadcn: "variant=destructive" → "destructive"
  variantName = findVariantProp(element.sourceNodeId, components)

  INTENT_PATTERNS = {
    "primary": /primary|default|contained/i,
    "secondary": /secondary|outline/i,
    "tertiary": /tertiary|ghost|text/i,
    "destructive": /destructive|danger|error/i,
    "link": /link/i,
    "ghost": /ghost|plain/i,
    "success": /success/i,
    "warning": /warning|warn/i,
    "info": /info|informational/i,
    "error": /error|critical/i,
  }

  FOR intent, pattern IN INTENT_PATTERNS:
    IF pattern.test(variantName): RETURN intent

  RETURN "primary"  // Default intent
```

## IR Output Schema

The complete extraction output returned by `extractSemanticIR()`:

```yaml
# SemanticIR output (in-memory, not written to file)
components:
  - type: "button"
    intent: "primary"
    size: "md"
    state: "default"
    icons:
      leading: "arrow-left"
      trailing: null
    children: "Back"
    props:
      fullWidth: false
    source:
      figmaNodeId: "1234:5678"
      figmaComponentName: "Buttons/Button"
      confidence: 0.90

  - type: "badge"
    intent: "success"
    size: "sm"
    state: "default"
    icons:
      leading: "check-circle"
      trailing: null
    children: "Active"
    props: {}
    source:
      figmaNodeId: "1234:9012"
      figmaComponentName: "Badge"
      confidence: 0.85

confidence: 0.875         # Average of per-component confidence
componentCount: 2
unmappedElements: 3        # JSX elements not mapped to IR types
```

## Adapter Contract

Every library adapter that consumes SemanticIR MUST implement:

```
// Pseudocode — NOT implementation code
interface LibraryAdapter {
  // Metadata
  name: string                       // "untitled_ui" | "shadcn_ui" | "tailwind"
  package: string | null             // npm package or "copy-paste"
  iconPackage: string | null         // Icon library package name
  importStyle: string | null         // Import path pattern

  // Component generation
  composability: "flat" | "compound" | "inline"

  // Per-type variant mappings
  // Each key is a ComponentType with:
  //   propName: string — the variant prop name
  //   variants: Record<ComponentIntent, string> — intent → prop value
  //   sizeProp: string — the size prop name
  //   sizes: Record<ComponentSize, string> — size → prop value
  //   iconProps: { leading: string, trailing: string }
  //   stateProps: Record<ComponentState, string | null>
  button: AdapterTypeMapping
  input: AdapterTypeMapping
  select: AdapterTypeMapping
  badge: AdapterTypeMapping
  // ... (all ComponentType values)

  // Icon name mapping: Figma name → library import name
  // 10-entry curated fast-path per adapter (see icon-mapping.md)
  // Unmapped icons use fallback: kebab-to-PascalCase ("arrow-left" → "ArrowLeft")
  //   with comment: "// TODO: verify icon import"
  iconMap: Record<string, string>
}
```

### AdapterTypeMapping Interface

```
// Pseudocode — NOT implementation code
interface AdapterTypeMapping {
  propName: string                              // e.g., "variant", "color"
  variants: Record<ComponentIntent, string>     // Intent → prop value
  sizeProp: string                              // e.g., "size"
  sizes: Record<ComponentSize, string>          // Size → prop value
  iconProps: { leading: string, trailing: string }
  stateProps: Record<ComponentState, string | null>  // null = not supported
}
```

## Unmapped Icon Fallback (DEPTH-002)

When an icon name is not in the adapter's `iconMap`, apply this fallback chain:

```
// Pseudocode — NOT implementation code
function resolveIconName(figmaName, adapter):
  // Step 1: Check curated map
  IF adapter.iconMap.has(figmaName):
    RETURN adapter.iconMap[figmaName]

  // Step 2: Fallback — kebab-to-PascalCase conversion
  // "arrow-left" → "ArrowLeft"
  // "log-out-04" → "LogOut04"
  pascalName = figmaName
    .split("-")
    .map(segment =>
      // Preserve numeric segments: "04" stays "04"
      IF isNumeric(segment): segment
      ELSE: capitalize(segment)
    )
    .join("")

  // Step 3: Emit verification comment
  RETURN {
    name: pascalName,
    verified: false,
    comment: "// TODO: verify icon import — auto-converted from '{figmaName}'"
  }
```

## Extension Protocol

To add a new `ComponentType`:

1. Add the type string to the `ComponentType` union in this file
2. Add classification rules to `classifyComponentType()` — tag name and/or class pattern
3. Add `AdapterTypeMapping` entries to each adapter file (UntitledUI, shadcn, Tailwind)
4. If the type requires new intents or states, extend those enums and update all adapters
5. Update `icon-mapping.md` if the type introduces new icon categories

To add a new library adapter:

1. Create `references/{library-name}-adapter.md` following the `LibraryAdapter` interface
2. Add the adapter to `selectAdapter()` in the code generation pipeline
3. Add framework signatures to `figma-framework-signatures.md` for Figma-side detection
4. Add icon mappings to `icon-mapping.md`

## Cross-References

- [figma-framework-signatures.md](figma-framework-signatures.md) — Figma-side framework detection patterns
- [figma-framework-detection.md](figma-framework-detection.md) — Detection algorithm using signatures
- [icon-mapping.md](icon-mapping.md) — Cross-library icon name mappings
- [ui-builder-discovery.md](ui-builder-discovery.md) — MCP builder detection for library search
