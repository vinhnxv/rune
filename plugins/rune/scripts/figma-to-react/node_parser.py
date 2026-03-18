"""Figma node parser with intermediate representation (IR).

Transforms raw Figma API node trees into a simplified intermediate
representation (``FigmaIRNode``) suitable for downstream processing
by the style builder, layout resolver, and React code generator.

Key transformations:
- GROUP nodes are converted to FRAME-like semantics
- BOOLEAN_OPERATION nodes are marked as SVG candidates
- characterStyleOverrides are merged into styledTextSegments
- Icon candidates (<=64x64 with vector primitives) are detected
- Unsupported types (STICKY, CONNECTOR, TABLE) are skipped gracefully

Inspired by FigmaToCode's AltNode concept.
"""

from __future__ import annotations

import logging
import math
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, FrozenSet, List, Optional, Tuple

from figma_types import (
    BooleanOperationNode,
    Color,
    ComponentProperty,
    ComponentPropertyDefinition,
    Effect,
    FigmaNodeBase,
    FigmaPropertyType,
    FrameNode,
    LayoutAlign,
    LayoutMode,
    LayoutSizingMode,
    LayoutWrap,
    NodeType,
    Paint,
    TextNode,
    TypeStyle,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Instance role classification
# ---------------------------------------------------------------------------


class InstanceRole(str, Enum):
    """Semantic role of an INSTANCE node within its parent context.

    Used by the React generator to decide rendering strategy:
    - PROP: Render as a JSX expression prop (e.g., ``icon={<IconHeart />}``)
    - CHILD: Render as inline children (default behavior)
    - STANDALONE: Render as a separate component reference
    """

    PROP = "prop"
    CHILD = "child"
    STANDALONE = "standalone"


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Node types that we skip entirely during parsing
_UNSUPPORTED_TYPES: FrozenSet[str] = frozenset({
    "STICKY",
    "CONNECTOR",
    "TABLE",
    "TABLE_CELL",
    "SHAPE_WITH_TEXT",
    "STAMP",
    "WIDGET",
    "EMBED",
    "LINK_UNFURL",
    "SLICE",
})

# Node types treated as FRAME-like (have children, support auto-layout)
_FRAME_LIKE_TYPES: FrozenSet[str] = frozenset({
    "FRAME",
    "COMPONENT",
    "INSTANCE",
    "COMPONENT_SET",
    "SECTION",
    "GROUP",
})

# Node types that contain vector primitives (for icon detection)
_VECTOR_TYPES: FrozenSet[str] = frozenset({
    "VECTOR",
    "BOOLEAN_OPERATION",
    "ELLIPSE",
    "RECTANGLE",
    "LINE",
    "REGULAR_POLYGON",
    "STAR",
})

# VEIL-002: Node types that are inherently SVG — always render as SVG regardless of size
# LINE, REGULAR_POLYGON, and STAR have no meaningful non-SVG representation
_INHERENTLY_SVG_TYPES: FrozenSet[str] = frozenset({
    "LINE",
    "REGULAR_POLYGON",
    "STAR",
})


# ---------------------------------------------------------------------------
# Styled text segment
# ---------------------------------------------------------------------------


@dataclass
class StyledTextSegment:
    """A contiguous run of text sharing the same style.

    Created by merging TEXT node's ``characterStyleOverrides`` with
    its ``styleOverrideTable`` entries.
    """

    text: str
    style: Optional[TypeStyle] = None
    start: int = 0
    end: int = 0


# ---------------------------------------------------------------------------
# Intermediate Representation (IR) node
# ---------------------------------------------------------------------------


@dataclass
class FigmaIRNode:
    """Intermediate representation of a Figma node.

    Flattens and normalizes the Figma API response into a form that
    is simpler for downstream code generation. Computed properties
    are resolved once during parsing rather than on every access.

    Attributes:
        node_id: Original Figma node ID.
        name: Node name from Figma.
        node_type: Normalized NodeType enum value.
        unique_name: Deduplicated name for React component/variable naming.
        visible: Whether the node is visible.
        opacity: Node opacity (0.0-1.0).
        width: Computed width from bounding box.
        height: Computed height from bounding box.
        x: X position relative to parent.
        y: Y position relative to parent.
        rotation: Rotation in degrees.
        cumulative_rotation: Accumulated rotation including ancestors.
        fills: List of fill paints.
        strokes: List of stroke paints.
        stroke_weight: Stroke thickness.
        effects: List of visual effects.
        corner_radius: Uniform corner radius.
        corner_radii: Per-corner radii [topLeft, topRight, bottomRight, bottomLeft].
        children: Parsed child IR nodes.
        is_frame_like: Whether this node acts as a container (FRAME, GROUP, etc.).
        is_svg_candidate: Whether this node should be rendered as inline SVG.
        is_icon_candidate: Whether this node is small enough to be an icon.
        is_absolute_positioned: Whether the node uses absolute positioning.
        can_be_flattened: Whether children can be inlined into parent.
        has_auto_layout: Whether the node has auto-layout enabled.
        layout_mode: Auto-layout direction (HORIZONTAL, VERTICAL, NONE).
        layout_wrap: Auto-layout wrap behavior.
        primary_axis_align: Primary axis alignment.
        counter_axis_align: Counter axis alignment.
        item_spacing: Gap between auto-layout children.
        counter_axis_spacing: Gap between wrapped rows/columns.
        padding: Padding as (top, right, bottom, left).
        layout_sizing_horizontal: Horizontal sizing mode (FIXED, HUG, FILL).
        layout_sizing_vertical: Vertical sizing mode (FIXED, HUG, FILL).
        layout_grow: Flex grow factor.
        min_width: Minimum width constraint.
        max_width: Maximum width constraint.
        min_height: Minimum height constraint.
        max_height: Maximum height constraint.
        clips_content: Whether content is clipped (overflow: hidden).
        text_content: Raw text for TEXT nodes.
        text_segments: Styled text segments for TEXT nodes.
        text_style: Base typography style for TEXT nodes.
        component_id: Referenced component ID for INSTANCE nodes.
        has_image_fill: Whether any fill is an IMAGE type.
        image_ref: Image reference hash for IMAGE fills.
        boolean_operation: Operation type for BOOLEAN_OPERATION nodes.
        raw: Original Figma API dict (for fallback access).
    """

    node_id: str
    name: str = ""
    node_type: NodeType = NodeType.FRAME
    unique_name: str = ""
    visible: bool = True
    opacity: float = 1.0

    # Geometry
    width: float = 0.0
    height: float = 0.0
    x: float = 0.0
    y: float = 0.0
    rotation: float = 0.0
    cumulative_rotation: float = 0.0

    # Styling
    fills: List[Paint] = field(default_factory=list)
    strokes: List[Paint] = field(default_factory=list)
    stroke_weight: float = 0.0
    effects: List[Effect] = field(default_factory=list)
    corner_radius: float = 0.0
    corner_radii: Optional[List[float]] = None

    # Tree
    children: List[FigmaIRNode] = field(default_factory=list)

    # Computed flags
    is_frame_like: bool = False
    is_svg_candidate: bool = False
    is_icon_candidate: bool = False
    is_absolute_positioned: bool = False
    can_be_flattened: bool = False

    # Auto-layout
    has_auto_layout: bool = False
    layout_mode: LayoutMode = LayoutMode.NONE
    layout_wrap: LayoutWrap = LayoutWrap.NO_WRAP
    primary_axis_align: Optional[LayoutAlign] = None
    counter_axis_align: Optional[LayoutAlign] = None
    counter_axis_align_content: Optional[LayoutAlign] = None
    item_spacing: float = 0.0
    counter_axis_spacing: Optional[float] = None
    padding: Tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    layout_sizing_horizontal: Optional[LayoutSizingMode] = None
    layout_sizing_vertical: Optional[LayoutSizingMode] = None
    layout_grow: Optional[float] = None
    min_width: Optional[float] = None
    max_width: Optional[float] = None
    min_height: Optional[float] = None
    max_height: Optional[float] = None
    clips_content: bool = False

    # v5 grid
    layout_grid_columns: Optional[int] = None
    layout_grid_cell_min_width: Optional[float] = None

    # Text
    text_content: Optional[str] = None
    text_segments: List[StyledTextSegment] = field(default_factory=list)
    text_style: Optional[TypeStyle] = None

    # Component
    component_id: Optional[str] = None
    # Component property definitions (from COMPONENT/COMPONENT_SET parent)
    component_property_definitions: Optional[
        Dict[str, ComponentPropertyDefinition]
    ] = None
    # Component property override values (from INSTANCE nodes)
    component_property_values: Optional[Dict[str, ComponentProperty]] = None
    # Instance role classification (Phase 2)
    instance_role: Optional[InstanceRole] = None

    # Cross-file component reference (Phase 2 edge case)
    cross_file_ref: bool = False

    # Slot detection (Phase 6)
    is_slot_candidate: bool = False
    is_empty_slot: bool = False
    is_decorative_container: bool = False
    slot_name: Optional[str] = None

    # Image
    has_image_fill: bool = False
    image_ref: Optional[str] = None

    # Boolean operation
    boolean_operation: Optional[str] = None

    # SVG geometry (for vector nodes — actual path data from fillGeometry)
    fill_geometry: List[Dict[str, Any]] = field(default_factory=list)
    # SVG stroke geometry (stroke outlines from strokeGeometry)
    stroke_geometry: List[Dict[str, Any]] = field(default_factory=list)

    # Blend mode (e.g., MULTIPLY, SCREEN, OVERLAY — maps to mix-blend-*)
    blend_mode: Optional[str] = None

    # Text auto-resize mode (WIDTH_AND_HEIGHT, HEIGHT, NONE, TRUNCATE)
    text_auto_resize: Optional[str] = None

    # Stroke alignment (INSIDE, OUTSIDE, CENTER)
    stroke_align: Optional[str] = None

    # Constraint-based positioning
    constraint_horizontal: Optional[str] = None
    constraint_vertical: Optional[str] = None

    # Vertical text alignment (TOP, CENTER, BOTTOM)
    text_align_vertical: Optional[str] = None

    # Raw data for fallback
    raw: Optional[Dict[str, Any]] = field(default=None, repr=False)


# ---------------------------------------------------------------------------
# Delegated to node_normalizer.py — normalization functions extracted
# for module decomposition. Re-exported here for backward compatibility.
# ---------------------------------------------------------------------------

from node_normalizer import (  # noqa: E402
    _sanitize_name,
    _NameDeduplicator,
    _has_vector_children,
    _detect_icon_candidate,
    _detect_svg_illustration,
    _detect_image_fill,
    _is_absolute_positioned,
    _can_be_flattened as _can_be_flattened,
)


# ---------------------------------------------------------------------------
# Text segment merging (kept in node_parser — constructs StyledTextSegment)
# ---------------------------------------------------------------------------


def _resolve_override_style(
    override_idx: int,
    base_style: Optional[TypeStyle],
    override_table: Dict[str, TypeStyle],
) -> Optional[TypeStyle]:
    """Resolve the effective style for a character override index."""
    if override_idx == 0:
        return base_style
    return override_table.get(str(override_idx), base_style)


def _build_override_segments(
    characters: str,
    base_style: Optional[TypeStyle],
    overrides: List[int],
    override_table: Dict[str, TypeStyle],
) -> List[StyledTextSegment]:
    """Build styled text segments from per-character override indices."""
    segments: List[StyledTextSegment] = []
    effective_overrides = overrides[:len(characters)]
    if not effective_overrides:
        return segments
    current_idx: int = effective_overrides[0]
    start: int = 0

    for i, char_override in enumerate(effective_overrides):
        if char_override != current_idx:
            style = _resolve_override_style(current_idx, base_style, override_table)
            segments.append(StyledTextSegment(
                text=characters[start:i], style=style, start=start, end=i,
            ))
            current_idx = char_override
            start = i

    remaining_text = characters[start:]
    if remaining_text:
        style = _resolve_override_style(current_idx, base_style, override_table)
        segments.append(StyledTextSegment(
            text=remaining_text, style=style, start=start, end=len(characters),
        ))

    return segments


def merge_text_segments(
    characters: str,
    base_style: Optional[TypeStyle],
    overrides: Optional[List[int]],
    override_table: Optional[Dict[str, TypeStyle]],
) -> List[StyledTextSegment]:
    """Merge characterStyleOverrides with styleOverrideTable into segments."""
    if not characters:
        return []

    if not overrides or not override_table:
        return [
            StyledTextSegment(
                text=characters, style=base_style,
                start=0, end=len(characters),
            )
        ]

    return _build_override_segments(characters, base_style, overrides, override_table)


# ---------------------------------------------------------------------------
# Core parser
# ---------------------------------------------------------------------------


def _clean_property_name(name: str) -> str:
    """Strip ``#hash`` suffix from Figma component property names."""
    return name.split("#")[0]


# Thin wrappers for _classify_instance_role and _detect_slot_candidate
# that bind the InstanceRole enum (defined above in this module).
# The actual logic lives in node_normalizer.py.

from node_normalizer import (  # noqa: E402
    _classify_instance_role as _classify_instance_role_impl,
    _detect_slot_candidate as _detect_slot_candidate_impl,
    _SLOT_KEYWORDS,
    _GENERIC_SLOT_NAMES,
    _INSTANCE_PROP_MAX_SIZE,
)


def _classify_instance_role(
    ir_node: FigmaIRNode,
    parent_ir: Optional[FigmaIRNode] = None,
) -> Optional[InstanceRole]:
    """Classify the semantic role of an INSTANCE node."""
    return _classify_instance_role_impl(ir_node, parent_ir, InstanceRole=InstanceRole)


def _detect_slot_candidate(
    ir_node: FigmaIRNode,
    parent_ir: Optional[FigmaIRNode] = None,
) -> bool:
    """Detect whether a frame-like node qualifies as a slot."""
    return _detect_slot_candidate_impl(ir_node, parent_ir)


_MAX_PARSE_DEPTH = 100  # BACK-P3-004: Guard against pathological nesting
_MAX_COLLECT_DEPTH = 10  # Depth ceiling for child geometry collection
_MAX_ROLE_CLASSIFICATION_DEPTH = 5  # Phase 2 edge case: skip role classification for deeply nested instances


def _extract_geometry_from_child(
    child: Dict[str, Any],
    fill_result: List[Dict[str, Any]],
    stroke_result: List[Dict[str, Any]],
    _depth: int,
) -> None:
    """Extract fill/stroke geometry from a single child node.

    Appends geometry data to *fill_result* and *stroke_result* in place.
    If the child has no own geometry and is a vector or frame-like type,
    recurses into its children.

    Args:
        child: Raw child node dict.
        fill_result: Accumulator for fill geometry paths.
        stroke_result: Accumulator for stroke geometry paths.
        _depth: Current recursion depth.
    """
    child_type = child.get("type", "")
    fill_geo = child.get("fillGeometry")
    stroke_geo = child.get("strokeGeometry")
    if fill_geo and isinstance(fill_geo, list):
        fill_result.extend(fill_geo)
    if stroke_geo and isinstance(stroke_geo, list):
        stroke_result.extend(stroke_geo)
    if not fill_geo and not stroke_geo:
        if child_type in _VECTOR_TYPES or child_type in _FRAME_LIKE_TYPES:
            sub_children = child.get("children", [])
            if sub_children:
                sub_fill, sub_stroke = _collect_child_geometry(sub_children, _depth + 1)
                fill_result.extend(sub_fill)
                stroke_result.extend(sub_stroke)


def _collect_child_geometry(
    children: List[Dict[str, Any]],
    _depth: int = 0,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Recursively collect fillGeometry and strokeGeometry from descendant vector nodes.

    When a BOOLEAN_OPERATION or icon-candidate FRAME has no geometry
    at its own level, this traverses children to gather path data from
    VECTOR, ELLIPSE, RECTANGLE, etc. nodes.

    Args:
        children: List of raw child node dicts.
        _depth: Recursion depth guard.

    Returns:
        Tuple of (fill_geometry, stroke_geometry) collected from all descendant vectors.
    """
    if _depth > _MAX_COLLECT_DEPTH:
        return [], []

    fill_result: List[Dict[str, Any]] = []
    stroke_result: List[Dict[str, Any]] = []
    for child in children:
        if isinstance(child, dict):
            _extract_geometry_from_child(child, fill_result, stroke_result, _depth)
    return fill_result, stroke_result


def _resolve_node_type(
    node_type_str: str, node_name: str, has_children: bool,
) -> Optional[NodeType]:
    """Resolve a Figma type string to a NodeType enum value.

    Unknown types with children are treated as FRAME. Unknown leaf
    types return None (caller should skip the node).

    Args:
        node_type_str: Raw type string from the Figma API.
        node_name: Node name for debug logging.
        has_children: Whether the node has child nodes.

    Returns:
        Resolved NodeType, or None if the type is unknown and has no children.
    """
    try:
        return NodeType(node_type_str)
    except ValueError:
        if has_children:
            logger.debug(
                "Unknown node type %s (%s) -- treating as FRAME",
                node_type_str, node_name,
            )
            return NodeType.FRAME
        logger.debug("Skipping unknown leaf node type %s: %s", node_type_str, node_name)
        return None


def _extract_bbox_geometry(pydantic_node: FigmaNodeBase) -> Tuple[float, float, float, float]:
    """Extract width, height, x, y from bounding box (defaulting to 0.0)."""
    bbox = pydantic_node.absolute_bounding_box
    if bbox:
        return bbox.width, bbox.height, bbox.x, bbox.y
    return 0.0, 0.0, 0.0, 0.0


def _build_ir_node(
    raw: Dict[str, Any],
    node_type: NodeType,
    node_type_str: str,
    pydantic_node: FigmaNodeBase,
    parent_rotation: float,
    deduplicator: _NameDeduplicator,
) -> FigmaIRNode:
    """Construct the base FigmaIRNode from parsed data."""
    width, height, x, y = _extract_bbox_geometry(pydantic_node)
    has_image_fill, image_ref = _detect_image_fill(pydantic_node.fills)
    rotation = pydantic_node.rotation or 0.0

    return FigmaIRNode(
        node_id=raw.get("id", ""),
        name=raw.get("name", ""),
        node_type=node_type,
        unique_name=deduplicator.get_unique(raw.get("name", "")),
        visible=pydantic_node.visible,
        opacity=pydantic_node.opacity if pydantic_node.opacity is not None else 1.0,
        width=width, height=height, x=x, y=y,
        rotation=rotation,
        cumulative_rotation=parent_rotation + rotation,
        fills=pydantic_node.fills,
        strokes=pydantic_node.strokes,
        stroke_weight=pydantic_node.stroke_weight or 0.0,
        effects=pydantic_node.effects,
        corner_radius=pydantic_node.corner_radius or 0.0,
        corner_radii=pydantic_node.rectangle_corner_radii,
        is_frame_like=node_type_str in _FRAME_LIKE_TYPES,
        is_svg_candidate=node_type == NodeType.BOOLEAN_OPERATION,
        is_icon_candidate=_detect_icon_candidate(pydantic_node),
        is_absolute_positioned=_is_absolute_positioned(pydantic_node),
        has_image_fill=has_image_fill, image_ref=image_ref,
        component_id=pydantic_node.component_id, raw=raw,
        stroke_align=(
            pydantic_node.stroke_align.value
            if pydantic_node.stroke_align is not None
            else None
        ),
        constraint_horizontal=(
            pydantic_node.constraints.horizontal.value
            if pydantic_node.constraints is not None
            else None
        ),
        constraint_vertical=(
            pydantic_node.constraints.vertical.value
            if pydantic_node.constraints is not None
            else None
        ),
    )


def _apply_type_specific_properties(
    ir_node: FigmaIRNode,
    raw: Dict[str, Any],
    node_type_str: str,
    pydantic_node: FigmaNodeBase,
) -> None:
    """Apply blend mode, text-auto-resize, frame, boolean, and text properties.

    Mutates *ir_node* in place based on the concrete Pydantic node type.

    Args:
        ir_node: IR node to enrich.
        raw: Raw Figma API node dictionary.
        node_type_str: Raw type string for set-membership checks.
        pydantic_node: Validated Pydantic model of the node.
    """
    blend_mode = raw.get("blendMode")
    if blend_mode and blend_mode != "PASS_THROUGH" and blend_mode != "NORMAL":
        ir_node.blend_mode = blend_mode

    text_auto_resize = raw.get("textAutoResize")
    if text_auto_resize:
        ir_node.text_auto_resize = text_auto_resize

    if isinstance(pydantic_node, FrameNode) or node_type_str in _FRAME_LIKE_TYPES:
        _apply_frame_properties(ir_node, raw)

    if isinstance(pydantic_node, BooleanOperationNode):
        ir_node.boolean_operation = (
            pydantic_node.boolean_operation.value
            if pydantic_node.boolean_operation is not None
            else None
        )
        ir_node.is_svg_candidate = True

    if isinstance(pydantic_node, TextNode):
        _apply_text_properties(ir_node, pydantic_node)

    # Component property definitions (COMPONENT / COMPONENT_SET)
    if pydantic_node.component_property_definitions:
        ir_node.component_property_definitions = {
            _clean_property_name(k): v
            for k, v in pydantic_node.component_property_definitions.items()
        }

    # Component property override values (INSTANCE)
    if pydantic_node.component_properties:
        ir_node.component_property_values = {
            _clean_property_name(k): v
            for k, v in pydantic_node.component_properties.items()
        }


def _apply_svg_geometry(
    ir_node: FigmaIRNode,
    raw: Dict[str, Any],
    node_type_str: str,
    pydantic_node: FigmaNodeBase,
) -> None:
    """Extract fill/stroke geometry and resolve SVG candidate status.

    Handles own-level geometry extraction, descendant geometry collection,
    icon candidate promotion, illustration detection, and inherently-SVG types.

    Args:
        ir_node: IR node to enrich with SVG data.
        raw: Raw Figma API node dictionary.
        node_type_str: Raw type string for set-membership checks.
        pydantic_node: Validated Pydantic model of the node.
    """
    if node_type_str in _VECTOR_TYPES or ir_node.is_svg_candidate:
        fill_geo = raw.get("fillGeometry")
        if fill_geo and isinstance(fill_geo, list):
            ir_node.fill_geometry = fill_geo
        if node_type_str != "BOOLEAN_OPERATION":
            stroke_geo = raw.get("strokeGeometry")
            if stroke_geo and isinstance(stroke_geo, list):
                ir_node.stroke_geometry = stroke_geo

    if ir_node.is_svg_candidate and not ir_node.fill_geometry and raw.get("children"):
        fill_geo, stroke_geo = _collect_child_geometry(raw.get("children", []))
        ir_node.fill_geometry = fill_geo
        ir_node.stroke_geometry = stroke_geo

    if ir_node.is_icon_candidate:
        ir_node.is_svg_candidate = True

    if not ir_node.is_svg_candidate and _detect_svg_illustration(pydantic_node):
        ir_node.is_svg_candidate = True

    if not ir_node.is_svg_candidate and node_type_str in _INHERENTLY_SVG_TYPES:
        ir_node.is_svg_candidate = True


def _validate_parse_input(
    raw: Any, _depth: int,
) -> bool:
    """Validate parse_node inputs; returns False if node should be skipped."""
    if _depth > _MAX_PARSE_DEPTH:
        logger.warning("Max parse depth (%d) exceeded, skipping subtree", _MAX_PARSE_DEPTH)
        return False
    if not isinstance(raw, dict):
        logger.debug("parse_node received non-dict argument: %r", type(raw))
        return False
    return True


def parse_node(
    raw: Dict[str, Any],
    parent_rotation: float = 0.0,
    deduplicator: Optional[_NameDeduplicator] = None,
    _depth: int = 0,
    parent_ir: Optional[FigmaIRNode] = None,
) -> Optional[FigmaIRNode]:
    """Parse a raw Figma API node dict into an IR node recursively."""
    if not _validate_parse_input(raw, _depth):
        return None
    if deduplicator is None:
        deduplicator = _NameDeduplicator()

    node_type_str = raw.get("type", "")
    node_name = raw.get("name", "")
    if node_type_str in _UNSUPPORTED_TYPES:
        logger.debug("Skipping unsupported node type %s: %s", node_type_str, node_name)
        return None

    pydantic_node = _parse_pydantic_node(raw, node_type_str)
    node_type = _resolve_node_type(node_type_str, node_name, bool(raw.get("children")))
    if node_type is None:
        return None

    ir_node = _build_ir_node(raw, node_type, node_type_str, pydantic_node, parent_rotation, deduplicator)
    _apply_type_specific_properties(ir_node, raw, node_type_str, pydantic_node)
    _apply_svg_geometry(ir_node, raw, node_type_str, pydantic_node)
    _parse_children(ir_node, raw, deduplicator, _depth)

    # Classify instance role (Phase 2) — after children are populated
    # Skip classification for deeply nested instances (depth > 5) to avoid
    # misclassifying instance→instance→...→icon chains far from component surface.
    if ir_node.component_id and _depth <= _MAX_ROLE_CLASSIFICATION_DEPTH:
        ir_node.instance_role = _classify_instance_role(ir_node, parent_ir)
        if ir_node.instance_role is not None:
            ir_node.can_be_flattened = False

    # Detect slot candidates (Phase 6) — after children are populated
    if _detect_slot_candidate(ir_node, parent_ir):
        ir_node.can_be_flattened = False

    if ir_node.is_frame_like and ir_node.instance_role is None and not ir_node.is_slot_candidate:
        ir_node.can_be_flattened = _can_be_flattened(ir_node)
    return ir_node


def _parse_children(
    ir_node: FigmaIRNode, raw: Dict[str, Any],
    deduplicator: _NameDeduplicator, _depth: int,
) -> None:
    """Recursively parse and append child nodes."""
    for child_raw in raw.get("children", []):
        child = parse_node(
            child_raw, ir_node.cumulative_rotation, deduplicator,
            _depth + 1, parent_ir=ir_node,
        )
        if child is not None:
            ir_node.children.append(child)


def _parse_pydantic_node(raw: Dict[str, Any], node_type_str: str) -> FigmaNodeBase:
    """Parse raw dict into the appropriate Pydantic node model.

    Args:
        raw: Raw Figma API node dictionary.
        node_type_str: The node's type string.

    Returns:
        Parsed Pydantic model (FrameNode, TextNode, BooleanOperationNode,
        or FigmaNodeBase).
    """
    if node_type_str in _FRAME_LIKE_TYPES:
        return FrameNode.model_validate(raw)
    if node_type_str == "TEXT":
        return TextNode.model_validate(raw)
    if node_type_str == "BOOLEAN_OPERATION":
        return BooleanOperationNode.model_validate(raw)
    return FigmaNodeBase.model_validate(raw)


def _try_parse_layout_align(value: str, field_name: str) -> Optional[LayoutAlign]:
    """Parse a layout alignment string, returning None on unknown values."""
    try:
        return LayoutAlign(value)
    except ValueError:
        logger.debug("Unknown %s value: %s", field_name, value)
        return None


def _apply_layout_mode_and_alignment(
    ir_node: FigmaIRNode, raw: Dict[str, Any],
) -> None:
    """Extract layout mode, wrap, and alignment properties from raw data."""
    layout_mode_str = raw.get("layoutMode")
    if layout_mode_str and layout_mode_str != "NONE":
        try:
            ir_node.layout_mode = LayoutMode(layout_mode_str)
        except ValueError:
            ir_node.layout_mode = LayoutMode.NONE
        ir_node.has_auto_layout = ir_node.layout_mode != LayoutMode.NONE

    wrap_str = raw.get("layoutWrap")
    if wrap_str:
        try:
            ir_node.layout_wrap = LayoutWrap(wrap_str)
        except ValueError:
            logger.debug("Unknown layoutWrap value: %s", wrap_str)

    for raw_key, attr_name in (
        ("primaryAxisAlignItems", "primary_axis_align"),
        ("counterAxisAlignItems", "counter_axis_align"),
        ("counterAxisAlignContent", "counter_axis_align_content"),
    ):
        val = raw.get(raw_key)
        if val:
            parsed = _try_parse_layout_align(val, raw_key)
            if parsed is not None:
                setattr(ir_node, attr_name, parsed)


def _apply_spacing_and_sizing(
    ir_node: FigmaIRNode, raw: Dict[str, Any],
) -> None:
    """Extract spacing, padding, sizing, constraints, grid, and clipping."""
    ir_node.item_spacing = raw.get("itemSpacing", 0.0)
    ir_node.counter_axis_spacing = raw.get("counterAxisSpacing")
    ir_node.padding = (
        raw.get("paddingTop", 0.0), raw.get("paddingRight", 0.0),
        raw.get("paddingBottom", 0.0), raw.get("paddingLeft", 0.0),
    )
    _apply_sizing_modes(ir_node, raw)
    ir_node.layout_grow = raw.get("layoutGrow")
    ir_node.min_width = raw.get("minWidth")
    ir_node.max_width = raw.get("maxWidth")
    ir_node.min_height = raw.get("minHeight")
    ir_node.max_height = raw.get("maxHeight")
    ir_node.layout_grid_columns = raw.get("layoutGridColumns")
    ir_node.layout_grid_cell_min_width = raw.get("layoutGridCellMinWidth")
    ir_node.clips_content = raw.get("clipsContent", False)


def _apply_sizing_modes(ir_node: FigmaIRNode, raw: Dict[str, Any]) -> None:
    """Parse layoutSizingHorizontal and layoutSizingVertical from raw data."""
    lsh = raw.get("layoutSizingHorizontal")
    if lsh:
        try:
            ir_node.layout_sizing_horizontal = LayoutSizingMode(lsh)
        except ValueError:
            logger.debug("Unknown layoutSizingHorizontal value: %s", lsh)
    lsv = raw.get("layoutSizingVertical")
    if lsv:
        try:
            ir_node.layout_sizing_vertical = LayoutSizingMode(lsv)
        except ValueError:
            logger.debug("Unknown layoutSizingVertical value: %s", lsv)


def _apply_frame_properties(ir_node: FigmaIRNode, raw: Dict[str, Any]) -> None:
    """Extract auto-layout and frame properties from raw data.

    Delegates to focused helpers for layout/alignment and spacing/sizing.

    Args:
        ir_node: IR node to populate.
        raw: Raw Figma API node dictionary.
    """
    _apply_layout_mode_and_alignment(ir_node, raw)
    _apply_spacing_and_sizing(ir_node, raw)


def _apply_text_properties(ir_node: FigmaIRNode, text_node: TextNode) -> None:
    """Extract text-specific properties into the IR node.

    Args:
        ir_node: IR node to populate.
        text_node: Parsed TextNode Pydantic model.
    """
    ir_node.text_content = text_node.characters
    ir_node.text_style = text_node.style
    if text_node.style and text_node.style.text_align_vertical is not None:
        ir_node.text_align_vertical = text_node.style.text_align_vertical.value
    ir_node.text_segments = merge_text_segments(
        characters=text_node.characters,
        base_style=text_node.style,
        overrides=text_node.character_style_overrides,
        override_table=text_node.style_override_table,
    )


# ---------------------------------------------------------------------------
# Tree utilities
# ---------------------------------------------------------------------------


def walk_tree(node: FigmaIRNode) -> List[FigmaIRNode]:
    """Flatten the IR tree into a pre-order list.

    Args:
        node: Root IR node.

    Returns:
        List of all nodes in pre-order traversal.
    """
    result: List[FigmaIRNode] = []
    stack: deque[FigmaIRNode] = deque([node])
    while stack:
        current = stack.pop()
        result.append(current)
        # Push children in reverse order to maintain pre-order traversal
        for child in reversed(current.children):
            stack.append(child)
    return result


def find_by_name(node: FigmaIRNode, name: str) -> Optional[FigmaIRNode]:
    """Find the first node with the given name in the tree.

    Args:
        node: Root IR node to search from.
        name: Exact name to match.

    Returns:
        The first matching node, or None if not found.
    """
    if node.name == name:
        return node
    for child in node.children:
        found = find_by_name(child, name)
        if found is not None:
            return found
    return None


def count_nodes(node: FigmaIRNode) -> int:
    """Count total nodes in the IR tree.

    Args:
        node: Root IR node.

    Returns:
        Total number of nodes including the root.
    """
    total = 0
    stack: deque[FigmaIRNode] = deque([node])
    while stack:
        current = stack.pop()
        total += 1
        for child in current.children:
            stack.append(child)
    return total


def mark_cross_file_refs(root: FigmaIRNode) -> None:
    """Mark INSTANCE nodes that reference components not defined in this tree.

    Walks the IR tree twice:
    1. Collect all local component IDs (COMPONENT/COMPONENT_SET nodes).
    2. Flag any INSTANCE whose component_id is not in the local set.
    """
    local_component_ids: set[str] = set()
    all_nodes = walk_tree(root)

    for node in all_nodes:
        if node.node_type.value in ("COMPONENT", "COMPONENT_SET"):
            local_component_ids.add(node.node_id)

    for node in all_nodes:
        if node.component_id and node.component_id not in local_component_ids:
            node.cross_file_ref = True
