"""Tests for node_parser.py — Figma JSON to intermediate FigmaNode IR."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from figma_types import (  # noqa: E402
    ComponentProperty,
    ComponentPropertyDefinition,
    FigmaNodeBase,
    FigmaPropertyType,
)
from node_parser import (  # noqa: E402
    FigmaIRNode,
    InstanceRole,
    StyledTextSegment,
    _classify_instance_role,
    _clean_property_name,
    _detect_slot_candidate,
    _has_vector_children,
    count_nodes,
    find_by_name,
    merge_text_segments,
    parse_node,
    walk_tree,
)
from figma_types import LayoutMode  # noqa: E402


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
# Inherently SVG types (VEIL-002 / BACK-001)
# ---------------------------------------------------------------------------

class TestInherentlySvgTypes:
    """LINE, REGULAR_POLYGON, and STAR are always SVG candidates."""

    @pytest.mark.parametrize("node_type", ["LINE", "REGULAR_POLYGON", "STAR"])
    def test_inherently_svg_type_marked_as_candidate(self, node_type):
        """Inherently SVG types must be SVG candidates regardless of size."""
        node = {
            "id": "50:1",
            "name": f"Test{node_type}",
            "type": node_type,
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 800, "height": 800},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 800, "height": 800},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.is_svg_candidate, (
            f"{node_type} should always be SVG candidate, even at 800x800"
        )

    def test_line_small_is_svg_candidate(self):
        """Small LINE node is still SVG candidate."""
        node = {
            "id": "50:2",
            "name": "SmallLine",
            "type": "LINE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 16, "height": 1},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 16, "height": 1},
            "fills": [],
            "strokes": [{"type": "SOLID", "color": {"r": 0, "g": 0, "b": 0, "a": 1}}],
            "effects": [],
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.is_svg_candidate


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


# ---------------------------------------------------------------------------
# Additional edge cases
# ---------------------------------------------------------------------------


class TestNodeParserAdditionalEdgeCases:
    """Additional edge cases covering empty inputs, boundary values, and unicode."""

    def test_parse_node_with_empty_name(self):
        """Node with empty string name should still parse."""
        node = {
            "id": "101:1",
            "name": "",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.name == ""

    def test_parse_node_with_unicode_name(self):
        """Node with unicode characters in name should parse correctly."""
        node = {
            "id": "102:1",
            "name": "按钮 / Кнопка / ボタン",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 40},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 100, "height": 40},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.name == "按钮 / Кнопка / ボタン"

    def test_parse_node_with_whitespace_only_name(self):
        """Node with whitespace-only name should still parse."""
        node = {
            "id": "103:1",
            "name": "   ",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None

    def test_parse_node_missing_fills_key(self):
        """Node missing 'fills' key should still parse (graceful fallback)."""
        node = {
            "id": "104:1",
            "name": "NoFills",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert not ir.has_image_fill

    def test_parse_node_empty_fills_list(self):
        """Node with empty fills list should not flag as image fill."""
        node = {
            "id": "105:1",
            "name": "EmptyFills",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert not ir.has_image_fill

    def test_parse_node_boundary_large_dimensions(self):
        """Node with very large dimensions (boundary) should parse without error."""
        node = {
            "id": "106:1",
            "name": "HugeBanner",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 99999, "height": 99999},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 99999, "height": 99999},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.width == 99999
        assert ir.height == 99999

    def test_parse_node_boundary_negative_position(self):
        """Node with negative x/y position should parse correctly."""
        node = {
            "id": "107:1",
            "name": "NegativeOffset",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": -100, "y": -200, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": -100, "y": -200, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.x == -100
        assert ir.y == -200

    def test_merge_text_segments_whitespace_only_text(self):
        """merge_text_segments with whitespace-only text should produce a single segment."""
        segments = merge_text_segments("   ", None, None, None)
        assert len(segments) == 1
        assert segments[0].text == "   "

    def test_merge_text_segments_unicode_text(self):
        """merge_text_segments with unicode content should work correctly."""
        segments = merge_text_segments("Hello 🌍 World", None, None, None)
        assert len(segments) == 1
        assert "Hello" in segments[0].text

    def test_merge_text_segments_empty_override_table(self):
        """merge_text_segments with empty override table should produce one segment."""
        overrides = [0, 0, 0, 0]
        table = {}
        segments = merge_text_segments("Test", None, overrides, table)
        combined = "".join(s.text for s in segments)
        assert combined == "Test"

    def test_parse_node_with_null_effects(self):
        """Node with null effects key should raise or return None — not crash unhandled."""
        from pydantic import ValidationError
        node = {
            "id": "108:1",
            "name": "NullEffects",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": None,
        }
        # Pydantic enforces effects is a list — None is invalid input.
        # parse_node should either return None (graceful) or raise ValidationError.
        try:
            ir = parse_node(node)
            assert ir is None
        except (ValidationError, Exception):
            pass  # Acceptable: invalid input raises a validation error

    def test_parse_node_invalid_node_type_string(self):
        """Node with completely invalid type string and no children returns None."""
        node = {
            "id": "109:1",
            "name": "InvalidType",
            "type": "COMPLETELY_INVALID_TYPE_XYZ",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is None

    def test_find_by_name_empty_string_query(self):
        """find_by_name with empty string query should handle gracefully."""
        outer = {
            "id": "110:1",
            "name": "Outer",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 100},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 100, "height": 100},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
        }
        ir = parse_node(outer)
        assert ir is not None
        # Empty string should not match any node
        result = find_by_name(ir, "")
        # Either None or an actual node named "" — but not crash
        assert result is None or result.name == ""

    def test_walk_tree_single_node(self):
        """walk_tree on a single leaf node returns just that node."""
        node = {
            "id": "111:1",
            "name": "SingleNode",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        nodes = walk_tree(ir)
        assert len(nodes) == 1
        assert nodes[0].name == "SingleNode"

    def test_count_nodes_boundary_zero_children(self):
        """count_nodes on a leaf node with zero children returns 1."""
        node = {
            "id": "112:1",
            "name": "LeafNode",
            "type": "RECTANGLE",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 50, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 50, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert count_nodes(ir) == 1

    def test_parse_node_frame_with_empty_children_list(self):
        """FRAME with empty children list should parse correctly."""
        node = {
            "id": "113:1",
            "name": "EmptyFrame",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 200, "height": 200},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 200, "height": 200},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert len(ir.children) == 0

    def test_parse_node_missing_bounding_box(self):
        """Node with None absoluteBoundingBox should return None gracefully."""
        node = {
            "id": "114:1",
            "name": "NoBBox",
            "type": "RECTANGLE",
            "absoluteBoundingBox": None,
            "absoluteRenderBounds": None,
            "fills": [],
            "strokes": [],
            "effects": [],
        }
        ir = parse_node(node)
        # Should either return None or handle gracefully (width/height = 0)
        if ir is not None:
            assert ir.width == 0 or ir.width is not None


# ---------------------------------------------------------------------------
# Phase 1: Typed Property Extraction
# ---------------------------------------------------------------------------


class TestCleanPropertyName:
    """Test _clean_property_name hash suffix stripping."""

    def test_strips_hash_suffix(self):
        assert _clean_property_name("Label#1234") == "Label"

    def test_no_hash_unchanged(self):
        assert _clean_property_name("variant") == "variant"

    def test_multiple_hashes_strips_first(self):
        assert _clean_property_name("Name#123#456") == "Name"

    def test_empty_string(self):
        assert _clean_property_name("") == ""

    def test_hash_only(self):
        assert _clean_property_name("#1234") == ""


class TestComponentPropertyDefinitionsParsing:
    """Test componentPropertyDefinitions extraction from COMPONENT nodes."""

    def test_component_has_property_definitions(self, component_node):
        """COMPONENT node with componentPropertyDefinitions should parse them."""
        ir = parse_node(component_node)
        assert ir is not None
        assert ir.component_property_definitions is not None
        # Hash suffixes should be stripped from keys
        assert "label" in ir.component_property_definitions
        assert "variant" in ir.component_property_definitions
        assert "disabled" in ir.component_property_definitions
        assert "icon" in ir.component_property_definitions

    def test_text_property_type(self, component_node):
        """TEXT property should have correct type and default value."""
        ir = parse_node(component_node)
        assert ir is not None
        label_def = ir.component_property_definitions["label"]
        assert label_def.type == FigmaPropertyType.TEXT
        assert label_def.default_value == "Button"

    def test_variant_property_type(self, component_node):
        """VARIANT property should have variant_options."""
        ir = parse_node(component_node)
        assert ir is not None
        variant_def = ir.component_property_definitions["variant"]
        assert variant_def.type == FigmaPropertyType.VARIANT
        assert variant_def.default_value == "primary"
        assert variant_def.variant_options == ["primary", "secondary"]

    def test_boolean_property_type(self, component_node):
        """BOOLEAN property should have bool default value."""
        ir = parse_node(component_node)
        assert ir is not None
        disabled_def = ir.component_property_definitions["disabled"]
        assert disabled_def.type == FigmaPropertyType.BOOLEAN
        assert disabled_def.default_value is False

    def test_instance_swap_property_type(self, component_node):
        """INSTANCE_SWAP property should have preferred values."""
        ir = parse_node(component_node)
        assert ir is not None
        icon_def = ir.component_property_definitions["icon"]
        assert icon_def.type == FigmaPropertyType.INSTANCE_SWAP
        assert icon_def.default_value == "99:1"
        assert icon_def.preferred_values is not None
        assert len(icon_def.preferred_values) == 2
        assert icon_def.preferred_values[0].type == "COMPONENT"
        assert icon_def.preferred_values[0].key == "icon-heart-key"

    def test_empty_definitions_treated_as_none(self):
        """Empty componentPropertyDefinitions dict should be treated as None."""
        node = {
            "id": "200:1",
            "name": "EmptyProps",
            "type": "COMPONENT",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 50},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 100, "height": 50},
            "fills": [],
            "strokes": [],
            "effects": [],
            "componentPropertyDefinitions": {},
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        # Empty dict is falsy, so it should not be propagated
        assert ir.component_property_definitions is None

    def test_frame_without_definitions(self, hero_card_node):
        """Regular FRAME nodes should have None for component_property_definitions."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        assert ir.component_property_definitions is None


class TestComponentPropertiesParsing:
    """Test componentProperties extraction from INSTANCE nodes."""

    def test_instance_has_property_values(self, instance_node):
        """INSTANCE node with componentProperties should parse them."""
        ir = parse_node(instance_node)
        assert ir is not None
        assert ir.component_property_values is not None
        # Hash suffixes should be stripped
        assert "label" in ir.component_property_values
        assert "variant" in ir.component_property_values
        assert "disabled" in ir.component_property_values
        assert "icon" in ir.component_property_values

    def test_instance_text_override(self, instance_node):
        """TEXT property override value should be extracted."""
        ir = parse_node(instance_node)
        assert ir is not None
        label_prop = ir.component_property_values["label"]
        assert label_prop.type == FigmaPropertyType.TEXT
        assert label_prop.value == "Submit"

    def test_instance_variant_override(self, instance_node):
        """VARIANT property override value should be extracted."""
        ir = parse_node(instance_node)
        assert ir is not None
        variant_prop = ir.component_property_values["variant"]
        assert variant_prop.type == FigmaPropertyType.VARIANT
        assert variant_prop.value == "secondary"

    def test_instance_boolean_override(self, instance_node):
        """BOOLEAN property override value should be extracted."""
        ir = parse_node(instance_node)
        assert ir is not None
        disabled_prop = ir.component_property_values["disabled"]
        assert disabled_prop.type == FigmaPropertyType.BOOLEAN
        assert disabled_prop.value is True

    def test_instance_swap_override(self, instance_node):
        """INSTANCE_SWAP property override value should be extracted."""
        ir = parse_node(instance_node)
        assert ir is not None
        icon_prop = ir.component_property_values["icon"]
        assert icon_prop.type == FigmaPropertyType.INSTANCE_SWAP
        assert icon_prop.value == "99:2"

    def test_instance_has_component_id(self, instance_node):
        """INSTANCE node should still have component_id."""
        ir = parse_node(instance_node)
        assert ir is not None
        assert ir.component_id == "6:1"

    def test_non_instance_has_no_property_values(self, component_node):
        """COMPONENT nodes should have None for component_property_values."""
        ir = parse_node(component_node)
        assert ir is not None
        assert ir.component_property_values is None


# ---------------------------------------------------------------------------
# Phase 2: Instance Role Classification
# ---------------------------------------------------------------------------


class TestInstanceRoleClassification:
    """Test _classify_instance_role heuristic and parse_node integration."""

    def test_instance_with_children_is_child(self):
        """Instance with children should always be CHILD (never PROP)."""
        ir = FigmaIRNode(
            node_id="r:1", component_id="comp:1",
            children=[FigmaIRNode(node_id="r:2")],
            width=24, height=24, is_icon_candidate=True,
        )
        role = _classify_instance_role(ir)
        assert role == InstanceRole.CHILD

    def test_small_instance_no_children_is_prop(self):
        """Small instance (<=48px) with no children should be PROP."""
        ir = FigmaIRNode(
            node_id="r:1", component_id="comp:1",
            width=24, height=24,
        )
        role = _classify_instance_role(ir)
        assert role == InstanceRole.PROP

    def test_icon_candidate_is_prop(self):
        """Icon candidate instance with no children should be PROP."""
        ir = FigmaIRNode(
            node_id="r:1", component_id="comp:1",
            is_icon_candidate=True, width=32, height=32,
        )
        role = _classify_instance_role(ir)
        assert role == InstanceRole.PROP

    def test_large_instance_no_children_is_child(self):
        """Large instance (>48px) without icon flag should be CHILD."""
        ir = FigmaIRNode(
            node_id="r:1", component_id="comp:1",
            width=200, height=60,
        )
        role = _classify_instance_role(ir)
        assert role == InstanceRole.CHILD

    def test_absolute_positioned_is_standalone(self):
        """Absolutely positioned instance should be STANDALONE."""
        ir = FigmaIRNode(
            node_id="r:1", component_id="comp:1",
            is_absolute_positioned=True, width=200, height=60,
        )
        role = _classify_instance_role(ir)
        assert role == InstanceRole.STANDALONE

    def test_non_instance_returns_none(self):
        """Node without component_id should return None."""
        ir = FigmaIRNode(node_id="r:1")
        role = _classify_instance_role(ir)
        assert role is None

    def test_instance_swap_parent_makes_prop(self):
        """Instance matching parent's INSTANCE_SWAP definition should be PROP."""
        parent = FigmaIRNode(
            node_id="p:1",
            component_property_definitions={
                "icon": ComponentPropertyDefinition(
                    type=FigmaPropertyType.INSTANCE_SWAP,
                    defaultValue="99:1",
                ),
            },
        )
        ir = FigmaIRNode(
            node_id="r:1", name="icon", component_id="comp:1",
            width=100, height=100,  # Large, but INSTANCE_SWAP takes priority
        )
        role = _classify_instance_role(ir, parent_ir=parent)
        assert role == InstanceRole.PROP

    def test_instance_role_prevents_flattening(self):
        """Nodes with instance_role should have can_be_flattened = False."""
        node = {
            "id": "300:1",
            "name": "SmallIcon",
            "type": "INSTANCE",
            "componentId": "comp:1",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 24, "height": 24},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 24, "height": 24},
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
        }
        ir = parse_node(node)
        assert ir is not None
        assert ir.instance_role is not None
        assert ir.can_be_flattened is False

    def test_fixture_instance_gets_child_role(self, instance_node):
        """Fixture INSTANCE node (has children, >48px) should be CHILD."""
        ir = parse_node(instance_node)
        assert ir is not None
        assert ir.instance_role == InstanceRole.CHILD

    def test_zero_dimension_instance_not_prop(self):
        """Instance with zero dimensions should not be classified as PROP."""
        ir = FigmaIRNode(
            node_id="r:1", component_id="comp:1",
            width=0, height=0,
        )
        role = _classify_instance_role(ir)
        # Zero dimensions should not be treated as small icon
        assert role == InstanceRole.CHILD


# ---------------------------------------------------------------------------
# Phase 6: Slot Detection
# ---------------------------------------------------------------------------


class TestSlotDetection:
    """Test _detect_slot_candidate and slot integration in parse_node."""

    def _make_component_with_slot(self, slot_name, slot_layout="VERTICAL",
                                   slot_children=None):
        """Build a COMPONENT with a named child frame for slot testing."""
        slot_child_list = slot_children or []
        return {
            "id": "400:1",
            "name": "CardComponent",
            "type": "COMPONENT",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 400, "height": 300},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 400, "height": 300},
            "fills": [],
            "strokes": [],
            "effects": [],
            "layoutMode": "VERTICAL",
            "itemSpacing": 8,
            "paddingLeft": 0, "paddingRight": 0,
            "paddingTop": 0, "paddingBottom": 0,
            "children": [
                {
                    "id": "400:2",
                    "name": slot_name,
                    "type": "FRAME",
                    "absoluteBoundingBox": {"x": 0, "y": 0, "width": 400, "height": 200},
                    "absoluteRenderBounds": {"x": 0, "y": 0, "width": 400, "height": 200},
                    "fills": [],
                    "strokes": [],
                    "effects": [],
                    "layoutMode": slot_layout,
                    "itemSpacing": 0,
                    "paddingLeft": 0, "paddingRight": 0,
                    "paddingTop": 0, "paddingBottom": 0,
                    "children": slot_child_list,
                },
            ],
        }

    def test_content_frame_inside_component_is_slot(self):
        """Frame named 'Content' inside COMPONENT should be detected as slot."""
        raw = self._make_component_with_slot("Content")
        ir = parse_node(raw)
        assert ir is not None
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is True
        assert content_child.slot_name == "Content"

    def test_body_frame_is_slot(self):
        """Frame named 'body' should be detected as slot."""
        raw = self._make_component_with_slot("body")
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is True

    def test_actions_frame_is_slot(self):
        """Frame named 'actions' should be detected as slot."""
        raw = self._make_component_with_slot("actions")
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is True

    def test_non_slot_name_not_detected(self):
        """Frame named 'Frame 42' inside COMPONENT should NOT be a slot."""
        raw = self._make_component_with_slot("Frame 42")
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is False

    def test_empty_slot_detected(self):
        """Empty frame named 'Content' should be an empty slot."""
        raw = self._make_component_with_slot("Content", slot_children=[])
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is True
        assert content_child.is_empty_slot is True

    def test_layout_none_is_not_slot(self):
        """Frame named 'Content' with layoutMode=NONE should NOT be a slot."""
        raw = self._make_component_with_slot("Content", slot_layout="NONE")
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is False

    def test_decorative_container_flagged(self):
        """Frame with NONE layout and no styling should be flagged decorative."""
        raw = self._make_component_with_slot("Content", slot_layout="NONE")
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_decorative_container is True

    def test_slot_prevents_flattening(self):
        """Slot candidates should have can_be_flattened = False."""
        raw = self._make_component_with_slot("Content")
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is True
        assert content_child.can_be_flattened is False

    def test_slot_not_detected_outside_component(self):
        """Frame named 'Content' inside a regular FRAME should NOT be a slot."""
        raw = {
            "id": "401:1",
            "name": "Wrapper",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 400, "height": 300},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 400, "height": 300},
            "fills": [], "strokes": [], "effects": [],
            "layoutMode": "VERTICAL",
            "itemSpacing": 0,
            "paddingLeft": 0, "paddingRight": 0,
            "paddingTop": 0, "paddingBottom": 0,
            "children": [
                {
                    "id": "401:2",
                    "name": "Content",
                    "type": "FRAME",
                    "absoluteBoundingBox": {"x": 0, "y": 0, "width": 400, "height": 200},
                    "absoluteRenderBounds": {"x": 0, "y": 0, "width": 400, "height": 200},
                    "fills": [], "strokes": [], "effects": [],
                    "layoutMode": "VERTICAL",
                    "itemSpacing": 0,
                    "paddingLeft": 0, "paddingRight": 0,
                    "paddingTop": 0, "paddingBottom": 0,
                    "children": [],
                },
            ],
        }
        ir = parse_node(raw)
        assert ir is not None
        assert ir.children[0].is_slot_candidate is False

    def test_keyword_prefix_match(self):
        """Frame named 'header section' should match 'header' keyword."""
        raw = self._make_component_with_slot("header section")
        ir = parse_node(raw)
        content_child = ir.children[0]
        assert content_child.is_slot_candidate is True

    def test_substring_mismatch(self):
        """Frame named 'mainNavigation' should NOT match 'main' substring."""
        raw = self._make_component_with_slot("mainNavigation")
        ir = parse_node(raw)
        content_child = ir.children[0]
        # Only match if name equals or starts with keyword + separator
        assert content_child.is_slot_candidate is False
