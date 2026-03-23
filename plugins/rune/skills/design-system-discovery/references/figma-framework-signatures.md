# Figma Framework Signature Registry

Module-level constant registry mapping UI framework identifiers to their Figma API
metadata patterns. Used by `discoverFigmaFramework()` (see [figma-framework-detection.md](figma-framework-detection.md))
to identify which UI library a Figma design references.

## Signal Weights

Each signal category has a fixed weight reflecting its discriminative power.
Total weights sum to 1.0 (excluding remote flag bonus).

| Signal Category | Weight | Description |
|-----------------|--------|-------------|
| Component naming | 0.35 | Component set names from `node.componentSets` |
| Variant props | 0.25 | Variant axis names from `node.components` (entries containing `=`) |
| Icon naming | 0.15 | Component names matching icon heuristic (kebab-case, no `=`, no `/`) |
| Typography styles | 0.10 | Style entries with `styleType === "TEXT"` |
| Effect/fill styles | 0.05 | Style entries with `styleType` in `["EFFECT", "FILL"]` |
| Remote flag | 0.10 | Bonus when >80% of components have `remote: true` |

## Icon Heuristic (`isIconLike`)

A component name is classified as icon-like when ALL of the following hold:

```
function isIconLike(name):
  RETURN regex(/^[a-z][a-z0-9-]*(-[a-z0-9]+)*$/).test(name)
         AND NOT name.contains("=")
         AND NOT name.contains("/")
         AND name.length <= 40
```

Examples of icon-like names: `arrow-left`, `home-line`, `stars-03`, `log-out-04`, `chevron-right`.
Examples of non-icon names: `Size=md, Hierarchy=Primary`, `Buttons/Button`, `_Breadcrumb button base`.

## FRAMEWORK_SIGNATURES

Registry is a module-level constant. Each entry defines regex patterns per signal category.
Patterns are compiled once at load time (BACK-001: avoids per-call regex compilation).

### untitled_ui

UntitledUI uses hierarchical component naming with PascalCase categories,
multi-axis variant props (`Size`, `Hierarchy`, `State`), and kebab-case icon names.

```
FRAMEWORK_SIGNATURES["untitled_ui"] = {
  component_patterns: [
    /^Buttons\/Button$/,
    /^(Page header|Breadcrumbs|Pagination|Select|Avatar group|Badge|Tooltip|Modal)$/,
    /^_[A-Z].*base$/,                   // Internal base components: "_Breadcrumb button base"
    /^(Metric item|Feature icon|Header section|Footer)/,
    /^(Input field|Textarea|Checkbox|Radio|Toggle|Dropdown)/,
    /^(Sidebar navigation|Header navigation|Command menu|Slideout menu)$/,  // Application UI — unique compound names
    /^(Featured icon|Badge group|Button group|Rating badge)$/,              // Unique to UntitledUI
    /^(Metric item|Activity feed|Progress steps|Content divider)$/,        // Specific naming
  ],

  variant_patterns: [
    /Size=(xs|sm|md|lg|xl|2xl)/,
    /Hierarchy=(Primary|Secondary|Tertiary|Link|Link color)/,
    /State=(Default|Hover|Focused|Disabled)/,
    /Breakpoint=(Mobile|Desktop)/,
    /Color=(Primary|Gray|Error|Warning|Success)/,
    /Type=(Filled|Light|Outline)/,
    /Destructive=(True|False)/,           // UntitledUI-specific boolean variant
    /Dot=(True|False)/,                   // Badge-specific
    /SupportingText=(True|False)/,        // Input-specific
  ],

  icon_patterns: [
    /^[a-z]+-[a-z0-9]+(-[a-z0-9]+)*$/,  // kebab-case: "arrow-left", "log-out-04"
  ],

  typography_patterns: [
    /^(Text|Display) (xs|sm|md|lg|xl)\/(Regular|Medium|Semibold|Bold)$/,
  ],

  style_patterns: [
    /^Shadows\/shadow-(xs|sm|md|lg|xl)/,
    /^Gradient\/(skeuemorphic|Linear)/,
    /^Colors\//,
  ],

  // Conclusive signals — weight 1.0, bypasses scoring when matched
  conclusive_signals: [
    /[_\s]UntitledUI\b/i,                // Library name containing "_UntitledUI" or "UntitledUI"
    /\bUntitled\s*UI\b/i,                // Library name containing "Untitled UI" (with optional space)
  ],
}
```

### shadcn_ui

shadcn/ui uses flat single-word component names, lowercase variant props
(`variant`, `size`), and Lucide icon references.

```
FRAMEWORK_SIGNATURES["shadcn_ui"] = {
  component_patterns: [
    /^(Button|Card|Dialog|Input|Select|Table|Badge|Avatar|Sheet|Tabs|Toast)$/,
    /^(Accordion|Alert|AlertDialog|Calendar|Checkbox|Collapsible)$/,
    /^(Command|ContextMenu|DropdownMenu|HoverCard|Label|Menubar)$/,
    /^(NavigationMenu|Popover|Progress|RadioGroup|ScrollArea|Separator)$/,
    /^(Skeleton|Slider|Switch|Textarea|Toggle|ToggleGroup|Tooltip)$/,
  ],

  variant_patterns: [
    /variant=(default|destructive|outline|secondary|ghost|link)/,
    /size=(default|sm|lg|icon)/,
  ],

  icon_patterns: [
    /^(Lucide|lucide-react)\//,
    /^(Icon|icon)\//,
  ],

  typography_patterns: [],   // shadcn uses Tailwind typography, no Figma text styles

  style_patterns: [],        // shadcn uses CSS variables, no Figma effect styles
}
```

### material_ui

Material UI (MUI) uses `Mui` prefix component naming, `contained`/`outlined`/`text`
variant system, and `Mui*Icon` icon naming.

```
FRAMEWORK_SIGNATURES["material_ui"] = {
  component_patterns: [
    /^Mui[A-Z]/,
    /^Material\/[A-Z]/,
    /^(AppBar|Drawer|Snackbar|Stepper|Chip|Fab|SpeedDial)$/,
    /^(DataGrid|TreeView|DatePicker|TimePicker)$/,
  ],

  variant_patterns: [
    /variant=(contained|outlined|text|filled|standard)/,
    /color=(primary|secondary|error|warning|info|success|inherit)/,
    /size=(small|medium|large)/,
  ],

  icon_patterns: [
    /^Mui[A-Z].*Icon$/,
    /^(Filled|Outlined|Rounded|Sharp|TwoTone)\//,
  ],

  typography_patterns: [
    /^typography\/(h[1-6]|body[12]|subtitle[12]|caption|overline|button)$/,
  ],

  style_patterns: [
    /^elevation\/[0-9]+$/,
    /^palette\/(primary|secondary|error|warning|info|success)/,
  ],
}
```

### ant_design

Ant Design uses `Ant` prefix or `ant-` prefix naming, `type` variant prop,
and built-in icon system.

```
FRAMEWORK_SIGNATURES["ant_design"] = {
  component_patterns: [
    /^Ant[A-Z]/,
    /^ant-/,
    /^(Breadcrumb|Cascader|ColorPicker|DatePicker|Descriptions)$/,
    /^(Form|Layout|Menu|Pagination|Result|Segmented|Space|Steps|Timeline|Transfer|TreeSelect|Upload)$/,
  ],

  variant_patterns: [
    /type=(primary|default|dashed|text|link)/,
    /size=(large|middle|small)/,
    /status=(success|processing|error|default|warning)/,
  ],

  icon_patterns: [
    /^(Outlined|Filled|TwoTone)[A-Z]/,     // AntD icon naming convention
  ],

  typography_patterns: [
    /^Typography\/(Title|Text|Paragraph|Link)/,
  ],

  style_patterns: [],        // Ant Design uses design tokens, minimal Figma style usage
}
```

## Extensibility

To add a new framework signature:

1. Add a new entry to `FRAMEWORK_SIGNATURES` following the structure above
2. Each entry requires all 5 pattern arrays (use empty `[]` when a category has no patterns)
3. Patterns should be specific enough to avoid false positives with other frameworks
4. Test against real Figma files using the matching algorithm in [figma-framework-detection.md](figma-framework-detection.md)

## Cross-Reference: Signal Category to Figma API Fields

| Signal Category | Figma API Source | Field Path |
|-----------------|------------------|------------|
| Component naming | `node.componentSets` | `values(componentSets).map(c => c.name)` |
| Variant props | `node.components` | `values(components).map(c => c.name)` — entries containing `=` |
| Icon naming | `node.components` | `values(components).filter(isIconLike).map(c => c.name)` |
| Typography styles | `node.styles` | `values(styles).filter(s => s.styleType === "TEXT").map(s => s.name)` |
| Effect/fill styles | `node.styles` | `values(styles).filter(s => s.styleType in ["EFFECT", "FILL"]).map(s => s.name)` |
| Remote flag | `node.components` | `values(components).filter(c => c.remote).length / total` |

## Match Detail Limits

To prevent unbounded output, cap `matchDetails` arrays at 10 entries per category (BACK-004).
When more than 10 entries match, include the first 10 and append a count suffix:
`matchDetails.components = firstTen.concat(["... and N more"])`.
