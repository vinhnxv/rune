"""Tests for node_parser.py — Figma JSON to intermediate FigmaNode IR."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from figma_types import FigmaNodeBase  # noqa: E402
from node_parser import (  # noqa: E402
    FigmaIRNode,
    StyledTextSegment,
    _has_vector_children,
    count_nodes,
    find_by_name,
    merge_text_segments,
    parse_node,
    walk_tree,
)


# ---------------------------------------------------------------------------
# Basic node type parsing (12 types)
# ---------------------------------------------------------------------------

class TestNodeTypes:
    """Test parsing of all 12 supported Figma node types."""

    def test_frame_node(self, hero_card_node):
        """FRAME nodes produce IR with layout properties."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert ir.node_type.value == "FRAME"
        assert ir.name == "HeroCard"
        assert ir.width == 400
        assert ir.height == 300

    def test_text_node(self, text_node):
        """TEXT nodes include text content and style info."""
        ir = parse_node(text_node)
        assert ir is not None
        assert ir.node_type.value == "TEXT"
        assert ir.name == "CardTitle"
        assert ir.text_content == "Welcome to Rune"

    def test_rectangle_node(self, image_rect_node):
        """RECTANGLE nodes include fill information."""
        ir = parse_node(image_rect_node)
        assert ir is not None
        assert ir.node_type.value == "RECTANGLE"
        assert ir.name == "CardImage"

    def test_ellipse_node(self, ellipse_node):
        """ELLIPSE nodes are parsed correctly."""
        ir = parse_node(ellipse_node)
        assert ir is not None
        assert ir.node_type.value == "ELLIPSE"
        assert ir.name == "CircleBadge"

    def test_vector_node(self, vector_node):
        """VECTOR nodes are parsed correctly."""
        ir = parse_node(vector_node)
        assert ir is not None
        assert ir.node_type.value == "VECTOR"
        assert ir.name == "IconSmall"

    def test_group_node(self, group_node):
        """GROUP nodes should have children and be frame-like."""
        ir = parse_node(group_node)
        assert ir is not None
        assert ir.name == "GroupedElements"
        assert ir.is_frame_like
        assert len(ir.children) == 2

    def test_boolean_operation_node(self, boolean_op_node):
        """BOOLEAN_OPERATION nodes include the operation type."""
        ir = parse_node(boolean_op_node)
        assert ir is not None
        assert ir.node_type.value == "BOOLEAN_OPERATION"
        assert ir.boolean_operation == "UNION"
        assert ir.is_svg_candidate

    def test_component_node(self, component_node):
        """COMPONENT nodes are frame-like."""
        ir = parse_node(component_node)
        assert ir is not None
        assert ir.node_type.value == "COMPONENT"
        assert ir.name == "MyComponent"
        assert ir.is_frame_like

    def test_section_node(self, section_node):
        """SECTION nodes are parsed correctly."""
        ir = parse_node(section_node)
        assert ir is not None
        assert ir.node_type.value == "SECTION"
        assert ir.name == "ContentSection"
        assert ir.is_frame_like


# ---------------------------------------------------------------------------
# GROUP to FRAME-like conversion
# ---------------------------------------------------------------------------

class TestGroupConversion:
    """Test GROUP node treatment as FRAME-like IR."""

    def test_group_is_frame_like(self, group_node):
        """GROUP nodes should be treated as frame-like containers."""
        ir = parse_node(group_node)
        assert ir is not None
        assert ir.is_frame_like

    def test_group_position_from_bbox(self, group_node):
        """GROUP position/size from absoluteBoundingBox."""
        ir = parse_node(group_node)
        assert ir is not None
        assert ir.width == 200
        assert ir.height == 100

    def test_group_preserves_children(self, group_node):
        """GROUP conversion should preserve child nodes."""
        ir = parse_node(group_node)
        assert ir is not None
        children = ir.children
        assert len(children) == 2
        names = [c.name for c in children]
        assert "GroupChild1" in names
        assert "GroupChild2" in names


# ---------------------------------------------------------------------------
# BOOLEAN_OPERATION handling
# ---------------------------------------------------------------------------

class TestBooleanOperation:
    """Test BOOLEAN_OPERATION SVG candidacy."""

    def test_boolean_marked_as_svg_candidate(self, boolean_op_node):
        """BOOLEAN_OPERATION should be marked as SVG candidate."""
        ir = parse_node(boolean_op_node)
        assert ir is not None
        assert ir.is_svg_candidate

    def test_boolean_operation_types(self):
        """All 4 boolean operation types should be recognized."""
        for op_type in ["UNION", "INTERSECT", "SUBTRACT", "EXCLUDE"]:
            node = {
                "id": "99:1",
                "name": f"Bool{op_type}",
                "type": "BOOLEAN_OPERATION",
                "absoluteBoundingBox": {"x": 0, "y": 0, "width": 64, "height": 64},
                "absoluteRenderBounds": {"x": 0, "y": 0, "width": 64, "height": 64},
                "booleanOperation": op_type,
                "fills": [],
                "strokes": [],
                "effects": [],
                "children": [],
            }
            ir = parse_node(node)
            assert ir is not None
            assert ir.boolean_operation == op_type


# ---------------------------------------------------------------------------
# Icon detection
# ---------------------------------------------------------------------------

class TestIconDetection:
    """Test detection of icon candidate nodes."""

    def test_small_vector_is_icon(self, vector_node):
        """VECTOR nodes 64x64 or smaller with vector primitives are icon candidates."""
        ir = parse_node(vector_node)
        assert ir is not None
        # 24x24 vector should be an icon candidate
        assert ir.is_icon_candidate

    def test_large_vector_not_icon(self):
        """VECTOR nodes larger than 64x64 are not icon candidates."""
        node = {
            "id": "99:2",
            "name": "LargeVector",
            "type": "VECTOR",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 200, "height": 200},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 200, "height": 200},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert not ir.is_icon_candidate


# ---------------------------------------------------------------------------
# Mixed text styles (merge_text_segments)
# ---------------------------------------------------------------------------

class TestMergeTextSegments:
    """Test characterStyleOverrides merging with styleOverrideTable."""

    def test_no_overrides_single_segment(self):
        """Text without overrides should produce a single segment."""
        segments = merge_text_segments("Hello world", None, None, None)
        assert len(segments) == 1
        assert segments[0].text == "Hello world"

    def test_empty_text_no_segments(self):
        """Empty text should produce no segments."""
        segments = merge_text_segments("", None, None, None)
        assert len(segments) == 0

    def test_mixed_style_multiple_segments(self):
        """Text with overrides should produce multiple segments."""
        from figma_types import TypeStyle
        base = TypeStyle(fontWeight=400)
        override = TypeStyle(fontWeight=700)
        overrides = [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0]
        table = {"1": override}

        segments = merge_text_segments("Hello bold world", base, overrides, table)
        # Should produce at least 3 segments: "Hello " (base), "bold" (700), " world" (base)
        assert len(segments) >= 2
        # Check that bold text is in one segment
        bold_segments = [s for s in segments if s.style and s.style.font_weight == 700]
        assert len(bold_segments) >= 1
        assert "bold" in bold_segments[0].text

    def test_segments_cover_all_text(self):
        """All text content should be covered by segments."""
        overrides = [0, 0, 1, 1, 0]
        table = {"1": None}  # override to base
        segments = merge_text_segments("ABCDE", None, overrides, table)
        combined = "".join(s.text for s in segments)
        assert combined == "ABCDE"


# ---------------------------------------------------------------------------
# Full node parse with text
# ---------------------------------------------------------------------------

class TestTextNodeParsing:
    """Test TEXT node IR properties via parse_node."""

    def test_text_ir_has_content(self, text_node):
        """TEXT IR should have text_content populated."""
        ir = parse_node(text_node)
        assert ir is not None
        assert ir.text_content == "Welcome to Rune"

    def test_text_ir_has_style(self, text_node):
        """TEXT IR should have text_style populated."""
        ir = parse_node(text_node)
        assert ir is not None
        assert ir.text_style is not None
        assert ir.text_style.font_weight == 700

    def test_mixed_text_has_segments(self, mixed_text_node):
        """Mixed text node should have multiple styled segments."""
        ir = parse_node(mixed_text_node)
        assert ir is not None
        assert len(ir.text_segments) >= 2

    def test_plain_text_single_segment(self, text_node):
        """Text without overrides should have a single segment."""
        ir = parse_node(text_node)
        assert ir is not None
        assert len(ir.text_segments) == 1


# ---------------------------------------------------------------------------
# Image fill detection
# ---------------------------------------------------------------------------

class TestImageFillDetection:
    """Test detection of image fills on nodes."""

    def test_image_fill_detected(self, image_rect_node):
        """RECTANGLE with IMAGE fill type should set has_image_fill."""
        ir = parse_node(image_rect_node)
        assert ir is not None
        assert ir.has_image_fill
        assert ir.image_ref == "abc123def456"

    def test_solid_fill_not_image(self, hero_card_node):
        """FRAME with SOLID fill should not be flagged as image."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert not ir.has_image_fill


# ---------------------------------------------------------------------------
# Auto-layout properties
# ---------------------------------------------------------------------------

class TestAutoLayout:
    """Test auto-layout property extraction."""

    def test_vertical_layout(self, hero_card_node):
        """VERTICAL layout mode should be detected."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert ir.has_auto_layout
        assert ir.layout_mode.value == "VERTICAL"

    def test_item_spacing(self, hero_card_node):
        """itemSpacing should be extracted."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert ir.item_spacing == 12

    def test_padding_extraction(self, hero_card_node):
        """Padding should be extracted as (top, right, bottom, left)."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert ir.padding == (16.0, 16.0, 16.0, 16.0)

    def test_clips_content(self, hero_card_node):
        """clipsContent should be extracted."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert ir.clips_content


# ---------------------------------------------------------------------------
# Tree utilities
# ---------------------------------------------------------------------------

class TestTreeUtilities:
    """Test walk_tree, find_by_name, count_nodes."""

    def test_walk_tree(self, hero_card_node):
        """walk_tree should return all nodes in pre-order."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        nodes = walk_tree(ir)
        # HeroCard + CardImage + CardTitle + CardDescription + ActionRow + PrimaryButton + ButtonLabel
        assert len(nodes) >= 7

    def test_find_by_name(self, hero_card_node):
        """find_by_name should locate a named node."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        found = find_by_name(ir, "CardTitle")
        assert found is not None
        assert found.text_content == "Welcome to Rune"

    def test_find_by_name_not_found(self, hero_card_node):
        """find_by_name should return None for missing names."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert find_by_name(ir, "NonexistentNode") is None

    def test_count_nodes(self, hero_card_node):
        """count_nodes should count all nodes including root."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        count = count_nodes(ir)
        assert count >= 7

    def test_unique_names(self, hero_card_node):
        """All nodes should have unique unique_name values."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        all_nodes = walk_tree(ir)
        names = [n.unique_name for n in all_nodes]
        assert len(names) == len(set(names))


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

class TestNodeParserEdgeCases:
    """Test edge cases and error handling."""

    def test_unsupported_node_type_returns_none(self):
        """Unsupported node types (STICKY, CONNECTOR) should return None."""
        node = {
            "id": "99:3",
            "name": "MyStickyNote",
            "type": "STICKY",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 100},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 100, "height": 100},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is None

    def test_node_with_zero_dimensions(self):
        """Node with zero width/height should still parse."""
        node = {
            "id": "99:4",
            "name": "ZeroSize",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 0, "height": 0},
            "absoluteRenderBounds": None,
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.width == 0
        assert ir.height == 0

    def test_node_with_null_render_bounds(self):
        """Node with null absoluteRenderBounds should use bounding box."""
        node = {
            "id": "99:5",
            "name": "NullRender",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 10, "y": 20, "width": 100, "height": 50},
            "absoluteRenderBounds": None,
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.width == 100

    def test_unknown_type_with_children_treated_as_frame(self):
        """Unknown type with children should be treated as FRAME."""
        node = {
            "id": "99:6",
            "name": "FutureType",
            "type": "TRANSFORM_GROUP",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 100},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 100, "height": 100},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [
                {
                    "id": "99:7",
                    "name": "Child",
                    "type": "RECTANGLE",
                    "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
                    "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
                    "fills": [],
                    "strokes": [],
                    "effects": [],
                },
            ],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.node_type.value == "FRAME"
        assert len(ir.children) == 1

    def test_unknown_leaf_type_returns_none(self):
        """Unknown leaf type without children should return None."""
        node = {
            "id": "99:8",
            "name": "TextPath",
            "type": "TEXT_PATH",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 100},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 100, "height": 100},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is None

    def test_deeply_nested_parsing(self):
        """Deeply nested nodes should parse without recursion errors."""
        inner = {
            "id": "99:22",
            "name": "Inner",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        middle = {
            "id": "99:21",
            "name": "Middle",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 100},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 100, "height": 100},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [inner],
        }
        outer = {
            "id": "99:20",
            "name": "Outer",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 200, "height": 200},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 200, "height": 200},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [middle],
        }
        ir = parse_node(outer)
        assert ir is not None
        assert count_nodes(ir) == 3


# ---------------------------------------------------------------------------
# _has_vector_children — FRAME/GROUP nested detection
# ---------------------------------------------------------------------------


def _make_node(node_type: str, children=None) -> FigmaNodeBase:
    """Construct a minimal FigmaNodeBase for _has_vector_children tests."""
    return FigmaNodeBase(
        id=f"test:{node_type}",
        type=node_type,
        children=children or [],
    )


class TestHasVectorChildren:
    """Tests confirming _has_vector_children() handles FRAME/GROUP nesting via recursion."""

    def test_frame_group_vector_hierarchy_detected(self):
        """FRAME > GROUP > VECTOR hierarchy detected as icon/SVG candidate.

        Confirms that _has_vector_children recurses through non-leaf container
        types (FRAME, GROUP) to find vector primitives at any depth.
        """
        vector = _make_node("VECTOR")
        group = _make_node("GROUP", children=[vector])
        frame = _make_node("FRAME", children=[group])
        assert _has_vector_children(frame) is True

    def test_frame_group_mixed_not_detected(self):
        """FRAME > GROUP > (VECTOR + TEXT) hierarchy NOT detected.

        A GROUP containing both a VECTOR and a TEXT node is not a pure vector
        subtree. TEXT is not in _VECTOR_TYPES, so _has_vector_children returns False.
        """
        vector = _make_node("VECTOR")
        text = _make_node("TEXT")
        group = _make_node("GROUP", children=[vector, text])
        frame = _make_node("FRAME", children=[group])
        assert _has_vector_children(frame) is False

    def test_deep_nesting_recursion_guard(self):
        """Deeply nested vector hierarchy (depth > 100) is handled by recursion guard.

        _has_vector_children has a depth guard at _MAX_PARSE_DEPTH=100.
        A chain of 105 nested FRAME nodes terminates with False (guard fires)
        rather than raising RecursionError.
        """
        # Build a chain: leaf VECTOR -> 105 FRAME wrappers
        node = _make_node("VECTOR")
        for _ in range(105):
            node = _make_node("FRAME", children=[node])
        # Guard fires at depth > 100, returns False for the pathological case
        result = _has_vector_children(node)
        assert isinstance(result, bool)
        # With 105 levels of FRAME wrapping, the guard kicks in and returns False
        assert result is False

    def test_has_vector_children_empty(self):
        """Node with no children returns False for leaf non-vector types.

        For a leaf FRAME with no children, `node.type` is FRAME, which is not
        in _VECTOR_TYPES. So the function correctly returns False.
        """
        frame = _make_node("FRAME")
        assert _has_vector_children(frame) is False

    def test_has_vector_children_single_vector(self):
        """Single VECTOR child returns True.

        Baseline test: a FRAME with a single VECTOR child is a pure vector
        subtree (all children are vector primitives).
        """
        vector = _make_node("VECTOR")
        frame = _make_node("FRAME", children=[vector])
        assert _has_vector_children(frame) is True

    def test_has_vector_children_boolean_op_leaf(self):
        """Leaf BOOLEAN_OPERATION node returns True (is in _VECTOR_TYPES)."""
        bool_op = _make_node("BOOLEAN_OPERATION")
        assert _has_vector_children(bool_op) is True

    def test_has_vector_children_ellipse_leaf(self):
        """Leaf ELLIPSE node returns True (is in _VECTOR_TYPES)."""
        ellipse = _make_node("ELLIPSE")
        assert _has_vector_children(ellipse) is True

    def test_has_vector_children_group_with_all_vectors(self):
        """GROUP with multiple vector children (ELLIPSE, VECTOR, LINE) returns True."""
        ellipse = _make_node("ELLIPSE")
        vector = _make_node("VECTOR")
        line = _make_node("LINE")
        group = _make_node("GROUP", children=[ellipse, vector, line])
        assert _has_vector_children(group) is True

    def test_has_vector_children_group_with_rectangle(self):
        """GROUP with RECTANGLE child returns True (RECTANGLE is a vector type)."""
        rect = _make_node("RECTANGLE")
        group = _make_node("GROUP", children=[rect])
        assert _has_vector_children(group) is True
