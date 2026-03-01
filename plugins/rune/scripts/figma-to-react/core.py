"""
Figma-to-React Core Business Logic

Pure async functions with zero MCP dependency. Used by both the MCP
server (server.py) and the CLI (cli.py) as thin adapters.

All functions take a FigmaClient as the first parameter — the caller
manages the client lifecycle.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from figma_client import FigmaClient, FigmaAPIError  # noqa: F401
from figma_types import NodeType
from image_handler import collect_image_refs
from node_parser import FigmaIRNode, count_nodes, parse_node, walk_tree
from react_generator import generate_component
from url_parser import FigmaURLError, parse_figma_url  # noqa: F401

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Pagination defaults
# ---------------------------------------------------------------------------

DEFAULT_MAX_LENGTH = 50_000  # characters
DEFAULT_START_INDEX = 0

# BACK-004: Schema version for public API response dicts.
# Bump when the response shape changes (new fields, removed fields, type changes).
RESPONSE_SCHEMA_VERSION = 1


# ---------------------------------------------------------------------------
# Helpers (moved from server.py — pure, no MCP dependency)
# ---------------------------------------------------------------------------


def ir_to_dict(node: FigmaIRNode, max_depth: int = 20) -> dict[str, Any]:
    """Convert an IR node tree to a JSON-serializable dict.

    Recursively serializes the IR tree, omitting None values and
    the raw Figma data to keep output compact.
    """
    if max_depth <= 0:
        return {"node_id": node.node_id, "name": node.name, "truncated": True}

    result: dict[str, Any] = {
        "node_id": node.node_id,
        "name": node.name,
        "type": node.node_type.value,
        "unique_name": node.unique_name,
    }

    # Geometry
    if node.width is not None or node.height is not None:
        result["width"] = round(node.width or 0.0, 1)
        result["height"] = round(node.height or 0.0, 1)

    # Visibility
    if not node.visible:
        result["visible"] = False
    if node.opacity < 1.0:
        result["opacity"] = round(node.opacity, 3)

    # Flags
    for flag_name in (
        "is_frame_like", "is_svg_candidate", "is_icon_candidate",
        "is_absolute_positioned", "has_auto_layout", "has_image_fill",
    ):
        val = getattr(node, flag_name, False)
        if val:
            result[flag_name] = True

    # Auto-layout
    if node.has_auto_layout:
        result["layout_mode"] = node.layout_mode.value
        if node.item_spacing:
            result["item_spacing"] = node.item_spacing
        if node.primary_axis_align:
            result["primary_axis_align"] = node.primary_axis_align.value
        if node.counter_axis_align:
            result["counter_axis_align"] = node.counter_axis_align.value
        if any(p > 0 for p in node.padding):
            result["padding"] = node.padding

    # Sizing
    if node.layout_sizing_horizontal:
        result["layout_sizing_horizontal"] = node.layout_sizing_horizontal.value
    if node.layout_sizing_vertical:
        result["layout_sizing_vertical"] = node.layout_sizing_vertical.value

    # Corner radius
    if node.corner_radius:
        result["corner_radius"] = node.corner_radius
    if node.corner_radii:
        result["corner_radii"] = node.corner_radii

    # Text
    if node.text_content is not None:
        result["text_content"] = node.text_content
        if node.text_style and node.text_style.font_family:
            result["font_family"] = node.text_style.font_family
            if node.text_style.font_size:
                result["font_size"] = node.text_style.font_size

    # Component
    if node.component_id:
        result["component_id"] = node.component_id

    # Image
    if node.image_ref:
        result["image_ref"] = node.image_ref

    # SVG geometry
    if node.fill_geometry:
        result["fill_geometry_count"] = len(node.fill_geometry)
    if node.stroke_geometry:
        result["stroke_geometry_count"] = len(node.stroke_geometry)

    # Children
    if node.children:
        result["children"] = [
            ir_to_dict(child, max_depth - 1) for child in node.children
        ]

    return result


def extract_react_code(result: dict[str, Any]) -> str:
    """Extract raw React/TSX code from a to_react() paginated result.

    The to_react() function returns a paginated dict with a 'content' key
    containing a JSON string. Inside that JSON is 'main_component' with the
    actual React code. This helper unwraps both layers.
    """
    content = result.get("content")
    if isinstance(content, str):
        inner = json.loads(content)
    else:
        inner = result
    return inner.get("main_component", "")


def paginate_output(
    content: str,
    *,
    max_length: int = DEFAULT_MAX_LENGTH,
    start_index: int = DEFAULT_START_INDEX,
) -> dict[str, Any]:
    """Apply pagination to large output strings."""
    total_length = len(content)
    end_index = min(start_index + max_length, total_length)
    chunk = content[start_index:end_index]

    result: dict[str, Any] = {"content": chunk}
    if total_length > max_length:
        result["total_length"] = total_length
        result["start_index"] = start_index
        result["end_index"] = end_index
        if end_index < total_length:
            result["has_more"] = True
            result["next_start_index"] = end_index

    return result


# Valid export formats for the Figma Images API (WS-4)
_VALID_IMAGE_FORMATS: frozenset[str] = frozenset({"png", "svg", "jpg", "pdf"})

# Max recursion depth for _collect_svg_fallback_ids (WS-8)
_MAX_SVG_SCAN_DEPTH = 100


def _collect_svg_fallback_ids(node: FigmaIRNode, _depth: int = 0) -> list[str]:
    """Collect node IDs of SVG candidates that have no fill or stroke geometry.

    These are nodes that need a Figma Images API SVG export because they have no
    inline path data available. Stops recursing into SVG candidates themselves (DS-6)
    to avoid redundant sub-tree exports.

    Args:
        node: IR node to scan.
        _depth: Internal recursion depth counter (WS-8).

    Returns:
        List of unique node ID strings for geometry-less SVG candidates.
    """
    if _depth > _MAX_SVG_SCAN_DEPTH:
        return []

    result: list[str] = []

    if node.is_svg_candidate and not node.fill_geometry and not node.stroke_geometry:
        # Collect this node — and also recurse into children (VEIL-004)
        # to find nested geometry-less SVG candidates
        result.append(node.node_id)
        for child in node.children:
            result.extend(_collect_svg_fallback_ids(child, _depth + 1))
        return result

    # Not an SVG candidate (or has geometry) — recurse into children
    for child in node.children:
        result.extend(_collect_svg_fallback_ids(child, _depth + 1))

    return result


async def _get_images_with_retry(
    client: FigmaClient,
    file_key: str,
    ids: list[str],
    *,
    max_retries: int = 3,
    **kwargs: Any,
) -> dict[str, str]:
    """Call client.get_images with exponential backoff on transient failures.

    BACK-005: The Figma Images API is rate-limited and occasionally returns
    transient 5xx errors. A single failure silently degrades all image fills
    to placeholders. Retry with exponential backoff gives transient errors
    a chance to recover.

    Args:
        client: Figma API client.
        file_key: Figma file key.
        ids: Node IDs to resolve image URLs for.
        max_retries: Maximum number of retry attempts.
        **kwargs: Additional arguments passed to get_images (format, scale).

    Returns:
        Dict mapping node IDs to image URLs.

    Raises:
        FigmaAPIError: If all retry attempts fail.
    """
    for attempt in range(max_retries):
        try:
            return await client.get_images(file_key, ids, **kwargs)
        except FigmaAPIError:
            if attempt == max_retries - 1:
                raise
            wait = 2 ** attempt  # 1s, 2s, 4s
            logger.warning(
                "get_images attempt %d/%d failed, retrying in %ds",
                attempt + 1, max_retries, wait,
            )
            await asyncio.sleep(wait)
    return {}  # Unreachable, but satisfies type checker


def extract_sub_components(
    root: FigmaIRNode,
    image_urls: dict[str, str],
    svg_urls: dict[str, str] | None = None,
    aria: bool = False,
) -> list[dict[str, str]]:
    """Extract repeated component instances as separate React components."""
    all_nodes = walk_tree(root)

    # Group instances by component ID
    instance_groups: dict[str, list[FigmaIRNode]] = {}
    for node in all_nodes:
        if node.node_type == NodeType.INSTANCE and node.component_id:
            instance_groups.setdefault(node.component_id, []).append(node)

    # Only extract components that appear more than once
    sub_components: list[dict[str, str]] = []
    for comp_id, instances in instance_groups.items():
        if len(instances) < 2:
            continue
        template = instances[0]
        code = generate_component(template, image_urls=image_urls, svg_urls=svg_urls, aria=aria)
        sub_components.append({
            "component_id": comp_id,
            "name": template.name,
            "instance_count": str(len(instances)),
            "code": code,
        })

    return sub_components


# ---------------------------------------------------------------------------
# Core operations — pure async, no MCP
# ---------------------------------------------------------------------------


async def _fetch_node_or_file(
    client: FigmaClient,
    file_key: str,
    node_id: str | None,
    branch_key: str | None,
    depth: int = 2,
) -> dict[str, Any]:
    """Fetch a Figma node or full file and return the raw document dict.

    Shared logic for fetch_design, inspect_node, list_components, to_react.
    """
    if node_id:
        response_data = await client.get_nodes(
            file_key, [node_id], branch_key=branch_key
        )
        # Extract raw dict directly — avoids Pydantic extra="ignore"
        # stripping type-specific fields (characters, layoutMode, etc.)
        node_data = response_data.get("nodes", {}).get(node_id)
        if node_data is None:
            raise FigmaAPIError(
                f"Node '{node_id}' not found in file '{file_key}'. "
                f"Verify the node ID is correct."
            )
        document = node_data.get("document")
        if document is None:
            raise FigmaAPIError(
                f"Node '{node_id}' has no document data."
            )
        return document
    else:
        response_data = await client.get_file(
            file_key, depth=depth, branch_key=branch_key
        )
        # Extract raw dict directly — same reason as above
        document = response_data.get("document")
        if document is None:
            raise FigmaAPIError(
                f"File '{file_key}' returned no document. "
                f"The file may be empty or access may be restricted."
            )
        return document


def _parse_url(url: str) -> tuple[str, str | None, str | None]:
    """Parse a Figma URL and return (file_key, node_id, branch_key).

    Raises FigmaURLError if the URL is invalid.
    """
    parsed = parse_figma_url(url)
    file_key = parsed["file_key"]
    if file_key is None:
        raise FigmaURLError("URL is missing a file key — check the URL format.")
    return file_key, parsed["node_id"], parsed["branch_key"]


async def fetch_design(
    client: FigmaClient,
    url: str,
    depth: int = 2,
    max_length: int = DEFAULT_MAX_LENGTH,
    start_index: int = DEFAULT_START_INDEX,
) -> dict[str, Any]:
    """Fetch a Figma design and return its parsed IR tree.

    Returns a dict with file_key, node_count, tree, and pagination metadata.
    """
    file_key, node_id, branch_key = _parse_url(url)

    raw_doc = await _fetch_node_or_file(client, file_key, node_id, branch_key, depth)

    ir_root = parse_node(raw_doc)
    if ir_root is None:
        raise FigmaAPIError("Failed to parse design — no supported nodes found.")

    tree_dict = ir_to_dict(ir_root)
    output = {
        "schema_version": RESPONSE_SCHEMA_VERSION,
        "file_key": file_key,
        "node_count": count_nodes(ir_root),
        "tree": tree_dict,
    }
    content = json.dumps(output, indent=2)
    return paginate_output(content, max_length=max_length, start_index=start_index)


async def inspect_node(
    client: FigmaClient,
    url: str,
) -> dict[str, Any]:
    """Inspect detailed properties of a specific Figma node.

    Requires a URL with ?node-id=... parameter.
    """
    file_key, node_id, branch_key = _parse_url(url)
    if not node_id:
        raise ValueError(
            "URL must include a node-id query parameter "
            "(e.g., ?node-id=1-3). Use `list` to find node IDs."
        )

    raw_doc = await _fetch_node_or_file(client, file_key, node_id, branch_key)

    ir_node = parse_node(raw_doc)
    if ir_node is None:
        raise FigmaAPIError(
            f"Node '{node_id}' has an unsupported type and cannot be inspected."
        )

    detail = ir_to_dict(ir_node, max_depth=3)

    # Add fills/strokes/effects detail
    if ir_node.fills:
        detail["fills"] = [
            {
                "type": f.type.value,
                "visible": f.visible,
                "opacity": f.opacity,
                "color": f.color.to_hex() if f.color else None,
                "image_ref": f.image_ref,
            }
            for f in ir_node.fills
        ]
    if ir_node.strokes:
        detail["strokes"] = [
            {
                "type": s.type.value,
                "color": s.color.to_hex() if s.color else None,
                "weight": ir_node.stroke_weight,
            }
            for s in ir_node.strokes
        ]
    if ir_node.effects:
        detail["effects"] = [
            {
                "type": e.type.value,
                "radius": e.radius,
                "color": e.color.to_hex() if e.color else None,
                "offset": {"x": e.offset.x, "y": e.offset.y} if e.offset else None,
                "spread": e.spread,
            }
            for e in ir_node.effects
        ]

    return detail


async def list_components(
    client: FigmaClient,
    url: str,
) -> dict[str, Any]:
    """List all components and component instances in a Figma file."""
    file_key, node_id, branch_key = _parse_url(url)

    raw_doc = await _fetch_node_or_file(client, file_key, node_id, branch_key, depth=2)

    ir_root = parse_node(raw_doc)
    if ir_root is None:
        raise FigmaAPIError("No supported nodes found in the design.")

    all_nodes = walk_tree(ir_root)

    components: list[dict[str, Any]] = []
    instances: list[dict[str, Any]] = []
    instance_by_component: dict[str, list[str]] = {}

    for n in all_nodes:
        entry: dict[str, Any] = {
            "node_id": n.node_id,
            "name": n.name,
            "type": n.node_type.value,
        }
        if n.width is not None or n.height is not None:
            entry["size"] = f"{round(n.width or 0)}x{round(n.height or 0)}"

        if n.node_type.value in ("COMPONENT", "COMPONENT_SET"):
            components.append(entry)
        elif n.node_type.value == "INSTANCE":
            if n.component_id:
                entry["component_id"] = n.component_id
                instance_by_component.setdefault(n.component_id, []).append(n.node_id)
            instances.append(entry)

    # Detect duplicate instances
    duplicates: list[dict[str, Any]] = []
    for comp_id, inst_ids in instance_by_component.items():
        if len(inst_ids) > 1:
            duplicates.append({
                "component_id": comp_id,
                "instance_count": len(inst_ids),
                "instance_node_ids": inst_ids,
            })

    output: dict[str, Any] = {
        "schema_version": RESPONSE_SCHEMA_VERSION,
        "file_key": file_key,
        "total_components": len(components),
        "total_instances": len(instances),
        "components": components,
        "instances": instances,
    }
    if duplicates:
        output["duplicate_instances"] = duplicates

    return output


async def to_react(
    client: FigmaClient,
    url: str,
    component_name: str = "",
    use_tailwind: bool = True,
    extract_components: bool = False,
    aria: bool = False,
    max_length: int = DEFAULT_MAX_LENGTH,
    start_index: int = DEFAULT_START_INDEX,
) -> dict[str, Any]:
    """Convert a Figma design to React + Tailwind CSS code.

    End-to-end pipeline: URL parsing -> Figma API fetch -> node parsing ->
    style extraction -> layout resolution -> React JSX generation.

    Args:
        client: Figma API client.
        url: Full Figma URL.
        component_name: Override component name.
        use_tailwind: Generate Tailwind CSS classes.
        extract_components: Extract repeated instances as components.
        aria: When True, emit ARIA accessibility attributes.
        max_length: Max response characters for pagination.
        start_index: Pagination offset.
    """
    file_key, node_id, branch_key = _parse_url(url)

    # Use depth=3 for react generation (need more detail)
    depth = 3
    raw_doc = await _fetch_node_or_file(client, file_key, node_id, branch_key, depth)

    ir_root = parse_node(raw_doc)
    if ir_root is None:
        raise FigmaAPIError("Failed to parse design — no supported nodes found.")

    # Collect image refs for resolution
    image_refs = collect_image_refs(ir_root)
    image_urls: dict[str, str] = {}

    if image_refs:
        try:
            image_urls = await _get_images_with_retry(
                client, file_key, list(image_refs),
            )
        except FigmaAPIError:
            logger.warning("Failed to resolve image URLs — using placeholders")

    # Collect SVG fallback IDs for nodes with no geometry (export as SVG via Images API)
    svg_fallback_ids = _collect_svg_fallback_ids(ir_root)
    svg_urls: dict[str, str] = {}

    if svg_fallback_ids:
        # Validate format (WS-4) and clamp scale (WS-9) before calling API
        export_format = "svg"
        if export_format not in _VALID_IMAGE_FORMATS:
            export_format = "svg"
        export_scale = max(0.01, min(4.0, 1.0))  # scale=1.0 for SVG (scale has no effect on SVG)
        try:
            raw_svg_urls = await _get_images_with_retry(
                client, file_key, svg_fallback_ids,
                format=export_format,
                scale=export_scale,
            )
            # Filter out None values — failed exports return None in the API response
            svg_urls = {k: v for k, v in raw_svg_urls.items() if v is not None}
        except FigmaAPIError:
            logger.warning("Failed to resolve SVG export URLs — using placeholders")

    # Generate main component
    name = component_name if component_name else None
    main_code = generate_component(
        ir_root,
        component_name=name,
        image_urls=image_urls,
        svg_urls=svg_urls,
        aria=aria,
    )

    output: dict[str, Any] = {
        "schema_version": RESPONSE_SCHEMA_VERSION,
        "file_key": file_key,
        "node_count": count_nodes(ir_root),
        "main_component": main_code,
    }

    # Extract sub-components from repeated instances
    if extract_components:
        sub = extract_sub_components(ir_root, image_urls, svg_urls=svg_urls, aria=aria)
        if sub:
            output["extracted_components"] = sub

    # Unresolved images info
    unresolved = [ref for ref in image_refs if ref not in image_urls]
    if unresolved:
        output["unresolved_images"] = unresolved

    content = json.dumps(output, indent=2)
    return paginate_output(content, max_length=max_length, start_index=start_index)
