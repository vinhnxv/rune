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
import re
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Dict, FrozenSet, List, Optional, Tuple

from figma_types import (
    BooleanOperationNode,
    Color,
    Effect,
    FigmaNodeBase,
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
# Constants
# ---------------------------------------------------------------------------

# Max dimension (px) for icon candidate detection
_ICON_MAX_SIZE: float = 64.0

# Max dimension (px) for SVG illustration candidate detection (64px < size <= 512px)
_SVG_ILLUSTRATION_MAX_SIZE: float = 512.0

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

    # Raw data for fallback
    raw: Optional[Dict[str, Any]] = field(default=None, repr=False)


# ---------------------------------------------------------------------------
# Name deduplication
# ---------------------------------------------------------------------------

_NAME_CLEANUP_RE = re.compile(r"[^a-zA-Z0-9_]")


def _sanitize_name(name: str) -> str:
    """Convert a Figma node name to a valid identifier.

    Replaces non-alphanumeric characters with underscores and ensures
    the result starts with a letter or underscore.

    Args:
        name: Raw Figma node name.

    Returns:
        Sanitized identifier string.
    """
    cleaned = _NAME_CLEANUP_RE.sub("_", name).strip("_")
    if not cleaned:
        return "Node"
    if cleaned[0].isdigit():
        cleaned = "_" + cleaned
    return cleaned


class _NameDeduplicator:
    """Tracks used names and appends numeric suffixes for uniqueness.

    Used during a single parse pass to ensure every ``FigmaIRNode.unique_name``
    is unique within the tree.
    """

    def __init__(self) -> None:
        self._counts: Dict[str, int] = {}

    def get_unique(self, name: str) -> str:
        """Return a unique version of the given name.

        Args:
            name: Sanitized base name.

        Returns:
            The name itself if unused, otherwise name + numeric suffix.
        """
        base = _sanitize_name(name)
        count = self._counts.get(base, 0)
        self._counts[base] = count + 1
        if count == 0:
            return base
        return f"{base}_{count}"


# ---------------------------------------------------------------------------
# Text segment merging
# ---------------------------------------------------------------------------


def merge_text_segments(
    characters: str,
    base_style: Optional[TypeStyle],
    overrides: Optional[List[int]],
    override_table: Optional[Dict[str, TypeStyle]],
) -> List[StyledTextSegment]:
    """Merge characterStyleOverrides with styleOverrideTable into segments.

    Figma represents styled text as a character string plus a parallel
    array of style override indices. This function groups consecutive
    characters with the same override index into ``StyledTextSegment``
    objects, each carrying the resolved ``TypeStyle``.

    Args:
        characters: The raw text content.
        base_style: Default TypeStyle for the text node.
        overrides: Per-character style override indices (0 = base style).
        override_table: Map of override index (as string) to TypeStyle.

    Returns:
        List of StyledTextSegment with contiguous style runs.
    """
    if not characters:
        return []

    if not overrides or not override_table:
        return [
            StyledTextSegment(
                text=characters,
                style=base_style,
                start=0,
                end=len(characters),
            )
        ]

    segments: List[StyledTextSegment] = []
    effective_overrides = overrides[:len(characters)]
    current_idx: int = effective_overrides[0]
    start: int = 0

    for i, char_override in enumerate(effective_overrides):
        if char_override != current_idx:
            # Flush segment
            style = (
                override_table.get(str(current_idx), base_style)
                if current_idx != 0
                else base_style
            )
            segments.append(
                StyledTextSegment(
                    text=characters[start:i],
                    style=style,
                    start=start,
                    end=i,
                )
            )
            current_idx = char_override
            start = i

    # Flush final segment (covers remaining characters beyond overrides)
    remaining_text = characters[start:]
    if remaining_text:
        style = (
            override_table.get(str(current_idx), base_style)
            if current_idx != 0
            else base_style
        )
        segments.append(
            StyledTextSegment(
                text=remaining_text,
                style=style,
                start=start,
                end=len(characters),
            )
        )

    return segments


# ---------------------------------------------------------------------------
# Core parser
# ---------------------------------------------------------------------------


def _has_vector_children(node: FigmaNodeBase, _depth: int = 0) -> bool:
    """Check if a node's subtree contains only vector primitives.

    Args:
        node: Figma node to check.
        _depth: Internal recursion depth counter.

    Returns:
        True if all children (recursively) are vector types.
    """
    if _depth > _MAX_PARSE_DEPTH:
        return False
    if not node.children:
        return node.type in _VECTOR_TYPES
    return all(_has_vector_children(child, _depth + 1) for child in node.children)


def _detect_icon_candidate(node: FigmaNodeBase) -> bool:
    """Determine if a node qualifies as an icon candidate.

    Icon candidates are nodes that are small (<=64x64) and contain
    only vector primitives. These are good candidates for inline SVG
    or image export rather than div-based rendering.

    Args:
        node: Figma node to evaluate.

    Returns:
        True if the node is an icon candidate.
    """
    bbox = node.absolute_bounding_box
    if bbox is None:
        return False
    if not math.isfinite(bbox.width) or not math.isfinite(bbox.height):
        return False
    if bbox.width > _ICON_MAX_SIZE or bbox.height > _ICON_MAX_SIZE:
        return False
    if bbox.width <= 0 or bbox.height <= 0:
        return False
    return _has_vector_children(node)


def _detect_svg_illustration(node: FigmaNodeBase) -> bool:
    """Determine if a node qualifies as an SVG illustration candidate.

    SVG illustration candidates are vector-only nodes that are larger than
    icons (>64px) but within an illustration-scale range (<=512px). These
    are suitable for inline SVG rendering with actual fill colors (unlike
    icons which always use currentColor).

    Args:
        node: Figma node to evaluate.

    Returns:
        True if the node is an SVG illustration candidate.
    """
    bbox = node.absolute_bounding_box
    if bbox is None:
        return False
    if not math.isfinite(bbox.width) or not math.isfinite(bbox.height):
        return False
    # Must be larger than icon threshold and within illustration range
    if bbox.width <= _ICON_MAX_SIZE and bbox.height <= _ICON_MAX_SIZE:
        return False
    if bbox.width > _SVG_ILLUSTRATION_MAX_SIZE or bbox.height > _SVG_ILLUSTRATION_MAX_SIZE:
        return False
    if bbox.width <= 0 or bbox.height <= 0:
        return False
    return _has_vector_children(node)


def _detect_image_fill(fills: List[Paint]) -> Tuple[bool, Optional[str]]:
    """Check fills for IMAGE type and extract image reference.

    Args:
        fills: List of Paint objects from a node.

    Returns:
        Tuple of (has_image_fill, image_ref_hash).
    """
    for fill in fills:
        if fill.type.value == "IMAGE" and fill.visible:
            return True, fill.image_ref
    return False, None


def _is_absolute_positioned(node: FigmaNodeBase) -> bool:
    """Determine if a node uses absolute positioning.

    A node is absolute-positioned if its ``layoutPositioning`` is set
    to ``"ABSOLUTE"`` in the Figma API response.

    Args:
        node: Figma node to check.

    Returns:
        True if the node is absolutely positioned.
    """
    return getattr(node, "layout_positioning", None) == "ABSOLUTE"


def _can_be_flattened(node: FigmaIRNode) -> bool:
    """Determine if a frame-like node can be flattened into its parent.

    A node can be flattened if it:
    - Has exactly one child
    - Has no auto-layout
    - Has no fills, strokes, or effects of its own
    - Has no corner radius
    - Is not clipping content

    Args:
        node: Parsed IR node to evaluate.

    Returns:
        True if the node can be safely flattened.
    """
    if len(node.children) != 1:
        return False
    if node.has_auto_layout:
        return False
    if node.fills or node.strokes or node.effects:
        return False
    if node.corner_radius > 0 or node.corner_radii:
        return False
    if node.clips_content:
        return False
    return True


_MAX_PARSE_DEPTH = 100  # BACK-P3-004: Guard against pathological nesting
_MAX_COLLECT_DEPTH = 10  # Depth ceiling for child geometry collection


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
        if not isinstance(child, dict):
            continue
        child_type = child.get("type", "")
        fill_geo = child.get("fillGeometry")
        stroke_geo = child.get("strokeGeometry")
        if fill_geo and isinstance(fill_geo, list):
            fill_result.extend(fill_geo)
        if stroke_geo and isinstance(stroke_geo, list):
            stroke_result.extend(stroke_geo)
        if not fill_geo and not stroke_geo:
            if child_type in _VECTOR_TYPES or child_type in _FRAME_LIKE_TYPES:
                # Recurse into nested groups / boolean ops
                sub_children = child.get("children", [])
                if sub_children:
                    sub_fill, sub_stroke = _collect_child_geometry(sub_children, _depth + 1)
                    fill_result.extend(sub_fill)
                    stroke_result.extend(sub_stroke)
    return fill_result, stroke_result


def parse_node(
    raw: Dict[str, Any],
    parent_rotation: float = 0.0,
    deduplicator: Optional[_NameDeduplicator] = None,
    _depth: int = 0,
) -> Optional[FigmaIRNode]:
    """Parse a raw Figma API node dict into an IR node.

    Recursively processes the node tree, applying transformations:
    - GROUP nodes are treated as FRAME-like containers
    - BOOLEAN_OPERATION nodes are marked as SVG candidates
    - TEXT nodes get their styled segments merged
    - Icon candidates are detected
    - Unsupported types are skipped with a debug log

    Args:
        raw: Raw Figma API node dictionary.
        parent_rotation: Accumulated rotation from ancestor nodes.
        deduplicator: Name deduplication tracker. Created automatically
            for the root call.
        _depth: Internal recursion depth counter.

    Returns:
        Parsed FigmaIRNode, or None if the node type is unsupported.
    """
    if _depth > _MAX_PARSE_DEPTH:
        logger.warning("Max parse depth (%d) exceeded, skipping subtree", _MAX_PARSE_DEPTH)
        return None
    if not isinstance(raw, dict):
        logger.debug("parse_node received non-dict argument: %r", type(raw))
        return None

    if deduplicator is None:
        deduplicator = _NameDeduplicator()

    node_type_str = raw.get("type", "")
    node_id = raw.get("id", "")
    node_name = raw.get("name", "")

    # Skip unsupported types
    if node_type_str in _UNSUPPORTED_TYPES:
        logger.debug("Skipping unsupported node type %s: %s", node_type_str, node_name)
        return None

    # Parse the raw dict into a Pydantic model for validated access
    pydantic_node = _parse_pydantic_node(raw, node_type_str)

    # Resolve node type enum
    try:
        node_type = NodeType(node_type_str)
    except ValueError:
        # Unknown type -- treat as generic frame if it has children
        if raw.get("children"):
            node_type = NodeType.FRAME
            logger.debug(
                "Unknown node type %s (%s) -- treating as FRAME", node_type_str, node_name
            )
        else:
            logger.debug("Skipping unknown leaf node type %s: %s", node_type_str, node_name)
            return None

    # Extract geometry
    bbox = pydantic_node.absolute_bounding_box
    width = bbox.width if bbox else 0.0
    height = bbox.height if bbox else 0.0
    x = bbox.x if bbox else 0.0
    y = bbox.y if bbox else 0.0

    rotation = pydantic_node.rotation or 0.0
    cumulative_rotation = parent_rotation + rotation

    # Detect image fills
    has_image_fill, image_ref = _detect_image_fill(pydantic_node.fills)

    # Build the IR node
    ir_node = FigmaIRNode(
        node_id=node_id,
        name=node_name,
        node_type=node_type,
        unique_name=deduplicator.get_unique(node_name),
        visible=pydantic_node.visible,
        opacity=pydantic_node.opacity if pydantic_node.opacity is not None else 1.0,
        width=width,
        height=height,
        x=x,
        y=y,
        rotation=rotation,
        cumulative_rotation=cumulative_rotation,
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
        has_image_fill=has_image_fill,
        image_ref=image_ref,
        component_id=pydantic_node.component_id,
        raw=raw,
    )

    # Blend mode
    blend_mode = raw.get("blendMode")
    if blend_mode and blend_mode != "PASS_THROUGH" and blend_mode != "NORMAL":
        ir_node.blend_mode = blend_mode

    # Text auto-resize mode
    text_auto_resize = raw.get("textAutoResize")
    if text_auto_resize:
        ir_node.text_auto_resize = text_auto_resize

    # Frame-like properties (auto-layout, clipping)
    if isinstance(pydantic_node, FrameNode) or node_type_str in _FRAME_LIKE_TYPES:
        _apply_frame_properties(ir_node, raw)

    # Boolean operation
    if isinstance(pydantic_node, BooleanOperationNode):
        ir_node.boolean_operation = (
            pydantic_node.boolean_operation.value
            if pydantic_node.boolean_operation is not None
            else None
        )
        ir_node.is_svg_candidate = True

    # Text properties
    if isinstance(pydantic_node, TextNode):
        _apply_text_properties(ir_node, pydantic_node)

    # Extract fillGeometry and strokeGeometry for vector/SVG nodes (actual path data)
    if node_type_str in _VECTOR_TYPES or ir_node.is_svg_candidate:
        fill_geo = raw.get("fillGeometry")
        if fill_geo and isinstance(fill_geo, list):
            ir_node.fill_geometry = fill_geo
        # BOOLEAN_OPERATION nodes do not have their own stroke geometry — skip
        if node_type_str != "BOOLEAN_OPERATION":
            stroke_geo = raw.get("strokeGeometry")
            if stroke_geo and isinstance(stroke_geo, list):
                ir_node.stroke_geometry = stroke_geo

    # For icon/SVG candidates without own geometry, collect from
    # descendant VECTOR nodes (e.g., BOOLEAN_OPERATION children, icon frames)
    if (
        ir_node.is_svg_candidate
        and not ir_node.fill_geometry
        and raw.get("children")
    ):
        fill_geo, stroke_geo = _collect_child_geometry(raw.get("children", []))
        ir_node.fill_geometry = fill_geo
        ir_node.stroke_geometry = stroke_geo

    # Override: icon candidates are also SVG candidates
    if ir_node.is_icon_candidate:
        ir_node.is_svg_candidate = True

    # SVG illustration candidates (64px < size <= 512px, vector-only) are SVG candidates
    if not ir_node.is_svg_candidate and _detect_svg_illustration(pydantic_node):
        ir_node.is_svg_candidate = True

    # VEIL-002: Inherently SVG types (LINE, REGULAR_POLYGON, STAR) must always
    # render as SVG — they have no meaningful non-SVG representation
    if not ir_node.is_svg_candidate and node_type_str in _INHERENTLY_SVG_TYPES:
        ir_node.is_svg_candidate = True

    # Recursively parse children
    for child_raw in raw.get("children", []):
        child = parse_node(child_raw, cumulative_rotation, deduplicator, _depth + 1)
        if child is not None:
            ir_node.children.append(child)

    # Compute can_be_flattened after children are parsed
    if ir_node.is_frame_like:
        ir_node.can_be_flattened = _can_be_flattened(ir_node)

    return ir_node


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


def _apply_frame_properties(ir_node: FigmaIRNode, raw: Dict[str, Any]) -> None:
    """Extract auto-layout and frame properties from raw data.

    Args:
        ir_node: IR node to populate.
        raw: Raw Figma API node dictionary.
    """
    layout_mode_str = raw.get("layoutMode")
    if layout_mode_str and layout_mode_str != "NONE":
        try:
            ir_node.layout_mode = LayoutMode(layout_mode_str)
        except ValueError:
            ir_node.layout_mode = LayoutMode.NONE
        ir_node.has_auto_layout = ir_node.layout_mode != LayoutMode.NONE

    # Wrap
    wrap_str = raw.get("layoutWrap")
    if wrap_str:
        try:
            ir_node.layout_wrap = LayoutWrap(wrap_str)
        except ValueError:
            logger.debug("Unknown layoutWrap value: %s", wrap_str)

    # Alignment
    pa = raw.get("primaryAxisAlignItems")
    if pa:
        try:
            ir_node.primary_axis_align = LayoutAlign(pa)
        except ValueError:
            logger.debug("Unknown primaryAxisAlignItems value: %s", pa)

    ca = raw.get("counterAxisAlignItems")
    if ca:
        try:
            ir_node.counter_axis_align = LayoutAlign(ca)
        except ValueError:
            logger.debug("Unknown counterAxisAlignItems value: %s", ca)

    cac = raw.get("counterAxisAlignContent")
    if cac:
        try:
            ir_node.counter_axis_align_content = LayoutAlign(cac)
        except ValueError:
            logger.debug("Unknown counterAxisAlignContent value: %s", cac)

    # Spacing
    ir_node.item_spacing = raw.get("itemSpacing", 0.0)
    ir_node.counter_axis_spacing = raw.get("counterAxisSpacing")

    # Padding
    ir_node.padding = (
        raw.get("paddingTop", 0.0),
        raw.get("paddingRight", 0.0),
        raw.get("paddingBottom", 0.0),
        raw.get("paddingLeft", 0.0),
    )

    # Sizing modes
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

    ir_node.layout_grow = raw.get("layoutGrow")

    # Min/max constraints (v5)
    ir_node.min_width = raw.get("minWidth")
    ir_node.max_width = raw.get("maxWidth")
    ir_node.min_height = raw.get("minHeight")
    ir_node.max_height = raw.get("maxHeight")

    # Grid (v5)
    ir_node.layout_grid_columns = raw.get("layoutGridColumns")
    ir_node.layout_grid_cell_min_width = raw.get("layoutGridCellMinWidth")

    # Clipping
    ir_node.clips_content = raw.get("clipsContent", False)


def _apply_text_properties(ir_node: FigmaIRNode, text_node: TextNode) -> None:
    """Extract text-specific properties into the IR node.

    Args:
        ir_node: IR node to populate.
        text_node: Parsed TextNode Pydantic model.
    """
    ir_node.text_content = text_node.characters
    ir_node.text_style = text_node.style
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
