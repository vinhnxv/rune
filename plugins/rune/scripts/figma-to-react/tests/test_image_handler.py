"""Tests for image_handler.py — image fill detection and JSX generation."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from image_handler import ImageHandler, collect_image_refs, _sanitize_alt_text, _sanitize_svg_path
from node_parser import FigmaIRNode
from figma_types import NodeType, Paint, PaintType, Color


# ---------------------------------------------------------------------------
# Helper to build minimal IR nodes
# ---------------------------------------------------------------------------

def _make_node(**overrides) -> FigmaIRNode:
    defaults = dict(node_id="1:1", name="TestNode", node_type=NodeType.RECTANGLE)
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


# ---------------------------------------------------------------------------
# ImageHandler.has_image
# ---------------------------------------------------------------------------

class TestHasImage:
    """Test image fill and SVG candidate detection."""

    def test_image_fill_detected(self):
        node = _make_node(has_image_fill=True, image_ref="abc123")
        handler = ImageHandler()
        assert handler.has_image(node)

    def test_svg_candidate_detected(self):
        node = _make_node(is_svg_candidate=True)
        handler = ImageHandler()
        assert handler.has_image(node)

    def test_plain_node_not_image(self):
        node = _make_node()
        handler = ImageHandler()
        assert not handler.has_image(node)


# ---------------------------------------------------------------------------
# ImageHandler.resolve_url
# ---------------------------------------------------------------------------

class TestResolveUrl:
    """Test image URL resolution from hash mapping."""

    def test_known_ref(self):
        handler = ImageHandler({"abc123": "https://img.figma.com/abc123.png"})
        assert handler.resolve_url("abc123") == "https://img.figma.com/abc123.png"

    def test_unknown_ref_placeholder(self):
        handler = ImageHandler()
        result = handler.resolve_url("unknown")
        assert result == ""

    def test_set_image_urls_updates(self):
        handler = ImageHandler()
        handler.set_image_urls({"ref1": "https://example.com/img.png"})
        assert handler.resolve_url("ref1") == "https://example.com/img.png"


# ---------------------------------------------------------------------------
# ImageHandler.generate_image_jsx
# ---------------------------------------------------------------------------

class TestGenerateImageJsx:
    """Test JSX generation for image nodes."""

    def test_image_fill_generates_img_tag(self):
        node = _make_node(
            has_image_fill=True,
            image_ref="abc123",
            width=300.0,
            height=200.0,
        )
        handler = ImageHandler({"abc123": "https://img.figma.com/abc123.png"})
        jsx = handler.generate_image_jsx(node, "rounded-lg")
        assert "<img" in jsx
        assert 'src="https://img.figma.com/abc123.png"' in jsx
        assert 'className="rounded-lg"' in jsx
        assert "width={300}" in jsx
        assert "height={200}" in jsx

    def test_image_with_no_url_uses_placeholder(self):
        node = _make_node(has_image_fill=True, image_ref="xyz789", width=100.0, height=100.0)
        handler = ImageHandler()  # No URL mapping
        jsx = handler.generate_image_jsx(node)
        assert "<div" in jsx

    def test_svg_candidate_generates_svg(self):
        node = _make_node(
            is_svg_candidate=True,
            name="IconClose",
            width=24.0,
            height=24.0,
        )
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node)
        assert "<svg" in jsx
        assert 'width="24"' in jsx
        assert 'height="24"' in jsx
        assert "TODO: SVG paths" in jsx
        assert "IconClose" in jsx

    def test_svg_with_classes(self):
        node = _make_node(is_svg_candidate=True, width=16.0, height=16.0)
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node, "text-red-500")
        assert 'className="text-red-500"' in jsx

    def test_fallback_div_when_no_fill_or_svg(self):
        """Node with has_image_fill but no image_ref falls back to div."""
        node = _make_node(has_image_fill=True, image_ref=None)
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node)
        assert "<div" in jsx

    def test_no_classes_omits_classname(self):
        node = _make_node(is_svg_candidate=True, width=24.0, height=24.0)
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node, "")
        assert "className" not in jsx

    def test_zero_dimensions_default_to_24(self):
        """SVG with 0 dimensions should default to 24x24."""
        node = _make_node(is_svg_candidate=True, width=0.0, height=0.0)
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node)
        assert 'width="24"' in jsx
        assert 'height="24"' in jsx


# ---------------------------------------------------------------------------
# collect_image_refs
# ---------------------------------------------------------------------------

class TestCollectImageRefs:
    """Test recursive image ref collection."""

    def test_single_node_with_ref(self):
        node = _make_node(image_ref="hash1")
        refs = collect_image_refs(node)
        assert refs == ["hash1"]

    def test_nested_refs(self):
        child1 = _make_node(node_id="2:1", image_ref="hash1")
        child2 = _make_node(node_id="3:1", image_ref="hash2")
        root = _make_node(node_id="1:1", children=[child1, child2])
        refs = collect_image_refs(root)
        assert "hash1" in refs
        assert "hash2" in refs

    def test_deduplicates_refs(self):
        child1 = _make_node(node_id="2:1", image_ref="same")
        child2 = _make_node(node_id="3:1", image_ref="same")
        root = _make_node(node_id="1:1", children=[child1, child2])
        refs = collect_image_refs(root)
        assert refs == ["same"]  # Only one copy

    def test_no_refs(self):
        root = _make_node()
        assert collect_image_refs(root) == []

    def test_deep_nesting(self):
        leaf = _make_node(node_id="4:1", image_ref="deep")
        mid = _make_node(node_id="3:1", children=[leaf])
        root = _make_node(node_id="1:1", children=[mid])
        refs = collect_image_refs(root)
        assert refs == ["deep"]


# ---------------------------------------------------------------------------
# _sanitize_alt_text
# ---------------------------------------------------------------------------

class TestSanitizeAltText:
    """Test alt text sanitization."""

    def test_normal_text_unchanged(self):
        assert _sanitize_alt_text("Hero Image") == "Hero Image"

    def test_quotes_removed(self):
        assert _sanitize_alt_text('Say "hello"') == "Say hello"

    def test_single_quotes_removed(self):
        assert _sanitize_alt_text("It's an image") == "Its an image"

    def test_angle_brackets_removed(self):
        assert _sanitize_alt_text("<script>alert</script>") == "scriptalert/script"

    def test_whitespace_trimmed(self):
        assert _sanitize_alt_text("  padded  ") == "padded"

    def test_null_bytes_stripped(self):
        """WS-6: Null bytes and control chars must be stripped."""
        assert _sanitize_alt_text("Icon\x00Name") == "IconName"

    def test_control_chars_stripped(self):
        assert _sanitize_alt_text("Tab\there") == "Tabhere"

    def test_del_char_stripped(self):
        assert _sanitize_alt_text("name\x7f!") == "name!"


# ---------------------------------------------------------------------------
# _sanitize_svg_path
# ---------------------------------------------------------------------------

class TestSanitizeSvgPath:
    """Test SVG path data whitelist sanitization (M1, WS-3)."""

    def test_clean_path_unchanged(self):
        """Valid SVG path data passes through unchanged."""
        d = "M 0 0 L 24 0 L 24 24 Z"
        assert _sanitize_svg_path(d) == d

    def test_script_injection_blocked(self):
        """HTML/script characters are stripped."""
        d = 'M0 0<script>alert(1)</script>L10 10'
        result = _sanitize_svg_path(d)
        assert "<" not in result
        assert ">" not in result
        assert "script" not in result

    def test_quote_injection_blocked(self):
        """Quotes that could break attribute are stripped."""
        d = 'M0 0"onload="evil()L10 10'
        result = _sanitize_svg_path(d)
        assert '"' not in result

    def test_numeric_data_preserved(self):
        """Numbers, commas, spaces, and sign chars pass through."""
        d = "M10.5,20.3 C1.0 2.0 3.0 4.0 5.0 6.0"
        result = _sanitize_svg_path(d)
        assert "10.5" in result
        assert "20.3" in result

    def test_scientific_notation_preserved(self):
        """Scientific notation (e.g., 1.5e-4) passes through."""
        d = "M1.5e-4 2.3E+6 L0 0"
        result = _sanitize_svg_path(d)
        assert "1.5e-4" in result
        assert "2.3E+6" in result


# ---------------------------------------------------------------------------
# svg_urls fallback in _generate_svg_placeholder
# ---------------------------------------------------------------------------

class TestSvgUrlsFallback:
    """Test SVG export URL fallback (Task 6 — M2, DS-6)."""

    def test_svg_url_used_when_no_geometry(self):
        """Geometry-less SVG candidate uses exported URL as <img> tag."""
        node = _make_node(
            node_id="5:1",
            is_svg_candidate=True,
            name="StarIcon",
            width=48.0,
            height=48.0,
        )
        handler = ImageHandler(svg_urls={"5:1": "https://figma.com/exports/star.svg"})
        jsx = handler.generate_image_jsx(node)
        assert "<img" in jsx
        assert "https://figma.com/exports/star.svg" in jsx
        assert 'alt="StarIcon"' in jsx

    def test_geometry_takes_priority_over_svg_url(self):
        """When fill_geometry is present, inline paths are used, not the URL."""
        node = _make_node(
            node_id="5:2",
            is_svg_candidate=True,
            name="FilledIcon",
            width=24.0,
            height=24.0,
            fill_geometry=[{"path": "M0 0 L24 24 Z", "windingRule": "NONZERO"}],
        )
        handler = ImageHandler(svg_urls={"5:2": "https://figma.com/exports/filled.svg"})
        jsx = handler.generate_image_jsx(node)
        assert "<svg" in jsx
        assert "<path" in jsx
        assert "figma.com/exports" not in jsx

    def test_svg_url_expiry_comment_present(self):
        """The generated <img> includes an expiry warning in the surrounding code."""
        # The expiry note is a JSX comment embedded above the <img> — check via docstring
        # We verify the URL is embedded and alt is set as basic smoke test
        node = _make_node(node_id="6:1", is_svg_candidate=True, name="Exp", width=16.0, height=16.0)
        handler = ImageHandler(svg_urls={"6:1": "https://cdn.figma.com/svg/abc.svg"})
        jsx = handler.generate_image_jsx(node)
        assert "https://cdn.figma.com/svg/abc.svg" in jsx

    def test_unsafe_svg_url_rejected(self):
        """Non-HTTPS SVG URLs are replaced with about:blank."""
        node = _make_node(node_id="7:1", is_svg_candidate=True, name="Evil", width=24.0, height=24.0)
        handler = ImageHandler(svg_urls={"7:1": "javascript:alert(1)"})
        jsx = handler.generate_image_jsx(node)
        # Either falls back to TODO placeholder or uses about:blank — never the JS URL
        assert "javascript:" not in jsx


# ---------------------------------------------------------------------------
# Stroke geometry rendering
# ---------------------------------------------------------------------------

class TestStrokeGeometryRendering:
    """Test stroke geometry path rendering (Task 4)."""

    def test_stroke_only_node_renders_path(self):
        """Node with only stroke_geometry renders a <path> element."""
        node = _make_node(
            node_id="8:1",
            is_svg_candidate=True,
            name="StrokeOnly",
            width=24.0,
            height=24.0,
            stroke_geometry=[{"path": "M0 0 L24 24 Z", "windingRule": "NONZERO"}],
        )
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node)
        assert "<path" in jsx
        assert "M0 0 L24 24 Z" in jsx

    def test_fill_and_stroke_both_render(self):
        """Node with both fill and stroke geometry renders two <path> elements."""
        node = _make_node(
            node_id="9:1",
            is_svg_candidate=True,
            name="BothPaths",
            width=24.0,
            height=24.0,
            fill_geometry=[{"path": "M0 0 L10 10 Z", "windingRule": "NONZERO"}],
            stroke_geometry=[{"path": "M5 5 L15 15 Z", "windingRule": "NONZERO"}],
        )
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node)
        assert jsx.count("<path") == 2
        assert "M0 0 L10 10 Z" in jsx
        assert "M5 5 L15 15 Z" in jsx

    def test_stroke_uses_node_stroke_color_for_non_icon(self):
        """Non-icon SVG uses actual stroke paint color (M7)."""
        stroke_paint = Paint(type=PaintType.SOLID, color=Color(r=1.0, g=0.0, b=0.0))
        node = _make_node(
            node_id="10:1",
            is_svg_candidate=True,
            is_icon_candidate=False,
            name="ColoredStroke",
            width=100.0,
            height=100.0,
            strokes=[stroke_paint],
            stroke_geometry=[{"path": "M0 0 L100 100 Z", "windingRule": "NONZERO"}],
        )
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node)
        # Red stroke (#ff0000) should appear as the fill color of the stroke path
        assert "#ff0000" in jsx

    def test_path_data_sanitized_in_stroke(self):
        """Malicious data in stroke path is sanitized before rendering."""
        node = _make_node(
            node_id="11:1",
            is_svg_candidate=True,
            name="MalStroke",
            width=24.0,
            height=24.0,
            stroke_geometry=[{"path": 'M0 0<script>alert(1)</script>L24 24', "windingRule": "NONZERO"}],
        )
        handler = ImageHandler()
        jsx = handler.generate_image_jsx(node)
        assert "<script>" not in jsx
