---
name: figma-to-react
description: |
  Figma-to-React MCP server knowledge. Provides 4 tools for converting
  Figma designs to React components with Tailwind CSS v4.
  Use when agents need to fetch Figma designs, inspect node properties,
  list components, or generate React + Tailwind code from design files.
  Trigger keywords: figma, design, react, component, tailwind, MCP,
  design-to-code, figma URL, figma API, component extraction.
user-invocable: false
disable-model-invocation: false
---

# Figma-to-React MCP Server

Converts Figma designs into React function components with Tailwind CSS v4 utility classes via 4 MCP tools.

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

Typical usage flow:

1. **Browse**: `figma_list_components(url)` to discover available components
2. **Inspect**: `figma_inspect_node(url?node-id=X)` to understand a specific node
3. **Generate**: `figma_to_react(url?node-id=X)` to produce React code
4. **Iterate**: Adjust generated code based on project conventions

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

When running `/rune:work` or `/rune:strive`, rune-smith worker Ashes have access to the figma-to-react MCP tools. Workers can call `figma_to_react`, `figma_inspect_node`, `figma_list_components`, and `figma_fetch_design` directly during implementation to generate component code from Figma designs without leaving the workflow.

## Configuration

Cache TTL environment variables (optional):
- `FIGMA_FILE_CACHE_TTL` (default: 1800 seconds / 30 min)
- `FIGMA_IMAGE_CACHE_TTL` (default: 86400 seconds / 24 hr)

## References

- [figma-workflow.md](references/figma-workflow.md) — Step-by-step usage guide for the 4 MCP tools
