"""Tests for layout_resolver.py — auto-layout to Tailwind flex/grid classes."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from layout_resolver import (
    LayoutClasses,
    resolve_container_layout,
    resolve_child_layout,
    resolve_absolute_position,
)
from node_parser import FigmaIRNode
from figma_types import (
    LayoutAlign,
    LayoutMode,
    LayoutSizingMode,
    LayoutWrap,
    NodeType,
)


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def _make_node(**overrides) -> FigmaIRNode:
    defaults = dict(node_id="1:1", name="TestNode", node_type=NodeType.FRAME)
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


# ---------------------------------------------------------------------------
# LayoutClasses
# ---------------------------------------------------------------------------

class TestLayoutClasses:
    """Test the LayoutClasses container."""

    def test_empty(self):
        lc = LayoutClasses()
        assert lc.container == []
        assert lc.self_classes == []
        assert lc.all_classes() == []

    def test_combined(self):
        lc = LayoutClasses()
        lc.container = ["flex", "flex-col"]
        lc.self_classes = ["w-full"]
        assert lc.all_classes() == ["flex", "flex-col", "w-full"]


# ---------------------------------------------------------------------------
# resolve_container_layout — no auto-layout
# ---------------------------------------------------------------------------

class TestNoAutoLayout:
    """Test nodes without auto-layout enabled."""

    def test_no_layout_no_children_empty(self):
        node = _make_node(has_auto_layout=False, is_frame_like=False)
        result = resolve_container_layout(node)
        assert result.container == []

    def test_frame_with_children_gets_relative(self):
        child = _make_node(node_id="2:1")
        node = _make_node(
            has_auto_layout=False, is_frame_like=True, children=[child]
        )
        result = resolve_container_layout(node)
        assert "relative" in result.container


# ---------------------------------------------------------------------------
# resolve_container_layout — flex
# ---------------------------------------------------------------------------

class TestFlexLayout:
    """Test horizontal and vertical flex layout resolution."""

    def test_horizontal_flex(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        result = resolve_container_layout(node)
        assert "flex" in result.container
        assert "flex-row" in result.container

    def test_vertical_flex(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
        )
        result = resolve_container_layout(node)
        assert "flex" in result.container
        assert "flex-col" in result.container

    def test_flex_wrap(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            layout_wrap=LayoutWrap.WRAP,
        )
        result = resolve_container_layout(node)
        assert "flex-wrap" in result.container

    def test_gap(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            item_spacing=16.0,
        )
        result = resolve_container_layout(node)
        assert "gap-4" in result.container

    def test_justify_center(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            primary_axis_align=LayoutAlign.CENTER,
        )
        result = resolve_container_layout(node)
        assert "justify-center" in result.container

    def test_justify_between(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            primary_axis_align=LayoutAlign.SPACE_BETWEEN,
        )
        result = resolve_container_layout(node)
        assert "justify-between" in result.container

    def test_items_center(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            counter_axis_align=LayoutAlign.CENTER,
        )
        result = resolve_container_layout(node)
        assert "items-center" in result.container

    def test_items_end(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            counter_axis_align=LayoutAlign.MAX,
        )
        result = resolve_container_layout(node)
        assert "items-end" in result.container

    def test_padding_uniform(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
            padding=(16.0, 16.0, 16.0, 16.0),
        )
        result = resolve_container_layout(node)
        assert "p-4" in result.container

    def test_padding_xy(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
            padding=(8.0, 16.0, 8.0, 16.0),
        )
        result = resolve_container_layout(node)
        assert "px-4" in result.container
        assert "py-2" in result.container

    def test_padding_individual(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
            padding=(4.0, 8.0, 12.0, 16.0),
        )
        result = resolve_container_layout(node)
        assert "pt-1" in result.container
        assert "pr-2" in result.container
        assert "pb-3" in result.container
        assert "pl-4" in result.container

    def test_zero_padding_omitted(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
            padding=(0.0, 0.0, 0.0, 0.0),
        )
        result = resolve_container_layout(node)
        assert not any("p-" in c or "px-" in c or "py-" in c for c in result.container)

    def test_overflow_hidden(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            clips_content=True,
        )
        result = resolve_container_layout(node)
        assert "overflow-hidden" in result.container

    def test_min_max_constraints(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            min_width=100.0,
            max_width=400.0,
        )
        result = resolve_container_layout(node)
        assert "min-w-25" in result.container
        assert "max-w-100" in result.container

    def test_content_alignment_on_wrap(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            layout_wrap=LayoutWrap.WRAP,
            counter_axis_align_content=LayoutAlign.CENTER,
        )
        result = resolve_container_layout(node)
        assert "content-center" in result.container

    def test_counter_axis_spacing_on_wrap(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            layout_wrap=LayoutWrap.WRAP,
            item_spacing=8.0,
            counter_axis_spacing=16.0,
        )
        result = resolve_container_layout(node)
        assert "gap-2" in result.container
        assert "gap-y-4" in result.container


# ---------------------------------------------------------------------------
# resolve_container_layout — grid
# ---------------------------------------------------------------------------

class TestGridLayout:
    """Test grid layout resolution."""

    def test_basic_grid(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            layout_grid_columns=3,
        )
        result = resolve_container_layout(node)
        assert "grid" in result.container
        assert "grid-cols-3" in result.container

    def test_grid_with_gap(self):
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            layout_grid_columns=2,
            item_spacing=12.0,
        )
        result = resolve_container_layout(node)
        assert "gap-3" in result.container

    def test_grid_auto_fill(self):
        """Grid with min cell width should use auto-fill."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            layout_grid_columns=3,
            layout_grid_cell_min_width=200.0,
        )
        result = resolve_container_layout(node)
        assert any("auto-fill" in c for c in result.container)
        # The fixed grid-cols-3 should be removed
        assert "grid-cols-3" not in result.container


# ---------------------------------------------------------------------------
# resolve_child_layout
# ---------------------------------------------------------------------------

class TestChildLayout:
    """Test child layout classes within parent auto-layout."""

    def test_absolute_child(self):
        child = _make_node(node_id="2:1", is_absolute_positioned=True)
        parent = _make_node(has_auto_layout=True)
        classes = resolve_child_layout(child, parent)
        assert "absolute" in classes

    def test_fill_horizontal_in_row(self):
        child = _make_node(
            node_id="2:1",
            layout_sizing_horizontal=LayoutSizingMode.FILL,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "flex-1" in classes

    def test_fill_horizontal_in_column(self):
        child = _make_node(
            node_id="2:1",
            layout_sizing_horizontal=LayoutSizingMode.FILL,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "w-full" in classes

    def test_fill_vertical_in_column(self):
        child = _make_node(
            node_id="2:1",
            layout_sizing_vertical=LayoutSizingMode.FILL,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "flex-1" in classes

    def test_fill_vertical_in_row(self):
        child = _make_node(
            node_id="2:1",
            layout_sizing_vertical=LayoutSizingMode.FILL,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "h-full" in classes

    def test_fixed_width(self):
        child = _make_node(
            node_id="2:1",
            layout_sizing_horizontal=LayoutSizingMode.FIXED,
            width=200.0,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "w-50" in classes

    def test_hug_generates_nothing(self):
        child = _make_node(
            node_id="2:1",
            layout_sizing_horizontal=LayoutSizingMode.HUG,
            layout_sizing_vertical=LayoutSizingMode.HUG,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert classes == []

    def test_no_auto_layout_parent(self):
        child = _make_node(node_id="2:1")
        parent = _make_node(has_auto_layout=False)
        classes = resolve_child_layout(child, parent)
        assert classes == []

    def test_layout_grow(self):
        child = _make_node(
            node_id="2:1",
            layout_grow=1.0,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "grow" in classes


# ---------------------------------------------------------------------------
# resolve_absolute_position
# ---------------------------------------------------------------------------

class TestAbsolutePosition:
    """Test absolute position class generation."""

    def test_non_absolute_returns_empty(self):
        node = _make_node(is_absolute_positioned=False)
        assert resolve_absolute_position(node) == []

    def test_absolute_with_position(self):
        node = _make_node(
            is_absolute_positioned=True,
            x=10.0,
            y=20.0,
            width=100.0,
            height=50.0,
        )
        classes = resolve_absolute_position(node)
        assert "absolute" in classes
        assert any("left-" in c for c in classes)
        assert any("top-" in c for c in classes)
        assert any("w-" in c for c in classes)
        assert any("h-" in c for c in classes)


# ---------------------------------------------------------------------------
# Edge-case tests: LayoutClasses
# ---------------------------------------------------------------------------


class TestLayoutClassesEdgeCases:
    """Edge-case tests for LayoutClasses container."""

    def test_empty_container_all_classes_empty(self):
        """Empty LayoutClasses returns empty list from all_classes()."""
        lc = LayoutClasses()
        assert lc.all_classes() == []

    def test_null_like_none_classes_not_added(self):
        """LayoutClasses with no items — both lists are empty (null-like state)."""
        lc = LayoutClasses()
        assert lc.container == []
        assert lc.self_classes == []

    def test_large_number_of_classes(self):
        """LayoutClasses with many classes (large/overflow-like scenario)."""
        lc = LayoutClasses()
        lc.container = [f"cls-{i}" for i in range(100)]
        lc.self_classes = [f"self-{i}" for i in range(100)]
        all_cls = lc.all_classes()
        assert len(all_cls) == 200


# ---------------------------------------------------------------------------
# Edge-case tests: resolve_container_layout
# ---------------------------------------------------------------------------


class TestContainerLayoutEdgeCases:
    """Edge-case tests for resolve_container_layout."""

    def test_zero_item_spacing_no_gap_class(self):
        """Zero item_spacing (boundary zero) should not generate a gap class."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            item_spacing=0.0,
        )
        result = resolve_container_layout(node)
        assert not any(c.startswith("gap-") for c in result.container)

    def test_negative_item_spacing_no_gap_class(self):
        """Negative item_spacing (negative boundary) should not generate a gap class."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            item_spacing=-8.0,
        )
        result = resolve_container_layout(node)
        assert not any(c.startswith("gap-") for c in result.container)

    def test_zero_padding_all_sides_omitted(self):
        """Zero padding on all sides produces no padding classes (boundary)."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
            padding=(0.0, 0.0, 0.0, 0.0),
        )
        result = resolve_container_layout(node)
        padding_classes = [c for c in result.container if c.startswith(("p-", "px-", "py-", "pt-", "pr-", "pb-", "pl-"))]
        assert padding_classes == []

    def test_zero_min_width_no_constraint_class(self):
        """min_width=0 (zero boundary) should not produce a min-w class."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            min_width=0.0,
        )
        result = resolve_container_layout(node)
        assert not any(c.startswith("min-w-") for c in result.container)

    def test_null_like_no_max_width_constraint(self):
        """max_width=None (null-like) produces no max-w class."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            max_width=None,
        )
        result = resolve_container_layout(node)
        assert not any(c.startswith("max-w-") for c in result.container)

    def test_empty_children_frame_no_relative(self):
        """Frame-like node with empty children list gets no 'relative' class."""
        node = _make_node(
            has_auto_layout=False,
            is_frame_like=True,
            children=[],
        )
        result = resolve_container_layout(node)
        assert "relative" not in result.container

    def test_missing_layout_mode_none_no_direction_class(self):
        """Node with has_auto_layout=True but layout_mode=None produces no direction class."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=None,
        )
        result = resolve_container_layout(node)
        # Still gets "flex" but no flex-row/flex-col without a valid mode
        assert "flex" in result.container
        assert "flex-row" not in result.container
        assert "flex-col" not in result.container

    def test_boundary_single_pixel_padding(self):
        """Single pixel padding (boundary minimum useful value)."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            padding=(1.0, 1.0, 1.0, 1.0),
        )
        result = resolve_container_layout(node)
        # Should produce some padding class for 1px
        padding_classes = [c for c in result.container if c.startswith("p")]
        assert len(padding_classes) > 0

    def test_zero_grid_columns_falls_back_to_flex(self):
        """layout_grid_columns=0 (zero boundary) falls back to flex layout."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            layout_grid_columns=0,
        )
        result = resolve_container_layout(node)
        # grid_columns=0 is falsy → should not get grid layout
        assert "grid" not in result.container

    def test_missing_counter_axis_align_no_items_class(self):
        """None counter_axis_align produces no items-* class."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            counter_axis_align=None,
        )
        result = resolve_container_layout(node)
        assert not any(c.startswith("items-") for c in result.container)

    def test_missing_primary_axis_align_no_justify_class(self):
        """None primary_axis_align produces no justify-* class."""
        node = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            primary_axis_align=None,
        )
        result = resolve_container_layout(node)
        assert not any(c.startswith("justify-") for c in result.container)


# ---------------------------------------------------------------------------
# Edge-case tests: resolve_child_layout
# ---------------------------------------------------------------------------


class TestChildLayoutEdgeCases:
    """Edge-case tests for resolve_child_layout."""

    def test_zero_width_fixed_child_no_width_class(self):
        """FIXED horizontal sizing with zero width produces no w-* class (zero boundary)."""
        child = _make_node(
            node_id="2:1",
            layout_sizing_horizontal=LayoutSizingMode.FIXED,
            width=0.0,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert not any(c.startswith("w-") for c in classes)

    def test_zero_height_fixed_child_no_height_class(self):
        """FIXED vertical sizing with zero height produces no h-* class (zero boundary)."""
        child = _make_node(
            node_id="2:1",
            layout_sizing_vertical=LayoutSizingMode.FIXED,
            height=0.0,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
        )
        classes = resolve_child_layout(child, parent)
        assert not any(c.startswith("h-") for c in classes)

    def test_null_like_none_parent_no_layout_classes(self):
        """Child with no auto-layout parent produces empty class list (null-like parent)."""
        child = _make_node(node_id="2:1")
        parent = _make_node(has_auto_layout=False, layout_mode=None)
        classes = resolve_child_layout(child, parent)
        assert classes == []

    def test_zero_layout_grow_no_grow_class(self):
        """layout_grow=0.0 (zero boundary) should not add grow class."""
        child = _make_node(
            node_id="2:1",
            layout_grow=0.0,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "grow" not in classes

    def test_negative_layout_grow_no_grow_class(self):
        """Negative layout_grow (negative boundary) should not add grow class."""
        child = _make_node(
            node_id="2:1",
            layout_grow=-1.0,
        )
        parent = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
        )
        classes = resolve_child_layout(child, parent)
        assert "grow" not in classes


# ---------------------------------------------------------------------------
# Edge-case tests: resolve_absolute_position
# ---------------------------------------------------------------------------


class TestAbsolutePositionEdgeCases:
    """Edge-case tests for resolve_absolute_position."""

    def test_zero_dimensions_absolute_no_size_classes(self):
        """Absolutely positioned node with zero width and height gets no w-/h- classes."""
        node = _make_node(
            is_absolute_positioned=True,
            x=5.0,
            y=5.0,
            width=0.0,
            height=0.0,
        )
        classes = resolve_absolute_position(node)
        assert "absolute" in classes
        assert not any(c.startswith("w-") for c in classes)
        assert not any(c.startswith("h-") for c in classes)

    def test_zero_xy_position_boundary(self):
        """Zero x=0, y=0 (boundary) should still generate left-0 and top-0."""
        node = _make_node(
            is_absolute_positioned=True,
            x=0.0,
            y=0.0,
            width=50.0,
            height=50.0,
        )
        classes = resolve_absolute_position(node)
        assert "absolute" in classes
        # x=0 and y=0 are >= 0, so left- and top- classes should be generated
        assert any("left-" in c for c in classes)
        assert any("top-" in c for c in classes)

    def test_missing_absolute_flag_returns_empty(self):
        """Node that is NOT absolutely positioned returns empty list."""
        node = _make_node(
            is_absolute_positioned=False,
            x=10.0,
            y=20.0,
            width=100.0,
            height=50.0,
        )
        assert resolve_absolute_position(node) == []

    def test_large_position_values_boundary(self):
        """Very large x/y/width/height (overflow-like) generates classes without crashing."""
        node = _make_node(
            is_absolute_positioned=True,
            x=9999.0,
            y=9999.0,
            width=9999.0,
            height=9999.0,
        )
        classes = resolve_absolute_position(node)
        assert "absolute" in classes
        assert len(classes) > 1
