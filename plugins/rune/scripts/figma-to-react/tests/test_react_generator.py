"""Tests for react_generator.py — React JSX code generation from Figma IR."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from react_generator import (
    generate_component,
    generate_component_with_props,
    generate_split_components,
    _to_component_name,
    _escape_jsx,
    _resolve_html_tag,
    _deduplicate_classes,
    _is_decorative_name,
    _is_promotable_text,
    _resolve_aria_attrs,
    _format_html_attrs,
)
from node_parser import FigmaIRNode, StyledTextSegment
from figma_types import Color, LayoutMode, LayoutSizingMode, NodeType, Paint, PaintType, TypeStyle


# ---------------------------------------------------------------------------
# Helper to build minimal IR nodes
# ---------------------------------------------------------------------------

def _make_node(**overrides) -> FigmaIRNode:
    defaults = dict(
        node_id="1:1",
        name="TestFrame",
        node_type=NodeType.FRAME,
        is_frame_like=True,
        width=400.0,
        height=300.0,
    )
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


def _make_text_node(**overrides) -> FigmaIRNode:
    defaults = dict(
        node_id="2:1",
        name="Title",
        node_type=NodeType.TEXT,
        text_content="Hello World",
        width=200.0,
        height=24.0,
    )
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


# ---------------------------------------------------------------------------
# _to_component_name
# ---------------------------------------------------------------------------

class TestComponentName:
    """Test Figma name to React component name conversion."""

    def test_simple_name(self):
        assert _to_component_name("HeroCard") == "Herocard"

    def test_spaces_to_pascal(self):
        assert _to_component_name("hero card") == "HeroCard"

    def test_hyphens_to_pascal(self):
        assert _to_component_name("nav-bar") == "NavBar"

    def test_slashes_to_pascal(self):
        assert _to_component_name("icons/close") == "IconsClose"

    def test_number_prefix_gets_component(self):
        # capitalize() lowercases all but first char: "3dButton" -> "3dbutton"
        assert _to_component_name("3dButton") == "Component3dbutton"

    def test_empty_returns_component(self):
        assert _to_component_name("") == "Component"

    def test_special_chars_only(self):
        assert _to_component_name("---") == "Component"


# ---------------------------------------------------------------------------
# _escape_jsx
# ---------------------------------------------------------------------------

class TestEscapeJsx:
    """Test JSX text escaping."""

    def test_plain_text_unchanged(self):
        assert _escape_jsx("Hello World") == "Hello World"

    def test_curly_braces_escaped(self):
        result = _escape_jsx("{value}")
        assert "&#123;" in result
        assert "&#125;" in result

    def test_angle_brackets_escaped(self):
        result = _escape_jsx("<script>alert(1)</script>")
        assert "&lt;" in result
        assert "&gt;" in result


# ---------------------------------------------------------------------------
# generate_component — basic structure
# ---------------------------------------------------------------------------

class TestGenerateComponentStructure:
    """Test generated component structure and boilerplate."""

    def test_has_import(self):
        root = _make_node()
        code = generate_component(root)
        assert "import React from 'react'" in code

    def test_has_export_default(self):
        root = _make_node()
        code = generate_component(root)
        assert "export default function" in code

    def test_uses_node_name(self):
        root = _make_node(name="HeroSection")
        code = generate_component(root)
        assert "Herosection" in code

    def test_custom_name_override(self):
        root = _make_node(name="SomeFrame")
        code = generate_component(root, component_name="MyCard")
        assert "MyCard" in code
        assert "Someframe" not in code

    def test_has_return_statement(self):
        root = _make_node()
        code = generate_component(root)
        assert "return (" in code

    def test_ends_with_closing_brace(self):
        root = _make_node()
        code = generate_component(root)
        lines = code.strip().split("\n")
        assert any(line.strip() == "}" for line in lines)


# ---------------------------------------------------------------------------
# generate_component — empty/leaf nodes
# ---------------------------------------------------------------------------

class TestLeafNodes:
    """Test code generation for leaf and empty nodes."""

    def test_empty_frame_self_closing_div(self):
        root = _make_node(children=[])
        code = generate_component(root)
        assert "<div" in code
        assert "/>" in code

    def test_invisible_child_skipped(self):
        child = _make_node(node_id="2:1", visible=False)
        root = _make_node(children=[child])
        code = generate_component(root)
        assert "<div" in code


# ---------------------------------------------------------------------------
# generate_component — text nodes
# ---------------------------------------------------------------------------

class TestTextNodeGeneration:
    """Test code generation for text nodes."""

    def test_simple_text_generates_p_tag(self):
        text = _make_text_node()
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "<p" in code
        assert "Hello World" in code

    def test_text_with_jsx_special_chars(self):
        text = _make_text_node(text_content="Price: {$10}")
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "&#123;" in code

    def test_rich_text_with_segments(self):
        """Text with multiple styled segments should use span wrappers."""
        # TypeStyle uses Pydantic aliases — must use model_validate with alias keys
        style_bold = TypeStyle.model_validate({"fontSize": 16.0, "fontWeight": 700.0})
        style_normal = TypeStyle.model_validate({"fontSize": 16.0, "fontWeight": 400.0})
        segments = [
            StyledTextSegment(text="Bold ", style=style_bold),
            StyledTextSegment(text="and normal", style=style_normal),
        ]
        text = _make_text_node(
            text_content="Bold and normal",
            text_segments=segments,
        )
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "<span" in code
        assert "Bold " in code


# ---------------------------------------------------------------------------
# generate_component — image nodes
# ---------------------------------------------------------------------------

class TestImageNodeGeneration:
    """Test code generation for image and SVG nodes."""

    def test_image_fill_generates_img(self):
        img = _make_node(
            node_id="2:1",
            name="CardImage",
            node_type=NodeType.RECTANGLE,
            has_image_fill=True,
            image_ref="hash123",
            width=300.0,
            height=200.0,
        )
        root = _make_node(children=[img])
        code = generate_component(root, image_urls={"hash123": "https://cdn.example.com/img.png"})
        assert "<img" in code
        assert "https://cdn.example.com/img.png" in code

    def test_unresolved_image_adds_todo(self):
        img = _make_node(
            node_id="2:1",
            node_type=NodeType.RECTANGLE,
            has_image_fill=True,
            image_ref="unresolved_hash",
        )
        root = _make_node(children=[img])
        code = generate_component(root)
        assert "TODO" in code
        assert "unresolved_hash" in code

    def test_svg_candidate_generates_svg(self):
        icon = _make_node(
            node_id="2:1",
            name="CloseIcon",
            is_svg_candidate=True,
            width=24.0,
            height=24.0,
        )
        root = _make_node(children=[icon])
        code = generate_component(root)
        assert "<svg" in code
        assert "CloseIcon" in code


# ---------------------------------------------------------------------------
# generate_component — nested structure
# ---------------------------------------------------------------------------

class TestNestedGeneration:
    """Test code generation for nested node trees."""

    def test_nested_divs(self):
        inner = _make_node(node_id="3:1", name="Inner", children=[])
        middle = _make_node(node_id="2:1", name="Middle", children=[inner])
        root = _make_node(children=[middle])
        code = generate_component(root)
        assert code.count("<div") >= 2

    def test_layout_classes_on_container(self):
        child = _make_node(node_id="2:1", name="Child")
        root = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            item_spacing=8.0,
            children=[child],
        )
        code = generate_component(root)
        assert "flex" in code
        assert "flex-row" in code
        assert "gap-2" in code


# ---------------------------------------------------------------------------
# generate_component_with_props
# ---------------------------------------------------------------------------

class TestGenerateComponentWithProps:
    """Test component generation with TypeScript props interface."""

    def test_generates_interface(self):
        root = _make_node()
        code = generate_component_with_props(
            root,
            component_name="Card",
            prop_names=["title", "subtitle"],
        )
        assert "interface CardProps" in code
        assert "title?: string" in code
        assert "subtitle?: string" in code

    def test_destructures_props(self):
        root = _make_node()
        code = generate_component_with_props(
            root,
            component_name="Card",
            prop_names=["title"],
        )
        assert "{ title }: CardProps" in code

    def test_no_props_same_as_generate_component(self):
        root = _make_node()
        code = generate_component_with_props(root, component_name="Card")
        assert "interface" not in code
        assert "export default function Card()" in code

    def test_custom_name(self):
        root = _make_node()
        code = generate_component_with_props(
            root,
            component_name="MyWidget",
            prop_names=["size"],
        )
        assert "MyWidgetProps" in code
        assert "function MyWidget" in code


# ---------------------------------------------------------------------------
# _resolve_html_tag — semantic HTML mapping
# ---------------------------------------------------------------------------


class TestResolveHtmlTag:
    """Test Figma node to semantic HTML tag mapping."""

    def test_button_by_name(self):
        node = _make_node(name="Login Button")
        assert _resolve_html_tag(node) == "button"

    def test_btn_keyword(self):
        node = _make_node(name="primary-btn")
        assert _resolve_html_tag(node) == "button"

    def test_cta_keyword(self):
        node = _make_node(name="CTA Block")
        assert _resolve_html_tag(node) == "button"

    def test_input_by_name(self):
        node = _make_node(name="Email Input")
        assert _resolve_html_tag(node) == "input"

    def test_nav_by_name(self):
        node = _make_node(name="TopNav")
        assert _resolve_html_tag(node) == "nav"

    def test_header_by_name(self):
        node = _make_node(name="Header")
        assert _resolve_html_tag(node) == "header"

    def test_footer_by_name(self):
        node = _make_node(name="Footer Section")
        assert _resolve_html_tag(node) == "footer"

    def test_large_text_is_h1(self):
        style = TypeStyle.model_validate({"fontSize": 36.0, "fontWeight": 700.0})
        node = _make_text_node(name="Heading", text_style=style)
        assert _resolve_html_tag(node) == "h1"

    def test_medium_text_is_h2(self):
        style = TypeStyle.model_validate({"fontSize": 24.0, "fontWeight": 600.0})
        node = _make_text_node(name="Subheading", text_style=style)
        assert _resolve_html_tag(node) == "h2"

    def test_h3_text(self):
        style = TypeStyle.model_validate({"fontSize": 20.0, "fontWeight": 500.0})
        node = _make_text_node(name="Label", text_style=style)
        assert _resolve_html_tag(node) == "h3"

    def test_small_text_is_p(self):
        style = TypeStyle.model_validate({"fontSize": 14.0, "fontWeight": 400.0})
        node = _make_text_node(name="Body", text_style=style)
        assert _resolve_html_tag(node) == "p"

    def test_text_no_style_is_p(self):
        node = _make_text_node(name="SomeText")
        assert _resolve_html_tag(node) == "p"

    def test_plain_frame_is_div(self):
        node = _make_node(name="Container")
        assert _resolve_html_tag(node) == "div"


# ---------------------------------------------------------------------------
# Semantic HTML in generated components
# ---------------------------------------------------------------------------


class TestSemanticHtmlGeneration:
    """Test that semantic tags appear in generated component output."""

    def test_button_node_generates_button_tag(self):
        child = _make_node(node_id="2:1", name="Submit Button", children=[])
        root = _make_node(children=[child])
        code = generate_component(root)
        assert "<button" in code

    def test_heading_text_generates_h_tag(self):
        style = TypeStyle.model_validate({"fontSize": 32.0, "fontWeight": 700.0})
        text = _make_text_node(
            name="PageTitle",
            text_content="Welcome",
            text_style=style,
        )
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "<h1" in code
        assert "Welcome" in code

    def test_nav_container_generates_nav_tag(self):
        child = _make_node(node_id="3:1", name="Link", children=[])
        nav = _make_node(node_id="2:1", name="Navigation", children=[child])
        root = _make_node(children=[nav])
        code = generate_component(root)
        assert "<nav" in code

    def test_input_with_children_wraps_in_div(self):
        """Void element <input> with children wraps in div instead of nesting."""
        label = _make_text_node(node_id="3:1", name="Label", text_content="Email")
        field = _make_node(node_id="2:1", name="Text field", children=[label])
        root = _make_node(children=[field])
        code = generate_component(root)
        # Should NOT have <input>...</input> (void element with children)
        assert "<input>" not in code
        # Should have self-closing <input />
        assert "<input />" in code
        # Children should still render
        assert "Email" in code


# ---------------------------------------------------------------------------
# SVG path rendering
# ---------------------------------------------------------------------------


class TestSvgPathRendering:
    """Test SVG path generation from fillGeometry."""

    def test_fill_geometry_renders_path(self):
        icon = _make_node(
            node_id="2:1",
            name="ArrowIcon",
            is_svg_candidate=True,
            width=24.0,
            height=24.0,
            fill_geometry=[
                {"path": "M10 20L20 10L30 20", "windingRule": "NONZERO"}
            ],
        )
        root = _make_node(children=[icon])
        code = generate_component(root)
        assert "<svg" in code
        assert '<path d="M10 20L20 10L30 20"' in code
        assert "TODO" not in code

    def test_evenodd_winding_rule(self):
        icon = _make_node(
            node_id="2:1",
            name="StarIcon",
            is_svg_candidate=True,
            width=24.0,
            height=24.0,
            fill_geometry=[
                {"path": "M12 2L15 9H22L16 14L18 21L12 17L6 21L8 14L2 9H9Z",
                 "windingRule": "EVENODD"}
            ],
        )
        root = _make_node(children=[icon])
        code = generate_component(root)
        assert 'fillRule="evenodd"' in code

    def test_multiple_paths(self):
        icon = _make_node(
            node_id="2:1",
            name="ComplexIcon",
            is_svg_candidate=True,
            width=32.0,
            height=32.0,
            fill_geometry=[
                {"path": "M0 0L10 10", "windingRule": "NONZERO"},
                {"path": "M5 5L15 15", "windingRule": "NONZERO"},
            ],
        )
        root = _make_node(children=[icon])
        code = generate_component(root)
        assert code.count("<path") == 2

    def test_no_fill_geometry_shows_todo(self):
        """SVG candidate without fill_geometry falls back to TODO."""
        icon = _make_node(
            node_id="2:1",
            name="UnknownIcon",
            is_svg_candidate=True,
            width=24.0,
            height=24.0,
        )
        root = _make_node(children=[icon])
        code = generate_component(root)
        assert "<svg" in code
        assert "TODO" in code


# ---------------------------------------------------------------------------
# _deduplicate_classes
# ---------------------------------------------------------------------------


class TestDeduplicateClasses:
    """Test CSS class deduplication."""

    def test_removes_exact_duplicates(self):
        assert _deduplicate_classes(["w-36", "h-20", "w-36"]) == ["w-36", "h-20"]

    def test_preserves_order(self):
        assert _deduplicate_classes(["flex", "flex-col", "gap-2"]) == ["flex", "flex-col", "gap-2"]

    def test_empty_list(self):
        assert _deduplicate_classes([]) == []

    def test_all_unique(self):
        assert _deduplicate_classes(["a", "b", "c"]) == ["a", "b", "c"]

    def test_multiple_duplicates(self):
        result = _deduplicate_classes(["w-36", "h-20", "bg-white", "w-36", "h-20"])
        assert result == ["w-36", "h-20", "bg-white"]


# ---------------------------------------------------------------------------
# Text color (text-* instead of bg-* for TEXT fills)
# ---------------------------------------------------------------------------


class TestTextColorFills:
    """Test that TEXT node fills produce text-* classes, not bg-*."""

    def test_text_node_solid_fill_uses_text_color(self):
        """TEXT nodes with solid fills should produce text-* classes."""
        blue_fill = Paint.model_validate({
            "type": "SOLID",
            "visible": True,
            "color": {"r": 0.23, "g": 0.23, "b": 0.23, "a": 1.0},
        })
        text = _make_text_node(
            name="Title",
            text_content="Hello",
            fills=[blue_fill],
        )
        root = _make_node(children=[text])
        code = generate_component(root)
        # Should NOT have bg-* from text node fills
        # (bg-* from parent is OK)
        lines = code.split("\n")
        text_lines = [l for l in lines if "Hello" in l]
        for line in text_lines:
            # The text element should not have bg-*
            # Instead it should have text-* color
            if 'className="' in line:
                cls = line.split('className="')[1].split('"')[0]
                assert "bg-" not in cls or "text-" in cls

    def test_frame_node_fill_still_uses_bg(self):
        """Non-TEXT nodes should still use bg-* for fills."""
        fill = Paint.model_validate({
            "type": "SOLID",
            "visible": True,
            "color": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0},
        })
        node = _make_node(fills=[fill])
        code = generate_component(node)
        assert "bg-" in code


# ---------------------------------------------------------------------------
# Font-family support
# ---------------------------------------------------------------------------


class TestFontFamilySupport:
    """Test font-family extraction from TypeStyle."""

    def test_custom_font_family(self):
        """Custom fonts should produce font-['FontName'] classes."""
        style = TypeStyle.model_validate({
            "fontSize": 16.0,
            "fontWeight": 400.0,
            "fontFamily": "Poppins",
        })
        text = _make_text_node(
            name="Body",
            text_content="Hello",
            text_style=style,
        )
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "font-['Poppins']" in code

    def test_system_font_maps_to_named(self):
        """Common system fonts map to Tailwind named classes."""
        style = TypeStyle.model_validate({
            "fontSize": 16.0,
            "fontWeight": 400.0,
            "fontFamily": "Inter",
        })
        text = _make_text_node(
            name="Body",
            text_content="Hello",
            text_style=style,
        )
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "font-sans" in code
        assert "font-['Inter']" not in code

    def test_no_font_family(self):
        """No fontFamily should not add any font class."""
        style = TypeStyle.model_validate({
            "fontSize": 16.0,
            "fontWeight": 400.0,
        })
        text = _make_text_node(
            name="Body",
            text_content="Hello",
            text_style=style,
        )
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "font-['" not in code


# ---------------------------------------------------------------------------
# Duplicate class resolution with layout + style
# ---------------------------------------------------------------------------


class TestNewlineHandling:
    """Test newline → <br /> conversion in JSX text."""

    def test_newline_converts_to_br(self):
        """Newlines in text should become <br /> elements."""
        result = _escape_jsx("Line one\nLine two")
        assert "<br />" in result
        assert "Line one" in result
        assert "Line two" in result

    def test_no_newline_unchanged(self):
        """Text without newlines should pass through unchanged."""
        result = _escape_jsx("No newlines here")
        assert "<br />" not in result


class TestEllipseRounding:
    """Test that ELLIPSE nodes get rounded-full class."""

    def test_ellipse_gets_rounded_full(self):
        """ELLIPSE nodes should always have rounded-full."""
        node = _make_node(
            node_type=NodeType.ELLIPSE,
            name="Circle",
            width=48.0,
            height=48.0,
        )
        code = generate_component(node)
        assert "rounded-full" in code


class TestRotationAndBlendMode:
    """Test that rotation and blend mode are wired to the style builder."""

    def test_rotation_produces_rotate_class(self):
        """A rotated node should produce a rotate-* class."""
        node = _make_node(rotation=45.0)
        code = generate_component(node)
        assert "rotate-45" in code or "-rotate-45" in code

    def test_blend_mode_produces_mix_blend_class(self):
        """A node with blend mode should produce mix-blend-* class."""
        node = _make_node(blend_mode="MULTIPLY")
        # blend_mode on FigmaIRNode stores the CSS value after mapping in style_builder
        # Actually, style_builder.blend_mode() maps Figma names → CSS values
        code = generate_component(node)
        assert "mix-blend-multiply" in code


class TestTextAutoResize:
    """Test text auto-resize suppresses fixed dimensions."""

    def test_width_and_height_auto_suppresses_both(self):
        """WIDTH_AND_HEIGHT should suppress both w- and h- classes."""
        node = _make_text_node(
            text_auto_resize="WIDTH_AND_HEIGHT",
            width=200.0,
            height=24.0,
        )
        code = generate_component(node)
        # Should NOT have w-50 or h-6 from fixed dimensions
        assert "w-50" not in code
        assert "h-6" not in code

    def test_height_auto_suppresses_only_height(self):
        """HEIGHT should suppress h- but keep w- class."""
        node = _make_text_node(
            text_auto_resize="HEIGHT",
            width=200.0,
            height=24.0,
        )
        code = generate_component(node)
        assert "h-6" not in code
        # Width should still be present
        assert "w-50" in code

    def test_none_keeps_both_dimensions(self):
        """NONE should keep both w- and h- classes."""
        node = _make_text_node(
            text_auto_resize="NONE",
            width=200.0,
            height=24.0,
        )
        code = generate_component(node)
        assert "w-50" in code
        assert "h-6" in code


class TestLayoutStyleDedup:
    """Test that layout + style classes don't produce duplicates."""

    def test_fixed_child_no_duplicate_width(self):
        """A FIXED-width child should not get w-* from both layout and style."""
        child = _make_node(
            node_id="2:1",
            name="FixedBox",
            width=144.0,
            height=80.0,
            layout_sizing_horizontal=LayoutSizingMode.FIXED,
            layout_sizing_vertical=LayoutSizingMode.FIXED,
        )
        root = _make_node(
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            children=[child],
        )
        code = generate_component(root)
        # Extract className of the child element
        # The w-36 class (144/4=36) should appear only once
        import re
        w_classes = re.findall(r'w-36', code)
        assert len(w_classes) <= 1, f"Found duplicate w-36: {w_classes}"


# ---------------------------------------------------------------------------
# ARIA: _is_decorative_name
# ---------------------------------------------------------------------------

class TestIsDecorativeName:
    """Test decorative/auto-generated Figma name detection."""

    def test_empty_is_decorative(self):
        assert _is_decorative_name("") is True

    def test_whitespace_is_decorative(self):
        assert _is_decorative_name("   ") is True

    def test_frame_n_is_decorative(self):
        assert _is_decorative_name("Frame 42") is True
        assert _is_decorative_name("frame 1") is True

    def test_rectangle_is_decorative(self):
        assert _is_decorative_name("Rectangle 7") is True

    def test_group_is_decorative(self):
        assert _is_decorative_name("Group 3") is True

    def test_vector_is_decorative(self):
        assert _is_decorative_name("Vector") is True
        assert _is_decorative_name("Vector 5") is True

    def test_named_is_not_decorative(self):
        assert _is_decorative_name("HeroCard") is False
        assert _is_decorative_name("Submit Button") is False
        assert _is_decorative_name("Main Navigation") is False


# ---------------------------------------------------------------------------
# ARIA: _resolve_aria_attrs
# ---------------------------------------------------------------------------

class TestResolveAriaAttrs:
    """Unit tests for ARIA attribute resolution by tag."""

    def test_button_tag(self):
        node = _make_node(name="Login")
        attrs = _resolve_aria_attrs(node, "button")
        assert attrs == {"type": "button"}

    def test_input_tag(self):
        node = _make_node(name="Email")
        attrs = _resolve_aria_attrs(node, "input")
        assert attrs["type"] == "text"
        assert attrs["aria-label"] == "Email"

    def test_nav_tag(self):
        node = _make_node(name="Site Nav")
        attrs = _resolve_aria_attrs(node, "nav")
        assert attrs["aria-label"] == "Site Nav"

    def test_header_tag(self):
        node = _make_node(name="Header")
        attrs = _resolve_aria_attrs(node, "header")
        assert attrs["role"] == "banner"

    def test_footer_tag(self):
        node = _make_node(name="Footer")
        attrs = _resolve_aria_attrs(node, "footer")
        assert attrs["role"] == "contentinfo"

    def test_h1_tag(self):
        node = _make_node(name="Title")
        attrs = _resolve_aria_attrs(node, "h1")
        assert attrs["role"] == "heading"
        assert attrs["aria-level"] == "1"

    def test_h2_tag(self):
        node = _make_node(name="Subtitle")
        attrs = _resolve_aria_attrs(node, "h2")
        assert attrs["aria-level"] == "2"

    def test_h3_tag(self):
        node = _make_node(name="Section")
        attrs = _resolve_aria_attrs(node, "h3")
        assert attrs["aria-level"] == "3"

    def test_div_with_button_name(self):
        node = _make_node(name="Action Button")
        attrs = _resolve_aria_attrs(node, "div")
        assert attrs["role"] == "button"
        assert attrs["tabIndex"] == "{0}"

    def test_decorative_returns_empty(self):
        node = _make_node(name="Frame 42")
        attrs = _resolve_aria_attrs(node, "div")
        assert attrs == {}

    def test_regular_div_no_attrs(self):
        node = _make_node(name="ContentWrapper")
        attrs = _resolve_aria_attrs(node, "div")
        assert attrs == {}


# ---------------------------------------------------------------------------
# ARIA: _format_html_attrs
# ---------------------------------------------------------------------------

class TestFormatHtmlAttrs:
    """Test JSX attribute string formatting."""

    def test_class_only(self):
        result = _format_html_attrs("flex gap-4", {})
        assert result == ' className="flex gap-4"'

    def test_class_plus_aria(self):
        result = _format_html_attrs("flex", {"role": "banner"})
        assert result == ' className="flex" role="banner"'

    def test_aria_sorted_alphabetically(self):
        result = _format_html_attrs("", {"role": "button", "aria-label": "Go"})
        assert result == ' aria-label="Go" role="button"'

    def test_jsx_expression_no_quotes(self):
        result = _format_html_attrs("", {"tabIndex": "{0}"})
        assert result == " tabIndex={0}"

    def test_empty_both(self):
        result = _format_html_attrs("", {})
        assert result == ""


# ---------------------------------------------------------------------------
# ARIA: Full generate_component integration
# ---------------------------------------------------------------------------

class TestAriaIntegration:
    """Test ARIA attributes in full component generation."""

    def test_button_gets_type_attribute(self):
        child = _make_node(node_id="2:1", name="Submit Button", children=[])
        root = _make_node(children=[child])
        code = generate_component(root, aria=True)
        assert 'type="button"' in code

    def test_no_aria_by_default(self):
        child = _make_node(node_id="2:1", name="Submit Button", children=[])
        root = _make_node(children=[child])
        code = generate_component(root, aria=False)
        assert 'type="button"' not in code

    def test_input_gets_type_and_label(self):
        field = _make_node(node_id="2:1", name="Email Input", children=[])
        root = _make_node(children=[field])
        code = generate_component(root, aria=True)
        assert 'type="text"' in code
        assert 'aria-label="Email Input"' in code

    def test_nav_gets_aria_label(self):
        child = _make_node(node_id="3:1", name="Link", children=[])
        nav = _make_node(node_id="2:1", name="Main Navigation", children=[child])
        root = _make_node(children=[nav])
        code = generate_component(root, aria=True)
        assert 'aria-label="Main Navigation"' in code

    def test_header_gets_banner_role(self):
        child = _make_node(node_id="3:1", name="Logo", children=[])
        header = _make_node(node_id="2:1", name="Header", children=[child])
        root = _make_node(children=[header])
        code = generate_component(root, aria=True)
        assert 'role="banner"' in code

    def test_footer_gets_contentinfo_role(self):
        child = _make_node(node_id="3:1", name="Copyright", children=[])
        footer = _make_node(node_id="2:1", name="Footer", children=[child])
        root = _make_node(children=[footer])
        code = generate_component(root, aria=True)
        assert 'role="contentinfo"' in code

    def test_h1_gets_heading_role_and_level(self):
        style = TypeStyle.model_validate({"fontSize": 36.0, "fontWeight": 700.0})
        text = _make_text_node(name="PageTitle", text_content="Welcome", text_style=style)
        root = _make_node(children=[text])
        code = generate_component(root, aria=True)
        assert 'role="heading"' in code
        assert 'aria-level="1"' in code

    def test_decorative_frame_no_aria(self):
        node = _make_node(name="Frame 42")
        code = generate_component(node, aria=True)
        assert "aria-" not in code
        assert 'role=' not in code

    def test_unnamed_node_no_aria(self):
        node = _make_node(name="Rectangle 7")
        code = generate_component(node, aria=True)
        assert "aria-" not in code

    def test_classname_before_aria(self):
        """className attribute should come before ARIA attributes."""
        child = _make_node(node_id="2:1", name="Submit Button", children=[])
        root = _make_node(children=[child])
        code = generate_component(root, aria=True)
        import re
        match = re.search(r'<button\s+([^>]+?)(?:\s*/)?\s*>', code)
        if match:
            attrs = match.group(1)
            class_pos = attrs.find("className")
            type_pos = attrs.find('type=')
            if class_pos >= 0 and type_pos >= 0:
                assert class_pos < type_pos

    def test_svg_candidate_gets_role_img(self):
        icon = _make_node(
            node_id="2:1",
            name="CloseIcon",
            is_svg_candidate=True,
            width=24.0,
            height=24.0,
        )
        root = _make_node(children=[icon])
        code = generate_component(root, aria=True)
        assert 'role="img"' in code


class TestVoidElementAttrSplit:
    """Test that void elements wrapped in <div> get correct attribute placement.

    When a void element like <input> has children in the Figma IR, it gets
    wrapped in a <div>. ARIA attrs (type, aria-label) must go on the <input>,
    NOT on the wrapper <div>. Regression tests for the type-on-div bug.
    """

    def test_input_with_children_type_on_input_not_div(self):
        """type='text' must appear on <input>, not the wrapper <div>."""
        import re

        placeholder = _make_text_node(
            node_id="3:1", name="Placeholder", text_content="Enter email"
        )
        field = _make_node(
            node_id="2:1", name="Text field", children=[placeholder]
        )
        root = _make_node(children=[field])
        code = generate_component(root, aria=True)
        # type='text' must NOT be on <div>
        assert re.search(r'<div[^>]*type="text"', code) is None
        # type='text' must be on <input>
        assert re.search(r'<input[^>]*type="text"', code) is not None

    def test_input_with_children_aria_label_on_input(self):
        """aria-label must appear on <input>, not the wrapper <div>."""
        import re

        child = _make_text_node(
            node_id="3:1", name="Help text", text_content="Required"
        )
        field = _make_node(
            node_id="2:1", name="Email Input", children=[child]
        )
        root = _make_node(children=[field])
        code = generate_component(root, aria=True)
        # aria-label must NOT be on <div>
        assert re.search(r'<div[^>]*aria-label', code) is None
        # aria-label must be on <input>
        assert re.search(r'<input[^>]*aria-label="Email Input"', code) is not None

    def test_input_without_children_keeps_attrs(self):
        """Childless <input> should keep its attrs directly."""
        field = _make_node(
            node_id="2:1", name="Search Input", children=[]
        )
        root = _make_node(children=[field])
        code = generate_component(root, aria=True)
        assert 'type="text"' in code
        assert 'aria-label="Search Input"' in code
        # Should be a self-closing input, not wrapped in div
        assert "<input" in code

    def test_wrapper_div_keeps_classname(self):
        """The wrapper <div> must retain className for styling."""
        child = _make_text_node(
            node_id="3:1", name="Label", text_content="Name"
        )
        field = _make_node(
            node_id="2:1", name="Text field", children=[child],
            width=200.0, height=56.0,
        )
        root = _make_node(children=[field])
        code = generate_component(root, aria=True)
        # The wrapper div should have className
        import re
        assert re.search(r'<div\s+className="[^"]*"', code) is not None

    def test_no_aria_mode_no_attrs_on_void_wrapper(self):
        """Without aria flag, no ARIA attrs should appear anywhere."""
        child = _make_text_node(
            node_id="3:1", name="Hint", text_content="Enter value"
        )
        field = _make_node(
            node_id="2:1", name="Text field", children=[child]
        )
        root = _make_node(children=[field])
        code = generate_component(root, aria=False)
        assert 'type="text"' not in code
        assert "aria-label" not in code

    def test_button_with_children_no_split_needed(self):
        """Non-void elements like <button> should NOT split attrs."""
        label = _make_text_node(
            node_id="3:1", name="Label", text_content="Submit"
        )
        btn = _make_node(
            node_id="2:1", name="Submit Button", children=[label]
        )
        root = _make_node(children=[btn])
        code = generate_component(root, aria=True)
        # type='button' should be directly on <button>
        import re
        assert re.search(r'<button[^>]*type="button"', code) is not None


# ---------------------------------------------------------------------------
# Edge-case tests: empty / None / missing / invalid inputs
# ---------------------------------------------------------------------------


class TestEmptyNodeInputs:
    """Edge-case tests for nodes with empty or missing required fields."""

    def test_empty_name_falls_back_to_component(self):
        """_to_component_name with empty string returns 'Component'."""
        assert _to_component_name("") == "Component"

    def test_none_text_content_renders_empty_text(self):
        """Text node with None text_content should render without crash."""
        text = _make_text_node(text_content=None)
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "<p" in code

    def test_empty_text_content_renders_empty_p_tag(self):
        """Text node with empty string text_content should render a <p> tag."""
        text = _make_text_node(text_content="")
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "<p" in code

    def test_whitespace_only_text_content_renders(self):
        """Whitespace-only text content is still rendered (not filtered)."""
        text = _make_text_node(text_content="   ")
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "<p" in code

    def test_empty_children_array_produces_self_closing(self):
        """Frame with empty children list generates self-closing div."""
        root = _make_node(children=[])
        code = generate_component(root)
        assert "/>" in code

    def test_node_with_no_fills_renders_without_bg_class(self):
        """Node with empty fills list should not emit bg-* class."""
        root = _make_node(fills=[])
        code = generate_component(root)
        assert "bg-" not in code

    def test_missing_text_style_text_node_renders_p(self):
        """Text node with no text_style should still render as <p>."""
        text = _make_text_node(text_style=None)
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "<p" in code

    def test_empty_text_segments_list_renders_inline_text(self):
        """Text node with empty text_segments list uses text_content inline."""
        text = _make_text_node(text_content="Hello", text_segments=[])
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "Hello" in code
        assert "<span" not in code


class TestInvalidAndMalformedNames:
    """Edge-case tests for invalid and malformed node names."""

    def test_unicode_name_component_conversion(self):
        """Unicode characters in names produce valid component names."""
        # Unicode chars are stripped by _COMPONENT_NAME_RE (non-alphanumeric)
        result = _to_component_name("图标-icon")
        # Non-ascii stripped, 'icon' remains after split on '-'
        assert isinstance(result, str)
        assert len(result) > 0

    def test_whitespace_only_name_to_component(self):
        """Whitespace-only name falls back to 'Component'."""
        result = _to_component_name("   ")
        assert result == "Component"

    def test_special_chars_only_name_to_component(self):
        """Name with only special chars falls back to 'Component'."""
        result = _to_component_name("!@#$%^&*()")
        assert result == "Component"

    def test_number_only_name_prefixed(self):
        """Name starting with a digit gets 'Component' prefix."""
        result = _to_component_name("123abc")
        assert result.startswith("Component")

    def test_large_component_name_with_many_parts(self):
        """Very long hyphenated name converts to valid PascalCase."""
        result = _to_component_name("a-b-c-d-e-f-g-h-i-j")
        # Each single-char part becomes uppercase: A + B + ... + J
        assert result == "ABCDEFGHIJ"

    def test_invalid_node_name_with_jsx_braces(self):
        """JSX braces in node names are handled safely."""
        node = _make_node(name="{template}")
        code = generate_component(node)
        # Should not produce invalid JSX from the component name
        assert "export default function" in code


class TestBoundaryValues:
    """Edge-case tests for boundary and extreme numeric values."""

    def test_zero_width_node_generates_code(self):
        """Node with zero width should still generate component code."""
        node = _make_node(width=0.0, height=100.0)
        code = generate_component(node)
        assert "export default function" in code

    def test_zero_height_node_generates_code(self):
        """Node with zero height should still generate component code."""
        node = _make_node(width=100.0, height=0.0)
        code = generate_component(node)
        assert "export default function" in code

    def test_negative_coordinates_no_crash(self):
        """Node with negative x/y coordinates should not crash."""
        node = _make_node(x=-50.0, y=-100.0)
        code = generate_component(node)
        assert "export default function" in code

    def test_huge_dimensions_generate_large_tailwind_class(self):
        """Very large dimensions produce a Tailwind arbitrary or large class."""
        node = _make_node(width=9999.0, height=8888.0)
        code = generate_component(node)
        # Should not crash; must produce valid output
        assert "export default function" in code

    def test_boundary_font_size_exactly_32_is_h1(self):
        """Font size exactly 32 maps to h1 tag."""
        style = TypeStyle.model_validate({"fontSize": 32.0, "fontWeight": 700.0})
        node = _make_text_node(name="Title", text_style=style)
        from react_generator import _resolve_html_tag
        assert _resolve_html_tag(node) == "h1"

    def test_boundary_font_size_exactly_24_is_h2(self):
        """Font size exactly 24 maps to h2 tag."""
        style = TypeStyle.model_validate({"fontSize": 24.0, "fontWeight": 700.0})
        node = _make_text_node(name="Subtitle", text_style=style)
        from react_generator import _resolve_html_tag
        assert _resolve_html_tag(node) == "h2"

    def test_boundary_font_size_exactly_20_is_h3(self):
        """Font size exactly 20 maps to h3 tag."""
        style = TypeStyle.model_validate({"fontSize": 20.0, "fontWeight": 700.0})
        node = _make_text_node(name="Section", text_style=style)
        from react_generator import _resolve_html_tag
        assert _resolve_html_tag(node) == "h3"

    def test_boundary_font_size_just_below_20_is_p(self):
        """Font size 19 (just below h3 threshold) maps to p."""
        style = TypeStyle.model_validate({"fontSize": 19.0, "fontWeight": 400.0})
        node = _make_text_node(name="Body", text_style=style)
        from react_generator import _resolve_html_tag
        assert _resolve_html_tag(node) == "p"

    def test_zero_font_size_is_p(self):
        """Font size of 0 should not match any heading, maps to p."""
        style = TypeStyle.model_validate({"fontSize": 0.0, "fontWeight": 400.0})
        node = _make_text_node(name="Tiny", text_style=style)
        from react_generator import _resolve_html_tag
        assert _resolve_html_tag(node) == "p"


class TestMissingRequiredFields:
    """Edge-case tests for nodes missing required fields."""

    def test_node_with_no_image_ref_falls_back(self):
        """Image fill node with empty image_ref produces div fallback."""
        node = _make_node(
            node_id="99:1",
            has_image_fill=True,
            image_ref="",
            node_type=NodeType.RECTANGLE,
            width=100.0,
            height=100.0,
        )
        root = _make_node(children=[node])
        code = generate_component(root)
        # Should not produce <img> since ref is empty/missing
        assert "<div" in code

    def test_invisible_root_node_produces_empty_body(self):
        """Invisible root node produces no JSX output in component body."""
        root = _make_node(visible=False)
        code = generate_component(root)
        # Component wrapper is always emitted, but JSX body should be empty
        assert "export default function" in code

    def test_all_invisible_children_produces_self_closing_parent(self):
        """All invisible children yields self-closing parent tag."""
        c1 = _make_node(node_id="2:1", visible=False)
        c2 = _make_node(node_id="3:1", visible=False)
        root = _make_node(children=[c1, c2])
        code = generate_component(root)
        assert "/>" in code

    def test_null_text_style_in_resolve_text_styles(self):
        """_resolve_text_styles with None should return empty list."""
        from react_generator import _resolve_text_styles
        assert _resolve_text_styles(None) == []

    def test_empty_deduplicate_classes_input(self):
        """Empty input to _deduplicate_classes returns empty list."""
        assert _deduplicate_classes([]) == []

    def test_single_element_deduplicate_classes(self):
        """Single element is preserved unchanged."""
        assert _deduplicate_classes(["flex"]) == ["flex"]


class TestNullAndNoneAriaEdgeCases:
    """Edge-case tests for ARIA attributes with null / None inputs."""

    def test_empty_string_name_is_decorative(self):
        """Empty string name is treated as decorative."""
        assert _is_decorative_name("") is True

    def test_none_name_treated_as_decorative(self):
        """None name treated as decorative (falsy)."""
        assert _is_decorative_name(None) is True

    def test_decorative_name_returns_no_aria_attrs(self):
        """Decorative node returns empty dict for any tag."""
        node = _make_node(name="Frame 1")
        attrs = _resolve_aria_attrs(node, "div")
        assert attrs == {}

    def test_format_html_attrs_empty_class_and_empty_aria(self):
        """Both empty inputs produce empty string."""
        assert _format_html_attrs("", {}) == ""

    def test_generate_component_with_unicode_name(self):
        """Component with unicode characters in name generates valid code."""
        root = _make_node(name="Ñoño Frame")
        code = generate_component(root)
        assert "export default function" in code
        # No SyntaxError or crash; function name must be valid
        assert "(" in code

    def test_missing_font_family_no_font_class(self):
        """TypeStyle with no font_family produces no font-* class."""
        style = TypeStyle.model_validate({"fontSize": 16.0, "fontWeight": 400.0})
        text = _make_text_node(text_style=style, text_content="Hello")
        root = _make_node(children=[text])
        code = generate_component(root)
        assert "font-['" not in code

    def test_malformed_font_family_injection_blocked(self):
        """Font family with CSS injection chars is sanitized."""
        style = TypeStyle.model_validate({
            "fontSize": 16.0,
            "fontWeight": 400.0,
            "fontFamily": "Hack'; alert(1); //",
        })
        text = _make_text_node(text_style=style, text_content="Unsafe")
        root = _make_node(children=[text])
        code = generate_component(root)
        # Injection chars stripped — no quote or semicolon in font class
        if "font-['" in code:
            import re
            font_match = re.search(r"font-\['([^']+)'\]", code)
            if font_match:
                font_value = font_match.group(1)
                assert ";" not in font_value
                assert "'" not in font_value

    def test_overflow_hidden_clips_content_class(self):
        """Node with clips_content=True should produce overflow-hidden."""
        node = _make_node(clips_content=True)
        code = generate_component(node)
        assert "overflow-hidden" in code

    def test_null_opacity_treated_as_fully_opaque(self):
        """Node with default opacity 1.0 should not emit opacity class."""
        node = _make_node(opacity=1.0)
        code = generate_component(node)
        # opacity-100 is not a standard tailwind utility that maps from 1.0
        # The style builder should skip opacity at 1.0 (no class)
        assert "opacity-0" not in code


# ---------------------------------------------------------------------------
# Phase 3: generate_split_components
# ---------------------------------------------------------------------------


class TestGenerateSplitComponents:
    def _make_component_set(self, variant_specs):
        """Build a COMPONENT_SET with variant COMPONENT children.

        variant_specs: list of (name, children) tuples
        """
        children = []
        for name, child_nodes in variant_specs:
            children.append(_make_node(
                name=name, node_type=NodeType.COMPONENT,
                children=child_nodes,
            ))
        return _make_node(
            name="Button", node_type=NodeType.COMPONENT_SET,
            children=children,
        )

    def test_split_generates_per_variant_component(self):
        cs = self._make_component_set([
            ("Type=Primary", [_make_node(node_type=NodeType.TEXT, name="Label")]),
            ("Type=Secondary", [_make_node(node_type=NodeType.TEXT, name="Label")]),
        ])
        results = generate_split_components(cs)
        assert len(results) == 2
        assert results[0]["name"] == "ButtonPrimary"
        assert results[1]["name"] == "ButtonSecondary"

    def test_split_flat_variant_names(self):
        cs = self._make_component_set([
            ("Primary", [_make_node(node_type=NodeType.TEXT, name="Label")]),
            ("Ghost", [_make_node(node_type=NodeType.TEXT, name="Label")]),
        ])
        results = generate_split_components(cs)
        assert results[0]["name"] == "ButtonPrimary"
        assert results[1]["name"] == "ButtonGhost"

    def test_split_generates_valid_react_code(self):
        cs = self._make_component_set([
            ("Type=Primary", [_make_node(node_type=NodeType.RECTANGLE, name="Icon")]),
        ])
        results = generate_split_components(cs)
        assert len(results) == 1
        code = results[0]["code"]
        assert "export default function ButtonPrimary()" in code
        assert "import React" in code

    def test_split_ignores_non_component_children(self):
        children = [
            _make_node(name="Type=Primary", node_type=NodeType.COMPONENT,
                       children=[_make_node(node_type=NodeType.TEXT, name="Label")]),
            _make_node(name="Divider", node_type=NodeType.RECTANGLE),
        ]
        cs = _make_node(name="Button", node_type=NodeType.COMPONENT_SET, children=children)
        results = generate_split_components(cs)
        assert len(results) == 1
        assert results[0]["name"] == "ButtonPrimary"

    def test_split_empty_set(self):
        cs = _make_node(name="Empty", node_type=NodeType.COMPONENT_SET, children=[])
        results = generate_split_components(cs)
        assert results == []

    def test_split_multi_key_variant_name(self):
        cs = self._make_component_set([
            ("Type=Primary, State=Default",
             [_make_node(node_type=NodeType.TEXT, name="Label")]),
        ])
        results = generate_split_components(cs)
        assert results[0]["name"] == "ButtonPrimaryDefault"


# ---------------------------------------------------------------------------
# Phase 4: Text-to-Prop Promotion
# ---------------------------------------------------------------------------


class TestIsPromotableText:
    def _make_parent(self, **overrides):
        defaults = dict(
            node_id="1:0", name="Card", node_type=NodeType.COMPONENT,
        )
        defaults.update(overrides)
        return _make_node(**defaults)

    def _make_text(self, name="Title", text_content="Hello", **overrides):
        defaults = dict(
            node_id="1:1", name=name, node_type=NodeType.TEXT,
            text_content=text_content,
        )
        defaults.update(overrides)
        return _make_node(**defaults)

    def test_semantic_name_promotes(self):
        parent = self._make_parent()
        node = self._make_text(name="Title")
        assert _is_promotable_text(node, parent) is True

    def test_label_promotes(self):
        parent = self._make_parent()
        node = self._make_text(name="Label")
        assert _is_promotable_text(node, parent) is True

    def test_description_promotes(self):
        parent = self._make_parent()
        node = self._make_text(name="Description")
        assert _is_promotable_text(node, parent) is True

    def test_non_semantic_name_rejected(self):
        parent = self._make_parent()
        node = self._make_text(name="Frame 42")
        assert _is_promotable_text(node, parent) is False

    def test_no_parent_rejected(self):
        node = self._make_text(name="Title")
        assert _is_promotable_text(node, None) is False

    def test_non_component_parent_rejected(self):
        parent = self._make_parent(node_type=NodeType.FRAME)
        node = self._make_text(name="Title")
        assert _is_promotable_text(node, parent) is False

    def test_long_text_rejected(self):
        parent = self._make_parent()
        node = self._make_text(name="Title", text_content="x" * 201)
        assert _is_promotable_text(node, parent) is False

    def test_text_with_newlines_rejected(self):
        parent = self._make_parent()
        node = self._make_text(name="Title", text_content="Hello\nWorld")
        assert _is_promotable_text(node, parent) is False

    def test_prop_role_parent_rejected(self):
        from node_parser import InstanceRole
        parent = self._make_parent(
            node_type=NodeType.INSTANCE, instance_role=InstanceRole.PROP,
        )
        node = self._make_text(name="Title")
        assert _is_promotable_text(node, parent) is False

    def test_slot_candidate_text_rejected(self):
        parent = self._make_parent()
        node = self._make_text(name="Title", is_slot_candidate=True)
        assert _is_promotable_text(node, parent) is False

    def test_slot_parent_rejected(self):
        parent = self._make_parent(is_slot_candidate=True)
        node = self._make_text(name="Title")
        assert _is_promotable_text(node, parent) is False


class TestTextToPromotionIntegration:
    def test_promoted_text_generates_props_interface(self):
        text_child = _make_node(
            node_id="2:1", name="Title", node_type=NodeType.TEXT,
            text_content="Hello",
        )
        root = _make_node(
            node_id="1:1", name="Card", node_type=NodeType.COMPONENT,
            children=[text_child],
        )
        code = generate_component(root)
        assert "interface CardProps" in code
        assert "title?: string;" in code
        assert "{title}" in code
        assert "{ title }: CardProps" in code

    def test_non_promotable_text_no_props(self):
        text_child = _make_node(
            node_id="2:1", name="RandomText123", node_type=NodeType.TEXT,
            text_content="Hello",
        )
        root = _make_node(
            node_id="1:1", name="Card", node_type=NodeType.COMPONENT,
            children=[text_child],
        )
        code = generate_component(root)
        assert "Props" not in code
        assert "export default function Card()" in code

    def test_multiple_promoted_texts(self):
        children = [
            _make_node(node_id="2:1", name="Title", node_type=NodeType.TEXT,
                       text_content="Hello"),
            _make_node(node_id="2:2", name="Description", node_type=NodeType.TEXT,
                       text_content="World"),
        ]
        root = _make_node(
            node_id="1:1", name="Card", node_type=NodeType.COMPONENT,
            children=children,
        )
        code = generate_component(root)
        assert "title?: string;" in code
        assert "description?: string;" in code
        assert "{title}" in code
        assert "{description}" in code
