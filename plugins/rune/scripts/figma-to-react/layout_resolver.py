"""Auto-layout detection and CSS layout class generation.

Translates Figma's auto-layout properties into Tailwind CSS flexbox
and grid classes. Handles:

- HORIZONTAL/VERTICAL layouts -> flex + flex-row/flex-col
- Grid layouts (v5) -> grid + grid-cols-{N}
- Alignment (primary/counter axis) -> justify-*/items-*
- Spacing -> gap-{N}
- Wrapping -> flex-wrap
- Child sizing (FILL/HUG/FIXED) -> w-full/flex-1/w-auto/explicit
- Min/max constraints -> min-w-[Npx]/max-w-[Npx]
- Absolute positioning detection
"""

from __future__ import annotations

from typing import List, Optional

from figma_types import LayoutAlign, LayoutMode, LayoutSizingMode, LayoutWrap
from node_parser import FigmaIRNode
from tailwind_mapper import _px_to_spacing


# ---------------------------------------------------------------------------
# Layout result
# ---------------------------------------------------------------------------


class LayoutClasses:
    """Container for resolved layout classes.

    Separates parent (container) classes from child-specific classes
    to allow correct placement in React component generation.

    Attributes:
        container: Classes for the parent/container element.
        self_classes: Classes for the node itself (as a child of a layout).
    """

    def __init__(self) -> None:
        self.container: List[str] = []
        self.self_classes: List[str] = []

    def all_classes(self) -> List[str]:
        """Return all classes combined.

        Returns:
            Combined list of container and self classes.
        """
        return self.container + self.self_classes


# ---------------------------------------------------------------------------
# Primary axis alignment mapping
# ---------------------------------------------------------------------------

# Figma primaryAxisAlignItems -> Tailwind justify-* class
_JUSTIFY_MAP = {
    LayoutAlign.MIN: "justify-start",
    LayoutAlign.CENTER: "justify-center",
    LayoutAlign.MAX: "justify-end",
    LayoutAlign.SPACE_BETWEEN: "justify-between",
}

# Figma counterAxisAlignItems -> Tailwind items-* class
_ITEMS_MAP = {
    LayoutAlign.MIN: "items-start",
    LayoutAlign.CENTER: "items-center",
    LayoutAlign.MAX: "items-end",
    LayoutAlign.BASELINE: "items-baseline",
}

# Figma counterAxisAlignContent -> Tailwind content-* class (for wrapped layouts)
_CONTENT_MAP = {
    LayoutAlign.MIN: "content-start",
    LayoutAlign.CENTER: "content-center",
    LayoutAlign.MAX: "content-end",
    LayoutAlign.SPACE_BETWEEN: "content-between",
}


# ---------------------------------------------------------------------------
# Layout resolver functions
# ---------------------------------------------------------------------------


def resolve_container_layout(node: FigmaIRNode) -> LayoutClasses:
    """Resolve layout classes for a container (parent) node.

    Examines the node's auto-layout properties and generates the
    appropriate Tailwind flex/grid classes for the container.

    Args:
        node: Parsed IR node with auto-layout properties.

    Returns:
        LayoutClasses with container classes populated.
    """
    result = LayoutClasses()

    if not node.has_auto_layout:
        # No auto-layout -- check if this is a positioned container
        if node.is_frame_like and node.children:
            result.container.append("relative")
        return result

    # Grid layout (v5)
    if node.layout_grid_columns is not None and node.layout_grid_columns > 0:
        return _resolve_grid_layout(node, result)

    # Flexbox layout
    return _resolve_flex_layout(node, result)


def _resolve_horizontal_sizing(
    child: FigmaIRNode,
    is_horizontal: bool,
    classes: List[str],
) -> None:
    """Append horizontal sizing classes for a child node.

    Args:
        child: The child IR node.
        is_horizontal: Whether the parent layout is horizontal.
        classes: List to append classes to (mutated in place).
    """
    h_sizing = child.layout_sizing_horizontal
    if h_sizing == LayoutSizingMode.FILL:
        classes.append("flex-1" if is_horizontal else "w-full")
    elif h_sizing == LayoutSizingMode.FIXED:
        if child.width > 0:
            classes.append(f"w-{_px_to_spacing(child.width)}")
    # HUG: default — no class needed


def _resolve_vertical_sizing(
    child: FigmaIRNode,
    is_horizontal: bool,
    classes: List[str],
) -> None:
    """Append vertical sizing classes for a child node.

    Args:
        child: The child IR node.
        is_horizontal: Whether the parent layout is horizontal.
        classes: List to append classes to (mutated in place).
    """
    v_sizing = child.layout_sizing_vertical
    if v_sizing == LayoutSizingMode.FILL:
        classes.append("flex-1" if not is_horizontal else "h-full")
    elif v_sizing == LayoutSizingMode.FIXED:
        if child.height > 0:
            classes.append(f"h-{_px_to_spacing(child.height)}")
    # HUG: default — no class needed


def resolve_child_layout(
    child: FigmaIRNode,
    parent: FigmaIRNode,
) -> List[str]:
    """Resolve layout classes for a child node within its parent's layout.

    Generates sizing classes (flex-1, w-full, etc.) based on how the
    child participates in the parent's auto-layout.

    Args:
        child: The child IR node.
        parent: The parent IR node with auto-layout.

    Returns:
        List of Tailwind classes for the child's layout behavior.
    """
    classes: List[str] = []

    # Absolute positioning overrides layout participation
    if child.is_absolute_positioned:
        classes.append("absolute")
        # Constraint-based positioning for absolutely positioned children
        _apply_constraint_classes(child, classes)
        return classes

    if not parent.has_auto_layout:
        return classes

    is_horizontal = parent.layout_mode == LayoutMode.HORIZONTAL

    _resolve_horizontal_sizing(child, is_horizontal, classes)
    _resolve_vertical_sizing(child, is_horizontal, classes)

    # Layout grow (explicit flex-grow value)
    if child.layout_grow is not None and child.layout_grow > 0:
        if "flex-1" not in classes:
            classes.append("grow")

    return classes


# ---------------------------------------------------------------------------
# Flex layout
# ---------------------------------------------------------------------------


def _resolve_flex_alignment(node: FigmaIRNode, result: LayoutClasses) -> None:
    """Append flex alignment classes (justify, items, content) to result.

    Args:
        node: Container node with auto-layout alignment properties.
        result: LayoutClasses to append to (mutated in place).
    """
    if node.primary_axis_align is not None:
        justify = _JUSTIFY_MAP.get(node.primary_axis_align)
        if justify:
            result.container.append(justify)

    if node.counter_axis_align is not None:
        items = _ITEMS_MAP.get(node.counter_axis_align)
        if items:
            result.container.append(items)

    if (
        node.layout_wrap == LayoutWrap.WRAP
        and node.counter_axis_align_content is not None
    ):
        content = _CONTENT_MAP.get(node.counter_axis_align_content)
        if content:
            result.container.append(content)


def _resolve_flex_gap(node: FigmaIRNode, result: LayoutClasses) -> None:
    """Append flex gap classes (gap, gap-y/gap-x for wrap) to result.

    Args:
        node: Container node with spacing properties.
        result: LayoutClasses to append to (mutated in place).
    """
    if node.item_spacing > 0:
        result.container.append(f"gap-{_px_to_spacing(node.item_spacing)}")

    if (
        node.layout_wrap == LayoutWrap.WRAP
        and node.counter_axis_spacing is not None
        and node.counter_axis_spacing > 0
    ):
        if node.layout_mode == LayoutMode.HORIZONTAL:
            result.container.append(
                f"gap-y-{_px_to_spacing(node.counter_axis_spacing)}"
            )
        else:
            result.container.append(
                f"gap-x-{_px_to_spacing(node.counter_axis_spacing)}"
            )


def _resolve_flex_layout(
    node: FigmaIRNode,
    result: LayoutClasses,
) -> LayoutClasses:
    """Resolve flexbox layout classes.

    Args:
        node: Container node with auto-layout.
        result: LayoutClasses to populate.

    Returns:
        The populated LayoutClasses.
    """
    result.container.append("flex")

    # Direction
    if node.layout_mode == LayoutMode.HORIZONTAL:
        result.container.append("flex-row")
    elif node.layout_mode == LayoutMode.VERTICAL:
        result.container.append("flex-col")

    # Wrap
    if node.layout_wrap == LayoutWrap.WRAP:
        result.container.append("flex-wrap")

    _resolve_flex_alignment(node, result)
    _resolve_flex_gap(node, result)

    # Padding
    _resolve_padding(node, result)

    # Overflow
    if node.clips_content:
        result.container.append("overflow-hidden")

    # Min/max constraints
    _resolve_constraints(node, result)

    return result


# ---------------------------------------------------------------------------
# Grid layout
# ---------------------------------------------------------------------------


def _resolve_grid_columns(node: FigmaIRNode, result: LayoutClasses) -> None:
    """Append grid column classes, handling auto-fill responsive override.

    Args:
        node: Container node with grid column properties.
        result: LayoutClasses to append to (mutated in place).
    """
    cols = node.layout_grid_columns
    if cols is not None and cols > 0:
        result.container.append(f"grid-cols-{cols}")

    if node.layout_grid_cell_min_width is not None and node.layout_grid_cell_min_width > 0:
        min_w = node.layout_grid_cell_min_width
        result.container.append(
            f"grid-cols-[repeat(auto-fill,minmax({min_w:.0f}px,1fr))]"
        )
        cols_class = f"grid-cols-{cols}" if cols else None
        if cols_class and cols_class in result.container:
            result.container.remove(cols_class)


def _resolve_grid_gap(node: FigmaIRNode, result: LayoutClasses) -> None:
    """Append grid gap classes to result.

    Args:
        node: Container node with spacing properties.
        result: LayoutClasses to append to (mutated in place).
    """
    if node.item_spacing > 0:
        result.container.append(f"gap-{_px_to_spacing(node.item_spacing)}")
    if node.counter_axis_spacing is not None and node.counter_axis_spacing > 0:
        result.container.append(
            f"gap-y-{_px_to_spacing(node.counter_axis_spacing)}"
        )


def _resolve_grid_layout(
    node: FigmaIRNode,
    result: LayoutClasses,
) -> LayoutClasses:
    """Resolve CSS Grid layout classes (Figma v5 grid mode).

    Args:
        node: Container node with grid layout properties.
        result: LayoutClasses to populate.

    Returns:
        The populated LayoutClasses.
    """
    result.container.append("grid")

    _resolve_grid_columns(node, result)
    _resolve_grid_gap(node, result)

    # Alignment
    if node.primary_axis_align is not None:
        justify = _JUSTIFY_MAP.get(node.primary_axis_align)
        if justify:
            result.container.append(justify)

    if node.counter_axis_align is not None:
        items = _ITEMS_MAP.get(node.counter_axis_align)
        if items:
            result.container.append(items)

    # Padding
    _resolve_padding(node, result)

    # Overflow
    if node.clips_content:
        result.container.append("overflow-hidden")

    # Min/max constraints
    _resolve_constraints(node, result)

    return result


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _resolve_padding(node: FigmaIRNode, result: LayoutClasses) -> None:
    """Add padding classes to the layout result.

    Uses smart optimization: all-equal -> p-N, h+v-equal -> px-N py-M.

    Args:
        node: IR node with padding tuple.
        result: LayoutClasses to append to.
    """
    top, right, bottom, left = node.padding

    if all(v == 0 for v in (top, right, bottom, left)):
        return

    if top == right == bottom == left:
        result.container.append(f"p-{_px_to_spacing(top)}")
    elif top == bottom and left == right:
        if left > 0:
            result.container.append(f"px-{_px_to_spacing(left)}")
        if top > 0:
            result.container.append(f"py-{_px_to_spacing(top)}")
    else:
        if top > 0:
            result.container.append(f"pt-{_px_to_spacing(top)}")
        if right > 0:
            result.container.append(f"pr-{_px_to_spacing(right)}")
        if bottom > 0:
            result.container.append(f"pb-{_px_to_spacing(bottom)}")
        if left > 0:
            result.container.append(f"pl-{_px_to_spacing(left)}")


def _resolve_constraints(node: FigmaIRNode, result: LayoutClasses) -> None:
    """Add min/max dimension constraint classes.

    Args:
        node: IR node with constraint properties.
        result: LayoutClasses to append to.
    """
    if node.min_width is not None and node.min_width > 0:
        result.container.append(f"min-w-{_px_to_spacing(node.min_width)}")
    if node.max_width is not None and node.max_width > 0:
        result.container.append(f"max-w-{_px_to_spacing(node.max_width)}")
    if node.min_height is not None and node.min_height > 0:
        result.container.append(f"min-h-{_px_to_spacing(node.min_height)}")
    if node.max_height is not None and node.max_height > 0:
        result.container.append(f"max-h-{_px_to_spacing(node.max_height)}")


def _apply_constraint_classes(node: FigmaIRNode, classes: List[str]) -> None:
    """Apply Tailwind position classes based on Figma constraint settings.

    Maps Figma's constraint system to CSS inset properties:
    - TOP/LEFT/MIN: pin to start edge (top-N / left-N)
    - BOTTOM/RIGHT/MAX: pin to end edge (bottom-N / right-N)
    - TOP_BOTTOM/LEFT_RIGHT/STRETCH: pin both edges (inset-y-0 / inset-x-0)
    - CENTER/SCALE: center with translate

    Args:
        node: Absolutely-positioned IR node with constraint fields.
        classes: List to append constraint classes to (mutated).
    """
    h = node.constraint_horizontal
    v = node.constraint_vertical

    # Vertical constraints
    if v in ("TOP", "MIN"):
        classes.append(f"top-{_px_to_spacing(node.y)}")
    elif v in ("BOTTOM", "MAX"):
        classes.append("bottom-0")
    elif v in ("TOP_BOTTOM", "STRETCH"):
        classes.append("inset-y-0")
    elif v in ("CENTER", "SCALE"):
        classes.append("top-1/2")
        classes.append("-translate-y-1/2")
    else:
        # Default: use y position
        classes.append(f"top-{_px_to_spacing(node.y)}")

    # Horizontal constraints
    if h in ("LEFT", "MIN"):
        classes.append(f"left-{_px_to_spacing(node.x)}")
    elif h in ("RIGHT", "MAX"):
        classes.append("right-0")
    elif h in ("LEFT_RIGHT", "STRETCH"):
        classes.append("inset-x-0")
    elif h in ("CENTER", "SCALE"):
        classes.append("left-1/2")
        classes.append("-translate-x-1/2")
    else:
        # Default: use x position
        classes.append(f"left-{_px_to_spacing(node.x)}")


def resolve_absolute_position(node: FigmaIRNode) -> List[str]:
    """Generate position classes for absolutely-positioned nodes.

    Uses the node's x/y coordinates relative to its parent's bounding box
    to set top/left/right/bottom values.

    Args:
        node: IR node with absolute positioning.

    Returns:
        List of Tailwind position classes.
    """
    if not node.is_absolute_positioned:
        return []

    classes = ["absolute"]

    if node.x >= 0:
        classes.append(f"left-{_px_to_spacing(node.x)}")
    if node.y >= 0:
        classes.append(f"top-{_px_to_spacing(node.y)}")
    if node.width > 0:
        classes.append(f"w-{_px_to_spacing(node.width)}")
    if node.height > 0:
        classes.append(f"h-{_px_to_spacing(node.height)}")

    return classes
