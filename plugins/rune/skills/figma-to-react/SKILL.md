---
name: figma-to-react
description: |
  Figma visual intent extractor — MCP server knowledge for the 4 Figma tools.
  figma_to_react() produces REFERENCE CODE (~50-60% match), NOT production code.
  Its primary role in the design-sync pipeline is as a search input: the generated
  code is analyzed for component intent, which drives library MCP searches when a
  UI builder is available. Without a builder, it serves as a starting point for
  direct implementation.
  Builder protocol role: figma-to-react provides baseline visual extraction;
  builder MCPs (UntitledUI, shadcn/ui, custom) enhance with library-specific
  component matching via Phase 1.5 Component Match in design-sync. When a builder
  is active, figma_to_react() output is consumed as search input — not applied directly.
  Use when agents need to fetch Figma designs, inspect node properties,
  list components, or extract visual intent from design files.
  Trigger keywords: figma, design, react, component, tailwind, MCP,
  design-to-code, figma URL, figma API, component extraction, visual intent.
user-invocable: false
disable-model-invocation: false
---

# Figma-to-React MCP Server

Extracts visual intent from Figma designs and generates reference React + Tailwind CSS v4 code via 4 MCP tools.

> **CRITICAL**: `figma_to_react()` output is REFERENCE CODE (~50-60% match). It is NOT production-ready implementation. When a UI builder MCP is available, this output is analyzed for component intent and used as search queries against the real component library — NOT applied directly.

## Reference-as-Search-Input Pattern

```
WITHOUT builder (fallback):
  figma_to_react() → reference code → workers apply directly → ~50-60% match

WITH builder (preferred):
  figma_to_react() → reference code → ANALYZE intent → SEARCH library MCP
                   → MATCH real components → workers import REAL code → ~85-95% match
```

Example: `<nav className="w-64"><a>Dashboard</a></nav>` is analyzed as:
```
{ type: "sidebar", layout: "vertical", items: ["Dashboard"], icons: false }
→ search_components("sidebar navigation") → SidebarNavigation component
→ get_component("SidebarNavigation") → REAL component code
```

## Prerequisites

`FIGMA_TOKEN` is **optional** when using this MCP server via the Rune figma-to-react MCP.
The Rune MCP server bundles its own Figma API access and works without a personal token.

`FIGMA_TOKEN` is **required** only when:
- Using the **Official Figma MCP** (`mcp__claude_ai_Figma__*` tools)
- Running the `scripts/figma-to-react/cli.py` CLI directly against the Figma REST API

```bash
# Only needed for Official MCP or direct CLI usage:
export FIGMA_TOKEN="figd_..."
```

## MCP Tools

### figma_fetch_design

Fetch a Figma design and return its parsed intermediate representation (IR) tree.

```
figma_fetch_design(url="https://www.figma.com/design/abc123/MyApp?node-id=1-3")
```

**Parameters:**
- `url` (required): Full Figma URL
- `depth` (optional, default 2): API traversal depth
- `max_length` / `start_index`: Pagination for large responses

**Returns:** JSON with `file_key`, `node_count`, and `tree` (IR structure).

### figma_inspect_node

Inspect detailed properties of a specific Figma node including fills, strokes, effects, auto-layout, and text styles.

```
figma_inspect_node(url="https://www.figma.com/design/abc123/MyApp?node-id=1-3")
```

**Parameters:**
- `url` (required): Figma URL with `?node-id=...`

**Returns:** JSON with full node property detail (fills, strokes, effects, layout, text).

### figma_list_components

List all COMPONENT, COMPONENT_SET, and INSTANCE nodes in a Figma file. Detects duplicate instances (same component ID used multiple times).

```
figma_list_components(url="https://www.figma.com/design/abc123/MyApp")
```

**Returns:** JSON with `components`, `instances`, and `duplicate_instances`.

### figma_to_react

End-to-end conversion: Figma URL to React + Tailwind CSS code.

```
figma_to_react(
    url="https://www.figma.com/design/abc123/MyApp?node-id=1-3",
    component_name="MyButton",
    extract_components=true
)
```

**Parameters:**
- `url` (required): Figma URL (include `?node-id=...` for specific component)
- `component_name` (optional): Override React component name
- `use_tailwind` (optional, default true): Generate Tailwind CSS classes
- `extract_components` (optional, default false): Extract repeated instances as separate components
- `max_length` / `start_index`: Pagination

**Returns:** JSON with `main_component` (React code string) and optionally `extracted_components`.

## CLI: Direct Output Modes

The CLI (`scripts/figma-to-react/cli.py`) also supports direct code output without JSON wrapping:

### `--code` — Raw TSX to stdout

```bash
python3 cli.py react URL --code               # pipe-friendly raw TSX
python3 cli.py react URL --code > SignUp.tsx   # redirect to file
```

### `--write PATH` — Write .tsx file directly

```bash
# Auto-name from component (e.g., creates ./components/LoginForm.tsx)
python3 cli.py react URL --write ./components/

# Explicit filename
python3 cli.py react URL --write ./SignUp.tsx
```

**Validation:** `--code` and `--write` are mutually exclusive. Neither can be combined with `--output`.

## Workflow

### Without UI Builder (fallback — direct reference application)

1. **Browse**: `figma_list_components(url)` to discover available components
2. **Inspect**: `figma_inspect_node(url?node-id=X)` to understand a specific node
3. **Generate**: `figma_to_react(url?node-id=X)` to produce reference code (~50-60% match)
4. **Apply**: Workers use reference code as starting point, fix the ~40-50% gap manually

### With UI Builder (preferred — reference-as-search-input)

1. **Browse**: `figma_list_components(url)` to discover components
2. **Extract**: `figma_to_react(url?node-id=X)` to extract visual intent as reference code
3. **Analyze**: Parse reference code to extract component intents (sidebar, table, form, card...)
4. **Search**: Use intent as query for builder MCP (e.g., `search_components("sidebar navigation")`)
5. **Match**: Score results, select best match, retrieve real component via `get_component(name)`
6. **Compose**: Workers import real library components instead of approximating from reference

## Supported Features

- 12 Figma node types (FRAME, TEXT, RECTANGLE, ELLIPSE, GROUP, COMPONENT, INSTANCE, COMPONENT_SET, SECTION, VECTOR, BOOLEAN_OPERATION, IMAGE fills)
- Auto-layout v5 (horizontal, vertical, wrap, grid mode)
- Tailwind v4 classes (bg-linear-to-*, rounded-xs, shadow-xs)
- Color snapping to Tailwind palette (22 palettes, RGB distance < 20)
- Styled text segments (characterStyleOverrides merged)
- Icon candidate detection (vector nodes <=64x64)
- SVG candidate marking (BOOLEAN_OPERATION nodes)
- Image fill handling with placeholder resolution

## Rune Integration

When running `/rune:design-sync`, the figma-to-react MCP tools are used in Phase 1 (Design Extraction) to produce a reference code artifact. This reference code is stored as `tmp/design-sync/{timestamp}/figma-reference.tsx` and serves as visual intent input for Phase 1.5 (Component Match) when a UI builder is available.

**Role in design-sync pipeline**:
- Phase 1: `figma_to_react()` → `figma-reference.tsx` (reference artifact, ~50-60% match)
- Phase 1.5 (when builder available): reference analyzed for component intent → library MCP search
- Phase 2: workers receive either enriched VSM with real components (builder path) or reference code directly (fallback path)

When running `/rune:work` or `/rune:strive` directly, rune-smith worker Ashes also have access to these tools. In that context, treat `figma_to_react` output as reference only — use it to understand visual intent, not as final implementation code.

## Configuration

Cache TTL environment variables (optional):
- `FIGMA_FILE_CACHE_TTL` (default: 1800 seconds / 30 min)
- `FIGMA_IMAGE_CACHE_TTL` (default: 86400 seconds / 24 hr)

## References

- [figma-workflow.md](references/figma-workflow.md) — Step-by-step usage guide for the 4 MCP tools
