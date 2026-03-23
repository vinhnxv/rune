"""Semantic classifier for Figma IR nodes.

Assigns UI component roles (e.g. ``"pagination"``, ``"avatar"``,
``"data-table"``) to :class:`FigmaIRNode` instances using a 3-tier
classification strategy:

1. **Name-based** — regex patterns on ``node.name`` (fast, high confidence).
2. **Structural heuristic** — analyse children composition, dimensions,
   and layout properties (medium confidence).
3. **Component property inference** — inspect
   ``component_property_definitions`` for trait combinations that imply
   a component role (lower confidence).

Main API
--------
- :func:`classify` — classify a single node, returns ``(role, confidence)``.
- :func:`annotate` — walk the IR tree and set ``semantic_role`` /
  ``semantic_confidence`` on every node.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING, Dict, List, Optional, Tuple

from figma_types import (
    FigmaPropertyType,
    LayoutMode,
    NodeType,
    PaintType,
)

if TYPE_CHECKING:
    from node_parser import FigmaIRNode

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Minimum confidence score required for a classification to be accepted.
CONFIDENCE_THRESHOLD: float = 0.70

# ---------------------------------------------------------------------------
# Tier 1 — Name-based patterns
# ---------------------------------------------------------------------------

#: Mapping of semantic role to compiled regex.  Patterns are matched
#: case-insensitively against ``node.name``.
_NAME_PATTERNS: Dict[str, re.Pattern[str]] = {
    "pagination": re.compile(r"pagination|paginator|page[\s_-]?nav", re.IGNORECASE),
    "avatar": re.compile(r"avatar|profile[\s_-]?pic|user[\s_-]?image", re.IGNORECASE),
    "toolbar": re.compile(r"toolbar|tool[\s_-]?bar|action[\s_-]?bar", re.IGNORECASE),
    "data-table": re.compile(
        r"data[\s_-]?table|table[\s_-]?view|grid[\s_-]?table", re.IGNORECASE
    ),
    "breadcrumb": re.compile(r"breadcrumb", re.IGNORECASE),
    "tabs": re.compile(r"\btabs?\b|tab[\s_-]?bar|tab[\s_-]?group", re.IGNORECASE),
    "search": re.compile(r"search[\s_-]?bar|search[\s_-]?input|search[\s_-]?field", re.IGNORECASE),
    "badge": re.compile(r"\bbadge\b|status[\s_-]?badge|chip", re.IGNORECASE),
    "card": re.compile(r"\bcard\b|content[\s_-]?card", re.IGNORECASE),
    "modal": re.compile(r"\bmodal\b|dialog|overlay[\s_-]?panel", re.IGNORECASE),
    "sidebar": re.compile(r"sidebar|side[\s_-]?bar|side[\s_-]?nav|nav[\s_-]?panel", re.IGNORECASE),
    "stepper": re.compile(r"stepper|step[\s_-]?indicator|progress[\s_-]?steps", re.IGNORECASE),
    "empty-state": re.compile(
        r"empty[\s_-]?state|no[\s_-]?data|no[\s_-]?results|placeholder[\s_-]?state",
        re.IGNORECASE,
    ),
}

#: Confidence assigned to name-based matches.
_NAME_CONFIDENCE: float = 0.90


def _classify_by_name(node: FigmaIRNode) -> Tuple[Optional[str], float]:
    """Tier 1: match ``node.name`` against known regex patterns.

    Returns:
        ``(role, confidence)`` if matched, otherwise ``(None, 0.0)``.
    """
    name = node.name
    if not name:
        return None, 0.0

    for role, pattern in _NAME_PATTERNS.items():
        if pattern.search(name):
            return role, _NAME_CONFIDENCE
    return None, 0.0


# ---------------------------------------------------------------------------
# Tier 2 — Structural heuristic
# ---------------------------------------------------------------------------

_STRUCTURAL_CONFIDENCE: float = 0.78


def _has_icon_child(children: List[FigmaIRNode]) -> bool:
    """Return ``True`` if any child looks like an icon (vector or small SVG)."""
    for c in children:
        if c.node_type == NodeType.VECTOR:
            return True
        if c.is_icon_candidate:
            return True
    return False


def _is_horizontal_frame(node: FigmaIRNode) -> bool:
    """Check whether *node* is a horizontally laid-out auto-layout frame."""
    return node.has_auto_layout and node.layout_mode == LayoutMode.HORIZONTAL


def _is_rounded(node: FigmaIRNode, threshold: float = 50.0) -> bool:
    """Return ``True`` if the node has corner radius >= *threshold* percent.

    For avatars, a corner radius of >= 50% of the smallest dimension
    produces a circle.  We check against the raw ``corner_radius`` value
    because the IR stores the absolute pixel value, not a percentage —
    so we compare it to half the smallest dimension instead.
    """
    if node.corner_radius <= 0:
        return False
    min_dim = min(node.width, node.height) if node.width and node.height else 0
    if min_dim == 0:
        return False
    return (node.corner_radius / min_dim) * 100 >= threshold


def _has_image_fill(node: FigmaIRNode) -> bool:
    """Return ``True`` if the node has an image-type fill."""
    return node.has_image_fill or any(
        f.type == PaintType.IMAGE for f in node.fills
    )


def _classify_pagination(node: FigmaIRNode) -> bool:
    """Heuristic: horizontal frame + icon children + numeric text."""
    if not _is_horizontal_frame(node):
        return False
    children = node.children
    if len(children) < 3:
        return False
    has_icon = _has_icon_child(children)
    has_numeric_text = any(
        c.node_type == NodeType.TEXT
        and c.text_content
        and any(ch.isdigit() for ch in c.text_content)
        for c in children
    )
    return has_icon and has_numeric_text


def _classify_avatar(node: FigmaIRNode) -> bool:
    """Heuristic: small (<= 64px), rounded (>= 50%), image fill."""
    if node.width > 64 or node.height > 64:
        return False
    if not _is_rounded(node):
        return False
    return _has_image_fill(node)


def _classify_data_table(node: FigmaIRNode) -> bool:
    """Heuristic: repeated children with shared layout (rows)."""
    children = node.children
    if len(children) < 3:
        return False
    # Check that most children are frame-like (rows) with similar widths.
    frame_children = [c for c in children if c.is_frame_like]
    if len(frame_children) < 3:
        return False
    # All row widths within 5% of the first row.
    ref_width = frame_children[0].width
    if ref_width == 0:
        return False
    return all(
        abs(c.width - ref_width) / ref_width < 0.05
        for c in frame_children[1:]
        if c.width > 0
    )


def _classify_stepper(node: FigmaIRNode) -> bool:
    """Heuristic: horizontal + arrow/separator children + 3+ card-like children."""
    if not _is_horizontal_frame(node):
        return False
    children = node.children
    if len(children) < 5:
        return False
    # Look for arrow-like separators (vectors) interspersed with frames.
    frames = [c for c in children if c.is_frame_like]
    separators = [c for c in children if c.node_type == NodeType.VECTOR or c.is_icon_candidate]
    return len(frames) >= 3 and len(separators) >= 2


def _classify_by_structure(node: FigmaIRNode) -> Tuple[Optional[str], float]:
    """Tier 2: analyse node dimensions, layout, and children composition.

    Returns:
        ``(role, confidence)`` if a heuristic matches, otherwise
        ``(None, 0.0)``.
    """
    if _classify_pagination(node):
        return "pagination", _STRUCTURAL_CONFIDENCE
    if _classify_avatar(node):
        return "avatar", _STRUCTURAL_CONFIDENCE
    if _classify_stepper(node):
        return "stepper", _STRUCTURAL_CONFIDENCE
    if _classify_data_table(node):
        return "data-table", _STRUCTURAL_CONFIDENCE

    return None, 0.0


# ---------------------------------------------------------------------------
# Tier 3 — Component property inference
# ---------------------------------------------------------------------------

_PROPERTY_CONFIDENCE: float = 0.72

#: Property name patterns that suggest interactive/selectable components.
_SELECTABLE_PROPS = re.compile(
    r"selected|active|checked|is[\s_-]?selected|is[\s_-]?active",
    re.IGNORECASE,
)

#: Property name patterns that suggest form-control components.
_SIZE_PROPS = re.compile(r"\bsize\b|dimension", re.IGNORECASE)
_VARIANT_PROPS = re.compile(r"\bvariant\b|style[\s_-]?type|appearance", re.IGNORECASE)


def _classify_by_properties(node: FigmaIRNode) -> Tuple[Optional[str], float]:
    """Tier 3: inspect ``component_property_definitions`` for trait combos.

    Returns:
        ``(role, confidence)`` if property patterns match, otherwise
        ``(None, 0.0)``.
    """
    props = node.component_property_definitions
    if not props:
        return None, 0.0

    prop_names = list(props.keys())
    prop_types = {name: defn.type for name, defn in props.items()}

    has_size = any(_SIZE_PROPS.search(n) for n in prop_names)
    has_variant = any(
        _VARIANT_PROPS.search(n)
        or prop_types.get(n) == FigmaPropertyType.VARIANT
        for n in prop_names
    )
    has_selectable = any(_SELECTABLE_PROPS.search(n) for n in prop_names)

    # size + variant → form-control (input, select, button, etc.)
    if has_size and has_variant:
        return "form-control", _PROPERTY_CONFIDENCE

    # selected/active/checked boolean → selectable element
    if has_selectable:
        return "selectable", _PROPERTY_CONFIDENCE

    return None, 0.0


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def classify(node: FigmaIRNode) -> Tuple[Optional[str], float]:
    """Classify a single IR node into a semantic UI role.

    Applies the 3-tier classification cascade:

    1. Name-based regex (confidence 0.90)
    2. Structural heuristic (confidence 0.78)
    3. Component property inference (confidence 0.72)

    The first tier to produce a result above :data:`CONFIDENCE_THRESHOLD`
    wins.

    Args:
        node: The Figma IR node to classify.

    Returns:
        A ``(role, confidence)`` tuple.  If no tier matches, returns
        ``(None, 0.0)``.
    """
    # Tier 1 — fastest, highest confidence
    role, confidence = _classify_by_name(node)
    if role and confidence >= CONFIDENCE_THRESHOLD:
        return role, confidence

    # Tier 2 — structural analysis
    role, confidence = _classify_by_structure(node)
    if role and confidence >= CONFIDENCE_THRESHOLD:
        return role, confidence

    # Tier 3 — property-based
    role, confidence = _classify_by_properties(node)
    if role and confidence >= CONFIDENCE_THRESHOLD:
        return role, confidence

    return None, 0.0


def annotate(root: FigmaIRNode) -> FigmaIRNode:
    """Walk the IR tree and set ``semantic_role`` / ``semantic_confidence``.

    Mutates each node in-place by setting the ``semantic_role`` and
    ``semantic_confidence`` attributes (if the fields exist on the
    dataclass).  Nodes that cannot be classified receive ``None`` and
    ``0.0`` respectively.

    Args:
        root: The root of the IR tree to annotate.

    Returns:
        The same *root* node (for chaining convenience).
    """
    _annotate_recursive(root)
    return root


def _annotate_recursive(node: FigmaIRNode) -> None:
    """Recursively classify and annotate *node* and its children."""
    role, confidence = classify(node)

    # Only set attributes if the fields exist on the dataclass.
    # This allows the classifier to be used before or after the IR
    # schema is extended with semantic fields.
    if hasattr(node, "semantic_role"):
        node.semantic_role = role  # type: ignore[attr-defined]
    if hasattr(node, "semantic_confidence"):
        node.semantic_confidence = confidence  # type: ignore[attr-defined]

    for child in node.children:
        _annotate_recursive(child)
