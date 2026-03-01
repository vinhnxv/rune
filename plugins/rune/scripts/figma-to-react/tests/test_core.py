"""Tests for core.py — business logic extracted from server.py."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Add parent directory to path so we can import the module under test
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import extract_react_code, ir_to_dict, paginate_output, _collect_svg_fallback_ids  # noqa: E402
from node_parser import FigmaIRNode, parse_node  # noqa: E402
from figma_types import NodeType  # noqa: E402


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def _make_node(**overrides) -> FigmaIRNode:
    defaults = dict(node_id="1:1", name="Node", node_type=NodeType.RECTANGLE)
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


# ---------------------------------------------------------------------------
# ir_to_dict
# ---------------------------------------------------------------------------


class TestIrToDict:
    """Test IR node tree serialization."""

    def test_basic_frame(self, hero_card_node):
        """Convert a parsed frame to dict."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        result = ir_to_dict(ir)
        assert result["node_id"] == "1:2"
        assert result["name"] == "HeroCard"
        assert "children" in result

    def test_max_depth_truncation(self, hero_card_node):
        """Nodes beyond max_depth are truncated."""
        ir = parse_node(hero_card_node)
        assert ir is not None
        result = ir_to_dict(ir, max_depth=1)
        if "children" in result:
            for child in result["children"]:
                assert child.get("truncated") is True

    def test_text_content_included(self, text_node):
        """Text nodes include content and font info."""
        ir = parse_node(text_node)
        assert ir is not None
        result = ir_to_dict(ir)
        assert "text_content" in result
        assert result["text_content"] == "Welcome to Rune"


# ---------------------------------------------------------------------------
# paginate_output
# ---------------------------------------------------------------------------


class TestPaginateOutput:
    """Test output pagination logic."""

    def test_small_content_no_pagination(self):
        content = "hello world"
        result = paginate_output(content)
        assert result["content"] == "hello world"
        assert "has_more" not in result

    def test_large_content_paginated(self):
        content = "x" * 100
        result = paginate_output(content, max_length=30)
        assert len(result["content"]) == 30
        assert result["has_more"] is True
        assert result["next_start_index"] == 30
        assert result["total_length"] == 100

    def test_start_index_offset(self):
        content = "abcdefghij"
        result = paginate_output(content, max_length=3, start_index=5)
        assert result["content"] == "fgh"
        assert result["start_index"] == 5
        assert result["end_index"] == 8

    def test_last_page_no_has_more(self):
        content = "abcdefghij"
        result = paginate_output(content, max_length=5, start_index=5)
        assert result["content"] == "fghij"
        assert "has_more" not in result


# ---------------------------------------------------------------------------
# extract_react_code
# ---------------------------------------------------------------------------


class TestExtractReactCode:
    """Test extracting raw React code from paginated to_react() results."""

    def test_extracts_from_paginated_result(self):
        """Standard paginated result with JSON content string."""
        import json
        inner = {"file_key": "ABC", "main_component": "export default function Foo() {}"}
        result = {"content": json.dumps(inner)}
        assert extract_react_code(result) == "export default function Foo() {}"

    def test_extracts_from_plain_dict(self):
        """Unpaginated dict (content is not a string)."""
        result = {"main_component": "const Bar = () => <div/>"}
        assert extract_react_code(result) == "const Bar = () => <div/>"

    def test_missing_main_component_returns_empty(self):
        """Returns empty string when main_component is absent."""
        import json
        result = {"content": json.dumps({"file_key": "X"})}
        assert extract_react_code(result) == ""

    def test_empty_result_returns_empty(self):
        """Gracefully handles empty dict."""
        assert extract_react_code({}) == ""


# ---------------------------------------------------------------------------
# Data preservation (P0 — validates the Pydantic bypass fix)
# ---------------------------------------------------------------------------


class TestDataPreservation:
    """Verify raw dict bypass preserves type-specific Figma fields.

    These tests simulate what _fetch_node_or_file() now returns:
    raw dicts with characters, layoutMode, fillGeometry, etc.
    """

    def test_text_characters_preserved(self):
        """TEXT node's characters field survives the roundtrip."""
        raw = {
            "id": "100:1",
            "name": "SignUp",
            "type": "TEXT",
            "characters": "Sign up with Facebook",
            "style": {"fontFamily": "Inter", "fontSize": 16.0, "fontWeight": 400.0},
            "fills": [],
            "strokes": [],
            "effects": [],
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 200, "height": 24},
        }
        ir = parse_node(raw)
        assert ir is not None
        assert ir.text_content == "Sign up with Facebook"

    def test_layout_mode_preserved(self):
        """FRAME node's layoutMode field survives the roundtrip."""
        raw = {
            "id": "100:2",
            "name": "Container",
            "type": "FRAME",
            "layoutMode": "VERTICAL",
            "itemSpacing": 48,
            "paddingTop": 16, "paddingRight": 16,
            "paddingBottom": 16, "paddingLeft": 16,
            "fills": [], "strokes": [], "effects": [],
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 400, "height": 600},
            "children": [],
        }
        ir = parse_node(raw)
        assert ir is not None
        assert ir.has_auto_layout is True
        assert ir.layout_mode.value == "VERTICAL"
        assert ir.item_spacing == 48

    def test_fill_geometry_preserved(self):
        """VECTOR node's fillGeometry field survives the roundtrip."""
        raw = {
            "id": "100:3",
            "name": "ArrowIcon",
            "type": "VECTOR",
            "fillGeometry": [
                {"path": "M10 20L20 10L30 20", "windingRule": "NONZERO"}
            ],
            "fills": [], "strokes": [], "effects": [],
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 30, "height": 20},
        }
        ir = parse_node(raw)
        assert ir is not None
        assert len(ir.fill_geometry) == 1
        assert ir.fill_geometry[0]["path"] == "M10 20L20 10L30 20"

    def test_nested_text_in_frame(self):
        """Text content survives when nested inside auto-layout frames."""
        raw = {
            "id": "100:4",
            "name": "Card",
            "type": "FRAME",
            "layoutMode": "VERTICAL",
            "itemSpacing": 16,
            "fills": [], "strokes": [], "effects": [],
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 300, "height": 400},
            "children": [
                {
                    "id": "100:5",
                    "name": "Title",
                    "type": "TEXT",
                    "characters": "Welcome",
                    "style": {"fontFamily": "Inter", "fontSize": 24.0, "fontWeight": 700.0},
                    "fills": [], "strokes": [], "effects": [],
                    "absoluteBoundingBox": {"x": 0, "y": 0, "width": 200, "height": 30},
                },
                {
                    "id": "100:6",
                    "name": "Body",
                    "type": "TEXT",
                    "characters": "Hello world",
                    "style": {"fontFamily": "Inter", "fontSize": 14.0, "fontWeight": 400.0},
                    "fills": [], "strokes": [], "effects": [],
                    "absoluteBoundingBox": {"x": 0, "y": 0, "width": 200, "height": 20},
                },
            ],
        }
        ir = parse_node(raw)
        assert ir is not None
        assert len(ir.children) == 2
        assert ir.children[0].text_content == "Welcome"
        assert ir.children[1].text_content == "Hello world"
        assert ir.has_auto_layout is True


# ---------------------------------------------------------------------------
# _collect_svg_fallback_ids (Task 6 — DS-6, WS-8)
# ---------------------------------------------------------------------------


class TestCollectSvgFallbackIds:
    """Test SVG fallback ID collection for geometry-less SVG candidates."""

    def test_geometry_less_candidate_collected(self):
        """SVG candidate with no geometry is included."""
        node = _make_node(node_id="20:1", is_svg_candidate=True)
        result = _collect_svg_fallback_ids(node)
        assert "20:1" in result

    def test_candidate_with_fill_geometry_excluded(self):
        """SVG candidate WITH fill_geometry is not collected (has inline paths)."""
        node = _make_node(
            node_id="20:2",
            is_svg_candidate=True,
            fill_geometry=[{"path": "M0 0 L10 10 Z", "windingRule": "NONZERO"}],
        )
        result = _collect_svg_fallback_ids(node)
        assert "20:2" not in result

    def test_candidate_with_stroke_geometry_excluded(self):
        """SVG candidate WITH stroke_geometry is not collected."""
        node = _make_node(
            node_id="20:3",
            is_svg_candidate=True,
            stroke_geometry=[{"path": "M0 0 L10 10 Z", "windingRule": "NONZERO"}],
        )
        result = _collect_svg_fallback_ids(node)
        assert "20:3" not in result

    def test_non_candidate_not_collected(self):
        """Regular RECTANGLE is not an SVG candidate — not collected."""
        node = _make_node(node_id="20:4", is_svg_candidate=False)
        result = _collect_svg_fallback_ids(node)
        assert "20:4" not in result

    def test_geometry_less_candidate_recurses_into_children(self):
        """Geometry-less SVG candidates recurse into children (VEIL-004)."""
        child = _make_node(node_id="21:2", is_svg_candidate=True)
        parent = _make_node(node_id="21:1", is_svg_candidate=True, children=[child])
        result = _collect_svg_fallback_ids(parent)
        # Both collected — geometry-less candidates recurse into children
        assert "21:1" in result
        assert "21:2" in result

    def test_nested_candidates_in_non_svg_parent(self):
        """Multiple geometry-less SVG candidates in different branches."""
        child1 = _make_node(node_id="22:2", is_svg_candidate=True)
        child2 = _make_node(node_id="22:3", is_svg_candidate=True)
        root = _make_node(node_id="22:1", is_svg_candidate=False, children=[child1, child2])
        result = _collect_svg_fallback_ids(root)
        assert "22:2" in result
        assert "22:3" in result
        assert "22:1" not in result

    def test_depth_cap_prevents_infinite_recursion(self):
        """Pathologically deep trees stop at _MAX_SVG_SCAN_DEPTH."""
        # Build 105-deep chain — depth limit is 100
        node = _make_node(node_id="99:1", is_svg_candidate=False)
        for i in range(105):
            parent = _make_node(node_id=f"99:{i+2}", is_svg_candidate=False, children=[node])
            node = parent
        # Should not raise RecursionError
        result = _collect_svg_fallback_ids(node)
        assert isinstance(result, list)

    def test_boolean_op_no_geometry_collected_via_parse_node(self):
        """BACK-003: Boolean op with no geometry is collected via full pipeline."""
        raw = {
            "id": "bo:1",
            "name": "Icon",
            "type": "BOOLEAN_OPERATION",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 24, "height": 24},
            "absoluteRenderBounds": {"x": 0, "y": 0, "width": 24, "height": 24},
            "booleanOperation": "UNION",
            "fills": [],
            "strokes": [],
            "effects": [],
            "children": [],
            # note: no fillGeometry key — geometry-less SVG candidate
        }
        ir = parse_node(raw)
        assert ir is not None
        ids = _collect_svg_fallback_ids(ir)
        assert "bo:1" in ids
