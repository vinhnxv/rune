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
import sys
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations

import core
from figma_client import FigmaAPIError, FigmaClient
from url_parser import FigmaURLError

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
    that subtree is returned.

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
        return json.dumps(result)
    except FigmaURLError as exc:
        raise ToolError(str(exc)) from exc
    except FigmaAPIError as exc:
        raise _handle_figma_error(exc) from exc


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
    and component references.

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
    instances pointing to the same component ID.

    Args:
        url: Figma file URL (node-id optional; if provided, scopes to subtree).
        ctx: MCP tool context (injected by FastMCP).

    Returns:
        JSON string with component inventory including duplicates.
    """
    client = _get_client(ctx)
    try:
        result = await core.list_components(client, url)
        return json.dumps(result, indent=2)
    except FigmaURLError as exc:
        raise ToolError(str(exc)) from exc
    except FigmaAPIError as exc:
        raise _handle_figma_error(exc) from exc


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
    See _run_to_react for full parameter docs.

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
