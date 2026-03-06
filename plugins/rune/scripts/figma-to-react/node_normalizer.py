"""Node normalization utilities extracted from node_parser.py.

Contains detection, classification, and name deduplication functions
that operate on FigmaNodeBase (Pydantic) or FigmaIRNode (IR) types.
Keeps node_parser.py focused on parse_node() and the IR dataclass.

All functions maintain their original private naming (_-prefix) and
are re-exported from node_parser.py for backward compatibility.
"""

from __future__ import annotations

import logging
import math
import re
from typing import Any, Dict, FrozenSet, List, Optional, Tuple

from figma_types import (
    FigmaNodeBase,
    FigmaPropertyType,
    LayoutMode,
    NodeType,
    Paint,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_ICON_MAX_SIZE: float = 64.0
_SVG_ILLUSTRATION_MAX_SIZE: float = 512.0
_MAX_PARSE_DEPTH = 100

_VECTOR_TYPES: FrozenSet[str] = frozenset({
    "VECTOR", "BOOLEAN_OPERATION", "ELLIPSE", "RECTANGLE",
    "LINE", "REGULAR_POLYGON", "STAR",
})

_NAME_CLEANUP_RE = re.compile(r"[^a-zA-Z0-9_]")

_INSTANCE_PROP_MAX_SIZE: float = 48.0

_SLOT_KEYWORDS: FrozenSet[str] = frozenset({
    "content", "slot", "body", "actions", "header", "footer",
    "children", "main", "sidebar", "overlay",
})

_GENERIC_SLOT_NAMES: FrozenSet[str] = frozenset({
    "content", "children", "body", "slot",
})


# ---------------------------------------------------------------------------
# Name sanitization and deduplication
# ---------------------------------------------------------------------------


def _sanitize_name(name: str) -> str:
    """Convert a Figma node name to a valid identifier.

    Replaces non-alphanumeric characters with underscores and ensures
    the result starts with a letter or underscore.
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
        """Return a unique version of the given name."""
        base = _sanitize_name(name)
        count = self._counts.get(base, 0)
        self._counts[base] = count + 1
        if count == 0:
            return base
        return f"{base}_{count}"


# ---------------------------------------------------------------------------
# Detection functions
# ---------------------------------------------------------------------------


def _has_vector_children(node: FigmaNodeBase, _depth: int = 0) -> bool:
    """Check if a node's subtree contains only vector primitives."""
    if _depth > _MAX_PARSE_DEPTH:
        return False
    if not node.children:
        return node.type in _VECTOR_TYPES
    return all(_has_vector_children(child, _depth + 1) for child in node.children)


def _detect_icon_candidate(node: FigmaNodeBase) -> bool:
    """Determine if a node qualifies as an icon candidate.

    Icon candidates are nodes that are small (<=64x64) and contain
    only vector primitives.
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
    icons (>64px) but within an illustration-scale range (<=512px).
    """
    bbox = node.absolute_bounding_box
    if bbox is None:
        return False
    if not math.isfinite(bbox.width) or not math.isfinite(bbox.height):
        return False
    if bbox.width <= _ICON_MAX_SIZE and bbox.height <= _ICON_MAX_SIZE:
        return False
    if bbox.width > _SVG_ILLUSTRATION_MAX_SIZE or bbox.height > _SVG_ILLUSTRATION_MAX_SIZE:
        return False
    if bbox.width <= 0 or bbox.height <= 0:
        return False
    return _has_vector_children(node)


def _detect_image_fill(fills: List[Paint]) -> Tuple[bool, Optional[str]]:
    """Check fills for IMAGE type and extract image reference."""
    for fill in fills:
        if fill.type.value == "IMAGE" and fill.visible:
            return True, fill.image_ref
    return False, None


def _is_absolute_positioned(node: FigmaNodeBase) -> bool:
    """Determine if a node uses absolute positioning."""
    return getattr(node, "layout_positioning", None) == "ABSOLUTE"


# ---------------------------------------------------------------------------
# Instance role classification (Phase 2)
# ---------------------------------------------------------------------------

# Uses Any for ir_node/parent_ir to avoid circular import with node_parser.
# InstanceRole enum is passed as parameter.


def _classify_instance_role(
    ir_node: Any,
    parent_ir: Any = None,
    InstanceRole: Any = None,
) -> Any:
    """Classify the semantic role of an INSTANCE node.

    Rules (in priority order):
    1. Not an instance (no component_id) -> None
    2. Has children -> CHILD (container, never PROP)
    3. Matches parent's INSTANCE_SWAP property -> PROP
    4. Icon-sized (<=48x48) with no children -> PROP
    5. Absolutely positioned -> STANDALONE
    6. Default -> CHILD
    """
    if not ir_node.component_id:
        return None

    if len(ir_node.children) > 0:
        return InstanceRole.CHILD

    if parent_ir and parent_ir.component_property_definitions:
        for _key, prop_def in parent_ir.component_property_definitions.items():
            if prop_def.type == FigmaPropertyType.INSTANCE_SWAP:
                return InstanceRole.PROP

    if (
        ir_node.is_icon_candidate
        or (ir_node.width <= _INSTANCE_PROP_MAX_SIZE
            and ir_node.height <= _INSTANCE_PROP_MAX_SIZE
            and ir_node.width > 0
            and ir_node.height > 0)
    ):
        return InstanceRole.PROP

    if ir_node.is_absolute_positioned:
        return InstanceRole.STANDALONE

    return InstanceRole.CHILD


# ---------------------------------------------------------------------------
# Slot detection (Phase 6)
# ---------------------------------------------------------------------------


def _detect_slot_candidate(
    ir_node: Any,
    parent_ir: Any = None,
) -> bool:
    """Detect whether a frame-like node qualifies as a slot.

    A slot is a frame with a slot-like name, active auto-layout, and is
    a direct child of a COMPONENT or COMPONENT_SET node.

    Mutates ir_node fields: is_slot_candidate, is_empty_slot,
    is_decorative_container, slot_name.

    Returns True if the node is a slot candidate.
    """
    if not ir_node.is_frame_like:
        return False

    if parent_ir is None:
        return False
    if parent_ir.node_type not in (NodeType.COMPONENT, NodeType.COMPONENT_SET):
        return False

    name_lower = ir_node.name.lower().strip()
    is_keyword_match = (
        name_lower in _SLOT_KEYWORDS
        or any(name_lower.startswith(kw + " ") or name_lower.startswith(kw + "-")
               for kw in _SLOT_KEYWORDS)
    )
    if not is_keyword_match:
        return False

    if ir_node.layout_mode == LayoutMode.NONE:
        ir_node.is_decorative_container = (
            not ir_node.fills and not ir_node.strokes and not ir_node.effects
        )
        return False

    ir_node.is_slot_candidate = True
    ir_node.is_empty_slot = len(ir_node.children) == 0
    ir_node.slot_name = ir_node.name
    return True


# ---------------------------------------------------------------------------
# Node flattening
# ---------------------------------------------------------------------------


def _can_be_flattened(node: Any) -> bool:
    """Determine if a frame-like node can be flattened into its parent.

    A node can be flattened if it:
    - Has exactly one child
    - Has no auto-layout
    - Has no fills, strokes, or effects of its own
    - Has no corner radius
    - Is not clipping content
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
