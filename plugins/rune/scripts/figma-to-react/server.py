"""
Figma-to-React MCP Server

A Model Context Protocol (MCP) stdio server that fetches Figma designs
and converts them into structured data for React component generation.

Thin adapter — delegates all business logic to core.py.

Provides 4 tools:
  - figma_fetch_design:     Fetch and parse a Figma design into IR tree
  - figma_inspect_node:     Inspect detailed properties of a specific node
  - figma_list_components:  List all components/instances in a file
  - figma_to_react:         Convert a Figma design to React + Tailwind CSS code

Environment variables:
  FIGMA_TOKEN              - Figma Personal Access Token (required)
  FIGMA_FILE_CACHE_TTL     - Cache TTL for file data in seconds (default: 1800)
  FIGMA_IMAGE_CACHE_TTL    - Cache TTL for image URLs in seconds (default: 86400)

Usage:
  # As MCP stdio server (normal mode via start.sh):
  python3 server.py
"""

import json
import logging
import re
import sys
import unicodedata
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations
from pydantic import Field, create_model
from pydantic import BaseModel

import core
from figma_client import FigmaAPIError, FigmaClient
from url_parser import FigmaURLError

# ---------------------------------------------------------------------------
# Elicitation schemas
# ---------------------------------------------------------------------------

# Component scope elicitation — used by figma_list_components when > 20 components
class ComponentCategoryFilter(BaseModel):
    """Filter components by category name keyword (empty = return all)."""
    category_filter: str = ""

# ---------------------------------------------------------------------------
# Logging — NEVER print to stdout (corrupts JSON-RPC protocol)
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("figma-to-react")


# ---------------------------------------------------------------------------
# Lifespan — shared FigmaClient
# ---------------------------------------------------------------------------


@asynccontextmanager
async def _lifespan(server: FastMCP) -> AsyncIterator[dict[str, Any]]:
    """Manage the shared FigmaClient lifecycle."""
    client = FigmaClient()
    try:
        yield {"figma_client": client}
    finally:
        await client.close()


# ---------------------------------------------------------------------------
# Server instance
# ---------------------------------------------------------------------------

mcp = FastMCP(
    "figma-to-react",
    lifespan=_lifespan,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_client(ctx: Context) -> FigmaClient:
    """Extract the shared FigmaClient from the MCP context."""
    try:
        return ctx.request_context.lifespan_context["figma_client"]
    except (AttributeError, KeyError, TypeError) as exc:
        raise ToolError(
            "Internal error: FigmaClient not available in server context."
        ) from exc


def _handle_figma_error(exc: FigmaAPIError) -> ToolError:
    """Convert a FigmaAPIError into a ToolError for MCP response."""
    return ToolError(str(exc))


# ---------------------------------------------------------------------------
# Frame elicitation helpers
# ---------------------------------------------------------------------------

_FRAME_LIKE_TYPES: frozenset[str] = frozenset(
    {"FRAME", "COMPONENT", "COMPONENT_SET", "SECTION"}
)

# Max frames shown in elicitation UI (prevent model field explosion)
_ELICIT_FRAME_THRESHOLD = 3
_ELICIT_FRAME_MAX = 50

# Maximum recursion depth for IR tree traversal (guards against adversarial Figma data)
_MAX_TREE_DEPTH = 10


def _sanitize_frame_name(name: str) -> str:
    """Strip non-printable characters and cap at 128 chars."""
    cleaned = "".join(c for c in name if unicodedata.category(c)[0] != "C")
    return cleaned[:128]


def _make_frame_field_key(name: str, idx: int) -> str:
    """Derive a safe Python identifier for use as a Pydantic field name."""
    safe = re.sub(r"[^a-zA-Z0-9]+", "_", name).strip("_") or "frame"
    return f"f{idx}_{safe[:40]}"


def _collect_top_level_frames(
    tree: dict[str, Any],
    _depth: int = 0,
) -> list[dict[str, Any]]:
    """Collect top-level FRAME-like nodes from a parsed IR tree dict.

    Handles three root shapes:
      - DOCUMENT → CANVAS children → FRAME grandchildren
      - CANVAS → FRAME children
      - FRAME directly (single-frame fetch with node-id URL)
    """
    if _depth > _MAX_TREE_DEPTH:
        logger.warning(
            "_collect_top_level_frames: max depth %d exceeded, stopping recursion",
            _MAX_TREE_DEPTH,
        )
        return []
    node_type = tree.get("type", "")
    if node_type == "DOCUMENT":
        frames: list[dict[str, Any]] = []
        for canvas in tree.get("children", []):
            frames.extend(_collect_top_level_frames(canvas, _depth + 1))
        return frames
    if node_type == "CANVAS":
        return [
            child
            for child in tree.get("children", [])
            if child.get("type") in _FRAME_LIKE_TYPES
        ]
    if node_type in _FRAME_LIKE_TYPES:
        return [tree]
    return []


def _filter_tree_frames(
    tree: dict[str, Any],
    selected_ids: set[str],
    _depth: int = 0,
) -> dict[str, Any]:
    """Return a shallow copy of tree with only selected frame node_ids retained.

    Filters at the CANVAS children level only (one level below DOCUMENT).
    Unrecognized root shapes are returned unchanged.
    """
    if _depth > _MAX_TREE_DEPTH:
        logger.warning(
            "_filter_tree_frames: max depth %d exceeded, returning node unfiltered",
            _MAX_TREE_DEPTH,
        )
        return tree
    node_type = tree.get("type", "")
    if node_type == "DOCUMENT":
        new_tree = dict(tree)
        new_tree["children"] = [
            _filter_tree_frames(child, selected_ids, _depth + 1)
            for child in tree.get("children", [])
        ]
        return new_tree
    if node_type == "CANVAS":
        new_tree = dict(tree)
        new_tree["children"] = [
            child
            for child in tree.get("children", [])
            if child.get("node_id") in selected_ids
        ]
        return new_tree
    return tree


# ---------------------------------------------------------------------------
# Tools — thin wrappers that delegate to core.py
# ---------------------------------------------------------------------------


@mcp.tool(annotations=ToolAnnotations(
    readOnlyHint=True, destructiveHint=False,
    idempotentHint=True, openWorldHint=True,
))
async def figma_fetch_design(
    url: str,
    ctx: Context,
    depth: int = 2,
    max_length: int = core.DEFAULT_MAX_LENGTH,
    start_index: int = core.DEFAULT_START_INDEX,
) -> str:
    """Fetch a Figma design and return its parsed node tree.

    Parses the Figma URL, fetches the file (with depth-limited traversal),
    converts the node tree to an intermediate representation (IR), and
    returns a JSON-serialized IR tree. If a node-id is in the URL, only
    that subtree is returned. Supports design system extraction, component
    inventory building, and design-to-code pipeline preprocessing.

    Large responses are paginated — use start_index to retrieve subsequent
    chunks.

    Args:
        url: Full Figma URL (e.g., https://www.figma.com/design/abc123/Title).
        ctx: MCP tool context (injected by FastMCP).
        depth: Figma API traversal depth (default 2).
        max_length: Max response characters (default 50000).
        start_index: Pagination offset (default 0).

    Returns:
        JSON string with the parsed IR tree and pagination metadata.
    """
    client = _get_client(ctx)
    try:
        result = await core.fetch_design(client, url, depth, max_length, start_index)
    except FigmaURLError as exc:
        raise ToolError(str(exc)) from exc
    except FigmaAPIError as exc:
        raise _handle_figma_error(exc) from exc

    # --- Frame selection elicitation (MCP SDK 2.x) ---
    # When a design has more than _ELICIT_FRAME_THRESHOLD top-level frames,
    # pause and ask the user to choose which ones to include in the response.
    # Falls back transparently on clients that don't support elicitation.
    try:
        content_str = result.get("content", "")
        if content_str:
            content_data = json.loads(content_str)
            tree = content_data.get("tree", {})
            frames = _collect_top_level_frames(tree)[:_ELICIT_FRAME_MAX]

            if len(frames) > _ELICIT_FRAME_THRESHOLD and hasattr(ctx, "elicit"):
                # Sanitize frame names before building the Pydantic model
                sanitized: list[tuple[str, str]] = [
                    (
                        f.get("node_id", f"id_{i}"),
                        _sanitize_frame_name(f.get("name", f"Frame {i + 1}")),
                    )
                    for i, f in enumerate(frames)
                ]
                field_keys: list[str] = [
                    _make_frame_field_key(name, i)
                    for i, (_, name) in enumerate(sanitized)
                ]
                fields: dict[str, Any] = {
                    key: (
                        bool,
                        Field(
                            default=True,
                            title=sanitized[i][1],
                            description=f"Include frame: {sanitized[i][1]} (id: {sanitized[i][0]})",
                        ),
                    )
                    for i, key in enumerate(field_keys)
                }
                FrameSelectionModel = create_model(  # type: ignore[call-overload]
                    "FrameSelection", **fields
                )

                frame_list = "\n".join(
                    f"  {i + 1}. {name}" for i, (_, name) in enumerate(sanitized)
                )
                elicit_result = await ctx.elicit(
                    message=(
                        f"Found {len(frames)} frames in this Figma design. "
                        f"Select which frames to include in the response:\n{frame_list}"
                    ),
                    schema=FrameSelectionModel,
                )

                if elicit_result.action == "accept" and elicit_result.data is not None:
                    selected_ids: set[str] = {
                        sanitized[i][0]
                        for i, key in enumerate(field_keys)
                        if getattr(elicit_result.data, key, False)
                    }
                    if not selected_ids:
                        raise ToolError(
                            "No frames were selected. Please select at least one frame "
                            "or decline the selection to return all frames."
                        )
                    if len(selected_ids) < len(frames):
                        content_data["tree"] = _filter_tree_frames(tree, selected_ids)
                        new_content = json.dumps(content_data, indent=2)
                        result = core.paginate_output(
                            new_content,
                            max_length=max_length,
                            start_index=start_index,
                        )
                elif elicit_result.action == "cancel":
                    raise ToolError("Frame selection cancelled by user.")
                # "decline" → return all frames without filtering
    except ToolError:
        raise
    except NotImplementedError:
        # Older Claude Code / clients without elicitation support — return all frames
        pass
    except (json.JSONDecodeError, ValueError, TypeError) as exc:
        logger.warning("Frame elicitation skipped due to parse error: %s", exc)

    return json.dumps(result)


@mcp.tool(annotations=ToolAnnotations(
    readOnlyHint=True, destructiveHint=False,
    idempotentHint=True, openWorldHint=True,
))
async def figma_inspect_node(
    url: str,
    ctx: Context,
) -> str:
    """Inspect detailed properties of a specific Figma node.

    Requires a Figma URL with a node-id query parameter. Returns
    detailed IR properties including auto-layout, styling, text content,
    and component references. Useful for extracting design tokens (colors,
    spacing, typography), responsive breakpoint analysis, and component
    variant inspection.

    Args:
        url: Figma URL with ?node-id=... (e.g., https://www.figma.com/design/abc/Title?node-id=1-3).
        ctx: MCP tool context (injected by FastMCP).

    Returns:
        JSON string with detailed node properties.
    """
    client = _get_client(ctx)
    try:
        result = await core.inspect_node(client, url)
        return json.dumps(result, indent=2)
    except (FigmaURLError, ValueError) as exc:
        raise ToolError(str(exc)) from exc
    except FigmaAPIError as exc:
        raise _handle_figma_error(exc) from exc


@mcp.tool(annotations=ToolAnnotations(
    readOnlyHint=True, destructiveHint=False,
    idempotentHint=True, openWorldHint=True,
))
async def figma_list_components(
    url: str,
    ctx: Context,
) -> str:
    """List all components and component instances in a Figma file.

    Fetches the file with depth=2, then walks the tree to find
    COMPONENT, COMPONENT_SET, and INSTANCE nodes. Detects duplicate
    instances pointing to the same component ID. Produces a component
    inventory for design system compliance checking, UI library matching,
    and Storybook story generation.

    When more than 20 components are found, elicits the user to optionally
    filter by category keyword before returning the full inventory.
    Backward-compatible: if elicitation is unsupported, returns all components.

    Args:
        url: Figma file URL (node-id optional; if provided, scopes to subtree).
        ctx: MCP tool context (injected by FastMCP).

    Returns:
        JSON string with component inventory including duplicates.
    """
    client = _get_client(ctx)
    try:
        result = await core.list_components(client, url)
    except FigmaURLError as exc:
        raise ToolError(str(exc)) from exc
    except FigmaAPIError as exc:
        raise _handle_figma_error(exc) from exc

    # Elicit component scope filter when inventory is large (> 20 components)
    components = result.get("components", [])
    component_count = len(components)
    category_filter: str | None = None

    if component_count > 20 and hasattr(ctx, "elicit"):
        # Sanitize component names before embedding in message (strip non-printable, cap)
        _MAX_NAMES = 50
        _MAX_NAME_LEN = 128
        sample_names: list[str] = []
        for comp in components[:_MAX_NAMES]:
            raw = comp.get("name", "") if isinstance(comp, dict) else ""
            sanitized = "".join(ch for ch in str(raw) if ch.isprintable())[:_MAX_NAME_LEN]
            if sanitized:
                sample_names.append(sanitized)

        sample_preview = ", ".join(sample_names[:10])
        elicit_msg = (
            f"This Figma file contains {component_count} components "
            f"(e.g. {sample_preview}{'…' if len(sample_names) > 10 else ''}). "
            "Enter a category keyword to filter results (e.g. 'Button', 'Card', 'Nav'), "
            "or leave empty to return all components."
        )

        try:
            elicit_result = await ctx.elicit(elicit_msg, ComponentCategoryFilter)
            if elicit_result.action == "accept" and elicit_result.data is not None:
                kw = elicit_result.data.category_filter.strip()
                if kw:
                    category_filter = kw
            # "decline" or "cancel" → return all components
        except NotImplementedError:
            # Elicitation not supported by this Claude Code version — return all components
            logger.debug("figma_list_components: elicitation not supported, returning all %d components", component_count)
        except Exception:
            # Unexpected error — log and proceed with full list (fail-open)
            logger.exception("figma_list_components: elicitation failed unexpectedly, returning all components")

    # Apply category filter if provided
    if category_filter:
        kw_lower = category_filter.lower()
        filtered = [
            comp for comp in components
            if kw_lower in str(comp.get("name", "") if isinstance(comp, dict) else "").lower()
        ]
        result = dict(result)
        result["components"] = filtered
        result["filtered_by"] = category_filter
        result["total_before_filter"] = component_count

    return json.dumps(result, indent=2)


async def _run_to_react(
    client: FigmaClient,
    url: str,
    component_name: str,
    use_tailwind: bool,
    extract_components: bool,
    aria: bool,
    max_length: int,
    start_index: int,
) -> str:
    """Invoke core.to_react and return JSON-serialized result.

    Args:
        client: Shared FigmaClient instance.
        url: Full Figma URL.
        component_name: Override component name (empty = auto-detect).
        use_tailwind: Whether to emit Tailwind CSS classes.
        extract_components: Extract repeated instances as sub-components.
        aria: Add ARIA attributes to JSX.
        max_length: Max response characters.
        start_index: Pagination offset.

    Returns:
        JSON string with generated React code and metadata.

    Raises:
        FigmaURLError: If the URL cannot be parsed.
        FigmaAPIError: If the Figma API call fails.
    """
    result = await core.to_react(
        client,
        url,
        component_name=component_name,
        use_tailwind=use_tailwind,
        extract_components=extract_components,
        aria=aria,
        max_length=max_length,
        start_index=start_index,
    )
    return json.dumps(result)


@mcp.tool(annotations=ToolAnnotations(
    readOnlyHint=True, destructiveHint=False,
    idempotentHint=True, openWorldHint=True,
))
async def figma_to_react(
    url: str,
    ctx: Context,
    component_name: str = "",
    use_tailwind: bool = True,
    extract_components: bool = False,
    aria: bool = False,
    max_length: int = core.DEFAULT_MAX_LENGTH,
    start_index: int = core.DEFAULT_START_INDEX,
) -> str:
    """Convert a Figma design to React + Tailwind CSS code.

    End-to-end pipeline: URL parsing -> Figma API fetch -> node parsing ->
    style extraction -> layout resolution -> React JSX generation.
    Generates reference-quality React JSX (50-60% fidelity) — use as search
    input for UI library matching (UntitledUI, shadcn/ui), not as production
    code. See _run_to_react for full parameter docs.

    Args:
        url: Full Figma URL (must include node-id for specific component).
        ctx: MCP tool context (injected by FastMCP).
        component_name: Override React component name (empty = auto-detect).
        use_tailwind: Generate Tailwind CSS classes (default True).
        extract_components: Extract repeated instances as sub-components.
        aria: Add ARIA accessibility attributes to generated JSX.
        max_length: Max response characters (default 50000).
        start_index: Pagination offset (default 0).

    Returns:
        JSON string with generated React code and metadata.
    """
    client = _get_client(ctx)
    try:
        return await _run_to_react(
            client, url, component_name, use_tailwind,
            extract_components, aria, max_length, start_index,
        )
    except FigmaURLError as exc:
        raise ToolError(str(exc)) from exc
    except FigmaAPIError as exc:
        raise _handle_figma_error(exc) from exc


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run()
