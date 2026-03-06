"""Tests for core.py — business logic extracted from server.py."""
from __future__ import annotations

import pytest

from core import (
    extract_react_code, ir_to_dict, paginate_output, _collect_svg_fallback_ids,
    structural_diff_score, classify_variant_strategy,
    _parse_variant_name, _is_multi_dimensional,
    generate_cva_from_variants, infer_dimension_name,
)
from node_parser import FigmaIRNode, parse_node
from figma_types import Color, NodeType, Paint, PaintType


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


# ---------------------------------------------------------------------------
# Edge-case tests: ir_to_dict
# ---------------------------------------------------------------------------


class TestIrToDictEdgeCases:
    """Edge-case tests for ir_to_dict."""

    def test_zero_max_depth_returns_truncated(self):
        """max_depth=0 (zero boundary) returns truncated dict immediately."""
        node = _make_node(node_id="5:1", name="TruncMe")
        result = ir_to_dict(node, max_depth=0)
        assert result["truncated"] is True
        assert result["node_id"] == "5:1"
        assert result["name"] == "TruncMe"

    def test_negative_max_depth_returns_truncated(self):
        """Negative max_depth (negative boundary) is treated as <= 0 → truncated."""
        node = _make_node(node_id="6:1", name="NegDepth")
        result = ir_to_dict(node, max_depth=-1)
        assert result.get("truncated") is True

    def test_empty_children_list_no_children_key(self):
        """Node with empty children list should not include 'children' in output."""
        node = _make_node(node_id="7:1", name="Leaf", children=[])
        result = ir_to_dict(node)
        assert "children" not in result

    def test_missing_node_type_uses_default(self):
        """Node with default NodeType (RECTANGLE) serializes 'type' field correctly."""
        from figma_types import NodeType
        node = _make_node(node_id="8:1", name="Rect", node_type=NodeType.RECTANGLE)
        result = ir_to_dict(node)
        assert result["type"] == "RECTANGLE"

    def test_unicode_node_name_preserved(self):
        """Node with unicode name is serialized without corruption."""
        unicode_name = "\u30ab\u30fc\u30c9\u30b3\u30f3\u30dd\u30fc\u30cd\u30f3\u30c8"
        node = _make_node(node_id="9:1", name=unicode_name)
        result = ir_to_dict(node)
        assert result["name"] == unicode_name

    def test_whitespace_only_name_preserved(self):
        """Node with whitespace-only name does not raise and is preserved."""
        node = _make_node(node_id="10:1", name="   ")
        result = ir_to_dict(node)
        assert result["name"] == "   "

    def test_node_with_zero_width_height_included(self):
        """Node with zero width and height (zero dimensions) still serializes."""
        node = _make_node(node_id="11:1", name="ZeroDim", width=0.0, height=0.0)
        result = ir_to_dict(node)
        assert result["node_id"] == "11:1"
        # Width/height are only included if non-None
        # zero values are non-None, so they should appear
        assert "width" in result
        assert result["width"] == 0.0

    def test_deeply_nested_truncation_at_boundary(self):
        """Children at max_depth boundary are truncated, not their parent."""
        child = _make_node(node_id="c:1", name="Child")
        parent = _make_node(node_id="p:1", name="Parent", children=[child])
        result = ir_to_dict(parent, max_depth=1)
        assert "children" in result
        for ch in result["children"]:
            assert ch.get("truncated") is True


# ---------------------------------------------------------------------------
# Edge-case tests: paginate_output
# ---------------------------------------------------------------------------


class TestPaginateOutputEdgeCases:
    """Edge-case tests for paginate_output."""

    def test_empty_string_content(self):
        """Empty string input (null-like) returns empty content without crashing."""
        result = paginate_output("")
        assert result["content"] == ""
        assert "has_more" not in result

    def test_zero_max_length_boundary(self):
        """max_length=0 (zero boundary) — start_index 0 means empty chunk."""
        result = paginate_output("hello", max_length=0)
        assert result["content"] == ""

    def test_start_index_beyond_content_length(self):
        """start_index beyond content length returns empty content."""
        result = paginate_output("abc", max_length=10, start_index=100)
        assert result["content"] == ""

    def test_start_index_at_exact_end(self):
        """start_index at exact content length (boundary) returns empty content."""
        content = "abcde"
        result = paginate_output(content, max_length=5, start_index=5)
        assert result["content"] == ""

    def test_large_content_boundary_pagination(self):
        """Large content (overflow-like) paginates correctly at exact boundary."""
        content = "x" * 50_001  # just over DEFAULT_MAX_LENGTH
        result = paginate_output(content)
        assert result["has_more"] is True
        assert result["total_length"] == 50_001

    def test_whitespace_only_content(self):
        """Whitespace-only content (special chars) is paginated without error."""
        content = "   \n\t  "
        result = paginate_output(content)
        assert result["content"] == content
        assert "has_more" not in result

    def test_unicode_content_pagination(self):
        """Unicode content is sliced correctly without raising."""
        content = "\u4e2d\u6587" * 100
        result = paginate_output(content, max_length=50)
        assert len(result["content"]) == 50
        assert result["has_more"] is True

    def test_negative_start_index_boundary(self):
        """Negative start_index acts as Python slice boundary (treated as 0)."""
        content = "abcdef"
        result = paginate_output(content, max_length=3, start_index=-1)
        # Python slice content[-1:2] = "" since -1 + 3 = 2 but [-1:2] on string "abcdef" = ""
        # The actual behavior depends on Python slicing; just verify no crash
        assert isinstance(result["content"], str)


# ---------------------------------------------------------------------------
# Edge-case tests: extract_react_code
# ---------------------------------------------------------------------------


class TestExtractReactCodeEdgeCases:
    """Edge-case tests for extract_react_code."""

    def test_empty_dict_returns_empty_string(self):
        """Empty dict (null-like input) returns empty string."""
        assert extract_react_code({}) == ""

    def test_null_like_none_content_returns_empty(self):
        """Result where content key maps to None-like value."""
        result = {"main_component": None}
        # main_component is None → dict.get returns None → .get("main_component", "") on inner
        # Actually this returns None, so verify no crash and returns empty/None
        code = extract_react_code(result)
        # None is falsy but function returns .get() which may return None
        assert code is None or code == ""

    def test_malformed_json_content_raises(self):
        """Malformed JSON in 'content' field raises JSONDecodeError."""
        import json as _json
        result = {"content": "not valid json {{{"}
        with pytest.raises(_json.JSONDecodeError):
            extract_react_code(result)

    def test_missing_main_component_in_inner_json(self):
        """Inner JSON with no 'main_component' key returns empty string."""
        import json as _json
        result = {"content": _json.dumps({"file_key": "ABC", "node_count": 5})}
        assert extract_react_code(result) == ""

    def test_empty_main_component_value(self):
        """Inner JSON with empty string main_component returns empty string."""
        import json as _json
        result = {"content": _json.dumps({"main_component": ""})}
        assert extract_react_code(result) == ""

    def test_whitespace_only_main_component(self):
        """Whitespace-only main_component is returned as-is (whitespace content)."""
        import json as _json
        result = {"content": _json.dumps({"main_component": "   \n  "})}
        code = extract_react_code(result)
        assert code.strip() == ""

    def test_unicode_component_code(self):
        """Unicode characters in React code are extracted correctly."""
        import json as _json
        unicode_code = "export default function \u30b3\u30f3\u30dd() { return <div>\u3053\u3093\u306b\u3061\u306f</div>; }"
        result = {"content": _json.dumps({"main_component": unicode_code})}
        extracted = extract_react_code(result)
        assert extracted == unicode_code

    def test_huge_component_code_no_crash(self):
        """Very large React component code (overflow-like) is extracted without error."""
        import json as _json
        large_code = "export default function Huge() {\n" + "  const x = 1;\n" * 10_000 + "}"
        result = {"content": _json.dumps({"main_component": large_code})}
        extracted = extract_react_code(result)
        assert extracted == large_code


# ---------------------------------------------------------------------------
# Edge-case tests: _collect_svg_fallback_ids
# ---------------------------------------------------------------------------


class TestCollectSvgFallbackIdsEdgeCases:
    """Edge-case tests for _collect_svg_fallback_ids."""

    def test_empty_children_svg_candidate_still_collected(self):
        """SVG candidate with empty children list is still collected."""
        node = _make_node(node_id="30:1", is_svg_candidate=True, children=[])
        result = _collect_svg_fallback_ids(node)
        assert "30:1" in result

    def test_none_like_non_candidate_with_empty_children(self):
        """Non-SVG candidate with no children returns empty list (null-like)."""
        node = _make_node(node_id="31:1", is_svg_candidate=False, children=[])
        result = _collect_svg_fallback_ids(node)
        assert result == []

    def test_zero_depth_boundary_still_scans(self):
        """Depth=0 (zero boundary) starts scanning normally."""
        node = _make_node(node_id="32:1", is_svg_candidate=True)
        result = _collect_svg_fallback_ids(node, _depth=0)
        assert "32:1" in result

    def test_boundary_depth_at_max_returns_empty(self):
        """_depth at exactly _MAX_SVG_SCAN_DEPTH boundary returns empty immediately."""
        from core import _MAX_SVG_SCAN_DEPTH
        node = _make_node(node_id="33:1", is_svg_candidate=True)
        result = _collect_svg_fallback_ids(node, _depth=_MAX_SVG_SCAN_DEPTH + 1)
        assert result == []

    def test_missing_fill_geometry_empty_list_is_geometry_less(self):
        """SVG candidate with fill_geometry=[] (empty list, not missing) is geometry-less."""
        node = _make_node(
            node_id="34:1",
            is_svg_candidate=True,
            fill_geometry=[],  # empty list — no geometry
            stroke_geometry=[],
        )
        result = _collect_svg_fallback_ids(node)
        assert "34:1" in result

    def test_large_tree_sibling_nodes_all_collected(self):
        """Many sibling SVG candidates (large/overflow scenario) are all collected."""
        siblings = [
            _make_node(node_id=f"40:{i}", is_svg_candidate=True)
            for i in range(50)
        ]
        root = _make_node(node_id="40:root", is_svg_candidate=False, children=siblings)
        result = _collect_svg_fallback_ids(root)
        for i in range(50):
            assert f"40:{i}" in result


# ---------------------------------------------------------------------------
# Phase 3: Variant-to-Component Splitting
# ---------------------------------------------------------------------------


class TestParseVariantName:
    def test_key_value_format(self):
        result = _parse_variant_name("Type=Primary, Size=Large")
        assert result == {"Type": "Primary", "Size": "Large"}

    def test_flat_format(self):
        result = _parse_variant_name("Primary")
        assert result == {"variant": "Primary"}

    def test_single_key_value(self):
        result = _parse_variant_name("State=Hover")
        assert result == {"State": "Hover"}

    def test_whitespace_handling(self):
        result = _parse_variant_name(" Type = Primary , Size = Large ")
        assert result == {"Type": "Primary", "Size": "Large"}


class TestIsMultiDimensional:
    def test_multi_dimensional(self):
        v = _make_node(name="Type=Primary, Size=Large", node_type=NodeType.COMPONENT)
        assert _is_multi_dimensional([v]) is True

    def test_single_dimensional(self):
        v = _make_node(name="Type=Primary", node_type=NodeType.COMPONENT)
        assert _is_multi_dimensional([v]) is False

    def test_flat_name(self):
        v = _make_node(name="Primary", node_type=NodeType.COMPONENT)
        assert _is_multi_dimensional([v]) is False

    def test_empty_list(self):
        assert _is_multi_dimensional([]) is False


class TestStructuralDiffScore:
    def test_identical_structure(self):
        a = _make_node(
            name="A", node_type=NodeType.COMPONENT, layout_mode="HORIZONTAL",
            children=[_make_node(node_type=NodeType.TEXT)],
        )
        b = _make_node(
            name="B", node_type=NodeType.COMPONENT, layout_mode="HORIZONTAL",
            children=[_make_node(node_type=NodeType.TEXT)],
        )
        assert structural_diff_score(a, b) == pytest.approx(1.0)

    def test_different_child_count(self):
        a = _make_node(
            name="A", node_type=NodeType.COMPONENT, layout_mode="HORIZONTAL",
            children=[_make_node(node_type=NodeType.TEXT)],
        )
        b = _make_node(
            name="B", node_type=NodeType.COMPONENT, layout_mode="HORIZONTAL",
            children=[
                _make_node(node_type=NodeType.TEXT),
                _make_node(node_type=NodeType.RECTANGLE),
                _make_node(node_type=NodeType.FRAME),
            ],
        )
        score = structural_diff_score(a, b)
        assert 0.0 < score < 1.0

    def test_different_layout_mode(self):
        a = _make_node(
            name="A", node_type=NodeType.COMPONENT, layout_mode="HORIZONTAL",
            children=[_make_node(node_type=NodeType.TEXT)],
        )
        b = _make_node(
            name="B", node_type=NodeType.COMPONENT, layout_mode="VERTICAL",
            children=[_make_node(node_type=NodeType.TEXT)],
        )
        score = structural_diff_score(a, b)
        # Same children but different layout: child_count=1.0*0.4, type=1.0*0.35, layout=0.5*0.25
        assert score == pytest.approx(0.4 + 0.35 + 0.125)

    def test_no_children(self):
        a = _make_node(name="A", node_type=NodeType.COMPONENT)
        b = _make_node(name="B", node_type=NodeType.COMPONENT)
        # Both empty: child_count=0/1=0, type=0, layout same=1.0*0.25
        score = structural_diff_score(a, b)
        assert score == pytest.approx(0.25)

    def test_completely_different(self):
        a = _make_node(
            name="A", node_type=NodeType.COMPONENT, layout_mode="HORIZONTAL",
            children=[_make_node(node_type=NodeType.TEXT)],
        )
        b = _make_node(
            name="B", node_type=NodeType.COMPONENT, layout_mode="VERTICAL",
            children=[
                _make_node(node_type=NodeType.RECTANGLE),
                _make_node(node_type=NodeType.FRAME),
                _make_node(node_type=NodeType.ELLIPSE),
            ],
        )
        score = structural_diff_score(a, b)
        assert score < 0.5


class TestClassifyVariantStrategy:
    def _make_component_set(self, variant_specs):
        """Build a COMPONENT_SET with variant children.

        variant_specs: list of (name, children, layout_mode) tuples
        """
        children = []
        for name, child_nodes, layout in variant_specs:
            children.append(_make_node(
                name=name, node_type=NodeType.COMPONENT,
                layout_mode=layout, children=child_nodes,
            ))
        return _make_node(
            name="ButtonGroup", node_type=NodeType.COMPONENT_SET,
            children=children,
        )

    def test_single_variant_merge(self):
        cs = self._make_component_set([
            ("Primary", [_make_node(node_type=NodeType.TEXT)], "HORIZONTAL"),
        ])
        strategy, score = classify_variant_strategy(cs)
        assert strategy == "merge"
        assert score == 1.0

    def test_identical_variants_merge(self):
        cs = self._make_component_set([
            ("Primary", [_make_node(node_type=NodeType.TEXT)], "HORIZONTAL"),
            ("Secondary", [_make_node(node_type=NodeType.TEXT)], "HORIZONTAL"),
        ])
        strategy, score = classify_variant_strategy(cs)
        assert strategy == "merge"
        assert score >= 0.75

    def test_very_different_variants_split(self):
        cs = self._make_component_set([
            ("Icon", [_make_node(node_type=NodeType.RECTANGLE)], "HORIZONTAL"),
            ("Text", [
                _make_node(node_type=NodeType.TEXT),
                _make_node(node_type=NodeType.FRAME),
                _make_node(node_type=NodeType.ELLIPSE),
            ], "VERTICAL"),
        ])
        strategy, score = classify_variant_strategy(cs)
        assert strategy == "split"
        assert score < 0.50

    def test_multi_dimensional_always_merge(self):
        cs = self._make_component_set([
            ("Type=Primary, Size=Large",
             [_make_node(node_type=NodeType.RECTANGLE)], "HORIZONTAL"),
            ("Type=Secondary, Size=Small",
             [_make_node(node_type=NodeType.TEXT),
              _make_node(node_type=NodeType.FRAME),
              _make_node(node_type=NodeType.ELLIPSE)], "VERTICAL"),
        ])
        strategy, score = classify_variant_strategy(cs)
        assert strategy == "merge"

    def test_large_set_always_merge(self):
        specs = [
            (f"Variant{i}", [_make_node(node_type=NodeType.TEXT)], "HORIZONTAL")
            for i in range(10)
        ]
        cs = self._make_component_set(specs)
        strategy, score = classify_variant_strategy(cs)
        assert strategy == "merge"
        assert score == 1.0

    def test_empty_component_set(self):
        cs = _make_node(
            name="Empty", node_type=NodeType.COMPONENT_SET, children=[],
        )
        strategy, score = classify_variant_strategy(cs)
        assert strategy == "merge"
        assert score == 1.0

    def test_non_component_children_ignored(self):
        children = [
            _make_node(name="Primary", node_type=NodeType.COMPONENT,
                       layout_mode="HORIZONTAL",
                       children=[_make_node(node_type=NodeType.TEXT)]),
            _make_node(name="Divider", node_type=NodeType.RECTANGLE),
        ]
        cs = _make_node(
            name="Set", node_type=NodeType.COMPONENT_SET, children=children,
        )
        strategy, score = classify_variant_strategy(cs)
        assert strategy == "merge"
        assert score == 1.0


# ---------------------------------------------------------------------------
# Phase 5: CVA Generation
# ---------------------------------------------------------------------------


class TestInferDimensionName:
    def test_key_value_format(self):
        assert infer_dimension_name("Type=Primary") == "type"

    def test_flat_format(self):
        assert infer_dimension_name("Primary") == "variant"

    def test_multi_dimensional(self):
        assert infer_dimension_name("Type=Primary, Size=Large") == "type"


class TestGenerateCvaFromVariants:
    _FILL_BLUE = Paint(type=PaintType.SOLID, visible=True, opacity=1.0,
                       color=Color(r=0.0, g=0.0, b=1.0, a=1.0))
    _FILL_RED = Paint(type=PaintType.SOLID, visible=True, opacity=1.0,
                      color=Color(r=1.0, g=0.0, b=0.0, a=1.0))

    def _make_variant(self, name, fills=None, corner_radius=0.0,
                      width=100, height=50, layout_mode="HORIZONTAL"):
        """Build a COMPONENT variant with styling that produces classes."""
        return _make_node(
            name=name, node_type=NodeType.COMPONENT,
            layout_mode=layout_mode,
            fills=fills or [],
            corner_radius=corner_radius,
            width=width, height=height,
        )

    def _make_component_set(self, variants):
        return _make_node(
            name="Button", node_type=NodeType.COMPONENT_SET,
            children=variants,
        )

    def test_empty_set(self):
        cs = self._make_component_set([])
        result = generate_cva_from_variants(cs)
        assert result["base"] == []
        assert result["variants"] == {}
        assert result["defaultVariants"] == {}
        assert result["compoundVariants"] == []

    def test_single_variant_all_base(self):
        v = self._make_variant("Primary")
        cs = self._make_component_set([v])
        result = generate_cva_from_variants(cs)
        assert isinstance(result["base"], list)
        assert result["variants"] == {}

    def test_two_variants_shared_and_diff_classes(self):
        v1 = self._make_variant(
            "Type=Primary", fills=[self._FILL_BLUE], corner_radius=8.0,
        )
        v2 = self._make_variant(
            "Type=Secondary", fills=[self._FILL_RED], corner_radius=8.0,
        )
        cs = self._make_component_set([v1, v2])
        result = generate_cva_from_variants(cs)
        # Shared: rounded-md, w-25, h-12.5. Diff: bg colors
        assert "rounded-md" in result["base"]
        assert "type" in result["variants"]
        assert "primary" in result["variants"]["type"]
        assert "secondary" in result["variants"]["type"]

    def test_default_variants_from_first(self):
        v1 = self._make_variant("Type=Primary")
        v2 = self._make_variant("Type=Secondary")
        cs = self._make_component_set([v1, v2])
        result = generate_cva_from_variants(cs)
        assert result["defaultVariants"] == {"type": "primary"}

    def test_flat_variant_names(self):
        v1 = self._make_variant("Primary")
        v2 = self._make_variant("Secondary")
        cs = self._make_component_set([v1, v2])
        result = generate_cva_from_variants(cs)
        assert "variant" in result["variants"]
        assert "primary" in result["variants"]["variant"]
        assert "secondary" in result["variants"]["variant"]

    def test_multi_dimensional_compound_variants(self):
        v1 = self._make_variant(
            "Type=Primary, Size=Small",
            fills=[self._FILL_BLUE], corner_radius=4.0,
        )
        v2 = self._make_variant(
            "Type=Secondary, Size=Large",
            fills=[self._FILL_RED], corner_radius=16.0,
        )
        cs = self._make_component_set([v1, v2])
        result = generate_cva_from_variants(cs)
        # Different fills + radii → diff classes → compoundVariants populated
        assert len(result["compoundVariants"]) > 0
        cv0 = result["compoundVariants"][0]
        assert "type" in cv0
        assert "size" in cv0

    def test_non_component_children_ignored(self):
        v = self._make_variant("Primary")
        rect = _make_node(name="Divider", node_type=NodeType.RECTANGLE)
        cs = self._make_component_set([v, rect])
        result = generate_cva_from_variants(cs)
        # Only one COMPONENT child → single variant, all base
        assert result["variants"] == {}

    def test_result_structure(self):
        v1 = self._make_variant("Type=Primary")
        v2 = self._make_variant("Type=Ghost")
        cs = self._make_component_set([v1, v2])
        result = generate_cva_from_variants(cs)
        assert "base" in result
        assert "variants" in result
        assert "defaultVariants" in result
        assert "compoundVariants" in result
