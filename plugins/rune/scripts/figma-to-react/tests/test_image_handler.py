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
