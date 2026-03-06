"""React JSX code generation from Figma IR nodes.

Transforms a ``FigmaIRNode`` tree into React function components with
Tailwind CSS classes. Handles all node types, styled text segments,
image fills, and SVG candidates.

Usage::

    from .react_generator import generate_component

    jsx_code = generate_component(ir_node, image_urls={"hash": "url"})
"""

from __future__ import annotations

import re
from typing import Dict, List, Optional

from figma_types import NodeType, TypeStyle
from image_handler import ImageHandler, _sanitize_alt_text, collect_image_refs
from layout_resolver import resolve_child_layout, resolve_container_layout
from node_parser import FigmaIRNode
from style_builder import StyleBuilder
from tailwind_mapper import (
    TailwindMapper,
    map_font_size,
    map_font_weight,
    map_letter_spacing,
    map_line_height,
    map_text_align,
)


# ---------------------------------------------------------------------------
# Name sanitization
# ---------------------------------------------------------------------------

_COMPONENT_NAME_RE = re.compile(r"[^a-zA-Z0-9]")


def _to_component_name(name: str) -> str:
    """Convert a Figma node name to a valid React component name.

    Sanitizes the name to PascalCase and ensures it starts with an
    uppercase letter.

    Args:
        name: Raw Figma node name.

    Returns:
        Valid React component name (PascalCase).
    """
    # Split on non-alphanumeric chars, capitalize each part
    parts = _COMPONENT_NAME_RE.split(name)
    pascal = "".join(p.capitalize() for p in parts if p)
    if not pascal:
        return "Component"
    if pascal[0].isdigit():
        pascal = "Component" + pascal
    return pascal


# ---------------------------------------------------------------------------
# Semantic HTML resolution
# ---------------------------------------------------------------------------

# HTML void elements — these cannot have children in React/JSX.
# When a Figma node maps to a void element but has children,
# we render the void element self-closed and wrap children in a <div>.
_VOID_ELEMENTS = frozenset({
    "input", "img", "br", "hr", "meta", "link", "area", "base",
    "col", "embed", "source", "track", "wbr",
})


def _resolve_text_heading(text_style) -> Optional[str]:
    """Resolve a text node's heading tag from its font size.

    Args:
        text_style: TypeStyle from the text node.

    Returns:
        Heading tag (``"h1"``, ``"h2"``, ``"h3"``) or None.
    """
    if text_style is None:
        return None
    fs = text_style.font_size or 0
    if fs >= 32:
        return "h1"
    if fs >= 24:
        return "h2"
    if fs >= 20:
        return "h3"
    return None


def _resolve_tag_from_name(name_lower: str) -> Optional[str]:
    """Resolve an HTML tag from a Figma node name using keyword heuristics.

    Args:
        name_lower: Lowercased Figma node name.

    Returns:
        HTML tag name or None if no keyword match.
    """
    if any(kw in name_lower for kw in ("button", "btn", "cta")):
        return "button"
    if any(kw in name_lower for kw in ("input", "text field", "textfield", "search bar")):
        return "input"
    if "nav" in name_lower:
        return "nav"
    if "header" == name_lower or name_lower.startswith("header"):
        return "header"
    if "footer" == name_lower or name_lower.startswith("footer"):
        return "footer"
    return None


def _resolve_html_tag(node: FigmaIRNode) -> str:
    """Map a Figma node to a semantic HTML tag based on heuristics.

    Uses node name keywords and text style properties to infer the
    appropriate HTML element. Falls back to ``div`` for containers
    and ``p`` for text nodes.

    Args:
        node: IR node to resolve.

    Returns:
        HTML tag name (e.g., ``"button"``, ``"h1"``, ``"div"``).
    """
    tag = _resolve_tag_from_name(node.name.lower())
    if tag:
        return tag

    if node.node_type == NodeType.TEXT:
        heading = _resolve_text_heading(node.text_style)
        if heading:
            return heading
        return "p"

    return "div"


# ---------------------------------------------------------------------------
# ARIA accessibility attributes (opt-in via aria=True)
# ---------------------------------------------------------------------------

# Pattern for auto-generated Figma node names that are decorative/unnamed.
_DECORATIVE_NAME_RE = re.compile(
    r"^(Frame|Rectangle|Group|Ellipse|Vector|Line|Instance)\s*\d*$",
    re.IGNORECASE,
)


def _is_decorative_name(name: str) -> bool:
    """Check if a node name is auto-generated (decorative).

    Figma assigns names like ``Frame 42``, ``Rectangle 7``, ``Group 3``
    to unnamed nodes. These carry no semantic meaning and should not
    receive ARIA attributes.

    Args:
        name: Figma node name.

    Returns:
        True if the name is decorative / auto-generated.
    """
    if not name or not name.strip():
        return True
    return bool(_DECORATIVE_NAME_RE.match(name.strip()))


def _resolve_aria_for_tag(tag: str, node_name: str) -> Dict[str, str]:
    """Resolve ARIA attributes based on the HTML tag.

    Args:
        tag: The resolved HTML tag.
        node_name: The Figma node name.

    Returns:
        Dict of attribute name to value.
    """
    attrs: Dict[str, str] = {}

    if tag == "button":
        attrs["type"] = "button"
    elif tag == "input":
        attrs["type"] = "text"
        label = _sanitize_alt_text(node_name)
        if label:
            attrs["aria-label"] = label
    elif tag == "nav":
        label = _sanitize_alt_text(node_name)
        if label:
            attrs["aria-label"] = label
    elif tag == "header":
        attrs["role"] = "banner"
    elif tag == "footer":
        attrs["role"] = "contentinfo"
    elif tag in ("h1", "h2", "h3"):
        attrs["role"] = "heading"
        attrs["aria-level"] = tag[1]
    elif tag == "div":
        name_lower = node_name.lower()
        if any(kw in name_lower for kw in ("button", "btn", "cta")):
            attrs["role"] = "button"
            attrs["tabIndex"] = "{0}"

    return attrs


def _resolve_aria_attrs(node: FigmaIRNode, tag: str) -> Dict[str, str]:
    """Resolve ARIA accessibility attributes for a node.

    Called only when ``aria=True``. Returns a dict of HTML attribute
    name to value based on the resolved HTML tag and node properties.
    Decorative nodes receive no attributes.

    Args:
        node: IR node to resolve attributes for.
        tag: The resolved HTML tag (e.g., ``"button"``, ``"h1"``).

    Returns:
        Dict of attribute name → value.
    """
    if _is_decorative_name(node.name):
        return {}

    return _resolve_aria_for_tag(tag, node.name)


def _resolve_aria_attrs_image(node: FigmaIRNode) -> Dict[str, str]:
    """Resolve ARIA attributes for image and SVG nodes.

    Separate from ``_resolve_aria_attrs`` because image/SVG nodes
    go through ``ImageHandler`` which has its own attribute emission.

    Args:
        node: IR node with image or SVG content.

    Returns:
        Dict of ARIA attribute name → value.
    """
    attrs: Dict[str, str] = {}

    if node.is_svg_candidate:
        if _is_decorative_name(node.name):
            attrs["aria-hidden"] = "true"
            attrs["role"] = "img"
        else:
            label = _sanitize_alt_text(node.name)
            if label:
                attrs["aria-label"] = label
            attrs["role"] = "img"
    elif node.has_image_fill:
        if not _is_decorative_name(node.name):
            attrs["role"] = "img"

    return attrs


def _format_html_attrs(class_str: str, aria_attrs: Dict[str, str]) -> str:
    """Format className and ARIA attributes into a JSX attribute string.

    Produces a leading-space-prefixed string suitable for insertion into
    an opening HTML tag. ``className`` comes first, followed by other
    attributes sorted alphabetically for deterministic output.

    Args:
        class_str: Tailwind class string (may be empty).
        aria_attrs: Dict of additional attributes (may be empty).

    Returns:
        Formatted attribute string with leading space, or empty string.
    """
    parts: List[str] = []

    if class_str:
        parts.append(f'className="{class_str}"')

    for key in sorted(aria_attrs.keys()):
        val = aria_attrs[key]
        if val.startswith("{") and val.endswith("}"):
            # JSX expression syntax (e.g., tabIndex={0})
            parts.append(f"{key}={val}")
        else:
            parts.append(f'{key}="{val}"')

    if not parts:
        return ""
    return " " + " ".join(parts)


# ---------------------------------------------------------------------------
# Style resolution
# ---------------------------------------------------------------------------

_mapper = TailwindMapper()


def _deduplicate_classes(classes: List[str]) -> List[str]:
    """Remove duplicate Tailwind classes, keeping first occurrence.

    When both layout_resolver and style_builder emit the same class
    (e.g., ``w-36`` from child layout AND from style size), this
    deduplicates to prevent ``w-36 w-36`` in the output.

    Also deduplicates by prefix for conflicting utilities — e.g.,
    if both ``overflow-hidden`` appear from layout and style, only
    the first is kept.

    Args:
        classes: List of Tailwind class strings.

    Returns:
        Deduplicated list preserving first-occurrence order.
    """
    seen: set = set()
    result: List[str] = []
    for cls in classes:
        if cls not in seen:
            seen.add(cls)
            result.append(cls)
    return result


def _resolve_sizing_overrides(node: FigmaIRNode):
    """Resolve layout sizing with text auto-resize overrides.

    Args:
        node: IR node to resolve sizing for.

    Returns:
        Tuple of (sizing_h, sizing_v) values.
    """
    sizing_h = node.layout_sizing_horizontal.value if node.layout_sizing_horizontal else None
    sizing_v = node.layout_sizing_vertical.value if node.layout_sizing_vertical else None

    if node.node_type == NodeType.TEXT and node.text_auto_resize:
        if node.text_auto_resize == "WIDTH_AND_HEIGHT":
            sizing_h = "HUG"
            sizing_v = "HUG"
        elif node.text_auto_resize == "HEIGHT":
            sizing_v = "HUG"
        elif node.text_auto_resize == "TRUNCATE":
            sizing_h = "FIXED"
            sizing_v = "FIXED"

    return sizing_h, sizing_v


def _resolve_node_styles(node: FigmaIRNode) -> List[str]:
    """Build Tailwind classes for a node's visual styles.

    Uses StyleBuilder to extract CSS properties from fills, strokes,
    effects, etc., then maps them to Tailwind classes.

    For TEXT nodes, fills are mapped to ``color`` (text-*) instead of
    ``background-color`` (bg-*).

    Args:
        node: IR node to style.

    Returns:
        List of Tailwind utility classes.
    """
    sizing_h, sizing_v = _resolve_sizing_overrides(node)
    is_text = node.node_type == NodeType.TEXT

    props = (
        StyleBuilder()
        .fills(node.fills, is_text=is_text)
        .strokes(node.strokes, node.stroke_weight, stroke_align=node.stroke_align)
        .effects(node.effects)
        .corner_radius(node.corner_radius, node.corner_radii)
        .opacity(node.opacity)
        .size(node.width, node.height, sizing_h, sizing_v)
        .overflow_hidden(node.clips_content)
        .rotation(node.rotation)
        .blend_mode(node.blend_mode)
        .build()
    )

    return _mapper.map_properties(props)


_SYSTEM_FONTS = {
    "inter": "font-sans",
    "arial": "font-sans",
    "helvetica": "font-sans",
    "system-ui": "font-sans",
    "georgia": "font-serif",
    "times new roman": "font-serif",
    "courier new": "font-mono",
    "monospace": "font-mono",
}


def _resolve_font_family(family: str) -> Optional[str]:
    """Map a font family name to a Tailwind font class.

    Uses Tailwind named fonts for common system fonts, falls back
    to an arbitrary ``font-['...']`` class for custom fonts.

    Args:
        family: CSS font family name.

    Returns:
        Tailwind font class string, or None if the family is empty
        after sanitization.
    """
    tw_font = _SYSTEM_FONTS.get(family.lower())
    if tw_font:
        return tw_font
    # WS-5: Sanitize font family to [a-zA-Z0-9 \-_] before interpolating into
    # an arbitrary Tailwind class — prevents CSS injection via malicious font names
    safe_family = re.sub(r'[^a-zA-Z0-9 \-_]', '', family)
    if safe_family:
        # SEC-003: Replace spaces with underscores for Tailwind arbitrary values
        tw_family = safe_family.replace(' ', '_')
        return f"font-['{tw_family}']"
    return None


def _resolve_text_decoration(style) -> List[str]:
    """Resolve text decoration and style classes.

    Args:
        style: TypeStyle from the text node.

    Returns:
        List of Tailwind classes for italic, underline, or line-through.
    """
    classes: List[str] = []
    if style.italic:
        classes.append("italic")
    if style.text_decoration == "UNDERLINE":
        classes.append("underline")
    elif style.text_decoration == "STRIKETHROUGH":
        classes.append("line-through")
    return classes


def _resolve_text_color(style) -> Optional[str]:
    """Resolve text color from style fills.

    Args:
        style: TypeStyle with fills.

    Returns:
        Tailwind text color class, or None.
    """
    if not style.fills:
        return None
    from tailwind_mapper import snap_color
    from style_builder import _color_to_css
    visible = [f for f in style.fills if f.visible]
    if visible and visible[0].color:
        css_color = _color_to_css(visible[0].color)
        return snap_color(css_color, "text")
    return None


def _resolve_text_styles(style: Optional[TypeStyle]) -> List[str]:
    """Build Tailwind classes for text typography.

    Args:
        style: TypeStyle from the text node.

    Returns:
        List of Tailwind typography classes.
    """
    if style is None:
        return []

    classes: List[str] = []

    if style.font_size is not None:
        classes.append(map_font_size(style.font_size))
    if style.font_weight is not None:
        classes.append(map_font_weight(style.font_weight))
    if style.letter_spacing is not None and style.letter_spacing != 0:
        classes.append(map_letter_spacing(style.letter_spacing))
    if style.line_height_px is not None and style.font_size:
        classes.append(map_line_height(style.line_height_px, style.font_size))
    if style.text_align_horizontal is not None:
        align = map_text_align(style.text_align_horizontal.value)
        if align:
            classes.append(align)
    if style.font_family:
        font_cls = _resolve_font_family(style.font_family)
        if font_cls:
            classes.append(font_cls)

    classes.extend(_resolve_text_decoration(style))

    # Text case transform (UPPER, LOWER, TITLE, ORIGINAL, SMALL_CAPS, etc.)
    if style.text_case is not None:
        case_val = style.text_case.value if hasattr(style.text_case, 'value') else str(style.text_case)
        _TEXT_CASE_MAP = {
            "UPPER": "uppercase",
            "LOWER": "lowercase",
            "TITLE": "capitalize",
            "SMALL_CAPS": "small-caps",
            "SMALL_CAPS_FORCED": "small-caps",
        }
        tw_case = _TEXT_CASE_MAP.get(case_val)
        if tw_case == "small-caps":
            classes.append("font-variant-[small-caps]")
        elif tw_case:
            classes.append(tw_case)

    color_cls = _resolve_text_color(style)
    if color_cls:
        classes.append(color_cls)

    return classes


# ---------------------------------------------------------------------------
# JSX generation
# ---------------------------------------------------------------------------


def _indent(text: str, level: int) -> str:
    """Indent text by the given level (2 spaces per level).

    Args:
        text: Text to indent.
        level: Indentation level.

    Returns:
        Indented text.
    """
    prefix = "  " * level
    return "\n".join(prefix + line if line.strip() else "" for line in text.split("\n"))


def _generate_rich_text_segments(segments, tag: str, attr_str: str) -> str:
    """Generate JSX for rich text with multiple styled segments.

    Args:
        segments: List of text segments with style info.
        tag: Wrapping HTML tag.
        attr_str: Pre-formatted attribute string.

    Returns:
        JSX string with span-wrapped styled segments.
    """
    lines: List[str] = [f"<{tag}{attr_str}>"]
    for segment in segments:
        seg_classes = _resolve_text_styles(segment.style)
        text = _escape_jsx(segment.text)
        if seg_classes:
            seg_class_str = " ".join(seg_classes)
            lines.append(f'  <span className="{seg_class_str}">{text}</span>')
        else:
            lines.append(f"  {text}")
    lines.append(f"</{tag}>")
    return "\n".join(lines)


def _generate_text_jsx(
    node: FigmaIRNode,
    classes: str,
    indent_level: int,
    tag: str = "p",
    aria_attrs: Optional[Dict[str, str]] = None,
) -> str:
    """Generate JSX for a text node.

    Handles both simple text (single style) and rich text
    (multiple styled segments using <span> wrappers).

    Args:
        node: Text IR node.
        classes: Tailwind class string.
        indent_level: Current indentation level.
        tag: Semantic HTML tag to use (default ``"p"``).
        aria_attrs: Optional ARIA attributes dict (when aria=True).

    Returns:
        JSX string for the text element.
    """
    if aria_attrs:
        attr_str = _format_html_attrs(classes, aria_attrs)
    else:
        attr_str = f' className="{classes}"' if classes else ""

    if len(node.text_segments) <= 1:
        text = _escape_jsx(node.text_content or "")
        return f"<{tag}{attr_str}>{text}</{tag}>"

    return _generate_rich_text_segments(node.text_segments, tag, attr_str)


def _collect_node_classes(
    node: FigmaIRNode, parent: Optional[FigmaIRNode],
) -> List[str]:
    """Collect all Tailwind classes for a node.

    Combines layout container classes, child layout classes,
    visual style classes, and node-type-specific classes.

    Args:
        node: Current IR node.
        parent: Parent IR node (for child layout resolution).

    Returns:
        Deduplicated list of Tailwind classes.
    """
    all_classes: List[str] = []

    layout = resolve_container_layout(node)
    all_classes.extend(layout.container)

    if parent is not None:
        child_classes = resolve_child_layout(node, parent)
        all_classes.extend(child_classes)

    style_classes = _resolve_node_styles(node)
    all_classes.extend(style_classes)

    if node.node_type == NodeType.ELLIPSE:
        all_classes.append("rounded-full")

    # Text truncation (TRUNCATE auto-resize mode)
    if (
        node.node_type == NodeType.TEXT
        and node.text_auto_resize == "TRUNCATE"
    ):
        all_classes.extend(["overflow-hidden", "text-ellipsis", "whitespace-nowrap"])

    # Vertical text alignment (only for non-TOP since TOP is default)
    if node.node_type == NodeType.TEXT and node.text_align_vertical:
        _VALIGN_MAP = {"CENTER": "items-center", "BOTTOM": "items-end"}
        valign_cls = _VALIGN_MAP.get(node.text_align_vertical)
        if valign_cls:
            all_classes.extend(["flex", valign_cls])

    return _deduplicate_classes(all_classes)


def _generate_void_element_jsx(
    tag: str, class_str: str, node_aria: Dict[str, str],
    child_jsxs: List[str],
) -> str:
    """Generate JSX for a void element with children.

    Void elements (input, img, etc.) cannot have children in React.
    Wraps in a <div> with ARIA attrs on the void element and
    className on the div.

    Args:
        tag: The void HTML tag.
        class_str: Tailwind class string.
        node_aria: ARIA attributes dict.
        child_jsxs: List of child JSX strings.

    Returns:
        JSX string wrapping the void element and children.
    """
    children_str = "\n".join(f"  {jsx}" for jsx in child_jsxs)
    div_attr = f' className="{class_str}"' if class_str else ""
    if node_aria:
        void_attr = _format_html_attrs("", node_aria)
    else:
        void_attr = ""
    return f"<div{div_attr}>\n  <{tag}{void_attr} />\n{children_str}\n</div>"


def _generate_container_jsx(
    node: FigmaIRNode, tag: str, attr_str: str,
    class_str: str, node_aria: Dict[str, str],
    image_handler: ImageHandler, indent_level: int, aria: bool,
) -> str:
    """Generate JSX for a container node with children.

    Args:
        node: Container IR node.
        tag: Resolved HTML tag.
        attr_str: Pre-formatted attribute string.
        class_str: Tailwind class string.
        node_aria: ARIA attributes dict.
        image_handler: Image handler for child nodes.
        indent_level: Current indentation level.
        aria: Whether to emit ARIA attributes.

    Returns:
        JSX string for the container and its children.
    """
    if not node.children:
        return f"<{tag}{attr_str} />"

    child_jsxs: List[str] = []
    for child in node.children:
        child_jsx = _generate_node_jsx(child, node, image_handler, indent_level + 1, aria=aria)
        if child_jsx:
            child_jsxs.append(child_jsx)

    if not child_jsxs:
        return f"<{tag}{attr_str} />"

    if tag in _VOID_ELEMENTS:
        return _generate_void_element_jsx(tag, class_str, node_aria, child_jsxs)

    children_str = "\n".join(f"  {jsx}" for jsx in child_jsxs)
    return f"<{tag}{attr_str}>\n{children_str}\n</{tag}>"


def _generate_text_node_jsx(
    node: FigmaIRNode, all_classes: List[str],
    tag: str, indent_level: int, aria: bool,
) -> str:
    """Generate JSX for a text-type IR node.

    Args:
        node: Text IR node.
        all_classes: Pre-collected Tailwind classes.
        tag: Resolved HTML tag.
        indent_level: Current indentation level.
        aria: Whether to emit ARIA attributes.

    Returns:
        JSX string for the text element.
    """
    text_classes = _resolve_text_styles(node.text_style)
    full_classes = " ".join(_deduplicate_classes(all_classes + text_classes))
    text_aria = _resolve_aria_attrs(node, tag) if aria else None
    return _generate_text_jsx(node, full_classes, indent_level, tag=tag, aria_attrs=text_aria)


def _build_container_attr_str(
    tag: str, class_str: str, aria: bool, node: FigmaIRNode,
) -> tuple:
    """Build attribute string and ARIA dict for a container node.

    Args:
        tag: Resolved HTML tag.
        class_str: Tailwind class string.
        aria: Whether to emit ARIA attributes.
        node: IR node.

    Returns:
        Tuple of (attr_str, node_aria dict).
    """
    node_aria: Dict[str, str] = {}
    if aria:
        node_aria = _resolve_aria_attrs(node, tag)
        attr_str = _format_html_attrs(class_str, node_aria)
    else:
        attr_str = f' className="{class_str}"' if class_str else ""
    return attr_str, node_aria


def _generate_node_jsx(
    node: FigmaIRNode,
    parent: Optional[FigmaIRNode],
    image_handler: ImageHandler,
    indent_level: int = 0,
    aria: bool = False,
) -> str:
    """Recursively generate JSX for an IR node and its children.

    Args:
        node: Current IR node.
        parent: Parent IR node (for child layout resolution).
        image_handler: Image handler for resolving image fills.
        indent_level: Current indentation level.
        aria: When True, emit ARIA accessibility attributes.

    Returns:
        JSX string for the node subtree.
    """
    if not node.visible:
        return ""

    # Node flattening: skip wrapper divs that add no value.
    # A frame-like node with exactly one visible child, no fills/strokes/effects,
    # and no auto-layout can be flattened — render the child directly.
    if (
        node.can_be_flattened
        and node.is_frame_like
        and not image_handler.has_image(node)
    ):
        visible_children = [c for c in node.children if c.visible]
        has_styling = (
            any(f.visible for f in node.fills)
            or any(s.visible for s in node.strokes)
            or any(e.visible for e in node.effects)
            or node.corner_radius > 0
            or node.clips_content
        )
        if len(visible_children) == 1 and not has_styling:
            return _generate_node_jsx(
                visible_children[0], parent, image_handler, indent_level, aria,
            )

    all_classes = _collect_node_classes(node, parent)
    class_str = " ".join(all_classes)

    if image_handler.has_image(node):
        aria_attrs = _resolve_aria_attrs_image(node) if aria else None
        return image_handler.generate_image_jsx(node, class_str, aria_attrs=aria_attrs)

    tag = _resolve_html_tag(node)

    if node.node_type == NodeType.TEXT:
        return _generate_text_node_jsx(node, all_classes, tag, indent_level, aria)

    attr_str, node_aria = _build_container_attr_str(tag, class_str, aria, node)
    return _generate_container_jsx(
        node, tag, attr_str, class_str, node_aria,
        image_handler, indent_level, aria,
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def _append_unresolved_image_comments(
    lines: List[str], refs: List[str], image_urls: Optional[Dict[str, str]],
) -> None:
    """Append TODO comments for unresolved image references.

    Args:
        lines: Component source lines to append to.
        refs: List of image reference hashes.
        image_urls: Dict of resolved image URLs (may be None).
    """
    unresolved = [ref for ref in refs if ref not in (image_urls or {})]
    if unresolved:
        lines.append("// TODO: Resolve image references via Figma Images API:")
        for ref in unresolved:
            lines.append(f"//   - {ref}")
        lines.append("")


def _build_component_lines(name: str, jsx: str) -> List[str]:
    """Assemble the lines for a React function component.

    Args:
        name: Component name.
        jsx: JSX body string.

    Returns:
        List of source code lines.
    """
    lines: List[str] = []
    lines.append("import React from 'react';")
    lines.append("")
    lines.append(f"export default function {name}() {{")
    lines.append("  return (")
    lines.append(_indent(jsx, 2))
    lines.append("  );")
    lines.append("}")
    lines.append("")
    return lines


def generate_component(
    root: FigmaIRNode,
    component_name: Optional[str] = None,
    image_urls: Optional[Dict[str, str]] = None,
    svg_urls: Optional[Dict[str, str]] = None,
    aria: bool = False,
) -> str:
    """Generate a complete React function component from an IR node tree.

    Args:
        root: Root IR node (typically a FRAME or COMPONENT).
        component_name: Override component name. If None, derived from
            the root node's name.
        image_urls: Dict mapping image ref hashes to resolved URLs.
        svg_urls: Dict mapping node IDs to exported SVG URLs (fallback).
        aria: When True, emit ARIA accessibility attributes.

    Returns:
        Complete React component source code as a string.
    """
    name = component_name or _to_component_name(root.name)
    image_handler = ImageHandler(image_urls, svg_urls=svg_urls)
    refs = collect_image_refs(root)
    jsx = _generate_node_jsx(root, None, image_handler, indent_level=1, aria=aria)

    lines = _build_component_lines(name, jsx)
    _append_unresolved_image_comments(lines, refs, image_urls)

    return "\n".join(lines)


def _generate_props_interface(
    lines: List[str], name: str, props: List[str],
) -> None:
    """Append TypeScript props interface and function signature.

    When props are provided, emits an interface block and a
    function signature with destructured props. Otherwise emits
    a plain function signature.

    Args:
        lines: Component source lines to append to.
        name: Component name.
        props: List of prop names.
    """
    if props:
        lines.append(f"interface {name}Props {{")
        for prop in props:
            lines.append(f"  {prop}?: string;")
        lines.append("}")
        lines.append("")
        prop_destructure = ", ".join(props)
        lines.append(
            f"export default function {name}({{ {prop_destructure} }}: {name}Props) {{"
        )
    else:
        lines.append(f"export default function {name}() {{")


def generate_component_with_props(
    root: FigmaIRNode,
    component_name: Optional[str] = None,
    prop_names: Optional[List[str]] = None,
    image_urls: Optional[Dict[str, str]] = None,
    svg_urls: Optional[Dict[str, str]] = None,
    aria: bool = False,
) -> str:
    """Generate a React component with typed props interface.

    Args:
        root: Root IR node.
        component_name: Override component name.
        prop_names: List of prop names to include in the interface.
        image_urls: Dict mapping image ref hashes to resolved URLs.
        svg_urls: Dict mapping node IDs to exported SVG URLs (fallback).
        aria: When True, emit ARIA accessibility attributes.

    Returns:
        React component source code with props interface.
    """
    name = component_name or _to_component_name(root.name)
    image_handler = ImageHandler(image_urls, svg_urls=svg_urls)
    jsx = _generate_node_jsx(root, None, image_handler, indent_level=1, aria=aria)

    lines: List[str] = []
    lines.append("import React from 'react';")
    lines.append("")
    _generate_props_interface(lines, name, prop_names or [])
    lines.append("  return (")
    lines.append(_indent(jsx, 2))
    lines.append("  );")
    lines.append("}")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# JSX helpers
# ---------------------------------------------------------------------------


def _escape_jsx(text: str) -> str:
    """Escape text for safe inclusion in JSX.

    Handles curly braces and angle brackets that have special
    meaning in JSX.

    Args:
        text: Raw text content.

    Returns:
        JSX-safe text string.
    """
    # SEC-004: Escape & first to prevent double-escaping of entities below
    text = text.replace("&", "&amp;")
    text = text.replace("{", "&#123;")
    text = text.replace("}", "&#125;")
    text = text.replace("<", "&lt;")
    text = text.replace(">", "&gt;")
    # Convert newlines to JSX <br /> elements
    if "\n" in text:
        parts = text.split("\n")
        text = "<br />\n".join(parts)
    return text
