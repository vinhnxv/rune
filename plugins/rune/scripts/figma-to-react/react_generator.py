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
    name_lower = node.name.lower()

    # Button detection
    if any(kw in name_lower for kw in ("button", "btn", "cta")):
        return "button"

    # Input detection
    if any(kw in name_lower for kw in ("input", "text field", "textfield", "search bar")):
        return "input"

    # Navigation
    if "nav" in name_lower:
        return "nav"

    # Header / footer / main / section
    if "header" == name_lower or name_lower.startswith("header"):
        return "header"
    if "footer" == name_lower or name_lower.startswith("footer"):
        return "footer"

    # Text nodes → heading by font size
    if node.node_type == NodeType.TEXT and node.text_style:
        fs = node.text_style.font_size or 0
        if fs >= 32:
            return "h1"
        if fs >= 24:
            return "h2"
        if fs >= 20:
            return "h3"

    # Text nodes default to <p>
    if node.node_type == NodeType.TEXT:
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

    attrs: Dict[str, str] = {}
    name_lower = node.name.lower()

    if tag == "button":
        attrs["type"] = "button"

    elif tag == "input":
        attrs["type"] = "text"
        label = _sanitize_alt_text(node.name)
        if label:
            attrs["aria-label"] = label

    elif tag == "nav":
        label = _sanitize_alt_text(node.name)
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
        # Interactive-looking nodes that resolved to div
        if any(kw in name_lower for kw in ("button", "btn", "cta")):
            attrs["role"] = "button"
            attrs["tabIndex"] = "{0}"

    return attrs


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
    sizing_h = node.layout_sizing_horizontal.value if node.layout_sizing_horizontal else None
    sizing_v = node.layout_sizing_vertical.value if node.layout_sizing_vertical else None

    is_text = node.node_type == NodeType.TEXT

    # Text auto-resize: suppress fixed dimensions when text auto-sizes
    if is_text and node.text_auto_resize:
        if node.text_auto_resize == "WIDTH_AND_HEIGHT":
            sizing_h = "HUG"
            sizing_v = "HUG"
        elif node.text_auto_resize == "HEIGHT":
            sizing_v = "HUG"

    props = (
        StyleBuilder()
        .fills(node.fills, is_text=is_text)
        .strokes(node.strokes, node.stroke_weight)
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

    # Font family — map to Tailwind arbitrary font-['...'] class
    if style.font_family:
        family = style.font_family
        # Use Tailwind named fonts for common system fonts
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
        tw_font = _SYSTEM_FONTS.get(family.lower())
        if tw_font:
            classes.append(tw_font)
        else:
            # WS-5: Sanitize font family to [a-zA-Z0-9 \-_] before interpolating into
            # an arbitrary Tailwind class — prevents CSS injection via malicious font names
            safe_family = re.sub(r'[^a-zA-Z0-9 \-_]', '', family)
            if safe_family:
                classes.append(f"font-['{safe_family}']")

    if style.italic:
        classes.append("italic")

    if style.text_decoration == "UNDERLINE":
        classes.append("underline")
    elif style.text_decoration == "STRIKETHROUGH":
        classes.append("line-through")

    # Text color from fills
    if style.fills:
        from tailwind_mapper import snap_color
        from style_builder import _color_to_css
        visible = [f for f in style.fills if f.visible]
        if visible and visible[0].color:
            css_color = _color_to_css(visible[0].color)
            classes.append(snap_color(css_color, "text"))

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

    # Simple text (no segments or single segment)
    if len(node.text_segments) <= 1:
        text = _escape_jsx(node.text_content or "")
        return f"<{tag}{attr_str}>{text}</{tag}>"

    # Rich text with styled segments
    lines: List[str] = [f"<{tag}{attr_str}>"]
    for segment in node.text_segments:
        seg_classes = _resolve_text_styles(segment.style)
        text = _escape_jsx(segment.text)
        if seg_classes:
            seg_class_str = " ".join(seg_classes)
            lines.append(f'  <span className="{seg_class_str}">{text}</span>')
        else:
            lines.append(f"  {text}")
    lines.append(f"</{tag}>")
    return "\n".join(lines)


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

    # Collect all classes
    all_classes: List[str] = []

    # Layout classes (container)
    layout = resolve_container_layout(node)
    all_classes.extend(layout.container)

    # Child layout classes (how this node behaves in parent's layout)
    if parent is not None:
        child_classes = resolve_child_layout(node, parent)
        all_classes.extend(child_classes)

    # Visual style classes
    style_classes = _resolve_node_styles(node)
    all_classes.extend(style_classes)

    # ELLIPSE nodes always get rounded-full (circles/ovals)
    if node.node_type == NodeType.ELLIPSE:
        all_classes.append("rounded-full")

    all_classes = _deduplicate_classes(all_classes)
    class_str = " ".join(all_classes)

    # Image/SVG handling
    if image_handler.has_image(node):
        aria_attrs = _resolve_aria_attrs_image(node) if aria else None
        return image_handler.generate_image_jsx(node, class_str, aria_attrs=aria_attrs)

    # Resolve semantic HTML tag
    tag = _resolve_html_tag(node)

    # Text node
    if node.node_type == NodeType.TEXT:
        text_classes = _resolve_text_styles(node.text_style)
        full_classes = " ".join(_deduplicate_classes(all_classes + text_classes))
        text_aria = _resolve_aria_attrs(node, tag) if aria else None
        return _generate_text_jsx(node, full_classes, indent_level, tag=tag, aria_attrs=text_aria)

    # Container/element node — build attribute string
    node_aria: Dict[str, str] = {}
    if aria:
        node_aria = _resolve_aria_attrs(node, tag)
        attr_str = _format_html_attrs(class_str, node_aria)
    else:
        attr_str = f' className="{class_str}"' if class_str else ""

    if not node.children:
        if tag in _VOID_ELEMENTS:
            return f"<{tag}{attr_str} />"
        return f"<{tag}{attr_str} />"

    # Generate children
    child_jsxs: List[str] = []
    for child in node.children:
        child_jsx = _generate_node_jsx(child, node, image_handler, indent_level + 1, aria=aria)
        if child_jsx:
            child_jsxs.append(child_jsx)

    if not child_jsxs:
        if tag in _VOID_ELEMENTS:
            return f"<{tag}{attr_str} />"
        return f"<{tag}{attr_str} />"

    # Void elements (input, img, etc.) cannot have children in React.
    # Wrap in a <div> — ARIA attrs go on the void element, className on the div.
    if tag in _VOID_ELEMENTS:
        children_str = "\n".join(f"  {jsx}" for jsx in child_jsxs)
        # Split attrs: className on wrapper div, ARIA/type on the void element
        div_attr = f' className="{class_str}"' if class_str else ""
        if node_aria:
            void_attr = _format_html_attrs("", node_aria)
        else:
            void_attr = ""
        return f"<div{div_attr}>\n  <{tag}{void_attr} />\n{children_str}\n</div>"

    children_str = "\n".join(f"  {jsx}" for jsx in child_jsxs)
    return f"<{tag}{attr_str}>\n{children_str}\n</{tag}>"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def generate_component(
    root: FigmaIRNode,
    component_name: Optional[str] = None,
    image_urls: Optional[Dict[str, str]] = None,
    svg_urls: Optional[Dict[str, str]] = None,
    aria: bool = False,
) -> str:
    """Generate a complete React function component from an IR node tree.

    Produces a self-contained React component with:
    - Import statement for React
    - Function component with proper name
    - JSX body with Tailwind classes
    - Export default

    Args:
        root: Root IR node (typically a FRAME or COMPONENT).
        component_name: Override component name. If None, derived from
            the root node's name.
        image_urls: Dict mapping image ref hashes to resolved URLs.
        svg_urls: Dict mapping node IDs to exported SVG URLs (fallback for
            nodes with no fill or stroke geometry).
        aria: When True, emit ARIA accessibility attributes.

    Returns:
        Complete React component source code as a string.
    """
    name = component_name or _to_component_name(root.name)
    image_handler = ImageHandler(image_urls, svg_urls=svg_urls)

    # Collect image refs that need resolution
    refs = collect_image_refs(root)

    # Generate JSX body
    jsx = _generate_node_jsx(root, None, image_handler, indent_level=1, aria=aria)

    # Build component
    lines: List[str] = []
    lines.append("import React from 'react';")
    lines.append("")
    lines.append(f"export default function {name}() {{")
    lines.append("  return (")
    lines.append(_indent(jsx, 2))
    lines.append("  );")
    lines.append("}")
    lines.append("")

    # Add TODO comments for unresolved images
    unresolved = [ref for ref in refs if ref not in (image_urls or {})]
    if unresolved:
        lines.append("// TODO: Resolve image references via Figma Images API:")
        for ref in unresolved:
            lines.append(f"//   - {ref}")
        lines.append("")

    return "\n".join(lines)


def generate_component_with_props(
    root: FigmaIRNode,
    component_name: Optional[str] = None,
    prop_names: Optional[List[str]] = None,
    image_urls: Optional[Dict[str, str]] = None,
    svg_urls: Optional[Dict[str, str]] = None,
    aria: bool = False,
) -> str:
    """Generate a React component with typed props interface.

    Similar to ``generate_component`` but includes a TypeScript-style
    props interface and passes props to the component function.

    Args:
        root: Root IR node.
        component_name: Override component name.
        prop_names: List of prop names to include in the interface.
        image_urls: Dict mapping image ref hashes to resolved URLs.
        svg_urls: Dict mapping node IDs to exported SVG URLs (fallback for
            nodes with no fill or stroke geometry).
        aria: When True, emit ARIA accessibility attributes.

    Returns:
        React component source code with props interface.
    """
    name = component_name or _to_component_name(root.name)
    image_handler = ImageHandler(image_urls, svg_urls=svg_urls)
    props = prop_names or []

    jsx = _generate_node_jsx(root, None, image_handler, indent_level=1, aria=aria)

    lines: List[str] = []
    lines.append("import React from 'react';")
    lines.append("")

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
    text = text.replace("{", "&#123;")
    text = text.replace("}", "&#125;")
    text = text.replace("<", "&lt;")
    text = text.replace(">", "&gt;")
    # Convert newlines to JSX <br /> elements
    if "\n" in text:
        parts = text.split("\n")
        text = "<br />\n".join(parts)
    return text
