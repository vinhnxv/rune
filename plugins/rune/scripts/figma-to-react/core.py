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
from node_parser import FigmaIRNode, count_nodes, mark_cross_file_refs, parse_node, walk_tree
from react_generator import (
    generate_component, generate_split_components, _collect_node_classes,
)
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


def _ir_geometry_and_visibility(node: FigmaIRNode, result: dict[str, Any]) -> None:
    """Extract geometry dimensions and visibility into result dict."""
    if node.width is not None or node.height is not None:
        result["width"] = round(node.width or 0.0, 1)
        result["height"] = round(node.height or 0.0, 1)

    if not node.visible:
        result["visible"] = False
    if node.opacity < 1.0:
        result["opacity"] = round(node.opacity, 3)


def _ir_flags(node: FigmaIRNode, result: dict[str, Any]) -> None:
    """Extract boolean flags into result dict."""
    for flag_name in (
        "is_frame_like", "is_svg_candidate", "is_icon_candidate",
        "is_absolute_positioned", "has_auto_layout", "has_image_fill",
    ):
        val = getattr(node, flag_name, False)
        if val:
            result[flag_name] = True


def _ir_auto_layout(node: FigmaIRNode, result: dict[str, Any]) -> None:
    """Extract auto-layout and sizing properties into result dict."""
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

    if node.layout_sizing_horizontal:
        result["layout_sizing_horizontal"] = node.layout_sizing_horizontal.value
    if node.layout_sizing_vertical:
        result["layout_sizing_vertical"] = node.layout_sizing_vertical.value

    if node.corner_radius:
        result["corner_radius"] = node.corner_radius
    if node.corner_radii:
        result["corner_radii"] = node.corner_radii


def _ir_text_and_refs(node: FigmaIRNode, result: dict[str, Any]) -> None:
    """Extract text content, component/image refs, and SVG geometry counts."""
    if node.text_content is not None:
        result["text_content"] = node.text_content
        if node.text_style and node.text_style.font_family:
            result["font_family"] = node.text_style.font_family
            if node.text_style.font_size:
                result["font_size"] = node.text_style.font_size

    if node.component_id:
        result["component_id"] = node.component_id
    if node.component_property_definitions:
        result["component_property_definitions"] = {
            k: {
                "type": v.type.value,
                "defaultValue": v.default_value,
                **({"variantOptions": v.variant_options} if v.variant_options else {}),
            }
            for k, v in node.component_property_definitions.items()
        }
    if node.component_property_values:
        result["component_property_values"] = {
            k: {"type": v.type.value, "value": v.value}
            for k, v in node.component_property_values.items()
        }
    if node.image_ref:
        result["image_ref"] = node.image_ref
    if node.fill_geometry:
        result["fill_geometry_count"] = len(node.fill_geometry)
    if node.stroke_geometry:
        result["stroke_geometry_count"] = len(node.stroke_geometry)


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

    _ir_geometry_and_visibility(node, result)
    _ir_flags(node, result)
    _ir_auto_layout(node, result)
    _ir_text_and_refs(node, result)

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

    BACK-005: Retry with backoff so transient 5xx errors don't silently
    degrade all image fills to placeholders.
    Raises FigmaAPIError if all retry attempts fail.
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


# ---------------------------------------------------------------------------
# Phase 3: Variant-to-Component Splitting
# ---------------------------------------------------------------------------

# Decision thresholds
_MERGE_THRESHOLD = 0.75
_SPLIT_THRESHOLD = 0.50
_MAX_VARIANTS_FOR_SCORING = 8


def structural_diff_score(
    variant_a: FigmaIRNode, variant_b: FigmaIRNode,
) -> float:
    """Compute structural similarity between two variant IR nodes.

    Returns a score from 0.0 (completely different) to 1.0 (identical structure).
    Uses a weighted metric: child count (0.40), type matching (0.35),
    layout mode agreement (0.25).
    """
    a_children = variant_a.children
    b_children = variant_b.children
    max_children = max(len(a_children), len(b_children), 1)

    # Child count similarity (weight 0.40)
    child_count_sim = min(len(a_children), len(b_children)) / max_children

    # Child type matching per position (weight 0.35)
    min_len = min(len(a_children), len(b_children))
    type_matches = sum(
        1 for i in range(min_len)
        if a_children[i].node_type == b_children[i].node_type
    )
    type_sim = type_matches / max_children

    # Layout mode agreement (weight 0.25)
    layout_sim = 1.0 if variant_a.layout_mode == variant_b.layout_mode else 0.5

    return (child_count_sim * 0.4) + (type_sim * 0.35) + (layout_sim * 0.25)


def _parse_variant_name(name: str) -> dict[str, str]:
    """Parse variant name into dimension-value pairs.

    Handles both "Type=Primary, Size=Large" and flat "Primary" formats.
    """
    result: dict[str, str] = {}
    if "=" in name:
        for part in name.split(","):
            part = part.strip()
            if "=" in part:
                key, value = part.split("=", 1)
                result[key.strip()] = value.strip()
    else:
        result["variant"] = name.strip()
    return result


def _is_multi_dimensional(variants: list[FigmaIRNode]) -> bool:
    """Check if variants span multiple dimensions (e.g., Type + Size)."""
    if not variants:
        return False
    parsed = _parse_variant_name(variants[0].name)
    return len(parsed) > 1


def classify_variant_strategy(
    component_set: FigmaIRNode,
) -> tuple[str, float]:
    """Classify whether a COMPONENT_SET should be MERGE or SPLIT.

    Returns (strategy, avg_score) where strategy is "merge", "split",
    or "conditional".
    """
    variants = [
        c for c in component_set.children
        if c.node_type == NodeType.COMPONENT
    ]

    if len(variants) <= 1:
        return "merge", 1.0

    # Multi-dimensional → always MERGE
    if _is_multi_dimensional(variants):
        return "merge", 1.0

    # Short-circuit for large sets
    if len(variants) > _MAX_VARIANTS_FOR_SCORING:
        return "merge", 1.0

    # Pairwise scoring
    scores: list[float] = []
    for i in range(len(variants)):
        for j in range(i + 1, len(variants)):
            scores.append(structural_diff_score(variants[i], variants[j]))

    avg_score = sum(scores) / len(scores) if scores else 1.0

    if avg_score >= _MERGE_THRESHOLD:
        return "merge", avg_score
    if avg_score < _SPLIT_THRESHOLD:
        return "split", avg_score
    return "conditional", avg_score


# ---------------------------------------------------------------------------
# Phase 5: CVA (Class Variance Authority) Generation
# ---------------------------------------------------------------------------

# Layout-class prefixes — if >50% of variants disagree, move to variants
_LAYOUT_PREFIXES = frozenset({
    "flex", "grid", "block", "inline", "hidden",
    "items-", "justify-", "gap-", "space-",
    "flex-row", "flex-col", "flex-wrap",
})


def _is_layout_class(cls: str) -> bool:
    """Check if a Tailwind class is layout-related."""
    return any(cls == p or cls.startswith(p) for p in _LAYOUT_PREFIXES)


def infer_dimension_name(variant_name: str) -> str:
    """Infer CVA dimension name from a variant name string.

    For "Type=Primary" → "type". For flat "Primary" → "variant".
    For multi-dimensional "Type=Primary, Size=Large" → uses first dimension.
    """
    parsed = _parse_variant_name(variant_name)
    if "variant" in parsed:
        return "variant"
    keys = list(parsed.keys())
    return keys[0].lower() if keys else "variant"


def _collect_variant_class_lists(
    component_set: FigmaIRNode,
) -> list[tuple[str, list[str]]]:
    """Collect Tailwind classes for each variant in a COMPONENT_SET.

    Returns list of (variant_name, classes) tuples.
    """
    result = []
    for child in component_set.children:
        if child.node_type != NodeType.COMPONENT:
            continue
        classes = _collect_node_classes(child, component_set)
        result.append((child.name, list(classes)))
    return result


def generate_cva_from_variants(
    component_set: FigmaIRNode,
) -> dict[str, Any]:
    """Generate CVA configuration from a COMPONENT_SET's variants.

    Computes:
    - base: intersection of all variant class lists
    - variants: per-dimension, per-value diff classes
    - defaultVariants: first variant's values as defaults
    - compoundVariants: cross-dimension interactions (if multi-dimensional)

    Returns a dict with base, variants, defaultVariants, compoundVariants.
    """
    variant_classes = _collect_variant_class_lists(component_set)

    if not variant_classes:
        return {"base": [], "variants": {}, "defaultVariants": {}, "compoundVariants": []}

    # Single variant → all classes are base, no variants needed
    if len(variant_classes) == 1:
        return {
            "base": variant_classes[0][1],
            "variants": {},
            "defaultVariants": {},
            "compoundVariants": [],
        }

    # Compute base classes (intersection of all variants)
    all_class_sets = [set(classes) for _, classes in variant_classes]
    base_set = set.intersection(*all_class_sets)

    # Check layout class divergence: if a layout class appears in fewer than
    # half of variants, remove it from base (it belongs in variant diffs)
    all_classes_union = set.union(*all_class_sets)
    layout_candidates = {c for c in all_classes_union if _is_layout_class(c)}
    for cls in layout_candidates:
        has_count = sum(1 for cs in all_class_sets if cls in cs)
        if has_count / len(variant_classes) <= 0.5:
            base_set.discard(cls)

    # Preserve insertion order from first variant
    base_ordered = [c for c in variant_classes[0][1] if c in base_set]

    # Build per-dimension variant diffs
    variants: dict[str, dict[str, list[str]]] = {}
    default_variants: dict[str, str] = {}

    # Parse dimension info from first variant to determine structure
    first_parsed = _parse_variant_name(variant_classes[0][0])

    # Group variant classes by dimension values for per-dimension diff computation
    dim_value_class_sets: dict[str, dict[str, list[set[str]]]] = {}
    for vname, classes in variant_classes:
        parsed = _parse_variant_name(vname)
        for dim_key, dim_value in parsed.items():
            dim_lower = dim_key.lower()
            val_lower = dim_value.lower()
            dim_value_class_sets.setdefault(dim_lower, {}).setdefault(val_lower, []).append(
                set(classes) - base_set
            )

    # For each dimension, compute classes unique to that dimension value
    for dim_lower, value_map in dim_value_class_sets.items():
        variants[dim_lower] = {}
        # Collect all non-base classes across all values of this dimension
        all_dim_classes: set[str] = set()
        for class_sets in value_map.values():
            for cs in class_sets:
                all_dim_classes.update(cs)
        # For each value, keep only classes that appear in this value but not in all other values
        for val_lower, class_sets in value_map.items():
            other_values_classes: set[str] = set()
            for other_val, other_sets in value_map.items():
                if other_val != val_lower:
                    for cs in other_sets:
                        other_values_classes.update(cs)
            # Classes unique to this dimension value: present here, not in all others
            value_classes = set()
            for cs in class_sets:
                value_classes.update(cs)
            dim_diff = sorted(value_classes - other_values_classes)
            variants[dim_lower][val_lower] = dim_diff

    # Default variants from first variant
    for dim_key, dim_value in first_parsed.items():
        default_variants[dim_key.lower()] = dim_value.lower()

    # Compound variants for multi-dimensional sets
    compound_variants: list[dict[str, Any]] = []
    if len(first_parsed) > 1:
        for vname, classes in variant_classes:
            parsed = _parse_variant_name(vname)
            diff = [c for c in classes if c not in base_set]
            if diff:
                condition = {k.lower(): v.lower() for k, v in parsed.items()}
                compound_variants.append({
                    **condition,
                    "class": diff,
                })

    return {
        "base": base_ordered,
        "variants": variants,
        "defaultVariants": default_variants,
        "compoundVariants": compound_variants,
    }


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


async def _fetch_single_node(
    client: FigmaClient, file_key: str, node_id: str, branch_key: str | None,
) -> dict[str, Any]:
    """Fetch a single Figma node and return its raw document dict."""
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
        raise FigmaAPIError(f"Node '{node_id}' has no document data.")
    return document


async def _fetch_full_file(
    client: FigmaClient, file_key: str, branch_key: str | None, depth: int,
) -> dict[str, Any]:
    """Fetch a full Figma file and return its raw document dict."""
    response_data = await client.get_file(
        file_key, depth=depth, branch_key=branch_key
    )
    # Extract raw dict directly — same reason as _fetch_single_node
    document = response_data.get("document")
    if document is None:
        raise FigmaAPIError(
            f"File '{file_key}' returned no document. "
            f"The file may be empty or access may be restricted."
        )
    return document


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
        return await _fetch_single_node(client, file_key, node_id, branch_key)
    return await _fetch_full_file(client, file_key, branch_key, depth)


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
    mark_cross_file_refs(ir_root)

    tree_dict = ir_to_dict(ir_root)
    output = {
        "schema_version": RESPONSE_SCHEMA_VERSION,
        "file_key": file_key,
        "node_count": count_nodes(ir_root),
        "tree": tree_dict,
    }
    content = json.dumps(output, indent=2)
    return paginate_output(content, max_length=max_length, start_index=start_index)


def _enrich_detail_with_paints(
    ir_node: FigmaIRNode, detail: dict[str, Any],
) -> None:
    """Add fills/strokes/effects detail to an inspect_node result dict."""
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
    mark_cross_file_refs(ir_node)

    detail = ir_to_dict(ir_node, max_depth=3)
    _enrich_detail_with_paints(ir_node, detail)

    return detail


def _classify_nodes(
    all_nodes: list[FigmaIRNode],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, list[str]]]:
    """Classify IR nodes into components, instances, and instance-by-component map."""
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
            if n.component_property_definitions:
                entry["property_definitions"] = {
                    k: {
                        "type": v.type.value,
                        "defaultValue": v.default_value,
                        **({"variantOptions": v.variant_options} if v.variant_options else {}),
                    }
                    for k, v in n.component_property_definitions.items()
                }
            components.append(entry)
        elif n.node_type.value == "INSTANCE":
            if n.component_id:
                entry["component_id"] = n.component_id
                instance_by_component.setdefault(n.component_id, []).append(n.node_id)
            instances.append(entry)

    return components, instances, instance_by_component


def _detect_duplicate_instances(
    instance_by_component: dict[str, list[str]],
) -> list[dict[str, Any]]:
    """Detect components with more than one instance."""
    duplicates: list[dict[str, Any]] = []
    for comp_id, inst_ids in instance_by_component.items():
        if len(inst_ids) > 1:
            duplicates.append({
                "component_id": comp_id,
                "instance_count": len(inst_ids),
                "instance_node_ids": inst_ids,
            })
    return duplicates


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
    mark_cross_file_refs(ir_root)

    all_nodes = walk_tree(ir_root)
    components, instances, instance_by_component = _classify_nodes(all_nodes)
    duplicates = _detect_duplicate_instances(instance_by_component)

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


async def _resolve_image_urls(
    client: FigmaClient, file_key: str, ir_root: FigmaIRNode,
) -> tuple[list[str], dict[str, str]]:
    """Collect image refs and resolve them to URLs via the Figma Images API."""
    image_refs = collect_image_refs(ir_root)
    image_urls: dict[str, str] = {}

    if image_refs:
        try:
            raw_image_urls = await _get_images_with_retry(
                client, file_key, list(image_refs),
            )
            # Filter out None values — failed exports return None
            image_urls = {k: v for k, v in raw_image_urls.items() if v is not None}
        except FigmaAPIError:
            logger.warning("Failed to resolve image URLs — using placeholders")

    return image_refs, image_urls


async def _resolve_svg_fallback_urls(
    client: FigmaClient, file_key: str, ir_root: FigmaIRNode,
) -> dict[str, str]:
    """Collect SVG fallback IDs and resolve them to export URLs."""
    svg_fallback_ids = _collect_svg_fallback_ids(ir_root)
    svg_urls: dict[str, str] = {}

    if svg_fallback_ids:
        try:
            raw_svg_urls = await _get_images_with_retry(
                client, file_key, svg_fallback_ids,
                format="svg",
                scale=1.0,
            )
            # Filter out None values — failed exports return None
            svg_urls = {k: v for k, v in raw_svg_urls.items() if v is not None}
        except FigmaAPIError:
            logger.warning("Failed to resolve SVG export URLs — using placeholders")

    return svg_urls


def _build_react_output(
    file_key: str,
    ir_root: FigmaIRNode,
    main_code: str,
    image_refs: list[str],
    image_urls: dict[str, str],
    svg_urls: dict[str, str],
    extract_components: bool,
    aria: bool,
    variant_components: list[dict[str, str]] | None = None,
    variant_strategy: str | None = None,
    cva_config: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build the to_react output dict with optional sub-components."""
    output: dict[str, Any] = {
        "schema_version": RESPONSE_SCHEMA_VERSION,
        "file_key": file_key,
        "node_count": count_nodes(ir_root),
        "main_component": main_code,
    }

    if variant_components:
        output["variant_components"] = variant_components
        output["variant_strategy"] = variant_strategy

    if cva_config:
        output["cva_config"] = cva_config
        output["variant_strategy"] = variant_strategy

    if extract_components:
        sub = extract_sub_components(ir_root, image_urls, svg_urls=svg_urls, aria=aria)
        if sub:
            output["extracted_components"] = sub

    unresolved = [ref for ref in image_refs if ref not in image_urls]
    if unresolved:
        output["unresolved_images"] = unresolved

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
    """
    file_key, node_id, branch_key = _parse_url(url)

    # Use depth=3 for react generation (need more detail)
    raw_doc = await _fetch_node_or_file(client, file_key, node_id, branch_key, 3)

    ir_root = parse_node(raw_doc)
    if ir_root is None:
        raise FigmaAPIError("Failed to parse design — no supported nodes found.")
    mark_cross_file_refs(ir_root)

    image_refs, image_urls = await _resolve_image_urls(client, file_key, ir_root)
    svg_urls = await _resolve_svg_fallback_urls(client, file_key, ir_root)

    name = component_name if component_name else None
    main_code = generate_component(
        ir_root, component_name=name,
        image_urls=image_urls, svg_urls=svg_urls, aria=aria,
    )

    # Phase 3: Variant-to-Component Splitting for COMPONENT_SET roots
    # Phase 5: CVA generation for MERGE strategy
    variant_components = None
    variant_strategy = None
    cva_config = None
    if ir_root.node_type == NodeType.COMPONENT_SET:
        strategy, _score = classify_variant_strategy(ir_root)
        variant_strategy = strategy
        if strategy == "split":
            variant_components = generate_split_components(
                ir_root, image_urls=image_urls, svg_urls=svg_urls, aria=aria,
            )
        elif strategy in ("merge", "conditional"):
            cva_config = generate_cva_from_variants(ir_root)

    output = _build_react_output(
        file_key, ir_root, main_code, image_refs, image_urls,
        svg_urls, extract_components, aria,
        variant_components=variant_components,
        variant_strategy=variant_strategy,
        cva_config=cva_config,
    )
    content = json.dumps(output, indent=2)
    return paginate_output(content, max_length=max_length, start_index=start_index)
